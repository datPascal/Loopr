import DomainKit
import Foundation
import Testing
@testable import CoachKit

/// A model that returns fixed text, fails or never answers, and records what it was asked.
private final class FakeRewordingModel: CoachRewordingModel, @unchecked Sendable {
    enum Behaviour { case answer(String), fail, hang }

    let behaviour: Behaviour
    let isAvailable: Bool
    private let lock = NSLock()
    private var asked: [(text: String, instructions: String)] = []

    init(_ behaviour: Behaviour, available: Bool = true) { self.behaviour = behaviour; isAvailable = available }

    var calls: [(text: String, instructions: String)] { lock.withLock { asked } }

    func reword(_ text: String, instructions: String) async throws -> String {
        lock.withLock { asked.append((text, instructions)) }
        switch behaviour {
        case .answer(let reply): return reply
        case .fail: throw CoachRewordingModelError.unavailable
        case .hang:
            try await Task.sleep(for: .seconds(60))
            return text
        }
    }
}

@Suite("LV-09.4 on-device rewording")
struct CoachRewriterTests {
    /// The contract morning note. The tests below start from its text.
    private let note: CoachNote = NoteFixtures.writer().morning(NoteFixtures.morning())!

    /// The rule text, reworded the way a faithful model would: the same numbers, units, names and directions.
    private let faithful = "Last night your sleep heart rate was 49 bpm, 4 bpm below your usual over 28 nights. "
        + "You stopped eating 4 h 04 m before bed, and on the 21 nights with 4 h or more it averaged 5 bpm lower than on the 9 nights with less."

    private func outcome(_ reply: String, note: CoachNote? = nil) async -> CoachRewordOutcome {
        await CoachRewriter(model: FakeRewordingModel(.answer(reply))).reword(note ?? self.note)
    }

    private func expectRules(_ outcome: CoachRewordOutcome, _ rejection: CoachRewordRejection, note: CoachNote? = nil,
                             sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(outcome == .rules(note ?? self.note, rejected: rejection), sourceLocation: sourceLocation)
        #expect(outcome.note == (note ?? self.note), sourceLocation: sourceLocation)
        #expect(!outcome.isReworded, sourceLocation: sourceLocation)
    }

    // MARK: Accepting

    @Test("The fixture note is the contract note, with its names marked")
    func fixture() {
        #expect(note.text.hasPrefix("Sleep heart rate was 49 bpm last night, 4 bpm below your usual over the previous 28 nights."))
        #expect(note.protectedPhrases == ["h or more", "less"])
    }

    @Test("A faithful rewording is accepted, and its numbers are runs again with the same highlights")
    func acceptsFaithful() async throws {
        let outcome = await self.outcome(faithful)
        guard case .reworded(let reworded) = outcome else { Issue.record("Rejected: \(outcome)"); return }
        #expect(reworded.text == faithful)
        #expect(reworded.kind == .morning)
        #expect(reworded.runs.filter(\.isHighlighted).map(\.text) == ["49 bpm", "4 h 04 m"])
        #expect(reworded.displayedNumbers == note.displayedNumbers)
        #expect(reworded.numberValues == note.numberValues)
        #expect(reworded.numerals == note.numerals)
        #expect(reworded.receipt == note.receipt && reworded.chips == note.chips)
        #expect(reworded.daysCovered == note.daysCovered && reworded.comparisonGroup == note.comparisonGroup)
        NoteFixtures.expectNumbersExact(reworded)
    }

    @Test("The model is told to keep every number and name, say differed, and give no advice")
    func instructionsReachTheModel() async {
        let model = FakeRewordingModel(.answer(faithful))
        _ = await CoachRewriter(model: model).reword(note)
        let call = model.calls.first
        #expect(model.calls.count == 1)
        #expect(call?.text == note.text)
        let instructions = call?.instructions ?? ""
        for phrase in ["Keep every number, name, day and comparison", "differed", "Do not give advice", "sentence case", "no exclamation marks"] {
            #expect(instructions.contains(phrase), "\(phrase)")
        }
        #expect(CoachRewriter.instructions == instructions)
    }

    @Test("A text with the same words as the rule text is accepted and still carries every number")
    func acceptsTheRuleTextItself() async {
        let outcome = await self.outcome(note.text)
        #expect(outcome.isReworded)
        #expect(outcome.note.text == note.text)
        #expect(outcome.note.numbers == note.numbers)
    }

    @Test("A rewording that swaps a narrow space for a plain one is still accepted, and the clock keeps its own form")
    func spacesAreForgiven() async throws {
        let evening = try #require(NoteFixtures.writer(NoteFixtures.enUS).evening(EveningNoteInput(rules: [NoteFixtures.kitchen, NoteFixtures.screens])))
        let plain = "Kitchen closed at \(NoteFixtures.clock(1_100, NoteFixtures.enUS).replacingOccurrences(of: "\u{202F}", with: " ")), and that is 7 of 7 days this week. "
            + "Screens off at \(NoteFixtures.clock(1_305, NoteFixtures.enUS).replacingOccurrences(of: "\u{202F}", with: " ")) is the last rule left."
        let outcome = await self.outcome(plain, note: evening)
        guard case .reworded(let reworded) = outcome else { Issue.record("Rejected: \(outcome)"); return }
        #expect(reworded.runs.compactMap(\.number).map(\.displayed).contains(NoteFixtures.clock(1_100, NoteFixtures.enUS)))
        #expect(reworded.numberValues == evening.numberValues)
        #expect(reworded.runs.filter(\.isHighlighted).map(\.text) == [NoteFixtures.clock(1_100, NoteFixtures.enUS)])
        NoteFixtures.expectNumbersExact(reworded)
    }

    @Test("A weekly page can be reworded, and a pattern line never is")
    func kinds() async throws {
        let page = try #require(WeeklyFixtures.story()?.pages.first)
        let again = await self.outcome(page.note.text, note: page.note)
        #expect(again.isReworded && again.note.kind == .weeklyPage)

        let line = try #require(NoteFixtures.writer().patternLine(NotePatternSummary(
            id: "a", factor: "Dinner 4 h before bed", outcome: .sleepHeartRate, difference: -5, nights: 30, strength: .strong)))
        let model = FakeRewordingModel(.answer(line.text))
        let result = await CoachRewriter(model: model).reword(line)
        expectRules(result, .notRewordable, note: line)
        #expect(model.calls.isEmpty)
        #expect(!CoachRewriter.isRewordable(.patternLine) && CoachRewriter.isRewordable(.morning)
            && CoachRewriter.isRewordable(.evening) && CoachRewriter.isRewordable(.weeklyPage))
    }

    // MARK: Numbers

    @Test("A new number is rejected")
    func newNumber() async {
        expectRules(await outcome(faithful.replacingOccurrences(of: "49 bpm", with: "49 bpm, 12 beats under your best,")), .newNumber("12"))
    }

    @Test("A changed number is rejected")
    func changedNumber() async {
        expectRules(await outcome(faithful.replacingOccurrences(of: "5 bpm lower", with: "6 bpm lower")), .newNumber("6"))
        expectRules(await outcome(faithful.replacingOccurrences(of: "49 bpm", with: "50 bpm")), .newNumber("50"))
        expectRules(await outcome(faithful.replacingOccurrences(of: "4 h 04 m", with: "4 h 05 m")), .newNumber("05"))
    }

    @Test("A dropped number is rejected")
    func droppedNumber() async {
        expectRules(await outcome(faithful.replacingOccurrences(of: "the 9 nights with less", with: "the other nights, with less")), .droppedNumber("9"))
        expectRules(await outcome(faithful.replacingOccurrences(of: ", 4 bpm below your usual over 28 nights", with: ", and below your usual over 28 nights")), .droppedNumber("4"))
    }

    @Test("A number said more often than the note says it is rejected")
    func repeatedNumber() async {
        expectRules(await outcome(faithful + " Again, 49 bpm."), .repeatedNumber("49"))
    }

    @Test("A number written out in words is rejected, unless the note's own text uses the word")
    func spelledNumber() async {
        expectRules(await outcome(faithful + " Both are two weeks apart."), .spelledNumber("two"))
        expectRules(await outcome(faithful.replacingOccurrences(of: "averaged", with: "averaged half of")), .spelledNumber("half"))
    }

    @Test("A number written another way is rejected")
    func numberFormat() async {
        expectRules(await outcome(faithful.replacingOccurrences(of: "4 h 04 m", with: "4 h and 04 m")), .numberFormatChanged("4 h 04 m"))
        expectRules(await outcome(faithful.replacingOccurrences(of: "49 bpm", with: "49 beats a minute")), .numberFormatChanged("49 bpm"))
    }

    @Test("The comparison keeps its direction")
    func direction() async {
        expectRules(await outcome(faithful.replacingOccurrences(of: "5 bpm lower", with: "5 bpm higher")), .directionChanged)
        expectRules(await outcome(faithful.replacingOccurrences(of: "below your usual", with: "above your usual")), .directionChanged)
        expectRules(await outcome(faithful.replacingOccurrences(of: "below your usual", with: "in line with your usual")), .directionChanged)
    }

    @Test("A name or group label that is changed is rejected")
    func names() async {
        expectRules(await outcome(faithful.replacingOccurrences(of: "with less", with: "with fewer")), .nameChanged("less"))
        expectRules(await outcome(faithful.replacingOccurrences(of: "4 h or more", with: "4 hours or more")), .nameChanged("h or more"))
    }

    // MARK: Words and marks

    @Test("The forbidden words are rejected")
    func forbiddenWords() async {
        expectRules(await outcome(faithful + " It happened because of dinner."), .forbiddenWord("because"))
        expectRules(await outcome(faithful.replacingOccurrences(of: "it averaged", with: "dinner caused it to average")), .forbiddenWord("caused"))
        expectRules(await outcome(faithful.replacingOccurrences(of: "it averaged", with: "it averaged, due to dinner,")), .forbiddenWord("due to"))
        expectRules(await outcome(faithful.replacingOccurrences(of: "it averaged", with: "it causes an average of")), .forbiddenWord("causes"))
    }

    @Test("An exclamation mark is rejected")
    func exclamation() async {
        expectRules(await outcome(faithful + "!"), .exclamationMark)
        expectRules(await outcome(faithful.replacingOccurrences(of: "Last night your", with: "Great news! Last night your")), .exclamationMark)
    }

    @Test("An em dash, an en dash and a spaced hyphen are rejected")
    func dashes() async {
        expectRules(await outcome(faithful.replacingOccurrences(of: ", 4 bpm", with: " \u{2014} 4 bpm")), .dash)
        expectRules(await outcome(faithful.replacingOccurrences(of: ", 4 bpm", with: " \u{2013} 4 bpm")), .dash)
        expectRules(await outcome(faithful.replacingOccurrences(of: ", 4 bpm", with: " - 4 bpm")), .dash)
    }

    @Test("A text that is much longer or much shorter than the rule text is rejected")
    func length() async {
        let padding = " Sleep is one of the things people notice most when they look back over a few weeks, and a quiet stretch can read as steady."
        expectRules(await outcome(faithful + padding + padding), .tooLong)
        expectRules(await outcome("Sleep heart rate was 49 bpm last night."), .tooShort)
        #expect(note.text.count > 100)
        #expect(CoachRewordLimits.standard.lengthRatio == 0.5...1.5)
    }

    @Test("An empty answer is rejected")
    func empty() async {
        expectRules(await outcome("   \n "), .empty)
        expectRules(await outcome(""), .empty)
    }

    // MARK: The model

    @Test("A failing model falls back to the rule text")
    func failure() async {
        let result = await CoachRewriter(model: FakeRewordingModel(.fail)).reword(note)
        expectRules(result, .modelFailed)
    }

    @Test("A model that runs out of time falls back to the rule text")
    func timeout() async {
        let model = FakeRewordingModel(.hang)
        let rewriter = CoachRewriter(model: model, limits: CoachRewordLimits(timeout: .milliseconds(50)))
        let result = await rewriter.reword(note)
        expectRules(result, .timedOut)
        #expect(model.calls.count == 1)
    }

    @Test("An unavailable model is never asked")
    func unavailable() async {
        let model = FakeRewordingModel(.answer(faithful), available: false)
        let rewriter = CoachRewriter(model: model)
        #expect(!rewriter.isAvailable)
        expectRules(await rewriter.reword(note), .modelUnavailable)
        #expect(model.calls.isEmpty)
        #expect(CoachRewriter(model: .unavailable).isAvailable == false)
        expectRules(await CoachRewriter(model: .unavailable).reword(note), .modelUnavailable)
    }

    @Test("The unavailable model throws, and the system choice agrees with its own availability")
    func systemModel() async {
        await #expect(throws: CoachRewordingModelError.unavailable) {
            _ = try await UnavailableCoachRewordingModel().reword("text", instructions: "")
        }
        let system = CoachRewriter.system()
        #expect(system.isAvailable == systemCoachRewordingModel().isAvailable)
        // On a device without the model the rule text shows. With it, whatever shows has passed the checks.
        if !system.isAvailable {
            expectRules(await system.reword(note), .modelUnavailable)
        }
    }

    @Test("A model that answers with the rule text of another note is rejected")
    func wrongNote() async throws {
        let other = try #require(NoteFixtures.writer().morning(NoteFixtures.morning(outcome: NightOutcome(kind: .hrv, value: 61))))
        let result = await outcome(other.text)
        #expect(!result.isReworded)
        #expect(result.note == note)
    }

    // MARK: Mapping back to runs

    @Test("A digit left outside every number run cannot be mapped, so the text is not used")
    func runMappingFailure() {
        #expect(CoachRewordValidator.runs(for: "Sleep heart rate was 49 bpm and 12", note: note) == nil)
        let mapped = CoachRewordValidator.runs(for: "It was 49 bpm, then 4 bpm under 28 nights.", note: note)
        #expect(mapped?.compactMap(\.number).map(\.displayed) == ["49 bpm", "4 bpm", "28 nights"])
        #expect(mapped?.filter(\.isHighlighted).map(\.text) == ["49 bpm"])
        #expect(mapped?.map(\.text).joined() == "It was 49 bpm, then 4 bpm under 28 nights.")
    }

    @Test("The longest number wins, so a short number inside a long one is not split off")
    func longestNumberFirst() {
        let mapped = CoachRewordValidator.runs(for: "You ate 4 h 04 m before bed and 4 h or more", note: note)
        #expect(mapped?.compactMap(\.number).map(\.displayed) == ["4 h 04 m", "4"])
        #expect(mapped?.filter(\.isHighlighted).map(\.text) == ["4 h 04 m"])
    }

    @Test("The same note and the same answer always give the same outcome")
    func deterministic() async {
        let first = await outcome(faithful)
        let second = await outcome(faithful)
        #expect(first == second)
        let rejected = await outcome(faithful + "!")
        #expect(rejected == (await outcome(faithful + "!")))
    }
}
