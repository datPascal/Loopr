import StressKit
import BluetoothKit
import XCTest

private actor LiveConsumerFixture: LiveConsumer {
    private(set) var acquired: [UUID] = []
    private(set) var released: [UUID] = []
    func acquire(generation: UUID) async throws -> AsyncStream<LiveCardiacSample> {
        acquired.append(generation)
        return AsyncStream { $0.finish() }
    }
    func release(generation: UUID) async { released.append(generation) }
    func releaseCount() -> Int { released.count }
    func acquisitionCount() -> Int { acquired.count }
}

private actor BreathingHookFixture: BreathingActivityHook {
    private(set) var starts = 0
    private(set) var updates = 0
    private(set) var interruptions = 0
    private(set) var ends = 0
    func started(sessionID: UUID, cadence: Double) async { starts += 1 }
    func updated(sessionID: UUID, sample: LiveCardiacSample) async { updates += 1 }
    func interrupted(sessionID: UUID) async { interruptions += 1 }
    func ended(sessionID: UUID, result: BreathingResult?) async { ends += 1 }
    func counts() -> (starts: Int, updates: Int, interruptions: Int, ends: Int) {
        (starts, updates, interruptions, ends)
    }
}

private struct SpotCheckFixture: SpotCheckMechanism {
    let result: SpotCheckResult
    func measure(duration: Duration, generation: UUID) async throws -> SpotCheckResult { result }
}

final class StressKitTests: XCTestCase {
    func testQualityGateKeepsAbsentAndZeroDistinct() {
        XCTAssertNil(StressDetail(observation: nil).value)
        XCTAssertNil(StressDetail(observation: StressObservation(day: "2026-08-18", value: 0, coverage: 0.4, confidence: 0.9)).value)
        let qualified = StressDetail(observation: StressObservation(day: "2026-08-18", value: 0, coverage: 0.9, confidence: 0.8))
        XCTAssertEqual(qualified.value, 0)
    }

    func testTypedLiveEventMapperBuildsCardiacSampleWithoutAnalyticsGuessing() {
        let event = LiveStreamEvent(
            kind: .compactHeartRateRR,
            generation: 33,
            payload: strippedCompactPayload(timestamp: 1_780_840_486, heartRate: 62, rr: [800, 810, 820, 830]),
            receivedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let sample = StressLiveEventMapper.decode(event)

        XCTAssertEqual(sample?.timestamp, Date(timeIntervalSince1970: 1_780_840_486))
        XCTAssertEqual(sample?.heartRate, 62)
        XCTAssertEqual(sample?.rrMilliseconds, [800, 810, 820, 830])
    }

    func testTypedLiveEventMapperFailsClosedForOffWristAndMalformedFrames() {
        let offWrist = LiveStreamEvent(
            kind: .compactHeartRateRR,
            generation: 33,
            payload: strippedCompactPayload(timestamp: 100, heartRate: 62, rr: [800], wearing: 0),
            receivedAt: Date()
        )
        let malformed = LiveStreamEvent(
            kind: .compactHeartRateRR,
            generation: 33,
            payload: Data([0x01, 0x02]),
            receivedAt: Date()
        )

        XCTAssertNil(StressLiveEventMapper.decode(offWrist))
        XCTAssertNil(StressLiveEventMapper.decode(malformed))
    }

    func testBreathingAcquiresReleasesAndRejectsStaleGeneration() async throws {
        let consumer = LiveConsumerFixture()
        let hook = BreathingHookFixture()
        let controller = BreathingSessionController(consumer: consumer, hook: hook)
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000020")!
        _ = try await controller.start(cadence: 6, now: Date(timeIntervalSince1970: 10), id: id)
        let generation = await controller.currentGeneration()!
        try await controller.append(LiveCardiacSample(timestamp: Date(timeIntervalSince1970: 11), heartRate: 60), generation: generation)
        try await controller.pause()
        try await controller.resume()
        do {
            try await controller.append(LiveCardiacSample(timestamp: Date(), heartRate: 61), generation: UUID())
            XCTFail("old live stream generations must be rejected")
        } catch StressError.staleGeneration { }
        let result = try await controller.finish(now: Date(timeIntervalSince1970: 20))
        XCTAssertEqual(result.samples, 1)
        XCTAssertEqual(result.averageHeartRate, 60.0)
        let state = await controller.currentState()
        let releases = await consumer.releaseCount()
        let counts = await hook.counts()
        XCTAssertEqual(state, .completed)
        XCTAssertEqual(releases, 1)
        XCTAssertEqual(counts.0, 1)
        XCTAssertEqual(counts.1, 1)
        XCTAssertEqual(counts.interruptions, 0)
        XCTAssertEqual(counts.ends, 1)
    }

    func testBreathingActivityHookTracksInterruptionResumeAndInvalidation() async throws {
        let consumer = LiveConsumerFixture()
        let hook = BreathingHookFixture()
        let controller = BreathingSessionController(consumer: consumer, hook: hook)
        _ = try await controller.start(id: UUID(uuidString: "00000000-0000-0000-0000-000000000023")!)

        try await controller.interrupt()
        var counts = await hook.counts()
        XCTAssertEqual(counts.starts, 1)
        XCTAssertEqual(counts.interruptions, 1)
        XCTAssertEqual(counts.ends, 0)

        try await controller.resume()
        counts = await hook.counts()
        XCTAssertEqual(counts.starts, 2)

        await controller.invalidateGeneration()
        counts = await hook.counts()
        XCTAssertEqual(counts.ends, 1)
    }

    func testSpotCheckUsesSharedMechanismAndUnavailableFailsClosed() async throws {
        let expected = SpotCheckResult(startedAt: Date(timeIntervalSince1970: 1), endedAt: Date(timeIntervalSince1970: 61), rmssd: 42, heartRate: 62, quality: 0.9)
        let history = SpotCheckHistory()
        let controller = SpotCheckController(mechanism: SpotCheckFixture(result: expected), history: history)
        let actual = try await controller.run()
        XCTAssertEqual(actual, expected)
        let historyRows = await history.all()
        XCTAssertEqual(historyRows, [expected])
        do {
            _ = try await SpotCheckController(mechanism: UnavailableSpotCheckMechanism()).run()
            XCTFail("unavailable hardware must not fabricate a result")
        } catch StressError.liveUnavailable { }
    }

    func testStressFixturesDistinguishLowCoverageFromQualifiedSignal() {
        XCTAssertNil(StressFixtures.lowCoverage.value)
        XCTAssertEqual(StressFixtures.qualified.value, 62)
        XCTAssertTrue(StressRoute.allCases.contains(.breathing))
    }

    func testStressScreenStateMatrixAndAccessibilityFixtures() {
        XCTAssertEqual(StressScreenStateFixtures.allStates.count, 14)
        XCTAssertTrue(StressScreenStateFixtures.statesByScreen.values.allSatisfy { $0.count == 14 })
        XCTAssertNotEqual(StressScreenStateFixtures.accessibilitySummary(for: .absent), StressScreenStateFixtures.accessibilitySummary(for: .measuredZero))
        XCTAssertTrue(StressScreenStateFixtures.accessibilityIdentifiers.allSatisfy { !$0.isEmpty })
    }

    func testStressStorePersistsLatestObservationAndSpotCheckOrdering() async throws {
        let first = SpotCheckResult(id: UUID(uuidString: "00000000-0000-0000-0000-000000000301")!, startedAt: Date(timeIntervalSince1970: 20), endedAt: Date(timeIntervalSince1970: 80), rmssd: 42, heartRate: 62, quality: 0.9)
        let second = SpotCheckResult(id: UUID(uuidString: "00000000-0000-0000-0000-000000000302")!, startedAt: Date(timeIntervalSince1970: 10), endedAt: Date(timeIntervalSince1970: 70), rmssd: 40, heartRate: 60, quality: 0.8)
        let store = InMemoryStressStore(spotChecks: [first, second])
        let initialObservation = await store.latestObservation()
        XCTAssertNil(initialObservation)
        await store.saveObservation(StressObservation(day: "2026-08-17", value: 55, coverage: 0.8, confidence: 0.7))
        await store.saveObservation(StressObservation(day: "2026-08-18", value: 0, coverage: 0.9, confidence: 0.8))
        let latestObservation = await store.latestObservation()
        XCTAssertEqual(latestObservation?.day, "2026-08-18")
        let orderedResults = await store.spotChecks()
        XCTAssertEqual(orderedResults, [second, first])
        await store.deleteAll()
        let deletedObservation = await store.latestObservation()
        let deletedResults = await store.spotChecks()
        XCTAssertNil(deletedObservation)
        XCTAssertTrue(deletedResults.isEmpty)
    }

    func testStressStorePersistsBreathingHistoryAndClearsItWithDeleteAll() async throws {
        let result = BreathingResult(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000303")!,
            startedAt: Date(timeIntervalSince1970: 30),
            endedAt: Date(timeIntervalSince1970: 90),
            cadence: 6,
            samples: 4,
            averageHeartRate: 61
        )
        let store = InMemoryStressStore(breathingHistory: [result])
        let initialHistory = await store.breathingHistory()
        XCTAssertEqual(initialHistory, [result])
        await store.saveBreathingResult(BreathingResult(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000304")!,
            startedAt: Date(timeIntervalSince1970: 10),
            endedAt: Date(timeIntervalSince1970: 20),
            cadence: 5,
            samples: 0,
            averageHeartRate: nil
        ))
        let updatedHistory = await store.breathingHistory()
        XCTAssertEqual(updatedHistory.count, 2)
        await store.deleteAll()
        let deletedHistory = await store.breathingHistory()
        XCTAssertTrue(deletedHistory.isEmpty)
    }

    func testLiveActivityBoundaryIsExplicitlyUnavailableByDefault() {
        XCTAssertEqual(UnavailableStressLiveActivityBoundary().availability, .unavailable)
    }

    @MainActor
    func testStressViewModelPersistsBreathingResultThroughDurableStore() async throws {
        let store = InMemoryStressStore()
        let controller = BreathingSessionController(consumer: LiveConsumerFixture())
        let viewModel = StressViewModel(breathing: controller, store: store)
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000305")!
        try await viewModel.startBreathing(id: id)
        _ = try await viewModel.finishBreathing(now: Date(timeIntervalSince1970: 60))
        let history = await store.breathingHistory()
        XCTAssertEqual(history.map(\.id), [id])
        XCTAssertEqual(viewModel.breathingHistory.map(\.id), [id])
    }

    func testCancellationAndStaleGenerationAlwaysReleaseLiveConsumer() async throws {
        let consumer = LiveConsumerFixture()
        let controller = BreathingSessionController(consumer: consumer)
        _ = try await controller.start(id: UUID(uuidString: "00000000-0000-0000-0000-000000000121")!)
        let generation = await controller.currentGeneration()!
        await controller.invalidateGeneration()
        let staleState = await controller.currentState()
        let firstReleaseCount = await consumer.releaseCount()
        XCTAssertEqual(staleState, .staleGeneration)
        XCTAssertEqual(firstReleaseCount, 1)
        do {
            try await controller.append(LiveCardiacSample(timestamp: Date(), heartRate: 70), generation: generation)
            XCTFail("invalidated generations must be rejected")
        } catch StressError.staleGeneration { }

        _ = try await controller.start(id: UUID(uuidString: "00000000-0000-0000-0000-000000000122")!)
        try await controller.cancel()
        let secondReleaseCount = await consumer.releaseCount()
        let cancelledState = await controller.currentState()
        XCTAssertEqual(secondReleaseCount, 2)
        XCTAssertEqual(cancelledState, .cancelled)
    }

    func testUnavailableDefaultConsumerFailsClosed() async {
        let controller = BreathingSessionController()
        do {
            _ = try await controller.start(id: UUID(uuidString: "00000000-0000-0000-0000-000000000123")!)
            XCTFail("a missing live adapter must not start a breathing session")
        } catch StressError.liveUnavailable { }
        catch { XCTFail("Unexpected error: \(error)") }
        let state = await controller.currentState()
        XCTAssertEqual(state, .ready)
    }

    func testBreathingInterruptionResumesWithNewGenerationAndReleasesEachLeaseOnce() async throws {
        let consumer = LiveConsumerFixture()
        let controller = BreathingSessionController(consumer: consumer)
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000124")!
        _ = try await controller.start(id: id)
        let firstGeneration = await controller.currentGeneration()!
        try await controller.append(LiveCardiacSample(timestamp: Date(timeIntervalSince1970: 1), heartRate: 60), generation: firstGeneration)
        try await controller.interrupt()
        let interruptedState = await controller.currentState()
        let firstReleaseCount = await consumer.releaseCount()
        XCTAssertEqual(interruptedState, .interrupted)
        XCTAssertEqual(firstReleaseCount, 1)
        try await controller.resume()
        let secondGeneration = await controller.currentGeneration()!
        XCTAssertNotEqual(firstGeneration, secondGeneration)
        try await controller.append(LiveCardiacSample(timestamp: Date(timeIntervalSince1970: 2), heartRate: 62), generation: secondGeneration)
        _ = try await controller.finish(now: Date(timeIntervalSince1970: 3))
        let acquisitionCount = await consumer.acquisitionCount()
        let secondReleaseCount = await consumer.releaseCount()
        XCTAssertEqual(acquisitionCount, 2)
        XCTAssertEqual(secondReleaseCount, 2)
        await controller.invalidateGeneration()
        let postInvalidateReleaseCount = await consumer.releaseCount()
        XCTAssertEqual(postInvalidateReleaseCount, 2)
    }

    func testSpotCheckConsumerReleasesOnSuccessFailureAndExplicitInterruptOnlyOnce() async throws {
        let expected = SpotCheckResult(startedAt: Date(timeIntervalSince1970: 1), endedAt: Date(timeIntervalSince1970: 61), rmssd: 42, heartRate: 62, quality: 0.9)
        let consumer = LiveConsumerFixture()
        let controller = SpotCheckController(mechanism: SpotCheckFixture(result: expected), consumer: consumer)
        _ = try await controller.run(generation: UUID(uuidString: "00000000-0000-0000-0000-000000000125")!)
        await controller.interrupt()
        let successReleaseCount = await consumer.releaseCount()
        XCTAssertEqual(successReleaseCount, 1)

        struct FailingMechanism: SpotCheckMechanism {
            func measure(duration: Duration, generation: UUID) async throws -> SpotCheckResult { throw StressError.liveUnavailable }
        }
        let failureConsumer = LiveConsumerFixture()
        let failing = SpotCheckController(mechanism: FailingMechanism(), consumer: failureConsumer)
        do {
            _ = try await failing.run(generation: UUID(uuidString: "00000000-0000-0000-0000-000000000126")!)
            XCTFail("failed spot checks must surface the mechanism error")
        } catch StressError.liveUnavailable { }
        catch { XCTFail("Unexpected error: \(error)") }
        let failureReleaseCount = await failureConsumer.releaseCount()
        XCTAssertEqual(failureReleaseCount, 1)
        await failing.interrupt()
        let postInterruptReleaseCount = await failureConsumer.releaseCount()
        XCTAssertEqual(postInterruptReleaseCount, 1)
    }

    private func strippedCompactPayload(
        timestamp: UInt32,
        heartRate: UInt8,
        rr: [UInt16],
        wearing: UInt8 = 1
    ) -> Data {
        var bytes = Data(repeating: 0, count: 20)
        bytes[0] = 0x28
        bytes[1] = 0x01
        bytes[2] = UInt8(truncatingIfNeeded: timestamp)
        bytes[3] = UInt8(truncatingIfNeeded: timestamp >> 8)
        bytes[4] = UInt8(truncatingIfNeeded: timestamp >> 16)
        bytes[5] = UInt8(truncatingIfNeeded: timestamp >> 24)
        bytes[8] = heartRate
        bytes[9] = UInt8(truncatingIfNeeded: rr.count)
        for (index, value) in rr.prefix(4).enumerated() {
            let offset = 10 + index * 2
            bytes[offset] = UInt8(truncatingIfNeeded: value)
            bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        }
        bytes[18] = wearing
        return Data(bytes.dropFirst())
    }
}
