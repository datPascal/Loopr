import XCTest
import Foundation
import StorageKit
import DomainKit
import ProfileKit
import HealthKitBridge
import HeartKit
import SleepKit
import TodayKit
import DesignSystem
@testable import Loopr

private struct HistoryTestDate: DateProviding {
    let value: Date
    func now() -> Date { value }
}

@MainActor
final class MetricHistoryTests: XCTestCase {
    private var roots: [URL] = []
    private let utc = TimeZone(secondsFromGMT: 0)!
    /// 2026-09-07 00:00 UTC.
    private let start: Int64 = 1_788_739_200

    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots.removeAll()
        super.tearDown()
    }

    // MARK: Contract

    func testEveryAppleHealthKeyIsAMetricKeyAndSDNNIsNeverRMSSD() {
        for metric in HealthHistoryMetric.allCases {
            XCTAssertNotNil(MetricKey(rawValue: metric.rawValue), metric.rawValue)
        }
        XCTAssertEqual(MetricKey(rawValue: HealthHistoryMetric.sdnn.rawValue), .sdnn)
        XCTAssertEqual(HealthHistoryMapping.metric(for: .heartRateVariabilitySDNN).rawValue, MetricKey.sdnn.rawValue)
        XCTAssertEqual(MetricKey.oxygenSaturation.historyUnit, .percent)
        XCTAssertEqual(MetricKey.sleepDuration.historyUnit, .minutes)
        XCTAssertEqual(MetricKey.strain.historyUnit, .strainScale)
    }

    // MARK: Band mapping

    func testBandMappingCarriesEveryDerivedValueInHistoryUnits() async throws {
        let (history, products) = try databases()
        try seedNight(history, start: start, seconds: 14_401)
        let engine = try makeEngine(history: history, products: products)
        let day = DayIdentity(year: 2026, month: 9, day: 7)
        let read = try await engine.read(day: day)
        let projection = try XCTUnwrap(read)
        let today = try await engine.readToday(day: day)

        let values = BandMetricSeriesMapping.values(projection: projection, today: today)
        XCTAssertEqual(values[.restingHeartRate] ?? nil, 55)
        XCTAssertEqual(values[.rmssd] ?? nil, projection.heart.metric(.rmssd)?.numericValue)
        XCTAssertNotNil(values[.rmssd] ?? nil)
        XCTAssertEqual(values[.sdnn] ?? nil, projection.heart.metric(.sdnn)?.numericValue)
        XCTAssertEqual(values[.respiratoryRate] ?? nil, projection.heart.metric(.respiration)?.numericValue)
        XCTAssertEqual(values[.sleepDuration] ?? nil, projection.sleep.metric("duration")?.numericValue)
        XCTAssertGreaterThan((values[.sleepDuration] ?? nil) ?? 0, 30, "Duration is stored in minutes")
        XCTAssertEqual(values[.stress] ?? nil, projection.stress?.score)
        // Recovery needs earlier nights and two contributors: absent, never zero.
        XCTAssertTrue(values.keys.contains(.recovery))
        XCTAssertNil(values[.recovery] ?? nil)
        // Nothing the derivation does not produce is invented.
        for key in [MetricKey.oxygenSaturation, .skinTemperatureDeviation, .vo2Max, .heartRateDip] {
            XCTAssertNil(values[key] ?? nil, key.rawValue)
        }
        // The surfaces lane now derives these from the recorded HR samples.
        XCTAssertEqual(values[.sleepingHeartRate] ?? nil, 55)
        XCTAssertEqual(values[.maxHeartRate] ?? nil, 55)
        XCTAssertEqual(values[.sleepingHeartRate] ?? nil, projection.heart.metric(.sleepingHeartRate)?.numericValue)
        XCTAssertEqual(values[.maxHeartRate] ?? nil, projection.heart.metric(.maxHeartRate)?.numericValue)
        // Without the display generation, readiness-only keys are left alone.
        let base = BandMetricSeriesMapping.values(projection: projection, today: nil)
        XCTAssertFalse(base.keys.contains(.recovery))
        XCTAssertFalse(base.keys.contains(.sleepConsistency))
    }

    func testDaytimeHeartReadingsWithoutANightStayOutOfHistory() async throws {
        let (history, products) = try databases()
        // A short daytime stretch: no main sleep, so heart values are the
        // captioned daytime fallback.
        try seedNight(history, start: start + 10 * 3_600, seconds: 1_800)
        let engine = try makeEngine(history: history, products: products,
                                    now: Date(timeIntervalSince1970: Double(start + 20 * 3_600)))
        let read = try await engine.read(day: DayIdentity(year: 2026, month: 9, day: 7))
        let projection = try XCTUnwrap(read)
        XCTAssertNil(projection.sleep.mainSleep)
        let values = BandMetricSeriesMapping.values(projection: projection)
        for key in [MetricKey.restingHeartRate, .rmssd, .sdnn, .pNN50, .respiratoryRate, .sleepDuration] {
            XCTAssertTrue(values.keys.contains(key), key.rawValue)
            XCTAssertNil(values[key] ?? nil, key.rawValue)
        }
    }

    // MARK: Write-through

    func testDerivationWritesBandSeriesOnlyForTheEngineWithARecorder() async throws {
        let (history, products) = try databases()
        try seedNight(history, start: start, seconds: 14_401)
        let screens = try makeEngine(history: history, products: products)
        screens.metricHistory.install(MetricSeriesRecorder(history: history, dates: HistoryTestDate(value: now)))
        let export = try makeEngine(history: history, products: products, namespace: "health-export-analytics")
        let day = DayIdentity(year: 2026, month: 9, day: 7)

        _ = try await export.read(day: day)
        XCTAssertEqual(try history.readInteger(sql: "SELECT COUNT(*) FROM metric_series"), 0,
                       "An engine without a recorder never writes history")

        _ = try await screens.readDisplay(day: day)
        let resting = try history.metricSeries(metricKey: "resting_heart_rate", from: "2026-09-07", through: "2026-09-07")
        XCTAssertEqual(resting.map(\.value), [55])
        XCTAssertEqual(resting.map(\.source), [.band])
        let duration = try history.metricSeries(metricKey: "sleep_duration", from: "2026-09-07", through: "2026-09-07")
        XCTAssertEqual(duration.count, 1)
        XCTAssertEqual(try history.readInteger(sql: "SELECT COUNT(*) FROM metric_series WHERE value IS NULL"), 0)
    }

    // MARK: Provider

    func testProviderPrefersBandOverAppleHealthAndReturnsAscendingLocalDays() async throws {
        let (history, products) = try databases()
        let zone = TimeZone(identifier: "Australia/Perth")!
        try history.upsertMetricSeries([
            .init(localDay: "2026-09-20", metricKey: "resting_heart_rate", source: .appleHealth, value: 58),
            .init(localDay: "2026-09-21", metricKey: "resting_heart_rate", source: .appleHealth, value: 57),
            .init(localDay: "2026-09-21", metricKey: "resting_heart_rate", source: .band, value: 53, low: 50, high: 60),
            .init(localDay: "2026-09-23", metricKey: "resting_heart_rate", source: .band, value: 52),
            .init(localDay: "2026-09-24", metricKey: "resting_heart_rate", source: .band, value: 51),
            .init(localDay: "2026-09-10", metricKey: "resting_heart_rate", source: .appleHealth, value: 61)
        ], updatedAt: 1)
        let provider = LooprMetricHistory()
        let engine = try makeEngine(history: history, products: products)
        provider.attach(history: history, analytics: engine, timeZoneProvider: SystemTimeZoneProvider(timeZone: zone),
                        dateProvider: HistoryTestDate(value: now), healthClient: nil, scheduleWork: false)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let endingOn = calendar.date(from: DateComponents(year: 2026, month: 9, day: 23, hour: 21))!
        let points = try await provider.series(for: .restingHeartRate, days: 7, endingOn: endingOn)
        XCTAssertEqual(points.map(\.value), [58, 53, 52], "One point per day, band first, days outside the range omitted")
        XCTAssertEqual(points.map(\.source), [.appleHealth, .band, .band])
        XCTAssertEqual(points.map(\.day), [20, 21, 23].map { calendar.date(from: DateComponents(year: 2026, month: 9, day: $0))! })
        XCTAssertEqual(points[1].low, 50)
        XCTAssertEqual(points[1].high, 60)
        let empty = try await provider.series(for: .vo2Max, days: 365, endingOn: endingOn)
        XCTAssertTrue(empty.isEmpty)
        let none = try await provider.series(for: .restingHeartRate, days: 0, endingOn: endingOn)
        XCTAssertTrue(none.isEmpty)

        try await LooprMetricHistoryDeletion(history: provider).deleteAll()
        let afterDeletion = try await provider.series(for: .restingHeartRate, days: 7, endingOn: endingOn)
        XCTAssertTrue(afterDeletion.isEmpty, "A deletion detaches the history before the file is wiped")
    }

    // MARK: Backfill

    func testBackfillFillsPastDaysOnceAndSkipsDaysThatAlreadyHaveSeries() async throws {
        let (history, products) = try databases()
        // Two nights on two days, recorded before the write-through existed.
        try seedNight(history, start: start, seconds: 14_401)
        try seedNight(history, start: start + 86_400, seconds: 14_401)
        let engine = try makeEngine(history: history, products: products,
                                    now: Date(timeIntervalSince1970: Double(start + 86_400 + 36_000)))
        let recorder = MetricSeriesRecorder(history: history, dates: HistoryTestDate(value: now))
        let backfill = MetricHistoryBackfill(history: history, analytics: engine, recorder: recorder,
            timeZoneProvider: SystemTimeZoneProvider(timeZone: utc),
            dates: HistoryTestDate(value: Date(timeIntervalSince1970: Double(start + 86_400 + 36_000))),
            budget: LooprDerivationBudget(foreground: LooprFixedForegroundState(true)), pause: .zero)

        let pending = try await backfill.pendingDays()
        XCTAssertEqual(pending, [DayIdentity(year: 2026, month: 9, day: 8), DayIdentity(year: 2026, month: 9, day: 7)])
        let written = await backfill.run()
        XCTAssertEqual(written, 2)
        let resting = try history.metricSeries(metricKey: "resting_heart_rate", from: "2026-09-01", through: "2026-09-30")
        XCTAssertEqual(resting.map(\.localDay), ["2026-09-07", "2026-09-08"])
        let remaining = try await backfill.pendingDays()
        XCTAssertTrue(remaining.isEmpty)
        let again = await backfill.run()
        XCTAssertEqual(again, 0)
    }

    func testBackfillDoesNothingOffScreen() async throws {
        let (history, products) = try databases()
        try seedNight(history, start: start, seconds: 14_401)
        let engine = try makeEngine(history: history, products: products)
        let backfill = MetricHistoryBackfill(history: history, analytics: engine,
            recorder: MetricSeriesRecorder(history: history, dates: HistoryTestDate(value: now)),
            timeZoneProvider: SystemTimeZoneProvider(timeZone: utc), dates: HistoryTestDate(value: now),
            budget: LooprDerivationBudget(foreground: LooprFixedForegroundState(false)), pause: .zero)
        let written = await backfill.run()
        XCTAssertEqual(written, 0)
        let derived = await engine.derivationCount
        XCTAssertEqual(derived, 0)
    }

    /// A copy of the phone's history database, when one is on this Mac,
    /// produces band series through the production backfill. The original is
    /// never opened; the copy lives in a temporary directory.
    func testRealDatabaseCopyProducesSeries() async throws {
        let candidates = [ProcessInfo.processInfo.environment["LOOPR_REAL_DB"],
                          "/tmp/loopr-night/device-snapshot/loopr.sqlite"].compactMap { $0 }
        let found = candidates.first { FileManager.default.isReadableFile(atPath: $0) }
        try XCTSkipIf(found == nil, "No real strap database available")
        let source = try XCTUnwrap(found)
        let root = try makeRoot()
        let copy = root.appendingPathComponent("history.sqlite")
        try FileManager.default.copyItem(atPath: source, toPath: copy.path)
        for suffix in ["-wal", "-shm"] where FileManager.default.fileExists(atPath: source + suffix) {
            try? FileManager.default.copyItem(atPath: source + suffix, toPath: copy.path + suffix)
        }
        let history = try StorageDatabase(url: copy)
        let products = try StorageDatabase(url: root.appendingPathComponent("products.sqlite"))
        let zone = TimeZone(identifier: "Australia/Perth")!
        let upper = try XCTUnwrap(try history.readInteger(sql: "SELECT MAX(absolute_timestamp) FROM decoded_second"))
        let clock = HistoryTestDate(value: Date(timeIntervalSince1970: Double(upper) + 60))
        let profile = Profile(id: UUID(), displayName: "Audit", birthYear: 1993, biologicalSex: .male,
                              heightCentimeters: 180, weightKilograms: 78, timezoneIdentifier: zone.identifier,
                              unitSystem: .metric, createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0))
        let engine = try CanonicalDailyAnalytics(history: history, products: products,
            profile: InMemoryProfileRepository(profile: profile), dateProvider: clock,
            timeZoneProvider: SystemTimeZoneProvider(timeZone: zone),
            budget: LooprDerivationBudget(foreground: LooprFixedForegroundState(true)),
            sharedGenerations: LooprSharedGenerationCache())
        let backfill = MetricHistoryBackfill(history: history, analytics: engine,
            recorder: MetricSeriesRecorder(history: history, dates: clock),
            timeZoneProvider: SystemTimeZoneProvider(timeZone: zone), dates: clock,
            budget: LooprDerivationBudget(foreground: LooprFixedForegroundState(true)), pause: .zero)
        let written = await backfill.run()
        XCTAssertGreaterThan(written, 0)
        let rows = try history.read { db in
            try Row.fetchAll(db, sql: "SELECT local_day, metric_key, value FROM metric_series WHERE source = 'band' ORDER BY local_day, metric_key")
        }
        XCTAssertFalse(rows.isEmpty)
        for row in rows {
            print("[metric-history] \(row["local_day"] as String) \(row["metric_key"] as String) = \(row["value"] as Double)")
        }
        XCTAssertTrue(rows.contains { ($0["metric_key"] as String) == "strain" || ($0["metric_key"] as String) == "resting_heart_rate" })
    }

    // MARK: Apple Health store

    func testAppleHealthImportStoreKeepsCursorAndReplacesItsOwnRowsOnly() throws {
        let (history, _) = try databases()
        let store = StorageHealthHistoryImportStore(history: history, dates: HistoryTestDate(value: now))
        XCTAssertNil(try store.importCursor(for: "apple_health.daily.steps"))
        try store.setImportCursor(Date(timeIntervalSince1970: 1_000), for: "apple_health.daily.steps")
        XCTAssertEqual(try store.importCursor(for: "apple_health.daily.steps"), Date(timeIntervalSince1970: 1_000))

        try history.upsertMetricSeries([.init(localDay: "2026-09-02", metricKey: "sdnn", source: .band, value: 70)], updatedAt: 1)
        try store.replaceDailyValues(.sdnn, from: "2026-09-01", through: "2026-09-03", values: [
            HealthHistoryDayValue(metric: .sdnn, localDay: "2026-09-02", value: 45, low: 30, high: 60)
        ])
        let health = try history.metricSeries(metricKey: "sdnn", from: "2026-09-01", through: "2026-09-03", source: .appleHealth)
        XCTAssertEqual(health, [StoredMetricSeriesValue(localDay: "2026-09-02", metricKey: "sdnn", source: .appleHealth,
                                                        value: 45, low: 30, high: 60)])
        XCTAssertEqual(try history.metricSeries(metricKey: "rmssd", from: "2026-09-01", through: "2026-09-03").count, 0,
                       "Apple Health SDNN never lands in RMSSD")
        try store.replaceDailyValues(.sdnn, from: "2026-09-01", through: "2026-09-03", values: [])
        XCTAssertTrue(try history.metricSeries(metricKey: "sdnn", from: "2026-09-01", through: "2026-09-03", source: .appleHealth).isEmpty)
        XCTAssertEqual(try history.metricSeries(metricKey: "sdnn", from: "2026-09-01", through: "2026-09-03", source: .band).count, 1)
    }

    // MARK: Helpers

    private var now: Date { Date(timeIntervalSince1970: Double(start + 36_000)) }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("metric-history-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        roots.append(root)
        return root
    }

    private func databases() throws -> (StorageDatabase, StorageDatabase) {
        let root = try makeRoot()
        return (try StorageDatabase(url: root.appendingPathComponent("history.sqlite")),
                try StorageDatabase(url: root.appendingPathComponent("products.sqlite")))
    }

    private func makeEngine(history: StorageDatabase, products: StorageDatabase, now: Date? = nil,
                            namespace: String = "daily-analytics") throws -> CanonicalDailyAnalytics {
        try CanonicalDailyAnalytics(history: history, products: products, profile: InMemoryProfileRepository(),
            dateProvider: HistoryTestDate(value: now ?? self.now), timeZoneProvider: SystemTimeZoneProvider(timeZone: utc),
            namespace: namespace,
            budget: LooprDerivationBudget(foreground: LooprFixedForegroundState(true)),
            sharedGenerations: LooprSharedGenerationCache())
    }

    /// The phone's ledger shape: one decoded second per row with heart rate
    /// and gravity, and one RR beat per second.
    private func seedNight(_ database: StorageDatabase, start: Int64, seconds: Int, heartRate: Int = 55) throws {
        let label = String(format: "%@", ISO8601DateFormatter.string(from: Date(timeIntervalSince1970: Double(start)),
                                                                      timeZone: utc, formatOptions: [.withFullDate]))
        try database.write { db in
            for index in 0..<seconds {
                let timestamp = start + Int64(index)
                try db.execute(sql: "INSERT INTO decoded_second(physiological_timestamp, band_counter, absolute_timestamp, local_day, record_version, heart_rate, gravity_x, gravity_y, gravity_z) VALUES (?, ?, ?, ?, 24, ?, 0, 0, 1)", arguments: [timestamp, index, timestamp, label, heartRate])
                let id = db.lastInsertedRowID
                let respiratoryInterval = Int((1_000 + 80 * sin(2 * .pi * 0.25 * Double(index))).rounded())
                try db.execute(sql: "INSERT INTO rr_beat(decoded_second_id, beat_index, rr_milliseconds, beat_timestamp_milliseconds) VALUES (?, 0, ?, ?)", arguments: [id, respiratoryInterval, timestamp * 1_000])
            }
        }
    }
}
