import SwiftUI

/// How a `LooprValueStepper` writes its value, when plain numbers are not enough.
/// Rest reads "2:30", not "150".
public struct LooprValueFormat: Sendable {
    /// What the card shows.
    public let text: @Sendable (Double) -> String
    /// What VoiceOver says for the whole value, unit included.
    public let spoken: @Sendable (Double) -> String

    public init(text: @escaping @Sendable (Double) -> String, spoken: @escaping @Sendable (Double) -> String) {
        self.text = text
        self.spoken = spoken
    }

    /// Whole seconds as minutes and seconds: 150 shows "2:30" and is spoken "2 minutes 30 seconds".
    public static let clock = LooprValueFormat(text: { clockText(seconds: $0) }, spoken: { spokenClock(seconds: $0) })

    /// `150` becomes "2:30". Negative and non-finite values show "0:00".
    public static func clockText(seconds: Double) -> String {
        let total = seconds.isFinite ? max(0, Int(seconds.rounded())) : 0
        return "\(total / 60):" + String(format: "%02d", total % 60)
    }

    /// `150` becomes "2 minutes 30 seconds", `60` "1 minute", `45` "45 seconds".
    public static func spokenClock(seconds: Double) -> String {
        let total = seconds.isFinite ? max(0, Int(seconds.rounded())) : 0
        let minutes = total / 60, rest = total % 60
        var parts: [String] = []
        if minutes > 0 { parts.append("\(minutes) \(minutes == 1 ? "minute" : "minutes")") }
        if rest > 0 || minutes == 0 { parts.append("\(rest) \(rest == 1 ? "second" : "seconds")") }
        return parts.joined(separator: " ")
    }
}

/// A card with a mono unit label, a large mono value and glass minus and plus
/// buttons. Live sessions use two of them side by side: KG and REPS.
///
/// The value reads as one adjustable element for VoiceOver (swipe up or down),
/// and the buttons stay separate elements so a UI test can press them by
/// identifier.
///
/// ```swift
/// LooprValueStepper("kg", label: "Weight", spokenUnit: "kilograms", value: $kg, step: 2.5, range: 0...500,
///                   identifier: "train-kg", decrementIdentifier: "train-kg-minus", incrementIdentifier: "train-kg-plus")
/// ```
///
/// Pass `format` when the number needs its own spelling, for example `.clock` for rest seconds.
///
/// Each button is 56 pt tall. Its width is 48 pt, so two steppers fit on one
/// 390 pt row beside a value of up to three digits. At accessibility text
/// sizes the buttons move under the value and each fills half the card.
public struct LooprValueStepper: View {
    public static let minimumTargetHeight: CGFloat = LooprSpacing.interactiveRowHeight

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// Numbers use the app's one number locale, so a half point reads "4.5" beside "9.5/10" on a German-region phone
    /// (R2-OPT-18, R3-NEW-14).
    private var locale: Locale { LooprUnitFormatter.displayLocale }
    @Binding private var value: Double
    private let unit: String
    private let label: String
    private let spokenUnit: String
    private let step: Double
    private let range: ClosedRange<Double>
    private let identifier: String
    private let decrementIdentifier: String
    private let incrementIdentifier: String
    private let format: LooprValueFormat?

    /// - Parameters:
    ///   - unit: The visible unit, set uppercase: "kg" shows KG.
    ///   - label: What the value is, for VoiceOver: "Weight".
    ///   - spokenUnit: The unit VoiceOver says after the number: "kilograms".
    ///   - format: Optional spelling of the value. Nil shows plain numbers and speaks the unit after them.
    public init(_ unit: String, label: String, spokenUnit: String, value: Binding<Double>,
                step: Double, range: ClosedRange<Double>, identifier: String,
                decrementIdentifier: String, incrementIdentifier: String, format: LooprValueFormat? = nil) {
        self.unit = unit
        self.label = label
        self.spokenUnit = spokenUnit
        _value = value
        self.step = step > 0 ? step : 1
        self.range = range
        self.identifier = identifier
        self.decrementIdentifier = decrementIdentifier
        self.incrementIdentifier = incrementIdentifier
        self.format = format
    }

    /// The value held inside `range`.
    public static func clamped(_ value: Double, in range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }

    /// The value after one press: `direction` is 1 for plus and -1 for minus.
    /// Rounds away binary noise (82.49999) and never leaves `range`.
    public static func stepped(_ value: Double, direction: Int, step: Double, range: ClosedRange<Double>) -> Double {
        let raw = value + Double(direction) * step
        return clamped((raw * 1_000_000).rounded() / 1_000_000, in: range)
    }

    /// The value as shown: whole numbers without a decimal, otherwise up to two places.
    /// A `format` replaces that.
    public static func valueText(_ value: Double, locale: Locale = .current, format: LooprValueFormat? = nil) -> String {
        if let format { return format.text(value) }
        return value.formatted(.number.precision(.fractionLength(0...2)).locale(locale))
    }

    /// What VoiceOver reads for the value: "80 kilograms".
    public static func spokenValue(_ value: Double, spokenUnit: String, locale: Locale = .current,
                                   format: LooprValueFormat? = nil) -> String {
        if let format { return format.spoken(value) }
        return "\(valueText(value, locale: locale)) \(spokenUnit)"
    }

    private var canDecrement: Bool { value > range.lowerBound }
    private var canIncrement: Bool { value < range.upperBound }

    private func press(_ direction: Int) {
        value = Self.stepped(value, direction: direction, step: step, range: range)
    }

    public var body: some View {
        LooprCard(density: .compact) {
            VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                Text(unit.looprLabelCased)
                    .looprTypography(.sectionLabel)
                    .foregroundStyle(Color.loopr(.inkSecondary))
                    .accessibilityHidden(true)
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(spacing: LooprSpacing.xs) {
                        valueView
                        HStack(spacing: LooprSpacing.xs) { minus(fill: true); plus(fill: true) }
                    }
                } else {
                    HStack(spacing: LooprSpacing.none) { minus(fill: false); valueView; plus(fill: false) }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }

    private var valueView: some View {
        Text(Self.valueText(value, locale: locale, format: format))
            .looprTypography(.metric)
            .monospacedDigit()
            .foregroundStyle(Color.loopr(.ink))
            .contentTransition(.numericText())
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityValue(Self.spokenValue(value, spokenUnit: spokenUnit, locale: locale, format: format))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: press(1)
                case .decrement: press(-1)
                @unknown default: break
                }
            }
    }

    private func minus(fill: Bool) -> some View {
        glassButton(symbol: "minus", fill: fill, enabled: canDecrement,
                    spoken: "Decrease \(label.lowercased())", identifier: decrementIdentifier) { press(-1) }
    }

    private func plus(fill: Bool) -> some View {
        glassButton(symbol: "plus", fill: fill, enabled: canIncrement,
                    spoken: "Increase \(label.lowercased())", identifier: incrementIdentifier) { press(1) }
    }

    private func glassButton(symbol: String, fill: Bool, enabled: Bool, spoken: String,
                             identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .looprTypography(.title)
                .foregroundStyle(Color.loopr(.ink))
                .frame(width: LooprSpacing.hero, height: LooprSpacing.hero)
                .glassEffect(.regular.interactive(), in: Circle())
                .frame(maxWidth: fill ? .infinity : LooprSpacing.headerControlDiameter,
                       minHeight: Self.minimumTargetHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityLabel(spoken)
        .accessibilityIdentifier(identifier)
    }
}

private struct LooprValueStepperPreview: View {
    @State private var kg = 80.0
    @State private var reps = 8.0
    @State private var rest = 150.0
    var body: some View {
        HStack(spacing: LooprSpacing.cardStack) {
            LooprValueStepper("kg", label: "Weight", spokenUnit: "kilograms", value: $kg, step: 2.5, range: 0...500,
                              identifier: "preview-kg", decrementIdentifier: "preview-kg-minus", incrementIdentifier: "preview-kg-plus")
            LooprValueStepper("rest", label: "Rest", spokenUnit: "seconds", value: $rest, step: 15, range: 0...600,
                              identifier: "preview-rest", decrementIdentifier: "preview-rest-minus", incrementIdentifier: "preview-rest-plus",
                              format: .clock)
            LooprValueStepper("reps", label: "Reps", spokenUnit: "reps", value: $reps, step: 1, range: 0...100,
                              identifier: "preview-reps", decrementIdentifier: "preview-reps-minus", incrementIdentifier: "preview-reps-plus")
        }
        .padding(LooprSpacing.screenGutter)
        .background(Color.loopr(.background))
    }
}

#Preview("Value steppers") { LooprValueStepperPreview() }
