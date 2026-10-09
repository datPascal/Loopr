import Foundation
import DomainKit
import DesignSystem

/// A civil date (`yyyy-MM-dd`), with day arithmetic that never goes through a
/// time zone, so DST and travel cannot add or drop a night.
public struct SleepCivilDay: Hashable, Comparable, Sendable {
    public let year: Int
    public let month: Int
    public let day: Int
    /// Days since 1970-01-01.
    public let ordinal: Int

    public init?(year: Int, month: Int, day: Int) {
        guard let date = Self.utc.date(from: DateComponents(year: year, month: month, day: day)) else { return nil }
        let parts = Self.utc.dateComponents([.year, .month, .day], from: date)
        guard parts.year == year, parts.month == month, parts.day == day else { return nil }
        self.year = year
        self.month = month
        self.day = day
        ordinal = Int((date.timeIntervalSince1970 / 86_400).rounded(.down))
    }

    public init?(label: String) {
        let parts = label.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        self.init(year: parts[0], month: parts[1], day: parts[2])
    }

    public init?(_ identity: DayIdentity) {
        self.init(year: identity.year, month: identity.month, day: identity.day)
    }

    public static func < (lhs: SleepCivilDay, rhs: SleepCivilDay) -> Bool { lhs.ordinal < rhs.ordinal }

    /// Saturday or Sunday. A night is filed under the day it ends on, so these
    /// are the Friday and Saturday nights.
    public var isWeekend: Bool {
        guard let date = Self.utc.date(from: DateComponents(year: year, month: month, day: day)) else { return false }
        let weekday = Self.utc.component(.weekday, from: date)
        return weekday == 1 || weekday == 7
    }

    /// Noon of this day in `calendar`'s time zone: the date a chart plots the
    /// night at, so axis labels read the right weekday in every time zone.
    public func noon(in calendar: Calendar) -> Date? {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))
    }

    public func adding(days: Int) -> SleepCivilDay? {
        guard let date = Self.utc.date(from: DateComponents(year: year, month: month, day: day)),
              let moved = Self.utc.date(byAdding: .day, value: days, to: date) else { return nil }
        let parts = Self.utc.dateComponents([.year, .month, .day], from: moved)
        return SleepCivilDay(year: parts.year ?? 0, month: parts.month ?? 0, day: parts.day ?? 0)
    }

    static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()
}

/// One night from the trend, keyed by the civil day it ends on.
public struct SleepNightRecord: Equatable, Sendable {
    public let day: SleepCivilDay
    /// Minutes asleep in the main sleep, nil when the night has no main sleep.
    public let asleepMinutes: Double?
    public let start: Date?
    public let end: Date?
    public let values: [String: Double]

    public init(day: SleepCivilDay, asleepMinutes: Double?, start: Date? = nil, end: Date? = nil, values: [String: Double] = [:]) {
        self.day = day
        self.asleepMinutes = asleepMinutes.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        self.start = start
        self.end = end
        self.values = values
    }

    public func value(_ id: String) -> Double? { values[id] }
}

/// The selected night and the nights before it, from `SleepDaySnapshot.trend`.
///
/// The derivation folds the selected night plus the 28 nights before it into
/// the trend, and keeps only finished nights from the earlier ones. Every
/// usual range on the Sleep tab is built from these earlier nights, never from
/// the selected night itself. Learning progress includes the selected night.
public struct SleepNightHistory: Equatable, Sendable {
    public let day: SleepCivilDay?
    /// The selected night, when the trend carries it.
    public let current: SleepNightRecord?
    /// Earlier nights, oldest first. At most one per civil day.
    public let prior: [SleepNightRecord]

    public init(trend: [SleepTrendPoint], day identity: DayIdentity) {
        let day = SleepCivilDay(identity)
        self.day = day
        var byDay: [SleepCivilDay: SleepNightRecord] = [:]
        for point in trend {
            guard let civil = SleepCivilDay(label: point.localDay), byDay[civil] == nil else { continue }
            byDay[civil] = SleepNightRecord(day: civil, asleepMinutes: point.value.map { $0 * 60 },
                                            start: point.start, end: point.end, values: point.values)
        }
        current = day.flatMap { byDay[$0] }
        prior = byDay.values
            .filter { record in day.map { record.day < $0 } ?? true }
            .sorted { $0.day < $1.day }
    }

    public init(day: SleepCivilDay?, current: SleepNightRecord?, prior: [SleepNightRecord]) {
        self.day = day
        self.current = current
        self.prior = prior.sorted { $0.day < $1.day }
    }

    /// Earlier nights inside the `nights` days before the selected day.
    public func prior(within nights: Int) -> [SleepNightRecord] {
        guard let day else { return prior }
        return prior.filter { day.ordinal - $0.day.ordinal <= nights && $0.day < day }
    }

    /// Earlier nights with a main sleep.
    public var priorNightsWithSleep: [SleepNightRecord] { prior.filter { $0.asleepMinutes != nil } }
}

/// A usual range: the middle half of recent nights (25th to 75th percentile),
/// with the median in the middle.
public struct SleepUsualRange: Equatable, Sendable {
    /// Nights the range looks back over.
    public static let windowNights = 30
    /// Fewer nights than this and the range is still being learned.
    public static let minimumNights = 5

    public let lower: Double
    public let median: Double
    public let upper: Double
    public let nights: Int

    public init(lower: Double, median: Double, upper: Double, nights: Int) {
        self.lower = min(lower, upper)
        self.median = median
        self.upper = max(lower, upper)
        self.nights = nights
    }

    /// The range from `values`, or nil with fewer than `minimumNights` finite values.
    public static func compute(_ values: [Double], minimumNights: Int = SleepUsualRange.minimumNights) -> SleepUsualRange? {
        let finite = values.filter(\.isFinite).sorted()
        guard finite.count >= max(1, minimumNights),
              let lower = percentile(finite, 25), let median = percentile(finite, 50), let upper = percentile(finite, 75) else { return nil }
        return SleepUsualRange(lower: lower, median: median, upper: upper, nights: finite.count)
    }

    /// Linear interpolation between closest ranks (the spreadsheet PERCENTILE.INC rule).
    public static func percentile(_ values: [Double], _ percent: Double) -> Double? {
        let sorted = values.filter(\.isFinite).sorted()
        guard !sorted.isEmpty else { return nil }
        guard sorted.count > 1 else { return sorted[0] }
        let rank = min(max(percent, 0), 100) / 100 * Double(sorted.count - 1)
        let low = Int(rank.rounded(.down))
        let high = min(low + 1, sorted.count - 1)
        return sorted[low] + (sorted[high] - sorted[low]) * (rank - Double(low))
    }

    /// The range as a baseline band, so `LooprDelta` and the range bars can
    /// read it.
    public var band: LooprBaselineBand {
        LooprBaselineBand(center: median, lower: lower, upper: upper, measuredDays: nights)
    }

    public func contains(_ value: Double) -> Bool { value >= lower && value <= upper }
}

/// A usual range, or how far along learning it is.
public enum SleepUsual: Equatable, Sendable {
    case range(SleepUsualRange)
    case learning(measured: Int, needed: Int)

    /// The usual range of `id` over the nights before the selected one.
    public static func of(_ id: String, in history: SleepNightHistory,
                          windowNights: Int = SleepUsualRange.windowNights,
                          minimumNights: Int = SleepUsualRange.minimumNights) -> SleepUsual {
        let values = history.prior(within: windowNights).compactMap { $0.value(id) }
        return includingCurrent(from(values, minimumNights: minimumNights), value: history.current?.value(id))
    }

    /// The usual range of minutes asleep over the nights before the selected one.
    public static func ofDuration(in history: SleepNightHistory,
                                  windowNights: Int = SleepUsualRange.windowNights,
                                  minimumNights: Int = SleepUsualRange.minimumNights) -> SleepUsual {
        includingCurrent(from(history.prior(within: windowNights).compactMap(\.asleepMinutes), minimumNights: minimumNights),
                         value: history.current?.asleepMinutes)
    }

    private static func includingCurrent(_ usual: SleepUsual, value: Double?) -> SleepUsual {
        guard case .learning(let measured, let needed) = usual, let value, value.isFinite else { return usual }
        return .learning(measured: min(measured + 1, needed), needed: needed)
    }

    static func from(_ values: [Double], minimumNights: Int) -> SleepUsual {
        if let range = SleepUsualRange.compute(values, minimumNights: minimumNights) { return .range(range) }
        return .learning(measured: values.filter(\.isFinite).count, needed: minimumNights)
    }

    public var range: SleepUsualRange? {
        if case .range(let range) = self { return range }
        return nil
    }

    /// The caption: "+12 min vs usual", "Usual", "Learning your usual · 2 of 5 nights".
    public func delta(for value: Double?, higherIsBetter: Bool?, unit: String = "",
                      format: LooprDeltaFormat, withinRange: LooprDelta.WithinRange = .word) -> LooprDelta? {
        switch self {
        case .range(let range):
            return LooprDelta.compare(value, usual: range.band, higherIsBetter: higherIsBetter, unit: unit,
                                      format: format, withinRange: withinRange)
        case .learning(let measured, let needed):
            guard value != nil else { return nil }
            return LooprDelta.learning(measured, of: needed)
        }
    }
}
