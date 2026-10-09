import Foundation

// Small-data rules for the metric charts. Pure, so they can be tested without
// rendering. Everything here is opt-in: a chart or card that passes none of it
// behaves exactly as before.

/// How far the value axis may zoom in for one metric.
///
/// Two readings of 46 and 42 ms fill the whole chart height when the axis
/// fits the data, and a 4 ms wobble looks like a plunge. A minimum span keeps
/// the axis at least that wide, centred on the data, and `bounds` keeps it
/// inside the metric's possible values (0 to 100 for a score, 0 to 21 for
/// strain).
///
/// ```swift
/// LooprChartSeries.prepare(points, range: .month, endingOn: today,
///                          scale: LooprChartScaleHint(minimumSpan: 20))          // HRV in ms
/// LooprChartScaleHint(minimumSpan: 100, bounds: 0...100)                        // recovery: always 0 to 100
/// ```
public struct LooprChartScaleHint: Hashable, Sendable {
    /// The smallest distance between the bottom and top of the value axis,
    /// in the metric's own unit.
    public var minimumSpan: Double
    /// The values the metric can take. The axis never extends past them
    /// unless a reading does.
    public var bounds: ClosedRange<Double>?
    /// Keep the reference zero visible for charts of changes.
    public var includeZero: Bool

    public init(minimumSpan: Double, bounds: ClosedRange<Double>? = nil, includeZero: Bool = false) {
        self.minimumSpan = max(0, minimumSpan)
        self.bounds = bounds
        self.includeZero = includeZero
    }
}

public extension LooprChartRange {
    /// The ranges worth offering for a history that covers `historyDays` days
    /// (from the first reading to the day on screen, inclusive).
    ///
    /// 7D is always there. Each longer range unlocks once the history is longer
    /// than the range before it, so a new range always shows more than the
    /// one below it and no reading is ever hidden: 30D from 8 days, 90D from
    /// 31 days, 1Y from 91 days.
    static func unlocked(historyDays: Int) -> Set<LooprChartRange> {
        var result: Set<LooprChartRange> = [.week]
        let ordered = LooprChartRange.allCases
        for (index, range) in ordered.enumerated() where index > 0 {
            if historyDays > ordered[index - 1].dayCount { result.insert(range) }
        }
        return result
    }

    /// Days from the first reading to `endingOn`, inclusive; 0 without readings.
    static func historyDays(_ points: [LooprChartPoint], endingOn: Date, calendar: Calendar = .current) -> Int {
        let last = calendar.startOfDay(for: endingOn)
        guard let first = points.lazy.filter({ $0.value.isFinite }).map({ calendar.startOfDay(for: $0.date) }).filter({ $0 <= last }).min() else {
            return 0
        }
        return (calendar.dateComponents([.day], from: first, to: last).day ?? 0) + 1
    }

    /// The range to draw when `preferred` may be locked: `preferred` itself
    /// when it is available, otherwise the longest available range shorter
    /// than it, otherwise the shortest available one. The stored preference
    /// is left alone, so the chart moves up to it once the history grows.
    static func resolved(_ preferred: LooprChartRange, available: Set<LooprChartRange>?) -> LooprChartRange {
        guard let available, !available.isEmpty, !available.contains(preferred) else { return preferred }
        let shorter = LooprChartRange.allCases.filter { available.contains($0) && $0.dayCount < preferred.dayCount }
        return shorter.last ?? LooprChartRange.allCases.first { available.contains($0) } ?? preferred
    }
}

/// Words for a count of days, so a header can say "Average of 2 nights"
/// instead of "30-day average" over two readings.
public struct LooprCountNoun: Hashable, Sendable {
    public let singular: String
    public let plural: String

    public init(singular: String, plural: String) {
        self.singular = singular
        self.plural = plural
    }

    public static let days = LooprCountNoun(singular: "day", plural: "days")
    public static let nights = LooprCountNoun(singular: "night", plural: "nights")

    /// "1 night", "2 nights".
    public func count(_ number: Int) -> String {
        "\(number) \(number == 1 ? singular : plural)"
    }
}

/// Opt-in behaviour for `LooprMetricTrendCard`. `.standard` is the card as it
/// always was; the metric detail page turns everything on.
public struct LooprTrendCardOptions: Sendable {
    /// Keeps the value axis from zooming in on a few close readings.
    public var scale: LooprChartScaleHint?
    /// Ranges the picker offers; the rest show as locked. Nil offers all.
    /// Build it with `LooprChartRange.unlocked(historyDays:)`.
    public var availableRanges: Set<LooprChartRange>?
    /// When set, a range with fewer than `smallDataThreshold` measured days
    /// says "Average of 2 nights" instead of "30-day average · 2 of 30 days".
    public var smallDataNoun: LooprCountNoun?
    public var smallDataThreshold: Int
    /// Whether the legend prints the usual range's numbers. Turn it off when
    /// the screen already states the range once elsewhere.
    public var legendShowsValues: Bool
    /// Shown under the picker while any range is locked.
    public var lockedCaption: String

    public init(
        scale: LooprChartScaleHint? = nil,
        availableRanges: Set<LooprChartRange>? = nil,
        smallDataNoun: LooprCountNoun? = nil,
        smallDataThreshold: Int = 7,
        legendShowsValues: Bool = true,
        lockedCaption: String = "Longer ranges unlock as your history builds."
    ) {
        self.scale = scale
        self.availableRanges = availableRanges
        self.smallDataNoun = smallDataNoun
        self.smallDataThreshold = smallDataThreshold
        self.legendShowsValues = legendShowsValues
        self.lockedCaption = lockedCaption
    }

    public static let standard = LooprTrendCardOptions()

    /// Whether the picker shows at least one locked range.
    public var hasLockedRanges: Bool {
        guard let availableRanges else { return false }
        return LooprChartRange.allCases.contains { !availableRanges.contains($0) }
    }
}

/// Fixed English date words for chart labels, matching `LooprDayLabel`:
/// "Tue 22 Sep" on every device.
enum LooprChartDateText {
    static func string(_ date: Date, _ format: String, calendar: Calendar = .current) -> String {
        LooprDateFormatterCache.string(from: date, format: format, calendar: calendar)
    }

    /// "TUE 22 SEP".
    static func day(_ date: Date, calendar: Calendar = .current) -> String {
        string(date, "EEE d MMM", calendar: calendar).uppercased()
    }
}
