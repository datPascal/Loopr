import Foundation

/// A straight line from today's best to the goal the person set for age 85. It is arithmetic between two points
/// the person chose or measured. It does not predict what will happen and it says nothing about health.
public struct CapacityTrajectory: Equatable, Sendable {
    public struct Point: Equatable, Sendable {
        public let date: Date
        public let value: Double
        public init(date: Date, value: Double) { self.date = date; self.value = value }
    }

    public let kind: CapacityTestKind
    public let start: Point
    /// The goal, on the person's 85th birthday.
    public let end: Point
    /// Negative when the goal is below today's best.
    public let changePerYear: Double
    /// True when today's best already meets or beats the goal.
    public let goalAlreadyMet: Bool

    public static let secondsPerYear: TimeInterval = 365.2425 * 86_400

    /// Nil without a best, a goal or a date of birth, and nil once the 85th birthday has passed.
    public static func make(kind: CapacityTestKind, best: Double?, goal: CapacityGoal?, dateOfBirth: Date?,
                            now: Date, calendar: Calendar) -> CapacityTrajectory? {
        guard let best, best.isFinite, let goal, goal.kind == kind, let dateOfBirth,
              let birthday = calendar.date(byAdding: .year, value: CapacityGoal.targetAge, to: dateOfBirth),
              birthday > now else { return nil }
        let years = birthday.timeIntervalSince(now) / secondsPerYear
        return CapacityTrajectory(kind: kind, start: Point(date: now, value: best),
            end: Point(date: birthday, value: goal.targetValue),
            changePerYear: (goal.targetValue - best) / years, goalAlreadyMet: best >= goal.targetValue)
    }

    /// The line's value at a date, held at the end points outside the line.
    public func value(at date: Date) -> Double {
        if date <= start.date { return start.value }
        if date >= end.date { return end.value }
        let fraction = date.timeIntervalSince(start.date) / end.date.timeIntervalSince(start.date)
        return start.value + (end.value - start.value) * fraction
    }

    /// `count` evenly spaced points from start to end, both included. At least two.
    public func points(count: Int) -> [Point] {
        let steps = max(count, 2) - 1
        let span = end.date.timeIntervalSince(start.date)
        return (0...steps).map { index in
            if index == 0 { return start }
            if index == steps { return end }
            let date = start.date.addingTimeInterval(span * Double(index) / Double(steps))
            return Point(date: date, value: value(at: date))
        }
    }
}

/// Everything one capacity instrument shows.
public struct CapacitySummary: Equatable, Sendable {
    public let kind: CapacityTestKind
    public let history: CapacityHistory
    public var latest: CapacityResult? { history.latest }
    /// Today's best: the best value from the most recent day.
    public var best: Double? { history.headline }
    public let retest: CapacityRetest
    public let goal: CapacityGoal?
    public let trajectory: CapacityTrajectory?

    public static func make(kind: CapacityTestKind, results: [CapacityResult], cadences: [CapacityTestKind: CapacityCadence],
                            goal: CapacityGoal?, dateOfBirth: Date?, now: Date, calendar: Calendar) -> CapacitySummary {
        let history = CapacityHistory(kind: kind, results: results)
        return CapacitySummary(kind: kind, history: history,
            retest: CapacityRetest.make(kind: kind, latest: history.latest, cadences: cadences, calendar: calendar),
            goal: goal?.kind == kind ? goal : nil,
            trajectory: CapacityTrajectory.make(kind: kind, best: history.headline, goal: goal, dateOfBirth: dateOfBirth,
                                                now: now, calendar: calendar))
    }
}
