import Foundation
import SwiftUI

/// The measurement system every screen formats against.
///
/// DesignSystem owns it so any kit can read the choice without depending on
/// Settings or Profile, both of which have their own `UnitSystem` enum for
/// storage. Those two map into this one at the composition root.
public enum LooprMeasurementSystem: String, Codable, CaseIterable, Sendable, Hashable {
    case metric
    case imperial
}

private struct LooprMeasurementSystemKey: EnvironmentKey {
    /// Falls back to whatever Settings last applied, so a screen rendered
    /// outside the app root still shows the chosen unit.
    static var defaultValue: LooprMeasurementSystem { DesignSystemRuntime.state().measurementSystem }
}

private struct LooprVoiceOverHintsKey: EnvironmentKey {
    static var defaultValue: Bool { DesignSystemRuntime.state().voiceOverHints }
}

public extension EnvironmentValues {
    /// Read this before rendering any distance, height, weight or pace.
    var looprMeasurementSystem: LooprMeasurementSystem {
        get { self[LooprMeasurementSystemKey.self] }
        set { self[LooprMeasurementSystemKey.self] = newValue }
    }

    /// False when the person has switched the longer VoiceOver hints off.
    var looprVoiceOverHints: Bool {
        get { self[LooprVoiceOverHintsKey.self] }
        set { self[LooprVoiceOverHintsKey.self] = newValue }
    }
}

public extension View {
    /// Applies the person's chosen measurement system to everything below.
    func looprMeasurementSystem(_ system: LooprMeasurementSystem) -> some View {
        environment(\.looprMeasurementSystem, system)
    }

    func looprVoiceOverHints(_ enabled: Bool) -> some View {
        environment(\.looprVoiceOverHints, enabled)
    }

    /// Adds a VoiceOver hint only when the person has left hints switched on.
    func looprAccessibilityHint(_ hint: String) -> some View {
        modifier(LooprAccessibilityHintModifier(hint: hint))
    }
}

private struct LooprAccessibilityHintModifier: ViewModifier {
    let hint: String
    @Environment(\.looprVoiceOverHints) private var hintsEnabled

    func body(content: Content) -> some View {
        if hintsEnabled {
            content.accessibilityHint(Text(hint))
        } else {
            content
        }
    }
}

/// A formatted number and its unit, kept apart so a card can render the unit
/// in its own type style.
public struct LooprMeasurement: Equatable, Sendable {
    public let value: String
    public let unit: String

    public init(value: String, unit: String) {
        self.value = value
        self.unit = unit
    }

    public var combined: String {
        unit.isEmpty ? value : "\(value) \(unit)"
    }
}

/// The one place that converts stored SI values into what a screen shows.
///
/// Everything Loopr stores is metric: metres, centimetres, kilograms. Only
/// rendering and text entry change with the setting.
public enum LooprUnitFormatter {
    static let metresPerMile: Double = 1_609.344
    static let metresPerFoot: Double = 0.3048
    static let poundsPerKilogram: Double = 2.204_622_621_848_78
    static let centimetresPerInch: Double = 2.54

    /// Distance travelled. Metric shows metres below a kilometre, imperial
    /// shows feet below a mile.
    public static func distance(meters: Double, system: LooprMeasurementSystem) -> LooprMeasurement {
        let value = max(0, meters)
        switch system {
        case .metric:
            if value >= 1_000 {
                return LooprMeasurement(value: fraction(value / 1_000, digits: 1), unit: "km")
            }
            return LooprMeasurement(value: Int(value.rounded()).formatted(), unit: "m")
        case .imperial:
            if value >= metresPerMile {
                return LooprMeasurement(value: fraction(value / metresPerMile, digits: 1), unit: "mi")
            }
            return LooprMeasurement(value: Int((value / metresPerFoot).rounded()).formatted(), unit: "ft")
        }
    }

    public static func weight(kilograms: Double, system: LooprMeasurementSystem) -> LooprMeasurement {
        switch system {
        case .metric:
            return LooprMeasurement(value: fraction(kilograms, digits: 1), unit: "kg")
        case .imperial:
            return LooprMeasurement(value: fraction(kilograms * poundsPerKilogram, digits: 1), unit: "lb")
        }
    }

    /// Imperial height reads as feet and inches, the way people say it.
    public static func height(centimeters: Double, system: LooprMeasurementSystem) -> LooprMeasurement {
        switch system {
        case .metric:
            return LooprMeasurement(value: fraction(centimeters, digits: 0), unit: "cm")
        case .imperial:
            let totalInches = (centimeters / centimetresPerInch).rounded()
            let feet = Int(totalInches) / 12
            let inches = Int(totalInches) % 12
            return LooprMeasurement(value: "\(feet)′ \(inches)″", unit: "")
        }
    }

    /// Pace for a run or a walk, formatted as minutes and seconds.
    public static func pace(secondsPerKilometer: Double, system: LooprMeasurementSystem) -> LooprMeasurement {
        guard secondsPerKilometer.isFinite, secondsPerKilometer > 0 else {
            return LooprMeasurement(value: "—", unit: system == .metric ? "/km" : "/mi")
        }
        let seconds = system == .metric
            ? secondsPerKilometer
            : secondsPerKilometer * (metresPerMile / 1_000)
        let total = Int(seconds.rounded())
        let text = String(format: "%d:%02d", total / 60, total % 60)
        return LooprMeasurement(value: text, unit: system == .metric ? "/km" : "/mi")
    }

    // MARK: Durations and signed numbers

    /// The minus sign every signed number uses. A hyphen reads as a dash in a
    /// monospaced font and sits too low next to a plus.
    public static let minusSign = "\u{2212}"

    /// A duration the way people say it: `7 h 42 m`, `8 h`, or `24 min` below
    /// an hour. Rounds to the nearest minute. Nil for a value that is not a
    /// finite, non-negative number, so a caller shows its own absence text
    /// instead of a made-up zero.
    public static func duration(minutes: Double) -> String? {
        guard minutes.isFinite, minutes >= 0 else { return nil }
        return durationText(Int(minutes.rounded()))
    }

    /// A signed change in duration for "vs usual" captions: `+24 min`,
    /// `−1 h 5 m`, or `0 min` when it rounds to nothing.
    public static func signedDuration(minutes: Double) -> String? {
        guard minutes.isFinite else { return nil }
        let whole = Int(minutes.rounded())
        guard whole != 0 else { return "0 min" }
        return (whole > 0 ? "+" : minusSign) + durationText(abs(whole))
    }

    /// The duration spelled out for VoiceOver: "7 hours 42 minutes".
    public static func spokenDuration(minutes: Double) -> String? {
        guard minutes.isFinite else { return nil }
        let whole = abs(Int(minutes.rounded()))
        let hours = whole / 60
        let rest = whole % 60
        var parts: [String] = []
        if hours > 0 { parts.append(hours == 1 ? "1 hour" : "\(hours) hours") }
        if rest > 0 || hours == 0 { parts.append(rest == 1 ? "1 minute" : "\(rest) minutes") }
        return parts.joined(separator: " ")
    }

    private static func durationText(_ totalMinutes: Int) -> String {
        guard totalMinutes >= 60 else { return "\(totalMinutes) min" }
        let hours = totalMinutes / 60
        let rest = totalMinutes % 60
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) m"
    }

    /// A number with its sign: `+6`, `−2.5`, or `0` when it rounds to zero at
    /// `digits` places, so a caption never says "+0".
    public static func signed(_ value: Double, digits: Int = 0) -> String? {
        guard value.isFinite else { return nil }
        let text = displayNumber(abs(value), digits: digits)
        let rounded = (abs(value) * pow(10, Double(digits))).rounded()
        guard rounded != 0 else { return displayNumber(0, digits: digits) }
        return (value > 0 ? "+" : minusSign) + text
    }

    /// A plain number at a fixed precision: `14.6`, `8,240`.
    ///
    /// Metric values across the app are written with a decimal point (the
    /// derivation formats them with `String(format:)`), so the new formatters
    /// do the same. Mixing `14.6` and `-0,2` on one row was a baseline defect.
    public static func number(_ value: Double, digits: Int = 0) -> String? {
        guard value.isFinite else { return nil }
        return displayNumber(value, digits: digits)
    }

    static let displayLocale = Locale(identifier: "en_US")

    private static func displayNumber(_ value: Double, digits: Int) -> String {
        value.formatted(.number.precision(.fractionLength(max(0, digits))).locale(displayLocale))
    }

    // MARK: Units on screen and in speech

    /// Unit words that only restate the row title or name a model quantity.
    /// Principle 10 of the tabs spec drops them after a number.
    static let fillerUnits: Set<String> = [
        "power", "load", "index", "level", "points", "point", "zones", "score", "quality", "tsb"
    ]

    /// The value and unit a metric row shows, cleaned up from what the
    /// derivation hands over:
    ///
    /// - `7:42 hours` becomes `7 h 42 m`, `0.4 hours` becomes `24 min` and
    ///   `82 minutes` becomes `1 h 22 m`, all with no separate unit.
    /// - Filler units (`points`, `index`, `load`, `level`, `power`, `zones`,
    ///   `score`, `quality`) are dropped.
    /// - A unit the title already says (`Estimated steps · 8,240 steps`) is
    ///   dropped.
    ///
    /// Anything it does not recognise passes through unchanged.
    public static func rowValue(_ value: String, unit: String?, title: String) -> LooprMeasurement {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let unit = unit?.trimmingCharacters(in: .whitespacesAndNewlines), !unit.isEmpty else {
            return LooprMeasurement(value: value, unit: "")
        }
        let word = unit.lowercased()
        if ["hours", "hour", "hrs", "hr", "h"].contains(word), let minutes = minutes(fromHours: trimmedValue),
           let text = duration(minutes: minutes) {
            return LooprMeasurement(value: text, unit: "")
        }
        if ["minutes", "minute", "mins", "min"].contains(word), let minutes = number(from: trimmedValue),
           let text = duration(minutes: minutes) {
            return LooprMeasurement(value: text, unit: "")
        }
        if fillerUnits.contains(word) { return LooprMeasurement(value: value, unit: "") }
        let titleWords = Set(title.lowercased().split { !$0.isLetter }.map(String.init))
        if word.allSatisfy(\.isLetter), word.count > 2,
           titleWords.contains(word) || titleWords.contains(word + "s") || (word.hasSuffix("s") && titleWords.contains(String(word.dropLast()))) {
            return LooprMeasurement(value: value, unit: "")
        }
        return LooprMeasurement(value: value, unit: unit)
    }

    /// `7:42` or `7.7` as minutes, or nil.
    static func minutes(fromHours text: String) -> Double? {
        let parts = text.split(separator: ":")
        if parts.count == 2, let hours = Int(parts[0]), let minutes = Int(parts[1]), minutes < 60, hours >= 0 {
            return Double(hours * 60 + minutes)
        }
        return number(from: text).map { $0 * 60 }
    }

    /// The unit as VoiceOver should say it: "ms" is "milliseconds", "/21" is
    /// "out of 21". Unknown units are returned unchanged.
    public static func spokenUnit(_ unit: String) -> String {
        let trimmed = unit.trimmingCharacters(in: .whitespaces)
        switch trimmed.lowercased() {
        case "ms": return "milliseconds"
        case "bpm": return "beats per minute"
        case "br/min", "brpm": return "breaths per minute"
        case "%": return "percent"
        case "kcal": return "kilocalories"
        case "min", "mins": return "minutes"
        case "h", "hrs": return "hours"
        case "km": return "kilometres"
        case "kg": return "kilograms"
        case "°c": return "degrees Celsius"
        default:
            if trimmed.hasPrefix("/"), let scale = Double(trimmed.dropFirst()) {
                return "out of \(Int(scale))"
            }
            return trimmed
        }
    }

    // MARK: Text entry

    /// Label for a height text field, including the unit it expects.
    public static func heightFieldLabel(_ system: LooprMeasurementSystem) -> String {
        system == .metric ? "Height (cm)" : "Height (in)"
    }

    public static func weightFieldLabel(_ system: LooprMeasurementSystem) -> String {
        system == .metric ? "Weight (kg)" : "Weight (lb)"
    }

    public static func heightFieldText(centimeters: Double?, system: LooprMeasurementSystem) -> String {
        guard let centimeters else { return "" }
        switch system {
        case .metric: return String(format: "%.0f", centimeters)
        case .imperial: return String(format: "%.0f", centimeters / centimetresPerInch)
        }
    }

    public static func heightCentimeters(fromField text: String, system: LooprMeasurementSystem) -> Double? {
        guard let entered = number(from: text) else { return nil }
        switch system {
        case .metric: return entered
        case .imperial: return entered * centimetresPerInch
        }
    }

    public static func weightFieldText(kilograms: Double?, system: LooprMeasurementSystem) -> String {
        guard let kilograms else { return "" }
        switch system {
        case .metric: return String(format: "%.1f", kilograms)
        case .imperial: return String(format: "%.1f", kilograms * poundsPerKilogram)
        }
    }

    public static func weightKilograms(fromField text: String, system: LooprMeasurementSystem) -> Double? {
        guard let entered = number(from: text) else { return nil }
        switch system {
        case .metric: return entered
        case .imperial: return entered / poundsPerKilogram
        }
    }

    // MARK: Helpers

    private static func number(from text: String) -> Double? {
        Double(text.replacingOccurrences(of: ",", with: "."))
    }

    private static func fraction(_ value: Double, digits: Int) -> String {
        value.formatted(.number.precision(.fractionLength(digits)))
    }
}
