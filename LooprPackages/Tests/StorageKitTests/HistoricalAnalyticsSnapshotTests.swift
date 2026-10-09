import XCTest
import Foundation
@testable import StorageKit

final class HistoricalAnalyticsSnapshotTests: XCTestCase {
    func testUpgradeRecoversRRFromExistingV24RawRecords() throws {
        let (database, url) = try HistoricalTestDatabase.open("analytics-backfill")
        defer { HistoricalTestDatabase.remove(url) }
        try database.write { db in
            for table in ["decoded_second", "rr_beat"] {
                for operation in ["insert", "update", "delete"] {
                    try db.execute(sql: "DROP TRIGGER analytics_revision_\(table)_\(operation)")
                }
            }
            try db.execute(sql: "DROP TABLE analytics_input_revision")
            try db.execute(sql: "DROP TABLE analytics_range_revision")
            for migration in ["storage-005-analytics-revision", "storage-006-analytics-range-revision"] {
                try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = ?", arguments: [migration])
                try db.execute(sql: "DELETE FROM storage_schema_metadata WHERE migration_identifier = ?", arguments: [migration])
            }
        }
        var raw = Data(repeating: 0, count: 96)
        raw[0] = 0x2f; raw[1] = 24; raw[18] = 2
        raw[19] = 0xe8; raw[20] = 3; raw[21] = 0xd4; raw[22] = 3
        try database.replaceHistoricalSecond(StoredHistoricalRecord(physiologicalTimestamp: 1_788_739_200, bandCounter: 1,
            localDay: "2026-09-07", version: 24, heartRate: 60, rawPayload: raw))
        try database.databasePool.close()
        let reopened = try StorageDatabase(url: url)
        defer { try? reopened.databasePool.close() }
        let stored = try reopened.storedHistoricalSecond(physiologicalTimestamp: 1_788_739_200)
        XCTAssertEqual(stored?.rrBeats.map(\.intervalMilliseconds), [1_000, 980])
        XCTAssertEqual(stored?.rrBeats.map(\.timestampMilliseconds), [1_788_739_200_000, 1_788_739_200_000])
    }

    func testRangeIsHalfOpenAndRRUpdatesInvalidateOnlyAffectedUTCWindows() throws {
        let (database, url) = try HistoricalTestDatabase.open("analytics-range")
        defer { try? database.databasePool.close(); HistoricalTestDatabase.remove(url) }
        let base: Int64 = 1_788_739_200
        let first = StoredHistoricalRecord(physiologicalTimestamp: base, bandCounter: 1, localDay: "2026-09-07", heartRate: 60,
            rrBeats: [RRBeat(index: 0, intervalMilliseconds: 1_000, timestampMilliseconds: base * 1_000)])
        try database.replaceHistoricalSecond(first)
        let revision = try database.historicalAnalyticsRevision(from: base, to: base + 86_400)
        try database.replaceHistoricalSecond(StoredHistoricalRecord(physiologicalTimestamp: base + 172_800, bandCounter: 2, localDay: "2026-09-09", heartRate: 65))
        XCTAssertEqual(try database.historicalAnalyticsRevision(from: base, to: base + 86_400), revision)
        XCTAssertEqual(try database.historicalAnalyticsSnapshot(from: base, to: base + 172_800).records.count, 1)
        try database.write { db in try db.execute(sql: "UPDATE rr_beat SET rr_milliseconds = 980") }
        let updated = try database.historicalAnalyticsSnapshot(from: base, to: base + 86_400)
        XCTAssertGreaterThan(updated.revision, revision)
        XCTAssertEqual(updated.records.first?.rrBeats.first?.intervalMilliseconds, 980)
        try database.deleteAllAccountData()
        XCTAssertTrue(try database.historicalAnalyticsSnapshot(from: base, to: base + 86_400).records.isEmpty)
        XCTAssertGreaterThan(try database.historicalAnalyticsRevision(), updated.revision)
    }

    func testAWindowWithNoRecordedDayKeepsOneRevisionWhileOtherDaysGrow() throws {
        let (database, url) = try HistoricalTestDatabase.open("analytics-empty-window")
        defer { try? database.databasePool.close(); HistoricalTestDatabase.remove(url) }
        let base: Int64 = 1_788_739_200
        try database.replaceHistoricalSecond(StoredHistoricalRecord(physiologicalTimestamp: base, bandCounter: 1,
            localDay: "2026-09-07", heartRate: 60))
        // A derived day is keyed by the revision of the seven days before it,
        // which on a new account hold nothing. A second landing anywhere else
        // must not move that revision, or nothing derived ever survives a live
        // sync and every screen re-derives the day it opens.
        XCTAssertEqual(try database.historicalAnalyticsRevision(from: base - 7 * 86_400, to: base), 0)
        try database.replaceHistoricalSecond(StoredHistoricalRecord(physiologicalTimestamp: base + 1, bandCounter: 2,
            localDay: "2026-09-07", heartRate: 61))
        XCTAssertEqual(try database.historicalAnalyticsRevision(from: base - 7 * 86_400, to: base), 0)
        XCTAssertGreaterThan(try database.historicalAnalyticsRevision(from: base, to: base + 86_400), 0)
    }
}

private enum HistoricalTestDatabase {
    static func open(_ name: String) throws -> (StorageDatabase, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent(name + ".sqlite")
        return (try StorageDatabase(url: url), url)
    }
    static func remove(_ url: URL) { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
}
