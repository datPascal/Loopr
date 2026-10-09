import BluetoothKit
import Foundation

/// Stops the reconnect loop when iOS repeatedly leaves the first encrypted
/// setup write waiting on an unanswered pairing prompt.
public struct SetupWriteTimeoutLoopDetector: Equatable, Sendable {
    public let threshold: Int
    public private(set) var consecutiveTimeouts: Int = 0
    public private(set) var isPaused = false

    public init(threshold: Int = 3) { self.threshold = max(1, threshold) }

    @discardableResult
    public mutating func recordTimeout() -> Bool {
        guard !isPaused else { return false }
        consecutiveTimeouts += 1
        if consecutiveTimeouts >= threshold { isPaused = true; return true }
        return false
    }

    public mutating func recordSuccess() {
        consecutiveTimeouts = 0
        isPaused = false
    }
}

public enum BluetoothBondRepairReason: String, Codable, Equatable, Sendable {
    case firstWriteTimeoutLoop
    case insufficientAuthentication
    case insufficientEncryption
    case peerRemovedPairing
}

/// Converts only source-observed bond failures into a latched repair state.
/// Other write and link failures continue through the ordinary reconnect path.
public struct SetupBondRecoveryPolicy: Equatable, Sendable {
    private var timeoutDetector: SetupWriteTimeoutLoopDetector
    public private(set) var requiredRepair: BluetoothBondRepairReason?

    public init(timeoutThreshold: Int = 3) {
        timeoutDetector = SetupWriteTimeoutLoopDetector(threshold: timeoutThreshold)
    }

    public var consecutiveFirstWriteTimeouts: Int {
        timeoutDetector.consecutiveTimeouts
    }

    @discardableResult
    public mutating func recordFirstWriteTimeout() -> BluetoothBondRepairReason? {
        guard timeoutDetector.recordTimeout() else { return nil }
        requiredRepair = .firstWriteTimeoutLoop
        return requiredRepair
    }

    public mutating func recordFirstWriteSuccess() {
        timeoutDetector.recordSuccess()
        requiredRepair = nil
    }

    @discardableResult
    public mutating func recordTransportFailure(
        _ error: TransportError
    ) -> BluetoothBondRepairReason? {
        let reason: BluetoothBondRepairReason?
        switch error {
        case .insufficientAuthentication:
            reason = .insufficientAuthentication
        case .insufficientEncryption:
            reason = .insufficientEncryption
        case .peerRemovedPairing:
            reason = .peerRemovedPairing
        default:
            reason = nil
        }
        if let reason { requiredRepair = reason }
        return reason
    }
}

/// Radio state projected by the CoreBluetooth adapter.  Bluetooth-off,
/// unauthorized, and out-of-range are intentionally separate outcomes.
public enum ConnectionRadioState: String, Codable, CaseIterable, Sendable {
    case unknown
    case poweredOn
    case poweredOff
    case unauthorized
    case unsupported
    case resetting
    case outOfRange
}

/// A rolling corruption snapshot matching the OpenStrap Edge link-health
/// policy: at least 20 samples in a 50-frame window and a corruption rate of
/// 20% or greater is unhealthy.  The snapshot is deliberately derived from a
/// rolling window rather than lifetime counters so a healthy stream can
/// recover after old bad frames age out.
public struct ConnectionCorruptionState: Equatable, Sendable {
    public let windowSize: Int
    public let minimumSamples: Int
    public let threshold: Double
    public let sampleCount: Int
    public let corruptCount: Int

    public init(
        windowSize: Int = 50,
        minimumSamples: Int = 20,
        threshold: Double = 0.20,
        sampleCount: Int = 0,
        corruptCount: Int = 0
    ) {
        let boundedWindow = max(1, windowSize)
        self.windowSize = boundedWindow
        self.minimumSamples = min(max(1, minimumSamples), boundedWindow)
        self.threshold = min(max(0, threshold), 1)
        self.sampleCount = min(max(0, sampleCount), boundedWindow)
        self.corruptCount = min(max(0, corruptCount), self.sampleCount)
    }

    public var corruptionRate: Double {
        guard sampleCount > 0 else { return 0 }
        return Double(corruptCount) / Double(sampleCount)
    }

    public var thresholdExceeded: Bool {
        sampleCount >= minimumSamples && corruptionRate >= threshold
    }
}

/// Mutable simulator-friendly implementation of Edge's rolling corruption
/// detector.  It has no sticky fault bit: once invalid frames leave the
/// window, `thresholdExceeded` can become false again without reconnecting.
public struct RollingCorruptionDetector: Sendable {
    public static let defaultWindowSize = 50
    public static let defaultMinimumSamples = 20
    public static let defaultThreshold = 0.20

    private let windowSize: Int
    private let minimumSamples: Int
    private let threshold: Double
    private var samples: [Bool] = []

    public init(
        windowSize: Int = RollingCorruptionDetector.defaultWindowSize,
        minimumSamples: Int = RollingCorruptionDetector.defaultMinimumSamples,
        threshold: Double = RollingCorruptionDetector.defaultThreshold
    ) {
        let boundedWindow = max(1, windowSize)
        self.windowSize = boundedWindow
        self.minimumSamples = min(max(1, minimumSamples), boundedWindow)
        self.threshold = min(max(0, threshold), 1)
    }

    @discardableResult
    public mutating func record(validFrame: Bool) -> ConnectionCorruptionState {
        samples.append(validFrame)
        if samples.count > windowSize {
            samples.removeFirst(samples.count - windowSize)
        }
        return snapshot()
    }

    @discardableResult
    public mutating func observe(validFrame: Bool) -> ConnectionCorruptionState {
        record(validFrame: validFrame)
    }

    public func snapshot() -> ConnectionCorruptionState {
        ConnectionCorruptionState(
            windowSize: windowSize,
            minimumSamples: minimumSamples,
            threshold: threshold,
            sampleCount: samples.count,
            corruptCount: samples.reduce(into: 0) { count, valid in
                if !valid { count += 1 }
            }
        )
    }

    public mutating func reset() { samples.removeAll(keepingCapacity: true) }
}

public struct ConnectionLivenessInput: Equatable, Sendable {
    public let radioState: ConnectionRadioState
    public let lastValidFrameAt: Date?
    public let lastHistoricalCommitAt: Date?
    public let validFrameCount: UInt64
    public let corruptFrameCount: UInt64
    public let writeTimeoutCount: UInt64
    public let expectedCharacteristicsReady: Bool
    public let rollingCorruption: ConnectionCorruptionState?

    public init(
        radioState: ConnectionRadioState,
        lastValidFrameAt: Date?,
        lastHistoricalCommitAt: Date?,
        validFrameCount: UInt64 = 0,
        corruptFrameCount: UInt64 = 0,
        writeTimeoutCount: UInt64 = 0,
        expectedCharacteristicsReady: Bool,
        rollingCorruption: ConnectionCorruptionState? = nil
    ) {
        self.radioState = radioState
        self.lastValidFrameAt = lastValidFrameAt
        self.lastHistoricalCommitAt = lastHistoricalCommitAt
        self.validFrameCount = validFrameCount
        self.corruptFrameCount = corruptFrameCount
        self.writeTimeoutCount = writeTimeoutCount
        self.expectedCharacteristicsReady = expectedCharacteristicsReady
        self.rollingCorruption = rollingCorruption
    }

    public var totalFrameCount: UInt64 { validFrameCount + corruptFrameCount }

    public var corruptionRate: Double {
        if let rollingCorruption { return rollingCorruption.corruptionRate }
        guard totalFrameCount > 0 else { return 0 }
        return Double(corruptFrameCount) / Double(totalFrameCount)
    }

    /// Link freshness is based only on valid inbound frames.  A historical
    /// commit proves storage progress but cannot mask a silent radio link.
    public var latestLinkObservationAt: Date? { lastValidFrameAt }

    /// Progress freshness is retained for diagnostics/UI and includes either
    /// valid RX or a durable historical commit.
    public var latestProgressObservationAt: Date? {
        switch (lastValidFrameAt, lastHistoricalCommitAt) {
        case let (frame?, commit?): return max(frame, commit)
        case let (frame?, nil): return frame
        case let (nil, commit?): return commit
        case (nil, nil): return nil
        }
    }

    /// Compatibility alias for callers that used the pre-parity name.
    public var latestObservationAt: Date? {
        latestProgressObservationAt
    }
}

public enum ConnectionHealthReason: String, Codable, CaseIterable, Sendable {
    case radioUnavailable
    case outOfRange
    case characteristicsNotReady
    case noValidFrame
    case staleObservation
    case corruptionObserved
    case writeTimeoutObserved
}

public struct ConnectionHealthReport: Equatable, Sendable {
    public let healthy: Bool
    public let stale: Bool
    public let shouldBounce: Bool
    public let ageOfLatestObservation: TimeInterval?
    public let ageOfLastValidFrame: TimeInterval?
    public let ageOfLastHistoricalCommit: TimeInterval?
    public let corruptionRate: Double
    public let reasons: Set<ConnectionHealthReason>

    public init(
        healthy: Bool,
        stale: Bool,
        shouldBounce: Bool,
        ageOfLatestObservation: TimeInterval?,
        corruptionRate: Double,
        reasons: Set<ConnectionHealthReason>,
        ageOfLastValidFrame: TimeInterval? = nil,
        ageOfLastHistoricalCommit: TimeInterval? = nil
    ) {
        self.healthy = healthy
        self.stale = stale
        self.shouldBounce = shouldBounce
        self.ageOfLatestObservation = ageOfLatestObservation
        self.ageOfLastValidFrame = ageOfLastValidFrame
        self.ageOfLastHistoricalCommit = ageOfLastHistoricalCommit
        self.corruptionRate = corruptionRate
        self.reasons = reasons
    }
}

/// Parity defaults copied from OpenStrap Edge Gate G.  They are public so
/// tests and callers cannot silently drift to a second set of timing values.
public enum ReconnectTimingDefaults {
    public static let staleConnectionReclamation: TimeInterval = 30
    public static let livenessBounce: TimeInterval = 120
    public static let periodicHistoryRequest: TimeInterval = 15 * 60
    public static let foregroundBackfillFloor: TimeInterval = 90
    public static let stalledOffloadDetection: TimeInterval = 60
    public static let continuationWindow: TimeInterval = 10 * 60
    public static let reconnectBackoff: [TimeInterval] = [2, 4, 8, 16, 30]
}

public struct ConnectionHealthEvaluator: Sendable {
    public let timing: ReconnectTimingDefaults.Type

    public init() { timing = ReconnectTimingDefaults.self }

    public func evaluate(
        input: ConnectionLivenessInput,
        now: Date
    ) -> ConnectionHealthReport {
        var reasons = Set<ConnectionHealthReason>()

        switch input.radioState {
        case .poweredOn:
            break
        case .outOfRange:
            reasons.insert(.outOfRange)
        case .unknown, .poweredOff, .unauthorized, .unsupported, .resetting:
            reasons.insert(.radioUnavailable)
        }

        if !input.expectedCharacteristicsReady {
            reasons.insert(.characteristicsNotReady)
        }

        func age(of observation: Date?) -> TimeInterval? {
            guard let observation else { return nil }
            // A future timestamp from a clock transition is not allowed to
            // make silence look healthy.  Treat it as observed now, while the
            // clock-correlation layer investigates the discrepancy.
            return max(0, now.timeIntervalSince(observation))
        }

        let linkAge = age(of: input.latestLinkObservationAt)
        let progressAge = age(of: input.latestProgressObservationAt)
        if linkAge == nil {
            reasons.insert(.noValidFrame)
        }

        if let linkAge, linkAge >= ReconnectTimingDefaults.staleConnectionReclamation {
            reasons.insert(.staleObservation)
        }
        let corruption = input.rollingCorruption ?? ConnectionCorruptionState(
            sampleCount: Int(min(input.totalFrameCount, UInt64(Int.max))),
            corruptCount: Int(min(input.corruptFrameCount, UInt64(Int.max)))
        )
        if corruption.thresholdExceeded {
            reasons.insert(.corruptionObserved)
        }
        if input.writeTimeoutCount > 0 {
            reasons.insert(.writeTimeoutObserved)
        }

        let stale = reasons.contains(.staleObservation) || reasons.contains(.noValidFrame)
        let shouldBounce = linkAge.map { $0 >= ReconnectTimingDefaults.livenessBounce } ?? true
        let healthy = input.radioState == .poweredOn
            && input.expectedCharacteristicsReady
            && !stale
            && !corruption.thresholdExceeded
            && input.writeTimeoutCount == 0

        return ConnectionHealthReport(
            healthy: healthy,
            stale: stale,
            shouldBounce: shouldBounce,
            ageOfLatestObservation: progressAge,
            corruptionRate: corruption.corruptionRate,
            reasons: reasons,
            ageOfLastValidFrame: linkAge,
            ageOfLastHistoricalCommit: age(of: input.lastHistoricalCommitAt)
        )
    }

    public func shouldReclaimStaleConnection(lastObservationAt: Date?, now: Date) -> Bool {
        guard let lastObservationAt else { return true }
        return now.timeIntervalSince(lastObservationAt) >= ReconnectTimingDefaults.staleConnectionReclamation
    }

    public func shouldLivenessBounce(lastObservationAt: Date?, now: Date) -> Bool {
        guard let lastObservationAt else { return true }
        return now.timeIntervalSince(lastObservationAt) >= ReconnectTimingDefaults.livenessBounce
    }

    public func shouldRequestPeriodicHistory(lastRequestAt: Date?, now: Date) -> Bool {
        guard let lastRequestAt else { return true }
        return now.timeIntervalSince(lastRequestAt) >= ReconnectTimingDefaults.periodicHistoryRequest
    }

    public func foregroundBackfillAllowed(lastRequestAt: Date?, now: Date) -> Bool {
        guard let lastRequestAt else { return true }
        return now.timeIntervalSince(lastRequestAt) >= ReconnectTimingDefaults.foregroundBackfillFloor
    }

    public func offloadIsStalled(startedAt: Date?, now: Date) -> Bool {
        guard let startedAt else { return false }
        return now.timeIntervalSince(startedAt) >= ReconnectTimingDefaults.stalledOffloadDetection
    }

    public func continuationExpired(startedAt: Date?, now: Date) -> Bool {
        guard let startedAt else { return false }
        return now.timeIntervalSince(startedAt) >= ReconnectTimingDefaults.continuationWindow
    }
}

public struct ReconnectRequest: Equatable, Sendable {
    public let id: UUID
    public let generation: UInt64
    public let attempt: Int
    public let delay: TimeInterval
    public let requestedAt: Date

    public init(
        id: UUID,
        generation: UInt64,
        attempt: Int,
        delay: TimeInterval,
        requestedAt: Date
    ) {
        self.id = id
        self.generation = generation
        self.attempt = attempt
        self.delay = delay
        self.requestedAt = requestedAt
    }
}

public protocol ReconnectJitterSource: Sendable {
    func jitter(forAttempt attempt: Int) -> TimeInterval
}

public struct FixedReconnectJitter: ReconnectJitterSource {
    public let value: TimeInterval

    public init(value: TimeInterval = 0) { self.value = value }

    public func jitter(forAttempt attempt: Int) -> TimeInterval { value }
}

/// Randomness seam for the Edge-bounded jitter calculation.  Tests can inject
/// a deterministic source while production uses the system RNG.
public protocol ReconnectRandomSource: Sendable {
    func nextInt(in range: ClosedRange<Int>) -> Int
}

public struct SystemReconnectRandom: ReconnectRandomSource {
    public init() {}

    public func nextInt(in range: ClosedRange<Int>) -> Int {
        Int.random(in: range)
    }
}

public struct FixedReconnectRandom: ReconnectRandomSource {
    public let value: Int

    public init(value: Int) { self.value = value }

    public func nextInt(in range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

public protocol ReconnectScheduling: Sendable {
    func scheduleReconnect(_ request: ReconnectRequest) async
    func cancelReconnect(_ request: ReconnectRequest) async
}

public struct NoopReconnectScheduler: ReconnectScheduling {
    public init() {}

    public func scheduleReconnect(_ request: ReconnectRequest) async {}
    public func cancelReconnect(_ request: ReconnectRequest) async {}
}

/// Pure backoff math.  Attempts are zero-based and saturate at the final
/// 30-second parity default; jitter is injected rather than generated here so
/// tests remain deterministic and disconnect storms cannot synchronize.
public struct ReconnectPolicy: Sendable {
    public static let edgeJitterFraction = 0.20

    public init() {}

    public func baseDelay(forAttempt attempt: Int) -> TimeInterval {
        guard !ReconnectTimingDefaults.reconnectBackoff.isEmpty else { return 0 }
        let index = min(max(0, attempt), ReconnectTimingDefaults.reconnectBackoff.count - 1)
        return ReconnectTimingDefaults.reconnectBackoff[index]
    }

    public func delay(forAttempt attempt: Int, jitter: TimeInterval = 0) -> TimeInterval {
        max(0, baseDelay(forAttempt: attempt) + jitter)
    }

    /// Returns Edge's one-based attempt delay with integer-millisecond jitter
    /// bounded to the global 2–30 second backoff range.  The legacy additive
    /// `jitter` overload remains available for callers that explicitly inject
    /// that older test seam.
    public func delay(
        forAttempt attempt: Int,
        random: any ReconnectRandomSource
    ) -> TimeInterval {
        let normalizedAttempt = max(1, attempt)
        let baseMilliseconds = Int((baseDelay(forAttempt: normalizedAttempt - 1) * 1_000).rounded())
        let span = Int((Double(baseMilliseconds) * Self.edgeJitterFraction).rounded())
        let delta = random.nextInt(in: -span...span)
        let minimum = Int(((ReconnectTimingDefaults.reconnectBackoff.first ?? 0) * 1_000).rounded())
        let maximum = Int(((ReconnectTimingDefaults.reconnectBackoff.last ?? 0) * 1_000).rounded())
        let bounded = min(max(baseMilliseconds + delta, minimum), maximum)
        return Double(bounded) / 1_000
    }
}

/// Serializes reconnect scheduling and drops duplicate disconnect callbacks.
/// At most one reconnect request can be pending, which prevents a disconnect
/// storm from producing a thundering herd of connects.
public actor ReconnectController {
    private let scheduler: any ReconnectScheduling
    private let jitterSource: (any ReconnectJitterSource)?
    private let randomSource: any ReconnectRandomSource
    private let policy: ReconnectPolicy
    private let makeID: @Sendable () -> UUID
    private var pending: ReconnectRequest?
    private var attempt = 0
    private var currentGeneration: UInt64?

    public init(
        scheduler: any ReconnectScheduling = NoopReconnectScheduler(),
        jitterSource: (any ReconnectJitterSource)? = nil,
        randomSource: any ReconnectRandomSource = SystemReconnectRandom(),
        policy: ReconnectPolicy = ReconnectPolicy(),
        makeID: @escaping @Sendable () -> UUID = { UUID() }
    ) {
        self.scheduler = scheduler
        self.jitterSource = jitterSource
        self.randomSource = randomSource
        self.policy = policy
        self.makeID = makeID
    }

    public func pendingRequest() -> ReconnectRequest? { pending }
    public func currentAttempt() -> Int { attempt }

    /// Requests one reconnect for a generation.  Duplicate callbacks while a
    /// request is pending return `nil`; the existing request remains the sole
    /// scheduled operation.
    @discardableResult
    public func disconnected(
        generation: UInt64,
        now: Date
    ) async -> ReconnectRequest? {
        guard pending == nil else { return nil }
        if let currentGeneration, generation < currentGeneration { return nil }
        // Every retry allocates a new generation, so resetting here pinned
        // the delay at the 2-second floor. Only `connected` and `reset`
        // clear the counter.
        currentGeneration = generation

        let delay: TimeInterval
        if let jitterSource {
            delay = policy.delay(
                forAttempt: attempt,
                jitter: jitterSource.jitter(forAttempt: attempt)
            )
        } else {
            delay = policy.delay(forAttempt: attempt + 1, random: randomSource)
        }

        let request = ReconnectRequest(
            id: makeID(),
            generation: generation,
            attempt: attempt,
            delay: delay,
            requestedAt: now
        )
        pending = request
        attempt = min(attempt + 1, ReconnectTimingDefaults.reconnectBackoff.count - 1)
        await scheduler.scheduleReconnect(request)
        return request
    }

    /// Marks a request as consumed.  A stale timer cannot consume a newer
    /// request because its UUID and generation must both match.
    @discardableResult
    public func consume(_ request: ReconnectRequest) -> Bool {
        guard pending?.id == request.id,
              pending?.generation == request.generation else { return false }
        pending = nil
        return true
    }

    public func connected(generation: UInt64) async {
        // Every reconnect allocates a newer generation than the one that
        // dropped, so an equality check here never matched on a real band
        // and the backoff stayed escalated after a successful setup.
        if let currentGeneration, generation < currentGeneration { return }
        attempt = 0
        currentGeneration = nil
        guard let request = pending, request.generation <= generation else { return }
        pending = nil
        await scheduler.cancelReconnect(request)
    }

    public func reset() async {
        if let request = pending {
            await scheduler.cancelReconnect(request)
        }
        pending = nil
        attempt = 0
        currentGeneration = nil
    }
}
