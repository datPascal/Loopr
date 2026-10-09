import Foundation

/// The sleep need chosen in onboarding or Profile. Older installs use eight hours.
public enum SleepNeed {
    public static let defaultMinutes: Double = 480
    public static let didChange = Notification.Name("loopr.sleepNeedDidChange")

    public static func minutes(from goals: [Goal]) -> Double {
        guard let goal = goals.first(where: { $0.type == .sleep && $0.isEnabled }) else {
            return defaultMinutes
        }
        return minutes(target: goal.target, unit: goal.unit) ?? defaultMinutes
    }

    public static func minutes(target: Double, unit: String) -> Double? {
        guard target.isFinite, target > 0 else { return nil }
        switch unit.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) {
        case "h", "hr", "hrs", "hour", "hours": return target * 60
        case "min", "mins", "minute", "minutes": return target
        default: return nil
        }
    }
}
