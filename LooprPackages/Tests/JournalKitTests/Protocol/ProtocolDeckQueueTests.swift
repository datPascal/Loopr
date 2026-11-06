import DomainKit
import Foundation
import JournalKit
import RoutineKit
import XCTest

/// LV-07.1: which rules tonight's deck asks, in which order, and how an answer and its undo are saved.
@MainActor final class ProtocolDeckQueueTests: XCTestCase {
    private typealias Fixture = ProtocolTestData

    // MARK: Queue

    func testTheDeckAsksOpenManualAndEveningRulesByTime() {
        let questions = ProtocolDeckQueue.questions(today: Fixture.tuesday, locale: Fixture.locale)
        // Magnesium, Screens off and In bed are open evening rules; Stretch is an open manual rule with no time. Food's
        // pending alcohol rule is not the person's to answer, and kept rules are never asked.
        XCTAssertEqual(questions.map(\.key), ["magnesium", "screens", "bed", "stretch"])
        XCTAssertEqual(questions[1].eyebrow, "Checked by you \u{00B7} 21:45")
        XCTAssertEqual(questions[1].question, "Screens off by 21:45?")
        XCTAssertEqual(questions[1].accessibilityIdentifier, "protocol-deck-card-screens")
        XCTAssertEqual(questions[3].eyebrow, "Checked by you")
        XCTAssertEqual(questions[2].eyebrow, "Checked by the band \u{00B7} 22:30", "The card says who checks the rule")
        XCTAssertEqual(questions[2].kind, .rule("bed", source: .band), "An evening rule a source checks is answered over it")
    }

    func testDecidedAndUnknownRulesAreNotAsked() {
        let today = Fixture.input(14, .today, ["magnesium": .kept, "screens": .missed, "bed": .unknown, "stretch": .pending])
        let questions = ProtocolDeckQueue.questions(today: today)
        XCTAssertEqual(questions.map(\.key), ["light", "stretch"], "Only rules still open are asked")
    }

    /// ICP R1-UPG-13: "No alcohol?" with No and Yes reads both ways. A rule written as something to avoid is asked so
    /// that Yes is kept, and its time follows the locale like every other title.
    func testARuleToAvoidIsAskedSoThatYesMeansKept() {
        let alcohol = ProtocolRule(key: "habit.alcohol", title: "No alcohol", isEvening: true)
        let caffeine = ProtocolRule(key: "late", title: "No caffeine after 14:00", isEvening: true)
        let today = Fixture.input(14, .today, [:], rules: [alcohol, caffeine, Fixture.screens])
        let british = ProtocolDeckQueue.questions(today: today, locale: Fixture.locale).map(\.question)
        XCTAssertEqual(british, ["Screens off by 21:45?", "Did you keep to no alcohol?", "Did you keep to no caffeine after 14:00?"])
        let us = Locale(identifier: "en_US")
        let american = ProtocolDeckQueue.questions(today: today, locale: us).map(\.question)
        XCTAssertEqual(american[0], "\(Fixture.screens.displayTitle(locale: us))?")
        XCTAssertTrue(american[2].hasPrefix("Did you keep to no caffeine after 2:00"), american[2])
        XCTAssertFalse(american.joined().contains("14:00") || american.joined().contains("21:45"))
    }

    /// ICP R1-UPG-1: the deck holds rules only. A Journal question about the day has its own place under How you feel,
    /// and one that became a rule is asked only as that rule.
    func testTheDeckHoldsRulesOnly() {
        let questions = ProtocolDeckQueue.questions(today: Fixture.input(14, .today, [:], rules: [Fixture.screens]))
        XCTAssertEqual(questions.map(\.key), ["screens"])
    }

    /// ICP R2-DES-05, R3-SEN-02: while nothing is due the deck is one quiet line. The later list under it names each
    /// rule and its time, so the line does not say "Next" again.
    func testAnEmptyDeckIsOneQuietLineThatLeavesTheNamesToTheLaterList() {
        let quiet = Fixture.input(14, .today, [:], rules: [Fixture.zone2, Fixture.magnesium, Fixture.screens])
        let later = ProtocolDeckQueue.later(today: quiet, nowMinute: 20 * 60, locale: Fixture.locale)
        XCTAssertEqual(ProtocolDeckQueue.waitingLine(today: quiet, later: later), "Nothing yet.")
        XCTAssertEqual(ProtocolDeckQueue.waitingLine(today: quiet, later: later, answering: true), "Done for now.",
                       "An answer still saving counts, so the line does not flip after the save")
        // Morning light is a rule the person ticks, and it is ticked.
        let ticked = Fixture.input(14, .today, ["light": .kept, "magnesium": .pending, "screens": .pending],
                                   rules: [Fixture.light, Fixture.magnesium, Fixture.screens])
        let after = ProtocolDeckQueue.later(today: ticked, nowMinute: 21 * 60 + 35, locale: Fixture.locale)
        XCTAssertEqual(ProtocolDeckQueue.waitingLine(today: ticked, later: after), "Done for now.",
                       "Once the person answered something today")
        XCTAssertNil(ProtocolDeckQueue.waitingLine(today: Fixture.tuesday, later: nil), "Nothing ahead is the closing card")
    }

    /// ICP R1-OPT-7: the counter is the rules left to answer, the number Today's "Your day" row shows.
    func testProgressCountsTheRulesLeftToAnswer() {
        XCTAssertEqual(ProtocolDeckProgress(remaining: 3).text, "3 left")
        XCTAssertEqual(ProtocolDeckProgress(remaining: 1).accessibilityLabel, "1 rule left to answer")
        XCTAssertEqual(ProtocolDeckProgress(remaining: 0).text, "All answered")
        let count = RoutineDayCount.make(Fixture.tuesday.rules.map { (rule: $0.rule, state: $0.state) })
        XCTAssertEqual(count.toAnswer, ProtocolDeckQueue.questions(today: Fixture.tuesday).count)
        XCTAssertEqual(count.toAnswerText, "4 rules left to answer")
        XCTAssertEqual(count.keptText, "5 of 10 rules kept")
    }

    // MARK: Answers and undo

    func testYesTicksAManualRuleNoOverridesItAndUndoClearsIt() async {
        let source = RecordingSource()
        let model = ProtocolTabModel(source: source, habits: HabitViewModel(store: InMemoryHabitStore()),
                                     timeZone: Fixture.zone, locale: Fixture.locale, now: { Fixture.now })
        await model.load()
        let magnesium = model.deck[0]
        XCTAssertEqual(magnesium.key, "magnesium")
        XCTAssertEqual(model.deckProgress.text, "4 left")

        let kept = await model.answer(magnesium, yes: true)
        XCTAssertTrue(kept, "A kept rule plays the kept-rule success")
        var calls = await source.calls
        XCTAssertEqual(calls, ["tick magnesium 2023-11-14"])
        XCTAssertEqual(model.lastAnswer?.question.key, "magnesium")
        XCTAssertEqual(model.deck.map(\.key), ["screens", "bed", "stretch"])
        XCTAssertEqual(model.deckProgress.text, "3 left")

        await model.undo()
        calls = await source.calls
        XCTAssertEqual(calls.last, "clear magnesium 2023-11-14")
        XCTAssertNil(model.lastAnswer)
        XCTAssertEqual(model.deck.first?.key, "magnesium", "Undo puts the card back on top")
        XCTAssertEqual(model.deckProgress.text, "4 left")

        let screens = model.deck[1]
        let keptNo = await model.answer(screens, yes: false)
        XCTAssertFalse(keptNo)
        let bed = model.deck.first { $0.key == "bed" }!
        _ = await model.answer(bed, yes: true)
        calls = await source.calls
        XCTAssertEqual(Array(calls.suffix(2)), ["override screens missed 2023-11-14", "override bed kept 2023-11-14"])
    }

    /// ICP R1-UPG-1: after a load the Journal knows which of its habits are rules, so its check-in leaves them out.
    func testALoadTellsTheJournalWhichHabitsAreRules() async {
        let stretchHabit = HabitID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000006")!)
        let napped = HabitDefinition(id: HabitID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!),
                                     source: .custom, name: "Napped", question: "Did you nap?", sortOrder: 0, createdAt: Fixture.now)
        let stretched = HabitDefinition(id: stretchHabit, source: .custom, name: "Stretched", question: "Did you stretch?",
                                        sortOrder: 1, createdAt: Fixture.now)
        let habits = HabitViewModel(store: InMemoryHabitStore(definitions: [napped, stretched]))
        await habits.load()
        XCTAssertEqual(habits.checkInDefinitions.count, 2, "Before the protocol loads, the Journal asks both")
        let model = ProtocolTabModel(source: RecordingSource(habitRule: stretchHabit.rawValue), habits: habits,
                                     timeZone: Fixture.zone, locale: Fixture.locale, now: { Fixture.now })
        await model.load()
        XCTAssertEqual(habits.ruleHabitIDs, [stretchHabit])
        XCTAssertEqual(habits.checkInDefinitions.map(\.id), [napped.id])
        XCTAssertEqual(habits.ruleDefinitions.map(\.id), [stretchHabit])
        XCTAssertEqual(habits.checkInProgress(on: Fixture.day(14)).total, JournalFeeling.allCases.count + 1 + 1,
                       "The rule is not counted as a Journal question")
    }

    /// ICP R1-HAB-01: Skip today saves a skip, takes the card off the deck, leaves the kept share alone, and Undo
    /// brings the card back.
    func testSkipTodayIsSavedLeftOutOfTheShareAndUndone() async throws {
        let source = RecordingSource()
        let model = ProtocolTabModel(source: source, habits: HabitViewModel(store: InMemoryHabitStore()),
                                     timeZone: Fixture.zone, locale: Fixture.locale, now: { Fixture.now })
        await model.load()
        let before = try XCTUnwrap(model.summary)
        let magnesium = model.deck[0]
        let kept = await model.answer(magnesium, choice: .skip)
        XCTAssertFalse(kept, "A skip plays no kept-rule success")
        var calls = await source.calls
        XCTAssertEqual(calls, ["skip magnesium 2023-11-14"])
        XCTAssertFalse(model.deck.contains { $0.key == "magnesium" })
        XCTAssertEqual(model.lastAnswer?.choice, .skip)
        XCTAssertEqual(model.lastAnswer?.summary, "You skipped it for today.")
        let after = try XCTUnwrap(model.summary)
        XCTAssertEqual(after.kept, before.kept)
        XCTAssertEqual(after.decided, before.decided, "A skip is neither kept nor not kept")
        XCTAssertEqual(model.days.first { $0.isToday }?.skipped, 1)

        await model.undo()
        calls = await source.calls
        XCTAssertEqual(calls.last, "clear magnesium 2023-11-14")
        XCTAssertEqual(model.deck.first?.key, "magnesium")
    }

    /// ICP R1-DES-04: the day sheet changes any rule of today or an earlier day. A kept manual rule is a tick, a change
    /// over a source is an override, Skip is a skip, and going back clears it.
    func testTheDaySheetChangesARuleOnAnyDayUpToToday() async throws {
        let source = RecordingSource()
        let model = ProtocolTabModel(source: source, habits: HabitViewModel(store: InMemoryHabitStore()),
                                     timeZone: Fixture.zone, locale: Fixture.locale, now: { Fixture.now })
        await model.load()
        await model.setAnswer("caffeine", day: Fixture.day(14), to: .missed)
        await model.setAnswer("stretch", day: Fixture.day(14), to: .kept)
        await model.setAnswer("alcohol", day: Fixture.day(13), to: .skipped)
        await model.setAnswer("caffeine", day: Fixture.day(14), to: nil)
        await model.setAnswer("light", day: Fixture.day(16), to: .kept)
        let calls = await source.calls
        XCTAssertEqual(calls, ["override caffeine missed 2023-11-14", "tick stretch 2023-11-14", "skip alcohol 2023-11-13",
                               "clear caffeine 2023-11-14"], "A day ahead cannot be changed")
    }

    func testAFailedSaveKeepsTheCardAndSaysSo() async {
        let source = RecordingSource(failsWrites: true)
        let model = ProtocolTabModel(source: source, habits: HabitViewModel(store: InMemoryHabitStore()),
                                     timeZone: Fixture.zone, locale: Fixture.locale, now: { Fixture.now })
        await model.load()
        let card = model.deck[0]
        _ = await model.answer(card, yes: true)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertNil(model.lastAnswer)
        XCTAssertEqual(model.deck.first?.id, card.id)
    }
}

/// A source over Tuesday's rules that records each write and applies it to its own copy of the day.
actor RecordingSource: ProtocolTabSource {
    private(set) var calls: [String] = []
    private var states: [RuleKey: CheckState] = ["light": .kept, "caffeine": .kept, "meal": .kept, "alcohol": .pending,
        "zone2": .kept, "training": .kept, "magnesium": .pending, "screens": .pending, "bed": .pending, "stretch": .pending]
    private var overridden: Set<RuleKey> = []
    private let failsWrites: Bool
    /// A habit whose rule an earlier version held.
    private let habitRule: UUID?
    /// The clock the deck reads. 23:00 by default, so every evening rule's time has come.
    private let nowMinute: Int

    init(failsWrites: Bool = false, habitRule: UUID? = nil, nowMinute: Int = 23 * 60) {
        self.failsWrites = failsWrites; self.habitRule = habitRule; self.nowMinute = nowMinute
    }

    func load(now: Date) async -> ProtocolTabContent {
        let today = ProtocolTestData.input(14, .today, states, overridden: overridden)
        let week = [ProtocolTestData.input(13, .past, [:]), today] + (15...19).map { ProtocolTestData.input($0, .future, [:]) }
        return ProtocolTabContent(routine: .ready(ProtocolRoutineData(
            protocolName: "My protocol", version: 7, versionCreatedAt: now, dayNumber: 21, rules: ProtocolTestData.rules,
            week: week, lastWeek: [], today: ProtocolTestData.day(14), nowMinute: nowMinute,
            habitRuleIDs: habitRule.map { Set([$0]) } ?? [])))
    }

    func tick(_ key: RuleKey, day: DayIdentity, now: Date) async throws {
        if failsWrites { throw RoutineError.missingProtocol }
        calls.append("tick \(key.rawValue) \(day.routineDayKey ?? "")")
        states[key] = .kept
    }

    func override(_ key: RuleKey, day: DayIdentity, kept: Bool, now: Date) async throws {
        if failsWrites { throw RoutineError.missingProtocol }
        calls.append("override \(key.rawValue) \(kept ? "kept" : "missed") \(day.routineDayKey ?? "")")
        states[key] = kept ? .kept : .missed
        overridden.insert(key)
    }

    func skip(_ key: RuleKey, day: DayIdentity, now: Date) async throws {
        if failsWrites { throw RoutineError.missingProtocol }
        calls.append("skip \(key.rawValue) \(day.routineDayKey ?? "")")
        states[key] = .skipped
        overridden.insert(key)
    }

    func clear(_ key: RuleKey, day: DayIdentity, now: Date) async throws {
        if failsWrites { throw RoutineError.missingProtocol }
        calls.append("clear \(key.rawValue) \(day.routineDayKey ?? "")")
        states[key] = .pending
        overridden.remove(key)
    }
}
