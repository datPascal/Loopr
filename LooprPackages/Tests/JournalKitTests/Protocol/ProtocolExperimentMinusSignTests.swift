import Foundation
import JournalKit
import RoutineKit
import Testing

/// LV-10 polish: an experiment that came out lower writes its difference with U+2212 and is read as "minus".
struct ProtocolExperimentMinusSignTests {
    private static let minus = "\u{2212}"

    /// The usual 14-night experiment with the arms swapped, so the difference is -20 minutes.
    private func lowerOnMagnesium() throws -> ProtocolExperimentItem {
        try ProtocolExperimentTestData.finished(on: ProtocolExperimentTestData.clearOff, off: ProtocolExperimentTestData.clearOn)
    }

    @Test func aNegativeDifferenceUsesTheTypographicMinusInTheRowAndTheHero() throws {
        let presentation = ProtocolExperimentPresentation.make(try lowerOnMagnesium())
        #expect(presentation.effect == -20)
        // The range rides with the effect, in the same minus (ICP R1-VET-11).
        #expect(presentation.rowSubtitle.hasPrefix("Deep sleep \(Self.minus)20 min, 95% range \(Self.minus)"), "\(presentation.rowSubtitle)")
        #expect(presentation.rowSubtitle.hasSuffix(" \u{00B7} 7 nights each"))
        #expect(presentation.rangeLine?.hasPrefix("95% range \(Self.minus)") == true && presentation.rangeLine?.contains("-") == false)
        #expect(!presentation.rowSubtitle.contains("-"))
        #expect(ExperimentCopy.signed(-9.3) == "\(Self.minus)9.3")
        #expect(ExperimentCopy.signed(14) == "+14")
    }

    @Test func theStripSummaryReadsMinusAndNeverAHyphenOrTheSymbol() throws {
        let strip = ProtocolExperimentStrip.make(try lowerOnMagnesium(), showsRange: true)
        #expect(strip.accessibilitySummary.contains("Difference minus 20 min"))
        #expect(!strip.accessibilitySummary.contains(Self.minus))
        #expect(!strip.accessibilitySummary.contains("-20"))
    }

    @Test func theSpokenFormOfASignedAmountSaysMinusOrPlus() {
        #expect(ExperimentCopy.spokenSigned(-9.3) == "minus 9.3")
        #expect(ExperimentCopy.spokenSigned(14) == "plus 14")
        #expect(ExperimentCopy.spokenSigned(0.01) == "0")
    }
}
