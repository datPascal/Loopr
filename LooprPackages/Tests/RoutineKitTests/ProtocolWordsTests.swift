import DomainKit
import Foundation
@testable import RoutineKit
import Testing

/// ICP round 2, W4: the short why line that never ends mid-word, and the experiment words that link a test to its rule
/// and say when the next one can start.
struct ProtocolWordsTests {
    // MARK: Short why line

    /// R2-SEN-05, R2-DES-02: text that fits comes back whole, blank text is no line.
    @Test func aShortWhyComesBackWhole() {
        #expect(ProtocolRule.shortLine("  Fewer drinks usually means better sleep.  ") == "Fewer drinks usually means better sleep.")
        #expect(ProtocolRule.shortLine("   ") == nil && ProtocolRule.shortLine(nil) == nil)
    }

    /// A long why keeps its whole first sentences, so the caveat is never cut in half.
    @Test func aLongWhyStopsAtTheLastWholeSentenceThatFits() {
        let text = "The WHO says no amount of alcohol is free of risk. US dietary guidelines set a limit of 1 drink a day for "
            + "women and 2 for men, and this rule starts lower than either."
        let line = ProtocolRule.shortLine(text)
        #expect(line == "The WHO says no amount of alcohol is free of risk.")
    }

    /// With no sentence end in reach, the line stops at the last whole word with an ellipsis, never inside a word.
    @Test func aLongSentenceStopsAtAWholeWord() throws {
        let text = String(repeating: "steady sleep helps, ", count: 12)
        let line = try #require(ProtocolRule.shortLine(text, limit: 50))
        #expect(line.hasSuffix("\u{2026}") && line.count <= 51)
        let words = line.dropLast().split(separator: " ")
        #expect(words.allSatisfy { ["steady", "sleep", "helps"].contains($0.trimmingCharacters(in: .punctuationCharacters)) }, "\(line)")
        #expect(!line.dropLast().hasSuffix(","))
    }

    /// A decimal point is not a sentence end.
    @Test func aDecimalIsNotASentenceEnd() {
        let text = "A 2013 group suggested 1.0 to 1.2 g of protein per kg of body weight a day for adults over 65, and more for "
            + "people who exercise. The template fits someone near 70 kg."
        #expect(ProtocolRule.shortLine(text, limit: 130)
                == "A 2013 group suggested 1.0 to 1.2 g of protein per kg of body weight a day for adults over 65, and more for people who exercise.")
    }

    // MARK: Experiments

    /// R2-VET-08: the running card names the rule it tests.
    @Test func theRunningCardNamesItsRule() {
        #expect(ExperimentCopy.testsRule("Magnesium, 300 mg") == "Tests your rule Magnesium, 300 mg")
        #expect(ExperimentCopy.testsRule("  ") == nil && ExperimentCopy.testsRule(nil) == nil)
    }

    /// R2-SEN-12: a blocked start says when it can start: the morning after the running test's last night.
    @Test func aBlockedStartSaysTheDayTheTestEnds() throws {
        // 14 nights from Mon 6 Nov: the last night is 19 Nov, so the test ends on 20 Nov.
        let start = try ExpFixtures.start(planned: 14, startDay: ExpFixtures.day(2023, 11, 6), name: "Magnesium")
        #expect(ExperimentCopy.startsAfter(start) == "You can start this after the magnesium test ends on 20 Nov.")
        #expect(ExperimentCopy.dayAndMonth(ExpFixtures.day(2026, 1, 3)) == "3 Jan")
        #expect(!ExperimentCopy.startsAfter(start).contains("\""), "no quote glyphs to get wrong (R2-DES-13)")
    }

    /// R2-VET-10: the range is named for what it is wherever it shows.
    @Test func theRangeIsCalledA95PercentRange() {
        #expect(ExperimentCopy.rangeName() == "95% range")
        #expect(ExperimentCopy.rangeName(policy: ExperimentPolicy(confidence: 0.9)) == "90% range")
        #expect(ExperimentCopy.rangeExplanation().hasPrefix("Loopr gets the 95% range by resampling"))
    }
}
