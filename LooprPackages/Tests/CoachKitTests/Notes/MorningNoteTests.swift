import DesignSystem
import DomainKit
import Foundation
import Testing
@testable import CoachKit

@Suite("LV-09.1 morning note")
struct MorningNoteTests {
    private let writer = NoteFixtures.writer()

    private func make(_ input: MorningNoteInput, _ writer: CoachNoteWriter? = nil) -> CoachNote? {
        (writer ?? self.writer).morning(input)
    }

    @Test("The contract note reads last night, the usual, the factor and the counted nights")
    func contractNote() throws {
        let note = try #require(make(NoteFixtures.morning()))
        #expect(note.kind == .morning)
        #expect(note.text == "Sleep heart rate was 49 bpm last night, 4 bpm below your usual over the previous 28 nights. "
            + "You stopped eating 4 h 04 m before bed. "
            + "On the 21 nights with 4 h or more, sleep heart rate averaged 5 bpm lower than on the 9 nights with less.")
        #expect(note.runs.filter(\.isHighlighted).map(\.text) == ["49 bpm", "4 h 04 m"])
        NoteFixtures.expectClean(note)
    }

    @Test("The note names its days and its comparison group, with the nights counted")
    func namesDaysAndComparisonGroup() throws {
        let note = try #require(make(NoteFixtures.morning()))
        #expect(note.comparisonGroup == "21 nights with 4 h or more, against 9 nights with less")
        #expect(note.daysCovered == "Last night, the night into Thursday. Your usual covers 28 nights. The comparison covers 30 nights.")
        #expect(note.text.contains("28 nights"))
        #expect(note.text.contains("21 nights"))
        #expect(note.text.contains("9 nights"))
    }

    @Test("The number set holds the displayed strings, the values and the digit groups, and nothing else")
    func numberSet() throws {
        let note = try #require(make(NoteFixtures.morning()))
        #expect(note.displayedNumbers == ["49 bpm", "4 bpm", "28 nights", "4 h 04 m", "21 nights", "4", "5 bpm", "9 nights"])
        #expect(note.numberValues == [49, 4, 28, 244, 21, 5, 9])
        #expect(note.numerals == ["49", "4", "28", "04", "21", "5", "9"])
        NoteFixtures.expectNumbersExact(note)
    }

    @Test("The receipt chart groups equal the counts the text states")
    func receiptMatchesText() throws {
        let note = try #require(make(NoteFixtures.morning()))
        let chart = try #require(note.receipt)
        #expect(chart.outcome == .sleepHeartRate)
        #expect(chart.unit == .bpm)
        #expect(chart.lastNightValue == 49)
        #expect(chart.groups.map(\.label) == ["21 nights, 4 h or more", "9 nights, less"])
        #expect(chart.groups.map(\.isLikeLastNight) == [true, false])
        #expect(chart.groups.map(\.nightCount) == [21, 9])
        #expect(chart.groups.map(\.nights.count) == [21, 9])
        #expect(chart.groups.map(\.mean) == [50, 55])
        #expect(chart.groups[1].nights.allSatisfy { $0.value == 55 })
        let stated = Dictionary(uniqueKeysWithValues: note.numbers.filter { $0.unit == .nights }.map { ($0.displayed, Int($0.value)) })
        #expect(stated["21 nights"] == chart.groups[0].nightCount)
        #expect(stated["9 nights"] == chart.groups[1].nightCount)
    }

    @Test("The chips are Why 49 and All 30 nights")
    func chips() throws {
        let note = try #require(make(NoteFixtures.morning()))
        #expect(note.chips.map(\.label) == ["Why 49?", "All 30 nights"])
        #expect(note.chips.map(\.action) == [.explainOutcome, .showNights])
        #expect(note.supportingNumbers.map(\.displayed) == ["30 nights"])
    }

    @Test("A factor under the minimum nights in either group is never named")
    func belowMinimumNeverNamed() throws {
        let minimum = NoteThresholds.standard.minimumNightsPerGroup
        #expect(minimum == 7)
        for (long, short) in [(30, minimum - 1), (minimum - 1, 30), (3, 3), (0, 20)] {
            let history = NoteFixtures.dinnerHistory(long: long, short: short)
            let input = NoteFixtures.morning(factors: [NoteFixtures.dinner(history: history)])
            let note = try #require(make(input))
            #expect(note.receipt == nil, "\(long) and \(short) nights")
            #expect(!note.text.contains("stopped eating"))
            #expect(!note.text.contains("averaged"))
            #expect(note.comparisonGroup == "Your usual over 28 nights")
            #expect(note.chips.map(\.action) == [.explainOutcome])
            NoteFixtures.expectClean(note)
        }
        let atMinimum = NoteFixtures.dinnerHistory(long: minimum, short: minimum)
        let named = try #require(make(NoteFixtures.morning(factors: [NoteFixtures.dinner(history: atMinimum)])))
        #expect(named.text.contains("On the 7 nights with 4 h or more"))
        #expect(named.text.contains("than on the 7 nights with less"))
    }

    @Test("A factor below the minimum is skipped even when its difference is larger")
    func belowMinimumLosesToSmallerDifference() throws {
        let tiny = NoteFixtures.alcohol(long: 20, short: 6, shortMean: 90, longMean: 50, id: "tiny")
        let note = try #require(make(NoteFixtures.morning(factors: [tiny, NoteFixtures.dinner()])))
        #expect(note.text.contains("stopped eating"))
        #expect(!note.text.contains("a drink"))
    }

    @Test("The strongest factor that applies to last night wins")
    func strongestFactorWins() throws {
        let alcohol = NoteFixtures.alcohol(long: 10, short: 8, shortMean: 58, longMean: 50)
        let note = try #require(make(NoteFixtures.morning(factors: [NoteFixtures.dinner(), alcohol])))
        #expect(note.text.hasSuffix("You had a drink in the evening. On the 8 nights with a drink, sleep heart rate averaged 8 bpm higher than on the 10 nights with no drink."))
        #expect(!note.text.contains("stopped eating"))
        let chart = try #require(note.receipt)
        #expect(chart.groups.map(\.label) == ["8 nights, a drink", "10 nights, no drink"])
        #expect(note.chips.last?.label == "All 18 nights")
        NoteFixtures.expectClean(note)
    }

    @Test("The order of the factors does not change the note")
    func orderDoesNotMatter() throws {
        let alcohol = NoteFixtures.alcohol(long: 10, short: 8, shortMean: 58, longMean: 50)
        let first = make(NoteFixtures.morning(factors: [NoteFixtures.dinner(), alcohol]))
        let second = make(NoteFixtures.morning(factors: [alcohol, NoteFixtures.dinner()]))
        #expect(first == second)
        #expect(first == make(NoteFixtures.morning(factors: [NoteFixtures.dinner(), alcohol])))
    }

    @Test("A factor that does not apply to last night is never named")
    func factorMustApplyToLastNight() throws {
        let unknownGroup = NoteFixtures.dinner(lastGroup: nil)
        let unknownValue = NoteFixtures.dinner(value: nil)
        let wrongGroup = NoteFixtures.dinner(lastGroup: "elsewhere")
        for factor in [unknownGroup, unknownValue, wrongGroup] {
            let note = try #require(make(NoteFixtures.morning(factors: [factor])))
            #expect(note.receipt == nil)
            #expect(!note.text.contains("stopped eating"))
        }
    }

    @Test("A factor needs two distinct groups")
    func factorNeedsTwoGroups() throws {
        let one = NightFactor(id: "one", name: "One", statement: "Statement.", lastNightValue: .flag, lastNightGroupID: "long",
                              groups: [NoteFixtures.longGroup], history: NoteFixtures.dinnerHistory())
        let same = NightFactor(id: "same", name: "Same", statement: "Statement.", lastNightValue: .flag, lastNightGroupID: "long",
                               groups: [NoteFixtures.longGroup, NoteFixtures.longGroup], history: NoteFixtures.dinnerHistory())
        for factor in [one, same] {
            #expect(try #require(make(NoteFixtures.morning(factors: [factor]))).receipt == nil)
        }
    }

    @Test("Nights without an outcome are left out of the counts and the means")
    func missingOutcomesStayMissing() throws {
        var history = NoteFixtures.dinnerHistory(long: 21, short: 7)
        history += (0..<10).map { NoteFactorNight(day: NoteFixtures.day($0), groupID: "short", outcome: nil) }
        history += [NoteFactorNight(groupID: "long", outcome: .nan), NoteFactorNight(groupID: "long", outcome: .infinity)]
        let note = try #require(make(NoteFixtures.morning(factors: [NoteFixtures.dinner(history: history)])))
        let chart = try #require(note.receipt)
        #expect(chart.groups.map(\.nightCount) == [21, 7])
        #expect(chart.groups.map(\.mean) == [50, 55])
        #expect(note.text.contains("the 7 nights with less"))

        // Only 4 of the 10 short nights have an outcome, so the factor goes unnamed.
        var thin = NoteFixtures.dinnerHistory(long: 21, short: 4)
        thin += (0..<6).map { _ in NoteFactorNight(groupID: "short", outcome: nil) }
        let unnamed = try #require(self.make(NoteFixtures.morning(factors: [NoteFixtures.dinner(history: thin)])))
        #expect(unnamed.receipt == nil)
    }

    @Test("A difference that rounds to nothing is not named")
    func zeroDifferenceNotNamed() throws {
        let history = NoteFixtures.dinnerHistory(long: 12, short: 12, longMean: 50, shortMean: 50.2)
        let note = try #require(make(NoteFixtures.morning(factors: [NoteFixtures.dinner(history: history)])))
        #expect(note.receipt == nil)
        #expect(!note.text.contains("averaged"))
    }

    @Test("A usual with too few nights says what is being learnt instead of comparing")
    func learningTheUsual() throws {
        let few = try #require(make(NoteFixtures.morning(factors: [], usual: NoteUsual(median: 53, nights: 3, windowDays: 30))))
        #expect(few.text == "Sleep heart rate was 49 bpm last night. Loopr needs 7 nights of data to learn your usual and has 3 nights so far.")
        #expect(!few.text.contains("below"))
        #expect(!few.text.contains("above"))
        #expect(few.comparisonGroup == nil)
        #expect(few.receipt == nil)
        NoteFixtures.expectClean(few)

        let none = try #require(make(NoteFixtures.morning(factors: [], usual: nil)))
        #expect(none.text == "Sleep heart rate was 49 bpm last night. Loopr needs 7 nights of data to learn your usual.")
        NoteFixtures.expectClean(none)

        let boundary = try #require(make(NoteFixtures.morning(factors: [], usual: NoteUsual(median: 53, nights: 7, windowDays: 30))))
        #expect(boundary.text.contains("below your usual over the previous 7 nights"))
    }

    @Test("Without a usual the factor can still be named")
    func factorWithoutUsual() throws {
        let note = try #require(make(NoteFixtures.morning(usual: nil)))
        #expect(note.text.hasPrefix("Sleep heart rate was 49 bpm last night. Loopr needs 7 nights"))
        #expect(note.text.contains("On the 21 nights with 4 h or more"))
        #expect(note.receipt != nil)
        NoteFixtures.expectClean(note)
    }

    @Test("A night in line with the usual is not given a gap")
    func inLineWithUsual() throws {
        let note = try #require(make(NoteFixtures.morning(factors: [], usual: NoteUsual(median: 49.3, nights: 28, windowDays: 30))))
        #expect(note.text == "Sleep heart rate was 49 bpm last night, in line with your usual over the previous 28 nights.")
        NoteFixtures.expectClean(note)
    }

    @Test("Above the usual reads above")
    func aboveUsual() throws {
        let outcome = NightOutcome(kind: .hrv, value: 71.4)
        let note = try #require(make(NoteFixtures.morning(factors: [], usual: NoteUsual(median: 64, nights: 20, windowDays: 30), outcome: outcome)))
        #expect(note.text == "HRV was 71 ms last night, 7 ms above your usual over the previous 20 nights.")
        NoteFixtures.expectClean(note)
    }

    @Test("Absent inputs give an absent note")
    func absentInputs() {
        #expect(make(NoteFixtures.morning(outcome: nil)) == nil)
        #expect(make(MorningNoteInput(lastNight: nil)) == nil)
        for value in [Double.nan, .infinity, -4] {
            let outcome = NightOutcome(kind: .sleepHeartRate, value: value)
            #expect(make(NoteFixtures.morning(outcome: outcome)) == nil, "\(value)")
        }
    }

    @Test("Each outcome kind and unit reads in its own words")
    func outcomeKinds() throws {
        let deep = try #require(make(NoteFixtures.morning(factors: [], usual: NoteUsual(median: 70, nights: 20, windowDays: 30),
                                                          outcome: NightOutcome(kind: .deepSleep, value: 48))))
        #expect(deep.text == "Deep sleep was 48 min last night, 22 min below your usual over the previous 20 nights.")

        let sleep = try #require(make(NoteFixtures.morning(factors: [], usual: NoteUsual(median: 455, nights: 20, windowDays: 30),
                                                           outcome: NightOutcome(kind: .sleepDuration, value: 400))))
        #expect(sleep.text == "Sleep was 6 h 40 m last night, 55 min below your usual over the previous 20 nights.")
        #expect(sleep.chips.first?.label == "Why 6 h 40 m?")

        let long = try #require(make(NoteFixtures.morning(factors: [], usual: NoteUsual(median: 360, nights: 20, windowDays: 30),
                                                          outcome: NightOutcome(kind: .sleepDuration, value: 425))))
        #expect(long.text.contains("1 h 05 m above your usual"))
        for note in [deep, sleep, long] { NoteFixtures.expectClean(note) }
    }

    @Test("No sentence says caused, because or due to, and a factor that does is not named")
    func neverClaimsACause() throws {
        let notes = [
            make(NoteFixtures.morning()),
            make(NoteFixtures.morning(factors: [], usual: nil)),
            make(NoteFixtures.morning(factors: [NoteFixtures.alcohol(long: 10, short: 8, shortMean: 58, longMean: 50)])),
        ].compactMap { $0 }
        #expect(notes.count == 3)
        for note in notes { NoteFixtures.expectNoCauseWording(note) }

        let history = NoteFixtures.dinnerHistory()
        let labelled = NightFactor(id: "bad", name: "Bad", statement: "You stopped eating {value} before bed.",
                                   lastNightValue: .duration(minutes: 244), lastNightGroupID: "long",
                                   groups: [NoteFactorGroup(id: "long", label: "4 h or more, which caused it"), NoteFixtures.shortGroup],
                                   history: history)
        let statement = NightFactor(id: "bad2", name: "Bad", statement: "Dinner timing is why you slept well because of it!",
                                    lastNightValue: .flag, lastNightGroupID: "long",
                                    groups: [NoteFixtures.longGroup, NoteFixtures.shortGroup], history: history)
        for factor in [labelled, statement] {
            let note = try #require(make(NoteFixtures.morning(factors: [factor])))
            #expect(note.receipt == nil)
            NoteFixtures.expectNoCauseWording(note)
        }
    }

    @Test("The comparison says how nights differed in plain words")
    func saysDifference() throws {
        let note = try #require(make(NoteFixtures.morning()))
        #expect(note.text.contains("averaged 5 bpm lower than on the"))
        let higher = try #require(self.make(NoteFixtures.morning(factors: [NoteFixtures.alcohol(long: 10, short: 8, shortMean: 58, longMean: 50)])))
        #expect(higher.text.contains("averaged 8 bpm higher than on the"))
    }

    @Test("Times and numbers follow the locale")
    func followsLocale() throws {
        let bedtime = NightFactor(id: "bed", name: "Bedtime", statement: "You went to bed at {value}.",
                                  lastNightValue: .clock(minuteOfDay: 23 * 60 + 15), lastNightGroupID: "long",
                                  groups: [NoteFactorGroup(id: "long", label: "before midnight"), NoteFixtures.shortGroup],
                                  history: NoteFixtures.dinnerHistory())
        let input = NoteFixtures.morning(factors: [bedtime])
        let us = try #require(make(input, NoteFixtures.writer(NoteFixtures.enUS)))
        let gb = try #require(make(input, NoteFixtures.writer(NoteFixtures.enGB)))
        let de = try #require(make(input, NoteFixtures.writer(NoteFixtures.deDE)))
        #expect(us.text.contains("You went to bed at \(NoteFixtures.clock(1_395, NoteFixtures.enUS))."))
        #expect(us.text.contains("11:15"))
        #expect(us.text.contains("PM"))
        #expect(gb.text.contains("You went to bed at 23:15."))
        #expect(de.text.contains("You went to bed at 23:15."))
        #expect(!gb.text.contains("PM"))
        #expect(!de.text.contains("PM"))
        for note in [us, gb, de] { NoteFixtures.expectClean(note) }
        #expect(us.numberValues.contains(1_395))
        #expect(gb.numberValues.contains(1_395))
    }

    @Test("Large counts are grouped by the locale")
    func groupsNumbers() throws {
        let steps = NightFactor(id: "steps", name: "Steps", statement: "You walked {value} yesterday.",
                                lastNightValue: .quantity(9_812, unit: "steps"), lastNightGroupID: "long",
                                groups: [NoteFactorGroup(id: "long", label: "more steps"), NoteFixtures.shortGroup],
                                history: NoteFixtures.dinnerHistory())
        let input = NoteFixtures.morning(factors: [steps])
        let us = try #require(make(input, NoteFixtures.writer(NoteFixtures.enUS)))
        let de = try #require(make(input, NoteFixtures.writer(NoteFixtures.deDE)))
        #expect(us.text.contains("You walked 9,812 steps yesterday."))
        #expect(de.text.contains("You walked 9.812 steps yesterday."))
        #expect(us.numberValues.contains(9_812))
        for note in [us, de] { NoteFixtures.expectClean(note) }
    }

    @Test("The weekday follows the injected calendar and locale")
    func weekdayFollowsInjection() throws {
        let us = try #require(make(NoteFixtures.morning(), NoteFixtures.writer(NoteFixtures.enUS)))
        let de = try #require(make(NoteFixtures.morning(), NoteFixtures.writer(NoteFixtures.deDE)))
        #expect(us.daysCovered.hasPrefix("Last night, the night into Thursday."))
        #expect(de.daysCovered.hasPrefix("Last night, the night into Donnerstag."))
        let undated = try #require(make(NoteFixtures.morning(outcome: NightOutcome(kind: .sleepHeartRate, value: 49))))
        #expect(undated.daysCovered.hasPrefix("Last night. "))
    }

    @Test("The same input always gives the same note")
    func deterministic() {
        let input = NoteFixtures.morning()
        let notes = (0..<5).map { _ in make(input) }
        #expect(notes.allSatisfy { $0 == notes[0] })
        #expect(notes[0] != nil)
    }
}
