import Foundation
import StorageKit
import DomainKit
import HeartKit
import HealthKitBridge
#if canImport(UIKit)
import UIKit
#endif

/// The app's metric history: the provider every detail screen reads, plus the
/// work that fills it (band write-through, the band backfill and the Apple
/// Health import).
///
/// One per process. The product composition attaches it to the history
/// database once that is open; until then, and after a data deletion, every
/// series is empty, which screens render as an honest empty state.
nonisolated final class LooprMetricHistory: MetricHistoryProviding, @unchecked Sendable {
    static let shared = LooprMetricHistory()

    /// How long after launch the background work waits, so opening the app
    /// never competes with it.
    static let launchDelay: Duration = .seconds(8)
    /// The Apple Health import re-reads recent days at most this often when
    /// Loopr comes back on screen.
    static let healthImportInterval: TimeInterval = 6 * 60 * 60

    private struct Attachment {
        let generation: Int
        let history: StorageDatabase
        let timeZoneProvider: any TimeZoneProviding
        let dates: any DateProviding
        let analytics: CanonicalDailyAnalytics
        let backfill: MetricHistoryBackfill
        let importer: HealthHistoryImporter?
    }

    private let lock = NSLock()
    private var attachment: Attachment?
    private var generation = 0
    private var lastHealthImport: Date?
    private var activeObserver: (any NSObjectProtocol)?
    private var launchTask: Task<Void, Never>?

    init() {}

    // MARK: Composition

    /// Connects the history to an opened history database and the screen
    /// analytics engine. `scheduleWork` starts the launch pass and the
    /// on-screen refreshes; tests pass false.
    func attach(history: StorageDatabase, analytics: CanonicalDailyAnalytics,
                timeZoneProvider: any TimeZoneProviding, dateProvider: any DateProviding,
                healthClient: (any HealthHistoryQueryClient)? = MetricHistoryHealth.liveClient(),
                healthPreferences: SQLiteHealthSyncStore? = nil,
                scheduleWork: Bool) {
        let recorder = MetricSeriesRecorder(history: history, dates: dateProvider)
        analytics.metricHistory.install(recorder)
        let backfill = MetricHistoryBackfill(history: history, analytics: analytics, recorder: recorder,
                                             timeZoneProvider: timeZoneProvider, dates: dateProvider)
        let importer = healthClient.map {
            HealthHistoryImporter(client: $0,
                store: StorageHealthHistoryImportStore(history: history, dates: dateProvider),
                calendar: MetricHistoryDays.calendar(timeZoneProvider.timeZone),
                excludedBundlePrefixes: MetricHistoryHealth.ownBundlePrefixes,
                mayImport: {
                    guard let healthPreferences else { return true }
                    return (try? healthPreferences.preferences().enabled) ?? false
                },
                mayRead: { quantity in
                    guard let preferences = try? healthPreferences?.preferences() else { return healthPreferences == nil }
                    if let quantity { return !preferences.disabledRead.contains(quantity) }
                    return preferences.sleepReadEnabled
                })
        }
        let previous: Attachment? = lock.withLock {
            generation += 1
            let old = attachment
            attachment = Attachment(generation: generation, history: history, timeZoneProvider: timeZoneProvider,
                                    dates: dateProvider, analytics: analytics, backfill: backfill, importer: importer)
            launchTask?.cancel()
            launchTask = nil
            return old
        }
        if let previous { Task { await Self.stop(previous) } }
        guard scheduleWork else { return }
        observeForeground()
        let task = Task(priority: .utility) { [weak self] in
            try? await Task.sleep(for: Self.launchDelay)
            guard !Task.isCancelled else { return }
            await self?.refresh(forceHealthImport: false)
        }
        lock.withLock { launchTask = task }
    }

    /// Stops all history work and forgets the database. Called before a data
    /// deletion wipes the history file, so nothing writes after it.
    func detach() async {
        let previous: Attachment? = lock.withLock {
            generation += 1
            let old = attachment
            attachment = nil
            launchTask?.cancel()
            launchTask = nil
            lastHealthImport = nil
            return old
        }
        if let previous { await Self.stop(previous) }
    }

    private static func stop(_ attachment: Attachment) async {
        await attachment.backfill.stop()
        await attachment.importer?.stop()
    }

    // MARK: Work

    /// The person just connected Apple Health: import now.
    func appleHealthConnected() async {
        await importAppleHealth(force: true)
    }

    /// The launch and on-screen pass: the Apple Health import when it is due,
    /// then one bounded backfill pass.
    func refresh(forceHealthImport: Bool) async {
        await importAppleHealth(force: forceHealthImport)
        guard let current = lock.withLock({ attachment }) else { return }
        await current.backfill.run()
    }

    func rebuildZoneHistory() async {
        guard let current = lock.withLock({ attachment }) else { return }
        await current.backfill.rebuildRecentZoneHistory()
        NotificationCenter.default.post(name: looprHeartZoneHistoryUpdated, object: nil)
    }

    private func importAppleHealth(force: Bool) async {
        guard let current = lock.withLock({ attachment }), let importer = current.importer else { return }
        let now = current.dates.now()
        let due: Bool = lock.withLock {
            guard force || lastHealthImport.map({ now.timeIntervalSince($0) >= Self.healthImportInterval }) ?? true else { return false }
            lastHealthImport = now
            return true
        }
        guard due else { return }
        let report = await importer.importHistory(now: now)
        // Nothing was read before the person answered the request, so the
        // next launch or connection tries again.
        if report?.skippedForAccess == true { lock.withLock { lastHealthImport = nil } }
    }

    private func observeForeground() {
        #if canImport(UIKit)
        lock.withLock {
            guard activeObserver == nil else { return }
            activeObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil
            ) { [weak self] _ in
                guard let self else { return }
                Task(priority: .utility) { await self.refresh(forceHealthImport: false) }
            }
        }
        #endif
    }

    // MARK: MetricHistoryProviding

    func series(for key: MetricKey, days: Int, endingOn: Date) async throws -> [MetricHistoryPoint] {
        guard days > 0, let current = lock.withLock({ attachment }) else { return [] }
        return try await Self.read(key: key, days: days, endingOn: endingOn, history: current.history,
                                   timeZone: current.timeZoneProvider.timeZone)
    }

    func skinTemperature(endingOn: Date) async throws -> HeartSkinTemperatureVital? {
        guard let current = lock.withLock({ attachment }) else { return nil }
        let calendar = MetricHistoryDays.calendar(current.timeZoneProvider.timeZone)
        let parts = calendar.dateComponents([.era, .year, .month, .day], from: endingOn)
        let day = DayIdentity(era: parts.era ?? 1, year: parts.year ?? 0, month: parts.month ?? 0, day: parts.day ?? 0)
        return try await current.analytics.readDisplay(day: day, reason: "temperature-detail")?.projection.heart.vitals?.skinTemperature
    }

    /// Runs off the main actor: a year of one key is a single indexed read.
    @concurrent
    private static func read(key: MetricKey, days: Int, endingOn: Date, history: StorageDatabase,
                             timeZone: TimeZone) async throws -> [MetricHistoryPoint] {
        let calendar = MetricHistoryDays.calendar(timeZone)
        let last = calendar.startOfDay(for: endingOn)
        guard let first = calendar.date(byAdding: .day, value: -(days - 1), to: last) else { return [] }
        let rows = try history.preferredMetricSeries(metricKey: key.rawValue,
            from: MetricHistoryDays.label(first, calendar: calendar),
            through: MetricHistoryDays.label(last, calendar: calendar),
            preference: key.historySourcePreference)
        return rows.compactMap { row in
            guard let day = MetricHistoryDays.date(row.localDay, calendar: calendar) else { return nil }
            return MetricHistoryPoint(day: day, value: row.value, source: MetricSampleSource(row.source),
                                      low: row.low, high: row.high)
        }
    }
}

nonisolated extension MetricKey {
    /// Which source wins when both have a value for the same day. The band
    /// wins everywhere, then an imported WHOOP export, then Apple Health. VO2
    /// max is the exception: it may only come from Apple Health.
    /// Older builds stored a band-derived estimate; excluding `.band` also
    /// hides those rows before a fresh derivation clears them.
    var historySourcePreference: [StoredMetricSeriesSource] {
        switch self {
        case .vo2Max: [.appleHealth]
        case .oxygenSaturation: [.whoopExport, .appleHealth]
        default: [.band, .whoopExport, .appleHealth]
        }
    }
}

nonisolated extension MetricSampleSource {
    init(_ source: StoredMetricSeriesSource) {
        switch source {
        case .band: self = .band
        case .appleHealth: self = .appleHealth
        case .whoopExport: self = .whoopExport
        }
    }
}

/// Stops the history work before a data deletion wipes the history file.
nonisolated struct LooprMetricHistoryDeletion: PersistentDataDeletionDeleter {
    let storeName = "metric-history.runtime"
    let history: LooprMetricHistory

    func deleteAll() async throws {
        await history.detach()
    }
}

/// Apple Health pieces of the metric history.
nonisolated enum MetricHistoryHealth {
    /// Loopr's own bundle and its extensions. Their samples in Apple Health
    /// are Loopr's exports and are never imported back.
    static var ownBundlePrefixes: [String] {
        [Bundle.main.bundleIdentifier ?? "com.loopr.ios", "com.loopr.ios"].reduce(into: []) { result, prefix in
            if !result.contains(prefix) { result.append(prefix) }
        }
    }

    static func liveClient() -> (any HealthHistoryQueryClient)? {
        #if canImport(HealthKit)
        LiveHealthHistoryClient()
        #else
        nil
        #endif
    }
}

/// Keeps Apple Health import progress in `health_import_cursor` and the
/// imported days in `metric_series` with source `apple_health`.
nonisolated struct StorageHealthHistoryImportStore: HealthHistoryImportStore {
    let history: StorageDatabase
    let dates: any DateProviding

    private struct Cursor: Codable { let through: TimeInterval }

    func importCursor(for key: String) throws -> Date? {
        guard let data = try history.healthImportCursor(source: key),
              let cursor = try? JSONDecoder().decode(Cursor.self, from: data) else { return nil }
        return Date(timeIntervalSince1970: cursor.through)
    }

    func setImportCursor(_ date: Date, for key: String) throws {
        let data = try JSONEncoder().encode(Cursor(through: date.timeIntervalSince1970))
        try history.setHealthImportCursor(data, source: key, updatedAt: Int64(dates.now().timeIntervalSince1970))
    }

    func replaceDailyValues(_ metric: HealthHistoryMetric, from lowerDay: String, through upperDay: String,
                            values: [HealthHistoryDayValue]) throws {
        try history.replaceMetricSeries(metricKey: metric.rawValue, source: .appleHealth,
            from: lowerDay, through: upperDay,
            with: values.map {
                StoredMetricSeriesValue(localDay: $0.localDay, metricKey: $0.metric.rawValue, source: .appleHealth,
                                        value: $0.value, low: $0.low, high: $0.high)
            },
            updatedAt: Int64(dates.now().timeIntervalSince1970))
    }
}
