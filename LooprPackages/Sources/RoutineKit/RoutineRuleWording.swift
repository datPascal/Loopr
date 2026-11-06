import DesignSystem
import Foundation

// How a rule reads on screen, and what one day of rules counts as. Every surface (the Protocol deck, the Rules list,
// Today's rail and "Your day", reminders, the bedtime activity) goes through these, so one rule never reads two ways
// and one day never counts two ways (ICP R1-OPT-7, R1-OPT-9, R1-UPG-13, R1-UPG-15).

public extension ProtocolRule {
    /// The title with every stored 24-hour time ("No caffeine after 14:00") written in the locale's clock
    /// ("No caffeine after 2:00 pm" in en_US). The stored title does not change.
    func displayTitle(locale: Locale = .current) -> String {
        LooprClockFormat.localizing(title.trimmingCharacters(in: .whitespacesAndNewlines), locale: locale)
    }

    /// True for a rule written as something to avoid: "No alcohol", "No screens in bed". A yes to "No alcohol?" is
    /// ambiguous, so the check-in asks these the other way (`checkInQuestion`).
    var isWrittenAsAvoid: Bool {
        let words = title.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ", maxSplits: 1)
        guard words.count == 2, let first = words.first?.lowercased() else { return false }
        return first == "no" || first == "not"
    }

    /// The check-in question, where Yes always means kept. "Screens off by 9:45 pm?" for a rule to do, and "Did you
    /// keep to no alcohol?" for a rule to avoid, so nobody has to answer "No" to "No alcohol?".
    func checkInQuestion(locale: Locale = .current) -> String {
        let title = displayTitle(locale: locale)
        guard isWrittenAsAvoid, let first = title.first else { return title.hasSuffix("?") ? title : "\(title)?" }
        let rest = title.dropFirst()
        let body = (first.lowercased() + rest).trimmingCharacters(in: CharacterSet(charactersIn: "?. "))
        return "Did you keep to \(body)?"
    }

    /// The minute the time in the title stands for: the target for a rule that checks a clock time ("In bed by 22:30"
    /// checks 22:30), otherwise the rule's own time ("Screens off by 21:45" is due at 21:45). Nil when the rule has no
    /// clock time at all.
    var titleMinute: Int? {
        if target.kind != .done, let metric = target.metric.flatMap(RoutineMetric.init(rawValue:)), metric.isTimeOfDay,
           let value = target.value, value.isFinite {
            return Int(value) % 1_440
        }
        return timeOfDayMinutes
    }
}

public enum RoutineRuleTitle {
    /// Moves the one 24-hour time in a title by `minutes`, so a rule called "Screens off by 21:45" becomes "Screens off
    /// by 22:00" when its time moves 15 minutes later. A title with no time, or with more than one, stays as it is: there
    /// is no telling which time the person meant.
    public static func shiftingTime(in title: String, by minutes: Int) -> String {
        guard minutes != 0, let expression = try? NSRegularExpression(pattern: #"(?<![\d:])([01]?\d|2[0-3]):([0-5]\d)(?![\d:])"#) else {
            return title
        }
        let matches = expression.matches(in: title, range: NSRange(title.startIndex..., in: title))
        guard matches.count == 1, let match = matches.first, let range = Range(match.range, in: title),
              let hourRange = Range(match.range(at: 1), in: title), let minuteRange = Range(match.range(at: 2), in: title),
              let hour = Int(title[hourRange]), let minute = Int(title[minuteRange]) else { return title }
        let moved = (((hour * 60 + minute + minutes) % 1_440) + 1_440) % 1_440
        return title.replacingCharacters(in: range, with: String(format: "%02d:%02d", moved / 60, moved % 60))
    }

    /// Replaces the last whole number `old` in a title with `new`, so "Zone 2, 45 min" becomes "Zone 2, 50 min" when the
    /// amount moves to 50 (ICP R2-OPT-5). A title without that number stays as it is. "2" in "Zone 2" is not 45.
    public static func replacingAmount(in title: String, from old: Double, to new: Double) -> String {
        let before = amountText(old), after = amountText(new)
        guard before != after,
              let expression = try? NSRegularExpression(pattern: "(?<![\\d.,:])" + NSRegularExpression.escapedPattern(for: before)
                                                                    + "(?![\\d:]|[.,]\\d)"),
              let match = expression.matches(in: title, range: NSRange(title.startIndex..., in: title)).last,
              let range = Range(match.range, in: title) else { return title }
        return title.replacingCharacters(in: range, with: after)
    }

    /// "45", "7.5": the way an amount reads in a rule's name.
    public static func amountText(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }
}

/// One day of rules, counted one way everywhere: the Protocol deck, Today's ring and rail, and Today's "Your day" row.
///
/// - `total` is every rule of the day.
/// - `kept` is the rules kept so far.
/// - `toAnswer` is the rules the person can still answer: a manual rule, or an evening rule whatever its source (the
///   evening is when the person knows), that is still pending. Kept and missed rules are decided, and a rule nobody could
///   check (unknown) is not asked.
public struct RoutineDayCount: Equatable, Sendable {
    public let kept: Int
    public let total: Int
    public let toAnswer: Int

    public init(kept: Int, total: Int, toAnswer: Int) {
        self.kept = kept; self.total = total; self.toAnswer = toAnswer
    }

    /// True when the rule is one the person still has to answer today.
    public static func asksPerson(source: CheckSource, isEvening: Bool, state: CheckState?) -> Bool {
        let open = state == nil || state == .pending
        return open && (source == .manual || isEvening)
    }

    public static func make(_ rules: [(rule: ProtocolRule, state: CheckState?)]) -> RoutineDayCount {
        RoutineDayCount(kept: rules.filter { $0.state == .kept }.count, total: rules.count,
                        toAnswer: rules.filter { asksPerson(source: $0.rule.source, isEvening: $0.rule.isEvening, state: $0.state) }.count)
    }

    /// "3 rules left to answer", "1 rule left to answer", "All answered".
    public var toAnswerText: String {
        switch toAnswer {
        case 0: "All answered"
        case 1: "1 rule left to answer"
        default: "\(toAnswer) rules left to answer"
        }
    }

    /// "2 of 8 rules kept".
    public var keptText: String { "\(kept) of \(total) \(total == 1 ? "rule" : "rules") kept" }
}
