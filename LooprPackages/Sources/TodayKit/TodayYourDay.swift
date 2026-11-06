import Foundation
import DesignSystem

/// The Sleep and Strain rows of the Your day card. Today derives both from its own summary. Food, Train
/// and Journal come from the app as `TodayYourDayRow`.
public struct TodayYourDayMetric: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable { case sleep, strain }

    public let kind: Kind
    public let title: String
    /// "94" for sleep as a share of the need, "6.4" for strain. Nil with no reading.
    public let value: String?
    /// "%" for sleep. Nil for strain.
    public let unit: String?
    /// "7 h 42 m of 8 h 10 m needed", "Suggested 14 to 18"
    public let caption: String?
    /// Where the reading sits against its usual range, for the range bar.
    public let range: Range?

    public struct Range: Equatable, Sendable {
        public let value: Double
        public let usual: ClosedRange<Double>
        public let domain: ClosedRange<Double>?
    }

    public var id: String { kind.rawValue }
    public var identifier: String { "today-your-day-\(kind.rawValue)" }
}

enum TodayYourDayRules {
    static func metrics(summary: TodaySummary, values: TodayValues, context: TodayDayContext?) -> [TodayYourDayMetric] {
        [sleep(summary: summary, values: values), strain(values: values, context: context)]
    }

    static func sleep(summary: TodaySummary, values: TodayValues) -> TodayYourDayMetric {
        guard let minutes = values.value(.sleep), minutes.isFinite, minutes > 0 else {
            return TodayYourDayMetric(kind: .sleep, title: "Sleep", value: nil, unit: nil, caption: nil, range: nil)
        }
        let night = LooprUnitFormatter.duration(minutes: minutes)
        let usual = values.usual(.sleep).flatMap { band in
            TodayYourDayMetric.Range(value: minutes, usual: band.lower...band.upper, domain: nil)
        }
        guard let need = summary.sleepNeedMinutes, need > 0 else {
            return TodayYourDayMetric(kind: .sleep, title: "Sleep", value: night, unit: nil, caption: nil, range: usual)
        }
        let share = Int((minutes / need * 100).rounded())
        let needText = LooprUnitFormatter.duration(minutes: need) ?? ""
        return TodayYourDayMetric(kind: .sleep, title: "Sleep", value: String(share), unit: "%",
            caption: "\(night ?? "") of \(needText) needed", range: usual)
    }

    static func strain(values: TodayValues, context: TodayDayContext?) -> TodayYourDayMetric {
        guard let strain = values.value(.strain), strain.isFinite else {
            return TodayYourDayMetric(kind: .strain, title: "Strain", value: nil, unit: nil, caption: nil, range: nil)
        }
        let suggested = context?.suggestedStrainRange
        let caption = suggested.map { "Suggested \(Int($0.lowerBound.rounded())) to \(Int($0.upperBound.rounded()))" }
        let range = suggested.map { TodayYourDayMetric.Range(value: strain, usual: $0, domain: 0...21) }
        return TodayYourDayMetric(kind: .strain, title: "Strain", value: String(format: "%.1f", strain), unit: nil,
                                  caption: caption, range: range)
    }
}
