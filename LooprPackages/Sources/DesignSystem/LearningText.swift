import Foundation

/// Shared wording; callers supply the count for the metric being displayed.
public enum LooprLearningText {
    public static func progress(have: Int, need: Int, noun: String = "nights") -> String {
        "\(min(max(have, 0), max(need, 0))) of \(max(need, 0)) \(noun)"
    }

    public static func remaining(have: Int, need: Int, noun: String = "nights") -> String {
        let count = max(0, need - max(have, 0))
        let unit = count == 1 && noun.hasSuffix("s") ? String(noun.dropLast()) : noun
        return "\(count) more \(unit)"
    }

    public static func stale(days: Int) -> String {
        let count = max(1, days)
        return "No new nights from your band for \(count) \(count == 1 ? "day" : "days")."
    }
}
