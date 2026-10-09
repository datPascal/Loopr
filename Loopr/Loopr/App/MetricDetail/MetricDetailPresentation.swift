import DesignSystem
import Foundation

/// Whether Loopr produces a metric from band data today. The detail page uses
/// it only for its empty state; when history exists it is always shown.
nonisolated enum MetricAvailability: Sendable {
    /// Derived from band data every day.
    case calculated
    /// Not derived from the band; only Apple Health can supply it.
    case appleHealthOnly
    /// Supplied by an import, never calculated from band data.
    case importedOnly
    /// Not derived yet, from any source Loopr reads.
    case notYetCalculated
}

/// How a metric's values are shown. Units match the history layer's storage
/// units: minutes for sleep durations, percent for shares, bpm, ms, and so on.
nonisolated struct MetricPresentation: Sendable {
    let title: String
    /// Unit printed next to a value. Empty for unitless scores.
    let unit: String
    /// Unit spoken by VoiceOver.
    let spokenUnit: String
    let accent: LooprColorToken
    let chartKind: LooprChartKind
    let format: MetricValueFormat
    let availability: MetricAvailability
    /// The section eyebrow above the hero value, e.g. "LAST NIGHT".
    let period: String
    /// Replaces the generic empty-state text for a calculated metric that
    /// needs more than one night before its first value.
    var emptyDetail: String? = nil

    func value(_ number: Double) -> String { format.string(number) }

    /// The value with its unit: "54 bpm", "46%", "11.2/21", "7h 12m".
    func valueWithUnit(_ number: Double) -> String {
        attach(format.string(number))
    }

    func attach(_ text: String) -> String {
        if unit.isEmpty { return text }
        if unit == "%" || unit.hasPrefix("/") || unit == "°C" { return text + unit }
        return "\(text) \(unit)"
    }

    /// Gridline step for the chart's value axis, where a round step reads better
    /// than the automatic one.
    var yAxisStep: Double? {
        switch format {
        case .duration: 60
        default: nil
        }
    }
    func axisValue(_ number: Double) -> String { format.axisString(number) }
}

nonisolated enum MetricValueFormat: Sendable {
    case whole
    case oneDecimal
    case signedOneDecimal
    case grouped
    case duration

    func string(_ value: Double) -> String {
        guard value.isFinite else { return "-" }
        switch self {
        case .whole:
            return String(Int(value.rounded()))
        case .oneDecimal:
            return String(format: "%.1f", value)
        case .signedOneDecimal:
            return LooprSignalFormatting.temperatureChange(value) ?? "-"
        case .grouped:
            // "8,240" on every device, like the tabs: a German-locale "8.240"
            // next to "14.6" read as eight point two.
            return LooprUnitFormatter.number(value.rounded(), digits: 0) ?? "-"
        case .duration:
            // "7 h 42 m", "8 h", "24 min" (tabs spec principle 10).
            return LooprUnitFormatter.duration(minutes: max(0, value)) ?? "-"
        }
    }

    func axisString(_ value: Double) -> String {
        switch self {
        case .duration:
            let hours = value / 60
            return hours.rounded() == hours ? "\(Int(hours)) h" : String(format: "%.1f h", hours)
        case .oneDecimal where value.rounded() == value:
            return String(Int(value))
        case .grouped where abs(value) >= 1000:
            let thousands = value / 1000
            return thousands.rounded() == thousands ? "\(Int(thousands))k" : String(format: "%.1fk", thousands)
        default:
            return string(value)
        }
    }

    /// A difference between two values, always signed, for trend lines.
    func delta(_ value: Double) -> String {
        switch self {
        case .duration:
            let minutes = Int(value.rounded())
            guard minutes != 0 else { return "0 min" }
            return (minutes > 0 ? "+" : "-") + MetricValueFormat.duration.string(Double(abs(minutes)))
        case .whole, .grouped:
            let rounded = Int(value.rounded())
            let body = MetricValueFormat.grouped.string(Double(abs(rounded)))
            return rounded > 0 ? "+" + body : rounded < 0 ? "-" + body : "0"
        case .oneDecimal, .signedOneDecimal:
            return MetricValueFormat.signedOneDecimal.string(value)
        }
    }
}

nonisolated extension MetricKey {
    /// Maps a `LooprMetricLinkID` string from a feature package back to a key.
    init?(linkID: String) {
        self.init(rawValue: linkID)
    }

    var linkID: String { rawValue }

    var presentation: MetricPresentation {
        switch self {
        case .restingHeartRate:
            .init(title: "Resting heart rate", unit: "bpm", spokenUnit: "beats per minute", accent: .heart, chartKind: .line, format: .whole, availability: .calculated, period: "LAST NIGHT")
        case .rmssd:
            // "HRV" everywhere in Loopr; the page names RMSSD in its definition.
            .init(title: "HRV", unit: "ms", spokenUnit: "milliseconds", accent: .heart, chartKind: .line, format: .whole, availability: .calculated, period: "LAST NIGHT")
        case .sdnn:
            .init(title: "SDNN", unit: "ms", spokenUnit: "milliseconds", accent: .heart, chartKind: .line, format: .whole, availability: .calculated, period: "LAST NIGHT")
        case .pNN50:
            .init(title: "pNN50", unit: "%", spokenUnit: "percent", accent: .heart, chartKind: .line, format: .whole, availability: .calculated, period: "LAST NIGHT")
        case .respiratoryRate:
            .init(title: "Respiratory rate", unit: "br/min", spokenUnit: "breaths per minute", accent: .heart, chartKind: .line, format: .oneDecimal, availability: .calculated, period: "LAST NIGHT")
        case .sleepingHeartRate:
            .init(title: "Sleeping heart rate", unit: "bpm", spokenUnit: "beats per minute", accent: .heart, chartKind: .rangeBars, format: .whole, availability: .calculated, period: "LAST NIGHT",
                  emptyDetail: "Sleeping heart rate needs a main sleep with at least 5 minutes of valid heart rate readings. It appears after that night syncs.")
        case .heartRateDip:
            .init(title: "Heart rate dip", unit: "%", spokenUnit: "percent", accent: .heart, chartKind: .line, format: .whole, availability: .calculated, period: "LAST NIGHT",
                  emptyDetail: "Heart rate dip needs at least 5 minutes of valid heart rate during your main sleep and 5 while awake. It appears after both sync.")
        case .oxygenSaturation:
            .init(title: "Blood oxygen", unit: "%", spokenUnit: "percent", accent: .brand, chartKind: .line, format: .oneDecimal, availability: .importedOnly, period: "LAST NIGHT")
        case .skinTemperatureDeviation:
            .init(title: "Skin temperature", unit: "°C", spokenUnit: "degrees Celsius from your usual", accent: .heart, chartKind: .line, format: .signedOneDecimal, availability: .calculated, period: "LAST NIGHT",
                  emptyDetail: "Your change from usual appears after 4 nights with a settled reading. Sleep with your band on and sync in the morning.")
        case .recovery:
            .init(title: "Recovery", unit: "", spokenUnit: "out of 100", accent: .recovery, chartKind: .line, format: .whole, availability: .calculated, period: "THIS MORNING",
                  emptyDetail: "Recovery needs at least two overnight heart readings with enough history. It can start after 4 nights with the band on.")
        case .strain:
            .init(title: "Strain", unit: "/21", spokenUnit: "out of 21", accent: .strain, chartKind: .bars, format: .oneDecimal, availability: .calculated, period: "TODAY",
                  emptyDetail: "Strain needs your birth year in Profile and a resting heart rate from a night with the band on. With both in place, it appears after your next sync.")
        case .stress:
            .init(title: "Stress", unit: "/100", spokenUnit: "out of 100", accent: .stress, chartKind: .line, format: .whole, availability: .calculated, period: "LAST NIGHT")
        case .sleepDuration:
            .init(title: "Sleep duration", unit: "", spokenUnit: "", accent: .sleep, chartKind: .bars, format: .duration, availability: .calculated, period: "LAST NIGHT")
        case .sleepEfficiency:
            .init(title: "Sleep efficiency", unit: "%", spokenUnit: "percent", accent: .sleep, chartKind: .line, format: .whole, availability: .calculated, period: "LAST NIGHT")
        case .deepSleep:
            .init(title: "Deep sleep", unit: "", spokenUnit: "", accent: .sleep, chartKind: .bars, format: .duration, availability: .calculated, period: "LAST NIGHT")
        case .remSleep:
            .init(title: "REM sleep", unit: "", spokenUnit: "", accent: .sleep, chartKind: .bars, format: .duration, availability: .calculated, period: "LAST NIGHT")
        case .sleepConsistency:
            .init(title: "Sleep regularity", unit: "/100", spokenUnit: "out of 100", accent: .sleep, chartKind: .line, format: .whole, availability: .calculated, period: "LAST NIGHT")
        case .vo2Max:
            .init(title: "VO2 max", unit: "ml/kg/min", spokenUnit: "millilitres per kilogram per minute", accent: .brand, chartKind: .line, format: .oneDecimal, availability: .appleHealthOnly, period: "LATEST",
                  emptyDetail: "Loopr does not estimate VO2 max from band data. You can show readings from Apple Health if you allow access.")
        case .maxHeartRate:
            .init(title: "Max heart rate", unit: "bpm", spokenUnit: "beats per minute", accent: .heart, chartKind: .line, format: .whole, availability: .calculated, period: "TODAY",
                  emptyDetail: "Your band has not synced valid heart rate readings for this day. The recorded peak appears after it syncs.")
        case .activeEnergy:
            .init(title: "Active energy", unit: "kcal", spokenUnit: "kilocalories", accent: .strain, chartKind: .bars, format: .grouped, availability: .calculated, period: "TODAY",
                  emptyDetail: "Active energy needs your birth year, height and weight in Profile. With those set, it appears after a day with the band on.")
        case .steps:
            .init(title: "Estimated steps", unit: "steps", spokenUnit: "steps", accent: .brand, chartKind: .bars, format: .grouped, availability: .calculated, period: "TODAY",
                  emptyDetail: "Loopr first learns how you move, which takes 5 days with at least an hour of wear each. Step estimates start after that.")
        }
    }
}
