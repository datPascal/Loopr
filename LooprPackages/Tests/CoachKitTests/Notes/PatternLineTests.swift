import DomainKit
import Foundation
import Testing
@testable import CoachKit

@Suite("LV-09.1 pattern lines")
struct PatternLineTests {
    private let writer = NoteFixtures.writer()

    private func pattern(_ id: String = "dinner", factor: String = "Dinner 4 h before bed", outcome: NoteOutcomeKind = .sleepHeartRate,
                         difference: Double = -5, nights: Int = 30, strength: NotePatternStrength = .strong) -> NotePatternSummary {
        NotePatternSummary(id: id, factor: factor, outcome: outcome, difference: difference, nights: nights, strength: strength)
    }

    @Test("The contract line reads factor, outcome and difference, and nights")
    func contractLine() throws {
        let note = try #require(writer.patternLine(pattern()))
        #expect(note.kind == .patternLine)
        #expect(note.text == "Dinner 4 h before bed \u{00B7} Sleep heart rate 5 bpm lower \u{00B7} 30 nights")
        #expect(note.receipt == nil)
        #expect(note.chips.isEmpty)
        #expect(note.displayedNumbers == ["4", "5 bpm", "30 nights"])
        #expect(note.numberValues == [4, 5, 30])
        #expect(note.daysCovered == "The 30 nights in the comparison.")
        NoteFixtures.expectClean(note)
    }

    @Test("Direction words follow the outcome")
    func directionWords() throws {
        let faster = try #require(writer.patternLine(pattern(factor: "Morning light", outcome: .timeToFallAsleep, difference: -11, nights: 41, strength: .clear)))
        #expect(faster.text == "Morning light \u{00B7} Time to fall asleep 11 min faster \u{00B7} 41 nights")
        let longer = try #require(writer.patternLine(pattern(factor: "No alcohol", outcome: .sleepDuration, difference: 65, nights: 22, strength: .clear)))
        #expect(longer.text == "No alcohol \u{00B7} Sleep 1 h 05 m longer \u{00B7} 22 nights")
        let higher = try #require(writer.patternLine(pattern(factor: "Zone 2 days", outcome: .hrv, difference: 6.4, nights: 18, strength: .strong)))
        #expect(higher.text == "Zone 2 days \u{00B7} HRV 6 ms higher \u{00B7} 18 nights")
        let deep = try #require(writer.patternLine(pattern(factor: "Late dinner", outcome: .deepSleep, difference: -14, nights: 12, strength: .clear)))
        #expect(deep.text == "Late dinner \u{00B7} Deep sleep 14 min lower \u{00B7} 12 nights")
        for note in [faster, longer, higher, deep] { NoteFixtures.expectClean(note) }
    }

    @Test("Early patterns have no line, alone or in a list")
    func skipsEarly() {
        #expect(writer.patternLine(pattern(strength: .early)) == nil)
        let lines = writer.patternLines([
            pattern("a", factor: "Early one", strength: .early),
            pattern("b", factor: "Clear one", strength: .clear),
            pattern("c", factor: "Strong one", strength: .strong),
            pattern("d", factor: "Another early one", strength: .early),
        ])
        #expect(lines.count == 2)
        #expect(lines.map { $0.text.components(separatedBy: " \u{00B7} ")[0] } == ["Strong one", "Clear one"])
        #expect(!lines.contains { $0.text.contains("Early") })
    }

    @Test("Lines come strongest first, then most nights, and a limit keeps the top ones")
    func ordersAndLimits() {
        let patterns = [
            pattern("c", factor: "C", nights: 20, strength: .clear),
            pattern("a", factor: "A", nights: 12, strength: .strong),
            pattern("b", factor: "B", nights: 30, strength: .clear),
            pattern("d", factor: "D", nights: 20, strength: .clear),
        ]
        let firstWords = { (notes: [CoachNote]) in notes.map { $0.text.components(separatedBy: " ")[0] } }
        #expect(firstWords(writer.patternLines(patterns)) == ["A", "B", "C", "D"])
        #expect(firstWords(writer.patternLines(Array(patterns.reversed()))) == ["A", "B", "C", "D"])
        #expect(firstWords(writer.patternLines(patterns, limit: 2)) == ["A", "B"])
        #expect(writer.patternLines(patterns, limit: 0).isEmpty)
        #expect(writer.patternLines([]).isEmpty)
    }

    @Test("A pattern without a readable difference or nights has no line")
    func absentInputs() {
        #expect(writer.patternLine(pattern(difference: 0.2)) == nil)
        #expect(writer.patternLine(pattern(difference: 0)) == nil)
        #expect(writer.patternLine(pattern(difference: .nan)) == nil)
        #expect(writer.patternLine(pattern(difference: .infinity)) == nil)
        #expect(writer.patternLine(pattern(nights: 0)) == nil)
        #expect(writer.patternLine(pattern(factor: "  ")) == nil)
        #expect(writer.patternLine(pattern(factor: "Late dinner because of work")) == nil)
    }

    @Test("One night reads as one night")
    func singleNight() throws {
        let note = try #require(writer.patternLine(pattern(nights: 1, strength: .clear)))
        #expect(note.text.hasSuffix("\u{00B7} 1 night"))
        NoteFixtures.expectClean(note)
    }

    @Test("A time in a factor name follows the locale clock")
    func followsClock() throws {
        let summary = pattern(factor: "Eating after 21:00", difference: -9, nights: 16)
        let us = try #require(NoteFixtures.writer(NoteFixtures.enUS).patternLine(summary))
        let gb = try #require(NoteFixtures.writer(NoteFixtures.enGB).patternLine(summary))
        let de = try #require(NoteFixtures.writer(NoteFixtures.deDE).patternLine(summary))
        #expect(us.text.hasPrefix("Eating after 9:00"))
        #expect(us.text.contains("PM"))
        #expect(gb.text.hasPrefix("Eating after 21:00 \u{00B7}"))
        #expect(de.text.hasPrefix("Eating after 21:00 \u{00B7}"))
        for note in [us, gb, de] { NoteFixtures.expectClean(note) }
    }

    @Test("A time inside a group label follows the locale clock in the morning note")
    func morningLabelFollowsClock() throws {
        let group = NoteFactorGroup(id: "long", label: "dinner before 19:00")
        let factor = NightFactor(id: "dinner", name: "Dinner", statement: "You finished dinner early.", lastNightValue: .flag,
                                 lastNightGroupID: "long", groups: [group, NoteFixtures.shortGroup], history: NoteFixtures.dinnerHistory())
        let input = NoteFixtures.morning(factors: [factor])
        let us = try #require(NoteFixtures.writer(NoteFixtures.enUS).morning(input))
        let gb = try #require(NoteFixtures.writer(NoteFixtures.enGB).morning(input))
        #expect(us.text.contains("with dinner before 7:00"))
        #expect(us.text.contains("PM"))
        #expect(gb.text.contains("with dinner before 19:00,"))
        for note in [us, gb] { NoteFixtures.expectNumbersExact(note) }
    }

    @Test("The same patterns always give the same lines")
    func deterministic() {
        let patterns = [pattern("a"), pattern("b", factor: "Morning light", outcome: .hrv, difference: 4, nights: 41, strength: .clear)]
        #expect(writer.patternLines(patterns) == writer.patternLines(patterns))
        #expect(writer.patternLines(patterns).count == 2)
    }
}
