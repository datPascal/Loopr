import DesignSystem
import Foundation
import Testing

struct SIPolishPresentationTests {
    @Test func comparisonsMatchPrintedPrecisionAndRejectMissingNumbers() {
        #expect(LooprSignalFormatting.comparison(change: 0.49, unit: "bpm", digits: 0) == "Same as usual")
        #expect(LooprSignalFormatting.comparison(change: -0.04, unit: "br/min", digits: 1) == "Same as usual")
        #expect(LooprSignalFormatting.comparison(change: 6, unit: "ms", digits: 0) == "+6 ms vs usual")
        #expect(LooprSignalFormatting.comparison(change: -1.2, unit: "br/min", digits: 1) == "−1.2 br/min vs usual")
        #expect(LooprSignalFormatting.comparison(change: nil, unit: "ms", digits: 0) == nil)
        #expect(LooprSignalFormatting.temperatureChange(.nan) == nil)
        #expect(LooprSignalFormatting.temperatureChange(-0.04) == "0.0")
    }

    @Test func rowModelNeverKeepsAnOrphanDeltaLine() {
        for text in ["vs usual", "  vs usual  ", "ms vs usual", "VS USUAL", ""] {
            #expect(LooprOvernightSignalRowModel(comparison: text).comparison == nil)
        }
        for text in ["+6 ms vs usual", "−0.2 °C vs usual", "Same as usual", "No reading"] {
            #expect(LooprOvernightSignalRowModel(comparison: text).comparison == text)
        }
        #expect(LooprSignalFormatting.outsideRangeHeadline(count: 2) == "Two signals outside your usual range")
    }

    @MainActor @Test func missingRowsKeepTheirReasonInVoiceOver() {
        let row = LooprOvernightSignalRow(title: "Skin temperature", value: nil, unit: "°C",
            comparison: "Wear your band overnight, then sync.", range: nil,
            status: "2 of 14 nights", accent: .heart, identifier: "test")
        #expect(row.accessibilitySummary == "Skin temperature. No reading. Wear your band overnight, then sync. 2 of 14 nights")
    }

    @Test func fixtureVariationIsStableBoundedAndDoesNotRepeatASawtooth() {
        let values = (0..<90).map { LooprFixtureMetrics.variation(seed: "temperature", offset: $0) }
        #expect(values.allSatisfy { (-1...1).contains($0) })
        #expect(Array(values.prefix(30)) == (0..<30).map { LooprFixtureMetrics.variation(seed: "temperature", offset: $0) })
        #expect(Set(values).count == values.count)
        let directions = zip(values, values.dropFirst()).map { $1 > $0 }
        #expect(zip(directions, directions.dropFirst()).contains { $0 == $1 })
    }
}
