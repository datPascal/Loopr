import Foundation
import BluetoothKit
import HeartKit
import ProtocolKit
import SyncKit
import WorkoutKit

/// Narrow runtime seam used by the Heart feature. SyncKit remains the only
/// owner of the physical live stream and its generation-pinned command path.
/// This protocol intentionally exposes acquisition and opaque buffered frames,
/// not transport commands or guessed packet fields.
nonisolated protocol LooprHeartLiveRuntime: Sendable {
    func acquireLiveStream(kind: LiveStreamKind, consumer: LiveStreamConsumer) async throws -> LiveStreamConsumerHandle
    func acquireLiveEventStream(kind: LiveStreamKind, consumer: LiveStreamConsumer) async throws -> LiveStreamEventSubscription
    func bufferedLiveSamples(for kind: LiveStreamKind) async -> [LiveStreamSample]
}

extension LooprHeartLiveRuntime {
    /// Existing app runtime fakes and non-live device seams remain safely
    /// unavailable until they explicitly adopt the typed subscription API.
    func acquireLiveEventStream(kind: LiveStreamKind, consumer: LiveStreamConsumer) async throws -> LiveStreamEventSubscription {
        throw HeartLiveStreamAdapterError.unavailable
    }
}

extension BluetoothAdoptionRuntime: LooprHeartLiveRuntime {}

enum HeartLiveStreamAdapterError: Error, Equatable, Sendable, LocalizedError {
    case unavailable

    var errorDescription: String? {
        switch self {
        case .unavailable: "Live heart data is unavailable until the shared Bluetooth session is ready."
        }
    }
}

/// Production HeartKit client backed by the already-running SyncKit runtime.
/// It never starts transport, writes BLE commands, or decodes protocol bytes.
/// A lease release is delegated to SyncKit's idempotent consumer handle.
actor SyncKitHeartLiveStreamClient: HeartLiveStreamClient, HeartLiveEventStreamClient {
    private let runtime: any LooprHeartLiveRuntime

    init(runtime: any LooprHeartLiveRuntime) {
        self.runtime = runtime
    }

    func acquire(kind: LiveStreamKind, consumer: LiveStreamConsumer) async throws -> HeartLiveConsumerLease {
        let handle = try await runtime.acquireLiveStream(kind: kind, consumer: consumer)
        return HeartLiveConsumerLease {
            _ = await handle.release()
        }
    }

    func acquireEventStream(kind: LiveStreamKind, consumer: LiveStreamConsumer) async throws -> HeartLiveEventSubscription {
        let source = try await runtime.acquireLiveEventStream(kind: kind, consumer: consumer)
        let pair = AsyncStream<HeartLiveDecodedSample>.makeStream(
            bufferingPolicy: .bufferingNewest(256)
        )
        let mappingTask = Task {
            for await event in source.stream {
                guard !Task.isCancelled else { break }
                // The runtime pins the subscription to this generation. Keep
                // the check at the feature seam as a second stale-frame fence.
                guard event.generation == source.generation,
                      let sample = HeartLiveEventMapper.decode(event) else {
                    continue
                }
                _ = pair.continuation.yield(sample)
            }
            pair.continuation.finish()
        }
        return HeartLiveEventSubscription(
            generation: source.generation,
            stream: pair.stream,
            cancelAction: {
                // Release the source before cancelling the mapper. Cancelling
                // its iterator can trigger AsyncStream's onTermination hook,
                // which also releases the source. If that hook wins the
                // actor turn, an explicit first cancellation would report
                // `false` despite this subscription still being active.
                let cancelled = await source.cancel()
                mappingTask.cancel()
                pair.continuation.finish()
                return cancelled
            }
        )
    }

    func samples(for kind: LiveStreamKind) async -> [HeartLiveSample] {
        let frames = await runtime.bufferedLiveSamples(for: kind)
        return frames.map {
            HeartLiveSample(
                kind: $0.kind,
                heartRateBPM: nil,
                rrMilliseconds: nil,
                receivedAt: $0.receivedAt,
                rawPayload: $0.payload
            )
        }
    }
}

/// Explicit fail-closed client for a production composition that has not yet
/// received a shared runtime. It is preferable to an in-memory sample source.
struct UnavailableHeartLiveStreamClient: HeartLiveStreamClient {
    init() {}

    func acquire(kind: LiveStreamKind, consumer: LiveStreamConsumer) async throws -> HeartLiveConsumerLease {
        throw HeartLiveStreamAdapterError.unavailable
    }

    func samples(for kind: LiveStreamKind) async -> [HeartLiveSample] { [] }
}

struct UnavailableHeartLiveEventClient: HeartLiveEventStreamClient {
    init() {}

    func acquireEventStream(kind: LiveStreamKind, consumer: LiveStreamConsumer) async throws -> HeartLiveEventSubscription {
        throw HeartLiveStreamAdapterError.unavailable
    }
}

/// WorkoutKit consumes the same verified, generation-pinned compact cardiac
/// stream as HeartKit. The adapter maps only decoded heart rate and preserves
/// the session's own UUID generation fence; it never interprets opaque bytes.
actor SyncKitWorkoutLiveSampleSource: WorkoutLiveSampleSource {
    private let runtime: any LooprHeartLiveRuntime

    init(runtime: any LooprHeartLiveRuntime) {
        self.runtime = runtime
    }

    func acquire(generation: UUID) async throws -> WorkoutLiveSampleLease {
        let source = try await runtime.acquireLiveEventStream(
            kind: .compactHeartRateRR,
            consumer: .activeWorkout
        )
        let pair = AsyncStream<WorkoutSample>.makeStream(bufferingPolicy: .bufferingNewest(256))
        let mappingTask = Task {
            for await event in source.stream {
                guard !Task.isCancelled,
                      event.generation == source.generation,
                      let decoded = LiveStreamEventDecoder.decodeCardiac(event) else { continue }
                let sample = decoded.sample
                _ = pair.continuation.yield(WorkoutSample(
                    // Receipt time is the live freshness clock. Band RTC can
                    // be unset, so its timestamp cannot prove a sample is live.
                    timestamp: event.receivedAt,
                    heartRate: Int(sample.heartRate)
                ))
            }
            pair.continuation.finish()
        }
        return WorkoutLiveSampleLease(
            generation: generation,
            stream: pair.stream,
            cancelAction: {
                mappingTask.cancel()
                pair.continuation.finish()
                _ = await source.cancel()
            }
        )
    }
}
