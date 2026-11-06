import Foundation
import StorageKit
import XCTest

/// `storage-019-food-longevity` adds the supplement stack tables. A database that already ran every earlier migration
/// must open, gain the tables and keep its data, and the tables must refuse rows that break the schema's rules.
final class SupplementMigrationTests: XCTestCase {
    private var urls: [URL] = []

    override func tearDown() {
        for url in urls {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
        }
        urls = []
        super.tearDown()
    }

    private func makeURL() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("supplement-migration-\(UUID().uuidString).sqlite")
        urls.append(url)
        return url
    }

    private func openDatabase() throws -> StorageDatabase {
        try StorageDatabase(url: makeURL(), applicationVersion: "supplement-migration-test")
    }

    private func insertItem(_ db: Database, id: String = "i1", lane: String = "supplement", key: String = "d3") throws {
        try db.execute(sql: """
            INSERT INTO supplement_item(id, lane, item_key, sort_order, is_active, start_day, created_at, payload)
            VALUES (?, ?, ?, 0, 1, '2026-01-01', 1, X'7B7D')
            """, arguments: [id, lane, key])
    }

    func testTheMigrationIsRegisteredAfterTheLabsMigrationWithTheAssignedName() {
        let identifiers = StorageMigrationHarness.registeredMigrationIdentifiers(applicationVersion: "test")
        XCTAssertEqual(StorageMigrationIdentifier.foodLongevity, "storage-019-food-longevity")
        let index = identifiers.firstIndex(of: StorageMigrationIdentifier.foodLongevity)
        XCTAssertNotNil(index)
        XCTAssertEqual(identifiers.firstIndex(of: StorageMigrationIdentifier.labs).map { $0 + 1 }, index)
    }

    func testADatabaseThatRanEveryEarlierMigrationGainsTheStackTablesAndKeepsItsData() throws {
        let url = makeURL()
        let identifiers = StorageMigrationHarness.registeredMigrationIdentifiers(applicationVersion: "1.0 (22)")
        let index = try XCTUnwrap(identifiers.firstIndex(of: StorageMigrationIdentifier.foodLongevity))
        let previous = identifiers[index - 1]

        let queue = try DatabaseQueue(path: url.path)
        try StorageMigrations.makeMigrator(applicationVersion: "1.0 (22)").migrate(queue, upTo: previous)
        try queue.write { db in
            XCTAssertFalse(try db.tableExists("supplement_item"))
            try db.execute(sql: "INSERT INTO decoded_second(physiological_timestamp, band_counter, absolute_timestamp, local_day, record_version) VALUES (1, 1, 1, '2026-09-12', 24)")
            try db.execute(sql: "INSERT INTO food_weight(id, local_day, measured_at, payload) VALUES ('w1', '2026-09-12', 1, x'7B7D')")
            try db.execute(sql: "INSERT INTO lab_report(id, collected_at, collected_day, time_zone_identifier, source, created_at) VALUES ('r1', 1, '2026-09-12', 'Europe/Berlin', 'typed', 2)")
        }
        try queue.close()

        let upgraded = try StorageDatabase(url: url, applicationVersion: "1.0 (23)")
        defer { try? upgraded.databasePool.close() }
        XCTAssertFalse(try upgraded.hasPendingMigrations())
        try upgraded.read { db in
            for table in SupplementStorageSchema.tableNames {
                XCTAssertTrue(try db.tableExists(table), "\(table) was not created on upgrade")
            }
            for index in ["supplement_item_order", "supplement_tick_day"] {
                XCTAssertNotNil(try String.fetchOne(db, sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND name = ?", arguments: [index]), index)
            }
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM decoded_second WHERE local_day = '2026-09-12'"), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM food_weight"), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM lab_report"), 1)
            let applied = try String.fetchAll(db, sql: "SELECT migration_identifier FROM storage_schema_metadata")
            XCTAssertTrue(applied.contains("storage-019-food-longevity"))
        }
        XCTAssertTrue(try upgraded.schemaMetadata().contains { $0.migrationIdentifier == StorageMigrationIdentifier.foodLongevity })
    }

    func testEveryRegisteredVersionStillConvergesOnTheCurrentSchema() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("supplement-harness-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let results = try StorageMigrationHarness.verifyAllRegisteredVersions(directory: directory)
        XCTAssertTrue(results.contains { $0.migrationIdentifier == StorageMigrationIdentifier.foodLongevity })
        XCTAssertTrue(results.allSatisfy(\.schemaMatchesCurrent))
    }

    func testTheTablesRefuseRowsThatBreakTheirRules() throws {
        let database = try openDatabase()
        defer { try? database.databasePool.close() }
        XCTAssertThrowsError(try database.write { db in try insertItem(db, lane: "snack") })
        try database.write { db in try insertItem(db) }
        // One key per lane; the other lane may reuse it.
        XCTAssertThrowsError(try database.write { db in try insertItem(db, id: "i2") })
        XCTAssertNoThrow(try database.write { db in try insertItem(db, id: "i3", lane: "medication") })
        XCTAssertThrowsError(try database.write { db in
            try db.execute(sql: "INSERT INTO supplement_item(id, lane, item_key, sort_order, is_active, start_day, created_at, payload) VALUES ('i4', 'supplement', 'x', 0, 2, '2026-01-01', 1, X'7B7D')")
        })
        func tick(item: String, slot: String, state: String, day: String = "2026-10-21") throws {
            try database.write { db in
                try db.execute(sql: "INSERT INTO supplement_tick(item_id, local_day, slot, state, recorded_at) VALUES (?, ?, ?, ?, 1)",
                    arguments: [item, day, slot, state])
            }
        }
        XCTAssertThrowsError(try tick(item: "i1", slot: "noon", state: "taken"))
        XCTAssertThrowsError(try tick(item: "i1", slot: "morning", state: "missed"))
        XCTAssertThrowsError(try tick(item: "nobody", slot: "morning", state: "taken"))
        XCTAssertNoThrow(try tick(item: "i1", slot: "morning", state: "taken"))
        // A dose has one record: a second row for the same item, day and slot is refused, whatever its state.
        XCTAssertThrowsError(try tick(item: "i1", slot: "morning", state: "skipped"))
        XCTAssertNoThrow(try tick(item: "i1", slot: "evening", state: "skipped"))
    }

    func testDeletingAnItemCascadesItsTicks() throws {
        let database = try openDatabase()
        defer { try? database.databasePool.close() }
        try database.write { db in
            try insertItem(db, id: "keep", key: "keep"); try insertItem(db, id: "drop", key: "drop")
            for (item, day, slot) in [("keep", "2026-10-21", "morning"), ("drop", "2026-10-21", "morning"), ("drop", "2026-10-21", "evening")] {
                try db.execute(sql: "INSERT INTO supplement_tick(item_id, local_day, slot, state, recorded_at) VALUES (?, ?, ?, 'taken', 1)",
                    arguments: [item, day, slot])
            }
            try db.execute(sql: "DELETE FROM supplement_item WHERE id = 'drop'")
        }
        XCTAssertEqual(try database.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM supplement_tick") }, 1)
    }

    func testDeleteAllAccountDataEmptiesTheTablesAndDayDeletionKeepsTheItems() throws {
        let database = try openDatabase()
        defer { try? database.databasePool.close() }
        try database.write { db in
            try insertItem(db)
            try db.execute(sql: "INSERT INTO supplement_tick(item_id, local_day, slot, state, recorded_at) VALUES ('i1', '2026-10-21', 'morning', 'taken', 1)")
        }
        let seeded = try database.tableRowCounts()
        for table in SupplementStorageSchema.tableNames { XCTAssertEqual(seeded[table], 1, "\(table) was not seeded") }

        try database.delete(localDay: "2026-10-21")
        let afterDay = try database.tableRowCounts()
        XCTAssertEqual(afterDay["supplement_item"], 1, "an item is not day data")
        XCTAssertEqual(afterDay["supplement_tick"], 0, "a day's ticks go with the day")

        try database.write { db in
            try db.execute(sql: "INSERT INTO supplement_tick(item_id, local_day, slot, state, recorded_at) VALUES ('i1', '2026-10-22', 'morning', 'taken', 1)")
        }
        try database.deleteAllAccountData()
        let after = try database.tableRowCounts()
        for table in SupplementStorageSchema.tableNames { XCTAssertEqual(after[table], 0, "\(table) survived deleteAllAccountData") }
    }

    func testDeleteAllDataEmptiesTheTablesToo() throws {
        let database = try openDatabase()
        defer { try? database.databasePool.close() }
        try database.write { db in
            try insertItem(db)
            try db.execute(sql: "INSERT INTO supplement_tick(item_id, local_day, slot, state, recorded_at) VALUES ('i1', '2026-10-21', 'evening', 'skipped', 1)")
        }
        try database.deleteAllData()
        let after = try database.tableRowCounts()
        for table in SupplementStorageSchema.tableNames { XCTAssertEqual(after[table], 0, "\(table)") }
    }

    func testTheExportCarriesTheTablesAndABackupWithoutThemIsNotAValidRestore() throws {
        let source = try openDatabase()
        defer { try? source.databasePool.close() }
        try source.write { db in
            try insertItem(db)
            try db.execute(sql: "INSERT INTO supplement_tick(item_id, local_day, slot, state, recorded_at, note) VALUES ('i1', '2026-10-21', 'morning', 'taken', 5, 'with food')")
        }
        let exportURL = makeURL()
        try source.export(to: exportURL)
        let exported = try DatabaseQueue(path: exportURL.path)
        try exported.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM supplement_item"), 1)
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT note FROM supplement_tick"), "with food")
        }
        try exported.close()

        let broken = makeURL()
        try source.export(to: broken)
        let queue = try DatabaseQueue(path: broken.path)
        try queue.write { db in try db.execute(sql: "DROP TABLE supplement_tick; DROP TABLE supplement_item;") }
        try queue.close()
        XCTAssertThrowsError(try source.restore(from: broken, applicationVersion: "supplement-migration-test")) { error in
            guard case StorageLifecycleError.missingRequiredTables(let missing) = error else {
                return XCTFail("Expected missingRequiredTables, got \(error)")
            }
            XCTAssertEqual(Set(missing), Set(SupplementStorageSchema.tableNames))
        }
    }
}
