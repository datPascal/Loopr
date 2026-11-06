import AnalyticsKit
import DesignSystem
import Foundation

// LV-08b step 1: one rule for "improving", "steady", "watch" and "changed", used by the year slopes and the star map.
//
// A later value is compared with an earlier one. It is steady when the two differ by no more than a band: half the
// spread of the middle half of the earlier values (their interquartile range), and never less than a floor share
// of the earlier median (2 % for band and Apple Health values, 5 % for lab values). Outside the band it is
// improving when it moved the way the metric's better direction points, and watch when it moved the other way.
// A metric with no stated better direction, every lab marker among them, is steady or changed: changed means it
// moved outside your own band, whichever way, and carries no judgement and no warning colour (DEC-12.6). Lab values
// are only ever compared with the person's own earlier values, never with a reference range.

public enum DataTrend: String, CaseIterable, Sendable, Hashable {
    case improving
    case steady
    case watch
    /// Moved outside the person's own band, on a metric with no better direction (every lab marker). Neutral.
    case changed

    public var title: String { rawValue }
}

public enum DataTrendRule {
    /// The band floor for band and Apple Health values, as a share of the earlier median.
    public static let floorShare = 0.02
    /// The band floor for lab values.
    public static let labFloorShare = 0.05

    public static func median(_ values: [Double]) -> Double? {
        let sorted = values.filter(\.isFinite).sorted()
        guard !sorted.isEmpty else { return nil }
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    /// The 75th minus the 25th percentile, by linear interpolation. Zero for fewer than two values.
    public static func interquartileRange(_ values: [Double]) -> Double {
        let sorted = values.filter(\.isFinite).sorted()
        guard sorted.count >= 2 else { return 0 }
        func percentile(_ p: Double) -> Double {
            let position = p * Double(sorted.count - 1)
            let low = Int(position.rounded(.down))
            let high = min(low + 1, sorted.count - 1)
            return sorted[low] + (sorted[high] - sorted[low]) * (position - Double(low))
        }
        return percentile(0.75) - percentile(0.25)
    }

    /// Half the earlier values' interquartile range, at least `floorShare` of their median.
    public static func band(earlier: [Double], floorShare: Double) -> Double {
        let center = median(earlier) ?? 0
        return max(interquartileRange(earlier) / 2, abs(center) * floorShare)
    }

    public static func classify(earlier: Double, later: Double, band: Double, higherIsBetter: Bool?) -> DataTrend {
        let change = later - earlier
        guard abs(change) > band else { return .steady }
        guard let higherIsBetter else { return .changed }
        return (change > 0) == higherIsBetter ? .improving : .watch
    }
}

// MARK: - Series

/// The ten clusters of the star map.
public enum DataBodySystem: String, CaseIterable, Sendable, Hashable, Identifiable {
    case cardiovascular
    case metabolic
    case inflammation
    case blood
    case kidney
    case liver
    case hormones
    case nutrients
    case sleep
    case fitness

    public var id: String { rawValue }
    /// `data-star-cluster-cardiovascular` and so on.
    public var identifier: String { "data-star-cluster-\(rawValue)" }

    public var title: String {
        switch self {
        case .cardiovascular: "Cardiovascular"
        case .metabolic: "Metabolic"
        case .inflammation: "Inflammation"
        case .blood: "Blood"
        case .kidney: "Kidney"
        case .liver: "Liver"
        case .hormones: "Hormones"
        case .nutrients: "Nutrients"
        case .sleep: "Sleep"
        case .fitness: "Fitness"
        }
    }

    public init(_ system: LabBodySystem) {
        switch system {
        case .cardiovascular: self = .cardiovascular
        case .metabolic: self = .metabolic
        case .inflammation: self = .inflammation
        case .blood: self = .blood
        case .kidney: self = .kidney
        case .liver: self = .liver
        case .hormones: self = .hormones
        case .nutrients: self = .nutrients
        }
    }
}

public enum DataMarkerSource: String, Sendable, Hashable {
    case band
    case appleHealth
    case lab
}

/// How often a series has values, which decides how it is compared.
public enum DataSeriesCadence: Sendable, Hashable {
    /// About one value a day: windows of days are compared.
    case daily
    /// Now and then, as weight or VO₂max: values are compared one against the others.
    case occasional
    /// A lab marker: compared like `occasional`, with the lab floor.
    case lab
}

public struct DataPoint: Equatable, Sendable {
    public let date: Date
    public let value: Double

    public init(date: Date, value: Double) {
        self.date = date
        self.value = value
    }
}

/// One metric's history as the Data tab compares it. The app maps band metrics, Apple Health kinds and lab markers
/// onto this; a metric with no values is still listed, so the star map can draw it as not measured.
public struct DataSeries: Sendable, Identifiable {
    public let id: String
    public let title: String
    public let system: DataBodySystem
    public let source: DataMarkerSource
    public let cadence: DataSeriesCadence
    /// Nil when the metric has no better direction Loopr states. Lab markers are always nil.
    public let higherIsBetter: Bool?
    /// Oldest first.
    public let points: [DataPoint]
    /// The latest value as the screen writes it, when it differs from `valueText(latest)`: a lab's printed digits.
    public let latestText: String?
    public let valueText: @Sendable (Double) -> String
    public let deltaText: @Sendable (Double) -> String
    /// This year's and last year's values when the metric has its own year rule, as VO₂max does: the 42-day median
    /// today and a year earlier (`VO2MaxYearChange`), the values the Fitness gauge shows (R3-OPT-3). Nil compares the
    /// 90-day windows. `lastYear` nil means a year ago had too few readings, so the metric has no row.
    public let yearValues: DataYearValues?

    public init(id: String, title: String, system: DataBodySystem, source: DataMarkerSource, cadence: DataSeriesCadence,
                higherIsBetter: Bool?, points: [DataPoint], latestText: String? = nil,
                valueText: @escaping @Sendable (Double) -> String, deltaText: @escaping @Sendable (Double) -> String,
                yearValues: DataYearValues? = nil) {
        self.id = id
        self.title = title
        self.system = system
        self.source = source
        self.cadence = cadence
        self.higherIsBetter = cadence == .lab ? nil : higherIsBetter
        self.points = points.filter { $0.value.isFinite }.sorted { $0.date < $1.date }
        self.latestText = latestText
        self.valueText = valueText
        self.deltaText = deltaText
        self.yearValues = yearValues
    }

    public var latest: DataPoint? { points.last }
    var floorShare: Double { cadence == .lab ? DataTrendRule.labFloorShare : DataTrendRule.floorShare }

    func values(from start: Date, through end: Date) -> [Double] {
        points.filter { $0.date >= start && $0.date <= end }.map(\.value)
    }
}

// MARK: - This year against last

/// A metric's own two values for the year comparison.
public struct DataYearValues: Equatable, Sendable {
    public let thisYear: Double
    public let lastYear: Double?
    /// What each value is, as the year row names it: "42-day median" for VO₂max.
    public let basis: String

    public init(thisYear: Double, lastYear: Double?, basis: String = "Median") {
        self.thisYear = thisYear
        self.lastYear = lastYear
        self.basis = basis
    }
}

public struct DataYearSlope: Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    /// This year's value with its unit: "44.1 ml/kg/min".
    public let valueText: String
    public let lastYear: Double
    public let thisYear: Double
    public let deltaText: String
    public let trend: DataTrend
    /// How far it moved in bands, for the order of the rows.
    public let movement: Double
    /// What the two values are: "90-day median", or "Latest draw" for a lab marker (Data ICP R4-VET-01).
    public var basis: String = "90-day median"
    /// Last year's value with its unit, so the change beside it reads in a unit (Data ICP R4-VET-02).
    public var lastYearText: String? = nil

    /// The sign of the change: 1 up, -1 down, 0 for steady. The glyph slopes this way whatever the trend's colour, so
    /// a value that went up is never drawn falling.
    public var direction: Int {
        guard trend != .steady else { return 0 }
        return thisYear > lastYear ? 1 : (thisYear < lastYear ? -1 : 0)
    }

    /// The row's second line: "90-day median 51 bpm, last year 54 bpm". The value is named by its basis, so 44.1 here
    /// and 47.5 on a tile read as two different things, and last year's value puts the change in a unit.
    public var caption: String {
        let now = "\(basis) \(valueText)"
        guard let lastYearText else { return now }
        return "\(now), last year \(lastYearText)"
    }

    /// The sign of the change is read as a word: "minus 0.5", never "hyphen 0.5".
    public var spokenLabel: String {
        "\(title), \(caption), \(LooprSignedNumber.spoken(text: deltaText)) on last year, \(trend.title)"
    }
}

public enum DataYearComparison: Equatable, Sendable {
    /// Less than a year of data: the comparison opens after `daysUntilOpen` more days.
    case learning(daysUntilOpen: Int)
    case noData
    /// A year of data, but no metric has the coverage in both windows yet.
    case notEnoughCoverage
    /// Every metric compared, most moved first.
    case rows([DataYearSlope])

    public var rows: [DataYearSlope] {
        if case .rows(let rows) = self { return rows }
        return []
    }
}

/// This year against last (contract `#meaning`, "From weeks to years"). Band and Apple Health daily metrics compare
/// the median of the 90 days up to today with the same 90 days a year earlier; each window needs 30 days with a value.
/// Occasional ones, such as weight, compare the same windows and need 3 values in each. Lab markers compare the latest
/// value of the last 365 days with the latest of the 365 days before. With less than a year since the first stored
/// value the comparison is learning.
public enum DataYearComparisonRule {
    public static let windowDays = 90
    public static let dailyCoverage = 30
    public static let occasionalCoverage = 3
    public static let daysToOpen = 365

    public static let ruleSentence = "The last 90 days against the same 90 days a year ago, for metrics with 30 days in each. VO₂max compares its 42-day median with the one a year earlier, as Fitness does. Lab values compare your latest result of each year."

    public static func compare(_ series: [DataSeries], now: Date, calendar: Calendar) -> DataYearComparison {
        let today = calendar.startOfDay(for: now)
        guard let first = series.compactMap({ $0.points.first?.date }).min() else { return .noData }
        let span = calendar.dateComponents([.day], from: calendar.startOfDay(for: first), to: today).day ?? 0
        if span < daysToOpen { return .learning(daysUntilOpen: daysToOpen - span) }

        let rows = series.compactMap { slope(for: $0, today: today, now: now, calendar: calendar) }
            .sorted { ($0.movement, $1.title) > ($1.movement, $0.title) }
        return rows.isEmpty ? .notEnoughCoverage : .rows(rows)
    }

    /// The windows a daily or occasional metric compares: this year's and last year's, each from its first day to the
    /// end of its last.
    public static func windows(today: Date, calendar: Calendar) -> (this: ClosedRange<Date>, last: ClosedRange<Date>)? {
        guard let start = calendar.date(byAdding: .day, value: -(windowDays - 1), to: today),
              let end = calendar.date(byAdding: DateComponents(day: 1, second: -1), to: today),
              let lastStart = calendar.date(byAdding: .year, value: -1, to: start),
              let lastEnd = calendar.date(byAdding: .year, value: -1, to: end) else { return nil }
        return (start...end, lastStart...lastEnd)
    }

    static func slope(for series: DataSeries, today: Date, now: Date, calendar: Calendar) -> DataYearSlope? {
        let earlierValues: [Double]
        let laterValue: Double
        let lastYearValue: Double
        var basis = "\(windowDays)-day median"
        if let own = series.yearValues {
            guard let lastYear = own.lastYear, own.thisYear.isFinite, lastYear.isFinite else { return nil }
            basis = own.basis
            earlierValues = [lastYear]
            laterValue = own.thisYear
            lastYearValue = lastYear
        } else {
            switch series.cadence {
            case .daily, .occasional:
                guard let windows = windows(today: today, calendar: calendar) else { return nil }
                let this = series.values(from: windows.this.lowerBound, through: windows.this.upperBound)
                let last = series.values(from: windows.last.lowerBound, through: windows.last.upperBound)
                let needed = series.cadence == .daily ? dailyCoverage : occasionalCoverage
                guard this.count >= needed, last.count >= needed,
                      let thisMedian = DataTrendRule.median(this), let lastMedian = DataTrendRule.median(last) else { return nil }
                earlierValues = last
                laterValue = thisMedian
                lastYearValue = lastMedian
            case .lab:
                guard let yearAgo = calendar.date(byAdding: .year, value: -1, to: now),
                      let twoYearsAgo = calendar.date(byAdding: .year, value: -2, to: now),
                      let this = series.points.last(where: { $0.date > yearAgo && $0.date <= now }),
                      let last = series.points.last(where: { $0.date > twoYearsAgo && $0.date <= yearAgo }) else { return nil }
                earlierValues = [last.value]
                laterValue = this.value
                lastYearValue = last.value
                basis = "Latest draw"
            }
        }
        let band = DataTrendRule.band(earlier: earlierValues, floorShare: series.floorShare)
        let trend = DataTrendRule.classify(earlier: lastYearValue, later: laterValue, band: band, higherIsBetter: series.higherIsBetter)
        let change = laterValue - lastYearValue
        return DataYearSlope(id: series.id, title: series.title, valueText: series.valueText(laterValue),
                             lastYear: lastYearValue, thisYear: laterValue, deltaText: series.deltaText(change), trend: trend,
                             movement: band > 0 ? abs(change) / band : (change == 0 ? 0 : .infinity),
                             basis: basis, lastYearText: series.valueText(lastYearValue))
    }
}
