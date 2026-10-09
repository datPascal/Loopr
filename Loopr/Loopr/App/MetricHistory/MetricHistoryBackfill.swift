import Foundation
import StorageKit
import DomainKit

/// Fills band history for past days that have raw seconds but no stored
/// series yet: the days recorded before this build, and days whose saved
/// generations predate the write-through.
///
/// Bounded on every axis the phone cares about. It only runs while Loopr is
/// on screen, walks at most `lookbackDays`, derives at most
/// `maximumDaysPerPass` days per pass, one at a time through the shared
/// derivation lane, with a pause between days. Each day is attempted at most
/// once per process, so a day that yields nothing is not retried in a loop.
actor MetricHistoryBackfill {
    nonisolated static let lookbackDays = 365
    nonisolated static let maximumDaysPerPass = 14
    nonisolated static let pauseBetweenDays: Duration = .milliseconds(400)

    private let history: StorageDatabase
    private let analytics: CanonicalDailyAnalytics
    private let recorder: MetricSeriesRecorder
    private let timeZoneProvider: any TimeZoneProviding
    private let dates: any DateProviding
    private let budget: LooprDerivationBudget
    private let maximumDaysPerPass: Int
    private let pause: Duration
    private var attempted: Set<String> = []
    private var running = false
    private var stopped = false

    init(history: StorageDatabase, analytics: CanonicalDailyAnalytics, recorder: MetricSeriesRecorder,
         timeZoneProvider: any TimeZoneProviding, dates: any DateProviding,
         budget: LooprDerivationBudget = .shared,
         maximumDaysPerPass: Int = MetricHistoryBackfill.maximumDaysPerPass,
         pause: Duration = MetricHistoryBackfill.pauseBetweenDays) {
        self.history = history
        self.analytics = analytics
        self.recorder = recorder
        self.timeZoneProvider = timeZoneProvider
        self.dates = dates
        self.budget = budget
        self.maximumDaysPerPass = maximumDaysPerPass
        self.pause = pause
    }

    func stop() { stopped = true }

    /// A zone edit changes strain across the 28-day training-load window.
    /// Revisit those days even when a series row exists.
    func rebuildRecentZoneHistory(days: Int = 28) async {
        for _ in 0..<60 where running && !stopped && !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(500))
        }
        guard !running, !stopped, budget.isForegroundNow else { return }
        running = true
        defer { running = false }
        let calendar = MetricHistoryDays.calendar(timeZoneProvider.timeZone)
        let today = calendar.startOfDay(for: dates.now())
        for offset in 0..<days {
            guard !stopped, !Task.isCancelled, budget.isForegroundNow,
                  let date = calendar.date(byAdding: .day, value: -offset, to: today) else { break }
            let day = MetricHistoryDays.identity(date, calendar: calendar)
            if let projection = try? await analytics.read(day: day, reason: "zone-settings") {
                let summary = try? await analytics.readToday(day: day, reason: "zone-settings")
                recorder.recordBand(day: day, projection: projection, today: summary)
            }
            try? await Task.sleep(for: pause)
        }
    }

    /// The days this pass would visit, newest first: every civil day in the
    /// lookback window with at least one recorded second and no band series.
    func pendingDays() throws -> [DayIdentity] {
        let calendar = MetricHistoryDays.calendar(timeZoneProvider.timeZone)
        let bounds = try history.read { db -> (Int64?, Int64?) in
            (try Int64.fetchOne(db, sql: "SELECT MIN(absolute_timestamp) FROM decoded_second"),
             try Int64.fetchOne(db, sql: "SELECT MAX(absolute_timestamp) FROM decoded_second"))
        }
        guard let lower = bounds.0, let upper = bounds.1 else { return [] }
        let now = dates.now()
        let today = calendar.startOfDay(for: now)
        guard let earliestAllowed = calendar.date(byAdding: .day, value: -(Self.lookbackDays - 1), to: today) else { return [] }
        let first = max(earliestAllowed, calendar.startOfDay(for: Date(timeIntervalSince1970: Double(lower))))
        let last = min(today, calendar.startOfDay(for: Date(timeIntervalSince1970: Double(upper))))
        guard first <= last else { return [] }
        let stored = try history.metricSeriesDays(source: .band, from: MetricHistoryDays.label(first, calendar: calendar),
                                                  through: MetricHistoryDays.label(last, calendar: calendar))
        var days: [DayIdentity] = []
        var cursor = last
        while cursor >= first {
            let label = MetricHistoryDays.label(cursor, calendar: calendar)
            if !stored.contains(label), !attempted.contains(label),
               let end = calendar.date(byAdding: .day, value: 1, to: cursor) {
                // The same window a day is derived from: the previous noon
                // through the day's end. An indexed lookup, no scan.
                let start = cursor.addingTimeInterval(-12 * 60 * 60)
                if try history.historicalAnalyticsRevision(from: Int64(start.timeIntervalSince1970),
                                                           to: Int64(end.timeIntervalSince1970)) != 0 {
                    days.append(MetricHistoryDays.identity(cursor, calendar: calendar))
                }
            }
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return days
    }

    /// Returns how many days were written.
    @discardableResult
    func run() async -> Int {
        guard !running, !stopped, budget.isForegroundNow else { return 0 }
        running = true
        defer { running = false }
        guard let days = try? pendingDays() else { return 0 }
        var written = 0
        var visited = 0
        for day in days {
            guard !stopped, !Task.isCancelled, budget.isForegroundNow, visited < maximumDaysPerPass else { break }
            visited += 1
            attempted.insert(MetricHistoryDays.label(day))
            // The display generation carries everything, recovery and sleep
            // consistency included. A day already derived is read back from
            // its saved generation without deriving again.
            guard let projection = try? await analytics.read(day: day, reason: "history-backfill") else { continue }
            let today = try? await analytics.readToday(day: day, reason: "history-backfill")
            guard !stopped else { break }
            if recorder.recordBand(day: day, projection: projection, today: today) { written += 1 }
            try? await Task.sleep(for: pause)
        }
        return written
    }
}
