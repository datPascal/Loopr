import DesignSystem
import DomainKit
import Foundation

// MARK: What "has data" means

/// Everything Loopr knows about which days hold data, read without deriving
/// anything.
///
/// Definitions, in the order they are trusted:
///
/// - A day **has data** when its derived generation produced at least one
///   band value: a number `BandMetricSeriesMapping` would write to the
///   metric history (sleep, a nightly heart value, strain, steps, stress,
///   active energy, recovery and so on). Every derivation writes those values
///   through to `metric_series`, so the stored band rows are the index.
/// - A day has **no data** when it was derived and produced none of those, or
///   when the band recorded no second between its local midnight and the next.
///   A civil day with no recorded second has nothing its own derivation could
///   measure, so it is skipped without deriving.
/// - Otherwise the day is **unknown**: seconds exist, nothing was derived yet.
///
/// The **latest complete day** is the newest day before today, in the
/// person's current time zone, that has data. Any day before today is
/// complete because its window has closed; late history can still revise it.
nonisolated struct LooprDayKnowledge: Equatable, Sendable {
    /// Days with at least one derived band value.
    var withData: Set<DayIdentity> = []
    /// Days that were derived in this process and produced nothing.
    var derivedEmpty: Set<DayIdentity> = []
    /// Days with at least one recorded second inside their civil window.
    var recorded: Set<DayIdentity> = []
    /// The first day the band recorded anything.
    var earliestRecorded: DayIdentity?
    /// When the newest recorded second was taken.
    var lastRecordAt: Date?
    /// The first day the index looked at. Days before it are unknown rather
    /// than empty. Nil means the index covers all of history.
    var coveredFrom: DayIdentity?

    func status(of day: DayIdentity) -> LooprDayDataStatus {
        if withData.contains(day) { return .hasData }
        if derivedEmpty.contains(day) { return .noData }
        if let coveredFrom, LooprDays.isEarlier(day, coveredFrom) { return .unknown }
        return recorded.contains(day) ? .unknown : .noData
    }

    /// The earliest day with anything at all: recorded or derived.
    var earliestDay: DayIdentity? {
        let candidates = [earliestRecorded, withData.min(by: LooprDays.isEarlier)].compactMap { $0 }
        return candidates.min(by: LooprDays.isEarlier)
    }

    /// The newest day with data on or before `limit`.
    func latestDayWithData(onOrBefore limit: DayIdentity) -> DayIdentity? {
        withData.filter { !LooprDays.isEarlier(limit, $0) }.max(by: LooprDays.isEarlier)
    }

    mutating func record(day: DayIdentity, hasData: Bool) {
        if hasData {
            withData.insert(day)
            derivedEmpty.remove(day)
        } else {
            withData.remove(day)
            derivedEmpty.insert(day)
        }
    }
}

// MARK: The default day

nonisolated enum LooprDayResolution {
    enum Decision: Equatable, Sendable {
        /// Show this day.
        case show(DayIdentity)
        /// This day must be derived before the answer is known.
        case derive(DayIdentity)
    }

    /// How far back the walk looks for the latest complete day. A person who
    /// has not worn the band for longer than this starts on an empty today.
    static let lookbackDays = 60

    /// Today when it has data; otherwise the latest complete day; otherwise
    /// today, empty. A day whose status is unknown has to be derived first,
    /// and the caller comes back with the answer.
    static func resolve(today: DayIdentity, knowledge: LooprDayKnowledge, calendar: Calendar,
                        lookbackDays: Int = LooprDayResolution.lookbackDays) -> Decision {
        switch knowledge.status(of: today) {
        case .hasData: return .show(today)
        case .unknown: return .derive(today)
        case .noData: break
        }
        let floor = knowledge.earliestDay
        var cursor = today
        for _ in 0..<max(0, lookbackDays) {
            guard let previous = LooprDays.adding(-1, to: cursor, calendar: calendar) else { break }
            cursor = previous
            if let floor, LooprDays.isEarlier(cursor, floor) { break }
            switch knowledge.status(of: cursor) {
            case .hasData: return .show(cursor)
            case .unknown: return .derive(cursor)
            case .noData: continue
            }
        }
        return .show(today)
    }
}

// MARK: Day arithmetic

/// Civil-day helpers for `DayIdentity`, anchored on local noon so a DST
/// change can never skip or repeat a day.
nonisolated enum LooprDays {
    static func calendar(_ timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    static func day(containing date: Date, calendar: Calendar) -> DayIdentity {
        let parts = calendar.dateComponents([.era, .year, .month, .day], from: date)
        return DayIdentity(era: parts.era ?? 1, year: parts.year ?? 1970, month: parts.month ?? 1, day: parts.day ?? 1)
    }

    static func noon(of day: DayIdentity, calendar: Calendar) -> Date? {
        calendar.date(from: DateComponents(era: day.era, year: day.year, month: day.month, day: day.day, hour: 12))
    }

    /// The first instant of `day` and of the day after it.
    static func bounds(of day: DayIdentity, calendar: Calendar) -> (start: Date, end: Date)? {
        guard let noon = noon(of: day, calendar: calendar),
              let nextNoon = calendar.date(byAdding: .day, value: 1, to: noon) else { return nil }
        return (calendar.startOfDay(for: noon), calendar.startOfDay(for: nextNoon))
    }

    static func adding(_ offset: Int, to day: DayIdentity, calendar: Calendar) -> DayIdentity? {
        guard let noon = noon(of: day, calendar: calendar),
              let moved = calendar.date(byAdding: .day, value: offset, to: noon) else { return nil }
        return Self.day(containing: moved, calendar: calendar)
    }

    static func isEarlier(_ lhs: DayIdentity, _ rhs: DayIdentity) -> Bool {
        (lhs.era, lhs.year, lhs.month, lhs.day) < (rhs.era, rhs.year, rhs.month, rhs.day)
    }

    static func looprDay(_ day: DayIdentity) -> LooprDay {
        LooprDay(year: day.year, month: day.month, day: day.day)
    }

    static func identity(_ day: LooprDay) -> DayIdentity {
        DayIdentity(year: day.year, month: day.month, day: day.day)
    }

    /// `yyyy-MM-dd`, the label `metric_series` stores.
    static func label(_ day: DayIdentity) -> String {
        String(format: "%04d-%02d-%02d", day.year, day.month, day.day)
    }

    static func identity(label: String) -> DayIdentity? {
        let parts = label.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return DayIdentity(year: parts[0], month: parts[1], day: parts[2])
    }
}
