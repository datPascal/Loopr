#if DEBUG
import CoachKit
import DomainKit
import Foundation
import RoutineKit

/// DEBUG launch fixture for the weekly review sheet: `--loopr-weekly-review=open` opens it on the week of Monday 19
/// October 2026, with all five pages. Kitchen closes was missed on Saturday and Sunday, and on the nights it was missed
/// sleep heart rate ran 5 bpm above the nights it was kept, so the story proposes version 8. Start the experiment and
/// Not now write to memory only. Nothing here is reachable in a release build.
enum WeeklyReviewFixture {
    static let argument = "--loopr-weekly-review=open"

    static func isRequested(_ arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        arguments.contains(argument)
    }

    static let monday = DayIdentity(year: 2026, month: 10, day: 19)
    static let week = WeeklyReviewWeek(monday: monday, isoKey: "2026-W43")

    static func day(_ offset: Int) -> DayIdentity { monday.adding(days: offset) ?? monday }

    static func rule(_ key: String, _ title: String, at minute: Int?) -> ProtocolRule {
        ProtocolRule(key: RuleKey(rawValue: key), title: title, timeOfDayMinutes: minute)
    }

    static func week(_ states: [CheckState]) -> [WeeklyRuleDay] {
        states.enumerated().map { WeeklyRuleDay(day: day($0.offset), state: $0.element) }
    }

    static var input: WeeklyStoryInput {
        let kitchen = rule("kitchen", "Kitchen closes", at: 18 * 60 + 30)
        let screens = rule("screens", "Screens off", at: 21 * 60 + 45)
        let light = rule("light", "Morning light", at: 7 * 60)
        let kept = CheckState.kept, missed = CheckState.missed
        let rules = [
            WeeklyRuleWeek(rule: kitchen, days: week([kept, kept, kept, kept, kept, missed, missed])),
            WeeklyRuleWeek(rule: screens, days: week([kept, kept, kept, kept, kept, kept, kept])),
            WeeklyRuleWeek(rule: light, days: week([kept, kept, kept, kept, missed, kept, kept]))
        ]
        let outcomes = [
            WeeklyOutcomeWeek(kind: .sleepHeartRate, weekMean: 51.4, nights: 6, usual: NoteUsual(median: 49, nights: 28, windowDays: 30)),
            WeeklyOutcomeWeek(kind: .hrv, weekMean: 60, nights: 6, usual: NoteUsual(median: 60.2, nights: 28, windowDays: 30))
        ]
        // 9 nights missed at 55 bpm and 28 kept at 50 bpm before this week.
        let history = (0..<9).map { WeeklySlipNight(day: day(-60 + $0), missed: true, outcome: 55) }
            + (0..<28).map { WeeklySlipNight(day: day(-50 + $0), missed: false, outcome: 50) }
        let slip = WeeklySlip(rule: kitchen, outcome: .sleepHeartRate, history: history,
                              changeTitle: "Kitchen closes at 18:30 on weekends too")
        return WeeklyStoryInput(days: (0..<7).map { day($0) }, protocolName: "Sleep first", versionNumber: 7, rules: rules,
                                outcomes: outcomes, slips: [slip])
    }

    /// The story on the phone's calendar and language.
    static func result(calendar: Calendar = .current, locale: Locale = .current) -> WeeklyStoryResult {
        WeeklyStoryWriter(context: NoteContext(locale: locale, calendar: calendar)).write(input)
    }

    /// An environment that starts nothing and keeps a decline in memory.
    static func environment(calendar: Calendar = .current) -> WeeklyReviewEnvironment {
        WeeklyReviewEnvironment(now: { Date() }, calendar: calendar, sources: WeeklyReviewSources(),
                                seen: .standard(persisting: false), decisions: InMemoryWeeklyProposalDecisionStore(),
                                startExperiment: { _, _ in })
    }
}
#endif
