import DesignSystem
import DomainKit
import Foundation
import RoutineKit
import Testing
@testable import CoachKit

@Suite("LV-09.1 evening note")
struct EveningNoteTests {
    private let writer = NoteFixtures.writer(NoteFixtures.enGB)

    private func make(_ rules: [NoteRuleDay], _ writer: CoachNoteWriter? = nil) -> CoachNote? {
        (writer ?? self.writer).evening(EveningNoteInput(rules: rules))
    }

    private func clock(_ minute: Int, _ locale: Locale = NoteFixtures.enGB) -> String {
        NoteFixtures.clock(minute, locale)
    }

    @Test("The contract note names what closed, the week and the last rule left")
    func contractNote() throws {
        let note = try #require(make([NoteFixtures.screens, NoteFixtures.kitchen]))
        #expect(note.kind == .evening)
        #expect(note.text == "Kitchen closed at 18:20. That is 7 of 7 days this week. Screens off at 21:45 is the last rule left.")
        #expect(note.runs.filter(\.isHighlighted).map(\.text) == ["18:20"])
        #expect(note.receipt == nil)
        #expect(note.chips.map(\.label) == ["Start wind-down", "Ask"])
        #expect(note.chips.map(\.action) == [.startWindDown, .ask])
        #expect(note.daysCovered == "Today, and the days so far this week.")
        #expect(note.comparisonGroup == "The 7 days of this week so far")
        NoteFixtures.expectClean(note)
    }

    @Test("Rules are ordered by time, kept rules by when they were kept, rules without a time last")
    func ordersByTime() throws {
        let rules = [
            NoteFixtures.ruleDay("supplements", "Supplements", at: nil, .kept),
            NoteFixtures.ruleDay("zone2", "Zone 2", at: 17 * 60 + 30, .kept, keptAt: 17 * 60 + 40),
            NoteFixtures.ruleDay("screens", "Screens off", at: 21 * 60 + 45, .pending),
            NoteFixtures.ruleDay("light", "Morning light", at: 7 * 60, .kept, keptAt: 7 * 60 + 10),
            NoteFixtures.ruleDay("cold", "Cold shower", at: 20 * 60, .pending),
        ]
        let note = try #require(make(rules))
        let expected = "So far today you have kept Morning light at \(clock(430)), Zone 2 at \(clock(1_060)) and Supplements. "
            + "Still to come before bed: Cold shower at \(clock(1_200)) and Screens off at \(clock(1_305))."
        #expect(note.text == expected)
        #expect(note.runs.filter(\.isHighlighted).isEmpty)
        NoteFixtures.expectClean(note)

        var generator = SeededGenerator(seed: 7)
        let permutations: [[NoteRuleDay]] = [
            Array(rules.reversed()), rules.shuffled(using: &generator), rules.sorted { $0.rule.title < $1.rule.title },
        ]
        for permutation in permutations {
            #expect(make(permutation) == note)
        }
    }

    @Test("A rule with an unknown check gets no sentence, and neither does a missed one")
    func unknownAndMissedSaySilence() throws {
        let rules = [
            NoteFixtures.kitchen,
            NoteFixtures.ruleDay("plunge", "Cold plunge", at: 19 * 60, .unknown),
            NoteFixtures.ruleDay("cardio", "Cardio", at: 12 * 60, .missed),
            NoteFixtures.screens,
        ]
        let note = try #require(make(rules))
        #expect(!note.text.contains("Cold plunge"))
        #expect(!note.text.contains("Cardio"))
        #expect(!note.text.localizedCaseInsensitiveContains("unknown"))
        #expect(!note.text.localizedCaseInsensitiveContains("missed"))
        #expect(note.text == "Kitchen closed at 18:20. That is 7 of 7 days this week. Screens off at 21:45 is the last rule left.")
        NoteFixtures.expectClean(note)

        let allKept = [NoteFixtures.kitchen, NoteFixtures.ruleDay("plunge", "Cold plunge", at: 19 * 60, .unknown)]
        let kept = try #require(make(allKept))
        #expect(!kept.text.contains("Every rule"))
        #expect(kept.chips.map(\.action) == [.ask])
    }

    @Test("No rules, or nothing to say, gives no note")
    func absentNote() {
        #expect(make([]) == nil)
        #expect(make([NoteFixtures.ruleDay("plunge", "Cold plunge", at: nil, .unknown)]) == nil)
        #expect(make([NoteFixtures.ruleDay("cardio", "Cardio", at: nil, .missed),
                      NoteFixtures.ruleDay("plunge", "Cold plunge", at: nil, .unknown)]) == nil)
        #expect(make([NoteFixtures.ruleDay("blank", "  ", at: nil, .kept)]) == nil)
    }

    @Test("A week count is stated only when it is real")
    func weekCountMustBeReal() throws {
        for (week, days) in [(1, 7), (8, 7), (3, 2), (3, 9), (0, 5)] as [(Int, Int)] {
            let day = NoteFixtures.ruleDay("kitchen", "Kitchen closes", at: 1_110, .kept, keptAt: 1_100, label: "Kitchen closed",
                                           week: week, of: days)
            let note = try #require(make([day]))
            #expect(note.text == "Kitchen closed at 18:20.", "\(week) of \(days)")
            #expect(note.comparisonGroup == nil)
            #expect(note.daysCovered == "Today.")
        }
        let none = NoteFixtures.ruleDay("kitchen", "Kitchen closes", at: 1_110, .kept, keptAt: 1_100, label: "Kitchen closed")
        #expect(try #require(make([none])).text == "Kitchen closed at 18:20.")
        let real = NoteFixtures.ruleDay("kitchen", "Kitchen closes", at: 1_110, .kept, keptAt: 1_100, label: "Kitchen closed", week: 2, of: 3)
        #expect(try #require(make([real])).text == "Kitchen closed at 18:20. That is 2 of 3 days this week.")
    }

    @Test("With several kept rules the count names the rule that has the longest run")
    func countNamesTheLead() throws {
        let rules = [
            NoteFixtures.ruleDay("zone2", "Zone 2, 45 min", at: 17 * 60 + 30, .kept, keptAt: 17 * 60 + 40, week: 4, of: 5),
            NoteFixtures.ruleDay("protein", "Protein", at: nil, .kept, week: 2, of: 5),
        ]
        let note = try #require(make(rules))
        #expect(note.text == "So far today you have kept Zone 2, 45 min at 17:40 and Protein. You kept Zone 2, 45 min on 4 of 5 days this week. Every rule for today is kept.")
        #expect(note.chips.map(\.action) == [.ask])
        // The digits in a rule title are numbers too, so they are in the set.
        #expect(note.displayedNumbers.isSuperset(of: ["2", "45", "17:40", "4", "5 days"]))
        NoteFixtures.expectClean(note)
    }

    @Test("A long list names the first four and counts the rest")
    func longListCountsTheRest() throws {
        let rules = (0..<6).map { index in
            NoteFixtures.ruleDay("rule\(index)", "Rule \(["a", "b", "c", "d", "e", "f"][index])", at: 8 * 60 + index * 60, .pending)
        }
        let note = try #require(make(rules))
        #expect(note.text == "Still to come before bed: Rule a at \(clock(480)), Rule b at \(clock(540)), Rule c at \(clock(600)), "
                + "Rule d at \(clock(660)) and 2 more.")
        NoteFixtures.expectClean(note)
    }

    /// ICP R3-OPT-15: a rule whose title names its time is listed once, without "at" the same time again.
    @Test("A rule that names its time is not timed twice")
    func aTimedTitleIsNotTimedTwice() throws {
        let rules = [NoteFixtures.ruleDay("magnesium", "Magnesium", at: 21 * 60 + 30, .pending),
                     NoteFixtures.ruleDay("screens", "Screens off by 21:45", at: 21 * 60 + 45, .pending),
                     NoteFixtures.ruleDay("bed", "In bed by 22:30", at: 22 * 60 + 30, .pending)]
        let note = try #require(make(rules))
        #expect(note.text == "Still to come before bed: Magnesium at \(clock(1_290)), Screens off by 21:45 and In bed by 22:30.")
        NoteFixtures.expectClean(note)
    }

    @Test("One kept rule without a past-tense label, and one rule left with nothing kept")
    func singleRules() throws {
        let kept = NoteFixtures.ruleDay("light", "Morning light", at: nil, .kept)
        #expect(try #require(make([kept])).text == "So far today you have kept Morning light.")
        let only = try #require(make([NoteFixtures.screens]))
        #expect(only.text == "Screens off at 21:45 is the only rule left today.")
        #expect(only.chips.map(\.action) == [.startWindDown, .ask])
        let untimed = NoteFixtures.ruleDay("supplements", "Supplements", at: nil, .pending)
        #expect(try #require(make([untimed])).text == "Supplements is the only rule left today.")
    }

    @Test("Times follow a 12-hour and a 24-hour locale")
    func followsClock() throws {
        let rules = [NoteFixtures.kitchen, NoteFixtures.screens]
        let us = try #require(make(rules, NoteFixtures.writer(NoteFixtures.enUS)))
        let gb = try #require(make(rules, NoteFixtures.writer(NoteFixtures.enGB)))
        let de = try #require(make(rules, NoteFixtures.writer(NoteFixtures.deDE)))
        #expect(us.text.contains("Kitchen closed at \(clock(1_100, NoteFixtures.enUS))."))
        #expect(us.text.contains("Screens off at \(clock(1_305, NoteFixtures.enUS))"))
        #expect(us.text.contains("6:20"))
        #expect(us.text.contains("9:45"))
        #expect(us.text.contains("PM"))
        #expect(gb.text.contains("18:20") && gb.text.contains("21:45"))
        #expect(de.text.contains("18:20") && de.text.contains("21:45"))
        #expect(!gb.text.contains("PM") && !de.text.contains("PM"))
        for note in [us, gb, de] { NoteFixtures.expectClean(note) }
        #expect(us.numberValues.isSuperset(of: [1_100, 1_305]))
        #expect(gb.numberValues.isSuperset(of: [1_100, 1_305]))
    }

    @Test("A rule whose title claims a cause is left out of the note")
    func titlesAreChecked() throws {
        let rules = [
            NoteFixtures.kitchen,
            NoteFixtures.ruleDay("bad", "No screens because of sleep", at: 21 * 60, .pending),
        ]
        let note = try #require(make(rules))
        #expect(!note.text.contains("No screens"))
        NoteFixtures.expectNoCauseWording(note)
        #expect(make([NoteFixtures.ruleDay("bad", "No screens due to sleep", at: nil, .pending)]) == nil)
    }

    @Test("Sources do not change what the note says, and the same input always gives the same note")
    func deterministic() throws {
        let band = ProtocolRule(key: "screens", title: "Screens off", timeOfDayMinutes: 21 * 60 + 45, source: .band)
        let fromBand = NoteRuleDay(rule: band, state: .pending)
        let first = make([NoteFixtures.kitchen, fromBand])
        let second = make([NoteFixtures.kitchen, NoteFixtures.screens])
        #expect(first == second)
        #expect(first == make([NoteFixtures.kitchen, fromBand]))
    }
}

/// A fixed shuffle, so a test never depends on the system generator.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
