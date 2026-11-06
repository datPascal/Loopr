import Foundation

// LV-06.3 and DEC-12.14: the capacity test flows. Every type here is a plain value that takes its time
// from the caller, so each step of a flow can be tested on an injected clock. A timer records the
// moment it started and works out the elapsed time from timestamps, never from a running counter, so
// sending Loopr to the background and back neither loses nor stretches a run.

// MARK: - Timed tests

/// The phone's timer for dead hang and one-leg balance: Start, a 3-2-1 lead-in, then the run until Stop.
public struct CapacityTimer: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case ready
        /// Counting down to the start. The run starts at `startsAt`.
        case leadIn(startsAt: Date)
        case running(startedAt: Date)
        /// A finished run of `seconds`.
        case stopped(seconds: Double)
    }

    /// Seconds of 3-2-1 before the run.
    public static let leadInSeconds = 3.0
    /// A stop inside the first second is a mis-tap, not a result.
    public static let minimumSeconds = 1.0
    /// Balance plays a tick every ten seconds.
    public static let tickEvery = 10.0

    public private(set) var phase: Phase = .ready
    /// True after a stop under a second. Cleared by the next start.
    public private(set) var rejectedMisTap = false
    /// True when Loopr went to the background during the current run.
    public private(set) var wasBackgrounded = false
    public let leadIn: Double

    public init(leadIn: Double = CapacityTimer.leadInSeconds) {
        self.leadIn = max(leadIn, 0)
    }

    /// The phase at `now`: a lead-in whose time has come is a run that started when the countdown ended.
    public func resolved(at now: Date) -> Phase {
        if case .leadIn(let startsAt) = phase, now >= startsAt { return .running(startedAt: startsAt) }
        return phase
    }

    public mutating func start(at now: Date) {
        guard resolved(at: now) == .ready || isStopped else { return }
        rejectedMisTap = false
        wasBackgrounded = false
        phase = leadIn > 0 ? .leadIn(startsAt: now.addingTimeInterval(leadIn)) : .running(startedAt: now)
    }

    /// Stops the run. During the lead-in it cancels back to ready. A run under a second is refused as a
    /// mis-tap and the timer goes back to ready.
    public mutating func stop(at now: Date) {
        switch resolved(at: now) {
        case .leadIn:
            phase = .ready
        case .running(let startedAt):
            let seconds = now.timeIntervalSince(startedAt)
            if seconds < Self.minimumSeconds {
                phase = .ready
                rejectedMisTap = true
            } else {
                phase = .stopped(seconds: seconds)
            }
        case .ready, .stopped:
            break
        }
    }

    /// Back to ready, dropping a stopped result.
    public mutating func reset() {
        phase = .ready
        rejectedMisTap = false
        wasBackgrounded = false
    }

    /// The scene went to the background. Nothing is paused: the run keeps its start time.
    public mutating func enterBackground(at now: Date) {
        switch resolved(at: now) {
        case .leadIn, .running: wasBackgrounded = true
        case .ready, .stopped: break
        }
    }

    /// Back in the foreground: the phase is worked out again from the timestamps.
    public mutating func enterForeground(at now: Date) {
        phase = resolved(at: now)
    }

    /// Seconds into the run, 0 before it starts.
    public func elapsed(at now: Date) -> Double {
        switch resolved(at: now) {
        case .ready, .leadIn: 0
        case .running(let startedAt): max(now.timeIntervalSince(startedAt), 0)
        case .stopped(let seconds): seconds
        }
    }

    /// 3, 2 or 1 during the lead-in. Nil otherwise.
    public func countdown(at now: Date) -> Int? {
        guard case .leadIn(let startsAt) = resolved(at: now) else { return nil }
        return max(Int(startsAt.timeIntervalSince(now).rounded(.up)), 1)
    }

    /// Whole ten-second marks passed in the run, for the balance ticks.
    public func ticks(at now: Date) -> Int {
        guard case .running = resolved(at: now) else { return 0 }
        return Int((elapsed(at: now) / Self.tickEvery).rounded(.down))
    }

    public var isStopped: Bool {
        if case .stopped = phase { return true }
        return false
    }

    public var result: Double? {
        if case .stopped(let seconds) = phase { return seconds }
        return nil
    }

    /// The run as a capacity result, rounded to a tenth of a second. Nil before a stop.
    public func capacityResult(kind: CapacityTestKind, side: CapacitySide?, at now: Date,
                               timeZoneIdentifier: String) throws -> CapacityResult? {
        guard let seconds = result else { return nil }
        let value = min((seconds * 10).rounded() / 10, kind.validRange.upperBound)
        return try CapacityResult(kind: kind, value: value, side: kind.requiresSide ? side : nil, recordedAt: now,
                                  timeZoneIdentifier: timeZoneIdentifier, source: .timed)
    }
}

// MARK: - Grip

/// Grip typed in from a dynamometer: up to three trials per hand, and the best of each hand is saved as
/// that hand's result.
public struct GripTrials: Equatable, Sendable {
    public static let maximumTrials = 3
    /// Dynamometers read to half a kilogram.
    public static let step = 0.5
    public static let range: ClosedRange<Double> = 1...150

    public private(set) var trials: [CapacitySide: [Double]] = [:]

    public init(trials: [CapacitySide: [Double]] = [:]) {
        for (side, values) in trials { self.trials[side] = Array(values.prefix(Self.maximumTrials)) }
    }

    public func trials(_ side: CapacitySide) -> [Double] { trials[side] ?? [] }

    public func canAdd(_ side: CapacitySide) -> Bool { trials(side).count < Self.maximumTrials }

    /// A value on the half-kilogram grid inside the dynamometer's range.
    public static func snapped(_ value: Double) -> Double {
        guard value.isFinite else { return range.lowerBound }
        return min(max((value / step).rounded() * step, range.lowerBound), range.upperBound)
    }

    /// Adds a trial, snapped to half a kilogram. False when the hand already has three.
    @discardableResult
    public mutating func add(_ value: Double, side: CapacitySide) -> Bool {
        guard canAdd(side) else { return false }
        trials[side, default: []].append(Self.snapped(value))
        return true
    }

    public mutating func remove(at index: Int, side: CapacitySide) {
        guard trials(side).indices.contains(index) else { return }
        trials[side]?.remove(at: index)
    }

    public func best(_ side: CapacitySide) -> Double? { trials(side).max() }

    /// The best of both hands, as the tile shows it.
    public var best: Double? { CapacitySide.allCases.compactMap(best).max() }

    public var hasTrials: Bool { best != nil }

    /// One result per hand that has a trial, left first.
    public func results(at now: Date, timeZoneIdentifier: String) throws -> [CapacityResult] {
        try CapacitySide.allCases.compactMap { side in
            guard let value = best(side) else { return nil }
            return try CapacityResult(kind: .grip, value: value, side: side, recordedAt: now,
                                      timeZoneIdentifier: timeZoneIdentifier, source: .typed)
        }
    }
}

// MARK: - Sit to stand

/// The sitting-rising test, self-scored: five points for sitting down to the floor and five for standing
/// back up. Each support used takes off a point, and a visible loss of balance takes off half a point
/// (Araujo's test, as used by Brito et al. 2014).
public struct SitToStandScore: Equatable, Sendable {
    public static let phaseMaximum = 5.0
    public static let step = 0.5

    /// Nil until the person scores that half. A half is not assumed to be perfect: an untested score is not a 10.
    public private(set) var sitting: Double?
    public private(set) var rising: Double?

    public init(sitting: Double? = nil, rising: Double? = nil) {
        self.sitting = sitting.map(Self.snapped)
        self.rising = rising.map(Self.snapped)
    }

    /// Both halves added, or nil while either is still unscored.
    public var total: Double? {
        guard let sitting, let rising else { return nil }
        return sitting + rising
    }

    public var isComplete: Bool { total != nil }

    public mutating func setSitting(_ value: Double) { sitting = Self.snapped(value) }
    public mutating func setRising(_ value: Double) { rising = Self.snapped(value) }

    /// A half-point score from 0 to 5.
    public static func snapped(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max((value / step).rounded() * step, 0), phaseMaximum)
    }

    /// The rules as the screen lists them.
    public static let rules = [
        "Start standing, then sit down to the floor and stand back up.",
        "Each half starts at 5 points.",
        "Take off 1 point for each hand, forearm, knee or side of a leg that helps you, and for a hand on a knee or thigh.",
        "Take off half a point for each wobble or loss of balance."
    ]

    /// Throws `CapacityError.missingResult` until both halves are scored.
    public func result(at now: Date, timeZoneIdentifier: String) throws -> CapacityResult {
        guard let total else { throw CapacityError.missingResult }
        return try CapacityResult(kind: .sitToStand, value: total, recordedAt: now, timeZoneIdentifier: timeZoneIdentifier,
                           source: .typed)
    }
}

// MARK: - Goals at 85

/// The ruler a goal for 85 is set on, per test.
public struct CapacityGoalScale: Equatable, Sendable {
    public let range: ClosedRange<Double>
    public let step: Double
    /// Steps between labelled ticks.
    public let majorEvery: Int
    /// What the ruler shows before a goal or a result exists.
    public let defaultValue: Double

    public static func scale(for kind: CapacityTestKind) -> CapacityGoalScale? {
        switch kind {
        case .grip: CapacityGoalScale(range: 5...100, step: 0.5, majorEvery: 10, defaultValue: 30)
        case .deadHang: CapacityGoalScale(range: 5...300, step: 5, majorEvery: 6, defaultValue: 60)
        case .sitToStand: CapacityGoalScale(range: 0.5...10, step: 0.5, majorEvery: 2, defaultValue: 8)
        case .oneLegBalance: CapacityGoalScale(range: 1...120, step: 1, majorEvery: 10, defaultValue: 10)
        case .heartRateRecovery: nil
        }
    }

    /// Where the ruler starts: the goal set before, else today's best, else the default, on the grid.
    public func initialValue(goal: Double?, best: Double?) -> Double {
        snapped(goal ?? best ?? defaultValue)
    }

    public func snapped(_ value: Double) -> Double {
        guard value.isFinite else { return defaultValue }
        return min(max((value / step).rounded() * step, range.lowerBound), range.upperBound)
    }

    public func goal(kind: CapacityTestKind, value: Double, at now: Date) throws -> CapacityGoal {
        try CapacityGoal(kind: kind, targetValue: snapped(value), setAt: now)
    }
}

// MARK: - Saving

/// What a saved flow hands back to the Fitness screen, so the result can fly into its tile.
public struct CapacityFlowOutcome: Equatable, Sendable {
    public let kind: CapacityTestKind
    /// The tile's value before the save. Nil before the first result.
    public let previousBest: Double?
    /// The best of what was just saved.
    public let newBest: Double
    /// True when the new best meets or beats the person's own goal for 85.
    public let meetsGoal: Bool

    public init(kind: CapacityTestKind, previousBest: Double?, results: [CapacityResult], goal: Double?) throws {
        guard let best = results.filter({ $0.kind == kind }).map(\.value).max() else { throw CapacityError.missingResult }
        self.kind = kind
        self.previousBest = previousBest
        newBest = best
        meetsGoal = goal.map { best >= $0 } ?? false
    }

    /// Dots that fly into the tile: more for a bigger number, never fewer than 8 or more than 20.
    public var dotCount: Int {
        let scale = FitnessOverview.instrumentScale(kind, best: newBest, goal: nil)
        return min(max(Int((newBest / scale * 20).rounded()), 8), 20)
    }
}
