import Foundation
import BluetoothKit
import HeartKit
import StressKit

/// Explicit upstream blockers for Stress live measurement. SyncKit currently
/// exposes opaque buffered frames and release handles, but not a decoded
/// cardiac event stream or a canonical RMSSD/quality derivation.
enum StressLiveAdapterBlocker: String, Equatable, Sendable {
    case sharedRuntimeUnavailable
    case canonicalCardiacDecoderAndEventStreamUnavailable
    case canonicalSpotCheckDerivationUnavailable

    var message: String {
        switch self {
        case .sharedRuntimeUnavailable:
            "Connect your band and try again."
        case .canonicalCardiacDecoderAndEventStreamUnavailable:
            "A live reading is unavailable with this band signal."
        case .canonicalSpotCheckDerivationUnavailable:
            "A spot check is unavailable because Loopr cannot calculate a reliable HRV result from the live signal yet."
        }
    }
}

enum StressLiveAdapterFailure: Error, Equatable, LocalizedError {
    case blocked(StressLiveAdapterBlocker)

    var errorDescription: String? {
        switch self {
        case .blocked(let blocker): blocker.message
        }
    }
}

/// Fail-closed Stress consumer. A raw 0x28 payload is never converted into a
/// cardiac sample by guessing byte offsets, so breathing cannot count opaque
/// packets as signal coverage.
struct FailClosedStressLiveConsumer: LiveConsumer {
    let blocker: StressLiveAdapterBlocker

    init(blocker: StressLiveAdapterBlocker) {
        self.blocker = blocker
    }

    func acquire(generation: UUID) async throws -> AsyncStream<LiveCardiacSample> {
        throw StressLiveAdapterFailure.blocked(blocker)
    }

    func release(generation: UUID) async {}
}

/// Typed StressKit bridge backed by the same generation-pinned event
/// subscription used by Heart. The UUID is StressKit's logical session token;
/// the underlying SyncKit subscription carries and validates the Bluetooth
/// connection generation.
actor SyncKitStressLiveConsumer: LiveConsumer {
    private struct ActiveSubscription {
        let source: LiveStreamEventSubscription
        let continuation: AsyncStream<LiveCardiacSample>.Continuation
        let mappingTask: Task<Void, Never>
    }

    private let runtime: any LooprHeartLiveRuntime
    private var active: [UUID: ActiveSubscription] = [:]
    private var releases: [UUID: Task<Void, Never>] = [:]

    init(runtime: any LooprHeartLiveRuntime) {
        self.runtime = runtime
    }

    func acquire(generation: UUID) async throws -> AsyncStream<LiveCardiacSample> {
        guard active[generation] == nil else { throw StressError.staleGeneration }

        let source = try await runtime.acquireLiveEventStream(
            kind: .compactHeartRateRR,
            consumer: .breathing
        )
        let pair = AsyncStream<LiveCardiacSample>.makeStream(
            bufferingPolicy: .bufferingNewest(256)
        )
        let mappingTask = Task { [weak self] in
            for await event in source.stream {
                guard !Task.isCancelled else { break }
                guard event.generation == source.generation,
                      let sample = StressLiveEventMapper.decode(event) else {
                    continue
                }
                _ = pair.continuation.yield(sample)
            }
            pair.continuation.finish()
            await self?.sourceEnded(generation: generation)
        }
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.release(generation: generation) }
        }
        active[generation] = ActiveSubscription(
            source: source,
            continuation: pair.continuation,
            mappingTask: mappingTask
        )
        return pair.stream
    }

    func release(generation: UUID) async {
        if let release = releases[generation] {
            await release.value
            return
        }
        guard let subscription = active.removeValue(forKey: generation) else { return }
        subscription.mappingTask.cancel()
        subscription.continuation.finish()
        let release = Task {
            _ = await subscription.source.cancel()
        }
        releases[generation] = release
        await release.value
        releases.removeValue(forKey: generation)
    }

    func activeGenerationCount() -> Int { active.count }

    private func sourceEnded(generation: UUID) {
        active.removeValue(forKey: generation)
    }
}

/// Fail-closed spot-check mechanism. Heart-rate/RR bytes alone are not a
/// canonical RMSSD or quality result, so no result is manufactured.
struct FailClosedStressSpotCheckMechanism: SpotCheckMechanism {
    let blocker: StressLiveAdapterBlocker

    init(blocker: StressLiveAdapterBlocker) {
        self.blocker = blocker
    }

    func measure(duration: Duration, generation: UUID) async throws -> SpotCheckResult {
        throw StressLiveAdapterFailure.blocked(blocker)
    }
}

enum StressLiveAdapter {
    nonisolated static func liveConsumer(runtime: (any LooprHeartLiveRuntime)?) -> any LiveConsumer {
        guard let runtime else {
            return FailClosedStressLiveConsumer(blocker: .sharedRuntimeUnavailable)
        }
        return SyncKitStressLiveConsumer(runtime: runtime)
    }

    nonisolated static func spotCheckMechanism(runtime: (any LooprHeartLiveRuntime)?) -> any SpotCheckMechanism {
        FailClosedStressSpotCheckMechanism(
            blocker: runtime == nil
                ? .sharedRuntimeUnavailable
                : .canonicalSpotCheckDerivationUnavailable
        )
    }
}
