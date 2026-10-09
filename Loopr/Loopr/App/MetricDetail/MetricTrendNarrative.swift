import DesignSystem
import Foundation

/// Turns a metric's history into the plain sentences on its detail page.
/// Pure and deterministic so the wording thresholds can be tested.
nonisolated enum MetricTrendNarrative {
    /// Measured days a week needs before Loopr calls a direction
    /// (Plews et al. 2014 used at least 3 valid days per week).
    static let minimumWeekDays = 3
    /// A 7-day average has to move by at least this share of the usual
    /// spread before it counts as a change: the "smallest worthwhile change"
    /// of 0.5 x the between-day standard deviation (Buchheit 2014).
    static let smallestWorthwhileChange = 0.5

    enum Direction: String, Equatable, Sendable {
        case higher
        case lower
        case steady
        case notEnoughData
    }

    struct Summary: Equatable, Sendable {
        let direction: Direction
        /// Short label for the direction row.
        let directionLabel: String
        /// One or two sentences that explain the comparison.
        let headline: String
        let weekAverage: Double?
        let weekMeasuredDays: Int
        let baseline: LooprBaselineBand?
        let delta: Double?
        /// "Changes by about 4 ms from one day to the next", or nil.
        let variability: String?
        /// Mean absolute change between consecutive measured days in the range.
        let typicalDailyChange: Double?
        let highest: LooprChartPoint?
        let lowest: LooprChartPoint?
        let rangeMeasuredDays: Int
    }

    struct HeroStatus: Equatable, Sendable {
        let text: String
        let position: LooprBaselineBand.Position?
    }

    static func chartPoints(_ history: [MetricHistoryPoint]) -> [LooprChartPoint] {
        history.map { LooprChartPoint(date: $0.day, value: $0.value, low: $0.low, high: $0.high) }
    }

    /// The usual range used everywhere on the page: the 30 days before
    /// `today`, excluding today.
    static func baseline(_ points: [LooprChartPoint], today: Date, calendar: Calendar = .current) -> LooprBaselineBand? {
        LooprBaselineBand.trailing(points, before: today, calendar: calendar)
    }

    static func daysTowardsBaseline(_ points: [LooprChartPoint], today: Date, calendar: Calendar = .current) -> Int {
        let end = calendar.startOfDay(for: today)
        guard let start = calendar.date(byAdding: .day, value: -LooprBaselineBand.windowDays, to: end) else { return 0 }
        return Set(points.filter { $0.date >= start && $0.date < end && $0.value.isFinite }
            .map { calendar.startOfDay(for: $0.date) }).count
    }

    static func summary(
        points: [LooprChartPoint],
        key: MetricKey,
        range: LooprChartRange,
        today: Date,
        calendar: Calendar = .current
    ) -> Summary {
        let presentation = key.presentation
        let format = presentation.format
        let unit = presentation.unit
        func valueText(_ value: Double) -> String {
            unit.hasPrefix("/") ? format.string(value) : presentation.valueWithUnit(value)
        }
        func deltaText(_ value: Double) -> String {
            let magnitude = format == .signedOneDecimal
                ? MetricValueFormat.oneDecimal.string(abs(value))
                : format.string(abs(value))
            return unit.hasPrefix("/") ? magnitude : presentation.attach(magnitude)
        }

        let week = LooprSeriesStatistics.compute(points, window: LooprChartWindow(dayCount: 7), endingOn: today, calendar: calendar)
        let inRange = LooprSeriesStatistics.compute(points, window: range.window, endingOn: today, calendar: calendar)
        let band = baseline(points, today: today, calendar: calendar)
        let weekDays = week?.measuredDays ?? 0

        let variability: String? = inRange?.typicalDailyChange.map {
            "Changes by about \(deltaText($0)) from one day to the next"
        }

        func make(_ direction: Direction, label: String, headline: String, delta: Double?) -> Summary {
            Summary(
                direction: direction,
                directionLabel: label,
                headline: headline,
                weekAverage: week?.mean,
                weekMeasuredDays: weekDays,
                baseline: band,
                delta: delta,
                variability: variability,
                typicalDailyChange: inRange?.typicalDailyChange,
                highest: inRange?.highest,
                lowest: inRange?.lowest,
                rangeMeasuredDays: inRange?.measuredDays ?? 0
            )
        }

        guard let band else {
            let have = daysTowardsBaseline(points, today: today, calendar: calendar)
            let needed = LooprBaselineBand.minimumDays
            return make(
                .notEnoughData,
                label: "Learning your usual range",
                headline: "Loopr needs \(needed) measured days in the last \(LooprBaselineBand.windowDays) to learn your usual range. It has \(have) so far.",
                delta: nil
            )
        }
        guard let week, weekDays >= minimumWeekDays else {
            return make(
                .notEnoughData,
                label: "Not enough days this week",
                headline: "\(weekDays == 1 ? "Only 1 day" : "Only \(weekDays) days") measured in the last 7. Loopr needs \(minimumWeekDays) to call a direction.",
                delta: nil
            )
        }

        let delta = week.mean - band.center
        let threshold = smallestWorthwhileChange * band.halfWidth
        let usual = valueText(band.center)
        let average = valueText(week.mean)
        if abs(delta) < threshold {
            return make(
                .steady,
                label: "About the same as usual",
                headline: "Your 7-day average is \(average), in line with your usual \(usual).",
                delta: delta
            )
        }
        let higher = delta > 0
        return make(
            higher ? .higher : .lower,
            label: higher ? "Higher than usual" : "Lower than usual",
            headline: "Your 7-day average is \(average), \(deltaText(delta)) \(higher ? "above" : "below") your usual \(usual).",
            delta: delta
        )
    }

    static func heroStatus(points: [LooprChartPoint], latest: LooprChartPoint?, today: Date, calendar: Calendar = .current) -> HeroStatus? {
        guard let latest else { return nil }
        guard let band = baseline(points, today: latest.date, calendar: calendar) else {
            let have = daysTowardsBaseline(points, today: latest.date, calendar: calendar)
            return HeroStatus(
                text: "Learning your usual range. \(have) of \(LooprBaselineBand.minimumDays) days so far.",
                position: nil
            )
        }
        let position = band.position(of: latest.value)
        let text = switch position {
        case .within: "Within your usual range"
        case .above: "Above your usual range"
        case .below: "Below your usual range"
        }
        return HeroStatus(text: text, position: position)
    }
}
