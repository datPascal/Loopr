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
        manager.startUpdatingLocation()
    }

    func stopUpdatingLocation() {
        manager.stopUpdatingLocation()
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
        guard !isRunning else { return }
        if let startTask {
            try await startTask.value
            return
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            try await self.performStart()
        }
        startTask = task
        defer { startTask = nil }
        try await task.value
    }

    func stop() async {
        startTask?.cancel()
        startTask = nil
        authorizationContinuation?.resume(returning: .denied)
        authorizationContinuation = nil
        guard isRunning else { return }
        isRunning = false
        isInterrupted = false
        driver?.stopUpdatingLocation()
    }

    func events() -> AsyncStream<LocationGateEvent> { eventStream }

    func locationFixes() -> AsyncStream<RoutePoint> { fixStream }

    private func performStart() async throws {
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
