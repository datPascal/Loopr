import Foundation
import ProtocolKit

/// The three high-rate streams exposed by a Gen 4 band.
///
/// These values are protocol identifiers, not historical-record types.  A
/// live packet is deliberately kept in memory and is never handed to a
/// storage writer by this package.
public enum LiveStreamKind: UInt8, CaseIterable, Codable, Sendable {
    case compactHeartRateRR = 0x28
    case realtimeRaw = 0x2B
    case realtimeIMU = 0x33
}

public enum LiveStreamConsumer: String, CaseIterable, Codable, Sendable {
    case activeWorkout
    case spotCheck
    case calibration
    case breathing
    case other
}

/// Acquisition policy applied when the app moves between foreground and
/// ordinary background. This is state at the manager seam only: existing
/// `LiveStreamKind` values are passed to the command sink, and no new command
/// byte or opcode is invented here.
public enum LiveStreamBackgroundPolicy: String, CaseIterable, Codable, Sendable {
    case foreground
    case ordinaryBackground
}

public struct LiveStreamSample: Equatable, Sendable {
    public let kind: LiveStreamKind
    public let payload: Data
    public let receivedAt: Date

    public init(kind: LiveStreamKind, payload: Data, receivedAt: Date) {
        self.kind = kind
        self.payload = Data(payload)
        self.receivedAt = receivedAt
    }
}

/// An ephemeral live packet delivered to a typed stream subscriber.
///
/// `generation` is the SyncKit connection generation that accepted the
/// packet. Consumers must discard events from a generation they did not
/// acquire; this prevents a late callback from an old connection from being
/// mistaken for a sample in a resumed session.
public struct LiveStreamEvent: Equatable, Sendable {
    public let kind: LiveStreamKind
    public let generation: UInt64
    public let payload: Data
    public let receivedAt: Date

    public init(
        kind: LiveStreamKind,
        generation: UInt64,
        payload: Data,
        receivedAt: Date
    ) {
        self.kind = kind
        self.generation = generation
        self.payload = Data(payload)
        self.receivedAt = receivedAt
    }
}

/// A compact cardiac event with the shared ProtocolKit decoder already
/// applied. Feature packages can map this value without reimplementing byte
/// offsets or treating an opaque payload as a heart-rate measurement.
public struct DecodedLiveCardiacEvent: Equatable, Sendable {
    public let event: LiveStreamEvent
    public let sample: CompactLiveHeartRateSample

    public init(event: LiveStreamEvent, sample: CompactLiveHeartRateSample) {
        self.event = event
        self.sample = sample
    }
}

public enum LiveStreamEventDecoder {
    /// Decodes only the compact HR/RR stream. The SyncKit runtime stores
    /// payloads after the discriminator, so this path states that form
    /// explicitly before calling ProtocolKit.
    public static func decodeCardiac(_ event: LiveStreamEvent) -> DecodedLiveCardiacEvent? {
        guard event.kind == .compactHeartRateRR,
              let sample = CompactLiveHeartRateDecoder.decode(
                  event.payload,
                  form: .strippedPayload
              ) else {
            return nil
        }
        return DecodedLiveCardiacEvent(event: event, sample: sample)
    }
}

public struct LiveStreamSummary: Equatable, Sendable {
    public let kind: LiveStreamKind
    public let latestReceivedAt: Date?
    public let packetsSinceLastSummary: Int
    public let bufferedPacketCount: Int

    public init(
        kind: LiveStreamKind,
        latestReceivedAt: Date?,
        packetsSinceLastSummary: Int,
        bufferedPacketCount: Int
    ) {
        self.kind = kind
        self.latestReceivedAt = latestReceivedAt
        self.packetsSinceLastSummary = packetsSinceLastSummary
        self.bufferedPacketCount = bufferedPacketCount
    }
}

/// The only command seam needed by the live stream manager.  The CoreBluetooth
/// writer or the session actor owns the actual command encoding and transport.
/// This keeps high-rate packet handling independent of protocol/storage code.
public protocol LiveStreamCommandSink: Sendable {
    func setLiveStream(_ kind: LiveStreamKind, enabled: Bool) async throws
}

/// Optional aggregate command seam for a production session that must keep
/// Edge's multi-command live transitions atomic and ordered.  The original
/// per-kind method remains the compatibility path for existing feature/test
/// sinks; the runtime uses this richer seam so optical controls and pacing are
/// never lost between independent consumer-count transitions.
public protocol LiveStreamPolicyCommandSink: LiveStreamCommandSink {
    func reconcileLiveStreams(
        previousEffectiveKinds: Set<LiveStreamKind>,
        requestedKinds: Set<LiveStreamKind>,
        effectiveKinds: Set<LiveStreamKind>,
        policy: LiveStreamBackgroundPolicy
    ) async throws

    func disableAllLiveStreams() async throws
}

public struct NoopLiveStreamCommandSink: LiveStreamCommandSink {
    public init() {}

    public func setLiveStream(_ kind: LiveStreamKind, enabled: Bool) async throws {}
}

public enum LiveStreamError: Error, Equatable, Sendable, LocalizedError {
    case historySafetyRequired
    case generationUnavailable
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .historySafetyRequired:
            return "Live streams remain disabled until history commit safety has passed."
        case .generationUnavailable:
            return "Live events require an active Bluetooth connection generation."
        case .commandFailed(let reason):
            return "The live stream command failed: \(reason)"
        }
    }
}

/// A release-once handle held by a feature while it consumes a stream.
///
/// `release()` is intentionally explicit because Swift cannot run an async
/// actor operation from `deinit`.  The manager also offers `withConsumer`,
/// which gives callers a `defer`-style release path for success, failure, and
/// cancellation.
public final class LiveStreamConsumerHandle: @unchecked Sendable {
    public let id: UUID
    public let kind: LiveStreamKind
    public let consumer: LiveStreamConsumer

    private let lock = NSLock()
    private var released = false
    private let releaseAction: @Sendable () async -> Void

    fileprivate init(
        id: UUID,
        kind: LiveStreamKind,
        consumer: LiveStreamConsumer,
        releaseAction: @escaping @Sendable () async -> Void
    ) {
        self.id = id
        self.kind = kind
        self.consumer = consumer
        self.releaseAction = releaseAction
    }

    /// Releases this lease exactly once.  Releasing twice is harmless and
    /// reports `false` on the second call.
    @discardableResult
    public func release() async -> Bool {
        let shouldRelease = lock.withLock {
            guard !released else { return false }
            released = true
            return true
        }
        guard shouldRelease else { return false }
        await releaseAction()
        return true
    }

    public var isReleased: Bool { lock.withLock { released } }
}

/// A release-once subscription to the bounded typed event stream. Cancelling
/// the subscription finishes its `AsyncStream` and releases the underlying
/// consumer ownership; repeated cancellation is harmless.
public final class LiveStreamEventSubscription: @unchecked Sendable {
    public let id: UUID
    public let kind: LiveStreamKind
    public let consumer: LiveStreamConsumer
    public let generation: UInt64
    public let stream: AsyncStream<LiveStreamEvent>

    private let lock = NSLock()
    private var cancelled = false
    private let cancelAction: @Sendable () async -> Bool

    fileprivate init(
        id: UUID,
        kind: LiveStreamKind,
        consumer: LiveStreamConsumer,
        generation: UInt64,
        stream: AsyncStream<LiveStreamEvent>,
        cancelAction: @escaping @Sendable () async -> Bool
    ) {
        self.id = id
        self.kind = kind
        self.consumer = consumer
        self.generation = generation
        self.stream = stream
        self.cancelAction = cancelAction
    }

    @discardableResult
    public func cancel() async -> Bool {
        let shouldCancel = lock.withLock {
            guard !cancelled else { return false }
            cancelled = true
            return true
        }
        guard shouldCancel else { return false }
        return await cancelAction()
    }

    public var isCancelled: Bool { lock.withLock { cancelled } }
}

/// Consumer-counted, bounded in-memory live stream storage.
///
/// The actor is the single owner of stream counts and buffers.  Enabling and
/// disabling commands happen only on the 0→1 and 1→0 transitions, so a
/// disconnect/cancellation path cannot leave a stream enabled after the last
/// feature has gone away.
public actor LiveStreamManager {
    public static let defaultBufferCapacity = 256
    public static let defaultSummaryInterval: TimeInterval = 0.25

    private let commandSink: any LiveStreamCommandSink
    private let bufferCapacity: Int
    private let eventBufferCapacity: Int
    private var historySafetyPassed: Bool
    private var backgroundPolicy: LiveStreamBackgroundPolicy = .foreground
    private var consumerIDs: [LiveStreamKind: Set<UUID>] = [:]
    private var consumersByID: [UUID: LiveStreamKind] = [:]
    private var commandEnabledKinds: Set<LiveStreamKind> = []
    private var buffers: [LiveStreamKind: [LiveStreamSample]] = [:]
    private var packetCountsSinceSummary: [LiveStreamKind: Int] = [:]
    private var latestTimes: [LiveStreamKind: Date] = [:]
    private var lastSummaryAt: [LiveStreamKind: Date] = [:]
    private struct EventSubscriber {
        let kind: LiveStreamKind
        let generation: UInt64
        let continuation: AsyncStream<LiveStreamEvent>.Continuation
        let handle: LiveStreamConsumerHandle
    }
    private var eventSubscribers: [UUID: EventSubscriber] = [:]

    public init(
        commandSink: any LiveStreamCommandSink = NoopLiveStreamCommandSink(),
        bufferCapacity: Int = LiveStreamManager.defaultBufferCapacity,
        eventBufferCapacity: Int? = nil,
        historySafetyPassed: Bool = false
    ) {
        self.commandSink = commandSink
        self.bufferCapacity = max(1, bufferCapacity)
        self.eventBufferCapacity = max(1, eventBufferCapacity ?? bufferCapacity)
        self.historySafetyPassed = historySafetyPassed
    }

    /// Enables acquisition only after the commit-before-ACK/history-safety
    /// gate is complete.  Calling this repeatedly is idempotent.
    public func markHistorySafetyPassed() {
        historySafetyPassed = true
    }

    public func historySafetyIsPassed() -> Bool { historySafetyPassed }

    public func currentBackgroundPolicy() -> LiveStreamBackgroundPolicy {
        backgroundPolicy
    }

    /// Switches acquisition policy while retaining feature ownership. Raw and
    /// IMU streams are suspended in ordinary background; compact HR/RR is the
    /// only allowed requested stream there. Returning to foreground restores
    /// the kinds still owned by consumers.
    public func setBackgroundPolicy(_ policy: LiveStreamBackgroundPolicy) async {
        guard policy != backgroundPolicy else { return }
        let previousEffective = effectiveEnabledKinds()
        let previousPolicy = backgroundPolicy
        backgroundPolicy = policy
        let nextEffective = effectiveEnabledKinds()

        if let policySink = commandSink as? any LiveStreamPolicyCommandSink {
            do {
                try await policySink.reconcileLiveStreams(
                    previousEffectiveKinds: previousEffective,
                    requestedKinds: enabledKinds(),
                    effectiveKinds: nextEffective,
                    policy: policy
                )
                commandEnabledKinds = nextEffective
            } catch {
                // Preserve the requested policy so a later foreground/background
                // transition retries the full aggregate operation.  Keep the
                // wire bookkeeping at the last known-good effective set.
                backgroundPolicy = previousPolicy
            }
            return
        }

        for kind in previousEffective.subtracting(nextEffective)
        where commandEnabledKinds.contains(kind) {
            do {
                try await commandSink.setLiveStream(kind, enabled: false)
                commandEnabledKinds.remove(kind)
            } catch {
                // Keep the presumed wire-enabled bit so a later foreground
                // transition does not issue a duplicate enable before the
                // session owner retries cleanup.
            }
        }

        for kind in nextEffective.subtracting(previousEffective)
        where !commandEnabledKinds.contains(kind) {
            do {
                try await commandSink.setLiveStream(kind, enabled: true)
                commandEnabledKinds.insert(kind)
            } catch {
                // Ownership remains truthful; the session/transport owner can
                // retry the still-requested stream on its next state change.
            }
        }
    }

    public func acquire(
        kind: LiveStreamKind,
        consumer: LiveStreamConsumer
    ) async throws -> LiveStreamConsumerHandle {
        guard historySafetyPassed else { throw LiveStreamError.historySafetyRequired }

        let id = UUID()
        let existingCount = consumerIDs[kind, default: []].count
        consumerIDs[kind, default: []].insert(id)
        consumersByID[id] = kind

        if let policySink = commandSink as? any LiveStreamPolicyCommandSink {
            do {
                let previousEffective = effectiveEnabledKinds().subtracting([kind])
                try await policySink.reconcileLiveStreams(
                    previousEffectiveKinds: previousEffective,
                    requestedKinds: enabledKinds(),
                    effectiveKinds: effectiveEnabledKinds(),
                    policy: backgroundPolicy
                )
                commandEnabledKinds = effectiveEnabledKinds()
            } catch {
                consumerIDs[kind, default: []].remove(id)
                consumersByID.removeValue(forKey: id)
                throw LiveStreamError.commandFailed(String(describing: error))
            }
            return LiveStreamConsumerHandle(
                id: id,
                kind: kind,
                consumer: consumer,
                releaseAction: { [weak self] in
                    await self?.release(id: id)
                }
            )
        }

        if effectiveEnabledKinds().contains(kind),
           !commandEnabledKinds.contains(kind) {
            do {
                try await commandSink.setLiveStream(kind, enabled: true)
                commandEnabledKinds.insert(kind)
            } catch {
                if existingCount == 0 {
                    consumerIDs[kind, default: []].remove(id)
                    consumersByID.removeValue(forKey: id)
                }
                throw LiveStreamError.commandFailed(String(describing: error))
            }
        }

        return LiveStreamConsumerHandle(
            id: id,
            kind: kind,
            consumer: consumer,
            releaseAction: { [weak self] in
                await self?.release(id: id)
            }
        )
    }

    /// Acquires a consumer and a bounded typed event stream as one ownership
    /// operation. The returned subscription is generation-pinned; events from
    /// another connection generation are ignored before they reach the
    /// feature. The existing `acquire`/`bufferedSamples` APIs remain unchanged
    /// for polling consumers.
    public func acquireEventStream(
        kind: LiveStreamKind,
        consumer: LiveStreamConsumer,
        generation: UInt64,
        eventBufferCapacity: Int? = nil
    ) async throws -> LiveStreamEventSubscription {
        let handle = try await acquire(kind: kind, consumer: consumer)
        let id = UUID()
        let capacity = max(1, eventBufferCapacity ?? self.eventBufferCapacity)
        let (stream, continuation) = AsyncStream<LiveStreamEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(capacity)
        )
        eventSubscribers[id] = EventSubscriber(
            kind: kind,
            generation: generation,
            continuation: continuation,
            handle: handle
        )
        continuation.onTermination = { [weak self] _ in
            Task { await self?.cancelEventSubscription(id: id) }
        }

        return LiveStreamEventSubscription(
            id: id,
            kind: kind,
            consumer: consumer,
            generation: generation,
            stream: stream,
            cancelAction: { [weak self] in
                guard let self else { return false }
                return await self.cancelEventSubscription(id: id)
            }
        )
    }

    @discardableResult
    private func cancelEventSubscription(id: UUID) async -> Bool {
        guard let subscriber = eventSubscribers.removeValue(forKey: id) else {
            return false
        }
        subscriber.continuation.finish()
        _ = await subscriber.handle.release()
        return true
    }

    /// Releases a live consumer.  The command sink is called only when the
    /// last consumer for a kind leaves.
    @discardableResult
    public func release(id: UUID) async -> Bool {
        guard let kind = consumersByID.removeValue(forKey: id),
              var IDs = consumerIDs[kind],
              IDs.remove(id) != nil else {
            return false
        }

        consumerIDs[kind] = IDs
        if IDs.isEmpty {
            if let policySink = commandSink as? any LiveStreamPolicyCommandSink {
                do {
                    try await policySink.reconcileLiveStreams(
                        previousEffectiveKinds: commandEnabledKinds,
                        requestedKinds: enabledKinds(),
                        effectiveKinds: effectiveEnabledKinds(),
                        policy: backgroundPolicy
                    )
                    commandEnabledKinds = effectiveEnabledKinds()
                } catch {
                    // Keep the last known-good wire state; the release remains
                    // truthful and the next aggregate transition retries it.
                }
                return true
            }
            if commandEnabledKinds.contains(kind) {
                do {
                    try await commandSink.setLiveStream(kind, enabled: false)
                    commandEnabledKinds.remove(kind)
                } catch {
                    // A failed disable must not resurrect a consumer. The
                    // transport/session owner will retry as part of disconnect
                    // cleanup; the manager remains truthful about ownership.
                }
            }
        }
        return true
    }

    public func consumerCount(for kind: LiveStreamKind) -> Int {
        consumerIDs[kind, default: []].count
    }

    public func totalConsumerCount() -> Int {
        consumerIDs.values.reduce(0) { $0 + $1.count }
    }

    public func enabledKinds() -> Set<LiveStreamKind> {
        Set(consumerIDs.compactMap { $0.value.isEmpty ? nil : $0.key })
    }

    /// Kinds that policy currently permits on the wire. This can be smaller
    /// than `enabledKinds()` while background ownership is retained.
    public func effectiveEnabledKinds() -> Set<LiveStreamKind> {
        let requested = enabledKinds()
        switch backgroundPolicy {
        case .foreground:
            return requested
        case .ordinaryBackground:
            return requested.intersection([.compactHeartRateRR])
        }
    }

    /// Adds one live packet to the bounded RAM buffer.  Packets received while
    /// no feature owns the stream are intentionally discarded.
    public func ingest(
        kind: LiveStreamKind,
        payload: Data,
        receivedAt: Date,
        generation: UInt64 = 0
    ) {
        guard consumerCount(for: kind) > 0 else { return }
        var buffer = buffers[kind, default: []]
        buffer.append(LiveStreamSample(kind: kind, payload: payload, receivedAt: receivedAt))
        if buffer.count > bufferCapacity {
            buffer.removeFirst(buffer.count - bufferCapacity)
        }
        buffers[kind] = buffer
        latestTimes[kind] = receivedAt
        packetCountsSinceSummary[kind, default: 0] += 1

        let event = LiveStreamEvent(
            kind: kind,
            generation: generation,
            payload: payload,
            receivedAt: receivedAt
        )
        for subscriber in eventSubscribers.values
        where subscriber.kind == kind && subscriber.generation == generation {
            _ = subscriber.continuation.yield(event)
        }
    }

    public func bufferedSamples(for kind: LiveStreamKind) -> [LiveStreamSample] {
        buffers[kind, default: []]
    }

    /// Returns a throttled summary suitable for UI observation.  Raw packets
    /// are never exposed by this summary path.
    public func summary(
        for kind: LiveStreamKind,
        at now: Date,
        minimumInterval: TimeInterval = LiveStreamManager.defaultSummaryInterval
    ) -> LiveStreamSummary? {
        if let previous = lastSummaryAt[kind],
           now.timeIntervalSince(previous) < max(0, minimumInterval) {
            return nil
        }

        lastSummaryAt[kind] = now
        let count = packetCountsSinceSummary[kind, default: 0]
        packetCountsSinceSummary[kind] = 0
        return LiveStreamSummary(
            kind: kind,
            latestReceivedAt: latestTimes[kind],
            packetsSinceLastSummary: count,
            bufferedPacketCount: buffers[kind, default: []].count
        )
    }

    /// Clears buffers and releases every outstanding consumer.  This is used
    /// by disconnect/session replacement and is idempotent.
    public func reset() async {
        let eventHandles = finishEventSubscriptions()
        if let policySink = commandSink as? any LiveStreamPolicyCommandSink {
            try? await policySink.disableAllLiveStreams()
            commandEnabledKinds.removeAll(keepingCapacity: true)
            consumerIDs.removeAll(keepingCapacity: true)
            consumersByID.removeAll(keepingCapacity: true)
            buffers.removeAll(keepingCapacity: true)
            packetCountsSinceSummary.removeAll(keepingCapacity: true)
            latestTimes.removeAll(keepingCapacity: true)
            lastSummaryAt.removeAll(keepingCapacity: true)
            for handle in eventHandles { _ = await handle.release() }
            return
        }
        let kinds = Array(commandEnabledKinds)
        for kind in kinds {
            consumerIDs[kind] = []
            try? await commandSink.setLiveStream(kind, enabled: false)
        }
        commandEnabledKinds.removeAll(keepingCapacity: true)
        consumerIDs.removeAll(keepingCapacity: true)
        consumersByID.removeAll(keepingCapacity: true)
        buffers.removeAll(keepingCapacity: true)
        packetCountsSinceSummary.removeAll(keepingCapacity: true)
        latestTimes.removeAll(keepingCapacity: true)
        lastSummaryAt.removeAll(keepingCapacity: true)
        for handle in eventHandles { _ = await handle.release() }
    }

    private func finishEventSubscriptions() -> [LiveStreamConsumerHandle] {
        let subscribers = Array(eventSubscribers.values)
        eventSubscribers.removeAll(keepingCapacity: true)
        for subscriber in subscribers {
            subscriber.continuation.finish()
        }
        return subscribers.map(\.handle)
    }

    public func withConsumer<T: Sendable>(
        kind: LiveStreamKind,
        consumer: LiveStreamConsumer,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let handle = try await acquire(kind: kind, consumer: consumer)
        do {
            let result = try await operation()
            await handle.release()
            return result
        } catch {
            await handle.release()
            throw error
        }
    }
}
