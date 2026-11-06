import Foundation
import DesignSystem

/// What happened on the day before one night's sleep. The app reads these from Food, Journal, Train and the
/// band and hands them over, so SleepKit does not depend on those packages. Every value is optional because
/// any of them can be missing for a day.
///
/// `day` is the day the night ends on, as `yyyy-MM-dd`, matching the Sleep tab's selected day. The other
/// fields describe the evening and day before it.
public struct SleepComparisonDay: Equatable, Sendable {
    public let day: String
    /// When the last dinner of the evening before started, in minutes after midnight.
    public let dinnerMinute: Int?
    /// The answer to the alcohol question, nil when it was not answered.
    public let alcohol: Bool?
    /// True when a workout was logged the day before. False when the day was logged with none.
    public let trained: Bool?
    /// When sleep started, in minutes after midnight. A time before noon counts as after midnight, so 00:30
    /// compares with 23:30 as one hour later, not 23 hours earlier.
    public let bedtimeMinute: Int?
    /// Steps on the day before.
    public let steps: Double?

    public init(day: String, dinnerMinute: Int? = nil, alcohol: Bool? = nil, trained: Bool? = nil,
                bedtimeMinute: Int? = nil, steps: Double? = nil) {
        self.day = day
        self.dinnerMinute = dinnerMinute.map { min(max($0, 0), 1_439) }
        self.alcohol = alcohol
        self.trained = trained
        self.bedtimeMinute = bedtimeMinute.map { min(max($0, 0), 1_439) }.map { $0 < 12 * 60 ? $0 + 1_440 : $0 }
        self.steps = steps.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
    }
}

/// One way the night differed from the last 28 days.
public struct SleepDeviation: Equatable, Sendable {
    public enum Factor: String, Sendable { case dinner, alcohol, workout, bedtime, steps }

    public let factor: Factor
    /// One plain sentence about the night, such as "Dinner was at 19:10, 2 h 0 m earlier than your average."
    public let sentence: String
    /// 0 to 1. How unusual the night was on this factor. Used only to order the deviations.
    public let strength: Double

    /// The app a person would open to check it.
    public var source: String {
        switch factor {
        case .dinner: "Food"
        case .alcohol: "Protocol"
        case .workout: "Fitness"
        case .bedtime: "Sleep"
        case .steps: "Activity"
        }
    }
}

/// Compares a night with the person's own trailing 28 days: dinner time, the alcohol answer, a workout the day
/// before, bedtime and steps. It runs on the phone and sends nothing anywhere. It reports at most three
/// differences, the biggest first, and nothing when no factor has enough history to compare.
public struct SleepNightComparison: Equatable, Sendable {
    /// Days of history the comparison looks back over.
    public static let windowDays = 28
    /// Fewest days a factor needs in the window before the night is compared with it.
    public static let minimumHistoryDays = 7
    public static let maximumDeviations = 3

    public let deviations: [SleepDeviation]

    /// The card text: the sentences of the top differences in one paragraph.
    public var text: String { deviations.map(\.sentence).joined(separator: " ") }

    /// "Food · Protocol · Sleep", once each in order of appearance.
    public var sources: [String] {
        deviations.reduce(into: [String]()) { if !$0.contains($1.source) { $0.append($1.source) } }
    }

    /// Nil when there is nothing to say.
    /// - Parameter locale: Writes clock times the way the Sleep hero does, so "7:10 pm" here matches "10:30 pm" there.
    public static func make(night: SleepComparisonDay, history: [SleepComparisonDay], locale: Locale = .current) -> SleepNightComparison? {
        let window = history.filter { Self.isInWindow($0.day, before: night.day) }
        var found: [SleepDeviation] = []
        func add(_ value: SleepDeviation?) { if let value { found.append(value) } }

        add(numeric(.dinner, night: night.dinnerMinute.map(Double.init), past: window.compactMap { $0.dinnerMinute.map(Double.init) },
                    smallest: 45, spread: 30) { value, _, diff in
            "Dinner was at \(clock(value, locale: locale)), \(gap(abs(diff))) \(diff < 0 ? "earlier" : "later") than your average."
        })
        add(numeric(.bedtime, night: night.bedtimeMinute.map(Double.init), past: window.compactMap { $0.bedtimeMinute.map(Double.init) },
                    smallest: 30, spread: 20) { value, _, diff in
            "Bedtime was \(clock(value, locale: locale)), \(gap(abs(diff))) \(diff < 0 ? "earlier" : "later") than your average."
        })
        add(numeric(.steps, night: night.steps, past: window.compactMap(\.steps), smallest: 2_000, spread: 1_500, relative: 0.2) { value, _, diff in
            "You took \(stepsText(value)) steps the day before, about \(stepsText(abs(diff))) \(diff < 0 ? "fewer" : "more") than your average."
        })
        add(flag(.alcohol, night: night.alcohol, past: window.compactMap(\.alcohol)) { value, _, _ in
            value ? "You logged alcohol." : "You logged no alcohol."
        })
        add(flag(.workout, night: night.trained, past: window.compactMap(\.trained)) { value, _, _ in
            value ? "You trained the day before." : "You did not train the day before."
        })

        let top = found.sorted { ($0.strength, $1.factor.rawValue) > ($1.strength, $0.factor.rawValue) }.prefix(maximumDeviations)
        guard !top.isEmpty else { return nil }
        return SleepNightComparison(deviations: Array(top))
    }

    // MARK: Numeric factors

    /// A number differs when it is far from the mean in absolute terms and against how much that factor usually
    /// moves. Strength is the distance in typical spreads, capped at three.
    private static func numeric(_ factor: SleepDeviation.Factor, night: Double?, past: [Double], smallest: Double, spread floor: Double,
                                relative: Double = 0, sentence: (Double, Double, Double) -> String) -> SleepDeviation? {
        guard let night, past.count >= minimumHistoryDays else { return nil }
        let mean = past.reduce(0, +) / Double(past.count)
        let variance = past.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(past.count)
        let diff = night - mean
        guard abs(diff) >= max(smallest, abs(mean) * relative) else { return nil }
        let strength = min(abs(diff) / max(variance.squareRoot(), floor), 3) / 3
        return SleepDeviation(factor: factor, sentence: sentence(night, mean, diff), strength: strength)
    }

    // MARK: Yes and no factors

    /// A yes or no answer differs when the night's answer is the one the person gave on half the days or fewer.
    /// Strength is how rare that answer was.
    private static func flag(_ factor: SleepDeviation.Factor, night: Bool?, past: [Bool],
                             sentence: (Bool, Int, Int) -> String) -> SleepDeviation? {
        guard let night, past.count >= minimumHistoryDays else { return nil }
        let same = past.filter { $0 == night }.count
        let rarity = Double(same) / Double(past.count)
        guard rarity <= 0.5 else { return nil }
        let yes = past.filter { $0 }.count
        return SleepDeviation(factor: factor, sentence: sentence(night, yes, past.count), strength: 1 - rarity)
    }

    // MARK: Wording

    /// The same locale-aware clock the Sleep hero uses, for a minute after midnight. A minute past 24 hours wraps.
    static func clock(_ minute: Double, locale: Locale) -> String {
        LooprClockFormat.text(minuteOfDay: Int(minute.rounded()), locale: locale)
    }

    /// A gap in plain words: "40 minutes", "an hour", "2 hours", "about 1.5 hours". Rounded to five minutes under an hour and
    /// to the half hour above it.
    static func gap(_ minutes: Double) -> String {
        if minutes < 55 { return "\(max(5, Int((minutes / 5).rounded()) * 5)) minutes" }
        let halves = max(2, Int((minutes / 30).rounded()))
        let hours = Double(halves) / 2
        let exact = abs(hours * 60 - minutes) <= 7
        let text: String
        switch halves {
        case 2: text = "an hour"
        case 4: text = "2 hours"
        default: text = halves.isMultiple(of: 2) ? "\(halves / 2) hours" : "\(halves / 2).5 hours"
        }
        return exact ? text : "about " + text
    }

    static func stepsText(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US")
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: (value / 100).rounded() * 100)) ?? "\(Int(value))"
    }

    // MARK: Window

    /// True for a day inside the 28 days before `night`, not the night itself.
    static func isInWindow(_ day: String, before night: String) -> Bool {
        guard let date = parse(day), let end = parse(night) else { return false }
        let gap = Int(((end.timeIntervalSince(date)) / 86_400).rounded())
        return gap >= 1 && gap <= windowDays
    }

    private static func parse(_ day: String) -> Date? {
        let parts = day.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, let year = Int(parts[0]), let month = Int(parts[1]), let dayNumber = Int(parts[2]) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(year: year, month: month, day: dayNumber, hour: 12))
    }
}
