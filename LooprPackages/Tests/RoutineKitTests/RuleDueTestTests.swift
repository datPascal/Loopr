import DomainKit
import Foundation
import RoutineKit
import Testing

/// ICP R4 Q3: one due test for Today, the check-in's counts and the weekly review. A day counts a rule that was due, and
/// any rule with an answer that day.
@Suite("Rule due test")
struct RuleDueTestTests {
    /// Mon 13 to Sun 19 Nov 2023.
    private func day(_ value: Int) -> DayIdentity { DayIdentity(year: 2023, month: 11, day: value) }
    private let panel = ProtocolRule(key: "panel", title: "Blood panel every 3 months", cadence: RuleCadence(unit: .month, every: 3))
    private let sauna = ProtocolRule(key: "sauna", title: "Sauna", cadence: RuleCadence(unit: .week))
    private let strength = ProtocolRule(key: "strength", title: "Strength", cadence: .timesAWeek(2))
    private let lifting = ProtocolRule(key: "lifting", title: "Lifting", cadence: .on([.monday, .wednesday, .friday]))

    @Test("A blood panel done on 2 Nov is not due again until 2 Feb")
    func longerRuleWaitsForItsNextDay() {
        let done = DayIdentity(year: 2023, month: 11, day: 2)
        #expect(!RuleDueTest.isDue(panel, on: day(14), keptThisWeek: 0, lastDone: done))
        #expect(RuleDueTest.isDue(panel, on: DayIdentity(year: 2024, month: 2, day: 2), keptThisWeek: 0, lastDone: done))
        #expect(RuleDueTest.isDue(panel, on: day(14), keptThisWeek: 0, lastDone: nil), "Never done is due")
        #expect(RuleDueTest.nextDue(panel, after: day(14), keptThisWeek: 0, lastDone: done) == DayIdentity(year: 2024, month: 2, day: 2))
        #expect(RuleDueTest.nextDue(panel, after: day(14), keptThisWeek: 0, lastDone: nil) == nil, "Due today: no next day")
    }

    @Test("A week of checks counts a rule only on days it was due, and every day it has an answer")
    func countedDays() {
        // The weekly sauna, kept on Wednesday: due Monday and Tuesday, kept Wednesday, then done for the week.
        let week: [(day: DayIdentity, state: CheckState?)] = [(day(13), .unknown), (day(14), nil), (day(15), .kept),
                                                              (day(16), .unknown), (day(17), .skipped), (day(18), nil)]
        #expect(RuleDueTest.counted(sauna, days: week, lastDone: nil) == [true, true, true, false, true, false])
        let count = RoutineWeekCount(rule: sauna, days: week)
        #expect(count.kept == 1)
        #expect(count.unknown == 1, "Thursday's not known check was not due, so it is left out")
        #expect(count.skipped == 1, "A skip is an answer and stays")
        // A daily rule counts every day.
        #expect(RuleDueTest.counted(ProtocolRule(key: "light", title: "Morning light"), days: week, lastDone: nil).allSatisfy { $0 })
    }

    @Test("A rule done twice a week is done after the second time; a rule on chosen days waits for its next one")
    func nextDayOfWeeklyAndChosenDayRules() {
        #expect(RuleDueTest.isDue(strength, on: day(15), keptThisWeek: 1, lastDone: nil))
        #expect(!RuleDueTest.isDue(strength, on: day(15), keptThisWeek: 2, lastDone: nil))
        #expect(RuleDueTest.nextDue(strength, after: day(15), keptThisWeek: 2, lastDone: nil) == day(20), "The next Monday")
        #expect(RuleDueTest.nextDue(sauna, after: day(19), keptThisWeek: 1, lastDone: day(15)) == day(20))
        #expect(!RuleDueTest.isDue(lifting, on: day(14), keptThisWeek: 0, lastDone: nil))
        #expect(RuleDueTest.nextDue(lifting, after: day(14), keptThisWeek: 0, lastDone: nil) == day(15), "Wednesday")
        #expect(RuleDueTest.nextDue(lifting, after: day(18), keptThisWeek: 0, lastDone: nil) == day(20), "Saturday to Monday")
        #expect(RuleDueTest.nextDue(lifting, after: day(17), keptThisWeek: 0, lastDone: nil) == nil, "Friday is a lifting day")
    }

    @Test("A blood panel done this week counts on its day, and not after")
    func longerRuleDoneThisWeek() {
        let week: [(day: DayIdentity, state: CheckState?)] = [(day(13), nil), (day(14), .kept), (day(15), nil)]
        #expect(RuleDueTest.counted(panel, days: week, lastDone: DayIdentity(year: 2023, month: 8, day: 1)) == [true, true, false])
        #expect(RuleDueTest.counted(panel, days: week, lastDone: DayIdentity(year: 2023, month: 11, day: 2)) == [false, true, false])
    }
}
