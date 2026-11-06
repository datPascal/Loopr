import SwiftUI

/// A count driven by landing dots: each landing moves the shown value its share of the way from
/// `from` to `to`, and the last landing shows `to` exactly.
public struct LooprCountUp: Equatable, Sendable {
    public var from: Double
    public var to: Double
    /// How many dots will land.
    public var total: Int
    /// How many have landed so far.
    public var landed: Int

    public init(from: Double, to: Double, total: Int, landed: Int = 0) {
        self.from = from
        self.to = to
        self.total = total
        self.landed = landed
    }

    public var isComplete: Bool { landed >= total }

    /// The value to show now.
    public var value: Double {
        guard total > 0, landed < total else { return to }
        return from + (to - from) * Double(max(landed, 0)) / Double(total)
    }

    /// The same count with one more dot landed.
    public func landing() -> Self {
        var next = self
        next.landed = min(landed + 1, total)
        return next
    }
}

/// The one number a screen is about (DESIGN_LANGUAGE premium check 3): Space Grotesk Light at 48 to
/// 76 pt with tabular figures. A new value rolls its digits up from the last one through
/// `contentTransition(.numericText())`. Given a `LooprCountUp`, it advances as its dots land and shows
/// the exact value when the last one lands. Under Reduce Motion the final value fades in at once.
/// A missing value shows `absentText` (or the caller's view), never 0. VoiceOver reads the final value
/// with its unit, never a count in between.
///
/// ```swift
/// LooprHeroNumber(1840, unit: "kcal", spokenUnit: "kilocalories", countUp: count)
/// LooprHeroNumber(nil, unit: "ms")   // "Not measured"
/// ```
public struct LooprHeroNumber<Absent: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.locale) private var environmentLocale

    private let value: Double?
    private let unit: String?
    private let spokenUnit: String?
    private let prefix: String?
    private let suffix: String?
    private let fractionDigits: Int
    private let style: LooprTextStyle
    private let color: LooprColorToken
    private let countUp: LooprCountUp?
    private let locale: Locale?
    private let absent: Absent

    /// - Parameters:
    ///   - unit: set small beside the number, as in `62 ms`.
    ///   - spokenUnit: what VoiceOver says for the unit, when it differs ("kilocalories" for "kcal").
    ///   - prefix: set before the number at its size, such as a sign or "≈".
    ///   - suffix: set after the unit, small.
    ///   - countUp: dots in flight towards this number. Its `to` should equal `value`.
    ///   - locale: the formatting locale. The environment's locale when nil.
    public init(_ value: Double?, unit: String? = nil, spokenUnit: String? = nil, prefix: String? = nil,
                suffix: String? = nil, fractionDigits: Int = 0, style: LooprTextStyle = .heroNumeralXL,
                color: LooprColorToken = .ink, countUp: LooprCountUp? = nil, locale: Locale? = nil,
                @ViewBuilder absent: () -> Absent) {
        self.value = value
        self.unit = unit
        self.spokenUnit = spokenUnit
        self.prefix = prefix
        self.suffix = suffix
        self.fractionDigits = max(fractionDigits, 0)
        self.style = style.isHeroNumeral ? style : .heroNumeralXL
        self.color = color
        self.countUp = countUp
        self.locale = locale
        self.absent = absent()
    }

    /// The caller's locale, else the app's number locale (`LooprUnitFormatter.displayLocale`), so a hero number
    /// groups its digits like every other number on the screen (ICP R2-OPT-21).
    private var resolvedLocale: Locale { locale ?? LooprUnitFormatter.displayLocale }
    private var reduces: Bool { LooprMotion.reducesMotion(reduceMotion) }

    /// The value on screen now: the count's progress, or the final value under Reduce Motion.
    var shown: Double? {
        guard let value else { return nil }
        guard let countUp, !reduces else { return value }
        return countUp.value
    }

    public var body: some View {
        Group {
            if let shown {
                // The final value, hidden, holds the width while the number counts up, so the text beside it is laid
                // out for "93 %" from the first frame and a stale count can never leave "%" over that text (ICP R2-NEW-4).
                ZStack(alignment: .bottomLeading) {
                    number(value ?? shown).hidden()
                    number(shown)
                }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(LooprHeroNumberFormat.accessibilityLabel(value ?? shown, unit: spokenUnit ?? unit, prefix: prefix,
                                                                suffix: suffix, fractionDigits: fractionDigits,
                                                                locale: resolvedLocale))
                    .transition(.opacity)
            } else {
                absent
                    .transition(.opacity)
            }
        }
        .animation(reduces ? .easeOut(duration: LooprMotion.fast) : .smooth(duration: LooprMotion.fast), value: shown)
        .animation(.easeOut(duration: LooprMotion.fast), value: value == nil)
    }

    private func number(_ shown: Double) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.none) {
            if let prefix {
                Text(verbatim: prefix)
                    .looprTypography(style)
                    .foregroundStyle(Color.loopr(color))
            }
            Text(verbatim: LooprHeroNumberFormat.text(shown, fractionDigits: fractionDigits, locale: resolvedLocale))
                .looprTypography(style)
                .foregroundStyle(Color.loopr(color))
                .contentTransition(reduces ? .opacity : .numericText(value: shown))
            if let unit {
                Text(verbatim: unit)
                    .looprTypography(.heroNumeralUnit)
                    .foregroundStyle(Color.loopr(.inkSecondary))
                    .padding(.leading, LooprTextStyle.heroNumeralUnit.baseSize * 0.12)
            }
            if let suffix {
                Text(verbatim: suffix)
                    .looprTypography(.heroNumeralUnit)
                    .foregroundStyle(Color.loopr(.inkSecondary))
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(LooprTextStyle.heroNumeralMinimumScaleFactor)
        .dynamicTypeSize(...LooprTextStyle.heroNumeralMaximumDynamicTypeSize)
    }
}

/// How a hero number is written and read aloud.
public enum LooprHeroNumberFormat {
    /// The number as it is set: grouped and rounded for `locale`, tabular through the style. A negative number
    /// carries U+2212 MINUS SIGN; a positive one carries no sign, because a caller that wants "+" passes it as the
    /// prefix.
    public static func text(_ value: Double, fractionDigits: Int = 0, locale: Locale) -> String {
        // A value that rounds to zero is "0", not "-0".
        LooprSignedNumber.text(value, fractionDigits: fractionDigits, plus: false, locale: locale)
    }

    /// What VoiceOver reads: the final value, its unit and any prefix or suffix. A negative value reads "minus 4",
    /// and a "+" prefix reads "plus".
    public static func accessibilityLabel(_ value: Double, unit: String?, prefix: String? = nil, suffix: String? = nil,
                                          fractionDigits: Int = 0, locale: Locale) -> String {
        let spokenPrefix = prefix.map { $0 == LooprSignedNumber.plusSign ? "plus" : $0 }
        let number = LooprSignedNumber.spoken(value, fractionDigits: fractionDigits, plus: false, locale: locale)
        return [spokenPrefix, number, unit, suffix]
            .compactMap { $0?.isEmpty == false ? $0 : nil }
            .joined(separator: " ")
    }
}

public extension LooprHeroNumber where Absent == LooprHeroNumberAbsent {
    /// A hero number whose missing value reads `absentText` in secondary ink.
    init(_ value: Double?, unit: String? = nil, spokenUnit: String? = nil, prefix: String? = nil, suffix: String? = nil,
         fractionDigits: Int = 0, style: LooprTextStyle = .heroNumeralXL, color: LooprColorToken = .ink,
         countUp: LooprCountUp? = nil, locale: Locale? = nil, absentText: String = LooprHeroNumberAbsent.defaultText) {
        self.init(value, unit: unit, spokenUnit: spokenUnit, prefix: prefix, suffix: suffix, fractionDigits: fractionDigits,
                  style: style, color: color, countUp: countUp, locale: locale) {
            LooprHeroNumberAbsent(absentText)
        }
    }
}

/// The designed absent state of a hero number: a short sentence in secondary ink where the number
/// would be. It is never a 0 and never a blank.
public struct LooprHeroNumberAbsent: View {
    public nonisolated static let defaultText = "Not measured"
    public let text: String

    public init(_ text: String = LooprHeroNumberAbsent.defaultText) {
        self.text = text
    }

    public var body: some View {
        LooprText(text, style: .titleLarge, color: .inkSecondary)
            .accessibilityLabel(text)
    }
}
