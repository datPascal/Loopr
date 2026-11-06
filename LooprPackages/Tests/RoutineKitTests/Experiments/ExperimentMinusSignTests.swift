import Foundation
import Testing
@testable import RoutineKit

/// LV-10 polish: experiment copy writes a negative number with U+2212 MINUS SIGN, not the ASCII hyphen.
struct ExperimentMinusSignTests {
    private static let minus = "\u{2212}"

    @Test func aNegativeDifferenceUsesTheTypographicMinus() {
        #expect(ExperimentCopy.signed(-9.3) == "\(Self.minus)9.3")
        #expect(ExperimentCopy.signed(-4) == "\(Self.minus)4")
        #expect(ExperimentCopy.signed(14) == "+14")
        #expect(ExperimentCopy.signed(-0.01) == "0")
    }

    @Test func aRangeBelowZeroWritesEachEndWithTheTypographicMinus() {
        let text = ExperimentCopy.rangeText(-9...(-2), unit: "ms", magnitude: false)
        // The unit reads in words in a sentence (ICP R2-SEN-13).
        #expect(text == "\(Self.minus)9 to \(Self.minus)2 milliseconds")
        #expect(!text.contains("-"))
        let across = ExperimentCopy.rangeText(-3...5, unit: "ms", magnitude: false)
        #expect(across == "\(Self.minus)3 to 5 milliseconds")
    }

    @Test func theSpokenFormSaysMinusOrPlus() {
        #expect(ExperimentCopy.spokenSigned(-9.3) == "minus 9.3")
        #expect(ExperimentCopy.spokenSigned(14) == "plus 14")
        #expect(ExperimentCopy.spokenSigned(0.01) == "0")
    }
}
