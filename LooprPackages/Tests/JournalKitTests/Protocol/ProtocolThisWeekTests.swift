import DomainKit
import Foundation
@testable import JournalKit
import RoutineKit
import XCTest

/// ICP R3-VET-01, R3-VET-02: "This week" opens the hero's number into one row per rule, counted with the hero's function.
final class ProtocolThisWeekTests: XCTestCase {
    private typealias Fixture = ProtocolTestData

    /// Monday: two rules not kept, one skipped and one a source could not tell. Tuesday as `ProtocolTestData.tuesday`.
    private let monday: [RuleKey: CheckState] = ["light": .kept, "caffeine": .skipped, "meal": .missed, "alcohol": .unknown,
                                                 "zone2": .kept, "training": .kept, "magnesium": .kept, "screens": .kept,
                                                 "bed": .missed, "stretch": .kept]

    private func content(_ week: [ProtocolDayInput], rules: [ProtocolRule] = Fixture.rules,
                         progress: [RuleKey: RuleProgress] = [:]) -> ProtocolThisWeekContent {
        ProtocolThisWeek.make(rules: rules, week: week, progress: progress, today: Fixture.day(14), calendar: Fixture.calendar)
    }

    func testTheTotalIsTheHerosAndEveryRuleHasARow() {
        let week = Fixture.week(monday: monday)
        let content = content(week)
        let summary = ProtocolWeekSummary.make(week: week, calendar: Fixture.calendar, dayNumber: 21)
        XCTAssertEqual(content.count.kept, summary.kept)
        XCTAssertEqual(content.count.decided, summary.decided)
        XCTAssertEqual(content.count, RoutineWeekCount(states: week.filter { $0.phase != .future }.flatMap(\.rules).map(\.state)))
        XCTAssertEqual(content.title, "This week, 13 to 19 Nov")
        XCTAssertEqual(content.lead, "11 of 13 kept so far.")
        XCTAssertEqual(content.rows.map(\.ruleKey), Fixture.rules.map(\.key))
        XCTAssertEqual(content.foot, "None of the 13 were changed by you.")
    }

    func testEachRowSaysItsCountWhoChecksItAndWhatIsMissing() throws {
        let rows = content(Fixture.week(monday: monday)).rows
        func row(_ key: RuleKey) throws -> ProtocolThisWeekRow { try XCTUnwrap(rows.first { $0.ruleKey == key }) }
        XCTAssertEqual(try row("light").countText, "2 of 2 kept")
        XCTAssertEqual(try row("light").detail, "Checked by you")
        XCTAssertEqual(try row("caffeine").countText, "1 of 1 kept")
        XCTAssertEqual(try row("caffeine").detail, "Checked by Food \u{00B7} 1 skipped")
        // Monday had no answer for No alcohol; today is still open, so it is not counted as not known.
        XCTAssertEqual(try row("alcohol").countText, "No answer yet")
        XCTAssertEqual(try row("alcohol").detail, "Checked by Food \u{00B7} 1 not known")
        XCTAssertEqual(try row("bed").countText, "0 of 1 kept")
        XCTAssertEqual(try row("bed").detail, "Checked by the band")
        XCTAssertEqual(try row("magnesium").notKnown, 0, "Tonight's open magnesium is not a missing answer")
        XCTAssertNil(try row("light").schedule, "A daily rule has no schedule line")
        XCTAssertEqual(try row("alcohol").accessibilityLabel, "No alcohol, No answer yet, Checked by Food \u{00B7} 1 not known")
    }

    func testAnswersChangedOverASourceAreCounted() throws {
        let changedMonday = Fixture.input(13, .past, ["light": .kept, "caffeine": .missed, "meal": .kept],
                                          overridden: ["caffeine", "light"])
        let content = content([changedMonday, Fixture.tuesday] + (15...19).map { Fixture.input($0, .future, [:]) })
        XCTAssertEqual(content.foot, "1 of the \(content.count.decided) was changed by you.",
                       "A tick on a rule the person answers is not a change")
        XCTAssertEqual(try XCTUnwrap(content.rows.first { $0.ruleKey == "caffeine" }).detail, "Checked by Food \u{00B7} 1 changed by you")
        XCTAssertEqual(ProtocolThisWeek.changesLine(2, of: 13), "2 of the 13 were changed by you.")
    }

    func testRulesWithALongerPeriodShowTheirProgressAndNoMissingDays() throws {
        let panel = ProtocolRule(key: "panel", title: "Blood panel every 3 months", cadence: RuleCadence(unit: .month, every: 3))
        let weekly = ProtocolRule(key: "zone2-week", title: "Zone 2, 150 min a week",
                                  target: RuleTarget(kind: .atLeast, metric: RoutineMetric.zone2Minutes.rawValue, value: 150, unit: "min"),
                                  source: .band, cadence: RuleCadence(unit: .week))
        let rules = Fixture.rules + [panel, weekly]
        let monday = Fixture.input(13, .past, self.monday.merging(["zone2-week": .unknown]) { $1 }, rules: rules)
        let week = [monday, Fixture.tuesday] + (15...19).map { Fixture.input($0, .future, [:]) }
        let progress: [RuleKey: RuleProgress] = [
            "panel": .due(lastDone: Fixture.day(1), next: DayIdentity(year: 2024, month: 2, day: 1)),
            "zone2-week": .amount(measured: 112, target: 150, unit: "min")
        ]
        let rows = content(week, rules: rules, progress: progress).rows
        let panelRow = try XCTUnwrap(rows.first { $0.ruleKey == "panel" })
        XCTAssertNil(panelRow.countText, "Nothing to answer this week, so no count")
        XCTAssertEqual(panelRow.schedule?.hasPrefix("Every 3 months \u{00B7} last done"), true, panelRow.schedule ?? "")
        let weeklyRow = try XCTUnwrap(rows.first { $0.ruleKey == "zone2-week" })
        XCTAssertEqual(weeklyRow.notKnown, 0, "A weekly rule is not asked every day")
        XCTAssertEqual(weeklyRow.schedule?.contains("112 of 150 min · 6 days left"), true, weeklyRow.schedule ?? "")
    }

    func testARuleThatLeftTheProtocolKeepsItsDays() {
        let old = ProtocolRule(key: "nap", title: "No nap after 15:00")
        let monday = Fixture.input(13, .past, ["nap": .kept], rules: Fixture.rules + [old])
        let content = content([monday, Fixture.tuesday] + (15...19).map { Fixture.input($0, .future, [:]) })
        XCTAssertEqual(content.rows.last?.ruleKey, "nap")
        XCTAssertEqual(content.rows.last?.countText, "1 of 1 kept")
    }

    func testTheHeroSplitsIntoTheNumberAndTheWordsThatOpenTheDay() {
        let slipped = ProtocolWeekSummary.make(week: Fixture.week(monday: monday), calendar: Fixture.calendar, dayNumber: 21)
        XCTAssertEqual(slipped.heroLead, slipped.line)
        XCTAssertEqual(slipped.heroSlip, "Last meal not kept on Monday")
        XCTAssertEqual("\(slipped.heroLead) \u{00B7} \(slipped.heroSlip ?? "")", slipped.hero)
        let kept = ProtocolWeekSummary.make(week: Fixture.week(monday: ["light": .kept]), calendar: Fixture.calendar, dayNumber: 21)
        XCTAssertNil(kept.heroSlip)
        XCTAssertEqual(kept.heroLead, kept.hero)
    }
}
