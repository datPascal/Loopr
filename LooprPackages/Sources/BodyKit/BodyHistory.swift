import Foundation
import DomainKit
import DesignSystem

/// One civil day of the daily values the Body tab looks back over.
public struct BodyHistoryDay: Equatable, Hashable, Sendable {
    public let day: DayIdentity
    /// The day's strain on the 0 to 21 scale.
    public var strain: Double?
    /// The recovery score of the morning that starts this day, 0 to 100.
    public var recovery: Double?
    public var steps: Double?
    public var activeEnergy: Double?

    public init(day: DayIdentity, strain: Double? = nil, recovery: Double? = nil, steps: Double? = nil, activeEnergy: Double? = nil) {
        self.day = day
        self.strain = strain.flatMap { $0.isFinite ? $0 : nil }
        self.recovery = recovery.flatMap { $0.isFinite ? $0 : nil }
        self.steps = steps.flatMap { $0.isFinite ? $0 : nil }
        self.activeEnergy = activeEnergy.flatMap { $0.isFinite ? $0 : nil }
    }
}

/// The daily history behind the Body tab, anchored on the day on screen.
///
/// It covers `lookbackDays` days before the anchor, the anchor, and the day
/// after it, whose recovery is the anchor's "next morning". Days with no value
/// are simply absent: nothing here is ever filled with zero.
public struct BodyHistory: Equatable, Sendable {
    /// Days before the anchor. 90 leaves enough history for
    /// the four-week load chart to include established 42-day comparisons.
    public static let lookbackDays = 90

    public let anchor: DayIdentity
    private let byDay: [DayIdentity: BodyHistoryDay]

    public init(anchor: DayIdentity, days: [BodyHistoryDay]) {
        self.anchor = anchor
        var byDay: [DayIdentity: BodyHistoryDay] = [:]
        for day in days { byDay[day.day] = day }
        self.byDay = byDay
    }

    public static func empty(anchor: DayIdentity) -> BodyHistory { BodyHistory(anchor: anchor, days: []) }

    public func day(_ day: DayIdentity) -> BodyHistoryDay? { byDay[day] }

    /// Every day with at least one value, oldest first.
    public var days: [BodyHistoryDay] { byDay.values.sorted { $0.day.bodyOrdinal < $1.day.bodyOrdinal } }

    public var isEmpty: Bool { byDay.isEmpty }

    /// The civil days from `offset` days before `end` up to `end`, oldest first.
    public static func window(endingOn end: DayIdentity, length: Int) -> [DayIdentity] {
        guard length > 0 else { return [] }
        return (0..<length).reversed().map { end.bodyAdding(days: -$0) }
    }
}

/// Supplies the Body tab's history. The app reads its metric history; the
/// fixtures read `LooprFixtureMetrics`.
public protocol BodyHistoryProviding: Sendable {
    /// History for `BodyHistory.lookbackDays` days before `anchor`, the
    /// anchor, and the day after it.
    func bodyHistory(anchor: DayIdentity) async -> BodyHistory
}

/// The shared fixture story, so the Body fixture's week, load and "vs usual"
/// agree with Today and with the metric pages.
public struct BodyFixtureHistoryProvider: BodyHistoryProviding {
    /// The day the fixture history ends on. Days after it have nothing.
    public let fixtureDay: DayIdentity
    public let hasValues: Bool

    public init(fixtureDay: DayIdentity = BodyFixtures.day, hasValues: Bool = true) {
        self.fixtureDay = fixtureDay
        self.hasValues = hasValues
    }

    public func bodyHistory(anchor: DayIdentity) async -> BodyHistory {
        Self.history(anchor: anchor, fixtureDay: fixtureDay, hasValues: hasValues)
    }

    public static func history(anchor: DayIdentity, fixtureDay: DayIdentity = BodyFixtures.day, hasValues: Bool = true,
                               calendar: Calendar = .current) -> BodyHistory {
        guard hasValues, let end = fixtureDay.bodyDate(calendar: calendar) else { return .empty(anchor: anchor) }
        let count = LooprFixtureMetrics.historyDays + BodyHistory.lookbackDays
        func values(_ id: String) -> [DayIdentity: Double] {
            var result: [DayIdentity: Double] = [:]
            for point in LooprFixtureMetrics.history(id, days: count, endingOn: end, calendar: calendar) {
                result[DayIdentity(bodyDate: point.date, calendar: calendar)] = point.value
            }
            return result
        }
        let strain = values(LooprMetricLinkID.strain)
        let recovery = values(LooprMetricLinkID.recovery)
        let steps = values(LooprMetricLinkID.steps)
        let energy = values(LooprMetricLinkID.activeEnergy)
        let window = BodyHistory.window(endingOn: anchor.bodyAdding(days: 1), length: BodyHistory.lookbackDays + 2)
        let days = window.compactMap { day -> BodyHistoryDay? in
            let value = BodyHistoryDay(day: day, strain: strain[day], recovery: recovery[day], steps: steps[day], activeEnergy: energy[day])
            return value.strain == nil && value.recovery == nil && value.steps == nil && value.activeEnergy == nil ? nil : value
        }
        return BodyHistory(anchor: anchor, days: days)
    }
}

// MARK: Civil day arithmetic

extension DayIdentity {
    /// A day number that orders days and steps across months, years and time
    /// zone changes. Civil dates only; no clock time is involved.
    var bodyOrdinal: Int {
        // Days since 1 March of year 0 (proleptic Gregorian), the usual
        // civil-from-days arithmetic.
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe
    }

    init(bodyOrdinal ordinal: Int) {
        let era = (ordinal >= 0 ? ordinal : ordinal - 146_096) / 146_097
        let doe = ordinal - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let day = doy - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        let year = yoe + era * 400 + (month <= 2 ? 1 : 0)
        self.init(year: year, month: month, day: day)
    }

    /// The civil day `days` after this one (negative for earlier).
    public func bodyAdding(days: Int) -> DayIdentity {
        DayIdentity(bodyOrdinal: bodyOrdinal + days)
    }

    /// Whole civil days from this day to `other`.
    public func bodyDays(to other: DayIdentity) -> Int { other.bodyOrdinal - bodyOrdinal }

    /// Local midnight at the start of this day.
    public func bodyDate(calendar: Calendar = .current) -> Date? {
        calendar.date(from: DateComponents(year: year, month: month, day: day))
    }

    /// The civil day `date` falls on in `calendar`'s time zone.
    public init(bodyDate date: Date, calendar: Calendar = .current) {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: parts.year ?? 1970, month: parts.month ?? 1, day: parts.day ?? 1)
    }
}
