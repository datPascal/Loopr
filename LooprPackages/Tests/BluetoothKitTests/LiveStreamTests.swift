import BluetoothKit
import Foundation
import XCTest

private actor RecordingLiveStreamSink: LiveStreamCommandSink {
    private(set) var calls: [(LiveStreamKind, Bool)] = []
    var failNextEnable = false

    func setLiveStream(_ kind: LiveStreamKind, enabled: Bool) async throws {
        calls.append((kind, enabled))
        if enabled, failNextEnable {
            failNextEnable = false
            throw TestError.enableFailed
        }
    }

    func recordedCalls() -> [(LiveStreamKind, Bool)] { calls }

    private enum TestError: Error { case enableFailed }
}

final class LiveStreamTests: XCTestCase {
    func testLiveStreamRequiresHistorySafetyAndTogglesOnlyAtConsumerBoundaries() async throws {
        let sink = RecordingLiveStreamSink()
        let manager = LiveStreamManager(commandSink: sink, bufferCapacity: 4)

        do {
            _ = try await manager.acquire(kind: .compactHeartRateRR, consumer: .activeWorkout)
            XCTFail("live stream acquired before history safety")
        } catch LiveStreamError.historySafetyRequired {
            // Expected.
        }

        await manager.markHistorySafetyPassed()
        let first = try await manager.acquire(kind: .compactHeartRateRR, consumer: .activeWorkout)
        let second = try await manager.acquire(kind: .compactHeartRateRR, consumer: .spotCheck)
        let countAfterAcquire = await manager.consumerCount(for: .compactHeartRateRR)
        let callsAfterAcquire = await sink.recordedCalls().map { $0.1 }
        XCTAssertEqual(countAfterAcquire, 2)
        XCTAssertEqual(callsAfterAcquire, [true])

        let firstRelease = await first.release()
        let firstReleaseAgain = await first.release()
        let countAfterFirstRelease = await manager.consumerCount(for: .compactHeartRateRR)
        let callsAfterFirstRelease = await sink.recordedCalls().map { $0.1 }
        XCTAssertTrue(firstRelease)
        XCTAssertFalse(firstReleaseAgain)
        XCTAssertEqual(countAfterFirstRelease, 1)
        XCTAssertEqual(callsAfterFirstRelease, [true])

        let secondRelease = await second.release()
        let countAfterSecondRelease = await manager.consumerCount(for: .compactHeartRateRR)
        let callsAfterSecondRelease = await sink.recordedCalls().map { $0.1 }
        XCTAssertTrue(secondRelease)
        XCTAssertEqual(countAfterSecondRelease, 0)
        XCTAssertEqual(callsAfterSecondRelease, [true, false])
    }

    func testLivePacketsAreBoundedInRAMAndOldestPacketsAreEvicted() async throws {
        let manager = LiveStreamManager(bufferCapacity: 2, historySafetyPassed: true)
        let handle = try await manager.acquire(kind: .realtimeRaw, consumer: .calibration)
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        await manager.ingest(kind: .realtimeRaw, payload: Data([1]), receivedAt: base)
        await manager.ingest(kind: .realtimeRaw, payload: Data([2]), receivedAt: base.addingTimeInterval(1))
        await manager.ingest(kind: .realtimeRaw, payload: Data([3]), receivedAt: base.addingTimeInterval(2))

        let samples = await manager.bufferedSamples(for: .realtimeRaw)
        XCTAssertEqual(samples.count, 2)
        XCTAssertEqual(samples.map(\.payload), [Data([2]), Data([3])])
        let countBeforeRelease = await manager.totalConsumerCount()
        let released = await handle.release()
        let countAfterRelease = await manager.totalConsumerCount()
        XCTAssertEqual(countBeforeRelease, 1)
        XCTAssertTrue(released)
        XCTAssertEqual(countAfterRelease, 0)
    }

    func testWithConsumerReleasesAfterFailureAndCancellation() async throws {
        let manager = LiveStreamManager(bufferCapacity: 2, historySafetyPassed: true)

        do {
            _ = try await manager.withConsumer(kind: .realtimeIMU, consumer: .breathing) {
                throw TestFailure.failed
            }
            XCTFail("expected operation failure")
        } catch TestFailure.failed {
            // Expected.
        }
        let countAfterFailure = await manager.totalConsumerCount()
        XCTAssertEqual(countAfterFailure, 0)

        let task = Task {
            try await manager.withConsumer(kind: .compactHeartRateRR, consumer: .spotCheck) {
                while !Task.isCancelled {
                    await Task.yield()
                }
                try Task.checkCancellation()
                return 1
            }
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
        let countAfterCancellation = await manager.totalConsumerCount()
        XCTAssertEqual(countAfterCancellation, 0)
    }

    func testOrdinaryBackgroundPolicyKeepsHRAndSuspendsHeavyStreams() async throws {
        let sink = RecordingLiveStreamSink()
        let manager = LiveStreamManager(commandSink: sink, historySafetyPassed: true)
        let raw = try await manager.acquire(kind: .realtimeRaw, consumer: .activeWorkout)
        let heartRate = try await manager.acquire(kind: .compactHeartRateRR, consumer: .activeWorkout)

        await manager.setBackgroundPolicy(.ordinaryBackground)
        let backgroundPolicy = await manager.currentBackgroundPolicy()
        XCTAssertEqual(backgroundPolicy, .ordinaryBackground)
        let backgroundEffectiveKinds = await manager.effectiveEnabledKinds()
        XCTAssertEqual(
            backgroundEffectiveKinds,
            [.compactHeartRateRR]
        )
        let backgroundRequestedKinds = await manager.enabledKinds()
        XCTAssertEqual(
            backgroundRequestedKinds,
            [.compactHeartRateRR, .realtimeRaw]
        )

        var calls = await sink.recordedCalls()
        XCTAssertTrue(calls.contains { $0 == (.realtimeRaw, false) })
        XCTAssertFalse(calls.contains { $0 == (.realtimeIMU, true) })

        await manager.setBackgroundPolicy(.foreground)
        let foregroundEffectiveKinds = await manager.effectiveEnabledKinds()
        XCTAssertEqual(foregroundEffectiveKinds, [.compactHeartRateRR, .realtimeRaw])
        calls = await sink.recordedCalls()
        XCTAssertTrue(calls.contains { $0 == (.realtimeRaw, true) })

        _ = await raw.release()
        _ = await heartRate.release()
        let totalConsumerCount = await manager.totalConsumerCount()
        XCTAssertEqual(totalConsumerCount, 0)
    }

    func testSummaryIsThrottledAndDoesNotExposePayloads() async throws {
        let manager = LiveStreamManager(bufferCapacity: 3, historySafetyPassed: true)
        let handle = try await manager.acquire(kind: .compactHeartRateRR, consumer: .activeWorkout)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        await manager.ingest(kind: .compactHeartRateRR, payload: Data([0xAA]), receivedAt: base)
        await manager.ingest(kind: .compactHeartRateRR, payload: Data([0xBB]), receivedAt: base.addingTimeInterval(0.1))

        let first = await manager.summary(for: .compactHeartRateRR, at: base, minimumInterval: 1)
        XCTAssertEqual(first?.packetsSinceLastSummary, 2)
        let throttled = await manager.summary(for: .compactHeartRateRR, at: base.addingTimeInterval(0.5), minimumInterval: 1)
        XCTAssertNil(throttled)
        let second = await manager.summary(for: .compactHeartRateRR, at: base.addingTimeInterval(1), minimumInterval: 1)
        XCTAssertEqual(second?.packetsSinceLastSummary, 0)
        let released = await handle.release()
        XCTAssertTrue(released)
    }

    func testTypedEventsAreGenerationPinnedBoundedAndDecodedWithoutChangingPolling() async throws {
        let sink = RecordingLiveStreamSink()
        let manager = LiveStreamManager(
            commandSink: sink,
            bufferCapacity: 4,
            eventBufferCapacity: 2,
            historySafetyPassed: true
        )
        let generation: UInt64 = 42
        let subscription = try await manager.acquireEventStream(
            kind: .compactHeartRateRR,
            consumer: .breathing,
            generation: generation
        )
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        await manager.ingest(
            kind: .compactHeartRateRR,
            payload: strippedCompactPayload(timestamp: 100, heartRate: 55, rr: [800]),
            receivedAt: base,
            generation: 41
        )
        await manager.ingest(
            kind: .compactHeartRateRR,
            payload: strippedCompactPayload(timestamp: 101, heartRate: 56, rr: [810]),
            receivedAt: base.addingTimeInterval(1),
            generation: generation
        )
        await manager.ingest(
            kind: .compactHeartRateRR,
            payload: strippedCompactPayload(timestamp: 102, heartRate: 57, rr: [820]),
            receivedAt: base.addingTimeInterval(2),
            generation: generation
        )
        await manager.ingest(
            kind: .compactHeartRateRR,
            payload: strippedCompactPayload(timestamp: 103, heartRate: 58, rr: [830]),
            receivedAt: base.addingTimeInterval(3),
            generation: generation
        )

        var iterator = subscription.stream.makeAsyncIterator()
        let first = await iterator.next()
        let second = await iterator.next()
        XCTAssertEqual(first?.generation, generation)
        XCTAssertEqual(second?.generation, generation)
        XCTAssertEqual(first?.payload, strippedCompactPayload(timestamp: 102, heartRate: 57, rr: [820]))
        XCTAssertEqual(second?.payload, strippedCompactPayload(timestamp: 103, heartRate: 58, rr: [830]))
        XCTAssertEqual(first.flatMap(LiveStreamEventDecoder.decodeCardiac)?.sample.heartRateBPM, 57)
        XCTAssertEqual(second.flatMap(LiveStreamEventDecoder.decodeCardiac)?.sample.rrMilliseconds, [830])

        let polling = await manager.bufferedSamples(for: .compactHeartRateRR)
        XCTAssertEqual(polling.count, 4, "legacy opaque polling remains available")

        let firstCancellation = await subscription.cancel()
        let secondCancellation = await subscription.cancel()
        let ended = await iterator.next()
        let consumerCount = await manager.consumerCount(for: .compactHeartRateRR)
        let calls = await sink.recordedCalls().map(\.1)
        XCTAssertTrue(firstCancellation)
        XCTAssertFalse(secondCancellation)
        XCTAssertNil(ended)
        XCTAssertEqual(consumerCount, 0)
        XCTAssertEqual(calls, [true, false])
    }

    func testTypedEventSubscriptionResetFinishesStreamAndDoesNotDoubleDisable() async throws {
        let sink = RecordingLiveStreamSink()
        let manager = LiveStreamManager(commandSink: sink, historySafetyPassed: true)
        let subscription = try await manager.acquireEventStream(
            kind: .compactHeartRateRR,
            consumer: .spotCheck,
            generation: 7
        )
        var iterator = subscription.stream.makeAsyncIterator()
        await manager.reset()

        let ended = await iterator.next()
        let cancelledAfterReset = await subscription.cancel()
        let consumerCount = await manager.totalConsumerCount()
        let calls = await sink.recordedCalls().map(\.1)
        XCTAssertNil(ended)
        XCTAssertFalse(cancelledAfterReset, "reset already ended the subscription")
        XCTAssertEqual(consumerCount, 0)
        XCTAssertEqual(calls, [true, false])
    }

    private func strippedCompactPayload(
        timestamp: UInt32,
        heartRate: UInt8,
        rr: [UInt16]
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
        bytes[18] = 1
        return Data(bytes.dropFirst())
    }

    private enum TestFailure: Error { case failed }
}
