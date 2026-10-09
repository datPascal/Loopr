import Foundation
import StorageKit
import DomainKit
import TodayKit

/// Writes band-derived day values into `metric_series`.
nonisolated struct MetricSeriesRecorder: Sendable {
    let history: StorageDatabase
    let dates: any DateProviding

    /// Replaces the band values the inputs can speak for on `day`. Failures
    /// are swallowed: history is a by-product and must never fail a
    /// derivation or a screen.
    @discardableResult
    func recordBand(day: DayIdentity, projection: CanonicalDailyProjection, today: TodaySummary?) -> Bool {
        record(day: day, values: BandMetricSeriesMapping.values(projection: projection, today: today),
               ranges: BandMetricSeriesMapping.ranges(projection: projection, today: today))
    }

    @discardableResult
    func record(day: DayIdentity, values: [MetricKey: Double?], ranges: [MetricKey: BandMetricRange] = [:]) -> Bool {
        let localDay = MetricHistoryDays.label(day)
        let stored = values.compactMap { key, value -> StoredMetricSeriesValue? in
            value.map {
                StoredMetricSeriesValue(localDay: localDay, metricKey: key.rawValue, source: .band, value: $0,
                                        low: ranges[key]?.low, high: ranges[key]?.high)
            }
        }
        do {
            try history.replaceMetricSeries(localDay: localDay, source: .band, keys: Set(values.keys.map(\.rawValue)),
                                            with: stored, updatedAt: Int64(dates.now().timeIntervalSince1970))
            return true
        } catch {
            return false
        }
    }
}

/// Held by the screen analytics engine. Empty until the composition installs
/// a recorder, and the Health export engine never gets one, so only days
/// derived in the person's own time zone reach the history.
nonisolated final class MetricHistoryRecorderSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var recorder: MetricSeriesRecorder?

    func install(_ recorder: MetricSeriesRecorder?) { lock.withLock { self.recorder = recorder } }

    var current: MetricSeriesRecorder? { lock.withLock { recorder } }

    func record(day: DayIdentity, projection: CanonicalDailyProjection, today: TodaySummary?) {
        current?.recordBand(day: day, projection: projection, today: today)
    }
}

/// `metric_series.local_day` labels and the dates they stand for.
nonisolated enum MetricHistoryDays {
    static func label(_ day: DayIdentity) -> String {
        String(format: "%04d-%02d-%02d", day.year, day.month, day.day)
    }

    static func label(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func identity(_ date: Date, calendar: Calendar) -> DayIdentity {
        let parts = calendar.dateComponents([.era, .year, .month, .day], from: date)
        return DayIdentity(era: parts.era ?? 1, year: parts.year ?? 0, month: parts.month ?? 1, day: parts.day ?? 1)
    }

    /// The local start of the day a label names, or nil for a malformed label.
    static func date(_ label: String, calendar: Calendar) -> Date? {
        let parts = label.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    static func calendar(_ timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }
}
