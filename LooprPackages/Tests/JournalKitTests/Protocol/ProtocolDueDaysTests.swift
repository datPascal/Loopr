import DomainKit
import Foundation
@testable import JournalKit
import RoutineKit
import XCTest

/// ICP round 4 (R2): the Protocol tab counts only the rules due that day, as Today does (Q3), a past day says when its
/// list changed (Q6), and the day sheet's words (SEN): no "version", no "by design", "Not asked tonight" on an off night.
@MainActor
final class ProtocolDueDaysTests: XCTestCase {
    private typealias Fixture = ProtocolTestData

    private static let panel = ProtocolRule(key: "panel", title: "Blood panel every 3 months",
                                            cadence: RuleCadence(unit: .month, every: 3))
    private static let lifting = ProtocolRule(key: "lifting", title: "Lifting", cadence: .on([.monday, .wednesday, .friday]))
    private static let rules = Fixture.rules + [panel]
    /// The blood panel was done on 2 Nov, so it is due again on 2 Feb.
    private static let panelDone = DayIdentity(year: 2023, month: 11, day: 2)
    private static let progress: [RuleKey: RuleProgress] = [
        "panel": .due(lastDone: panelDone, next: DayIdentity(year: 2024, month: 2, day: 2))
    ]

    private static func tuesday(_ extra: [RuleKey: CheckState] = [:],
                                rules: [ProtocolRule] = ProtocolDueDaysTests.rules) -> ProtocolDayInput {
        var states: [RuleKey: CheckState] = ["light": .kept, "caffeine": .kept, "meal": .kept, "alcohol": .pending,
                                             "zone2": .kept, "training": .kept, "magnesium": .pending, "screens": .pending,
                                             "bed": .pending, "stretch": .pending]
        states.merge(extra) { _, new in new }
        return Fixture.input(14, .today, states, rules: rules)
    }

    private static func week(tuesday: ProtocolDayInput = ProtocolDueDaysTests.tuesday(), monday: [RuleKey: CheckState] = [:],
                             mondayVersion: Int? = 3,
                             mondayRules: [ProtocolRule] = ProtocolDueDaysTests.rules) -> [ProtocolDayInput] {
        let monday = Fixture.input(13, .past, monday, rules: mondayRules)
        return [ProtocolDayInput(day: monday.day, phase: .past, rules: monday.rules, version: mondayVersion),
                ProtocolDayInput(day: tuesday.day, phase: .today, rules: tuesday.rules, version: 3)]
            + (15...19).map { day in
                let input = Fixture.input(day, .future, [:], rules: Self.rules)
                return ProtocolDayInput(day: input.day, phase: .future, rules: input.rules, version: 3)
            }
    }

    private static func data(week: [ProtocolDayInput], progress: [RuleKey: RuleProgress] = ProtocolDueDaysTests.progress,
                             rules: [ProtocolRule] = ProtocolDueDaysTests.rules,
                             versions: [ProtocolVersion] = []) -> ProtocolRoutineData {
        ProtocolRoutineData(protocolName: "My protocol", version: 3, versionCreatedAt: Fixture.now, dayNumber: 21, rules: rules,
                            week: week, lastWeek: [], today: Fixture.day(14), nowMinute: 22 * 60, progress: progress,
                            versions: versions)
    }

    // MARK: Q3, one count for one day

    func testTodayCountsTheTenRulesDueAsTodaysListDoes() throws {
        let data = Self.data(week: Self.week())
        let raw = try XCTUnwrap(data.todayInput)
        let counted = try XCTUnwrap(data.countedToday)
        XCTAssertEqual(raw.rules.count, 11)
        XCTAssertEqual(counted.rules.map(\.rule.key), Fixture.rules.map(\.key), "The blood panel is not due until February")
        // The same due test Today's list uses (`TodayNoteRailReaders.dueRules` asks `ProtocolDeckQueue.isDue`).
        let todayList = Self.rules.filter { rule in
            ProtocolDeckQueue.isDue(rule, on: Fixture.day(14), keptThisWeek: 0, progress: Self.progress[rule.key])
        }
        XCTAssertEqual(counted.rules.map(\.rule.key), todayList.map(\.key))
        let rosette = ProtocolDayPresentation.make(counted, week: Fixture.calendar)
        XCTAssertEqual(rosette.accessibilitySummary, "Today, Tuesday, 5 of 10 rules kept, 5 pending")
        XCTAssertEqual(ProtocolDayPresentation.make(raw, week: Fixture.calendar).accessibilitySummary,
                       "Today, Tuesday, 5 of 11 rules kept, 6 pending", "Before round 4 the rosette counted 11")
        let monday = ProtocolDayPresentation.make(data.countedWeek[0], week: Fixture.calendar)
        XCTAssertEqual(monday.total, 10, "Not known on Monday never counts a rule that was not due")
        XCTAssertEqual(ProtocolDayPresentation.make(data.countedWeek[3], week: Fixture.calendar).accessibilitySummary,
                       "Thursday, 10 rules ahead")
    }

    func testARuleAnsweredOnADayItWasNotDueStaysCounted() throws {
        // The panel was ticked today: today counts it, and the days after leave it out until February.
        let progress: [RuleKey: RuleProgress] = ["panel": .due(lastDone: Fixture.day(14), next: DayIdentity(year: 2024, month: 2, day: 14))]
        let data = Self.data(week: Self.week(tuesday: Self.tuesday(["panel": .kept])), progress: progress)
        XCTAssertEqual(data.countedToday?.rules.count, 11)
        XCTAssertEqual(data.countedToday?.rules.last?.state, .kept)
        XCTAssertFalse(data.countedWeek[2].rules.contains { $0.rule.key == "panel" })
        // A rule not due today and not kept by the person, but skipped, stays as skipped.
        let skipped = Self.data(week: Self.week(tuesday: Self.tuesday(["panel": .skipped])))
        XCTAssertEqual(skipped.countedToday?.rules.last?.state, .skipped)
    }

    func testTheHeroThisWeekAndTheRosettesCountTheSameDays() async throws {
        let week = Self.week(monday: ["light": .kept, "caffeine": .kept, "meal": .missed, "alcohol": .kept, "zone2": .kept,
                                      "training": .kept, "magnesium": .kept, "screens": .kept, "bed": .kept, "stretch": .kept,
                                      "panel": .unknown])
        let model = ProtocolTabModel(source: DueSource(data: Self.data(week: week)),
                                     habits: HabitViewModel(store: InMemoryHabitStore()),
                                     timeZone: Fixture.zone, locale: Fixture.locale, now: { Fixture.now })
        await model.load()
        XCTAssertEqual(Array(model.days.map(\.total).prefix(2)), [10, 10])
        XCTAssertEqual(model.days[0].unknown, 0, "Monday's not known blood panel was not due, so it is left out")
        let summary = try XCTUnwrap(model.summary)
        let routine = try XCTUnwrap(model.routine)
        let thisWeek = ProtocolThisWeek.make(rules: routine.rules, week: routine.countedWeek, progress: routine.progress,
                                             today: routine.today, calendar: Fixture.calendar)
        XCTAssertEqual(summary.line, "14 of 15 kept this week")
        XCTAssertEqual(thisWeek.count.kept, summary.kept)
        XCTAssertEqual(thisWeek.count.decided, summary.decided)
        XCTAssertEqual(thisWeek.count.unknown, 0)
        XCTAssertEqual(model.days.reduce(0) { $0 + $1.kept }, summary.kept)
    }

    // MARK: Q3, the day sheet's "Not due" line

    func testTheDaySheetNamesTheRulesThatAreNotDueAndWhenTheyAreNext() throws {
        let data = Self.data(week: Self.week())
        let today = try XCTUnwrap(ProtocolDayRules.content(for: Fixture.day(14), routine: data, calendar: Fixture.calendar))
        XCTAssertEqual(today.rows.count, 10)
        XCTAssertFalse(today.rows.contains { $0.ruleKey == "panel" })
        XCTAssertEqual(today.notDue, "Not due today: Blood panel, next in February.")
        let monday = try XCTUnwrap(ProtocolDayRules.content(for: Fixture.day(13), routine: data, calendar: Fixture.calendar))
        XCTAssertEqual(monday.notDue, "Not due that day: Blood panel, next in February.")
        let everyDay = Self.data(week: Self.week(tuesday: Self.tuesday(rules: Fixture.rules), mondayRules: Fixture.rules),
                                 rules: Fixture.rules)
        XCTAssertNil(ProtocolDayRules.content(for: Fixture.day(14), routine: everyDay, calendar: Fixture.calendar)?.notDue)
    }

    func testWeeklyAndChosenDayRulesSayTheirNextDay() throws {
        let sauna = ProtocolRule(key: "sauna", title: "Sauna once a week", cadence: RuleCadence(unit: .week))
        let rules = Fixture.rules + [sauna, Self.lifting]
        // The loader leaves Lifting off Tuesday, which is not one of its days. Sauna was done on Monday.
        let monday = Fixture.input(13, .past, ["sauna": .kept, "lifting": .kept], rules: rules)
        let tuesday = Self.tuesday(rules: Fixture.rules + [sauna])
        let data = Self.data(week: [monday, tuesday], progress: [:], rules: rules)
        let content = try XCTUnwrap(ProtocolDayRules.content(for: Fixture.day(14), routine: data, calendar: Fixture.calendar))
        XCTAssertEqual(content.notDue, "Not due today: Sauna, next on Monday. Lifting, next on Wednesday.")
        XCTAssertEqual(content.rows.count, 10)
    }

    func testTheNextDayReadsAsAWeekdayADateOrAMonth() {
        let calendar = Fixture.calendar
        XCTAssertEqual(ProtocolDayRules.nextText(Fixture.day(20), from: Fixture.day(14), calendar: calendar), "next on Monday")
        XCTAssertEqual(ProtocolDayRules.nextText(Fixture.day(28), from: Fixture.day(14), calendar: calendar), "next on 28 Nov")
        XCTAssertEqual(ProtocolDayRules.nextText(DayIdentity(year: 2024, month: 2, day: 2), from: Fixture.day(14), calendar: calendar),
                       "next in February")
        XCTAssertEqual(ProtocolDayRules.nextText(DayIdentity(year: 2024, month: 11, day: 2), from: Fixture.day(14), calendar: calendar),
                       "next in November 2024")
        XCTAssertNil(ProtocolDayRules.nextText(Fixture.day(14), from: Fixture.day(14), calendar: calendar))
        XCTAssertEqual(ProtocolDayRules.notDueName(ProtocolRule(key: "z", title: "Zone 2, 150 min a week"), locale: Fixture.locale),
                       "Zone 2")
        XCTAssertEqual(ProtocolDayRules.notDueName(ProtocolRule(key: "s", title: "Strength 3 times a week"), locale: Fixture.locale),
                       "Strength")
    }

    // MARK: Q6, a past day keeps its list

    private func versions(_ id: ProtocolID = ProtocolID()) throws -> [ProtocolVersion] {
        func at(_ day: Int, month: Int = 11) -> Date {
            Fixture.calendar.date(DayIdentity(year: 2023, month: month, day: day)) ?? Fixture.now
        }
        let zone2Daily = ProtocolRule(key: "zone2-daily", title: "Zone 2, 45 min")
        return [try ProtocolVersion(protocolID: id, number: 1, createdAt: at(25, month: 10), rules: Fixture.rules + [zone2Daily]),
                try ProtocolVersion(protocolID: id, number: 2, createdAt: at(30, month: 10), note: "Kept the caffeine result",
                                    rules: Fixture.rules + [zone2Daily]),
                try ProtocolVersion(protocolID: id, number: 3, createdAt: at(2), rules: Self.rules)]
    }

    func testAPastDayWithAnOlderListSaysWhenTheRulesChanged() throws {
        let versions = try versions()
        let old = Self.week(mondayVersion: 1, mondayRules: versions[0].rules)
        let data = Self.data(week: old, versions: versions)
        let monday = try XCTUnwrap(ProtocolDayRules.content(for: Fixture.day(13), routine: data, calendar: Fixture.calendar))
        XCTAssertEqual(monday.listChange, "You changed your rules on 2 Nov. This day shows the list you had then.")
        XCTAssertTrue(monday.rows.contains { $0.ruleKey == "zone2-daily" }, "The day keeps the list it had")
        XCTAssertNil(monday.notDue, "The blood panel was not on Monday's list")
        let second = Self.data(week: Self.week(mondayVersion: 2, mondayRules: versions[1].rules), versions: versions)
        XCTAssertEqual(ProtocolDayRules.content(for: Fixture.day(13), routine: second, calendar: Fixture.calendar)?.listChange,
                       "You changed your rules on 2 Nov. This day shows the list you had then.",
                       "Version 2 kept the same rules, so the change is version 3's")
        XCTAssertNil(ProtocolDayRules.content(for: Fixture.day(14), routine: data, calendar: Fixture.calendar)?.listChange, "Today")
        let same = Self.data(week: Self.week(), versions: versions)
        XCTAssertNil(ProtocolDayRules.content(for: Fixture.day(13), routine: same, calendar: Fixture.calendar)?.listChange,
                     "Monday's list is today's")
        let unread = Self.data(week: old)
        XCTAssertNil(ProtocolDayRules.content(for: Fixture.day(13), routine: unread, calendar: Fixture.calendar)?.listChange,
                     "Without the versions there is no date to name")
    }

    // MARK: Words (SEN)

    func testAnOffNightReadsNotAskedTonight() throws {
        let magnesium = ProtocolRuleDay(rule: Fixture.magnesium, state: nil, offNightTest: "magnesium")
        let today = try XCTUnwrap(ProtocolDayRules.rows(for: ProtocolDayInput(day: Fixture.day(14), phase: .today, rules: [magnesium]),
                                                        locale: Fixture.locale).first)
        XCTAssertEqual(today.stateText, "Not asked tonight")
        XCTAssertEqual(today.detail, "Off night in the magnesium test.")
        XCTAssertTrue(today.isNotAsked)
        XCTAssertEqual(today.accessibilityLabel, "Magnesium, 300 mg, Not asked tonight, Off night in the magnesium test.")
        let past = try XCTUnwrap(ProtocolDayRules.rows(for: ProtocolDayInput(day: Fixture.day(13), phase: .past, rules: [magnesium]),
                                                       locale: Fixture.locale).first)
        XCTAssertEqual(past.stateText, "Not asked that night")
        let changed = ProtocolRuleDay(rule: Fixture.magnesium, state: .kept, decidedBy: .manual, overriddenByPerson: true,
                                      offNightTest: "magnesium")
        let kept = try XCTUnwrap(ProtocolDayRules.rows(for: ProtocolDayInput(day: Fixture.day(14), phase: .today, rules: [changed])).first)
        XCTAssertEqual(kept.stateText, "Kept", "The person's own answer on an off night reads as theirs")
        XCTAssertFalse(kept.isNotAsked)
    }

    func testTheDaySheetNeverSaysVersionOrByDesign() throws {
        let versions = try versions()
        var week = Self.week(mondayVersion: 1, mondayRules: versions[0].rules)
        let offNight = week[1].rules.map { item in
            item.rule.key == "magnesium" ? ProtocolRuleDay(rule: item.rule, state: nil, offNightTest: "magnesium") : item
        }
        week[1] = ProtocolDayInput(day: week[1].day, phase: .today, rules: offNight, version: 3)
        let data = Self.data(week: week, versions: versions)
        for day in week.map(\.day) {
            let content = try XCTUnwrap(ProtocolDayRules.content(for: day, routine: data, calendar: Fixture.calendar))
            let words = [content.title, content.lead, content.notDue, content.listChange].compactMap { $0 }
                + content.rows.flatMap { [$0.title, $0.stateText, $0.detail, $0.resetTitle, $0.accessibilityLabel].compactMap { $0 } }
            for text in words {
                XCTAssertFalse(text.localizedCaseInsensitiveContains("version"), text)
                XCTAssertFalse(text.localizedCaseInsensitiveContains("by design"), text)
            }
        }
    }
}

/// A source that hands the model one fixed week.
private struct DueSource: ProtocolTabSource {
    let data: ProtocolRoutineData

    func load(now: Date) async -> ProtocolTabContent { ProtocolTabContent(routine: .ready(data)) }
    func tick(_ key: RuleKey, day: DayIdentity, now: Date) async throws {}
    func override(_ key: RuleKey, day: DayIdentity, kept: Bool, now: Date) async throws {}
    func clear(_ key: RuleKey, day: DayIdentity, now: Date) async throws {}
}
