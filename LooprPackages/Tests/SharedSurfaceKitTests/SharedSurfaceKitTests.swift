import Foundation
import SharedSurfaceKit
import XCTest

private func snapshot(version: Int = 1, generation: UInt64 = 1) -> SurfaceSnapshot {
    .init(schemaVersion: version, generation: generation, createdAt: Date(timeIntervalSince1970: 1),
          sourceDay: "2026-08-23", syncDate: nil, metrics: .init(recovery: nil, sleep: 80),
          battery: nil, activeWorkout: nil, staleReasons: [.disconnected])
}

final class SurfaceSnapshotCompatibilityTests: XCTestCase {
    func testBatteryWidgetReportsChargingAndOlderSnapshotsKeepItUnknown() throws {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let value = SurfaceSnapshot(generation: 1, createdAt: now, sourceDay: "2025-06-15", syncDate: now, metrics: .init(),
            battery: .init(level: 0.72, observedAt: now, charging: true), activeWorkout: nil, staleReasons: [])
        XCTAssertEqual(SurfaceWidgetProjection.battery(snapshot: value, now: now).secondaryText, "Charging")
        let old = try JSONDecoder().decode(SurfaceBatteryObservation.self,
            from: Data("{\"level\":0.72,\"observedAt\":0}".utf8))
        XCTAssertNil(old.charging)
    }

    func testFutureVersionFailsTypedAndNeverPartiallyDecodes() throws {
        let data = try JSONEncoder().encode(snapshot(version: 99))
        XCTAssertThrowsError(try SurfaceSnapshotCodec.decode(data)) {
            XCTAssertEqual($0 as? SurfaceSnapshotError, .unsupportedVersion(99))
        }
    }

    func testPublishedFixtureSetHasCurrentAndFailClosedFutureSnapshot() throws {
        let currentURL = try XCTUnwrap(Bundle.module.url(forResource: "current", withExtension: "json", subdirectory: "Fixtures"))
        let futureURL = try XCTUnwrap(Bundle.module.url(forResource: "future", withExtension: "json", subdirectory: "Fixtures"))
        let current = try SurfaceSnapshotCodec.decode(Data(contentsOf: currentURL))
        XCTAssertEqual(current.generation, 42)
        XCTAssertThrowsError(try SurfaceSnapshotCodec.decode(Data(contentsOf: futureURL))) {
            XCTAssertEqual($0 as? SurfaceSnapshotError, .unsupportedVersion(99))
        }
    }
}

final class SurfaceSnapshotStalenessTests: XCTestCase {
    func testReasonsAreDistinctAndMetricsStayOptional() {
        XCTAssertEqual(Set(SurfaceStaleReason.allCases), [.noRecentSync, .disconnected, .permissionRevoked])
        XCTAssertNil(snapshot().metrics.recovery)
    }
}

final class SurfaceSnapshotNoCredentialTests: XCTestCase {
    func testCredentialShapedContentFailsClosed() {
        XCTAssertThrowsError(try SurfaceSnapshotCodec.validateNoCredentials(Data("{\"access_token\":\"x\"}".utf8)))
    }
}

final class SurfaceSnapshotAtomicWriteTests: XCTestCase {
    func testConcurrentReadsObserveWholeSnapshots() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AtomicSurfaceSnapshotStore(url: directory.appending(path: "surface.json"))
        try await store.write(snapshot())
        for generation in 2...25 {
            try await store.write(snapshot(generation: UInt64(generation)))
            let observed = try await store.read().generation
            XCTAssertEqual(observed, UInt64(generation))
        }
    }
}

final class TodayWidgetTimelineTests: XCTestCase {
    func testCurrentAbsentAndStaleSnapshotsProjectWithoutPrivateDependencies() {
        let now = Date(timeIntervalSince1970: 10)
        let current = SurfaceWidgetProjection.today(snapshot: snapshot(), now: now)
        XCTAssertEqual(current.generation, 1)
        XCTAssertTrue(current.isStale)
        XCTAssertEqual(current.secondaryText, "Open Loopr to sync")

        let absent = SurfaceWidgetProjection.today(snapshot: nil, now: now)
        XCTAssertTrue(absent.isPlaceholder)
        XCTAssertEqual(absent.primaryText, "Open Loopr to sync")
    }
}

final class BatteryWidgetTests: XCTestCase {
    func testPresentAbsentAndStaleBatteryObservations() {
        let now = Date(timeIntervalSince1970: 10)
        let present = SurfaceSnapshot(
            generation: 2, createdAt: now, sourceDay: "2026-08-23", syncDate: now,
            metrics: .init(), battery: .init(level: 0.72, observedAt: now),
            activeWorkout: nil, staleReasons: []
        )
        XCTAssertEqual(SurfaceWidgetProjection.battery(snapshot: present, now: now).primaryText, "72%")
        XCTAssertEqual(SurfaceWidgetProjection.battery(snapshot: snapshot(), now: now).primaryText,
                       "Battery unavailable")
        XCTAssertTrue(SurfaceWidgetProjection.battery(snapshot: snapshot(), now: now).isStale)
    }
}

final class WidgetPrivacyTests: XCTestCase {
    func testLockScreenRedactsHealthValuesAndStillShowsStaleness() {
        let value = SurfaceSnapshot(
            generation: 3, createdAt: Date(), sourceDay: "2026-08-23", syncDate: nil,
            metrics: .init(recovery: 99), battery: .init(level: 0.42, observedAt: Date()),
            activeWorkout: nil, staleReasons: [.permissionRevoked]
        )
        let today = SurfaceWidgetProjection.today(snapshot: value, now: Date(), privacy: .lockScreen)
        let battery = SurfaceWidgetProjection.battery(snapshot: value, now: Date(), privacy: .lockScreen)
        XCTAssertFalse(today.primaryText.contains("99"))
        XCTAssertFalse(battery.primaryText.contains("42"))
        XCTAssertEqual(today.secondaryText, "Permission needed")
    }
}

private actor ActivityDriverSpy: SurfaceActivityDriver {
    var events: [String] = []
    var active: Set<UUID> = []
    func start(_ state: SurfaceActivityState) { events.append("start:\(state.kind.rawValue)"); active.insert(state.sessionID) }
    func update(_ state: SurfaceActivityState) { events.append("update:\(state.kind.rawValue)"); active.insert(state.sessionID) }
    func end(sessionID: UUID, finalState: SurfaceActivityState?) { events.append("end:\(finalState?.kind.rawValue ?? "orphan")"); active.remove(sessionID) }
    func activeSessionIDs() -> Set<UUID> { active }
    func setActive(_ ids: Set<UUID>) { active = ids }
    func recordedEvents() -> [String] { events }
}

final class LiveActivityLifecycleTests: XCTestCase {
    func testWorkoutAndBreathingStartUpdateEndExactlyOnce() async throws {
        for kind in [SurfaceActivityKind.workout, .breathing] {
            let driver = ActivityDriverSpy(); let coordinator = SurfaceActivityCoordinator(driver: driver)
            let id = UUID(); let started = Date(timeIntervalSince1970: 1)
            let initial = SurfaceActivityState(sessionID: id, kind: kind, startedAt: started, progress: 0, status: "active")
            let updated = SurfaceActivityState(sessionID: id, kind: kind, startedAt: started, progress: 0.5, status: "active")
            try await coordinator.start(initial); try await coordinator.start(initial)
            try await coordinator.update(updated)
            try await coordinator.end(sessionID: id, finalState: updated)
            try await coordinator.end(sessionID: id, finalState: updated)
            let events = await driver.recordedEvents()
            XCTAssertEqual(events, ["start:\(kind.rawValue)", "update:\(kind.rawValue)", "end:\(kind.rawValue)"])
        }
    }
}

final class LiveActivityRecoveryTests: XCTestCase {
    func testRecoveryReattachesCanonicalAndEndsOrphan() async throws {
        let driver = ActivityDriverSpy(); let coordinator = SurfaceActivityCoordinator(driver: driver)
        let canonicalID = UUID(); let orphanID = UUID()
        await driver.setActive([canonicalID, orphanID])
        let canonical = SurfaceActivityState(sessionID: canonicalID, kind: .workout,
                                             startedAt: Date(), progress: 0.4, status: "active")
        try await coordinator.recover(canonicalSessions: [canonical])
        let events = await driver.recordedEvents()
        XCTAssertEqual(Set(events), ["end:orphan", "update:workout"])
    }
}

final class AppIntentIdempotenceTests: XCTestCase {
    func testOpenBreathingRepeatsSafely() async throws {
        let executor = SurfaceIntentExecutor()
        _ = try await executor.perform(.openBreathing, snapshot: nil, healthAuthorized: false)
        _ = try await executor.perform(.openBreathing, snapshot: nil, healthAuthorized: false)
        let count = await executor.openedRouteCount()
        XCTAssertEqual(count, 1)
    }
}

final class AppIntentAuthorizationTests: XCTestCase {
    func testDeniedHealthAuthorizationProducesTypedError() async {
        let executor = SurfaceIntentExecutor()
        do {
            _ = try await executor.perform(.readRecovery, snapshot: snapshot(), healthAuthorized: false)
            XCTFail("expected authorization failure")
        } catch {
            XCTAssertEqual(error as? SurfaceIntentError, .authorizationDenied)
        }
    }

    func testNavigationProducesTypedRoute() async throws {
        let executor = SurfaceIntentExecutor()
        let result = try await executor.perform(.navigate(.heart), snapshot: nil, healthAuthorized: false)
        XCTAssertEqual(result.route, .heart)
    }
}

final class WatchSnapshotCompatibilityTests: XCTestCase {
    func testWatchUsesSameVersionedCodecAsWidgets() throws {
        let decoded = try SurfaceSnapshotCodec.decode(JSONEncoder().encode(snapshot()))
        XCTAssertEqual(WatchSurfaceProjector.project(decoded).sleep, "—")
        XCTAssertEqual(decoded.metrics.sleep, 80)
        XCTAssertThrowsError(try SurfaceSnapshotCodec.decode(JSONEncoder().encode(snapshot(version: 99))))
    }

    func testWatchApplicationContextRevocationOverridesAnOlderPayload() throws {
        let data = try JSONEncoder().encode(snapshot())
        let published = WatchSurfaceApplicationContext.publishing(data)
        XCTAssertEqual(WatchSurfaceApplicationContext.payload(in: published), data)
        XCTAssertFalse(WatchSurfaceApplicationContext.isRevoked(published))
        XCTAssertTrue(WatchSurfaceApplicationContext.replacesCachedPayload(published))

        let revoked = WatchSurfaceApplicationContext.revoking
        XCTAssertTrue(WatchSurfaceApplicationContext.isRevoked(revoked))
        XCTAssertNil(WatchSurfaceApplicationContext.payload(in: revoked))
        XCTAssertNil(revoked[WatchSurfaceApplicationContext.payloadKey])
        XCTAssertTrue(WatchSurfaceApplicationContext.replacesCachedPayload(revoked))
        XCTAssertFalse(WatchSurfaceApplicationContext.replacesCachedPayload([:]))
    }
}

final class WatchComplicationTests: XCTestCase {
    func testCircularAndRectangularFamiliesRenderStaleState() {
        for family in WatchComplicationFamily.allCases {
            let entry = WatchSurfaceProjector.complication(family, snapshot: snapshot())
            XCTAssertTrue(entry.isStale)
            XCTAssertEqual(entry.secondaryText, "Open Loopr to sync")
        }
    }
}
