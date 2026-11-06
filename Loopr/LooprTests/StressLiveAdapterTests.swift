import BluetoothKit
import Foundation
import HeartKit
import StressKit
import Testing
@testable import Loopr

struct StressLiveAdapterTests {
    @Test func releaseDuringAcquisitionDisposesLateSubscription() async throws {
        let runtime = StressRuntimeFixture()
        let gate = StressAcquisitionGate()
        await runtime.pauseNextAcquisition(gate)
        let consumer = SyncKitStressLiveConsumer(runtime: runtime)
        let generation = UUID()
        let acquisition = Task { try await consumer.acquire(generation: generation) }
        await gate.wait()
        await consumer.release(generation: generation)
        await gate.open(); _ = try? await acquisition.value
        #expect(await consumer.activeGenerationCount() == 0)
        #expect(await runtime.consumerCount() == 0)
    }

    @Test func concurrentAcquisitionCannotReplaceSameGenerationLease() async throws {
        let runtime = StressRuntimeFixture()
        let gate = StressAcquisitionGate()
        await runtime.pauseNextAcquisition(gate)
        let consumer = SyncKitStressLiveConsumer(runtime: runtime)
        let generation = UUID()
        let first = Task { try await consumer.acquire(generation: generation) }
        await gate.wait()
        do {
            _ = try await consumer.acquire(generation: generation)
            Issue.record("A pending generation accepted a second subscription")
        } catch StressError.staleGeneration {}
        await gate.open(); _ = try await first.value
        await consumer.release(generation: generation)
        #expect(await runtime.consumerCount() == 0)
    }

    @Test
    func missingRuntimeFailsClosedForBothStressCapabilities() async {
        let liveConsumer = StressLiveAdapter.liveConsumer(runtime: nil)
        let spotCheck = StressLiveAdapter.spotCheckMechanism(runtime: nil)
        let generation = UUID(uuidString: "00000000-0000-0000-0000-000000000081")!

        await #expect(throws: StressLiveAdapterFailure.blocked(.sharedRuntimeUnavailable)) {
            _ = try await liveConsumer.acquire(generation: generation)
        }
        await #expect(throws: StressLiveAdapterFailure.blocked(.sharedRuntimeUnavailable)) {
            _ = try await spotCheck.measure(duration: .seconds(30), generation: generation)
        }

        let failClosedConsumer = liveConsumer as? FailClosedStressLiveConsumer
        let failClosedSpotCheck = spotCheck as? FailClosedStressSpotCheckMechanism
        #expect(failClosedConsumer?.blocker == .sharedRuntimeUnavailable)
        #expect(failClosedSpotCheck?.blocker == .sharedRuntimeUnavailable)
    }

    @Test
    func availableRuntimeMapsTypedHeartAndRRFramesAndReleasesOnce() async throws {
        let runtime = StressRuntimeFixture()
        let liveConsumer = StressLiveAdapter.liveConsumer(runtime: runtime)
        let spotCheck = StressLiveAdapter.spotCheckMechanism(runtime: runtime)
        let generation = UUID(uuidString: "00000000-0000-0000-0000-000000000082")!

        let stream = try await liveConsumer.acquire(generation: generation)
        let nextSample = Task { @Sendable in
            var iterator = stream.makeAsyncIterator()
            return await iterator.next()
        }
        await runtime.ingest(Data([0x01, 0x01, 0, 0, 0, 0, 0, 72, 1]))
        await runtime.ingest(compactHeartRatePayload(), generation: 8)
        await runtime.ingest(compactHeartRatePayload())

        let sample = try #require(await nextSample.value)
        #expect(sample.heartRate == 72)
        #expect(sample.rrMilliseconds == [1_000.0, 1_012.0])

        await liveConsumer.release(generation: generation)
        await liveConsumer.release(generation: generation)
        #expect(await runtime.consumerCount() == 0)

        await #expect(throws: StressLiveAdapterFailure.blocked(.canonicalSpotCheckDerivationUnavailable)) {
            _ = try await spotCheck.measure(duration: .seconds(30), generation: generation)
        }

        let failClosedSpotCheck = spotCheck as? FailClosedStressSpotCheckMechanism
        #expect(failClosedSpotCheck?.blocker == .canonicalSpotCheckDerivationUnavailable)
    }

    @Test
    func blockerMessagesExplainUnavailableReadings() {
        #expect(StressLiveAdapterFailure.blocked(.sharedRuntimeUnavailable).localizedDescription == "Connect your band and try again.")
        #expect(StressLiveAdapterFailure.blocked(.canonicalSpotCheckDerivationUnavailable).localizedDescription.contains("reliable HRV result"))
    }
}

private actor StressRuntimeFixture: LooprHeartLiveRuntime {
    private let manager = LiveStreamManager(historySafetyPassed: true)
    let generation: UInt64 = 7
    private var acquisitionGate: StressAcquisitionGate?
    func pauseNextAcquisition(_ gate: StressAcquisitionGate) { acquisitionGate = gate }

    func acquireLiveStream(kind: LiveStreamKind, consumer: LiveStreamConsumer) async throws -> LiveStreamConsumerHandle {
        try await manager.acquire(kind: kind, consumer: consumer)
    }

    func acquireLiveEventStream(kind: LiveStreamKind, consumer: LiveStreamConsumer) async throws -> LiveStreamEventSubscription {
        let subscription = try await manager.acquireEventStream(kind: kind, consumer: consumer, generation: generation)
        if let gate = acquisitionGate { acquisitionGate = nil; await gate.pause() }
        return subscription
    }

    func bufferedLiveSamples(for kind: LiveStreamKind) async -> [LiveStreamSample] {
        []
    }

    func ingest(_ payload: Data, generation: UInt64 = 7) async {
        await manager.ingest(
            kind: .compactHeartRateRR,
            payload: payload,
            receivedAt: Date(timeIntervalSince1970: 42),
            generation: generation
        )
    }

    func consumerCount() async -> Int {
        await manager.consumerCount(for: .compactHeartRateRR)
    }
}

private actor StressAcquisitionGate {
    private var entered = false
    private var waiting: CheckedContinuation<Void, Never>?
    private var opening: CheckedContinuation<Void, Never>?
    func pause() async {
        entered = true; waiting?.resume(); waiting = nil
        await withCheckedContinuation { opening = $0 }
    }
    func wait() async {
        if entered { return }
        await withCheckedContinuation { waiting = $0 }
    }
    func open() { opening?.resume(); opening = nil }
}

private func compactHeartRatePayload() -> Data {
    Data([
        0x01,
        0x01, 0x00, 0x00, 0x00,
        0x00, 0x00,
        72,
        2,
        0xE8, 0x03,
        0xF4, 0x03
    ])
}
