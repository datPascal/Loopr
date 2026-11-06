import Foundation
import Testing
@testable import DesignSystem

/// LV-10 polish: a signed number on screen carries U+2212 MINUS SIGN, never the ASCII hyphen, and VoiceOver reads
/// it as "minus".
struct LooprSignedNumberTests {
    private static let english = Locale(identifier: "en_US")
    private static let german = Locale(identifier: "de_DE")
    private static let minus = "\u{2212}"

    @Test func aNegativeNumberCarriesTheTypographicMinus() {
        #expect(LooprSignedNumber.text(-4, locale: Self.english) == "\(Self.minus)4")
        #expect(LooprSignedNumber.text(-2.46, fractionDigits: 1, locale: Self.english) == "\(Self.minus)2.5")
        #expect(LooprSignedNumber.text(-1_250, locale: Self.english) == "\(Self.minus)1,250")
        #expect(!LooprSignedNumber.text(-17.1, fractionDigits: 1, locale: Self.english).contains("-"))
        #expect(LooprSignedNumber.minusSign.unicodeScalars.map(\.value) == [0x2212])
    }

    @Test func aPositiveNumberCarriesAPlusOnlyWhenAskedTo() {
        #expect(LooprSignedNumber.text(6, locale: Self.english) == "+6")
        #expect(LooprSignedNumber.text(0.5, fractionDigits: 1, locale: Self.english) == "+0.5")
        #expect(LooprSignedNumber.text(6, plus: false, locale: Self.english) == "6")
        #expect(LooprSignedNumber.text(-6, plus: false, locale: Self.english) == "\(Self.minus)6")
    }

    @Test func zeroAndValuesThatRoundToZeroHaveNoSign() {
        #expect(LooprSignedNumber.text(0, locale: Self.english) == "0")
        #expect(LooprSignedNumber.text(-0.0, locale: Self.english) == "0")
        #expect(LooprSignedNumber.text(0.04, fractionDigits: 1, locale: Self.english) == "0.0")
        #expect(LooprSignedNumber.text(-0.04, fractionDigits: 1, locale: Self.english) == "0.0")
        #expect(LooprSignedNumber.text(-0.2, locale: Self.english) == "0")
        #expect(LooprSignedNumber.text(.nan, locale: Self.english) == "")
        #expect(LooprSignedNumber.text(.infinity, locale: Self.english) == "")
    }

    @Test func theDecimalSeparatorFollowsTheLocale() {
        #expect(LooprSignedNumber.text(-0.5, fractionDigits: 1, locale: Self.german) == "\(Self.minus)0,5")
        #expect(LooprSignedNumber.text(1.2, fractionDigits: 1, locale: Self.german) == "+1,2")
        #expect(LooprSignedNumber.text(-1_234.5, fractionDigits: 1, locale: Self.german) == "\(Self.minus)1.234,5")
        #expect(LooprSignedNumber.text(-1.25, fractionLength: 0...2, locale: Self.german) == "\(Self.minus)1,25")
    }

    @Test func aFractionRangeWritesOnlyTheDecimalsItNeeds() {
        #expect(LooprSignedNumber.text(-23, fractionLength: 0...2, locale: Self.english) == "\(Self.minus)23")
        #expect(LooprSignedNumber.text(-0.5, fractionLength: 0...2, locale: Self.english) == "\(Self.minus)0.5")
        #expect(LooprSignedNumber.text(14.256, fractionLength: 0...2, locale: Self.english) == "+14.26")
    }

    @Test func voiceOverReadsTheSignAsAWord() {
        #expect(LooprSignedNumber.spoken(-4, locale: Self.english) == "minus 4")
        #expect(LooprSignedNumber.spoken(2.5, fractionDigits: 1, locale: Self.english) == "plus 2.5")
        #expect(LooprSignedNumber.spoken(0, locale: Self.english) == "0")
        #expect(LooprSignedNumber.spoken(-0.5, fractionDigits: 1, locale: Self.german) == "minus 0,5")
    }

    @Test func textThatIsAlreadyFormattedIsSpokenWithoutHyphens() {
        #expect(LooprSignedNumber.spoken(text: "\(Self.minus)4 bpm") == "minus 4 bpm")
        #expect(LooprSignedNumber.spoken(text: "-4 bpm") == "minus 4 bpm")
        #expect(LooprSignedNumber.spoken(text: "+14 min") == "plus 14 min")
        #expect(LooprSignedNumber.spoken(text: "HRV \(Self.minus)11 ms") == "HRV minus 11 ms")
        #expect(LooprSignedNumber.spoken(text: "\(Self.minus)0.5 to +1.2 min") == "minus 0.5 to plus 1.2 min")
        #expect(LooprSignedNumber.spoken(text: "(\(Self.minus)3)") == "(minus 3)")
        // A hyphen inside a date, a range or a word is not a sign.
        #expect(LooprSignedNumber.spoken(text: "2026-10-11") == "2026-10-11")
        #expect(LooprSignedNumber.spoken(text: "4-7 nights") == "4-7 nights")
        #expect(LooprSignedNumber.spoken(text: "42-day median") == "42-day median")
        #expect(LooprSignedNumber.spoken(text: "No reading") == "No reading")
    }

    @Test func aHeroNumberSetsAndReadsANegativeValueWithTheMinus() {
        #expect(LooprHeroNumberFormat.text(-4, locale: Self.english) == "\(Self.minus)4")
        #expect(LooprHeroNumberFormat.text(-17.1, fractionDigits: 1, locale: Self.english) == "\(Self.minus)17.1")
        #expect(LooprHeroNumberFormat.text(4, locale: Self.english) == "4")
        #expect(LooprHeroNumberFormat.accessibilityLabel(-4, unit: "bpm", locale: Self.english) == "minus 4 bpm")
        #expect(LooprHeroNumberFormat.accessibilityLabel(4, unit: "bpm", prefix: "+", locale: Self.english) == "plus 4 bpm")
    }

    @Test func theUnitFormatterSharesTheSameMinus() {
        #expect(LooprUnitFormatter.minusSign == LooprSignedNumber.minusSign)
        #expect(LooprUnitFormatter.signed(-2.46, digits: 1) == "\(Self.minus)2.5")
        #expect(LooprUnitFormatter.signedDuration(minutes: -65) == "\(Self.minus)1 h 5 m")
    }

    @MainActor @Test func aMetricRowReadsANegativeValueAsMinus() {
        let row = HairlineMetricRow(title: "Skin temperature", value: "\(Self.minus)0.3", unit: "°C")
        #expect(row.accessibilitySummary.contains("minus 0.3"))
        #expect(!row.accessibilitySummary.contains(Self.minus))
        #expect(!row.accessibilitySummary.contains("-"))
    }
}
