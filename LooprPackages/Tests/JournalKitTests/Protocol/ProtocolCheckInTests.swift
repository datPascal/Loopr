import DomainKit
import Foundation
import JournalKit
import RoutineKit
import XCTest

/// ICP round 1, W2: the deck holds only rules whose time has come, the rest wait in one line, an experiment's off night
/// skips its rule by design, the check-in closes once nothing is left, and the day sheet says who checked each rule.
final class ProtocolCheckInTests: XCTestCase {
    private typealias Fixture = ProtocolTestData

    // MARK: Deck timing (R1-SEN-02, R1-NEW-06, R1-DES-09)

    func testAt1949OnlyRulesWhoseTimeHasComeAreAskedAndTheRestWait() throws {
        let evening = 19 * 60 + 49
        let questions = ProtocolDeckQueue.questions(today: Fixture.tuesday, nowMinute: evening, locale: Fixture.locale)
        XCTAssertEqual(questions.map(\.key), ["stretch"], "An untimed rule joins at 17:00; 21:30 and later wait")
        let later = try XCTUnwrap(ProtocolDeckQueue.later(today: Fixture.tuesday, nowMinute: evening, locale: Fixture.locale))
        XCTAssertEqual(later.keys, ["magnesium", "screens"], "In bed is the band's to check, so it is not a question to come")
        XCTAssertEqual(later.text, "Later tonight: Magnesium, 300 mg at 21:30, Screens off by 21:45")
    }

    func testAtTheRulesTimeItJoinsTheDeck() {
        let questions = ProtocolDeckQueue.questions(today: Fixture.tuesday, nowMinute: 21 * 60 + 45, locale: Fixture.locale)
        XCTAssertEqual(questions.map(\.key), ["magnesium", "screens", "stretch"])
        XCTAssertNil(ProtocolDeckQueue.later(today: Fixture.tuesday, nowMinute: 21 * 60 + 45, locale: Fixture.locale),
                     "Only the band's In bed is still ahead")
    }

    func testInTheMorningAnUntimedRuleWaitsForTheEvening() throws {
        let morning = 7 * 60 + 12
        XCTAssertTrue(ProtocolDeckQueue.questions(today: Fixture.tuesday, nowMinute: morning).isEmpty)
        let later = try XCTUnwrap(ProtocolDeckQueue.later(today: Fixture.tuesday, nowMinute: morning, locale: Fixture.locale))
        XCTAssertEqual(later.text, "Later today: Magnesium, 300 mg at 21:30, Screens off by 21:45, Stretch tonight",
                       "Under \"This morning\" the list says today, not tonight (ICP R3-DES-06)")
        XCTAssertEqual(ProtocolDeckQueue.later(today: Fixture.tuesday, nowMinute: 12 * 60, locale: Fixture.locale)?.title,
                       "Later tonight", "From noon an evening list says tonight")
        let early = ProtocolRule(key: "pills", title: "Morning pills", timeOfDayMinutes: 7 * 60)
        let lunch = ProtocolRule(key: "walk", title: "Walk after lunch", timeOfDayMinutes: 13 * 60)
        let day = Fixture.input(14, .today, [:], rules: [early, lunch, Fixture.magnesium])
        XCTAssertEqual(ProtocolDeckQueue.questions(today: day, nowMinute: morning).map(\.key), ["pills"],
                       "A morning rule whose time has passed is asked in the morning")
        XCTAssertEqual(ProtocolDeckQueue.later(today: day, nowMinute: morning, locale: Fixture.locale)?.text,
                       "Later today: Walk after lunch at 13:00, Magnesium, 300 mg at 21:30")
    }

    func testTheLaterLineNamesFourRulesThenCounts() {
        let rules = (0..<6).map { ProtocolRule(key: RuleKey(rawValue: "r\($0)"), title: "Rule \($0)", timeOfDayMinutes: 20 * 60 + $0) }
        let line = ProtocolDeckQueue.later(today: Fixture.input(14, .today, [:], rules: rules), nowMinute: 18 * 60,
                                           locale: Fixture.locale)
        XCTAssertEqual(line?.text, "Later tonight: Rule 0 at 20:00, Rule 1 at 20:01, Rule 2 at 20:02, Rule 3 at 20:03, and 2 more")
        XCTAssertEqual(line?.shown.count, 4)
        XCTAssertEqual(line?.more, 2)
    }

    func testTheTitleFollowsTheTimeOfDay() {
        XCTAssertEqual(ProtocolDeckQueue.title(nowMinute: 7 * 60 + 12), "This morning")
        XCTAssertEqual(ProtocolDeckQueue.title(nowMinute: 13 * 60 + 30), "This afternoon")
        XCTAssertEqual(ProtocolDeckQueue.title(nowMinute: 19 * 60 + 49), "Tonight's check-in")
    }

    func testTheProgressHidesWhileTheDeckWaitsForALaterRule() {
        XCTAssertNil(ProtocolDeckProgress(remaining: 0, later: 2).text)
        XCTAssertEqual(ProtocolDeckProgress(remaining: 0, later: 0).text, "All answered")
        XCTAssertEqual(ProtocolDeckProgress(remaining: 2, later: 1).text, "2 left")
    }

    func testTheCardCarriesTheRulesWhy() {
        let rule = ProtocolRule(key: "mg", title: "Magnesium, 300 mg", timeOfDayMinutes: 21 * 60 + 30, isEvening: true,
                                why: "Some people fall asleep sooner with it.")
        let card = ProtocolDeckQueue.questions(today: Fixture.input(14, .today, [:], rules: [rule]), nowMinute: 22 * 60)[0]
        XCTAssertEqual(card.why, "Some people fall asleep sooner with it.")
        XCTAssertNil(ProtocolDeckQueue.questions(today: Fixture.input(14, .today, [:], rules: [Fixture.stretch]))[0].why)
    }

    // MARK: Off nights (R1-VET-02)

    func testAnOffNightSkipsTheRuleByDesignAndSaysSo() {
        let magnesium = ProtocolRuleDay(rule: Fixture.magnesium, state: .pending, decidedBy: .manual, offNightTest: "magnesium")
        let screens = ProtocolRuleDay(rule: Fixture.screens, state: .pending)
        let today = ProtocolDayInput(day: Fixture.day(14), phase: .today, rules: [magnesium, screens])
        XCTAssertEqual(magnesium.state, .skipped)
        XCTAssertTrue(magnesium.isSkippedByDesign)
        XCTAssertEqual(ProtocolDeckQueue.questions(today: today, nowMinute: 22 * 60).map(\.key), ["screens"])
        XCTAssertNil(ProtocolDeckQueue.later(today: today, nowMinute: 20 * 60)?.keys.first { $0 == "magnesium" })
        XCTAssertEqual(ProtocolDeckQueue.offNightLines(today: today), ["Tonight is an off night for the magnesium test."])
        let summary = ProtocolWeekSummary.make(week: [today], calendar: Fixture.calendar)
        XCTAssertEqual(summary.decided, 0, "An off night is never counted as not kept")
    }

    func testThePersonsChangeOnAnOffNightWins() {
        let changed = ProtocolRuleDay(rule: Fixture.magnesium, state: .kept, decidedBy: .manual, overriddenByPerson: true,
                                      offNightTest: "magnesium")
        XCTAssertEqual(changed.state, .kept)
        XCTAssertFalse(changed.isSkippedByDesign)
        let day = ProtocolDayInput(day: Fixture.day(14), phase: .today, rules: [changed])
        XCTAssertTrue(ProtocolDeckQueue.offNightLines(today: day).isEmpty)
        XCTAssertEqual(ProtocolDayRules.rows(for: day).first?.resetTitle, "Back to the off night")
    }

    // MARK: Closing (R1-DES-01, R1-SEN-08)

    func testTheClosingCardSaysTheDayIsDoneAndNamesTomorrowsFirstRule() {
        let closing = ProtocolDeckClosing.make(nowMinute: 22 * 60 + 40, tomorrow: Fixture.rules, locale: Fixture.locale)
        XCTAssertEqual(closing.title, "Tonight is done")
        XCTAssertEqual(closing.detail, "Nothing is left for you to answer.")
        XCTAssertEqual(closing.tomorrow, "Tomorrow: Morning light at 08:00.")
        let noTimes = ProtocolDeckClosing.make(nowMinute: 15 * 60, tomorrow: [Fixture.stretch], locale: Fixture.locale)
        XCTAssertEqual(noTimes.title, "Today is done")
        XCTAssertEqual(noTimes.tomorrow, "Tomorrow: Stretch.")
        // A gentle start: the band checks In bed in the evening, and its own name already says the time (R2-SEN-06).
        let gentle = ProtocolDeckClosing.make(nowMinute: 22 * 60, tomorrow: [Fixture.bed, Fixture.zone2], locale: Fixture.locale)
        XCTAssertEqual(gentle.tomorrow, "Tomorrow: In bed by 22:30.")
        let kitchen = ProtocolRule(key: "kitchen", title: "Kitchen closes", timeOfDayMinutes: 18 * 60 + 30, source: .food,
                                   isEvening: true)
        XCTAssertEqual(ProtocolDeckClosing.make(nowMinute: 22 * 60, tomorrow: [kitchen, Fixture.magnesium, Fixture.bed],
                                                locale: Fixture.locale).tomorrow,
                       "Tomorrow: Magnesium, 300 mg at 21:30.", "A rule the person ticks comes before one Food checks")
        XCTAssertNil(ProtocolDeckClosing.make(nowMinute: 22 * 60, tomorrow: [], locale: Fixture.locale).tomorrow)
        for text in [closing.title, closing.detail, closing.tomorrow ?? ""] {
            for banned in ["streak", "missed", "!", "\u{2014}"] { XCTAssertFalse(text.lowercased().contains(banned), text) }
        }
    }

    // MARK: Day sheet (R1-DES-04, R1-VET-04, R1-SEN-17)

    func testEachRowSaysWhoCheckedItWhatItSawAndWhetherThePersonChangedIt() throws {
        let protein = ProtocolRule(key: "protein", title: "Protein 150 g",
                                   target: RuleTarget(kind: .atLeast, metric: RoutineMetric.proteinG.rawValue, value: 150), source: .food)
        let rules = [
            ProtocolRuleDay(rule: Fixture.caffeine, state: .kept, decidedBy: .food, measuredValue: 615),
            ProtocolRuleDay(rule: protein, state: .kept, decidedBy: .manual, overriddenByPerson: true, measuredValue: 82),
            ProtocolRuleDay(rule: Fixture.zone2, state: nil),
            ProtocolRuleDay(rule: Fixture.alcohol, state: .missed, decidedBy: .food, measuredValue: 2),
            ProtocolRuleDay(rule: Fixture.stretch, state: .skipped, decidedBy: .manual, overriddenByPerson: true),
            ProtocolRuleDay(rule: Fixture.magnesium, state: nil)
        ]
        let rows = ProtocolDayRules.rows(for: ProtocolDayInput(day: Fixture.day(14), phase: .today, rules: rules),
                                         locale: Fixture.locale)
        let byKey = Dictionary(uniqueKeysWithValues: rows.map { ($0.ruleKey, $0) })
        let caffeine = try XCTUnwrap(byKey["caffeine"])
        XCTAssertEqual(caffeine.detail, "Food saw the last caffeine at 10:15.")
        XCTAssertFalse(caffeine.changedByYou)
        XCTAssertNil(caffeine.resetTitle)
        XCTAssertEqual(caffeine.selection, .kept)
        let changed = try XCTUnwrap(byKey["protein"])
        XCTAssertTrue(changed.changedByYou, "A person's change over a source is marked")
        XCTAssertEqual(changed.detail, "Food saw 82 g of protein.", "What the source saw stays traceable")
        XCTAssertEqual(changed.resetTitle, "Use what Food says")
        XCTAssertTrue(changed.accessibilityLabel.contains("Changed by you"))
        XCTAssertEqual(byKey["zone2"]?.detail, "The band checks it as the day goes on.")
        XCTAssertNil(byKey["zone2"]?.selection)
        XCTAssertEqual(byKey["alcohol"]?.detail, "Food saw 2 drinks.")
        let stretch = try XCTUnwrap(byKey["stretch"])
        XCTAssertEqual(stretch.stateText, "Skipped")
        XCTAssertEqual(stretch.detail, "You skipped it.")
        XCTAssertFalse(stretch.changedByYou, "A rule the person checks is theirs, so nothing is marked")
        XCTAssertEqual(stretch.resetTitle, "Clear my answer")
        XCTAssertEqual(byKey["magnesium"]?.detail, "Waiting for your answer.")
        XCTAssertTrue(rows.allSatisfy(\.canChange))
    }

    func testTheSheetTitleNamesTodayAndInvitesAChange() {
        let content = ProtocolDayRules.content(for: Fixture.tuesday, calendar: Fixture.calendar)
        XCTAssertEqual(content.title, "Today, Tuesday 14 Nov")
        XCTAssertEqual(content.lead, "Tap an answer to change it.")
        XCTAssertEqual(ProtocolDayRules.content(for: Fixture.input(13, .past, [:]), calendar: Fixture.calendar).title,
                       "Monday 13 Nov")
    }

    // MARK: About the day (R1-SEN-10)

    func testAQuestionThatAsksTheSameAsARuleIsHidden() {
        let rules = [Fixture.screens, ProtocolRule(key: "read", title: "Read before bed"), Fixture.caffeine, Fixture.alcohol,
                     Fixture.bed]
        for question in ["Read before sleep", "Screens in bed", "Caffeine after 14:00", "Alcohol"] {
            XCTAssertTrue(ProtocolQuestionMatch.matches(question, rules: rules), question)
        }
        for question in ["Shared bed", "Sleep mask", "Travel day", "Nap", "Late meal"] {
            XCTAssertFalse(ProtocolQuestionMatch.matches(question, rules: rules), question)
        }
    }
}
