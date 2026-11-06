import Foundation

/// One work phase of an interval timer session.
public struct WorkoutEffortWindow: Codable, Equatable, Sendable {
    public let round: Int
    public let start: Date
    public let end: Date
    public init(round: Int, start: Date, end: Date) { self.round = round; self.start = start; self.end = end }
}

public extension ActivityType {
    /// Lengths and a pool size stand in for a distance.
    var takesLengths: Bool { self == .swim }
    /// Calories read off a machine's display.
    var takesCalories: Bool { [.cardio, .rowing].contains(self) }
    /// GPS is recorded for these. Everything else never shows a map.
    var recordsRoute: Bool { [.run, .cycle, .walk, .hike].contains(self) }
    /// Steady sessions, where comparing the first half with the second means something.
    var showsDrift: Bool { [.run, .cycle, .walk, .hike, .cardio, .rowing].contains(self) }
    /// Sessions made of hard efforts, where efforts are looked for in the heart rate.
    var showsEfforts: Bool { [.hiit, .crossfit].contains(self) }
}

public extension WorkoutRecord {
    /// The size Loopr assumes until the person says otherwise.
    static let defaultPoolLengthMeters = 25

    /// A distance saved with the session, then counted lengths, then a typed distance.
    var resolvedDistanceMeters: Double? {
        if let measured = latestDistanceSample?.distanceMeters { return measured }
        if let lengths, lengths > 0 { return Double(lengths * (poolLengthMeters ?? Self.defaultPoolLengthMeters)) }
        return loggedDistanceMeters
    }
}
