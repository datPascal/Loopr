import DomainKit
import Foundation

// When a rule is due, and how far a rule with a longer period has come (ICP R1-HAB-02, R1-VET-08, R1-VET-23). Pure:
// the same rule, days, checks and snapshots give the same answer.

public extension RuleCadence {
    /// True when a rule with this cadence asks for something on `day`. A rule on chosen weekdays is due on those days
    /// only. Every other cadence is due on any day: a weekly or monthly rule can be done on whichever day suits.
    func isDue(on day: DayIdentity) -> Bool {
        guard hasChosenDays else { return true }
        guard let weekday = RuleWeekday(day: day) else { return false }
        return days.contains(weekday)
    }
}

public extension ProtocolRule {
    /// The one answer to "is this rule due on this day?" for the day view, the deck and the Rules list. A rule without
    /// a cadence is due every day. A day it is not due on gets no check, so it is neither kept nor missed.
    func isDue(on day: DayIdentity) -> Bool { cadence?.isDue(on: day) ?? true }

    /// `isDue(on:)`, and false once an "N times a week" rule is done N times in the day's week, so the deck stops
    /// asking. `keptThisWeek` counts the kept days of the day's week, the day itself included.
    func isDue(on day: DayIdentity, keptThisWeek: Int) -> Bool {
        guard isDue(on: day) else { return false }
        guard let times = cadence?.timesPerWeek else { return true }
        return keptThisWeek < times
    }
}

/// The one due test behind Today's list, the check-in's deck and every count of a day or a week (ICP R3-NEW-07, R4 Q3),
/// so Today and the Protocol tab give one number for one day and the weekly review counts the same checks.
public enum RuleDueTest {
    /// Whether the deck asks `rule` on `day`. `isDue(on:keptThisWeek:)` decides chosen days and "N times a week"; on top
    /// of it a weekly tick is done once it was kept this week, and a rule every few days, weeks or months waits for the
    /// next day its progress names. A rule that was never done is due.
    public static func isDue(_ rule: ProtocolRule, on day: DayIdentity, keptThisWeek: Int,
                             progress: RuleProgress? = nil) -> Bool {
        guard rule.isDue(on: day, keptThisWeek: keptThisWeek) else { return false }
        guard let cadence = rule.cadence else { return true }
        if isWeeklyTick(cadence) { return keptThisWeek < 1 }
        if case .due(_, let next?)? = progress { return key(next) <= key(day) }
        return true
    }

    /// `isDue`, with the last day the rule was kept before `day` in place of its progress. Nil reads as never done.
    public static func isDue(_ rule: ProtocolRule, on day: DayIdentity, keptThisWeek: Int, lastDone: DayIdentity?) -> Bool {
        isDue(rule, on: day, keptThisWeek: keptThisWeek, progress: progress(rule, lastDone: lastDone))
    }

    /// One rule over the days of one week, in day order: true where the day counts the rule. A day with an answer (kept,
    /// not kept or skipped) always counts it, so an answer is never dropped; any other day counts it only when it was
    /// due. `lastDone` is the last day the rule was kept before the first of `days`, for a rule every few days, weeks or
    /// months; nil reads as never done, so the rule is due.
    public static func counted(_ rule: ProtocolRule, days: [(day: DayIdentity, state: CheckState?)],
                               lastDone: DayIdentity?) -> [Bool] {
        var kept = 0
        var last = lastDone
        return days.map { entry in
            if entry.state == .kept { kept += 1 }
            let due = isDue(rule, on: entry.day, keptThisWeek: kept, progress: progress(rule, lastDone: last))
            if entry.state == .kept { last = entry.day }
            return entry.state == .kept || entry.state == .missed || entry.state == .skipped || due
        }
    }

    /// The next day after `day` on which `rule` is due again, for a day it is not due: the next chosen weekday, the
    /// Monday after a week whose count is met, or the day its period comes round. Nil when the rule is due, or when
    /// nothing says when it is next.
    public static func nextDue(_ rule: ProtocolRule, after day: DayIdentity, keptThisWeek: Int,
                               lastDone: DayIdentity?) -> DayIdentity? {
        guard let cadence = rule.cadence,
              !isDue(rule, on: day, keptThisWeek: keptThisWeek, progress: progress(rule, lastDone: lastDone)) else { return nil }
        if !cadence.isDue(on: day) {
            return (1...7).lazy.compactMap { day.adding(days: $0) }.first { cadence.isDue(on: $0) }
        }
        if cadence.timesPerWeek != nil || isWeeklyTick(cadence) {
            guard let weekday = RuleWeekday(day: day)?.isoNumber else { return nil }
            return day.adding(days: 8 - weekday)
        }
        if case .due(_, let next?)? = progress(rule, lastDone: lastDone) { return next }
        return nil
    }

    /// `.due` from the last kept day, for a rule every few days, weeks or months. Nil for any other rule, or never done.
    static func progress(_ rule: ProtocolRule, lastDone: DayIdentity?) -> RuleProgress? {
        guard let cadence = rule.cadence, !cadence.isDaily, !isWeeklyTick(cadence), cadence.timesPerWeek == nil,
              let lastDone else { return nil }
        return .due(lastDone: lastDone, next: RuleProgressReader.next(after: lastDone, cadence: cadence))
    }

    /// Once a week, done on any day: "each week".
    private static func isWeeklyTick(_ cadence: RuleCadence) -> Bool {
        cadence.unit == .week && cadence.every == 1 && cadence.timesPerWeek == nil
    }

    private static func key(_ day: DayIdentity) -> String { day.routineDayKey ?? "" }
}

/// How far a rule with a longer period has come.
public enum RuleProgress: Equatable, Sendable {
    /// A week's amount from a source, such as 112 of 150 zone 2 minutes. Only days with a reading add to it. Nil
    /// `measured` means the source has nothing for the week yet, which is never shown as zero.
    case amount(measured: Double?, target: Double, unit: String?)
    /// Days done this week against the times asked for: "3 times a week", or once for a weekly tick.
    case times(done: Int, target: Int)
    /// A rule every few days, weeks or months: the day it was last done and the day it is due next. Both nil when it
    /// was never done.
    case due(lastDone: DayIdentity?, next: DayIdentity?)
}

public enum RuleProgressReader {
    /// True when a rule has a longer period to show progress for. A daily rule, on every day or on chosen days, has none.
    public static func hasProgress(_ rule: ProtocolRule) -> Bool {
        guard let cadence = rule.cadence else { return false }
        return !cadence.isDaily
    }

    /// True when the progress reads the sources' readings for the week, so the caller fetches them.
    public static func needsReadings(_ rule: ProtocolRule) -> Bool {
        guard let cadence = rule.cadence, cadence.unit == .week, cadence.every == 1, rule.source != .manual else { return false }
        return cadence.timesPerWeek != nil || addableMetric(rule) != nil
    }

    /// The progress of `rule`. `week` is Monday to the day being shown, `history` the rule's stored checks up to that
    /// day, and `readings` the source snapshots of the week's days so far. Nil for a daily rule, or when nothing can be
    /// said honestly, such as a weekly source rule on a metric that does not add up over days.
    public static func progress(for rule: ProtocolRule, week: [DayIdentity], history: [RuleCheck],
                                readings: [DayIdentity: RoutineSourceSnapshots]) -> RuleProgress? {
        guard let cadence = rule.cadence, !cadence.isDaily else { return nil }
        if cadence.unit == .week, cadence.every == 1 {
            let target = cadence.timesPerWeek ?? 1
            if rule.source == .manual {
                return .times(done: keptDays(history, in: week), target: target)
            }
            if cadence.timesPerWeek != nil {
                let done = week.filter { day in readings[day].map { meetsTarget(rule, snapshots: $0) } ?? false }.count
                return .times(done: max(done, keptDays(history, in: week)), target: target)
            }
            return weekAmount(rule, week: week, readings: readings)
        }
        let last = history.filter { $0.state == .kept }.map(\.day).max { key($0) < key($1) }
        guard let last else { return .due(lastDone: nil, next: nil) }
        return .due(lastDone: last, next: next(after: last, cadence: cadence))
    }

    /// The day after `day` by the cadence's period: 12 Sep and every 3 months gives 12 Dec.
    public static func next(after day: DayIdentity, cadence: RuleCadence) -> DayIdentity? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day)) else { return nil }
        let component: Calendar.Component = switch cadence.unit {
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        }
        guard let next = calendar.date(byAdding: component, value: cadence.every, to: date) else { return nil }
        let parts = calendar.dateComponents([.year, .month, .day], from: next)
        guard let year = parts.year, let month = parts.month, let dayOfMonth = parts.day else { return nil }
        return DayIdentity(year: year, month: month, day: dayOfMonth)
    }

    // MARK: Parts

    private static func keptDays(_ history: [RuleCheck], in week: [DayIdentity]) -> Int {
        let days = Set(week)
        return Set(history.filter { $0.state == .kept && days.contains($0.day) }.map(\.day)).count
    }

    /// A metric whose daily readings add up to a week: minutes, sessions, steps, grams, kilocalories and drinks.
    static func addableMetric(_ rule: ProtocolRule) -> RoutineMetric? {
        guard let name = rule.target.metric, let metric = RoutineMetric(rawValue: name), metric.source == rule.source else { return nil }
        switch metric.unit {
        case .minutes, .sessions, .steps, .grams, .kilocalories, .drinks: return metric
        case .minutesAfterMidnight, .tick, .fraction, .mlPerKgPerMin, .kilograms, .beatsPerMinute: return nil
        }
    }

    private static func weekAmount(_ rule: ProtocolRule, week: [DayIdentity],
                                   readings: [DayIdentity: RoutineSourceSnapshots]) -> RuleProgress? {
        guard rule.target.kind != .done, let target = rule.target.value, target.isFinite,
              let metric = addableMetric(rule) else { return nil }
        let amounts = week.compactMap { day -> Double? in
            guard let snapshot = readings[day]?.snapshot(for: rule.source), snapshot.access(for: metric) == .available else { return nil }
            return amount(snapshot.readings[metric])
        }
        return .amount(measured: amounts.isEmpty ? nil : amounts.reduce(0, +), target: target, unit: rule.target.unit)
    }

    /// A day of an "N times a week" source rule counts when its reading meets the rule's target for one time.
    private static func meetsTarget(_ rule: ProtocolRule, snapshots: RoutineSourceSnapshots) -> Bool {
        guard let name = rule.target.metric, let metric = RoutineMetric(rawValue: name),
              let snapshot = snapshots.snapshot(for: rule.source), snapshot.access(for: metric) == .available,
              let value = amount(snapshot.readings[metric]) else { return false }
        let target = rule.target.value ?? 1
        switch rule.target.kind {
        case .done: return value > 0
        case .atLeast: return value >= target
        case .atMost: return value <= target
        case .exactly: return abs(value - target) < 1e-6
        }
    }

    private static func amount(_ reading: MetricReading?) -> Double? {
        switch reading {
        case .measured(let value)? where value.isFinite && value >= 0: value
        case .atLeast(let value)? where value.isFinite && value >= 0: value
        default: nil
        }
    }

    private static func key(_ day: DayIdentity) -> String { day.routineDayKey ?? "" }
}
