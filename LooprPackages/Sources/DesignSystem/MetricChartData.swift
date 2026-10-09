import Foundation

// Pure data preparation for the metric charts. Nothing in this file draws;
// every rule the charts depend on (gaps, buckets, baseline band, axis domain)
// lives here so it can be tested without rendering.

/// One day of one metric as the charts receive it. `low` and `high` are the
/// optional within-day extremes a range bar draws.
public struct LooprChartPoint: Identifiable, Hashable, Sendable {
    public var date: Date
    public var value: Double
    public var low: Double?
    public var high: Double?

    public var id: Date { date }

    public init(date: Date, value: Double, low: Double? = nil, high: Double? = nil) {
        self.date = date
        self.value = value
        self.low = low
        self.high = high
    }
}

/// How the chart draws a metric. Lines suit continuous physiology, bars suit
/// daily totals that start from zero, range bars suit a daily low and high.
public enum LooprChartKind: String, CaseIterable, Sendable {
    case line
    case bars
    case rangeBars
}

public enum LooprChartBucket: String, Sendable {
    case day
    case week
}

/// The ranges the trend chart offers. The year view averages each week so a
/// 365-day series stays readable on a phone.
public enum LooprChartRange: String, CaseIterable, Identifiable, Hashable, Sendable {
    case week
    case month
    case quarter
    case year

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .week: "7D"
        case .month: "30D"
        case .quarter: "90D"
        case .year: "1Y"
        }
    }

    public var spokenTitle: String {
        switch self {
        case .week: "7 days"
        case .month: "30 days"
        case .quarter: "90 days"
        case .year: "1 year"
        }
    }

    public var dayCount: Int {
        switch self {
        case .week: 7
        case .month: 30
        case .quarter: 90
        case .year: 365
        }
    }

    public var bucket: LooprChartBucket {
        self == .year ? .week : .day
    }

    public var window: LooprChartWindow {
        LooprChartWindow(dayCount: dayCount, bucket: bucket)
    }
}

public struct LooprChartWindow: Hashable, Sendable {
    public let dayCount: Int
    public let bucket: LooprChartBucket

    public init(dayCount: Int, bucket: LooprChartBucket = .day) {
        self.dayCount = max(1, dayCount)
        self.bucket = bucket
    }
}

/// A point after bucketing. `segment` changes wherever the series skips a
/// bucket, so a line is never drawn across a day with no reading.
public struct LooprPlottedPoint: Identifiable, Hashable, Sendable {
    public let date: Date
    public let value: Double
    public let low: Double?
    public let high: Double?
    public let segment: Int
    /// Number of measured days folded into this point: 1 for daily buckets.
    public let measuredDays: Int

    public var id: Date { date }

    public init(date: Date, value: Double, low: Double?, high: Double?, segment: Int, measuredDays: Int) {
        self.date = date
        self.value = value
        self.low = low
        self.high = high
        self.segment = segment
        self.measuredDays = measuredDays
    }
}

/// The person's usual range: the median of recent days plus or minus a
/// robust spread (1.4826 x the median absolute deviation, which matches one
/// standard deviation for normally distributed data but ignores outliers).
public struct LooprBaselineBand: Hashable, Sendable {
    public enum Position: String, Sendable {
        case below
        case within
        case above
    }

    /// Days of history the band looks back over.
    public static let windowDays = 30
    /// Fewer measured days than this and no band is shown.
    public static let minimumDays = 14
    static let madScale = 1.4826

    public let center: Double
    public let lower: Double
    public let upper: Double
    public let measuredDays: Int

    public init(center: Double, lower: Double, upper: Double, measuredDays: Int) {
        self.center = center
        self.lower = min(lower, upper)
        self.upper = max(lower, upper)
        self.measuredDays = measuredDays
    }

    public var halfWidth: Double { (upper - lower) / 2 }

    public func position(of value: Double) -> Position {
        if value < lower { return .below }
        if value > upper { return .above }
        return .within
    }

    /// Builds the band from raw daily values, or nil when there are too few.
    public static func compute(values: [Double], minimumDays: Int = LooprBaselineBand.minimumDays) -> LooprBaselineBand? {
        let finite = values.filter(\.isFinite)
        guard finite.count >= max(1, minimumDays), let center = LooprStatistics.median(finite) else { return nil }
        let deviations = finite.map { abs($0 - center) }
        let mad = LooprStatistics.median(deviations) ?? 0
        // A perfectly flat history would collapse the band to a line and call
        // every rounding difference "outside your usual range". Keep a floor
        // of 1% of the median so tiny changes stay inside.
        let spread = max(mad * madScale, abs(center) * 0.01)
        return LooprBaselineBand(center: center, lower: center - spread, upper: center + spread, measuredDays: finite.count)
    }

    /// The band for the `windowDays` days before `day`, excluding `day` itself,
    /// so today's reading is compared against the days that came before it.
    public static func trailing(
        _ points: [LooprChartPoint],
        before day: Date,
        windowDays: Int = LooprBaselineBand.windowDays,
        minimumDays: Int = LooprBaselineBand.minimumDays,
        calendar: Calendar = .current
    ) -> LooprBaselineBand? {
        let end = calendar.startOfDay(for: day)
        guard let start = calendar.date(byAdding: .day, value: -windowDays, to: end) else { return nil }
        let values = LooprChartSeries.dailyPoints(points, calendar: calendar)
            .filter { $0.date >= start && $0.date < end }
            .map(\.value)
        return compute(values: values, minimumDays: minimumDays)
    }
}

public enum LooprStatistics {
    public static func median(_ values: [Double]) -> Double? {
        let sorted = values.filter(\.isFinite).sorted()
        guard !sorted.isEmpty else { return nil }
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    public static func mean(_ values: [Double]) -> Double? {
        let finite = values.filter(\.isFinite)
        guard !finite.isEmpty else { return nil }
        return finite.reduce(0, +) / Double(finite.count)
    }
}

/// Plain numbers about one window of daily values, used by trend summaries.
public struct LooprSeriesStatistics: Hashable, Sendable {
    public let measuredDays: Int
    public let windowDays: Int
    public let mean: Double
    public let highest: LooprChartPoint
    public let lowest: LooprChartPoint
    /// Mean absolute change between consecutive measured calendar days. Nil
    /// when no two measured days are adjacent.
    public let typicalDailyChange: Double?

    public static func compute(
        _ points: [LooprChartPoint],
        window: LooprChartWindow,
        endingOn: Date,
        calendar: Calendar = .current
    ) -> LooprSeriesStatistics? {
        let bounds = LooprChartSeries.bounds(window: window, endingOn: endingOn, calendar: calendar)
        let daily = LooprChartSeries.dailyPoints(points, calendar: calendar)
            .filter { $0.date >= bounds.start && $0.date <= bounds.lastDay }
        guard let first = daily.first,
              let mean = LooprStatistics.mean(daily.map(\.value)) else { return nil }
        var highest = first
        var lowest = first
        var changes: [Double] = []
        for (index, point) in daily.enumerated() {
            if point.value > highest.value { highest = point }
            if point.value < lowest.value { lowest = point }
            if index > 0 {
                let previous = daily[index - 1]
                let gap = calendar.dateComponents([.day], from: previous.date, to: point.date).day ?? 0
                if gap == 1 { changes.append(abs(point.value - previous.value)) }
            }
        }
        return LooprSeriesStatistics(
            measuredDays: daily.count,
            windowDays: window.dayCount,
            mean: mean,
            highest: highest,
            lowest: lowest,
            typicalDailyChange: LooprStatistics.mean(changes)
        )
    }
}

/// A chart-ready series for one window.
public struct LooprChartSeries: Hashable, Sendable {
    public let window: LooprChartWindow
    /// Start of the first day in the window.
    public let start: Date
    /// Start of the last day in the window.
    public let lastDay: Date
    public let points: [LooprPlottedPoint]
    public let yDomain: ClosedRange<Double>
    public let baseline: LooprBaselineBand?

    public var latest: LooprPlottedPoint? { points.last }
    public var isEmpty: Bool { points.isEmpty }
    /// Days in the window that carry a reading.
    public var measuredDays: Int { points.reduce(0) { $0 + $1.measuredDays } }

    /// The x domain covers whole days: from the first day's start to the end
    /// of the last day, so a bar on the last day is not clipped.
    public func xDomain(calendar: Calendar = .current) -> ClosedRange<Date> {
        let end = calendar.date(byAdding: .day, value: 1, to: lastDay) ?? lastDay
        return start...end
    }

    /// Snaps a raw chart position to the bucket that contains it.
    public func bucketStart(for date: Date, calendar: Calendar = .current) -> Date {
        Self.bucketStart(for: date, bucket: window.bucket, calendar: calendar)
    }

    /// The plotted point in the bucket containing `date`, or nil for a gap.
    public func point(at date: Date, calendar: Calendar = .current) -> LooprPlottedPoint? {
        let key = bucketStart(for: date, calendar: calendar)
        return points.first { $0.date == key }
    }

    public init(window: LooprChartWindow, start: Date, lastDay: Date, points: [LooprPlottedPoint], yDomain: ClosedRange<Double>, baseline: LooprBaselineBand?) {
        self.window = window
        self.start = start
        self.lastDay = lastDay
        self.points = points
        self.yDomain = yDomain
        self.baseline = baseline
    }

    public static func prepare(
        _ raw: [LooprChartPoint],
        window: LooprChartWindow,
        endingOn: Date,
        kind: LooprChartKind = .line,
        baseline: LooprBaselineBand? = nil,
        scale: LooprChartScaleHint? = nil,
        calendar: Calendar = .current
    ) -> LooprChartSeries {
        let bounds = bounds(window: window, endingOn: endingOn, calendar: calendar)
        let daily = dailyPoints(raw, calendar: calendar)
            .filter { $0.date >= bounds.start && $0.date <= bounds.lastDay }
        let bucketed = bucket(daily, bucket: window.bucket, calendar: calendar)
        let plotted = segment(bucketed, bucket: window.bucket, calendar: calendar)
        return LooprChartSeries(
            window: window,
            start: bounds.start,
            lastDay: bounds.lastDay,
            points: plotted,
            yDomain: yDomain(for: plotted, kind: kind, baseline: baseline, scale: scale),
            baseline: baseline
        )
    }

    public static func prepare(
        _ raw: [LooprChartPoint],
        range: LooprChartRange,
        endingOn: Date,
        kind: LooprChartKind = .line,
        baseline: LooprBaselineBand? = nil,
        scale: LooprChartScaleHint? = nil,
        calendar: Calendar = .current
    ) -> LooprChartSeries {
        prepare(raw, window: range.window, endingOn: endingOn, kind: kind, baseline: baseline, scale: scale, calendar: calendar)
    }

    // MARK: - Steps

    static func bounds(window: LooprChartWindow, endingOn: Date, calendar: Calendar) -> (start: Date, lastDay: Date) {
        let lastDay = calendar.startOfDay(for: endingOn)
        let start = calendar.date(byAdding: .day, value: -(window.dayCount - 1), to: lastDay) ?? lastDay
        return (start, lastDay)
    }

    /// One point per calendar day, dates normalised to the start of the day,
    /// non-finite values dropped, the later entry winning on duplicates.
    static func dailyPoints(_ raw: [LooprChartPoint], calendar: Calendar) -> [LooprChartPoint] {
        var byDay: [Date: LooprChartPoint] = [:]
        for point in raw where point.value.isFinite {
            let day = calendar.startOfDay(for: point.date)
            byDay[day] = LooprChartPoint(
                date: day,
                value: point.value,
                low: point.low.flatMap { $0.isFinite ? $0 : nil },
                high: point.high.flatMap { $0.isFinite ? $0 : nil }
            )
        }
        return byDay.values.sorted { $0.date < $1.date }
    }

    static func bucketStart(for date: Date, bucket: LooprChartBucket, calendar: Calendar) -> Date {
        switch bucket {
        case .day:
            return calendar.startOfDay(for: date)
        case .week:
            return calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
        }
    }

    private struct Bucketed {
        let date: Date
        let value: Double
        let low: Double?
        let high: Double?
        let measuredDays: Int
    }

    private static func bucket(_ daily: [LooprChartPoint], bucket: LooprChartBucket, calendar: Calendar) -> [Bucketed] {
        switch bucket {
        case .day:
            return daily.map { Bucketed(date: $0.date, value: $0.value, low: $0.low, high: $0.high, measuredDays: 1) }
        case .week:
            let groups = Dictionary(grouping: daily) { bucketStart(for: $0.date, bucket: .week, calendar: calendar) }
            return groups.keys.sorted().compactMap { key in
                guard let members = groups[key], let mean = LooprStatistics.mean(members.map(\.value)) else { return nil }
                let lows = members.map { $0.low ?? $0.value }
                let highs = members.map { $0.high ?? $0.value }
                return Bucketed(date: key, value: mean, low: lows.min(), high: highs.max(), measuredDays: members.count)
            }
        }
    }

    private static func segment(_ buckets: [Bucketed], bucket: LooprChartBucket, calendar: Calendar) -> [LooprPlottedPoint] {
        var segment = 0
        var previous: Date?
        return buckets.map { item in
            if let previous {
                let step: Int
                switch bucket {
                case .day: step = calendar.dateComponents([.day], from: previous, to: item.date).day ?? 0
                case .week: step = calendar.dateComponents([.weekOfYear], from: previous, to: item.date).weekOfYear ?? 0
                }
                if step > 1 { segment += 1 }
            }
            previous = item.date
            return LooprPlottedPoint(
                date: item.date,
                value: item.value,
                low: item.low,
                high: item.high,
                segment: segment,
                measuredDays: item.measuredDays
            )
        }
    }

    /// Lines get a data-fitted domain so variation is visible; bars start at
    /// zero so their length stays proportional to the value.
    ///
    /// A `scale` hint widens a line's domain to at least its minimum span and
    /// keeps it inside the metric's bounds; for bars it raises the top to at
    /// least the minimum span. Without a hint the domain is unchanged.
    static func yDomain(
        for points: [LooprPlottedPoint],
        kind: LooprChartKind,
        baseline: LooprBaselineBand?,
        scale: LooprChartScaleHint? = nil
    ) -> ClosedRange<Double> {
        var values = points.map(\.value)
        if kind == .rangeBars {
            values += points.compactMap(\.low) + points.compactMap(\.high)
        }
        if let baseline {
            values += [baseline.lower, baseline.upper]
        }
        guard var low = values.min(), var high = values.max() else { return 0...1 }
        let dataLow = low
        let dataHigh = high

        if kind == .bars {
            var top = high <= 0 ? 1 : high * 1.12
            if let scale {
                top = max(top, min(0, low) + scale.minimumSpan)
                if let bounds = scale.bounds { top = min(top, max(bounds.upperBound, dataHigh)) }
            }
            return min(0, low)...max(top, min(0, low) + 0.000_001)
        }

        if scale?.includeZero == true { low = min(0, low); high = max(0, high) }
        let span = high - low
        let minimumSpan = max(abs((high + low) / 2) * 0.08, 1, scale?.minimumSpan ?? 0)
        if span < minimumSpan {
            let middle = (high + low) / 2
            low = middle - minimumSpan / 2
            high = middle + minimumSpan / 2
        }
        if let bounds = scale?.bounds {
            // Slide the window back inside the metric's possible values
            // rather than cutting it, so the minimum span survives.
            if low < bounds.lowerBound, dataLow >= bounds.lowerBound {
                high += bounds.lowerBound - low
                low = bounds.lowerBound
            }
            if high > bounds.upperBound, dataHigh <= bounds.upperBound {
                low = max(low - (high - bounds.upperBound), min(bounds.lowerBound, dataLow))
                high = bounds.upperBound
            }
        }
        let padding = (high - low) * 0.14
        let allNonNegative = values.allSatisfy { $0 >= 0 }
        var lower = allNonNegative ? max(0, low - padding) : low - padding
        var upper = high + padding
        if let bounds = scale?.bounds {
            lower = max(lower, min(bounds.lowerBound, dataLow))
            upper = min(upper, max(bounds.upperBound, dataHigh))
        }
        return lower...upper
    }
}
