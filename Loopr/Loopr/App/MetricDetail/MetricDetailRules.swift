import DesignSystem
import Foundation

/// The small-data and day rules of the metric detail page, kept pure so each
/// threshold is tested on its own.
nonisolated enum MetricDetailRules {
    /// Highest, lowest and day-to-day change mean little over fewer measured
    /// days than this, so the page hides them until then.
    static let fullStatisticsMinimumDays = 7

    static func showsFullStatistics(measuredDays: Int) -> Bool {
        measuredDays >= fullStatisticsMinimumDays
    }

    /// The narrowest the chart's value axis gets, in the metric's stored unit.
    /// Chosen so a normal night-to-night wobble reads as a wobble: about the
    /// width of a typical usual range for each metric.
    static func scale(for key: MetricKey) -> LooprChartScaleHint {
        switch key {
        case .restingHeartRate, .sleepingHeartRate: LooprChartScaleHint(minimumSpan: 10, bounds: 0...250)
        case .maxHeartRate: LooprChartScaleHint(minimumSpan: 20, bounds: 0...250)
        case .rmssd, .sdnn: LooprChartScaleHint(minimumSpan: 20, bounds: 0...400)
        case .pNN50: LooprChartScaleHint(minimumSpan: 20, bounds: 0...100)
        case .respiratoryRate: LooprChartScaleHint(minimumSpan: 3, bounds: 0...60)
        case .heartRateDip: LooprChartScaleHint(minimumSpan: 10)
        case .oxygenSaturation: LooprChartScaleHint(minimumSpan: 5, bounds: 0...100)
        case .skinTemperatureDeviation: LooprChartScaleHint(minimumSpan: 1, includeZero: true)
        // A score's whole scale is the context: always 0 to 100, 0 to 21.
        case .recovery: LooprChartScaleHint(minimumSpan: 100, bounds: 0...100)
        case .strain: LooprChartScaleHint(minimumSpan: 21, bounds: 0...21)
        case .stress: LooprChartScaleHint(minimumSpan: 40, bounds: 0...100)
        case .sleepConsistency: LooprChartScaleHint(minimumSpan: 30, bounds: 0...100)
        case .sleepEfficiency: LooprChartScaleHint(minimumSpan: 20, bounds: 0...100)
        case .sleepDuration: LooprChartScaleHint(minimumSpan: 480)
        case .deepSleep, .remSleep: LooprChartScaleHint(minimumSpan: 120)
        case .vo2Max: LooprChartScaleHint(minimumSpan: 8, bounds: 0...100)
        case .activeEnergy: LooprChartScaleHint(minimumSpan: 500)
        case .steps: LooprChartScaleHint(minimumSpan: 5_000)
        }
    }

    /// Nightly metrics count nights; the rest count days.
    static func countNoun(for key: MetricKey) -> LooprCountNoun {
        isNightly(key) ? .nights : .days
    }

    static func isNightly(_ key: MetricKey) -> Bool {
        switch key {
        case .restingHeartRate, .rmssd, .sdnn, .pNN50, .respiratoryRate, .sleepingHeartRate, .heartRateDip,
             .oxygenSaturation, .skinTemperatureDeviation, .stress, .sleepDuration, .sleepEfficiency,
             .deepSleep, .remSleep, .sleepConsistency:
            true
        case .recovery, .strain, .vo2Max, .maxHeartRate, .activeEnergy, .steps:
            false
        }
    }

    /// Which way is good, for "vs usual" colour (tabs spec principle 6). Nil
    /// for metrics with no good direction: they stay grey.
    static func higherIsBetter(_ key: MetricKey) -> Bool? {
        switch key {
        case .rmssd, .sdnn, .pNN50, .recovery, .sleepDuration, .sleepEfficiency, .deepSleep, .remSleep,
             .sleepConsistency, .vo2Max, .steps:
            true
        case .restingHeartRate, .sleepingHeartRate, .stress:
            false
        case .respiratoryRate, .oxygenSaturation, .skinTemperatureDeviation, .strain, .maxHeartRate, .activeEnergy, .heartRateDip:
            nil
        }
    }

    static func deltaFormat(_ key: MetricKey) -> LooprDeltaFormat {
        switch key.presentation.format {
        case .duration: .duration
        case .oneDecimal, .signedOneDecimal: .number(digits: 1)
        case .whole, .grouped: .number(digits: 0)
        }
    }

    /// The unit a "vs usual" delta prints: none for scores out of a total.
    static func deltaUnit(_ key: MetricKey) -> String {
        let unit = key.presentation.unit
        return unit.hasPrefix("/") ? "" : unit
    }

    /// Readings counted towards a usual range while Loopr is still learning
    /// it: the days in the 30-day window up to and including the latest
    /// reading. The band itself leaves the latest day out, but a count that
    /// says "1 of 14" under a chart with two nights reads as a mistake.
    static func learningCount(_ points: [LooprChartPoint], latest: Date, calendar: Calendar = .current) -> Int {
        let next = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: latest)) ?? latest
        return MetricTrendNarrative.daysTowardsBaseline(points, today: next, calendar: calendar)
    }

    /// Ranges the page offers for this history, seen from `anchor`.
    static func availableRanges(_ points: [LooprChartPoint], anchor: Date, calendar: Calendar = .current) -> Set<LooprChartRange> {
        LooprChartRange.unlocked(historyDays: LooprChartRange.historyDays(points, endingOn: anchor, calendar: calendar))
    }
}

/// The day a metric page is about: the day the tabs show, which is today or
/// the day the person stepped back to. Everything on the page (hero, chart,
/// statistics, links) is seen from this day.
nonisolated struct MetricDetailAnchor: Hashable, Sendable {
    /// Start of the day on screen.
    let day: Date
    /// Start of the current day.
    let today: Date
    let calendar: Calendar

    init(day: Date, today: Date, calendar: Calendar = .current) {
        self.calendar = calendar
        let todayStart = calendar.startOfDay(for: today)
        self.today = todayStart
        self.day = min(calendar.startOfDay(for: day), todayStart)
    }

    /// The tabs' shared day, or today outside the tab shell.
    init(selectedDay: LooprDay?, today: LooprDay?, now: Date = Date(), calendar: Calendar = .current) {
        let todayDate = today?.start(in: calendar) ?? now
        let dayDate = selectedDay?.start(in: calendar) ?? todayDate
        self.init(day: dayDate, today: todayDate, calendar: calendar)
    }

    var isToday: Bool { day == today }

    /// The last moment of the anchor day, for history reads that end on it.
    var endOfDay: Date {
        (calendar.date(byAdding: .day, value: 1, to: day) ?? day).addingTimeInterval(-1)
    }

    private func looprDay(_ date: Date) -> LooprDay { LooprDay(date: date, calendar: calendar) }

    /// "Tue 22 Sep", with weekday.
    func dateText(_ date: Date) -> String {
        LooprDayLabel.date(for: looprDay(date), today: looprDay(today), calendar: calendar)
    }

    /// The latest reading on or before the anchor day.
    func latest(in points: [LooprChartPoint]) -> LooprChartPoint? {
        points.last { calendar.startOfDay(for: $0.date) <= day }
    }

    /// The eyebrow over the hero value.
    ///
    /// - A reading from the anchor day: the metric's own period today
    ///   ("LAST NIGHT"), otherwise the day ("YESTERDAY · WED 23 SEP", or the
    ///   night "TUE 22 → WED 23 SEP" for nightly metrics).
    /// - An older reading: "LATEST · MON 21 SEP".
    func heroEyebrow(for valueDate: Date, key: MetricKey) -> String {
        let valueDay = calendar.startOfDay(for: valueDate)
        guard valueDay == day else {
            return "LATEST · " + dateText(valueDay).uppercased()
        }
        if isToday { return key.presentation.period }
        let today = looprDay(today)
        let shown = looprDay(day)
        if MetricDetailRules.isNightly(key) {
            return LooprDayLabel.nightRange(for: shown, today: today, calendar: calendar).uppercased()
        }
        let date = dateText(day).uppercased()
        return today.adding(days: -1, calendar: calendar) == shown ? "YESTERDAY · " + date : date
    }

    /// A quiet line when the value on screen is older than the anchor day.
    func missingCaption(for valueDate: Date) -> String? {
        guard calendar.startOfDay(for: valueDate) < day else { return nil }
        return isToday ? "No reading for today yet." : "No reading on \(dateText(day))."
    }
}
