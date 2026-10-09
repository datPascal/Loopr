#if canImport(CoreLocation)
import CoreLocation
import Foundation
import RouteKit
import Testing
@testable import Loopr

@MainActor
struct CoreLocationRouteAdapterTests {
    @Test
    func permissionIsNotRequestedUntilExplicitStartAndStopIsIdempotent() async throws {
        let driver = FakeCoreLocationRouteDriver(status: .notDetermined)
        let adapter = CoreLocationRouteAdapter(driverFactory: { driver })

        #expect(driver.requestCount == 0)
        let startTask = Task { @MainActor in try await adapter.start() }
        for _ in 0..<20 where driver.requestCount == 0 {
            await Task.yield()
        }
        #expect(driver.requestCount == 1)

        driver.resolve(.authorizedWhenInUse)
        try await startTask.value
        #expect(driver.startCount == 1)

        await adapter.stop()
        await adapter.stop()
        #expect(driver.stopCount == 1)
    }

    @Test
    func deniedAndDisabledServicesFailClosed() async {
        let deniedDriver = FakeCoreLocationRouteDriver(status: .denied)
        let deniedAdapter = CoreLocationRouteAdapter(driverFactory: { deniedDriver })
        let deniedEvents = Task { @MainActor in
            var iterator = deniedAdapter.events().makeAsyncIterator()
            return await iterator.next()
        }

        await #expect(throws: LocationGateError.permissionDenied) {
            try await deniedAdapter.start()
        }
        #expect(await deniedEvents.value == .permissionRevoked)
        #expect(deniedDriver.requestCount == 0)
        #expect(deniedDriver.startCount == 0)

        let disabledDriver = FakeCoreLocationRouteDriver(status: .notDetermined, servicesEnabled: false)
        let disabledAdapter = CoreLocationRouteAdapter(driverFactory: { disabledDriver })
        await #expect(throws: LocationGateError.unavailable) {
            try await disabledAdapter.start()
        }
        #expect(disabledDriver.requestCount == 0)
        #expect(disabledDriver.startCount == 0)
    }

    @Test
    func finiteLocationFieldsForwardWithoutZeroFillingUnavailableValues() async throws {
        let driver = FakeCoreLocationRouteDriver(status: .authorizedWhenInUse)
        let adapter = CoreLocationRouteAdapter(driverFactory: { driver })
        try await adapter.start()

        let pointTask = Task { @MainActor in
            var iterator = adapter.locationFixes().makeAsyncIterator()
            return await iterator.next()
        }
        let invalid = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 91, longitude: 181),
            altitude: 0,
            horizontalAccuracy: 5,
            verticalAccuracy: 5,
            course: -1,
            speed: -1,
            timestamp: Date(timeIntervalSince1970: 10)
        )
        let valid = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 40, longitude: -73),
            altitude: 0,
            horizontalAccuracy: 5,
            verticalAccuracy: -1,
            course: -1,
            speed: -1,
            timestamp: Date(timeIntervalSince1970: 11)
        )
        driver.emit([invalid, valid])

        let point = try #require(await pointTask.value)
        #expect(point.latitude == 40)
        #expect(point.longitude == -73)
        #expect(point.horizontalAccuracy == 5)
        #expect(point.altitude == nil)
        #expect(point.speedMetersPerSecond == nil)
    }

    @Test
    func interruptionResumeAndPermissionRevocationAreSemanticAndOrdered() async throws {
        let driver = FakeCoreLocationRouteDriver(status: .authorizedWhenInUse)
        let adapter = CoreLocationRouteAdapter(driverFactory: { driver })
        try await adapter.start()

        let eventsTask = Task { @MainActor in
            var iterator = adapter.events().makeAsyncIterator()
            return [await iterator.next(), await iterator.next(), await iterator.next()]
        }
        driver.pause()
        driver.resume()
        driver.resolve(.denied)

        let events = await eventsTask.value.compactMap { $0 }
        #expect(events == [.interruptionBegan, .interruptionEnded, .permissionRevoked])
        #expect(driver.stopCount == 1)
    }
}

@MainActor
private final class FakeCoreLocationRouteDriver: NSObject, CoreLocationRouteDriver {
    private let callbackManager = CLLocationManager()
    private(set) var status: CLAuthorizationStatus
    let locationServicesEnabled: Bool
    weak var delegate: CLLocationManagerDelegate?
    private(set) var requestCount = 0
    private(set) var startCount = 0
    private(set) var stopCount = 0

    init(status: CLAuthorizationStatus, servicesEnabled: Bool = true) {
        self.status = status
        self.locationServicesEnabled = servicesEnabled
        super.init()
    }

    var authorizationStatus: CLAuthorizationStatus { status }

    func requestWhenInUseAuthorization() {
        requestCount += 1
    }

    func startUpdatingLocation() {
        startCount += 1
    }

    func stopUpdatingLocation() {
        stopCount += 1
    }

    func resolve(_ status: CLAuthorizationStatus) {
        self.status = status
        delegate?.locationManagerDidChangeAuthorization?(callbackManager)
    }

    func emit(_ locations: [CLLocation]) {
        delegate?.locationManager?(callbackManager, didUpdateLocations: locations)
    }

    func pause() {
        delegate?.locationManagerDidPauseLocationUpdates?(callbackManager)
    }

    func resume() {
        delegate?.locationManagerDidResumeLocationUpdates?(callbackManager)
    }
}
#endif
