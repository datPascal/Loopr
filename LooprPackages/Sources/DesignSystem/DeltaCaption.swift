import SwiftUI

/// How a delta writes its number.
public enum LooprDeltaFormat: Sendable, Hashable {
    /// The difference in the metric's own unit, at `digits` decimal places:
    /// `+6 ms`, `−1.2 br/min`.
    case number(digits: Int)
    /// The difference relative to the usual value, in percent: `−22%`.
    case percent
    /// The difference in minutes, written as a duration: `+24 min`, `−1 h 5 m`.
    case duration
}

/// A reading compared with the person's usual range, ready to print.
///
/// Build one with `LooprDelta.compare(_:usual:...)` or `LooprDelta.learning(_:of:)`
/// and hand it to `LooprDeltaCaption`, `LooprContributorRow` or anything else
/// that needs the words. All the rules live here so every screen says the
/// same thing:
///
/// - A value inside the usual range reads "Usual" (or a quiet signed delta if
///   the caller asks for `.signed`).
/// - A value outside it reads "+6 ms vs usual".
/// - A change that rounds to zero reads "Usual", never "+0".
/// - With no usual range yet it reads "Learning · 3 of 14".
///
/// Colour follows principle 6 of the tabs spec: the good direction uses the
/// domain accent, the other direction uses amber only when outside the usual
/// range and grey otherwise, and metrics with no good direction
/// (`higherIsBetter: nil`) are always grey. Never red.
public struct LooprDelta: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// Signed difference from the usual value, in the unit `format` names
        /// (percent points for `.percent`, minutes for `.duration`).
        case change(Double)
        /// Inside the usual range.
        case usual
        /// No usual range yet: `measured` of `needed` days or nights so far.
        case learning(measured: Int, needed: Int)
    }

    /// What colour the caption takes.
    public enum Tone: String, Sendable, Hashable {
        /// Moved in the good direction. Domain accent.
        case good
        /// Moved in the unwanted direction and left the usual range. Amber.
        case caution
        /// Everything else. Secondary ink.
        case neutral
    }

    /// What to print when the value sits inside the usual range.
    public enum WithinRange: Sendable, Hashable {
        /// The word "Usual". Right for captions under rings and tiles.
        case word
        /// The signed difference, so a list can still show size. Right for
        /// contributor rows.
        case signed
    }

    public let kind: Kind
    /// Whether the value sits outside the usual range. Drives amber.
    public let isOutsideUsual: Bool
    /// True when a higher value is better (HRV), false when lower is better
    /// (resting heart rate), nil when neither (strain, weight, steps split).
    public let higherIsBetter: Bool?
    /// Unit printed after a `.number` change, for example "ms".
    public let unit: String
    public let format: LooprDeltaFormat
    /// "nights" or "days", used by the learning text.
    public let learningNoun: String
    /// What a change is measured against, as in "+12 min vs need". "usual"
    /// unless the caller compares with a target instead of the usual range.
    public let reference: String

    public init(
        kind: Kind,
        isOutsideUsual: Bool = false,
        higherIsBetter: Bool? = nil,
        unit: String = "",
        format: LooprDeltaFormat = .number(digits: 0),
        learningNoun: String = "nights",
        reference: String = "usual"
    ) {
        self.kind = kind
        self.isOutsideUsual = isOutsideUsual
        self.higherIsBetter = higherIsBetter
        self.unit = unit
        self.format = format
        self.learningNoun = learningNoun
        self.reference = reference
    }

    /// Compares `value` with the usual range.
    ///
    /// - Returns: nil when there is no value, or no usual range and no
    ///   learning progress to report. Callers then show no caption at all.
    /// - Parameters:
    ///   - value: Today's reading, in the same unit as `usual`.
    ///   - usual: The usual range, usually `LooprBaselineBand.trailing(...)`.
    ///   - learning: Progress towards a usual range, shown while `usual` is nil.
    public static func compare(
        _ value: Double?,
        usual: LooprBaselineBand?,
        higherIsBetter: Bool?,
        unit: String = "",
        format: LooprDeltaFormat = .number(digits: 0),
        withinRange: WithinRange = .word,
        learning: (measured: Int, needed: Int)? = nil,
        learningNoun: String = "nights"
    ) -> LooprDelta? {
        guard let value, value.isFinite else { return nil }
        guard let usual else {
            guard let learning else { return nil }
            return LooprDelta(kind: .learning(measured: max(0, learning.measured), needed: max(1, learning.needed)),
                              higherIsBetter: higherIsBetter, unit: unit, format: format, learningNoun: learningNoun)
        }
        let outside = usual.position(of: value) != .within
        let difference: Double
        switch format {
        case .percent:
            guard usual.center != 0 else { return nil }
            difference = (value - usual.center) / abs(usual.center) * 100
        case .number, .duration:
            difference = value - usual.center
        }
        let make = { (kind: Kind) in
            LooprDelta(kind: kind, isOutsideUsual: outside, higherIsBetter: higherIsBetter,
                       unit: unit, format: format, learningNoun: learningNoun)
        }
        if !outside, withinRange == .word { return make(.usual) }
        if Self.roundsToZero(difference, format: format) { return make(.usual) }
        return make(.change(difference))
    }

    /// Progress towards a usual range, for a metric that has no band yet.
    public static func learning(_ measured: Int, of needed: Int, noun: String = "nights") -> LooprDelta {
        LooprDelta(kind: .learning(measured: max(0, measured), needed: max(1, needed)), learningNoun: noun)
    }

    static func roundsToZero(_ difference: Double, format: LooprDeltaFormat) -> Bool {
        switch format {
        case .number(let digits): (abs(difference) * pow(10, Double(max(0, digits)))).rounded() == 0
        case .percent, .duration: abs(difference).rounded() == 0
        }
    }

    // MARK: Words

    public var tone: Tone {
        guard case .change(let difference) = kind, let higherIsBetter else { return .neutral }
        if (difference > 0) == higherIsBetter { return .good }
        return isOutsideUsual ? .caution : .neutral
    }

    /// The signed number with its unit, `+6 ms`, or nil for usual and learning.
    public var signedText: String? {
        guard case .change(let difference) = kind else { return nil }
        switch format {
        case .number(let digits):
            guard let number = LooprUnitFormatter.signed(difference, digits: digits) else { return nil }
            return unit.isEmpty ? number : (unit == "%" ? number + unit : "\(number) \(unit)")
        case .percent:
            return LooprUnitFormatter.signed(difference, digits: 0).map { $0 + "%" }
        case .duration:
            return LooprUnitFormatter.signedDuration(minutes: difference)
        }
    }

    /// The short form for tight spaces: `+6 ms`, `Usual`, `Learning · 3 of 14`.
    public var compactText: String {
        switch kind {
        case .change: signedText ?? "Usual"
        case .usual: "Usual"
        case .learning(let measured, let needed): "Learning · " + LooprLearningText.progress(have: measured, need: needed, noun: learningNoun)
        }
    }

    /// The full form: `+6 ms vs usual`, `Usual`,
    /// `Learning your usual · 3 of 14 nights`.
    public var text: String {
        switch kind {
        case .change: signedText.map { "\($0) vs \(reference)" } ?? "Usual"
        case .usual: "Usual"
        case .learning(let measured, let needed):
            "Learning your usual · " + LooprLearningText.progress(have: measured, need: needed, noun: learningNoun)
        }
    }

    /// What VoiceOver says: "6 milliseconds above your usual", "In your usual
    /// range", "Learning your usual range, 3 of 14 nights".
    public var spokenText: String {
        switch kind {
        case .usual:
            return "In your usual range"
        case .learning(let measured, let needed):
            return "Learning your usual range, " + LooprLearningText.progress(have: measured, need: needed, noun: learningNoun)
        case .change(let difference):
            let direction = difference > 0 ? "above" : "below"
            let amount: String
            switch format {
            case .number(let digits):
                let number = LooprUnitFormatter.number(abs(difference), digits: digits) ?? ""
                amount = unit.isEmpty ? number : "\(number) \(LooprUnitFormatter.spokenUnit(unit))"
            case .percent:
                amount = "\(LooprUnitFormatter.number(abs(difference), digits: 0) ?? "") percent"
            case .duration:
                amount = LooprUnitFormatter.spokenDuration(minutes: abs(difference)) ?? ""
            }
            return "\(amount) \(direction) your \(reference)"
        }
    }
}

/// The small "vs usual" line under a number: `+6 ms vs usual`, `Usual` or
/// `Learning your usual · 3 of 14 nights`.
///
/// ```swift
/// if let delta = LooprDelta.compare(58, usual: band, higherIsBetter: true, unit: "ms") {
///     LooprDeltaCaption(delta, accent: .heart)
/// }
/// ```
///
/// Use `.compact` under ring tiles and in tight rows, `.standard` everywhere
/// else. The caption is one VoiceOver element that reads the spoken form.
/// Colour never carries the meaning alone: the sign and the words do.
public struct LooprDeltaCaption: View {
    public enum Length: Sendable {
        /// `+6 ms`, `Usual`, `Learning · 3 of 14`.
        case compact
        /// `+6 ms vs usual`, `Usual`, `Learning your usual · 3 of 14 nights`.
        case standard
    }

    private let delta: LooprDelta
    private let accent: LooprColorToken
    private let length: Length
    private let style: LooprTextStyle
    private let wraps: Bool

    /// - Parameters:
    ///   - accent: The screen's domain accent. The good direction prints in a
    ///     text-safe shade of it (`LooprColorToken.textInk`).
    ///   - style: Mono `.metricUnit` by default. Pass `.headerMeta` or
    ///     `.confidence` for a smaller caption.
    public init(_ delta: LooprDelta, accent: LooprColorToken, length: Length = .standard, style: LooprTextStyle = .metricUnit, wraps: Bool = false) {
        self.delta = delta
        self.accent = accent
        self.length = length
        self.style = style
        self.wraps = wraps
    }

    public var body: some View {
        Group {
            if case .change = delta.kind, let signed = delta.signedText {
                if length == .standard {
                    Text("\(Text(signed).foregroundStyle(Color.loopr(toneToken))) vs \(delta.reference)")
                        .foregroundStyle(Color.loopr(.inkSecondary))
                } else {
                    Text(signed).foregroundStyle(Color.loopr(toneToken))
                }
            } else {
                Text(length == .standard ? delta.text : delta.compactText)
                    .foregroundStyle(Color.loopr(.inkSecondary))
            }
        }
        .looprTypography(style)
        .monospacedDigit()
        .lineLimit(wraps ? nil : 1)
        .fixedSize(horizontal: false, vertical: wraps)
        .minimumScaleFactor(0.8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(delta.spokenText)
    }

    /// The colour token the signed number takes, exposed for tests and for
    /// callers that draw their own marks next to the caption.
    public var toneToken: LooprColorToken {
        Self.token(for: delta.tone, accent: accent)
    }

    public static func token(for tone: LooprDelta.Tone, accent: LooprColorToken) -> LooprColorToken {
        switch tone {
        case .good: accent.textInk
        case .caution: .caution
        case .neutral: .inkSecondary
        }
    }
}

#Preview("Delta captions") {
    let band = LooprBaselineBand(center: 52, lower: 47, upper: 57, measuredDays: 28)
    let rhr = LooprBaselineBand(center: 54, lower: 52.5, upper: 55.5, measuredDays: 28)
    let sleep = LooprBaselineBand(center: 450, lower: 420, upper: 480, measuredDays: 28)
    return VStack(alignment: .leading, spacing: LooprSpacing.sm) {
        LooprDeltaCaption(.compare(58, usual: band, higherIsBetter: true, unit: "ms")!, accent: .heart)
        LooprDeltaCaption(.compare(51, usual: rhr, higherIsBetter: false, unit: "bpm")!, accent: .heart)
        LooprDeltaCaption(.compare(59, usual: rhr, higherIsBetter: false, unit: "bpm")!, accent: .heart)
        LooprDeltaCaption(.compare(40, usual: band, higherIsBetter: true, format: .percent)!, accent: .heart)
        LooprDeltaCaption(.compare(462, usual: sleep, higherIsBetter: true, format: .duration)!, accent: .sleep)
        LooprDeltaCaption(.compare(372, usual: sleep, higherIsBetter: true, format: .duration)!, accent: .sleep)
        LooprDeltaCaption(.learning(3, of: 14), accent: .heart)
        LooprDeltaCaption(.learning(3, of: 14), accent: .heart, length: .compact)
    }
    .padding()
    .background(Color.loopr(.background))
}
