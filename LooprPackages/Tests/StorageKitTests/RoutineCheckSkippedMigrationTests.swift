import Foundation
import StorageKit
import XCTest

/// `storage-024-routine-check-skipped` lets `routine_check` hold "Skip today" (ICP R1-HAB-01). A database that already
/// holds checks must open, keep every check as it was, and then accept `skipped` while still refusing unknown states.
final class RoutineCheckSkippedMigrationTests: XCTestCase {
    private var urls: [URL] = []

    override func tearDown() {
        for url in urls {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
        }
        urls = []
        super.tearDown()
    }

    private func makeURL() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("routine-skip-migration-\(UUID().uuidString).sqlite")
        urls.append(url)
        return url
    }

    func testTheMigrationIsRegisteredAfterTheLabComparatorMigration() {
        let identifiers = StorageMigrationHarness.registeredMigrationIdentifiers(applicationVersion: "test")
        XCTAssertEqual(StorageMigrationIdentifier.routineCheckSkipped, "storage-024-routine-check-skipped")
        XCTAssertEqual(identifiers.firstIndex(of: StorageMigrationIdentifier.labValueComparator).map { $0 + 1 },
                       identifiers.firstIndex(of: StorageMigrationIdentifier.routineCheckSkipped))
    }

    func testStoredChecksSurviveAndASkipCanBeStored() throws {
        let url = makeURL()
        let identifiers = StorageMigrationHarness.registeredMigrationIdentifiers(applicationVersion: "1.0 (25)")
        let index = try XCTUnwrap(identifiers.firstIndex(of: StorageMigrationIdentifier.routineCheckSkipped))
        let queue = try DatabaseQueue(path: url.path)
        try StorageMigrations.makeMigrator(applicationVersion: "1.0 (25)").migrate(queue, upTo: identifiers[index - 1])
        try queue.write { db in
            try db.execute(sql: "INSERT INTO routine_protocol VALUES ('p1', 'Mine', 1, 1, x'7B7D')")
            try db.execute(sql: "INSERT INTO routine_version VALUES ('p1', 1, 1, x'7B7D')")
            try db.execute(sql: "INSERT INTO routine_check VALUES ('p1', 'protein', '2023-11-13', 1, 'kept', 'food', 82, 0, 5)")
            try db.execute(sql: "INSERT INTO routine_check VALUES ('p1', 'bed', '2023-11-13', 1, 'unknown', 'band', NULL, 0, 6)")
            XCTAssertThrowsError(try db.execute(sql: """
                INSERT INTO routine_check VALUES ('p1', 'mg', '2023-11-13', 1, 'skipped', 'manual', NULL, 1, 7)
                """), "Before the migration a skip is refused")
        }
        try queue.close()

        let upgraded = try StorageDatabase(url: url, applicationVersion: "1.0 (26)")
        defer { try? upgraded.databasePool.close() }
        XCTAssertFalse(try upgraded.hasPendingMigrations())
        try upgraded.write { db in
            let rows = try Row.fetchAll(db, sql: "SELECT rule_key, state, measured_value, recorded_at FROM routine_check ORDER BY rule_key")
            XCTAssertEqual(rows.map { $0["rule_key"] as String }, ["bed", "protein"])
            XCTAssertEqual(rows.map { $0["state"] as String }, ["unknown", "kept"])
            XCTAssertEqual(rows[1]["measured_value"] as Double?, 82)
            try db.execute(sql: "INSERT INTO routine_check VALUES ('p1', 'mg', '2023-11-13', 1, 'skipped', 'manual', NULL, 1, 7, NULL)")
            XCTAssertThrowsError(try db.execute(sql: """
                INSERT INTO routine_check VALUES ('p1', 'x', '2023-11-13', 1, 'maybe', 'manual', NULL, 1, 7, NULL)
                """))
            XCTAssertThrowsError(try db.execute(sql: """
                INSERT INTO routine_check VALUES ('p1', 'y', '2023-11-13', 1, 'unknown', 'band', 3, 0, 7, NULL)
                """), "An unknown check still holds no value")
            XCTAssertTrue(try db.indexes(on: "routine_check").contains { $0.name == "routine_check_day" })
            try db.execute(sql: "DELETE FROM routine_protocol WHERE id = 'p1'")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM routine_check"), 0, "The cascade still removes checks")
        }
    }
}
