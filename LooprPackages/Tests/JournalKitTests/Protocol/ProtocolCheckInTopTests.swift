import DomainKit
import Foundation
@testable import JournalKit
import RoutineKit
import XCTest

/// ICP round 2, W1: the top of the check-in. One hero line, the first days' line, the later list with answer now, the
/// deck's due rule for longer periods, and the rosette week's seven equal columns.
final class ProtocolCheckInTopTests: XCTestCase {
    private typealias Fixture = ProtocolTestData

    private let monday: [RuleKey: CheckState] = ["light": .kept, "caffeine": .kept, "meal": .kept, "alcohol": .kept,
        "zone2": .kept, "training": .kept, "magnesium": .kept, "screens": .kept, "bed": .missed, "stretch": .unknown]

    // MARK: Hero (R2-NEW-01, R2-NEW-03, R2-DES-01, R2-DES-06)

    func testTheHeroIsOneLineWithTheRuleNotKept() {
        let summary = ProtocolWeekSummary.make(week: Fixture.week(monday: monday), calendar: Fixture.calendar, dayNumber: 21)
        XCTAssertEqual(summary.hero, "13 of 14 kept this week \u{00B7} In bed not kept on Monday")
        XCTAssertEqual(summary.percent, 93)
        var kept = monday; kept["bed"] = .kept
        let clean = ProtocolWeekSummary.make(week: Fixture.week(monday: kept), calendar: Fixture.calendar, dayNumber: 21)
        XCTAssertEqual(clean.hero, "14 of 14 kept this week")
    }

    func testTheFirstTwoDaysSayOnePlainLine() {
        let open = [Fixture.input(14, .today, [:], rules: [Fixture.magnesium, Fixture.screens, Fixture.zone2])]
            + (15...19).map { Fixture.input($0, .future, [:]) }
        let first = ProtocolWeekSummary.make(week: open, calendar: Fixture.calendar, dayNumber: 1)
        XCTAssertEqual(first.hero, "Day 1. Answer tonight's cards to fill your first dot.")
        XCTAssertNil(first.percent)
        XCTAssertEqual(ProtocolWeekSummary.make(week: open, calendar: Fixture.calendar, dayNumber: 2).hero,
                       "Day 2. Answer tonight's cards to fill today's dots.")
        let one = [Fixture.input(14, .today, [:], rules: [Fixture.magnesium, Fixture.zone2])]
        XCTAssertEqual(ProtocolWeekSummary.make(week: one, calendar: Fixture.calendar, dayNumber: 1).hero,
                       "Day 1. Answer tonight's card to fill your first dot.")
        let sources = [Fixture.input(14, .today, [:], rules: [Fixture.zone2, Fixture.caffeine])]
        XCTAssertEqual(ProtocolWeekSummary.make(week: sources, calendar: Fixture.calendar, dayNumber: 1).hero,
                       "Day 1. Your first dots fill in as Loopr checks your rules.")
        let answered = [Fixture.input(14, .today, ["magnesium": .kept, "zone2": .missed],
                                      rules: [Fixture.magnesium, Fixture.zone2])]
        XCTAssertEqual(ProtocolWeekSummary.make(week: answered, calendar: Fixture.calendar, dayNumber: 1).hero,
                       "Day 1. 1 of 2 kept so far.")
    }

    // MARK: Later and answer now (R2-SEN-01, R2-NEW-04, R2-DES-17, R2-VET-04, R2-HAB-04)

    func testTheLaterListUsesTheRulesOwnNameAndOnlyRulesThePersonTicks() throws {
        // The gentle start's In bed is the band's, with a check time that is not its bedtime.
        let bed = ProtocolRule(key: "in-bed", title: "In bed by 22:30", timeOfDayMinutes: 21 * 60 + 45, source: .band,
                               isEvening: true)
        let drink = ProtocolRule(key: "alcohol", title: "One drink at most", isEvening: true)
        let reading = ProtocolRule(key: "read", title: "Read before bed", timeOfDayMinutes: 22 * 60, isEvening: true)
        let today = Fixture.input(14, .today, [:], rules: [bed, drink, reading])
        let later = try XCTUnwrap(ProtocolDeckQueue.later(today: today, nowMinute: 12 * 60, locale: Fixture.locale))
        XCTAssertEqual(later.keys, ["read", "alcohol"])
        XCTAssertEqual(later.items.map(\.when), ["22:00", "tonight"])
        XCTAssertFalse(later.text.contains("21:45"), later.text)
        let named = ProtocolDeckQueue.later(today: Fixture.tuesday, nowMinute: 19 * 60, locale: Fixture.locale)
        XCTAssertEqual(named?.items.map(\.name), ["Magnesium, 300 mg", "Screens off by 21:45"])
        XCTAssertEqual(named?.items.map(\.when), ["21:30", nil], "A name that says its time gets no second time")
        XCTAssertEqual(named?.items.first?.accessibilityIdentifier, "protocol-deck-later-magnesium")
    }

    func testARuleFromTheLaterListIsAnsweredNow() {
        let evening = 19 * 60 + 49
        let questions = ProtocolDeckQueue.questions(today: Fixture.tuesday, nowMinute: evening, early: ["screens"],
                                                    locale: Fixture.locale)
        XCTAssertEqual(questions.map(\.key), ["screens", "stretch"], "The rule brought forward leads the deck")
        let later = ProtocolDeckQueue.later(today: Fixture.tuesday, nowMinute: evening, early: ["screens"], locale: Fixture.locale)
        XCTAssertEqual(later?.keys, ["magnesium"])
        let answered = Fixture.input(14, .today, ["screens": .kept], rules: [Fixture.magnesium, Fixture.screens])
        XCTAssertEqual(ProtocolDeckQueue.questions(today: answered, nowMinute: evening, early: ["screens"]).map(\.key), [],
                       "Once answered it leaves the deck")
    }

    @MainActor func testTheModelBringsALaterRuleToTheFrontOfTheDeck() async {
        let model = ProtocolTabModel(source: RecordingSource(nowMinute: 19 * 60 + 49),
                                     habits: HabitViewModel(store: InMemoryHabitStore()),
                                     timeZone: Fixture.zone, locale: Fixture.locale, now: { Fixture.now })
        await model.load()
        XCTAssertEqual(model.deck.map(\.key), ["stretch"])
        XCTAssertEqual(model.waitingLine, "Done for now.", "Morning light was ticked today, and the later list names the rest")
        model.answerEarly("magnesium")
        model.answerEarly("magnesium")
        XCTAssertEqual(model.early, ["magnesium"])
        XCTAssertEqual(model.deck.map(\.key), ["magnesium", "stretch"])
        XCTAssertEqual(model.deckLater?.keys, ["screens"])
        XCTAssertNil(model.closing)
    }

    // MARK: Due (R2-VET-06)

    func testTheDeckAsksOnlyRulesDueToday() {
        let swim = ProtocolRule(key: "swim", title: "Swim", isEvening: true, cadence: .timesAWeek(2))
        let sauna = ProtocolRule(key: "sauna", title: "Sauna", isEvening: true, cadence: .timesAWeek(1))
        let panel = ProtocolRule(key: "panel", title: "Blood panel", cadence: RuleCadence(unit: .month, every: 3))
        let gym = ProtocolRule(key: "gym", title: "Gym", isEvening: true, cadence: .on([.monday, .wednesday]))
        let rules = [swim, sauna, panel, gym]
        let monday = Fixture.input(13, .past, ["swim": .kept, "sauna": .kept, "gym": .kept], rules: rules)
        let tuesday = Fixture.input(14, .today, [:], rules: rules)
        let week = [monday, tuesday]
        let soon: [RuleKey: RuleProgress] = ["panel": .due(lastDone: Fixture.day(1), next: DayIdentity(year: 2024, month: 2, day: 1))]
        let asked = ProtocolDeckQueue.questions(today: tuesday, week: week, progress: soon, nowMinute: 22 * 60).map(\.key)
        XCTAssertEqual(asked, ["swim"], "Swim has one of two this week; the weekly sauna is done, the panel waits, gym is off")
        XCTAssertFalse(ProtocolDeckQueue.isDue(swim, on: Fixture.day(14), keptThisWeek: 2), "Twice a week, kept twice")
        let due: [RuleKey: RuleProgress] = ["panel": .due(lastDone: DayIdentity(year: 2023, month: 8, day: 14), next: Fixture.day(14))]
        XCTAssertTrue(ProtocolDeckQueue.questions(today: tuesday, week: week, progress: due, nowMinute: 22 * 60).map(\.key)
            .contains("panel"), "Due on its day")
        XCTAssertTrue(ProtocolDeckQueue.isDue(panel, on: Fixture.day(14), keptThisWeek: 0, progress: .due(lastDone: nil, next: nil)),
                      "Never done is due")
    }

    // MARK: Rosette week (R2-DES-03, R2-SEN-07)

    @MainActor func testTheWeekHasSevenEqualColumnsAndTodayIsOneAndAHalfTimesAPastDay() {
        // An iPhone 17's content width (402 less two 20 pt gutters) fits today's ring between its neighbours.
        let narrow = ProtocolRosetteWeek.pastSize(width: 362)
        XCTAssertEqual(narrow, 38.2, accuracy: 0.1)
        let today = ProtocolRosetteWeek.size(width: 362, isToday: true)
        XCTAssertEqual(today, narrow * 1.5, accuracy: 0.01)
        let column: CGFloat = 362 / 7
        XCTAssertLessThanOrEqual(today / 2 + ProtocolRosetteWeek.ringGap + narrow / 2, column - ProtocolRosetteWeek.ringGap)
        XCTAssertEqual(ProtocolRosetteWeek.pastSize(width: 440), 44, "A wide phone gets the full 44 pt")
        XCTAssertLessThanOrEqual(ProtocolRosetteWeek.size(width: 440, isToday: true) + 2 * ProtocolRosetteWeek.ringGap,
                                 ProtocolRosetteWeek.height)
    }

    @MainActor func testTheKeySaysNotKeptIsNotGrey() {
        XCTAssertFalse(ProtocolRosetteLegend.accessibilityText.contains("grey dot is not kept"))
        XCTAssertEqual(ProtocolRosetteLegend.label(.missed), "Not kept")
    }
}
