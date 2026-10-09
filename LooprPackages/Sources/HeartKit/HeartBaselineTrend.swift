import Foundation
import DesignSystem

// The resting heart rate and HRV cards on the Heart tab, in the style
// Garmin's HRV status and HRV4Training made familiar: the night's value, how
// it sits against your usual range, and 30 days of nights with the usual band
// and a 7-day average line.

/// The two nightly metrics the Heart tab leads with.
public enum HeartBaselineMetric: String, CaseIterable, Sendable {
    case restingHeartRate
    case hrv

    public var title: String {
        switch self {
        case .restingHeartRate: "Resting heart rate"
        case .hrv: "HRV"
        }
    }

    public var unit: String {
        switch self {
        case .restingHeartRate: "bpm"
        case .hrv: "ms"
        }
    }

    /// Lower resting heart rate and higher HRV are the good directions.
    public var higherIsBetter: Bool {
        switch self {
        case .restingHeartRate: false
        case .hrv: true
        }
    }

    public var linkID: String {
        switch self {
        case .restingHeartRate: LooprMetricLinkID.restingHeartRate
        case .hrv: LooprMetricLinkID.rmssd
        }
    }

    public var heartMetricID: HeartMetricID {
        switch self {
        case .restingHeartRate: .restingHeartRate
        case .hrv: .rmssd
        }
    }

    /// The accessibility identifier. The HRV card keeps the id the RMSSD row
    /// had, so UI tests that open the HRV page from the tab still find it.
    public var identifier: String { "heart-metric-\(heartMetricID.rawValue)" }

    /// The smallest y span the chart draws, so two nights 1 bpm apart do not
    /// fill the card top to bottom.
    public var minimumSpan: Double {
        switch self {
        case .restingHeartRate: 10
        case .hrv: 20
        }
    }
}

public struct HeartBaselineTrend: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        /// No value for the selected night.
        case noReading
        /// A value, but fewer than `needed` earlier nights for a usual range.
        case learning(measured: Int, needed: Int)
        /// A value and a usual range.
        case ready
    }

    /// Days the chart shows, the selected day included.
    public static let windowDays = 30
    /// Days the 7-day average looks back over, the plotted day included.
    public static let averageDays = 7
    /// Nights the 7-day average needs inside its window to be drawn.
    public static let averageMinimum = 3

    public let metric: HeartBaselineMetric
    /// Start of the selected day.
    public let day: Date
    /// Start of the first day on the chart.
    public let windowStart: Date
    /// One point per measured night in the window, oldest first.
    public let points: [LooprChartPoint]
    /// The trailing 7-day average on each day it can be computed.
    public let average: [LooprChartPoint]
    /// The usual range from the 30 nights before the selected one.
    public let band: LooprBaselineBand?
    /// The selected night's value.
    public let value: Double?
    /// Measured nights in the 30 before the selected one.
    public let measuredNights: Int

    public var needed: Int { LooprBaselineBand.minimumDays }
    private var progressNights: Int { min(measuredNights + (value == nil ? 0 : 1), needed) }

    public var state: State {
        guard value != nil else { return .noReading }
        return band == nil ? .learning(measured: progressNights, needed: needed) : .ready
    }

    /// "−3 bpm vs usual", "Usual", or "Learning your usual · 2 of 14 nights".
    public var delta: LooprDelta? {
        LooprDelta.compare(value, usual: band, higherIsBetter: metric.higherIsBetter, unit: metric.unit,
                           learning: (progressNights, needed))
    }

    /// The usual range as text: "Usual 52 to 56 bpm". Nil while learning.
    public var usualText: String? {
        guard let band else { return nil }
        let lower = Int(band.lower.rounded())
        let upper = Int(band.upper.rounded())
        return lower == upper ? "Usual \(lower) \(metric.unit)" : "Usual \(lower) to \(upper) \(metric.unit)"
    }

    public var valueText: String? { value.map { String(Int($0.rounded())) } }

    /// The y range: points, band and average, padded, at least the metric's
    /// minimum span tall.
    public var yDomain: ClosedRange<Double> {
        var values = points.map(\.value) + average.map(\.value)
        if let band { values += [band.lower, band.upper] }
        guard let low = values.min(), let high = values.max() else { return 0...metric.minimumSpan }
        var lower = low
        var upper = high
        let span = upper - lower
        let pad = max(span * 0.15, 1)
        lower -= pad
        upper += pad
        if upper - lower < metric.minimumSpan {
            let middle = (upper + lower) / 2
            lower = middle - metric.minimumSpan / 2
            upper = middle + metric.minimumSpan / 2
        }
        return max(0, lower.rounded(.down))...upper.rounded(.up)
    }

    /// The last day of the window, the selected day's end.
    public var windowEnd: Date { day.addingTimeInterval(86_400) }

    /// The point on `date`'s day, if that night was measured.
    public func point(on date: Date, calendar: Calendar = .current) -> LooprChartPoint? {
        points.first { calendar.isDate($0.date, inSameDayAs: date) }
    }

    /// The 7-day average on `date`'s day.
    public func averagePoint(on date: Date, calendar: Calendar = .current) -> LooprChartPoint? {
        average.first { calendar.isDate($0.date, inSameDayAs: date) }
    }

    /// What VoiceOver reads for the card.
    public var spokenSummary: String {
        var parts = [metric.title]
        if let valueText {
            parts.append("\(valueText) \(LooprUnitFormatter.spokenUnit(metric.unit))")
        } else {
            parts.append("No reading")
        }
        if let delta { parts.append(delta.spokenText) }
        if let usualText { parts.append(usualText) }
        return parts.joined(separator: ", ")
    }

    public init(metric: HeartBaselineMetric, day: Date, windowStart: Date, points: [LooprChartPoint],
                average: [LooprChartPoint], band: LooprBaselineBand?, value: Double?, measuredNights: Int) {
        self.metric = metric
        self.day = day
        self.windowStart = windowStart
        self.points = points
        self.average = average
        self.band = band
        self.value = value
        self.measuredNights = measuredNights
    }

    /// Builds the card from the metric's daily history.
    ///
    /// - Parameters:
    ///   - history: Daily values, any order, any length; more than 60 days
    ///     back is ignored. Several values on one day are averaged.
    ///   - day: Any moment on the selected day.
    ///   - dayValue: The value the tab shows for the selected day. It wins
    ///     over the history's value for that day, so the card and the rest of
    ///     the tab never disagree; history alone is used when it is nil.
    public static func make(
        metric: HeartBaselineMetric,
        history: [LooprChartPoint],
        day: Date,
        dayValue: Double?,
        calendar: Calendar = .current
    ) -> HeartBaselineTrend {
        let dayStart = calendar.startOfDay(for: day)
        let windowStart = calendar.date(byAdding: .day, value: -(windowDays - 1), to: dayStart) ?? dayStart
        let lookback = calendar.date(byAdding: .day, value: -(LooprBaselineBand.windowDays + averageDays), to: dayStart) ?? dayStart

        var daily = dailyMeans(history, calendar: calendar)
            .filter { $0.date >= lookback && $0.date <= dayStart }
        let finiteDayValue = dayValue.flatMap { $0.isFinite ? $0 : nil }
        let value = finiteDayValue ?? daily.first { $0.date == dayStart }?.value
        daily.removeAll { $0.date == dayStart }
        if let value { daily.append(LooprChartPoint(date: dayStart, value: value)) }
        daily.sort { $0.date < $1.date }

        let band = LooprBaselineBand.trailing(daily, before: dayStart, calendar: calendar)
        let bandStart = calendar.date(byAdding: .day, value: -LooprBaselineBand.windowDays, to: dayStart) ?? dayStart
        let measured = daily.filter { $0.date >= bandStart && $0.date < dayStart }.count

        let windowPoints = daily.filter { $0.date >= windowStart }
        let average = windowPoints.compactMap { point -> LooprChartPoint? in
            guard let from = calendar.date(byAdding: .day, value: -(averageDays - 1), to: point.date) else { return nil }
            let values = daily.filter { $0.date >= from && $0.date <= point.date }.map(\.value)
            guard values.count >= averageMinimum, let mean = LooprStatistics.mean(values) else { return nil }
            return LooprChartPoint(date: point.date, value: mean)
        }

        return HeartBaselineTrend(metric: metric, day: dayStart, windowStart: windowStart, points: windowPoints,
                                  average: average, band: band, value: value, measuredNights: measured)
    }

    /// One point per day at local midnight, the mean of that day's values.
    static func dailyMeans(_ points: [LooprChartPoint], calendar: Calendar) -> [LooprChartPoint] {
        var sums: [Date: (Double, Int)] = [:]
        for point in points where point.value.isFinite {
            let day = calendar.startOfDay(for: point.date)
            let current = sums[day] ?? (0, 0)
            sums[day] = (current.0 + point.value, current.1 + 1)
        }
        return sums.map { LooprChartPoint(date: $0.key, value: $0.value.0 / Double($0.value.1)) }
            .sorted { $0.date < $1.date }
    }
}
