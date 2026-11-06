import Foundation

// Fitness round 2 (R2-WOD-01, R2-DES-20): the clock a WOD runs on. For time counts up and stops at an optional
// cap; AMRAP counts down from its length. Both count rounds with one big button and the reps into the current
// round with a stepper, start after a 3-2-1 lead-in, and end with a score the WOD log can save. EMOM and Tabata
// stay on the interval timer. Everything here reads a passed-in date, so a suspended app wakes to the right time.

/// The two clocks a WOD can run on.
public enum WODClockKind: String, Equatable, Sendable {
    /// Counts up. A cap, when set, stops the clock and the score becomes rounds and reps.
    case forTime
    /// Counts down from the length. The score is rounds and reps.
    case amrap

    /// The clock for a format. Nil for EMOM, Tabata and Other, which run on the interval timer or no clock.
    public init?(format: WODFormat) {
        switch format {
        case .forTime, .roundsForTime: self = .forTime
        case .amrap: self = .amrap
        case .emom, .tabata, .other: return nil
        }
    }
}

/// What the clock runs: its kind, the cap or length, and the lead-in.
public struct WODClockSetup: Equatable, Sendable {
    public static let defaultLeadInSeconds = 3
    /// The AMRAP length when the log has none: 12 minutes, the log's own default.
    public static let defaultAMRAPSeconds = 12 * 60

    public let kind: WODClockKind
    /// The cap for For time (nil runs without one), the length for AMRAP (always set).
    public let limitSeconds: Int?
    public let leadInSeconds: Int

    public init(kind: WODClockKind, limitSeconds: Int?, leadInSeconds: Int = Self.defaultLeadInSeconds) {
        self.kind = kind
        let limit = limitSeconds.flatMap { $0 > 0 ? $0 : nil }
        self.limitSeconds = kind == .amrap ? (limit ?? Self.defaultAMRAPSeconds) : limit
        self.leadInSeconds = max(0, leadInSeconds)
    }

    /// The setup for the WOD log's format and cap in minutes. Nil when the format has no clock.
    public init?(format: WODFormat, capMinutes: Int?) {
        guard let kind = WODClockKind(format: format) else { return nil }
        self.init(kind: kind, limitSeconds: capMinutes.map { $0 * 60 })
    }

    /// "For time, 10 min cap", "For time, no cap", "AMRAP 12 min".
    public var summary: String {
        switch kind {
        case .forTime: "For time, " + (limitSeconds.map { "\(WODScore.clock($0)) cap" } ?? "no cap")
        case .amrap: "AMRAP " + (limitSeconds.map { $0 % 60 == 0 ? "\($0 / 60) min" : WODScore.clock($0) } ?? "")
        }
    }
}

/// Where the clock is.
public enum WODClockPhase: Equatable, Sendable {
    /// Counting in. The value is the number on screen: 3, 2, 1.
    case leadIn(Int)
    case running
    /// The cap or the AMRAP length ran out.
    case timeUp
    /// Finish was tapped before the time ran out.
    case finished
}

/// The clock at one moment.
public struct WODClockReading: Equatable, Sendable {
    public let phase: WODClockPhase
    /// Whole seconds since Go, never past the cap or length.
    public let elapsedSeconds: Int
    /// What the big numeral shows: the time so far for For time, the time left for AMRAP.
    public let displaySeconds: Int
}

/// A score from the clock, ready for the WOD log.
public struct WODClockResult: Equatable, Sendable {
    public let score: WODScore
    /// True when For time hit its cap. The score is then rounds and reps.
    public let capped: Bool
    /// Seconds from Go to the end.
    public let workSeconds: Int
    public let startedAt: Date
    public let endedAt: Date
}

/// One run of the clock: when it was started, the rounds and reps counted, and when it ended.
public struct WODClock: Equatable, Sendable {
    public let setup: WODClockSetup
    /// The tap on Start. Work starts after the lead-in, at `goAt`.
    public let startedAt: Date
    public private(set) var rounds = 0
    /// Reps into the round after the last full one.
    public private(set) var reps = 0
    /// Set by Finish, or when the time runs out.
    public private(set) var endedAt: Date?

    public static let maximumRounds = 999
    public static let maximumReps = 999

    public init(setup: WODClockSetup, startedAt: Date) {
        self.setup = setup
        self.startedAt = startedAt
    }

    public var goAt: Date { startedAt.addingTimeInterval(Double(setup.leadInSeconds)) }

    /// When the cap or the AMRAP length runs out. Nil for For time without a cap.
    public var limitAt: Date? { setup.limitSeconds.map { goAt.addingTimeInterval(Double($0)) } }

    public func reading(at date: Date) -> WODClockReading {
        let end = endedAt.map { min($0, date) } ?? date
        if end < goAt, endedAt == nil {
            let left = Int(ceil(goAt.timeIntervalSince(end)))
            return .init(phase: .leadIn(max(1, left)), elapsedSeconds: 0, displaySeconds: display(elapsed: 0))
        }
        let limit = setup.limitSeconds
        var elapsed = max(0, Int(floor(end.timeIntervalSince(goAt))))
        let timeUp = limit.map { elapsed >= $0 } ?? false
        if let limit { elapsed = min(elapsed, limit) }
        let phase: WODClockPhase = timeUp ? .timeUp : endedAt != nil ? .finished : .running
        return .init(phase: phase, elapsedSeconds: elapsed, displaySeconds: display(elapsed: elapsed))
    }

    private func display(elapsed: Int) -> Int {
        switch setup.kind {
        case .forTime: elapsed
        case .amrap: max(0, (setup.limitSeconds ?? 0) - elapsed)
        }
    }

    /// True once Finish was tapped or the time ran out at `date`.
    public func isOver(at date: Date) -> Bool {
        switch reading(at: date).phase {
        case .timeUp, .finished: true
        case .leadIn, .running: false
        }
    }

    /// One more full round. The reps into the round start again from zero.
    public mutating func addRound() {
        rounds = min(rounds + 1, Self.maximumRounds)
        reps = 0
    }

    /// Takes back a round tapped by mistake.
    public mutating func removeRound() { rounds = max(0, rounds - 1) }

    public mutating func stepReps(_ direction: Int) { reps = min(max(reps + direction, 0), Self.maximumReps) }

    /// Stops the clock at `date`, or at the cap when that came first. Finish during the lead-in ends at Go.
    public mutating func finish(at date: Date) {
        guard endedAt == nil else { return }
        let capped = limitAt.map { min(date, $0) } ?? date
        endedAt = max(capped, goAt)
    }

    /// Takes back a Finish tapped by mistake (R3-WOD-01): the clock runs on as if it never stopped. A clock that ran
    /// out of time stays over.
    public mutating func resume(at date: Date) {
        guard endedAt != nil, limitAt.map({ date < $0 }) ?? true else { return }
        endedAt = nil
    }

    /// The sound a reading calls for, compared with the reading a moment before (R3-WOD-02): a tick for each lead-in
    /// number, Go, a tone each full minute, a tick for each of the last 10 seconds before a limit, and the end.
    public func cue(from previous: WODClockReading?, to reading: WODClockReading) -> WODClockCue? {
        switch (previous?.phase, reading.phase) {
        case (_, .timeUp), (_, .finished):
            if case .timeUp? = previous?.phase { return nil }
            if case .finished? = previous?.phase { return nil }
            return .end
        case (_, .leadIn(let number)):
            if case .leadIn(let before)? = previous?.phase, before == number { return nil }
            return .tick
        case (.leadIn?, .running):
            return .go
        case (_, .running):
            guard let previous, reading.elapsedSeconds != previous.elapsedSeconds else { return nil }
            if let limit = setup.limitSeconds, limit - reading.elapsedSeconds <= 10, limit - reading.elapsedSeconds > 0 {
                return .tick
            }
            return reading.elapsedSeconds > 0 && reading.elapsedSeconds % 60 == 0 ? .minute : nil
        }
    }

    /// The score at `date`: the time for a For time finished inside its cap, otherwise the rounds and reps.
    public func result(at date: Date) -> WODClockResult {
        let reading = reading(at: date)
        let end = goAt.addingTimeInterval(Double(reading.elapsedSeconds))
        let capped = setup.kind == .forTime && reading.phase == .timeUp
        let score: WODScore = setup.kind == .forTime && !capped
            ? .time(seconds: reading.elapsedSeconds)
            : .roundsAndReps(rounds: rounds, reps: reps)
        return .init(score: score, capped: capped, workSeconds: reading.elapsedSeconds, startedAt: goAt, endedAt: end)
    }
}

/// A sound the WOD clock plays (R3-WOD-02).
public enum WODClockCue: Equatable, Sendable {
    case tick, go, minute, end
}
