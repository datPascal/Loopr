import DesignSystem
import Foundation

/// Where the person stands against their goal: the plan from the targets and the weight readings.
public struct FoodGoalProgress: Equatable, Sendable {
    public let goal: FoodGoal
    public let plan: FoodGoalPlan?
    public let trend: FoodWeightTrend?

    public init(settings: FoodTargetSettings, trend: FoodWeightTrend?) {
        goal = settings.goal; plan = settings.plan; self.trend = trend
    }

    /// The smoothed trend once it counts, otherwise the latest day's weight. Nil without readings.
    public var current: Double? { trend?.current }

    /// Kilograms still to go, never negative. Nil without a goal weight or readings.
    public var remainingKg: Double? {
        guard let goalWeight = plan?.goalWeightKg, let current, goal != .maintain else { return nil }
        let left = goal == .lose ? current - goalWeight : goalWeight - current
        return max(left, 0)
    }

    /// Kilograms moved toward the goal since the plan started, never negative.
    public var doneKg: Double? {
        guard let plan, plan.goalWeightKg != nil, let current, goal != .maintain else { return nil }
        return max(goal == .lose ? plan.startWeightKg - current : current - plan.startWeightKg, 0)
    }

    /// 0 to 1 from the start weight to the goal weight.
    public var fraction: Double? {
        guard let plan, let goalWeight = plan.goalWeightKg, let doneKg else { return nil }
        let total = abs(goalWeight - plan.startWeightKg)
        return total > 0 ? min(doneKg / total, 1) : nil
    }

    /// "Losing 0.5 kg a week", "Keeping your weight" or "Building 0.25 kg a week".
    public var headline: String {
        guard let plan, plan.paceKgPerWeek > 0, goal != .maintain else {
            return switch goal { case .lose: "Lose weight"; case .maintain: "Keeping your weight"; case .build: "Build muscle" }
        }
        let pace = FoodGoalProgress.pace(plan.paceKgPerWeek)
        return goal == .lose ? "Losing \(pace) kg a week" : "Gaining \(pace) kg a week"
    }

    /// When the goal weight is reached at the planned pace from today's weight. Nil when it is
    /// reached already, or without a pace, goal weight or readings.
    public func expectedDate(from now: Date, calendar: Calendar) -> Date? {
        guard let remainingKg, remainingKg > 0.05, let pace = plan?.paceKgPerWeek, pace > 0 else { return nil }
        return calendar.date(byAdding: .day, value: Int((remainingKg / pace * 7).rounded(.up)), to: now)
    }

    /// 80 shows "80", 80.45 shows "80.5". One decimal at most: scales are not more precise.
    public static func kilograms(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)).locale(LooprUnitFormatter.displayLocale))
    }

    /// A weekly pace keeps its quarter kilos: "0.25", "0.5", "1".
    public static func pace(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)).locale(LooprUnitFormatter.displayLocale))
    }

    /// "−0.4", "+0.2" or "0".
    public static func signedKilograms(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        if rounded == 0 { return "0" }
        return (rounded > 0 ? "+" : "−") + kilograms(abs(rounded))
    }
}
