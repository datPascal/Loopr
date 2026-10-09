import AnalyticsKit
import XCTest

private actor CountingDerivationPipeline: AnalyticsDerivationPipeline {
    private(set) var calls = 0
    private let delayNanoseconds: UInt64

    init(delayNanoseconds: UInt64 = 0) { self.delayNanoseconds = delayNanoseconds }

    func derive(day: Date, family: AnalyticsMetricFamily, inputRevision: String) async throws -> DerivationPayload {
        calls += 1
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        } else {
            await Task.yield()
        }
        try Task.checkCancellation()
        return DerivationPayload(bytes: Data(inputRevision.utf8))
    }
}

final class SchedulerCancellationTests: XCTestCase {
    func testCancellationLeavesNoPersistedOutput() async throws {
        let pipeline = CountingDerivationPipeline(delayNanoseconds: 2_000_000_000)
        let store = InMemoryDerivationStore()
        let scheduler = DerivationScheduler(pipeline: pipeline, store: store)
        let day = Date(timeIntervalSince1970: 2_000_000_000)
        let task = Task { try await scheduler.request(day: day, family: .sleep) }
        try await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("cancelled work must not publish")
        } catch is CancellationError {
            XCTAssertTrue(true)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        let generations = await store.allGenerations()
        XCTAssertTrue(generations.isEmpty)
    }
}

final class SchedulerCoalescingTests: XCTestCase {
    func testConcurrentIdenticalRequestsRunOnce() async throws {
        let pipeline = CountingDerivationPipeline(delayNanoseconds: 30_000_000)
        let store = InMemoryDerivationStore()
        let scheduler = DerivationScheduler(pipeline: pipeline, store: store)
        let day = Date(timeIntervalSince1970: 2_000_000_000)
        let results = try await withThrowingTaskGroup(of: PersistedDerivationGeneration.self, returning: [PersistedDerivationGeneration].self) { group in
            for _ in 0..<8 {
                group.addTask { try await scheduler.request(day: day, family: .activity) }
            }
            var values: [PersistedDerivationGeneration] = []
            for try await value in group { values.append(value) }
            return values
        }
        XCTAssertEqual(results.count, 8)
        XCTAssertEqual(Set(results.map(\.generationID)).count, 1)
        let calls = await pipeline.calls
        let generations = await store.allGenerations()
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(generations.count, 1)
    }
}

final class GenerationVersioningTests: XCTestCase {
    func testHistoricalGenerationRemainsReadableAndCurrentUsesLatestVersion() async throws {
        let pipeline = CountingDerivationPipeline()
        let store = InMemoryDerivationStore()
        let scheduler = DerivationScheduler(pipeline: pipeline, store: store, algorithmVersion: 1)
        let day = Date(timeIntervalSince1970: 2_000_000_000)
        _ = try await scheduler.request(day: day, family: .heart, algorithmVersion: 1)
        _ = try await scheduler.request(day: day, family: .heart, algorithmVersion: 2)
        let history = try await scheduler.historicalGenerations(day: day, family: .heart)
        let current = try await scheduler.currentProjection(day: day, family: .heart, algorithmVersion: 2)
        XCTAssertEqual(history.count, 2)
        XCTAssertEqual(current?.algorithmVersion, 2)
    }

    func testCurrentProjectionFiltersByInputRevisionWhileHistoryKeepsBoth() async throws {
        let pipeline = CountingDerivationPipeline()
        let store = InMemoryDerivationStore()
        let scheduler = DerivationScheduler(pipeline: pipeline, store: store, algorithmVersion: 1)
        let day = Date(timeIntervalSince1970: 2_000_000_000)
        _ = try await scheduler.request(day: day, family: .hrv, inputRevision: "raw-a", algorithmVersion: 1)
        _ = try await scheduler.request(day: day, family: .hrv, inputRevision: "raw-b", algorithmVersion: 1)

        let history = try await scheduler.historicalGenerations(day: day, family: .hrv)
        let currentA = try await scheduler.currentProjection(day: day, family: .hrv, algorithmVersion: 1, inputRevision: "raw-a")
        let currentB = try await scheduler.currentProjection(day: day, family: .hrv, algorithmVersion: 1, inputRevision: "raw-b")
        XCTAssertEqual(history.count, 2)
        XCTAssertEqual(currentA?.inputRevision, "raw-a")
        XCTAssertEqual(currentB?.inputRevision, "raw-b")
    }
}

final class PruningBarrierTests: XCTestCase {
    func testOnlyCompleteDurableVersionedPastEdgeIsPrunable() async throws {
        let pipeline = CountingDerivationPipeline()
        let store = InMemoryDerivationStore()
        let scheduler = DerivationScheduler(pipeline: pipeline, store: store, stateProvider: store, timeZone: TimeZone(secondsFromGMT: 0)!)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let oldDay = now.addingTimeInterval(-5 * 86_400)
        await store.setState(.complete(day: oldDay))
        let oldDayPrunable = await scheduler.isDayPrunable(day: oldDay, now: now)
        XCTAssertTrue(oldDayPrunable)

        await store.setState(DerivationDayState(day: oldDay, isCurrentDay: false, isComplete: false, isDurable: true, isVersioned: true))
        let partialPrunable = await scheduler.isDayPrunable(day: oldDay, now: now)
        XCTAssertFalse(partialPrunable)
        await store.setState(DerivationDayState(day: oldDay, isCurrentDay: false, isComplete: true, isDurable: true, isVersioned: true, isDecodable: false))
        let undecodablePrunable = await scheduler.isDayPrunable(day: oldDay, now: now)
        XCTAssertFalse(undecodablePrunable)

        await store.setState(DerivationDayState(day: oldDay, isCurrentDay: true, isComplete: true, isDurable: true, isVersioned: true))
        let currentPrunable = await scheduler.isDayPrunable(day: oldDay, now: now)
        XCTAssertFalse(currentPrunable)

        await store.setState(DerivationDayState(day: oldDay, isCurrentDay: false, isComplete: true, isDurable: true, isVersioned: false))
        let unversionedPrunable = await scheduler.isDayPrunable(day: oldDay, now: now)
        XCTAssertFalse(unversionedPrunable)

        await store.setState(DerivationDayState(day: oldDay, isCurrentDay: false, isComplete: true, isDurable: true, isVersioned: true, hasFailed: true))
        let failedPrunable = await scheduler.isDayPrunable(day: oldDay, now: now)
        XCTAssertFalse(failedPrunable)
    }
}

final class SchedulerFullRegressionTests: XCTestCase {
    func testRepeatedRequestIsIdempotent() async throws {
        let pipeline = CountingDerivationPipeline()
        let store = InMemoryDerivationStore()
        let scheduler = DerivationScheduler(pipeline: pipeline, store: store)
        let day = Date(timeIntervalSince1970: 2_000_000_000)
        let first = try await scheduler.request(day: day, family: .age)
        let second = try await scheduler.request(day: day, family: .age)
        XCTAssertEqual(first, second)
        let calls = await pipeline.calls
        let generations = await store.allGenerations()
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(generations.count, 1)
    }

    func testFullTwoPassFixtureFamilySetLeavesIdenticalGenerationState() async throws {
        let pipeline = CountingDerivationPipeline()
        let store = InMemoryDerivationStore()
        let scheduler = DerivationScheduler(pipeline: pipeline, store: store, algorithmVersion: 7)
        let day = Date(timeIntervalSince1970: 2_000_000_000)
        // The seven pruning families are the complete ANA-02…ANA-07A set:
        // heart/HRV, sleep, recovery, activity, workout, and age. The
        // counting pipeline is deliberate: this regression must exercise one
        // scheduler generation per family, not the empty placeholder pipeline.
        let families = AnalyticsMetricFamily.pruningFamilies.sorted { $0.rawValue < $1.rawValue }

        var firstPass: [PersistedDerivationGeneration] = []
        for family in families {
            firstPass.append(try await scheduler.request(day: day, family: family, inputRevision: "fixture-ana02-07a"))
        }
        let stateAfterFirstPass = await store.allGenerations()

        var secondPass: [PersistedDerivationGeneration] = []
        for family in families {
            secondPass.append(try await scheduler.request(day: day, family: family, inputRevision: "fixture-ana02-07a"))
        }
        let stateAfterSecondPass = await store.allGenerations()

        XCTAssertEqual(firstPass, secondPass)
        XCTAssertEqual(stateAfterSecondPass, stateAfterFirstPass)
        XCTAssertEqual(stateAfterSecondPass.count, families.count)
        let calls = await pipeline.calls
        XCTAssertEqual(calls, families.count)
    }
}
