import Foundation
import StorageKit
import XCTest

/// `storage-016-routine` adds the protocol, version and check tables after `storage-015-food-weight`.
final class RoutineMigrationTests: XCTestCase {
    private var urls: [URL] = []

    override func tearDown() {
        for url in urls { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) } }
        urls = []
        super.tearDown()
    }

    private func makeURL() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("routine-migration-\(UUID().uuidString).sqlite")
        urls.append(url)
        return url
    }

    func testMigrationIsRegisteredRightAfterFoodWeight() {
        let identifiers = StorageMigrationHarness.registeredMigrationIdentifiers(applicationVersion: "test")
        XCTAssertEqual(StorageMigrationIdentifier.routine, "storage-016-routine")
        XCTAssertEqual(identifiers.firstIndex(of: "storage-015-food-weight").map { $0 + 1 },
                       identifiers.firstIndex(of: StorageMigrationIdentifier.routine))
    }

    func testADatabaseThatRanMigrationsOneToFifteenGainsTheRoutineTablesAndKeepsItsData() throws {
        let url = makeURL()
        let queue = try DatabaseQueue(path: url.path)
        try StorageMigrations.makeMigrator(applicationVersion: "1.0 (21)").migrate(queue, upTo: "storage-015-food-weight")
        try queue.write { db in
            for table in RoutineStorageSchema.tableNames { XCTAssertFalse(try db.tableExists(table), table) }
            try db.execute(sql: "INSERT INTO food_weight VALUES ('kept-weight', '2026-10-20', 1792000000, X'0102')")
            try db.execute(sql: "INSERT INTO decoded_second(physiological_timestamp, band_counter, absolute_timestamp, local_day, record_version) VALUES (1, 1, 1, '2026-10-20', 24)")
        }
        try queue.close()

        let upgraded = try StorageDatabase(url: url, applicationVersion: "1.0 (22)")
        defer { try? upgraded.databasePool.close() }
        XCTAssertFalse(try upgraded.hasPendingMigrations())
        let metadata = try upgraded.schemaMetadata()
        let routine = try XCTUnwrap(metadata.first { $0.migrationIdentifier == StorageMigrationIdentifier.routine })
        XCTAssertEqual(routine.schemaVersion, "16")
        XCTAssertEqual(routine.applicationVersion, "1.0 (22)")
        try upgraded.read { db in
            for table in RoutineStorageSchema.tableNames { XCTAssertTrue(try db.tableExists(table), "\(table) was not created") }
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM food_weight WHERE id = 'kept-weight'"), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM decoded_second WHERE local_day = '2026-10-20'"), 1)
            let indexes = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name LIKE 'routine_%'")
            XCTAssertTrue(indexes.contains("routine_check_day") && indexes.contains("routine_protocol_one_active"))
        }
    }

    func testChecksAndVersionsFollowTheirProtocolOnDelete() throws {
        let database = try StorageDatabase(url: makeURL(), applicationVersion: "routine-migration")
        defer { try? database.databasePool.close() }
        try database.write { db in
            for id in ["a", "b"] {
                try db.execute(sql: "INSERT INTO routine_protocol VALUES (?, 'Name', 1, 0, X'7B7D')", arguments: [id])
                try db.execute(sql: "INSERT INTO routine_version VALUES (?, 1, 1, X'7B7D')", arguments: [id])
                try db.execute(sql: "INSERT INTO routine_check VALUES (?, 'rule', '2026-10-20', 1, 'kept', 'manual', NULL, 0, 1, NULL)", arguments: [id])
            }
            try db.execute(sql: "DELETE FROM routine_protocol WHERE id = 'a'")
        }
        let counts = try database.tableRowCounts()
        XCTAssertEqual(counts["routine_protocol"], 1)
        XCTAssertEqual(counts["routine_version"], 1)
        XCTAssertEqual(counts["routine_check"], 1)
    }

    func testTheTablesRefuseWhatTheModelNeverWrites() throws {
        let database = try StorageDatabase(url: makeURL(), applicationVersion: "routine-migration")
        defer { try? database.databasePool.close() }
        try database.write { db in
            try db.execute(sql: "INSERT INTO routine_protocol VALUES ('a', 'One', 1, 1, X'7B7D')")
            try db.execute(sql: "INSERT INTO routine_version VALUES ('a', 1, 1, X'7B7D')")
        }
        func fails(_ sql: String, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertThrowsError(try database.write { db in try db.execute(sql: sql) }, sql, file: file, line: line)
        }
        fails("INSERT INTO routine_protocol VALUES ('b', 'Two', 1, 1, X'7B7D')")          // a second active protocol
        fails("INSERT INTO routine_version VALUES ('a', 0, 1, X'7B7D')")                  // version numbers start at 1
        fails("INSERT INTO routine_version VALUES ('a', 1, 2, X'7B7D')")                  // a version number is used once
        fails("UPDATE routine_version SET payload = X'00' WHERE protocol_id = 'a'")       // versions are immutable
        fails("INSERT INTO routine_version VALUES ('missing', 1, 1, X'7B7D')")            // versions belong to a protocol
        fails("INSERT INTO routine_check VALUES ('a', 'r', '2026-10-20', 1, 'late', 'manual', NULL, 0, 1, NULL)")
        fails("INSERT INTO routine_check VALUES ('a', 'r', '2026-10-20', 1, 'kept', 'oracle', NULL, 0, 1, NULL)")
        fails("INSERT INTO routine_check VALUES ('a', 'r', '2026-10-20', 1, 'unknown', 'band', 0, 0, 1, NULL)")
    }

    func testFullAccountDeletionEmptiesTheRoutineTables() throws {
        let database = try StorageDatabase(url: makeURL(), applicationVersion: "routine-migration")
        defer { try? database.databasePool.close() }
        try database.write { db in
            try db.execute(sql: "INSERT INTO routine_protocol VALUES ('a', 'One', 1, 1, X'7B7D')")
            try db.execute(sql: "INSERT INTO routine_version VALUES ('a', 1, 1, X'7B7D')")
            try db.execute(sql: "INSERT INTO routine_check VALUES ('a', 'r', '2026-10-20', 1, 'kept', 'manual', NULL, 0, 1, NULL)")
        }
        XCTAssertEqual(try database.tableRowCounts()["routine_check"], 1)
        try database.deleteAllAccountData()
        let counts = try database.tableRowCounts()
        for table in RoutineStorageSchema.tableNames { XCTAssertEqual(counts[table], 0, table) }
    }

    func testDeletingADayRemovesThatDaysChecksOnly() throws {
        let database = try StorageDatabase(url: makeURL(), applicationVersion: "routine-migration")
        defer { try? database.databasePool.close() }
        try database.write { db in
            try db.execute(sql: "INSERT INTO routine_protocol VALUES ('a', 'One', 1, 1, X'7B7D')")
            try db.execute(sql: "INSERT INTO routine_version VALUES ('a', 1, 1, X'7B7D')")
            for day in ["2026-10-20", "2026-10-21"] {
                try db.execute(sql: "INSERT INTO routine_check VALUES ('a', 'r', ?, 1, 'kept', 'manual', NULL, 0, 1, NULL)", arguments: [day])
            }
        }
        try database.delete(localDay: "2026-10-20")
        XCTAssertEqual(try database.readString(sql: "SELECT local_day FROM routine_check"), "2026-10-21")
        XCTAssertEqual(try database.readInteger(sql: "SELECT COUNT(*) FROM routine_version"), 1)
    }
}
