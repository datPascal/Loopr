import DomainKit
import Foundation

/// On which days a rule's reminder fires (ICP round 4, Q1b and Q5). Pure: the same rule, day, progress and tests give the
/// same plan, so the app can plan again whenever it opens or an answer is saved.
///
/// - A daily rule repeats on its days for as long as nothing changes: every day, or its chosen weekdays.
/// - A rule that is not daily ("3 times a week", "150 min a week", "every 3 months") reminds every day until the
///   period's count is met, counting what a source checked, then stays quiet until the next period starts: Monday for a
///   weekly rule, the next due day for a longer one.
/// - A rule a running test tests gets no reminder on the test's off nights, washout nights after a switch to off
///   included.
///
/// When the days depend on either, the plan names the days of one `window`, and the app plans again before it runs
/// out: at the next launch, or the next answer from the deck, Today or the lock screen.
public enum RuleReminderPlan: Equatable, Sendable {
    /// The rule's own repeat: every day when empty, else once a week on each of these days.
    case repeating([RuleWeekday])
    /// One reminder on each of these days, soonest first. Empty means none until the next plan.
    case days([DayIdentity])

    /// How many days a dated plan covers, starting on the first day it may fire.
    public static let window = 7

    /// Only a rule the person ticks takes Done and Skip today from its reminder. A rule the band, Food, Fitness or Apple
    /// Health checks gets a plain reminder (ICP round 4, VET).
    public static func takesAnswers(_ rule: ProtocolRule) -> Bool { rule.source == .manual }

    /// - Parameters:
    ///   - today: the person's local day now.
    ///   - progress: how far the rule has come this period (`RuleProgressReader.progress`), or nil when unknown, which
    ///     never silences a reminder.
    ///   - tests: the schedules of the running tests of this rule.
    public static func plan(for rule: ProtocolRule, today: DayIdentity, progress: RuleProgress?,
                            tests: [ExperimentSchedule]) -> RuleReminderPlan {
        let quiet = quietUntil(rule, today: today, progress: progress)
        let start = quiet ?? today
        let days = (0..<window).compactMap { start.adding(days: $0) }
        let tested = tests.contains { schedule in days.contains { schedule.role(on: $0) != .outside } }
        guard quiet != nil || tested else {
            guard let cadence = rule.cadence, cadence.isDaily else { return .repeating([]) }
            return .repeating(cadence.days)
        }
        return .days(days.filter { day in rule.isDue(on: day) && !tests.contains { isOffNight($0.role(on: day)) } })
    }

    /// The first day of the next period, when the rule's count for this one is met. Nil while it is still open, for a
    /// daily rule, and when nothing is known.
    static func quietUntil(_ rule: ProtocolRule, today: DayIdentity, progress: RuleProgress?) -> DayIdentity? {
        guard let cadence = rule.cadence, !cadence.isDaily, let progress else { return nil }
        switch progress {
        case .times(let done, let target):
            return done >= target ? nextMonday(after: today) : nil
        case .amount(let measured, let target, _):
            // "At most 2 drinks a week" is never done early, so it keeps its reminder.
            guard rule.target.kind == .atLeast || rule.target.kind == .exactly, let measured, measured >= target else { return nil }
            return nextMonday(after: today)
        case .due(_, let next):
            guard let next, let ahead = today.days(until: next), ahead > 0 else { return nil }
            return next
        }
    }

    /// The Monday after `day`: the start of the next week, which always starts on Monday.
    static func nextMonday(after day: DayIdentity) -> DayIdentity? {
        guard let weekday = RuleWeekday(day: day) else { return nil }
        return day.adding(days: 8 - weekday.isoNumber)
    }

    /// An off night, or a washout night after a switch to off: the rule is meant to be left out.
    static func isOffNight(_ role: ExperimentNightRole) -> Bool {
        switch role {
        case .off, .washout(.off): true
        case .on, .washout(.on), .outside: false
        }
    }
}
