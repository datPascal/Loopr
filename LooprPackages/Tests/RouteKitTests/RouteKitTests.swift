import RouteKit
import XCTest

private actor LocationFixture: LocationStartGate {
    private(set) var starts = 0
    private(set) var stops = 0
    func start() async { starts += 1 }
    func stop() async { stops += 1 }
    func counts() -> (Int, Int) { (starts, stops) }
}

private actor ParentFinalizerFixture {
    private(set) var workoutIDs: [String] = []
    func finalize(_ id: String) { workoutIDs.append(id) }
    func all() -> [String] { workoutIDs }
}

private enum RouteStoreFixtureError: Error { case writeFailed }

private actor FailingRouteStore: RouteStore {
    private var rows: [String: RouteRecord] = [:]
    func route(workoutID: String) -> RouteRecord? { rows[workoutID] }
    func all() -> [RouteRecord] { Array(rows.values) }
    func save(_: RouteRecord) throws { throw RouteStoreFixtureError.writeFailed }
    func delete(workoutID: String) { rows.removeValue(forKey: workoutID) }
    func count() -> Int { rows.count }
    func deleteAll() { rows.removeAll() }
}

final class RouteKitTests: XCTestCase {
    private func point(_ lat: Double, _ lon: Double, _ seconds: Double, accuracy: Double = 5) -> RoutePoint {
        RoutePoint(timestamp: Date(timeIntervalSince1970: seconds), latitude: lat, longitude: lon, horizontalAccuracy: accuracy, speedMetersPerSecond: 3)
    }

    func testConcurrentPointsDoNotOverwriteEachOther() async throws {
        let recorder = RouteRecorder(location: LocationFixture())
        try await recorder.start(workoutID: "concurrent", activity: .walk, permission: .authorized)
        let accepted = try await withThrowingTaskGroup(of: Bool.self) { group in
            for index in 0..<100 {
                let sample = RoutePoint(timestamp: Date(timeIntervalSince1970: 100), latitude: 0,
                    longitude: Double(index) / 1_000_000, horizontalAccuracy: 5)
                group.addTask { try await recorder.append(sample) }
            }
            var count = 0
            for try await success in group { if success { count += 1 } }
            return count
        }
        let route = try await recorder.finish()
        XCTAssertEqual(accepted, 100)
        XCTAssertEqual(route.points.count, accepted)
        XCTAssertEqual(Set(route.points.map(\.longitude)).count, accepted)
    }

    func testLateResumeCannotRestartAFinishedRoute() async throws {
        let location = DelayedResumeLocation()
        let recorder = RouteRecorder(location: location)
        try await recorder.start(workoutID: "late-resume", activity: .walk, permission: .authorized)
        try await recorder.suspend()
        let resuming = Task { try await recorder.resume() }
        await location.waitForResume()
        let finished = try await recorder.finish()
        XCTAssertTrue(finished.completed)
        await location.release()
        do {
            try await resuming.value
            XCTFail("Finishing must invalidate an outstanding resume")
        } catch is CancellationError {}
        let state = await recorder.currentState()
        XCTAssertEqual(state, .idle)
    }

    func testSplitTimesInterpolateBoundariesAndUseTheZoneAtThatLocation() {
        let points = (0...20).map { point(0, Double($0) / 1000, Double($0) * 10) }
        let route = RouteRecord(workoutID: "split-zones", activity: .run, points: points, segments: [
            RouteSegment(points: Array(points.prefix(5)), zone: 1),
            RouteSegment(points: Array(points.dropFirst(5)), zone: 3)
        ])
        let splits = RouteMath.splits(route: route)
        XCTAssertEqual(splits.count, 2)
        let speed = RouteMath.distanceMeters(from: points[0], to: points[1]) / 10
        for split in splits {
            XCTAssertEqual(split.duration, 1000 / speed, accuracy: 0.001)
            XCTAssertEqual(split.zone, 3)
        }
        // One long recorded edge can cross more than one boundary.
        let sparse = RouteRecord(workoutID: "sparse", activity: .run, points: [points[0], points[20]])
        XCTAssertEqual(RouteMath.splits(route: sparse).count, 2)
    }

    func testInvalidTimeAndAltitudeAreFilteredBeforePersistence() {
        let filter = RouteFilter()
        XCTAssertFalse(filter.accepts(RoutePoint(timestamp: Date(timeIntervalSince1970: .infinity),
            latitude: 0, longitude: 0, horizontalAccuracy: 5), after: nil))
        XCTAssertFalse(filter.accepts(RoutePoint(timestamp: Date(), latitude: 0, longitude: 0,
            horizontalAccuracy: 5, altitude: .nan), after: nil))
    }

    func testFailedPointAfterGPSGapKeepsTheGapForRetry() async throws {
        let store = RetryRouteStore()
        let recorder = RouteRecorder(store: store, location: LocationFixture())
        try await recorder.start(workoutID: "retry-gap", activity: .walk, permission: .authorized)
        _ = try await recorder.append(point(0, 0, 0))
        try await recorder.suspend()
        try await recorder.resume()
        await store.failNextSave()
        do {
            _ = try await recorder.append(point(0, 0.0001, 1))
            XCTFail("The injected write failure must be reported")
        } catch RouteStoreFixtureError.writeFailed {}
        _ = try await recorder.append(point(0, 0.0002, 2))
        let route = try await recorder.finish()
        XCTAssertEqual(route.points.count, 2)
        XCTAssertEqual(route.gapStartIndices, [1])
        XCTAssertEqual(RouteMath.distanceMeters(route: route), 0)
    }

    func testPermissionEventDoesNotCancelTheParentFinalizer() async throws {
        let location = EventLocationFixture()
        let finalized = expectation(description: "Parent finalizer remains active")
        let recorder = RouteRecorder(location: location, parentFinalizer: { _ in
            XCTAssertFalse(Task.isCancelled)
            finalized.fulfill()
        })
        try await recorder.start(workoutID: "event-denial", activity: .walk, permission: .authorized)
        location.continuation.yield(.permissionRevoked)
        await fulfillment(of: [finalized], timeout: 2)
        _ = try await recorder.finish()
    }

    func testEligibilityAndPermissionGateFailClosed() async {
        let recorder = RouteRecorder()
        do {
            _ = try await recorder.start(workoutID: "w", activity: nil, permission: .authorized)
            XCTFail("ineligible route should not start")
        } catch RouteError.noActiveEligibleWorkout { }
        catch { XCTFail("Unexpected error: \(error)") }
        do {
            _ = try await recorder.start(workoutID: "w", activity: .run, permission: .denied)
            XCTFail("denied location should not start")
        } catch RouteError.permissionDenied { }
        catch { XCTFail("Unexpected error: \(error)") }
    }

    func testBadFixIsFilteredAndSuspensionPersistsBuffer() async throws {
        let recorder = RouteRecorder(location: LocationFixture())
        try await recorder.start(workoutID: "w", activity: .run, permission: .authorized)
        let firstAccepted = try await recorder.append(point(40, -73, 0))
        XCTAssertTrue(firstAccepted)
        let badFixAccepted = try await recorder.append(point(40.1, -73.1, 1, accuracy: 400))
        XCTAssertFalse(badFixAccepted)
        let secondAccepted = try await recorder.append(point(40.0001, -73.0001, 2))
        XCTAssertTrue(secondAccepted)
        try await recorder.suspend()
        let restored = try await recorder.recover(workoutID: "w")
        XCTAssertEqual(restored.points.count, 2)
        let state = await recorder.currentState()
        XCTAssertEqual(state, .suspended)
        do {
            _ = try await recorder.append(point(40.0002, -73.0002, 3))
            XCTFail("suspended location must not collect points")
        } catch RouteError.noActiveEligibleWorkout { }
        catch { XCTFail("Unexpected error: \(error)") }
    }

    func testFailedPointWriteDoesNotAdvanceTheInMemoryRoute() async throws {
        let recorder = RouteRecorder(store: FailingRouteStore(), location: LocationFixture())
        try await recorder.start(workoutID: "write-failure", activity: .run, permission: .authorized)

        do {
            _ = try await recorder.append(point(40, -73, 0))
            XCTFail("a route write failure must be reported")
        } catch RouteStoreFixtureError.writeFailed {}

        let route = await recorder.currentRoute()
        XCTAssertTrue(route?.points.isEmpty == true)
    }

    func testShareCardExcludesRouteByDefaultAndSplitDistanceIsStable() async throws {
        let recorder = RouteRecorder(filter: RouteFilter(configuration: RouteFilterConfiguration(maximumJumpMeters: 2_000)), location: LocationFixture())
        try await recorder.start(workoutID: "w", activity: .walk, permission: .authorized)
        _ = try await recorder.append(point(0, 0, 0))
        _ = try await recorder.append(point(0, 0.01, 60))
        let route = try await recorder.finish()
        let card = RouteShareCard(route: route)
        XCTAssertFalse(card.includesRoute)
        XCTAssertTrue(card.routePoints.isEmpty)
        XCTAssertFalse(RouteMath.splits(route: route).isEmpty)
        do {
            _ = try await recorder.start(workoutID: "w", activity: .walk, permission: .authorized)
            XCTFail("finished routes must never be reconstructed")
        } catch RouteError.routeAlreadyCompleted { }
        catch { XCTFail("Unexpected error: \(error)") }
    }

    func testRouteFixtureAndTypedDestinationsAreStable() {
        XCTAssertTrue(RouteFixtures.completedWalk.completed)
        XCTAssertEqual(RouteFixtures.completedWalk.activity, .walk)
        XCTAssertEqual(Set(RouteRoute.allCases).count, RouteRoute.allCases.count)
    }

    func testRoutePrimitivePreservesZoneSegmentsAndAccessibleSummary() async throws {
        let recorder = RouteRecorder(filter: RouteFilter(configuration: RouteFilterConfiguration(maximumJumpMeters: 2_000)), location: LocationFixture())
        try await recorder.start(workoutID: "zones", activity: .run, permission: .authorized)
        _ = try await recorder.append(point(0, 0, 0), zone: 2)
        _ = try await recorder.append(point(0, 0.005, 60), zone: 2)
        _ = try await recorder.append(point(0, 0.01, 120), zone: 3)
        let route = try await recorder.finish()
        let primitive = RoutePrimitiveData(route: route)
        XCTAssertEqual(route.segments.map(\.zone), [2, 3])
        XCTAssertEqual(primitive.polylines.count, 1)
        XCTAssertFalse(primitive.accessibilitySummary.isEmpty)
        let splits = RouteMath.splits(route: route, everyMeters: 500)
        XCTAssertFalse(splits.isEmpty)
        XCTAssertTrue(splits.allSatisfy { $0.zone == 2 || $0.zone == 3 })
    }

    func testGPSLossStartsNewPolylineWithoutDuplicateOrGapSpanningDistance() async throws {
        let recorder = RouteRecorder(filter: RouteFilter(configuration: RouteFilterConfiguration(maximumJumpMeters: 2_000)), location: LocationFixture())
        try await recorder.start(workoutID: "gps-loss", activity: .walk, permission: .authorized)
        _ = try await recorder.append(point(0, 0, 0))
        _ = try await recorder.append(point(0, 0.005, 60))
        let duplicateAccepted = try await recorder.append(point(0, 0.005, 60))
        XCTAssertFalse(duplicateAccepted)
        try await recorder.markGPSUnavailable()
        try await recorder.resume()
        _ = try await recorder.append(point(0, 0.006, 300))
        let route = try await recorder.finish()
        let pointIDs = Set(route.points.map { "\($0.timestamp.timeIntervalSince1970):\($0.latitude):\($0.longitude)" })
        XCTAssertEqual(route.points.count, pointIDs.count)
        XCTAssertEqual(route.gapStartIndices, [2])
        XCTAssertEqual(RouteMath.polylineSegments(route: route).count, 2)
        let primitive = RoutePrimitiveData(route: route)
        XCTAssertEqual(primitive.polylines.count, 2)
    }

    func testPermissionDenialFinalizesParentWithoutCollectingMoreLocation() async throws {
        let location = LocationFixture()
        let parent = ParentFinalizerFixture()
        let recorder = RouteRecorder(location: location, parentFinalizer: { id in await parent.finalize(id) })
        try await recorder.start(workoutID: "parent-workout", activity: .run, permission: .authorized)
        _ = try await recorder.append(point(40, -73, 0))
        try await recorder.denyPermissionAndFinalizeParent()
        let recorderState = await recorder.currentState()
        let finalizedIDs = await parent.all()
        XCTAssertEqual(recorderState, .permissionDenied)
        XCTAssertEqual(finalizedIDs, ["parent-workout"])
        do {
            _ = try await recorder.append(point(40, -73, 1))
            XCTFail("permission denial must stop route collection")
        } catch RouteError.noActiveEligibleWorkout { }
        let counts = await location.counts()
        XCTAssertGreaterThanOrEqual(counts.1, 1)
    }

    func testDeletingRouteRemovesOnlyRouteStoreRows() async throws {
        let store = InMemoryRouteStore()
        let recorder = RouteRecorder(store: store, location: LocationFixture())
        try await recorder.start(workoutID: "delete-only", activity: .cycle, permission: .authorized)
        _ = try await recorder.append(point(40, -73, 0))
        _ = try await recorder.finish()
        try await recorder.delete(workoutID: "delete-only")
        let deletedRoute = await store.route(workoutID: "delete-only")
        let rowCount = await store.count()
        XCTAssertNil(deletedRoute)
        XCTAssertEqual(rowCount, 0)
    }

    func testDefaultLocationGateFailsClosedUntilAppInjectsAnAdapter() async {
        let recorder = RouteRecorder()
        do {
            _ = try await recorder.start(workoutID: "no-location-adapter", activity: .walk, permission: .authorized)
            XCTFail("the default location gate must never claim that location is recording")
        } catch RouteError.locationUnavailable { }
        catch { XCTFail("Unexpected error: \(error)") }
        let state = await recorder.currentState()
        XCTAssertEqual(state, .suspended)
    }

    func testLocationInterruptionEventFailsClosedAndResumesWithGapBoundary() async throws {
        let recorder = RouteRecorder(location: LocationFixture())
        try await recorder.start(workoutID: "interrupt", activity: .run, permission: .authorized)
        _ = try await recorder.append(point(40, -73, 0))
        await recorder.handle(.interruptionBegan)
        let interruptedState = await recorder.currentState()
        XCTAssertEqual(interruptedState, .suspended)
        do {
            _ = try await recorder.append(point(40.0001, -73.0001, 1))
            XCTFail("interrupted location must not collect points")
        } catch RouteError.noActiveEligibleWorkout { }
        await recorder.handle(.interruptionEnded)
        _ = try await recorder.append(point(40.0001, -73.0001, 2))
        let route = try await recorder.finish()
        XCTAssertEqual(route.gapStartIndices, [1])
    }

    func testRouteExportDefaultsToRedactedCoordinatesAndDeleteReturnsReceipt() async throws {
        let store = InMemoryRouteStore()
        let recorder = RouteRecorder(store: store, location: LocationFixture())
        try await recorder.start(workoutID: "export-delete", activity: .walk, permission: .authorized)
        _ = try await recorder.append(point(40, -73, 0))
        _ = try await recorder.append(point(40.001, -73.001, 60))
        _ = try await recorder.finish()

        let redacted = try await recorder.export(workoutID: "export-delete")
        XCTAssertFalse(redacted.includesLocation)
        XCTAssertTrue(redacted.points.isEmpty)
        let optedIn = try await recorder.export(workoutID: "export-delete", request: RouteExportRequest(includeLocation: true))
        XCTAssertTrue(optedIn.includesLocation)
        XCTAssertEqual(optedIn.points.count, 2)
        let receipt = try await recorder.delete(workoutID: "export-delete")
        XCTAssertTrue(receipt.removed)
        let deleted = await store.route(workoutID: "export-delete")
        XCTAssertNil(deleted)
    }

    func testRouteStoreListsCanonicalRowsWithoutFixtureLookup() async throws {
        let store = InMemoryRouteStore()
        await store.save(RouteRecord(workoutID: "route-b", activity: .walk, completed: true))
        await store.save(RouteRecord(workoutID: "route-a", activity: .run, completed: true))
        let rows = await store.all()
        XCTAssertEqual(rows.map(\.workoutID), ["route-a", "route-b"])
    }

    func testRouteScreenStateMatrixAndAccessibilityFixtures() {
        XCTAssertEqual(RouteScreenStateFixtures.allStates.count, 14)
        XCTAssertTrue(RouteScreenStateFixtures.statesByScreen.values.allSatisfy { $0.count == 14 })
        XCTAssertNotEqual(RouteScreenStateFixtures.accessibilitySummary(for: .absent), RouteScreenStateFixtures.accessibilitySummary(for: .measuredZero))
        XCTAssertTrue(RouteScreenStateFixtures.accessibilityIdentifiers.allSatisfy { !$0.isEmpty })
    }
}

private actor DelayedResumeLocation: LocationStartGate {
    private var starts = 0
    private var pending: CheckedContinuation<Void, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    func start() async {
        starts += 1
        if starts > 1 {
            waiter?.resume(); waiter = nil
            await withCheckedContinuation { pending = $0 }
        }
    }
    func waitForResume() async {
        if starts < 2 { await withCheckedContinuation { waiter = $0 } }
    }
    func release() { pending?.resume(); pending = nil }
    func stop() async {}
}

private actor RetryRouteStore: RouteStore {
    private var rows: [String: RouteRecord] = [:]
    private var shouldFail = false
    func failNextSave() { shouldFail = true }
    func route(workoutID: String) -> RouteRecord? { rows[workoutID] }
    func all() -> [RouteRecord] { Array(rows.values) }
    func save(_ route: RouteRecord) throws {
        if shouldFail { shouldFail = false; throw RouteStoreFixtureError.writeFailed }
        rows[route.workoutID] = route
    }
    func delete(workoutID: String) { rows.removeValue(forKey: workoutID) }
    func count() -> Int { rows.count }
    func deleteAll() { rows.removeAll() }
}

private struct EventLocationFixture: LocationStartGate {
    let stream: AsyncStream<LocationGateEvent>
    let continuation: AsyncStream<LocationGateEvent>.Continuation
    init() { (stream, continuation) = AsyncStream.makeStream() }
    func start() async throws {}
    func stop() async {}
    func events() -> AsyncStream<LocationGateEvent> { stream }
}
