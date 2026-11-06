import Foundation
import RouteKit

/// Separate from `LocationStartGate` so a route recorder can consume real
/// location fixes without coupling its permission lifecycle to Core Location.
@MainActor
protocol RouteLocationFixSource: AnyObject {
    func locationFixes() -> AsyncStream<RoutePoint>
}

#if canImport(CoreLocation)
import CoreLocation

/// The narrow Core Location driver seam keeps `CLLocationManager` behind an
/// injectable boundary.  The app adapter owns the delegate and permission
/// policy; tests can use a deterministic driver without starting Core
/// Location services.
@MainActor
protocol CoreLocationRouteDriver: AnyObject {
    var authorizationStatus: CLAuthorizationStatus { get }
    var locationServicesEnabled: Bool { get }
    var delegate: CLLocationManagerDelegate? { get set }

    func requestWhenInUseAuthorization()
    func startUpdatingLocation()
    func stopUpdatingLocation()
}

typealias CoreLocationRouteDriverFactory = @MainActor () -> any CoreLocationRouteDriver

@MainActor
final class CoreLocationManagerRouteDriver: NSObject, CoreLocationRouteDriver {
    private let manager: CLLocationManager

    override init() {
        manager = CLLocationManager()
        super.init()
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
    }

    private static var mayUpdateInBackground: Bool {
        (Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String])?.contains("location") == true
    }

    var authorizationStatus: CLAuthorizationStatus { manager.authorizationStatus }

    var locationServicesEnabled: Bool { CLLocationManager.locationServicesEnabled() }

    var delegate: CLLocationManagerDelegate? {
        get { manager.delegate }
        set { manager.delegate = newValue }
    }

    func requestWhenInUseAuthorization() {
        manager.requestWhenInUseAuthorization()
    }

    func startUpdatingLocation() {
        // A run is done with the phone in a belt. Background updates run only between start and stop, under
        // When In Use, with the system's blue indicator showing. Asking without the Info.plist mode would crash.
        if Self.mayUpdateInBackground {
            manager.allowsBackgroundLocationUpdates = true
            manager.showsBackgroundLocationIndicator = true
        }
        manager.pausesLocationUpdatesAutomatically = false
        manager.activityType = .fitness
        manager.startUpdatingLocation()
    }

    func stopUpdatingLocation() {
        manager.stopUpdatingLocation()
        if Self.mayUpdateInBackground { manager.allowsBackgroundLocationUpdates = false }
    }
}

/// Permission-aware, fail-closed Core Location composition for eligible route
/// workouts. It never requests permission during initialization and never
/// starts location services until `start()` is explicitly called.
@MainActor
final class CoreLocationRouteAdapter: NSObject, @preconcurrency LocationStartGate, RouteLocationFixSource, CLLocationManagerDelegate {
    private let driverFactory: CoreLocationRouteDriverFactory
    private var driver: (any CoreLocationRouteDriver)?
    private let eventStream: AsyncStream<LocationGateEvent>
    private var eventContinuation: AsyncStream<LocationGateEvent>.Continuation
    private let fixStream: AsyncStream<RoutePoint>
    private var fixContinuation: AsyncStream<RoutePoint>.Continuation
    private var authorizationContinuation: CheckedContinuation<CLAuthorizationStatus, Never>?
    private var startTask: Task<Void, Error>?
    private var startID: UUID?
    private var isRunning = false
    private var isInterrupted = false
    private var lastAuthorizationStatus: CLAuthorizationStatus?
    private var permissionRevokedEmitted = false

    init(driverFactory: @escaping CoreLocationRouteDriverFactory = { CoreLocationManagerRouteDriver() }) {
        self.driverFactory = driverFactory
        let eventPair = AsyncStream<LocationGateEvent>.makeStream()
        eventStream = eventPair.stream
        eventContinuation = eventPair.continuation
        let fixPair = AsyncStream<RoutePoint>.makeStream()
        fixStream = fixPair.stream
        fixContinuation = fixPair.continuation
        super.init()
    }

    deinit {
        eventContinuation.finish()
        fixContinuation.finish()
    }

    func start() async throws {
        try Task.checkCancellation()
        guard !isRunning else { return }
        if let startTask {
            try await startTask.value
            return
        }

        let id = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            try await self.performStart()
        }
        startTask = task
        startID = id
        defer {
            if startID == id { startTask = nil; startID = nil }
        }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
            Task { @MainActor [weak self] in self?.cancelStart(id: id) }
        }
    }

    func stop() async {
        let pending = startTask
        pending?.cancel()
        startTask = nil
        startID = nil
        authorizationContinuation?.resume(returning: .denied)
        authorizationContinuation = nil
        if isRunning { driver?.stopUpdatingLocation() }
        isRunning = false
        isInterrupted = false
        _ = await pending?.result
    }

    func events() -> AsyncStream<LocationGateEvent> { eventStream }

    func locationFixes() -> AsyncStream<RoutePoint> { fixStream }

    private func performStart() async throws {
        try Task.checkCancellation()
        guard !isRunning else { return }
        let driver = ensureDriver()
        let status = driver.authorizationStatus
        lastAuthorizationStatus = status

        guard driver.locationServicesEnabled else {
            if isRunning { emitInterruptionBegan() }
            throw LocationGateError.unavailable
        }

        let resolvedStatus: CLAuthorizationStatus
        switch status {
        case .notDetermined:
            resolvedStatus = await awaitAuthorization(using: driver)
        default:
            resolvedStatus = status
        }

        try Task.checkCancellation()
        switch resolvedStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            permissionRevokedEmitted = false
            driver.startUpdatingLocation()
            isRunning = true
            isInterrupted = false
        case .denied, .restricted:
            emitPermissionRevoked()
            throw LocationGateError.permissionDenied
        case .notDetermined:
            throw LocationGateError.permissionDenied
        @unknown default:
            throw LocationGateError.unavailable
        }
    }

    private func cancelStart(id: UUID) {
        guard startID == id else { return }
        authorizationContinuation?.resume(returning: .denied)
        authorizationContinuation = nil
    }

    /// What Core Location reports right now. Reading the status never prompts,
    /// so callers can ask before starting a recording. `.notDetermined` maps to
    /// `.notRequested`, which leaves room for `start()` to show the prompt.
    var currentRoutePermission: RoutePermission {
        switch ensureDriver().authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: return .authorized
        case .denied, .restricted: return .denied
        default: return .notRequested
        }
    }

    private func ensureDriver() -> any CoreLocationRouteDriver {
        if let driver { return driver }
        let driver = driverFactory()
        driver.delegate = self
        self.driver = driver
        return driver
    }

    private func awaitAuthorization(using driver: any CoreLocationRouteDriver) async -> CLAuthorizationStatus {
        await withCheckedContinuation { continuation in
            authorizationContinuation = continuation
            guard driver.authorizationStatus == .notDetermined else {
                authorizationContinuation = nil
                continuation.resume(returning: driver.authorizationStatus)
                return
            }
            driver.requestWhenInUseAuthorization()
        }
    }

    private func resolveAuthorization(_ status: CLAuthorizationStatus) {
        lastAuthorizationStatus = status
        authorizationContinuation?.resume(returning: status)
        authorizationContinuation = nil
        if status == .denied || status == .restricted {
            if isRunning { driver?.stopUpdatingLocation(); isRunning = false }
            emitPermissionRevoked()
        } else {
            permissionRevokedEmitted = false
        }
    }

    private func emitPermissionRevoked() {
        guard !permissionRevokedEmitted else { return }
        permissionRevokedEmitted = true
        eventContinuation.yield(.permissionRevoked)
    }

    private func emitInterruptionBegan() {
        guard isRunning, !isInterrupted else { return }
        isInterrupted = true
        eventContinuation.yield(.interruptionBegan)
    }

    private func emitInterruptionEnded() {
        guard isRunning, isInterrupted else { return }
        isInterrupted = false
        eventContinuation.yield(.interruptionEnded)
    }

    private func routePoint(from location: CLLocation) -> RoutePoint? {
        let coordinate = location.coordinate
        let timestamp = location.timestamp.timeIntervalSinceReferenceDate
        let horizontalAccuracy = location.horizontalAccuracy
        guard CLLocationCoordinate2DIsValid(coordinate),
              coordinate.latitude.isFinite,
              coordinate.longitude.isFinite,
              timestamp.isFinite,
              horizontalAccuracy.isFinite,
              horizontalAccuracy >= 0 else {
            return nil
        }

        let altitude: Double?
        if location.verticalAccuracy.isFinite, location.verticalAccuracy >= 0, location.altitude.isFinite {
            altitude = location.altitude
        } else {
            altitude = nil
        }

        let speed: Double?
        if location.speed.isFinite, location.speed >= 0 {
            speed = location.speed
        } else {
            speed = nil
        }

        return RoutePoint(
            timestamp: location.timestamp,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            horizontalAccuracy: horizontalAccuracy,
            altitude: altitude,
            speedMetersPerSecond: speed
        )
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        resolveAuthorization(driver?.authorizationStatus ?? manager.authorizationStatus)
    }

    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        resolveAuthorization(driver?.authorizationStatus ?? status)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard isRunning else { return }
        emitInterruptionEnded()
        for location in locations {
            guard let point = routePoint(from: location) else { continue }
            fixContinuation.yield(point)
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if let error = error as? CLError, error.code == .denied {
            resolveAuthorization(.denied)
            return
        }
        emitInterruptionBegan()
    }

    func locationManagerDidPauseLocationUpdates(_ manager: CLLocationManager) {
        emitInterruptionBegan()
    }

    func locationManagerDidResumeLocationUpdates(_ manager: CLLocationManager) {
        emitInterruptionEnded()
    }
}
#else

typealias CoreLocationRouteDriverFactory = @MainActor () -> AnyObject

@MainActor
final class CoreLocationManagerRouteDriver: NSObject {}

@MainActor
final class CoreLocationRouteAdapter: NSObject, LocationStartGate, RouteLocationFixSource {
    init(driverFactory: @escaping CoreLocationRouteDriverFactory = { NSObject() }) {}

    func start() async throws { throw LocationGateError.unavailable }
    func stop() async {}
    func events() -> AsyncStream<LocationGateEvent> { AsyncStream { $0.finish() } }
    func locationFixes() -> AsyncStream<RoutePoint> { AsyncStream { $0.finish() } }
}
#endif
