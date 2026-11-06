import DomainKit
import Foundation
import RoutineKit

/// A rule a day leaves out of its count because it was not due: a blood panel due in February, a weekly rule already
/// done this week, a rule on chosen days on another day.
public struct ProtocolNotDueRule: Equatable, Sendable, Identifiable {
    public var id: RuleKey { rule.key }
    public let rule: ProtocolRule
    /// The next day it is due. Nil when nothing says when.
    public let next: DayIdentity?
}

/// Which rules a day of the Protocol tab counts (ICP R4 Q3). The tab counts what Today counts: the rules due that day by
/// `RuleDueTest`, the test the deck asks with, and any rule with an answer that day, kept, not kept or skipped, so an
/// answer is never dropped. On the fixture Today and the Protocol day both say 10 rules: the blood panel done on 2 Nov
/// is not due until February.
///
/// The week holds what the test needs: the kept days of each rule this week, for weekly and "N times a week" rules, and
/// the progress of a rule every few days, weeks or months, whose last done day stands for the days before this week.
/// A rule last done on a day after the one being counted reads as never done before it, so it counts as due.
public enum ProtocolDueDays {
    /// `week` with only the rules each day counts.
    public static func counted(week: [ProtocolDayInput], progress: [RuleKey: RuleProgress]) -> [ProtocolDayInput] {
        week.map { input in
            input.keeping(input.rules.filter { isCounted($0, on: input.day, week: week, progress: progress) })
        }
    }

    /// True when `day` counts `item`: it has an answer, or it was due.
    public static func isCounted(_ item: ProtocolRuleDay, on day: DayIdentity, week: [ProtocolDayInput],
                                 progress: [RuleKey: RuleProgress]) -> Bool {
        item.hasAnswer || isDue(item.rule, on: day, week: week, progress: progress)
    }

    /// The deck's due test for `rule` on `day`, from the week's kept days and the rule's progress.
    public static func isDue(_ rule: ProtocolRule, on day: DayIdentity, week: [ProtocolDayInput],
                             progress: [RuleKey: RuleProgress]) -> Bool {
        RuleDueTest.isDue(rule, on: day, keptThisWeek: ProtocolDeckQueue.keptDays(rule.key, in: week, through: day),
                          lastDone: lastDone(rule.key, before: day, week: week, progress: progress))
    }

    /// The rules `day` leaves out, in the order of the day's list: the ones on the day that were not due and have no
    /// answer, then the rules of `list` (the day's version) that are not on the day at all because they are kept on
    /// other weekdays.
    public static func notDue(on day: DayIdentity, week: [ProtocolDayInput], progress: [RuleKey: RuleProgress],
                              list: [ProtocolRule]) -> [ProtocolNotDueRule] {
        guard let input = week.first(where: { $0.day == day }), input.phase != .beforeProtocol else { return [] }
        let shown = Set(input.rules.map(\.rule.key))
        let left = input.rules.filter { !isCounted($0, on: day, week: week, progress: progress) }.map(\.rule)
        let leftKeys = Set(left.map(\.key))
        let offDays = list.filter { !shown.contains($0.key) && !leftKeys.contains($0.key) && !$0.isDue(on: day) }
        let order = Dictionary(list.enumerated().map { ($0.element.key, $0.offset) }, uniquingKeysWith: { first, _ in first })
        return (left + offDays)
            .sorted { (order[$0.key] ?? Int.max) < (order[$1.key] ?? Int.max) }
            .map { rule in
                ProtocolNotDueRule(rule: rule, next: RuleDueTest.nextDue(
                    rule, after: day, keptThisWeek: ProtocolDeckQueue.keptDays(rule.key, in: week, through: day),
                    lastDone: lastDone(rule.key, before: day, week: week, progress: progress)))
            }
    }

    /// The last day before `day` the rule was kept: a kept day earlier this week, or the last done day its progress
    /// names when that is earlier still. Nil when neither is known.
    static func lastDone(_ key: RuleKey, before day: DayIdentity, week: [ProtocolDayInput],
                         progress: [RuleKey: RuleProgress]) -> DayIdentity? {
        let limit = ProtocolDeckQueue.dayKey(day)
        var days = week.filter { input in
            ProtocolDeckQueue.dayKey(input.day) < limit && input.rules.contains { $0.rule.key == key && $0.state == .kept }
        }.map(\.day)
        if case .due(let last?, _)? = progress[key], ProtocolDeckQueue.dayKey(last) < limit { days.append(last) }
        return days.max { ProtocolDeckQueue.dayKey($0) < ProtocolDeckQueue.dayKey($1) }
    }
}

// MARK: Day sheet lines (R2: Q3's "Not due today" and Q6's list change)

public extension ProtocolDayRules {
    /// "Not due today: Blood panel, next in February.", or "Not due that day: ..." on any other day. Nil when every
    /// rule of the day was due.
    static func notDueLine(_ rules: [ProtocolNotDueRule], day: DayIdentity, phase: ProtocolDayPhase,
                           calendar: ProtocolWeekCalendar) -> String? {
        guard !rules.isEmpty else { return nil }
        let lead = phase == .today ? "Not due today" : "Not due that day"
        let parts = rules.map { item -> String in
            let name = notDueName(item.rule, locale: calendar.locale)
            guard let next = item.next, let when = nextText(next, from: day, calendar: calendar) else { return name }
            return "\(name), \(when)"
        }
        return "\(lead): \(parts.joined(separator: ". "))."
    }

    /// "next on Monday" within the week, "next on 28 Nov" within four weeks, then "next in February". The year shows
    /// when the month alone could be read as this year's.
    static func nextText(_ next: DayIdentity, from day: DayIdentity, calendar: ProtocolWeekCalendar) -> String? {
        guard let days = calendar.days(from: day, to: next), days > 0, let date = calendar.date(next) else { return nil }
        if days < 7 { return "next on \(calendar.weekdayName(next))" }
        let formatter = DateFormatter()
        formatter.locale = calendar.locale
        formatter.calendar = calendar.calendar
        formatter.timeZone = calendar.calendar.timeZone
        if days < 28 {
            formatter.setLocalizedDateFormatFromTemplate("dMMM")
            return "next on \(formatter.string(from: date))"
        }
        formatter.setLocalizedDateFormatFromTemplate(days > 300 ? "MMMMy" : "MMMM")
        return "next in \(formatter.string(from: date))"
    }

    /// The rule's name without its schedule: "Blood panel" for "Blood panel every 3 months", "Zone 2" for "Zone 2, 150
    /// min a week". The whole title when nothing is left.
    static func notDueName(_ rule: ProtocolRule, locale: Locale) -> String {
        let short = ProtocolDeckQueue.shortName(rule, locale: locale).replacingOccurrences(
            of: #"\s+(every\s+(\d+\s+)?(days?|weeks?|months?)|each\s+(week|month)|once\s+a\s+(week|month)|\d+\s+times\s+a\s+week)$"#,
            with: "", options: [.regularExpression, .caseInsensitive])
        let trimmed = short.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? rule.displayTitle(locale: locale) : trimmed
    }

    /// "You changed your rules on 2 Nov. This day shows the list you had then." for a past day whose list differs from
    /// today's (ICP R4 Q6). The date is the day the first list after the day's own was saved. No version numbers: the
    /// reviewers did not know what a version is.
    static func listChangeLine(for input: ProtocolDayInput, routine: ProtocolRoutineData,
                               calendar: ProtocolWeekCalendar) -> String? {
        guard let changed = listChangedOn(input, routine: routine, calendar: calendar), let date = calendar.date(changed) else {
            return nil
        }
        let formatter = DateFormatter()
        formatter.locale = calendar.locale
        formatter.calendar = calendar.calendar
        formatter.timeZone = calendar.calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("dMMM")
        return "You changed your rules on \(formatter.string(from: date)). This day shows the list you had then."
    }

    /// The day the list changed after `input`'s own, when the day is past and its list differs from today's.
    static func listChangedOn(_ input: ProtocolDayInput, routine: ProtocolRoutineData,
                              calendar: ProtocolWeekCalendar) -> DayIdentity? {
        guard input.phase == .past, let number = input.version, number != routine.version else { return nil }
        let versions = routine.versions.sorted { $0.number < $1.number }
        guard let own = versions.first(where: { $0.number == number }) else { return nil }
        let list = listSignature(own.rules)
        guard list != listSignature(routine.rules),
              let change = versions.first(where: { $0.number > number && listSignature($0.rules) != list }) else { return nil }
        return calendar.day(change.createdAt)
    }

    /// What makes two lists the same for a person: the same rules with the same names, targets and schedules. A new
    /// reason or a moved reminder is not a new list.
    private static func listSignature(_ rules: [ProtocolRule]) -> [String] {
        rules.map { rule in
            "\(rule.key.rawValue)|\(rule.title)|\(String(describing: rule.target))|\(String(describing: rule.cadence))"
        }
    }

    /// The rules the day sheet lists for `day` (the ones the day counts), with the lines under the list.
    static func content(for day: DayIdentity, routine: ProtocolRoutineData,
                        calendar: ProtocolWeekCalendar) -> ProtocolDaySheetContent? {
        guard let input = routine.week.first(where: { $0.day == day }),
              let counted = routine.countedWeek.first(where: { $0.day == day }) else { return nil }
        let list = input.version.flatMap { number in routine.versions.first { $0.number == number }?.rules }
            ?? (input.version == nil || input.version == routine.version ? routine.rules : [])
        let notDue = ProtocolDueDays.notDue(on: day, week: routine.week, progress: routine.progress, list: list)
        let base = content(for: counted, calendar: calendar)
        return ProtocolDaySheetContent(title: base.title, lead: base.lead, rows: base.rows,
                                       notDue: notDueLine(notDue, day: day, phase: input.phase, calendar: calendar),
                                       listChange: listChangeLine(for: input, routine: routine, calendar: calendar))
    }
}
