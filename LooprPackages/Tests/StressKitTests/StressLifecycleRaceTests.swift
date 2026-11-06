import Foundation
import StressKit
import Testing

private actor StressGate {
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

private actor GatedStressConsumer: LiveConsumer {
    let acquireGate: StressGate?
    let releaseGate: StressGate?
    private var acquisitions = 0
    private var releases = 0
    init(acquire: StressGate? = nil, release: StressGate? = nil) {
        acquireGate = acquire; releaseGate = release
    }
    func acquire(generation: UUID) async throws -> AsyncStream<LiveCardiacSample> {
        acquisitions += 1
        if acquisitions == 1 { await acquireGate?.pause() }
        return AsyncStream { _ in }
    }
    func release(generation: UUID) async {
        releases += 1
        if releases == 1 { await releaseGate?.pause() }
    }
    func counts() -> (Int, Int) { (acquisitions, releases) }
}

private struct GatedStressMeasurement: SpotCheckMechanism {
    let gate: StressGate
    func measure(duration: Duration, generation: UUID) async throws -> SpotCheckResult {
        await gate.pause()
        return SpotCheckResult(id: generation, startedAt: .now, endedAt: .now, rmssd: 40, heartRate: 60, quality: 1)
    }
}

struct StressLifecycleRaceTests {
    @Test func invalidationDuringBreathingAcquisitionCannotRestartSession() async throws {
        let gate = StressGate()
        let consumer = GatedStressConsumer(acquire: gate)
        let controller = BreathingSessionController(consumer: consumer)
        let start = Task { try await controller.start() }
        await gate.wait()
        await controller.invalidateGeneration()
        await gate.open()
        _ = try? await start.value
        #expect(await controller.currentState() == .staleGeneration)
        #expect(await controller.currentGeneration() == nil)
        #expect(await consumer.counts().1 == 1)
    }

    @Test func cancelledBreathingAcquisitionReleasesLateLease() async throws {
        let gate = StressGate()
        let consumer = GatedStressConsumer(acquire: gate)
        let controller = BreathingSessionController(consumer: consumer)
        let start = Task { try await controller.start() }
        await gate.wait(); start.cancel(); await gate.open()
        _ = try? await start.value
        #expect(await controller.currentState() != .running)
        #expect(await controller.currentGeneration() == nil)
        #expect(await consumer.counts().1 == 1)
    }

    @Test func breathingFinishDetachesBeforeAwaitingRelease() async throws {
        let gate = StressGate()
        let consumer = GatedStressConsumer(release: gate)
        let controller = BreathingSessionController(consumer: consumer)
        let oldID = try await controller.start()
        let finish = Task { try await controller.finish() }
        await gate.wait()
        let newID = UUID()
        _ = try await controller.start(id: newID)
        await gate.open(); _ = try await finish.value
        #expect(await controller.currentState() == .running)
        #expect(await controller.currentGeneration() != nil)
        #expect(await controller.history().map(\.id) == [oldID])
        let current = try await controller.finish()
        #expect(current.id == newID)
    }

    @Test func interruptedSpotCheckCannotPublishLateResult() async throws {
        let gate = StressGate()
        let controller = SpotCheckController(mechanism: GatedStressMeasurement(gate: gate))
        let run = Task { try await controller.run() }
        await gate.wait(); await controller.interrupt(); await gate.open()
        _ = try? await run.value
        #expect(await controller.history.all().isEmpty)
    }

    @Test func interruptedSpotCheckAcquisitionNeverStartsMeasurement() async throws {
        let gate = StressGate()
        let consumer = GatedStressConsumer(acquire: gate)
        let mechanism = CountingStressMeasurement()
        let controller = SpotCheckController(mechanism: mechanism, consumer: consumer)
        let run = Task { try await controller.run() }
        await gate.wait(); await controller.interrupt(); await gate.open()
        _ = try? await run.value
        #expect(await mechanism.count == 0)
        #expect(await consumer.counts().1 == 1)
        #expect(await controller.history.all().isEmpty)
    }
}

private actor CountingStressMeasurement: SpotCheckMechanism {
    private(set) var count = 0
    func measure(duration: Duration, generation: UUID) async throws -> SpotCheckResult {
        count += 1
        return SpotCheckResult(id: generation, startedAt: .now, endedAt: .now, rmssd: 40, heartRate: 60, quality: 1)
    }
}
