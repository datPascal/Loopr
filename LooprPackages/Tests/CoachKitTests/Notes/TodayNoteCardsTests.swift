import DesignSystem
import DomainKit
import Foundation
import RoutineKit
import Testing
import TodayKit
@testable import CoachKit

private struct FixedRewordingModel: CoachRewordingModel {
    let reply: String
    var isAvailable: Bool { true }
    func reword(_ text: String, instructions: String) async throws -> String { reply }
}

/// LV-04 step 3: the rule engine's notes as Today's cards.
@Suite("LV-04.3 Today note cards")
struct TodayNoteCardsTests {
    private let provenance = TodayNoteProvenance(outcome: .band(device: "WHOOP 4.0"), factor: .food(.logged), kept: .food(.logged))

    private func morningCard() throws -> (card: TodayNoteCard, note: CoachNote) {
        let result = TodayNoteCards.morning(NoteFixtures.morning(), writer: NoteFixtures.writer(), provenance: provenance)
        let card = try #require(result.state.card)
        return (card, try #require(result.note))
    }

    @Test("The morning note maps to a card with the same text, its numbers emphasised and the stated values highlighted")
    func morningNoteToCard() throws {
        let (card, note) = try morningCard()
        #expect(card.kind == .morning)
        #expect(card.kind.header == "Loopr · morning note")
        #expect(card.text == note.text)
        let highlighted = card.runs.filter(\.isHighlighted).map(\.text)
        #expect(highlighted == ["49 bpm", "4 h 04 m"])
        #expect(card.runs.filter(\.isNumber).map(\.text).contains("21 nights"))
        // Every number the rules state is a number run. The only digits left plain are inside a name the app supplied,
        // which the engine marks as a literal: the "4" of the group label "4 h or more". Emphasising it alone would
        // read "**4** h or more", half a label in bold, so the card draws the label as words, as the rule text does.
        #expect(card.runs.count == note.runs.count)
        let plainDigits = zip(card.runs, note.runs).filter { !$0.0.isNumber && !NoteDigits.tokens(in: $0.0.text).isEmpty }
        #expect(plainDigits.allSatisfy { $0.1.number?.unit == .literal && $0.1.isProtected })
        #expect(plainDigits.map { $0.0.text } == ["4"])
        #expect(zip(card.runs, note.runs).allSatisfy { $0.0.isNumber == ($0.1.number != nil && $0.1.number?.unit != .literal) })
        #expect(card.chips.map(\.action) == [.explainOutcome, .showNights])
        #expect(card.chips.map(\.label) == ["Why 49?", "All 30 nights"])
        #expect(card.chips.map(\.action.identifier) == ["today-note-why", "today-note-nights"])
        #expect(!card.isReworded)
        #expect(card.coverage.contains("Last night"))
    }

    @Test("Each highlighted number carries its own source and the worked-out numbers share one")
    func sources() throws {
        let (card, _) = try morningCard()
        #expect(card.sources == [
            TodayNoteSource(number: "49 bpm", provenance: .band(device: "WHOOP 4.0")),
            TodayNoteSource(number: "4 h 04 m", provenance: .food(.logged)),
            TodayNoteSource(number: TodayNoteCards.workedOutQualifier, provenance: .onThisPhone)
        ])
    }

    @Test("The receipt holds both comparison groups with their nights, the group like last night first")
    func receiptGroups() throws {
        let (card, _) = try morningCard()
        let receipt = try #require(card.receipt)
        #expect(receipt.outcome == "Sleep heart rate")
        #expect(receipt.unit == "bpm")
        #expect(receipt.groups.map(\.label) == ["21 nights, 4 h or more", "9 nights, less"])
        #expect(receipt.groups.map(\.nightCount) == [21, 9])
        #expect(receipt.groups.map(\.values.count) == [21, 9])
        #expect(receipt.groups.map(\.isLikeLastNight) == [true, false])
        #expect(receipt.groups.map(\.tint) == [.brand, .heart])
        #expect(abs(receipt.groups[0].mean - 50) < 0.001 && abs(receipt.groups[1].mean - 55) < 0.001)
        #expect(receipt.lastNightValue == 49)
        #expect(receipt.spokenSummary == "Receipt chart for sleep heart rate. 21 nights, 4 h or more, averaged 50 bpm. "
            + "9 nights, less, averaged 55 bpm. Last night 49 bpm.")
    }

    @Test("A note without a factor that reaches both groups has no receipt and no nights chip")
    func noReceiptWithoutComparison() throws {
        let input = NoteFixtures.morning(factors: [])
        let card = try #require(TodayNoteCards.morning(input, writer: NoteFixtures.writer(), provenance: provenance).state.card)
        #expect(card.receipt == nil)
        #expect(card.chips.map(\.action) == [.explainOutcome])
    }

    @Test("Too few nights for the usual is the learning state with the nights still needed, and no sentence")
    func learningState() {
        let few = TodayNoteCards.morning(NoteFixtures.morning(usual: NoteUsual(median: 53, nights: 3, windowDays: 30)),
                                         writer: NoteFixtures.writer())
        #expect(few.state == .learning(have: 3, need: 7))
        #expect(few.note == nil)
        let none = TodayNoteCards.morning(NoteFixtures.morning(usual: nil, outcome: nil), writer: NoteFixtures.writer())
        #expect(none.state == .learning(have: 0, need: 7))
        #expect(TodayNoteState.learningText(have: 3, need: 7) == "The morning note starts after 7 nights of sleep heart rate.")
        #expect(!TodayNoteState.learningText(have: 6, need: 7).contains("to go"))
    }

    @Test("Enough nights but no reading last night is the absent state")
    func absentState() {
        let result = TodayNoteCards.morning(NoteFixtures.morning(outcome: nil), writer: NoteFixtures.writer())
        #expect(result.state == .absent)
        #expect(result.note == nil)
    }

    @Test("A rewording whose numbers match the rule note replaces its text")
    func rewordingWithMatchingNumbers() async throws {
        let (_, note) = try morningCard()
        let faithful = "Last night your sleep heart rate was 49 bpm, 4 bpm below your usual over 28 nights. "
            + "You stopped eating 4 h 04 m before bed, and on the 21 nights with 4 h or more it averaged 5 bpm lower than on the 9 nights with less."
        let card = await TodayNoteCards.reworded(note, rewriter: CoachRewriter(model: FixedRewordingModel(reply: faithful)),
                                                 provenance: provenance)
        #expect(card.isReworded)
        #expect(card.text == faithful)
        #expect(card.receipt != nil)
        #expect(card.runs.filter(\.isHighlighted).map(\.text) == ["49 bpm", "4 h 04 m"])
    }

    @Test("A rewording with a number the rule note does not state is dropped and the rule text shows")
    func rewordingWithANewNumberIsDropped() async throws {
        let (rules, note) = try morningCard()
        let invented = "Last night your sleep heart rate was 48 bpm, 4 bpm below your usual over 28 nights. "
            + "You stopped eating 4 h 04 m before bed, and on the 21 nights with 4 h or more it averaged 5 bpm lower than on the 9 nights with less."
        let card = await TodayNoteCards.reworded(note, rewriter: CoachRewriter(model: FixedRewordingModel(reply: invented)),
                                                 provenance: provenance)
        #expect(!card.isReworded)
        #expect(card == rules)
        let unavailable = await TodayNoteCards.reworded(note, rewriter: CoachRewriter(model: UnavailableCoachRewordingModel()),
                                                        provenance: provenance)
        #expect(unavailable == rules)
    }

    @Test("The evening note maps with Start wind-down and Ask, and the kept time carries the rule's source")
    func eveningNoteToCard() throws {
        let kitchen = ProtocolRule(key: "kitchen", title: "Kitchen closes", group: .food,
                                   target: RuleTarget(kind: .atMost, metric: RoutineMetric.lastMealTime.rawValue, value: 1_110),
                                   timeOfDayMinutes: 1_110, source: .food, isEvening: true)
        let screens = ProtocolRule(key: "screens", title: "Screens off", timeOfDayMinutes: 21 * 60 + 45, isEvening: true)
        let input = EveningNoteInput(rules: [
            NoteRuleDay(rule: kitchen, state: .kept, keptAtMinuteOfDay: 1_100, keptLabel: "Kitchen closed", keptDaysThisWeek: 7, daysThisWeek: 7),
            NoteRuleDay(rule: screens, state: .pending)
        ])
        let evening = try #require(TodayNoteCards.evening(input, writer: NoteFixtures.writer(NoteFixtures.enGB), provenance: provenance))
        #expect(evening.card.kind == .evening)
        #expect(evening.card.text == "Kitchen closed at 18:20. That is 7 of 7 days this week. Screens off at 21:45 is the last rule left.")
        #expect(evening.card.chips.map(\.action) == [.startWindDown, .ask])
        #expect(evening.card.removingChip(.startWindDown).chips.map(\.action) == [.ask])
        #expect(evening.card.sources.first == TodayNoteSource(number: "18:20", provenance: .food(.logged)))
        #expect(evening.card.receipt == nil)
    }
}
