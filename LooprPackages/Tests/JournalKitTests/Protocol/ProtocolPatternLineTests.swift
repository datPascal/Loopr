import DomainKit
import Foundation
@testable import JournalKit
import RoutineKit
import XCTest

/// ICP round 3 on the check-in (F1): the pattern line's words and rule (R3-NEW-02, R3-SEN-03, R3-VET-03), now two lines
/// with the rule behind the tap (R4 Q7), the swipe hint (R3-HAB-01), the evening count (R3-NEW-04) and the deck slot
/// that closes as a card goes (R3-NEW-08).
@MainActor
final class ProtocolPatternLineTests: XCTestCase {
    private typealias Fixture = ProtocolTestData

    private func pattern(candidate: String = "food.lateMeal", habit: UUID = UUID(), title: String = "Last meal after 21:00",
                         predicate: PatternPredicate = .food(label: "when you eat after 21:00"),
                         metric: HabitOutcomeMetricID = .deepSleepMinutes, strength: PatternStrength = .strong,
                         difference: Double = -19, spread: Double? = 11, with: Int = 9, without: Int = 20) -> FoundPattern {
        FoundPattern(candidateID: candidate, habitID: HabitID(rawValue: habit), title: title, predicate: predicate,
                     metric: metric, strength: strength,
                     effect: PatternEffect(adjustedDifference: difference, rawDifference: difference, withMean: nil,
                                           withoutMean: nil, intervalLower: nil, intervalUpper: nil, pValue: 0.01,
                                           practicalThreshold: 6, unit: metric.unit, spread: spread),
                     nights: PatternNights(with: with, without: without), windowEnd: "2023-11-14", algorithmVersion: "1",
                     foundAt: Fixture.now)
    }

    // MARK: Pattern line

    /// R4 Q7: a headline in the pattern's own words, then its counts, spread and "Not proof of cause." The rule moves to
    /// Patterns, behind the tap.
    func testTheLineIsAHeadlineOverItsCountsAndTheRuleMovesBehindTheTap() throws {
        let finding = try XCTUnwrap(ProtocolPatternFinding.make(pattern(), locale: Fixture.locale))
        XCTAssertEqual(finding.headline, "Last meal after 21:00, 19 min less deep sleep.")
        XCTAssertLessThanOrEqual(finding.headline.count, 46, "About 45 characters, so it is read in one glance")
        XCTAssertEqual(finding.detail, "9 nights against 20. Usual spread 11 min. Not proof of cause.")
        XCTAssertEqual(finding.sentence,
                       "On the 9 nights you ate after 21:00, you had 19 minutes less deep sleep than on the other 20.")
        let named = finding.naming(rules: Fixture.rules)
        XCTAssertEqual(named.rule, "Last meal by 19:00", "A late meal is what the last meal rule measures")
        XCTAssertEqual(named.detail, finding.detail, "The rule is not on the line")
        XCTAssertEqual(named.ruleLine, "Your rule: Last meal by 19:00.", "Patterns names it behind the tap")
        let signal = ProtocolPatternSignal.found(finding).naming(rules: Fixture.rules)
        XCTAssertEqual(signal.title, "Last meal after 21:00, 19 min less deep sleep.")
        XCTAssertEqual(signal.accessibilityLabel,
                       "Last meal after 21:00, 19 min less deep sleep. 9 nights against 20. Usual spread 11 min. Not proof of cause.")
        XCTAssertFalse(signal.accessibilityLabel.contains("Your rule"))
    }

    func testWithoutASpreadTheLineKeepsItsCountsAndNotProof() throws {
        let finding = try XCTUnwrap(ProtocolPatternFinding.make(pattern(spread: nil, with: 1, without: 12), locale: Fixture.locale))
        XCTAssertEqual(finding.detail, "1 night against 12. Not proof of cause.")
        XCTAssertNil(finding.naming(rules: [Fixture.magnesium]).ruleLine, "No rule matches it")
    }

    func testTheHeadlineSaysWhatMovedAndShortensALongName() throws {
        let hrv = try XCTUnwrap(ProtocolPatternFinding.make(pattern(candidate: "journal.x", title: "Alcohol",
            predicate: .journalAnswer(name: "Alcohol"), metric: .hrvRMSSD, difference: -8)))
        XCTAssertEqual(hrv.headline, "Alcohol, HRV 8 ms lower.")
        let sleep = try XCTUnwrap(ProtocolPatternFinding.make(pattern(title: "Training day", predicate: .trainingDay,
            metric: .sleepDuration, difference: 24)))
        XCTAssertEqual(sleep.headline, "Training day, 24 min more sleep.")
        let same = try XCTUnwrap(ProtocolPatternFinding.make(pattern(difference: 0)))
        XCTAssertEqual(same.headline, "Last meal after 21:00, deep sleep about the same.")
        let long = try XCTUnwrap(ProtocolPatternFinding.make(pattern(candidate: "journal.y",
            title: "Took a long walk with the dog after dinner", predicate: .journalAnswer(name: "Walk"), difference: 12)))
        XCTAssertEqual(long.headline, "Took a long walk with\u{2026}, 12 min more deep sleep.")
        XCTAssertLessThanOrEqual(long.headline.count, ProtocolPatternFinding.headlineLimit)
        let twelveHour = try XCTUnwrap(ProtocolPatternFinding.make(pattern(), locale: Locale(identifier: "en_US")))
        XCTAssertFalse(twelveHour.headline.contains("\u{2026}"), "A clock time in a 12-hour locale still fits: \(twelveHour.headline)")
        XCTAssertFalse(long.headline.contains("caused"))
    }

    /// A pattern stored before Loopr kept the spread decodes with none, and the line says only "Not proof of cause."
    func testAnOldStoredPatternWithoutASpreadStillReads() throws {
        let old = """
        {"candidateID":"food.lateMeal","habitID":{"rawValue":"\(UUID().uuidString)"},"title":"Last meal after 21:00",
         "predicate":{"kind":"food","text":"when you eat after 21:00"},"metric":"deepSleepMinutes","strength":"clear",
         "effect":{"adjustedDifference":-14,"practicalThreshold":6,"unit":"minutes"},"nights":{"with":10,"without":12}}
        """
        let decoded = try JSONDecoder().decode(FoundPattern.self, from: Data(old.utf8))
        let finding = try XCTUnwrap(ProtocolPatternFinding.make(decoded, locale: Fixture.locale))
        XCTAssertEqual(finding.sentence,
                       "On the 10 nights you ate after 21:00, you had 14 minutes less deep sleep than on the other 12.")
        XCTAssertEqual(finding.detail, "10 nights against 12. Not proof of cause.")
    }

    func testAnEarlyPatternNeverReachesTheLine() {
        XCTAssertNil(ProtocolPatternFinding.make(pattern(strength: .early)))
    }

    func testOtherMeasuresAndHabitsReadAsSentencesToo() throws {
        let alcohol = try XCTUnwrap(ProtocolPatternFinding.make(pattern(candidate: "journal.x", title: "Alcohol",
            predicate: .journalAnswer(name: "Alcohol"), metric: .hrvRMSSD, difference: -8, spread: 11, with: 9, without: 14)))
        XCTAssertEqual(alcohol.sentence, "On the 9 nights after you logged alcohol, your HRV was 8 ms lower than on the other 14.")
        XCTAssertEqual(alcohol.naming(rules: Fixture.rules).rule, "No alcohol", "The rule's question starts with the same word")
        let protein = try XCTUnwrap(ProtocolPatternFinding.make(pattern(candidate: "food.proteinTarget", title: "Protein target met",
            predicate: .food(label: "a day you met your protein target"), metric: .recoveryScore, difference: 4, spread: nil,
            with: 8, without: 11)))
        XCTAssertEqual(protein.sentence,
                       "On the 8 nights after a day you met your protein target, your recovery was 4 points higher than on the other 11.")
        let legDay = try XCTUnwrap(ProtocolPatternFinding.make(pattern(candidate: "legDay", title: "Leg day", predicate: .legDay,
            metric: .restingHeartRate, difference: 1, spread: 2, with: 4, without: 7)))
        XCTAssertEqual(legDay.sentence, "On the 4 nights after a leg day, your resting heart rate was 1 bpm higher than on the other 7.")
        XCTAssertNil(legDay.naming(rules: Fixture.rules).rule, "Training is not the same habit as a leg day")
        XCTAssertFalse(alcohol.sentence.contains("caused"))
    }

    func testARuleMadeFromTheSameJournalHabitIsNamed() throws {
        let habit = UUID()
        let rule = ProtocolRule(key: RoutineHabitMigration.ruleKey(forHabit: habit), title: "Walk after dinner")
        let finding = try XCTUnwrap(ProtocolPatternFinding.make(pattern(candidate: "journal.\(habit.uuidString)", habit: habit,
            title: "Evening walk", predicate: .journalAnswer(name: "Evening walk"))))
        XCTAssertEqual(finding.naming(rules: Fixture.rules + [rule]).rule, "Walk after dinner")
    }

    /// The line follows the stored pattern: new nights give a new sentence on the next load.
    func testTheLineChangesWhenTheStoredPatternDoes() throws {
        let before = try XCTUnwrap(ProtocolPatternFinding.make(pattern(with: 9, without: 20)))
        let after = try XCTUnwrap(ProtocolPatternFinding.make(pattern(difference: -17, with: 10, without: 20)))
        XCTAssertNotEqual(before, after)
        XCTAssertEqual(after.sentence,
                       "On the 10 nights you ate after 21:00, you had 17 minutes less deep sleep than on the other 20.")
    }

    // MARK: Swipe hint (R3-HAB-01, R3-SEN-08)

    func testTheSwipeHintIsOnlyForSomeoneWhoHasNeverAnswered() {
        let fresh = [Fixture.input(14, .today, [:])]
        XCTAssertTrue(ProtocolDeckQueue.showsSwipeHint(answersOnPhone: 0, history: fresh))
        XCTAssertFalse(ProtocolDeckQueue.showsSwipeHint(answersOnPhone: 3, history: fresh), "Three answers on this phone")
        XCTAssertFalse(ProtocolDeckQueue.showsSwipeHint(answersOnPhone: 0, history: [Fixture.tuesday]),
                       "Morning light was ticked by the person, so they have answered before")
        let byFood = Fixture.input(14, .today, ["caffeine": .kept])
        XCTAssertTrue(ProtocolDeckQueue.showsSwipeHint(answersOnPhone: 0, history: [byFood]), "A source's answer is not theirs")
    }

    // MARK: Evening count (R3-NEW-04)

    func testTheEveningRowCountsOnlyAnswersMadeOnTheListsOwnDays() {
        let start = Fixture.calendar.calendar.startOfDay(for: Fixture.now)
        let made = start.addingTimeInterval(15 * 3600)
        let newList = data(dayNumber: 1, version: 1, createdAt: made)
        let since = ProtocolEveningCount.since(day: Fixture.day(14), routine: newList, calendar: Fixture.calendar)
        XCTAssertEqual(since, made, "On a new list's first day, from the moment it was made")
        let answers = [start.addingTimeInterval(9 * 3600), start.addingTimeInterval(-3 * 3600), made.addingTimeInterval(600)]
        XCTAssertEqual(ProtocolEveningCount.count(answers, since: since), 1, "Only the answer after the list was made")
        XCTAssertEqual(ProtocolEveningRow.detail(answered: 0), "Mood, a few questions and a note. Optional.")

        let older = data(dayNumber: 21, version: 3, createdAt: made)
        let day21 = ProtocolEveningCount.since(day: Fixture.day(14), routine: older, calendar: Fixture.calendar)
        XCTAssertEqual(day21, start)
        XCTAssertEqual(ProtocolEveningCount.count(answers, since: day21), 2, "Yesterday's answer is not today's")
        XCTAssertEqual(ProtocolEveningCount.since(day: Fixture.day(13), routine: newList, calendar: Fixture.calendar), .distantFuture,
                       "The day before the list began counts nothing")
    }

    private func data(dayNumber: Int, version: Int, createdAt: Date) -> ProtocolRoutineData {
        ProtocolRoutineData(protocolName: "My protocol", version: version, versionCreatedAt: createdAt, dayNumber: dayNumber,
                            rules: Fixture.rules, week: [Fixture.tuesday], lastWeek: [], today: Fixture.day(14),
                            nowMinute: 22 * 60)
    }

    // MARK: Deck slot (R3-NEW-08, R3-DES-11)

    func testTheCardLeavesTheDeckAsSoonAsItIsAnswered() async {
        let source = RecordingSource()
        let model = ProtocolTabModel(source: source, habits: HabitViewModel(store: InMemoryHabitStore()),
                                     timeZone: Fixture.zone, locale: Fixture.locale, now: { Fixture.now })
        await model.load()
        let first = model.deck[0]
        let count = model.deck.count
        model.willAnswer(first)
        XCTAssertEqual(model.deck.count, count - 1, "The slot closes before the save is done")
        XCTAssertFalse(model.deck.contains { $0.id == first.id })
        await model.answer(first, choice: .yes)
        XCTAssertNil(model.answering)
        XCTAssertFalse(model.deck.contains { $0.id == first.id })
    }

    func testAFailedSaveBringsTheCardBack() async {
        let model = ProtocolTabModel(source: RecordingSource(failsWrites: true), habits: HabitViewModel(store: InMemoryHabitStore()),
                                     timeZone: Fixture.zone, locale: Fixture.locale, now: { Fixture.now })
        await model.load()
        let first = model.deck[0]
        model.willAnswer(first)
        await model.answer(first, choice: .no)
        XCTAssertEqual(model.deck.first?.id, first.id)
        XCTAssertNotNil(model.errorMessage)
    }
}
