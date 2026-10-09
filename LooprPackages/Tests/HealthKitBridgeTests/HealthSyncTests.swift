import Foundation
import HealthKitBridge
import XCTest

private final class SyncMemoryStore: HealthSyncStore, @unchecked Sendable {
    private let lock = NSLock()
    private var preference = HealthSyncPreferences(timeZoneIdentifier: "America/New_York")
    private var partitions: [String: HealthSyncPartition] = [:]
    func preferences() throws -> HealthSyncPreferences { lock.withLock { preference } }
    func savePreferences(_ value: HealthSyncPreferences) throws { lock.withLock { preference = value } }
    func partition(_ key: String) throws -> HealthSyncPartition? { lock.withLock { partitions[key] } }
    func savePartition(_ value: HealthSyncPartition, key: String) throws { lock.withLock { partitions[key] = value } }
    func partitionKeys() throws -> [String] { lock.withLock { Array(partitions.keys) } }
}

private enum SyncFailure: Error { case interrupted }

private actor SyncClientSpy: HealthSyncClient {
    var authorization: [ExportMetricKind: HealthAuthorizationState] = [:]
    var saved: [(HealthSyncSample, Int)] = []
    var removed: [String] = []
    var failOnce: Set<String> = []
    var afterSave: (@Sendable () throws -> Void)?
    func writeAuthorization(for metric: ExportMetricKind) async -> HealthAuthorizationState { authorization[metric] ?? .notDetermined }
    func requestWriteAuthorization(for metrics: Set<ExportMetricKind>) async throws {}
    func save(_ sample: HealthSyncSample, version: Int) async throws {
        if failOnce.remove(sample.identifier) != nil { throw SyncFailure.interrupted }
        saved.append((sample, version))
        try afterSave?()
    }
    func remove(metric: ExportMetricKind, identifiers: [String]) async throws { removed += identifiers }
    func setAuthorization(_ value: HealthAuthorizationState, metric: ExportMetricKind = .heartRate) { authorization[metric] = value }
    func fail(_ id: String) { failOnce.insert(id) }
    func onSave(_ action: @escaping @Sendable () throws -> Void) { afterSave = action }
    func writes() -> [(HealthSyncSample, Int)] { saved }
    func deletions() -> [String] { removed }
}

final class HealthSyncTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_788_739_200)
    private func sample(_ id: String, value: Double = 65, metric: ExportMetricKind = .heartRate) -> HealthSyncSample {
        HealthSyncSample(identifier: id, metric: metric, value: value, start: now.addingTimeInterval(-60), end: now,
            provenance: "Measured", algorithm: "test.1", timeZone: "UTC")
    }

    func testLegacyPreferencesDecodeWithAllCategoriesOn() throws {
        let data = Data(#"{"enabled":true,"timeZoneIdentifier":"UTC"}"#.utf8)
        let preferences = try JSONDecoder().decode(HealthSyncPreferences.self, from: data)
        XCTAssertTrue(preferences.disabledRead.isEmpty)
        XCTAssertTrue(preferences.disabledWrite.isEmpty)
        XCTAssertTrue(preferences.sleepReadEnabled)
    }

    func testDisabledWriteCategoryNeverSavesIncludingMidBatch() async throws {
        let store = SyncMemoryStore(), client = SyncClientSpy()
        await client.setAuthorization(.authorized)
        var preferences = try store.preferences()
        preferences.disabledWrite = [.heartRate]
        try store.savePreferences(preferences)
        let engine = HealthSyncEngine(store: store, client: client)
        _ = try await engine.synchronize(key: "hr", metric: .heartRate, samples: [sample("one")], now: now)
        let disabledWrites = await client.writes()
        XCTAssertTrue(disabledWrites.isEmpty)
        XCTAssertNil(try store.partition("hr"))

        preferences.disabledWrite = []
        try store.savePreferences(preferences)
        await client.onSave {
            var value = try store.preferences()
            value.disabledWrite.insert(.heartRate)
            try store.savePreferences(value)
        }
        _ = try await engine.synchronize(key: "hr", metric: .heartRate,
                                         samples: [sample("one"), sample("two")], now: now)
        let midBatchWrites = await client.writes()
        XCTAssertEqual(midBatchWrites.map { $0.0.identifier }, ["one"])
    }

    func testDefaultOnStillRequiresPermissionAndPartialGrantsWork() async throws {
        let store = SyncMemoryStore(), client = SyncClientSpy()
        let engine = HealthSyncEngine(store: store, client: client)
        XCTAssertTrue(try store.preferences().enabled)
        _ = try await engine.synchronize(key: "hr", metric: .heartRate, samples: [sample("one")], now: now)
        let before = await client.writes()
        XCTAssertTrue(before.isEmpty)
        XCTAssertEqual(try store.partition("hr")?.pendingCount, 1)
        await client.setAuthorization(.authorized)
        await client.setAuthorization(.denied, metric: .steps)
        _ = try await engine.synchronize(key: "hr", metric: .heartRate, samples: [sample("one")], now: now)
        _ = try await engine.synchronize(key: "steps", metric: .steps, samples: [sample("steps", metric: .steps)], now: now)
        let writes = await client.writes()
        XCTAssertEqual(writes.map { $0.0.identifier }, ["one"])
        XCTAssertEqual(try store.partition("steps")?.pendingCount, 1)
    }

    func testOptOutSurvivesEngineRecreationAndStopsInFlightBatch() async throws {
        let store = SyncMemoryStore(), client = SyncClientSpy()
        await client.setAuthorization(.authorized)
        await client.onSave {
            var preferences = try store.preferences()
            preferences.enabled = false
            try store.savePreferences(preferences)
        }
        let engine = HealthSyncEngine(store: store, client: client)
        _ = try await engine.synchronize(key: "day", metric: .heartRate, samples: [sample("one"), sample("two")], now: now)
        let recreated = HealthSyncEngine(store: store, client: client)
        _ = try await recreated.synchronize(key: "day", metric: .heartRate, samples: [sample("one"), sample("two")], now: now)
        let writes = await client.writes()
        let removals = await client.deletions()
        XCTAssertEqual(writes.count, 1)
        XCTAssertTrue(removals.isEmpty)
        XCTAssertEqual(try store.partition("day")?.pendingCount, 1)
    }

    func testFailedSampleRetriesWithSameVersionAndSuccessfulSamplesDoNotRepeat() async throws {
        let store = SyncMemoryStore(), client = SyncClientSpy()
        await client.setAuthorization(.authorized)
        await client.fail("two")
        let samples = [sample("one"), sample("two")]
        let engine = HealthSyncEngine(store: store, client: client)
        _ = try await engine.synchronize(key: "day", metric: .heartRate, samples: samples, now: now)
        let firstVersion = try XCTUnwrap(store.partition("day")?.version)
        XCTAssertEqual(try store.partition("day")?.pendingCount, 1)
        let recreated = HealthSyncEngine(store: store, client: client)
        _ = try await recreated.synchronize(key: "day", metric: .heartRate, samples: samples, now: now.addingTimeInterval(60))
        _ = try await recreated.synchronize(key: "day", metric: .heartRate, samples: samples, now: now.addingTimeInterval(120))
        let writes = await client.writes()
        XCTAssertEqual(writes.map { $0.0.identifier }, ["one", "two"])
        XCTAssertEqual(writes.map { $0.1 }, [firstVersion, firstVersion])
        XCTAssertEqual(try store.partition("day")?.pendingCount, 0)
    }

    func testCorrectionReplacesStableIdentityAndRemovesOnlyObsoleteIntervals() async throws {
        let store = SyncMemoryStore(), client = SyncClientSpy()
        await client.setAuthorization(.authorized)
        let engine = HealthSyncEngine(store: store, client: client)
        _ = try await engine.synchronize(key: "day", metric: .heartRate, samples: [sample("one"), sample("two")], now: now)
        let old = try XCTUnwrap(store.partition("day")?.version)
        await client.fail("one")
        _ = try await engine.synchronize(key: "day", metric: .heartRate, samples: [sample("one", value: 70)], now: now)
        let beforeRetry = await client.deletions()
        XCTAssertTrue(beforeRetry.isEmpty)
        _ = try await engine.synchronize(key: "day", metric: .heartRate, samples: [sample("one", value: 70)], now: now)
        let writes = await client.writes()
        let removals = await client.deletions()
        XCTAssertEqual(writes.last?.0.identifier, "one")
        XCTAssertEqual(writes.last?.0.value, 70)
        XCTAssertGreaterThan(writes.last?.1 ?? 0, old)
        XCTAssertEqual(removals, ["two"])
    }

    func testRevocationPreservesPendingAndEmptyHistoryDoesNotClaimASave() async throws {
        let store = SyncMemoryStore(), client = SyncClientSpy()
        let engine = HealthSyncEngine(store: store, client: client)
        _ = try await engine.synchronize(key: "empty", metric: .heartRate, samples: [], now: now)
        XCTAssertNil(try store.partition("empty"))
        await client.setAuthorization(.denied)
        _ = try await engine.synchronize(key: "day", metric: .heartRate, samples: [sample("one")], now: now)
        XCTAssertNil(try store.partition("day")?.completedAt)
        await client.setAuthorization(.authorized)
        _ = try await engine.synchronize(key: "day", metric: .heartRate, samples: [sample("one")], now: now)
        XCTAssertNotNil(try store.partition("day")?.completedAt)
        await engine.stop()
        _ = try await engine.synchronize(key: "new", metric: .heartRate, samples: [sample("two")], now: now)
        XCTAssertNil(try store.partition("new"))
    }

    func testNewMinuteDoesNotRewriteEarlierMinutes() async throws {
        let store = SyncMemoryStore(), client = SyncClientSpy()
        await client.setAuthorization(.authorized)
        let engine = HealthSyncEngine(store: store, client: client)
        _ = try await engine.synchronize(key: "day", metric: .heartRate, samples: [sample("one")], now: now)
        _ = try await engine.synchronize(key: "day", metric: .heartRate, samples: [sample("one"), sample("two")], now: now.addingTimeInterval(60))
        let writes = await client.writes()
        XCTAssertEqual(writes.map { $0.0.identifier }, ["one", "two"])
    }

    func testAmbiguousSaveFailureRetriesTheSameSyncIdentityAndVersion() async throws {
        let store = SyncMemoryStore(), client = SyncClientSpy()
        await client.setAuthorization(.authorized)
        await client.onSave { throw SyncFailure.interrupted }
        let engine = HealthSyncEngine(store: store, client: client)
        _ = try await engine.synchronize(key: "day", metric: .heartRate, samples: [sample("one")], now: now)
        await client.onSave {}
        _ = try await engine.synchronize(key: "day", metric: .heartRate, samples: [sample("one")], now: now.addingTimeInterval(60))
        let writes = await client.writes()
        XCTAssertEqual(writes.count, 2)
        XCTAssertEqual(writes.first?.0, writes.last?.0)
        XCTAssertEqual(writes.first?.1, writes.last?.1)
        XCTAssertEqual(try store.partition("day")?.pendingCount, 0)
    }
}
