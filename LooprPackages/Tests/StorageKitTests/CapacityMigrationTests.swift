import Foundation
import StorageKit
import XCTest

/// `storage-020-capacity` adds the capacity result and goal tables. A database that already ran every earlier
/// migration must open, gain them and keep its data, and the tables must refuse rows that break the schema's rules.
final class CapacityMigrationTests: XCTestCase {
    private var urls: [URL] = []

    override func tearDown() {
        for url in urls {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
        }
        urls = []
        super.tearDown()
    }

    private func makeURL() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("capacity-migration-\(UUID().uuidString).sqlite")
        urls.append(url)
        return url
    }

    private func openDatabase() throws -> StorageDatabase {
        try StorageDatabase(url: makeURL(), applicationVersion: "capacity-migration-test")
    }

    private func insertResult(_ database: StorageDatabase, kind: String, unit: String, side: String?, source: String,
                              workout: String? = nil, version: String? = nil, value: Double = 10, id: String = UUID().uuidString) throws {
        try database.write { db in
            try db.execute(sql: """
                INSERT INTO capacity_result(id, test_kind, value, unit, side, recorded_at, time_zone_identifier, source, workout_id, algorithm_version, created_at)
                VALUES (?, ?, ?, ?, ?, 1, 'UTC', ?, ?, ?, 2)
                """, arguments: [id, kind, value, unit, side, source, workout, version])
        }
    }

    func testTheMigrationIsRegisteredAfterTheSupplementsMigration() {
        let identifiers = StorageMigrationHarness.registeredMigrationIdentifiers(applicationVersion: "test")
        XCTAssertEqual(StorageMigrationIdentifier.capacity, "storage-020-capacity")
        XCTAssertEqual(identifiers.firstIndex(of: StorageMigrationIdentifier.foodLongevity).map { $0 + 1 },
                       identifiers.firstIndex(of: StorageMigrationIdentifier.capacity))
    }

    func testADatabaseThatRanEveryEarlierMigrationGainsTheCapacityTablesAndKeepsItsData() throws {
        let url = makeURL()
        let identifiers = StorageMigrationHarness.registeredMigrationIdentifiers(applicationVersion: "1.0 (21)")
        let index = try XCTUnwrap(identifiers.firstIndex(of: StorageMigrationIdentifier.capacity))
        let previous = identifiers[index - 1]

        let queue = try DatabaseQueue(path: url.path)
        try StorageMigrations.makeMigrator(applicationVersion: "1.0 (21)").migrate(queue, upTo: previous)
        try queue.write { db in
            XCTAssertFalse(try db.tableExists("capacity_result"))
            try db.execute(sql: "INSERT INTO decoded_second(physiological_timestamp, band_counter, absolute_timestamp, local_day, record_version) VALUES (1, 1, 1, '2026-09-12', 24)")
            try db.execute(sql: "INSERT INTO lab_clock_result(id, clock_kind, value_text, lab_name, collected_at, time_zone_identifier, created_at) VALUES ('c1', 'grimage', '41', 'Lab', 1, 'UTC', 2)")
        }
        try queue.close()

        let upgraded = try StorageDatabase(url: url, applicationVersion: "1.0 (22)")
        defer { try? upgraded.databasePool.close() }
        XCTAssertFalse(try upgraded.hasPendingMigrations())
        try upgraded.read { db in
            for table in CapacityStorageSchema.tableNames {
                XCTAssertTrue(try db.tableExists(table), "\(table) was not created on upgrade")
            }
            for index in ["capacity_result_kind", "capacity_result_workout"] {
                XCTAssertNotNil(try String.fetchOne(db, sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND name = ?", arguments: [index]), index)
            }
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM decoded_second WHERE local_day = '2026-09-12'"), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM lab_clock_result"), 1)
            let applied = try String.fetchAll(db, sql: "SELECT migration_identifier FROM storage_schema_metadata")
            XCTAssertTrue(applied.contains("storage-020-capacity"))
        }
    }

    func testEveryRegisteredVersionStillConvergesOnTheCurrentSchema() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("capacity-harness-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let results = try StorageMigrationHarness.verifyAllRegisteredVersions(directory: directory)
        XCTAssertTrue(results.contains { $0.migrationIdentifier == StorageMigrationIdentifier.capacity })
        XCTAssertTrue(results.allSatisfy(\.schemaMatchesCurrent))
    }

    func testEachTestKindTakesOnlyItsOwnUnit() throws {
        let database = try openDatabase()
        defer { try? database.databasePool.close() }
        XCTAssertThrowsError(try insertResult(database, kind: "grip", unit: "s", side: "left", source: "typed"))
        XCTAssertThrowsError(try insertResult(database, kind: "dead_hang", unit: "kg", side: nil, source: "timed"))
        XCTAssertThrowsError(try insertResult(database, kind: "swim", unit: "s", side: nil, source: "timed"))
        XCTAssertNoThrow(try insertResult(database, kind: "grip", unit: "kg", side: "left", source: "typed"))
        XCTAssertNoThrow(try insertResult(database, kind: "dead_hang", unit: "s", side: nil, source: "timed"))
        XCTAssertNoThrow(try insertResult(database, kind: "sit_to_stand", unit: "points", side: nil, source: "typed", value: 9.5))
        XCTAssertNoThrow(try insertResult(database, kind: "one_leg_balance", unit: "s", side: "right", source: "timed"))
    }

    func testOnlyGripAndBalanceCarryASide() throws {
        let database = try openDatabase()
        defer { try? database.databasePool.close() }
        XCTAssertThrowsError(try insertResult(database, kind: "grip", unit: "kg", side: nil, source: "typed"))
        XCTAssertThrowsError(try insertResult(database, kind: "one_leg_balance", unit: "s", side: nil, source: "timed"))
        XCTAssertThrowsError(try insertResult(database, kind: "grip", unit: "kg", side: "both", source: "typed"))
        XCTAssertThrowsError(try insertResult(database, kind: "dead_hang", unit: "s", side: "left", source: "timed"))
        XCTAssertThrowsError(try insertResult(database, kind: "sit_to_stand", unit: "points", side: "right", source: "typed"))
    }

    func testEachTestKindTakesOnlyItsOwnSource() throws {
        let database = try openDatabase()
        defer { try? database.databasePool.close() }
        XCTAssertThrowsError(try insertResult(database, kind: "grip", unit: "kg", side: "left", source: "timed"))
        XCTAssertThrowsError(try insertResult(database, kind: "dead_hang", unit: "s", side: nil, source: "typed"))
        XCTAssertThrowsError(try insertResult(database, kind: "sit_to_stand", unit: "points", side: nil, source: "workout"))
        XCTAssertThrowsError(try insertResult(database, kind: "heart_rate_recovery", unit: "bpm", side: nil, source: "typed"))
    }

    func testAWorkoutResultNeedsItsWorkoutAndVersionAndNoOtherResultMayHaveThem() throws {
        let database = try openDatabase()
        defer { try? database.databasePool.close() }
        XCTAssertThrowsError(try insertResult(database, kind: "heart_rate_recovery", unit: "bpm", side: nil, source: "workout"))
        XCTAssertThrowsError(try insertResult(database, kind: "heart_rate_recovery", unit: "bpm", side: nil, source: "workout", workout: "w1"))
        XCTAssertThrowsError(try insertResult(database, kind: "grip", unit: "kg", side: "left", source: "typed", workout: "w1", version: "x"))
        XCTAssertNoThrow(try insertResult(database, kind: "heart_rate_recovery", unit: "bpm", side: nil, source: "workout", workout: "w1", version: "loopr.workout-hrr.1"))
        // One result per workout.
        XCTAssertThrowsError(try insertResult(database, kind: "heart_rate_recovery", unit: "bpm", side: nil, source: "workout", workout: "w1", version: "loopr.workout-hrr.1"))
    }

    func testAGoalNeedsAPositiveValueAndTheTestsOwnUnit() throws {
        let database = try openDatabase()
        defer { try? database.databasePool.close() }
        func insert(kind: String, value: Double, unit: String) throws {
            try database.write { db in
                try db.execute(sql: "INSERT INTO capacity_goal(test_kind, target_value, unit, set_at) VALUES (?, ?, ?, 1)", arguments: [kind, value, unit])
            }
        }
        XCTAssertThrowsError(try insert(kind: "grip", value: 0, unit: "kg"))
        XCTAssertThrowsError(try insert(kind: "grip", value: 30, unit: "s"))
        XCTAssertThrowsError(try insert(kind: "chin_up", value: 3, unit: "reps"))
        XCTAssertNoThrow(try insert(kind: "grip", value: 30, unit: "kg"))
        // One goal per test.
        XCTAssertThrowsError(try insert(kind: "grip", value: 31, unit: "kg"))
    }

    func testDeleteAllAccountDataEmptiesTheCapacityTablesAndDayDeletionLeavesThem() throws {
        let database = try openDatabase()
        defer { try? database.databasePool.close() }
        try insertResult(database, kind: "grip", unit: "kg", side: "left", source: "typed")
        try database.write { db in
            try db.execute(sql: "INSERT INTO capacity_goal(test_kind, target_value, unit, set_at) VALUES ('grip', 30, 'kg', 1)")
        }
        let seeded = try database.tableRowCounts()
        for table in CapacityStorageSchema.tableNames { XCTAssertEqual(seeded[table], 1, "\(table) was not seeded") }

        try database.delete(localDay: "1970-01-01")
        let afterDay = try database.tableRowCounts()
        for table in CapacityStorageSchema.tableNames { XCTAssertEqual(afterDay[table], 1, "\(table) must survive a band day deletion") }

        try database.deleteAllAccountData()
        let after = try database.tableRowCounts()
        for table in CapacityStorageSchema.tableNames { XCTAssertEqual(after[table], 0, "\(table) survived deleteAllAccountData") }
    }

    func testABackupWithoutTheCapacityTablesIsNotAValidExportOrRestore() throws {
        let source = try openDatabase()
        defer { try? source.databasePool.close() }
        let exportURL = makeURL()
        try source.export(to: exportURL)

        let queue = try DatabaseQueue(path: exportURL.path)
        try queue.write { db in try db.execute(sql: "DROP TABLE capacity_result; DROP TABLE capacity_goal;") }
        try queue.close()

        XCTAssertThrowsError(try source.restore(from: exportURL, applicationVersion: "capacity-migration-test")) { error in
            guard case StorageLifecycleError.missingRequiredTables(let missing) = error else {
                return XCTFail("Expected missingRequiredTables, got \(error)")
            }
            XCTAssertEqual(Set(missing), Set(CapacityStorageSchema.tableNames))
        }
    }
}
