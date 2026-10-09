import Foundation
import DesignSystem
import ProfileKit

/// What one Today ring shows: the number it counts to, the scale one lap
/// stands for, and how VoiceOver should describe the fill.
///
/// Every value comes from the summary; nothing here derives a metric. When the
/// summary has no honest scale for a reading, `scale` is nil and the ring
/// shows an empty track around the number.
struct TodayRingReading: Equatable, Sendable {
    /// The reading in ring units: minutes for sleep, points otherwise.
    let value: Double?
    let scale: LooprRingScale?
    let format: LooprRingNumberFormat?
    /// Finishes the spoken sentence "N percent of …", or nil when the value
    /// already is a percentage and saying it twice would only add noise.
    let scaleDescription: String?

    var fraction: Double? { scale?.fraction(for: value) }
    var percent: Int? { scale?.percent(for: value) }

    /// The clause VoiceOver appends to the metric's own summary.
    var accessibilityFill: String? {
        guard let percent, let scaleDescription else { return nil }
        return "\(percent) percent of \(scaleDescription)"
    }

    static let empty = TodayRingReading(value: nil, scale: nil, format: nil, scaleDescription: nil)

    static func reading(for id: TodayMetricID, metric: TodayMetricValue?, summary: TodaySummary) -> TodayRingReading {
        guard let metric, let value = metric.numericValue, value.isFinite,
              metric.state != .absent, metric.state != .noRecords else { return .empty }
        switch id {
        case .sleep:
            guard metric.numericUnit == .minutes else { return .empty }
            let reference = sleepReference(in: summary)
            return TodayRingReading(
                value: value,
                scale: LooprRingScale(fullValue: reference.minutes),
                format: .hoursMinutes,
                scaleDescription: reference.description
            )
        case .recovery, .readiness:
            guard metric.numericUnit == .scorePoints else { return .empty }
            // Recovery is already a percentage; the ring is its own scale.
            return TodayRingReading(value: value, scale: LooprRingScale(fullValue: 100), format: .integer, scaleDescription: nil)
        case .strain:
            guard metric.numericUnit == .strainScore else { return .empty }
            return TodayRingReading(value: value, scale: LooprRingScale(fullValue: 21), format: .oneDecimal,
                                    scaleDescription: "the 21 point strain scale")
        case .stress:
            // The canonical stress reading is a 0 to 100 score. A value with
            // any other unit is not something this ring knows how to scale.
            guard metric.numericUnit == .scorePoints else { return .empty }
            return TodayRingReading(value: value, scale: LooprRingScale(fullValue: 100), format: .integer,
                                    scaleDescription: "the 100 point stress scale")
        case .heart, .hrv, .restingHeartRate, .calories, .steps, .wearQuality:
            return TodayRingReading(value: value, scale: nil, format: nil, scaleDescription: nil)
        }
    }

    /// The configured need, with the same eight-hour default as Sleep.
    static func sleepReference(in summary: TodaySummary) -> (minutes: Double, description: String) {
        if let goal = summary.goals.first(where: { $0.id == "sleep" }),
           let target = goal.target.flatMap(Double.init), target.isFinite, target > 0 {
            let unit = goal.unit.lowercased()
            let minutes: Double? = switch unit {
            case "h", "hour", "hours": target * 60
            case "min", "minute", "minutes": target
            default: nil
            }
            if let minutes {
                return (minutes, "your sleep need of \(hoursText(minutes)) hours")
            }
        }
        return (SleepNeed.defaultMinutes, "your sleep need of 8 hours")
    }

    private static func hoursText(_ minutes: Double) -> String {
        let hours = (minutes / 60 * 10).rounded() / 10
        return hours.rounded() == hours ? String(Int(hours)) : String(format: "%.1f", hours)
    }
}
