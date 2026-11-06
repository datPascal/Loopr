import Foundation

/// The one way a signed number is written for the screen and read aloud.
///
/// A negative number gets U+2212 MINUS SIGN, not the ASCII hyphen-minus: the hyphen is short, sits low and reads
/// as a dash next to tabular figures. A positive number gets "+" when a sign is shown. A value that rounds to
/// zero at the requested precision is plain "0", never "+0" or "−0". Digits and the decimal separator follow
/// `locale`, so a German reader sees `−0,5`.
///
/// Display only. Stored values, CSV, JSON and anything else a machine reads keep the ASCII "-" the encoders
/// write; never feed this output back into a parser.
///
/// Set the result in a font with tabular figures (`.looprTypography` metric styles or `.monospacedDigit()`),
/// so a column of deltas keeps its alignment. U+2212 has the same advance as "+" in those fonts.
///
/// VoiceOver says "minus" for U+2212 only some of the time, so a label built from this number goes through
/// `spoken(_:)` or `spoken(text:)`, which write the word.
public enum LooprSignedNumber {
    /// U+2212 MINUS SIGN.
    public static let minusSign = "\u{2212}"
    public static let plusSign = "+"

    /// `+6`, `−2.5`, or `0` when the value rounds to zero at `fractionDigits` places.
    /// - Parameter plus: write "+" before a positive number. Off, only a negative number carries a sign.
    /// - Returns: an empty string for a value that is not finite.
    public static func text(_ value: Double, fractionDigits: Int = 0, plus: Bool = true, locale: Locale = LooprUnitFormatter.displayLocale) -> String {
        let digits = max(fractionDigits, 0)
        return text(value, fractionLength: digits...digits, plus: plus, locale: locale)
    }

    /// The same, with the decimals in `fractionLength`: `0...2` writes `1.25`, `1.5` and `2`.
    public static func text(_ value: Double, fractionLength: ClosedRange<Int>, plus: Bool = true,
                            locale: Locale = LooprUnitFormatter.displayLocale) -> String {
        guard value.isFinite else { return "" }
        let lower = max(fractionLength.lowerBound, 0)
        let range = lower...max(fractionLength.upperBound, lower)
        let body = abs(value).formatted(.number.precision(.fractionLength(range)).locale(locale))
        guard !isZero(body) else { return body }
        if value < 0 { return minusSign + body }
        return plus ? plusSign + body : body
    }

    /// What VoiceOver reads for the number: `minus 4`, `plus 2.5`, `0`. The digits follow `locale`.
    public static func spoken(_ value: Double, fractionDigits: Int = 0, plus: Bool = true, locale: Locale = LooprUnitFormatter.displayLocale) -> String {
        spoken(text: text(value, fractionDigits: fractionDigits, plus: plus, locale: locale))
    }

    /// Spoken form of text that is already formatted: a sign at the start, or after a space or an opening
    /// bracket and before a digit, becomes a word. "−4 bpm" reads "minus 4 bpm", "+14 min" reads "plus 14 min"
    /// and "−0.5 to +1.2" reads "minus 0.5 to plus 1.2". The ASCII hyphen is read the same way, so text that
    /// did not come through this formatter is still never spoken as "hyphen". A hyphen between two digits, as in
    /// a date or a range, is left alone.
    public static func spoken(text: String) -> String {
        var output = ""
        var previous: Character?
        let characters = Array(text)
        for (index, character) in characters.enumerated() {
            let isSign = character == "\u{2212}" || character == "-" || character == "+"
            let startsNumber = index + 1 < characters.count && characters[index + 1].isNumber
            let followsBoundary = previous == nil || previous == " " || previous == "(" || previous == "\u{00A0}"
            if isSign, startsNumber, followsBoundary {
                output += character == "+" ? "plus " : "minus "
            } else {
                output.append(character)
            }
            previous = character
        }
        return output
    }

    /// True when every digit of a formatted magnitude is zero: "0", "0.0", "0,00".
    private static func isZero(_ body: String) -> Bool {
        body.allSatisfy { $0.wholeNumberValue.map { $0 == 0 } ?? true }
    }
}
