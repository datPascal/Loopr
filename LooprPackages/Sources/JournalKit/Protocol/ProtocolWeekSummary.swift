import DesignSystem
import DomainKit
import Foundation
import RoutineKit

/// What the hero says about this week: one line, "13 of 14 kept this week · In bed not kept on Monday", the share in
/// percent from the protocol's third day, and behind the info button the counting rule (ICP R2-NEW-01, R2-DES-01).
///
/// The rules it follows (DEC-12.12, ICP R1-VET-01, R1-NEW-05, R1-DES-06):
/// - One rule on one day is one check. The share is kept checks over checks with an answer, kept or not kept, Monday
///   through today. Skipped and not known checks are left out, so a sick day or a day nobody could check never reads as
///   not kept. Nothing answered means no share, never 0 percent.
/// - The big percent waits for day 3 of the protocol, so two checks on day one never read as "100%".
/// - It names the rule not kept on the most days this week, the first in the version's order on a tie, and the days.
///   The wording states the fact and passes no judgement (ICP R1-NEW-8): no "missed", "slipped" or "like last week".
/// - A protocol that started this week says which day it started on.
/// - On the protocol's first two days the hero is one plain line and nothing else (R2-NEW-03, R2-DES-06): "Day 1. Answer
///   tonight's cards to fill your first dot.", then "Day 1. 2 of 3 kept so far." once something has an answer.
public struct ProtocolWeekSummary: Equatable, Sendable {
    /// The protocol's day from which the percent shows.
    public static let percentFromDay = 3
    /// The counting rule, behind the week's info button.
    public static let countingRule = "Counts checks with an answer. Skipped and not known are left out."

    public let kept: Int
    public let decided: Int
    /// The share in percent, rounded. Nil when nothing has an answer or before the protocol's third day.
    public let percent: Int?
    /// "13 of 14 kept this week".
    public let line: String
    /// The check-in's one hero line: `line` with the rule not kept on the most days ("13 of 14 kept this week · In bed
    /// not kept on Monday"), or the first days' line.
    public let hero: String
    /// The counting rule, and the start day for a protocol that started this week.
    public let countingLine: String
    /// "Not kept on Monday: In bed by 22:30". Nil when every answered check was kept.
    public let slipLine: String?
    /// The rule named in `slipLine`.
    public let slippedRule: RuleKey?
    /// The last day that rule was not kept, which the slip line opens.
    public let slippedDay: DayIdentity?

    public var share: Double? { decided == 0 ? nil : Double(kept) / Double(decided) }

    public static let absentText = "Nothing answered yet this week"

    public static func make(week: [ProtocolDayInput], calendar: ProtocolWeekCalendar, dayNumber: Int = percentFromDay,
                            startedOn start: DayIdentity? = nil) -> ProtocolWeekSummary {
        let counted = week.filter { $0.phase != .future }
        let decided = counted.flatMap(\.rules).filter(\.isDecided)
        let kept = decided.filter { $0.state == .kept }.count
        let percent = decided.isEmpty || dayNumber < percentFromDay ? nil : Int((Double(kept) / Double(decided.count) * 100).rounded())
        let line = decided.isEmpty ? absentText : "\(kept) of \(decided.count) kept this week"

        var counting = countingRule
        if let start, week.contains(where: { $0.day == start }), calendar.isoWeekday(start) != 1 {
            counting += " Your protocol started on \(calendar.weekdayName(start)), so the week counts from there."
        }

        let slip = slipped(in: counted)
        let slipLine = slip.map { slip in
            let days = list(slip.days.map(calendar.weekdayName), locale: calendar.locale)
            return "Not kept on \(days): \(LooprClockFormat.localizing(slip.rule.title, locale: calendar.locale))"
        }
        let suffix = slip.map { slip in
            let days = list(slip.days.map(calendar.weekdayName), locale: calendar.locale)
            return " \u{00B7} \(ProtocolDeckQueue.shortName(slip.rule, locale: calendar.locale)) not kept on \(days)"
        } ?? ""
        let hero = dayNumber < percentFromDay
            ? firstDays(day: max(dayNumber, 1), kept: kept, decided: decided.count, today: week.first { $0.phase == .today })
            : line + (decided.isEmpty ? "" : suffix)
        return ProtocolWeekSummary(kept: kept, decided: decided.count, percent: percent, line: line, hero: hero,
                                   countingLine: counting, slipLine: slipLine, slippedRule: slip?.rule.key,
                                   slippedDay: slip?.days.last)
    }

    /// "Day 1. Answer tonight's cards to fill your first dot.", "Day 2. 5 of 6 kept so far.", or for a list a source
    /// checks alone, "Day 1. Your first dots fill in as Loopr checks your rules."
    static func firstDays(day: Int, kept: Int, decided: Int, today: ProtocolDayInput?) -> String {
        if decided > 0 { return "Day \(day). \(kept) of \(decided) kept so far." }
        let cards = today?.rules.filter { $0.rule.source == .manual || $0.rule.isEvening }.count ?? 0
        guard cards > 0 else { return "Day \(day). Your first dots fill in as Loopr checks your rules." }
        let fill = day == 1 ? "your first dot" : "today's dots"
        return "Day \(day). Answer tonight's \(cards == 1 ? "card" : "cards") to fill \(fill)."
    }

    private static func slipped(in days: [ProtocolDayInput]) -> (rule: ProtocolRule, days: [DayIdentity])? {
        var order: [RuleKey] = []
        var rules: [RuleKey: ProtocolRule] = [:]
        var missed: [RuleKey: [DayIdentity]] = [:]
        for day in days {
            for item in day.rules {
                if rules[item.rule.key] == nil { rules[item.rule.key] = item.rule; order.append(item.rule.key) }
                if item.state == .missed { missed[item.rule.key, default: []].append(day.day) }
            }
        }
        var best: RuleKey?
        for key in order where (missed[key]?.count ?? 0) > (best.flatMap { missed[$0]?.count } ?? 0) { best = key }
        guard let best, let rule = rules[best], let days = missed[best] else { return nil }
        return (rule, days)
    }

    /// "Saturday and Sunday", in the locale's list style.
    static func list(_ items: [String], locale: Locale) -> String {
        let formatter = ListFormatter()
        formatter.locale = locale
        return formatter.string(from: items) ?? items.joined(separator: ", ")
    }
}

/// The weekly review's row: last week's, with its dates, so its share is never read against this week's (ICP R1-VET-01,
/// R1-SEN-16, R1-HAB-14). It leads the check-in on Sunday from 17:00 and on Monday, when the week has just ended
/// (R1-DES-18, R1-NEW-09); the other days it is a small row further down.
public struct ProtocolWeeklyReviewPlacement: Equatable, Sendable {
    /// "Last week, 6 to 12 Nov", or "This week, 13 to 19 Nov" on Sunday evening.
    public let title: String
    public let isProminent: Bool

    /// `monday` is the Monday of the week the review covers.
    public static func make(monday: DayIdentity, today: DayIdentity, nowMinute: Int,
                            calendar: ProtocolWeekCalendar) -> ProtocolWeeklyReviewPlacement {
        let sunday = calendar.adding(6, to: monday) ?? monday
        let thisWeek = calendar.week(containing: today).first == monday
        let weekday = calendar.isoWeekday(today) ?? 1
        let prominent = (weekday == 7 && nowMinute >= ProtocolDeckQueue.eveningMinute) || weekday == 1
        return ProtocolWeeklyReviewPlacement(title: "\(thisWeek ? "This week" : "Last week"), \(range(monday, sunday, calendar: calendar))",
                                             isProminent: prominent)
    }

    /// "6 to 12 Nov", or "30 Oct to 5 Nov" across a month.
    static func range(_ start: DayIdentity, _ end: DayIdentity, calendar: ProtocolWeekCalendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = calendar.locale
        formatter.calendar = calendar.calendar
        formatter.timeZone = calendar.calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("dMMM")
        guard let first = calendar.date(start), let last = calendar.date(end) else { return "" }
        let endText = formatter.string(from: last)
        // A day-first locale shares the month: "6 to 12 Nov". Elsewhere both dates are whole: "Nov 6 to Nov 12".
        if start.month == end.month && start.year == end.year && endText.hasPrefix("\(end.day)") {
            return "\(start.day) to \(endText)"
        }
        return "\(formatter.string(from: first)) to \(endText)"
    }
}
