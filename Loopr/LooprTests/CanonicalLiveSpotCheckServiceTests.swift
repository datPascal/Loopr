import BluetoothKit
import Foundation
import HeartKit
import StressKit
import Testing
@testable import Loopr

@MainActor
struct CanonicalLiveSpotCheckServiceTests {
    @Test
    func sufficientSessionUsesCanonicalQualityAndPersistsBothRows() async throws {
        let runtime = SpotCheckRuntimeFixture()
        let clock = GateSpotCheckClock()
        let persistence = InMemoryCanonicalSpotCheckPersistence()
        let service = CanonicalLiveSpotCheckService(
            runtime: runtime,
            persistence: persistence,
            clock: clock,
            defaultDuration: .seconds(60)
        )
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000601")!
        let task = Task { try await service.measure(duration: .seconds(60), generation: id) }
        try await waitForAcquisition(runtime)

        for index in 0..<16 {
            await runtime.ingest(compactPayload(timestamp: UInt32(index + 1)))
        }
        clock.open()
        let result = try await task.value

        #expect(result.resolvedAvailability == .complete)
        #expect(result.rmssd != nil)
        #expect(result.heartRate == 72)
        #expect(result.rrSampleCount == 32)
        #expect(result.normalRRCount ?? 0 >= 30)
        #expect(result.cleanFraction ?? 0 >= 0.5)
        #expect(result.algorithmVersions == ["ana02.rr-quality.v1", "ana02.hrv.v1"])
        #expect(result.provenance?.contains("BLE-07") == true)
        #expect((await persistence.savedStress()).count == 1)
        #expect(await persistence.savedHeart()?.resolvedAvailability == .complete)
        #expect(await runtime.consumerCount() == 0)
    }

    @Test
    func insufficientQualityPreservesAbsenceAndCountsMalformedFrames() async throws {
        let runtime = SpotCheckRuntimeFixture()
        let clock = GateSpotCheckClock()
        let persistence = InMemoryCanonicalSpotCheckPersistence()
        let service = CanonicalLiveSpotCheckService(runtime: runtime, persistence: persistence, clock: clock)
        let task = Task {
            try await service.measure(
                duration: .seconds(60),
                generation: UUID(uuidString: "00000000-0000-0000-0000-000000000602")!
            )
        }
        try await waitForAcquisition(runtime)
        await runtime.ingest(compactPayload(timestamp: 1))
        await runtime.ingest(Data([0x01, 0x02]))
        clock.open()

        let result = try await task.value
        #expect(result.resolvedAvailability == .insufficientQuality)
        #expect(result.rmssd == nil)
        #expect(result.qualityAvailable == nil)
        #expect(result.rrSampleCount == 2)
        #expect(result.rejectedSampleCount == 1)
        #expect(result.cleanFraction ?? 0 > 0)
        #expect((await persistence.savedStress()).count == 1)
        #expect(await runtime.consumerCount() == 0)
    }

    @Test
    func packetGapsDoNotCreateFalseSuccessiveRRDifferences() async throws {
        let runtime = SpotCheckRuntimeFixture()
        let clock = GateSpotCheckClock()
        let persistence = InMemoryCanonicalSpotCheckPersistence()
        let service = CanonicalLiveSpotCheckService(runtime: runtime, persistence: persistence, clock: clock)
        let task = Task {
            try await service.measure(
                duration: .seconds(60),
                generation: UUID(uuidString: "00000000-0000-0000-0000-000000000606")!
            )
        }
        try await waitForAcquisition(runtime)
        for index in 0..<10 {
            await runtime.ingest(
                compactPayload(
                    timestamp: UInt32(index * 10 + 1),
                    rr: [960, 1_000, 1_040]
                )
            )
        }
        clock.open()

        let result = try await task.value
        #expect(result.resolvedAvailability == .complete)
        #expect(result.rrSampleCount == 30)
        #expect(result.rmssd == 40)
        #expect(await runtime.consumerCount() == 0)
    }

    @Test
    func staleGenerationIsDroppedBeforeAnalytics() async throws {
        let runtime = SpotCheckRuntimeFixture()
        let clock = GateSpotCheckClock()
        let persistence = InMemoryCanonicalSpotCheckPersistence()
        let service = CanonicalLiveSpotCheckService(runtime: runtime, persistence: persistence, clock: clock)
        let task = Task {
            try await service.measure(
                duration: .seconds(60),
                generation: UUID(uuidString: "00000000-0000-0000-0000-000000000603")!
            )
        }
        try await waitForAcquisition(runtime)
        await runtime.ingest(compactPayload(timestamp: 1), generation: 8)
        clock.open()

        let result = try await task.value
        #expect(result.resolvedAvailability == .insufficientQuality)
        #expect(result.rrSampleCount == 0)
        #expect(result.rmssd == nil)
        #expect(await runtime.consumerCount() == 0)
    }

    @Test
    func cancellationReleasesSubscriptionAndDoesNotPersist() async throws {
        let runtime = SpotCheckRuntimeFixture()
        let clock = GateSpotCheckClock()
        let persistence = InMemoryCanonicalSpotCheckPersistence()
        let service = CanonicalLiveSpotCheckService(runtime: runtime, persistence: persistence, clock: clock)
        let task = Task {
            try await service.measure(
                duration: .seconds(60),
                generation: UUID(uuidString: "00000000-0000-0000-0000-000000000604")!
            )
        }
        try await waitForAcquisition(runtime)
        task.cancel()

        await #expect(throws: CanonicalLiveSpotCheckError.cancelled) {
            _ = try await task.value
        }
        #expect(await persistence.savedStress().isEmpty)
        #expect(await runtime.consumerCount() == 0)
    }

    @Test
    func persistenceFailureFailsClosedAfterRelease() async throws {
        let runtime = SpotCheckRuntimeFixture()
        let clock = GateSpotCheckClock()
        let persistence = InMemoryCanonicalSpotCheckPersistence()
        await persistence.setShouldFail(true)
        let service = CanonicalLiveSpotCheckService(runtime: runtime, persistence: persistence, clock: clock)
        let task = Task {
            try await service.measure(
                duration: .seconds(60),
                generation: UUID(uuidString: "00000000-0000-0000-0000-000000000605")!
            )
        }
        try await waitForAcquisition(runtime)
        for index in 0..<16 {
            await runtime.ingest(compactPayload(timestamp: UInt32(index + 1)))
        }
        clock.open()

        await #expect(throws: CanonicalLiveSpotCheckError.persistenceFailed) {
            _ = try await task.value
        }
        #expect(await persistence.savedStress().isEmpty)
        #expect(await runtime.consumerCount() == 0)
    }
}

private actor SpotCheckRuntimeFixture: LooprHeartLiveRuntime {
    private let manager = LiveStreamManager(historySafetyPassed: true)
    private let pinnedGeneration: UInt64 = 7
    private var eventReady = false

    func acquireLiveStream(kind: LiveStreamKind, consumer: LiveStreamConsumer) async throws -> LiveStreamConsumerHandle {
        try await manager.acquire(kind: kind, consumer: consumer)
    }

    func acquireLiveEventStream(kind: LiveStreamKind, consumer: LiveStreamConsumer) async throws -> LiveStreamEventSubscription {
        let subscription = try await manager.acquireEventStream(kind: kind, consumer: consumer, generation: pinnedGeneration)
        eventReady = true
        return subscription
    }

    func bufferedLiveSamples(for kind: LiveStreamKind) async -> [LiveStreamSample] { [] }

    func ingest(_ payload: Data, generation: UInt64 = 7) async {
        await manager.ingest(
            kind: .compactHeartRateRR,
            payload: payload,
            receivedAt: Date(timeIntervalSince1970: 1_700_000_000),
            generation: generation
        )
    }

    func consumerCount() async -> Int {
        await manager.consumerCount(for: .compactHeartRateRR)
    }

    func eventSubscriptionReady() -> Bool { eventReady }
}

private final class GateSpotCheckClock: @unchecked Sendable, LiveSpotCheckClock {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var opened = false
    private var cancelled = false
    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_100)

    func now() -> Date { fixedDate }

    func sleep(for duration: Duration) async throws {
        if lock.withLock({ opened }) { return }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                self.lock.withLock {
                    if self.cancelled {
                        continuation.resume(throwing: CancellationError())
                    } else if self.opened {
                        continuation.resume()
                    } else {
                        self.continuation = continuation
                    }
                }
            }
        } onCancel: {
            self.cancelWait()
        }
    }

    func open() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            opened = true
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume()
    }

    private func cancelWait() {
        let continuation = lock.withLock {
            cancelled = true
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume(throwing: CancellationError())
    }
}

private func waitForAcquisition(_ runtime: SpotCheckRuntimeFixture) async throws {
    for _ in 0..<100 {
        if await runtime.consumerCount() == 1, await runtime.eventSubscriptionReady() { return }
        await Task.yield()
    }
    throw CanonicalLiveSpotCheckError.unavailable
}

private func compactPayload(timestamp: UInt32, heartRate: UInt8 = 72, rr: [UInt16] = [1_000, 1_012]) -> Data {
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
