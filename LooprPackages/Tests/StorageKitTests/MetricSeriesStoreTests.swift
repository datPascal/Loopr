import Foundation
import StorageKit
import XCTest

final class MetricSeriesStoreTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots.removeAll()
        super.tearDown()
    }

    private func makeURL() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("metric-series-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        roots.append(root)
        return root.appendingPathComponent("history.sqlite")
    }

    private func database() throws -> StorageDatabase {
        try StorageDatabase(url: try makeURL(), applicationVersion: "metric-series-test")
    }

    func testMigrationIsRegisteredAfterTheV24Migration() {
        let identifiers = StorageMigrationHarness.registeredMigrationIdentifiers(applicationVersion: "test")
        XCTAssertEqual(identifiers.last, "storage-009-v24-skin-temperature")
        XCTAssertEqual(identifiers.firstIndex(of: StorageMigrationIdentifier.metricSeriesSource).map { $0 + 1 },
                       identifiers.firstIndex(of: "storage-009-v24-skin-temperature"))
        XCTAssertEqual(identifiers.firstIndex(of: "storage-007-v24-adc-fields").map { $0 + 1 },
                       identifiers.firstIndex(of: StorageMigrationIdentifier.metricSeriesSource))
    }

    func testFreshDatabaseHasSourceColumnsAndMetadata() throws {
        let database = try database()
        let columns = try database.read { db in try db.columns(in: "metric_series").map(\.name) }
        XCTAssertEqual(Set(columns), ["local_day", "metric_key", "source", "value", "low", "high", "updated_at"])
        XCTAssertTrue(try database.schemaMetadata().contains {
            $0.migrationIdentifier == StorageMigrationIdentifier.metricSeriesSource && $0.schemaVersion == "8"
        })
    }

    func testMigrationKeepsLegacyRowsAsBandValues() throws {
        let url = try makeURL()
        let migrator = StorageMigrations.makeMigrator(applicationVersion: "legacy")
        let queue = try DatabaseQueue(path: url.path)
        try migrator.migrate(queue, upTo: "storage-007-v24-adc-fields")
        try queue.write { db in
            try db.execute(sql: "INSERT INTO metric_series(local_day, metric_key, value, updated_at) VALUES ('2026-09-01', 'recovery', 81, 1)")
            try db.execute(sql: "INSERT INTO metric_series(local_day, metric_key, value, updated_at) VALUES ('2026-09-02', 'recovery', NULL, 1)")
        }
        try queue.close()

        let database = try StorageDatabase(url: url, applicationVersion: "migrated")
        let values = try database.metricSeries(metricKey: "recovery", from: "2026-09-01", through: "2026-09-30")
        XCTAssertEqual(values, [StoredMetricSeriesValue(localDay: "2026-09-01", metricKey: "recovery", source: .band, value: 81)])
        XCTAssertEqual(try database.readInteger(sql: "SELECT COUNT(*) FROM metric_series"), 2)
        XCTAssertFalse(try database.hasPendingMigrations())
    }

    func testEveryRegisteredVersionMigratesToTheCurrentSchema() throws {
        let directory = try makeURL().deletingLastPathComponent()
        let verification = try StorageMigrationHarness.verifyAllRegisteredVersions(
            applicationVersion: "harness", directory: directory)
        XCTAssertTrue(verification.contains { $0.migrationIdentifier == StorageMigrationIdentifier.metricSeriesSource })
        XCTAssertTrue(verification.allSatisfy(\.schemaMatchesCurrent))
    }

    func testRoundTripReturnsAscendingDaysInRange() throws {
        let database = try database()
        try database.upsertMetricSeries([
            .init(localDay: "2026-09-03", metricKey: "rmssd", source: .band, value: 41),
            .init(localDay: "2026-09-01", metricKey: "rmssd", source: .band, value: 38, low: 30, high: 50),
            .init(localDay: "2026-08-31", metricKey: "rmssd", source: .band, value: 12),
            .init(localDay: "2026-09-02", metricKey: "sdnn", source: .band, value: 60)
        ], updatedAt: 10)
        let values = try database.metricSeries(metricKey: "rmssd", from: "2026-09-01", through: "2026-09-30")
        XCTAssertEqual(values.map(\.localDay), ["2026-09-01", "2026-09-03"])
        XCTAssertEqual(values.first?.low, 30)
        XCTAssertEqual(values.first?.high, 50)
        XCTAssertEqual(values.map(\.value), [38, 41])
    }

    func testUpsertIsIdempotentAndUpdatesChangedValues() throws {
        let database = try database()
        let value = StoredMetricSeriesValue(localDay: "2026-09-01", metricKey: "strain", source: .band, value: 9.5)
        try database.upsertMetricSeries([value], updatedAt: 10)
        try database.upsertMetricSeries([value], updatedAt: 20)
        XCTAssertEqual(try database.readInteger(sql: "SELECT COUNT(*) FROM metric_series"), 1)
        XCTAssertEqual(try database.readInteger(sql: "SELECT updated_at FROM metric_series"), 10,
                       "An unchanged value must not rewrite the row")
        try database.upsertMetricSeries([.init(localDay: "2026-09-01", metricKey: "strain", source: .band, value: 11)], updatedAt: 30)
        XCTAssertEqual(try database.metricSeries(metricKey: "strain", from: "2026-09-01", through: "2026-09-01").map(\.value), [11])
        XCTAssertEqual(try database.readInteger(sql: "SELECT updated_at FROM metric_series"), 30)
    }

    func testNonFiniteAndMalformedValuesAreNeverStored() throws {
        let database = try database()
        try database.upsertMetricSeries([
            .init(localDay: "2026-09-01", metricKey: "strain", source: .band, value: .nan),
            .init(localDay: "2026-09-01", metricKey: "steps", source: .band, value: .infinity),
            .init(localDay: "2026-9-1", metricKey: "steps", source: .band, value: 100),
            .init(localDay: "2026-09-01", metricKey: "rmssd", source: .band, value: 40, low: .nan)
        ], updatedAt: 1)
        XCTAssertEqual(try database.readInteger(sql: "SELECT COUNT(*) FROM metric_series"), 0)
    }

    func testBandIsPreferredOverAppleHealthForTheSameDay() throws {
        let database = try database()
        try database.upsertMetricSeries([
            .init(localDay: "2026-09-01", metricKey: "resting_heart_rate", source: .appleHealth, value: 58),
            .init(localDay: "2026-09-02", metricKey: "resting_heart_rate", source: .appleHealth, value: 57),
            .init(localDay: "2026-09-02", metricKey: "resting_heart_rate", source: .band, value: 52),
            .init(localDay: "2026-09-03", metricKey: "resting_heart_rate", source: .band, value: 51)
        ], updatedAt: 1)
        let preferred = try database.preferredMetricSeries(metricKey: "resting_heart_rate",
                                                           from: "2026-09-01", through: "2026-09-03")
        XCTAssertEqual(preferred.map(\.localDay), ["2026-09-01", "2026-09-02", "2026-09-03"])
        XCTAssertEqual(preferred.map(\.source), [.appleHealth, .band, .band])
        XCTAssertEqual(preferred.map(\.value), [58, 52, 51])
        let healthOnly = try database.metricSeries(metricKey: "resting_heart_rate", from: "2026-09-01",
                                                   through: "2026-09-03", source: .appleHealth)
        XCTAssertEqual(healthOnly.count, 2)
    }

    func testReplacingADayClearsCoveredKeysThatAreNoLongerPresent() throws {
        let database = try database()
        try database.upsertMetricSeries([
            .init(localDay: "2026-09-01", metricKey: "rmssd", source: .band, value: 40),
            .init(localDay: "2026-09-01", metricKey: "recovery", source: .band, value: 70),
            .init(localDay: "2026-09-01", metricKey: "rmssd", source: .appleHealth, value: 44)
        ], updatedAt: 1)
        try database.replaceMetricSeries(localDay: "2026-09-01", source: .band, keys: ["rmssd", "strain"],
            with: [.init(localDay: "2026-09-01", metricKey: "strain", source: .band, value: 8)], updatedAt: 2)
        let band = try database.metricSeries(metricKey: "rmssd", from: "2026-09-01", through: "2026-09-01", source: .band)
        XCTAssertTrue(band.isEmpty, "A covered key without a value is removed")
        XCTAssertEqual(try database.metricSeries(metricKey: "recovery", from: "2026-09-01", through: "2026-09-01").count, 1,
                       "Keys outside the covered set are untouched")
        XCTAssertEqual(try database.metricSeries(metricKey: "rmssd", from: "2026-09-01", through: "2026-09-01", source: .appleHealth).count, 1,
                       "Another source is untouched")
        XCTAssertEqual(try database.metricSeries(metricKey: "strain", from: "2026-09-01", through: "2026-09-01").map(\.value), [8])
    }

    func testReplacingARangeDropsDaysTheSourceNoLongerHas() throws {
        let database = try database()
        try database.upsertMetricSeries([
            .init(localDay: "2026-08-30", metricKey: "steps", source: .appleHealth, value: 1_000),
            .init(localDay: "2026-09-01", metricKey: "steps", source: .appleHealth, value: 2_000),
            .init(localDay: "2026-09-02", metricKey: "steps", source: .appleHealth, value: 3_000),
            .init(localDay: "2026-09-02", metricKey: "steps", source: .band, value: 2_900)
        ], updatedAt: 1)
        try database.replaceMetricSeries(metricKey: "steps", source: .appleHealth, from: "2026-09-01", through: "2026-09-03",
            with: [.init(localDay: "2026-09-03", metricKey: "steps", source: .appleHealth, value: 4_000)], updatedAt: 2)
        let health = try database.metricSeries(metricKey: "steps", from: "2026-08-01", through: "2026-09-30", source: .appleHealth)
        XCTAssertEqual(health.map(\.localDay), ["2026-08-30", "2026-09-03"])
        XCTAssertEqual(try database.metricSeries(metricKey: "steps", from: "2026-09-02", through: "2026-09-02", source: .band).count, 1)
    }

    func testSeriesDaysAndSourceDeletion() throws {
        let database = try database()
        try database.upsertMetricSeries([
            .init(localDay: "2026-09-01", metricKey: "steps", source: .band, value: 1),
            .init(localDay: "2026-09-01", metricKey: "strain", source: .band, value: 2),
            .init(localDay: "2026-09-04", metricKey: "strain", source: .band, value: 2),
            .init(localDay: "2026-09-02", metricKey: "steps", source: .appleHealth, value: 1)
        ], updatedAt: 1)
        XCTAssertEqual(try database.metricSeriesDays(source: .band, from: "2026-09-01", through: "2026-09-03"), ["2026-09-01"])
        try database.deleteMetricSeries(source: .appleHealth)
        XCTAssertEqual(try database.readInteger(sql: "SELECT COUNT(*) FROM metric_series WHERE source = 'apple_health'"), 0)
        XCTAssertEqual(try database.readInteger(sql: "SELECT COUNT(*) FROM metric_series WHERE source = 'band'"), 3)
    }

    func testHealthImportCursorRoundTrip() throws {
        let database = try database()
        XCTAssertNil(try database.healthImportCursor(source: "apple_health.daily.steps"))
        try database.setHealthImportCursor(Data([1, 2]), source: "apple_health.daily.steps", updatedAt: 1)
        try database.setHealthImportCursor(Data([3]), source: "apple_health.daily.steps", updatedAt: 2)
        try database.setHealthImportCursor(Data([4]), source: "other", updatedAt: 2)
        XCTAssertEqual(try database.healthImportCursor(source: "apple_health.daily.steps"), Data([3]))
        try database.removeHealthImportCursors(prefix: "apple_health.")
        XCTAssertNil(try database.healthImportCursor(source: "apple_health.daily.steps"))
        XCTAssertEqual(try database.healthImportCursor(source: "other"), Data([4]))
    }

    func testDayDeletionRemovesSeriesRowsForThatDay() throws {
        let database = try database()
        try database.upsertMetricSeries([
            .init(localDay: "2024-01-02", metricKey: "steps", source: .band, value: 1),
            .init(localDay: "2024-01-02", metricKey: "steps", source: .appleHealth, value: 1),
            .init(localDay: "2024-01-03", metricKey: "steps", source: .band, value: 1)
        ], updatedAt: 1)
        try database.delete(localDay: "2024-01-02")
        XCTAssertEqual(try database.readInteger(sql: "SELECT COUNT(*) FROM metric_series"), 1,
                       "Deleting a day removes that day's values from every source")
    }
}
