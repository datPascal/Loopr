import Foundation
import ProfileKit

/// Reads the canonical Profile sleep goal after the Today goals adapter maps it.
public enum TodaySleepNeed {
    public static func minutes(from goals: [TodayGoalProgress]) -> Double {
        guard let goal = goals.first(where: { $0.id == "sleep" }),
              let target = goal.target.flatMap(Double.init) else { return SleepNeed.defaultMinutes }
        return SleepNeed.minutes(target: target, unit: goal.unit) ?? SleepNeed.defaultMinutes
    }
}
