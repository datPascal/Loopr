import Foundation
import StorageKit
import XCTest

/// `storage-022-body-composition` adds the table that holds body fat and lean mass typed next to a weight. A database
/// that already ran every earlier migration must open, gain it and keep its data. The table must refuse numbers
/// outside the entry sheet's ranges, hold no row without a value, and leave with the weight it belongs to.
final class BodyCompositionMigrationTests: XCTestCase {
    private var urls: [URL] = []

    override func tearDown() {
        for url in urls {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
        }
        urls = []
        super.tearDown()
    }

    private func makeURL() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("body-composition-migration-\(UUID().uuidString).sqlite")
        urls.append(url)
        return url
    }

    private func openDatabase() throws -> StorageDatabase {
        try StorageDatabase(url: makeURL(), applicationVersion: "body-composition-migration-test")
    }

    private func insertWeight(_ database: StorageDatabase, id: String, day: String = "2026-10-20") throws {
        try database.write { db in
            try db.execute(sql: "INSERT INTO food_weight(id, local_day, measured_at, payload) VALUES (?, ?, 1, x'7B7D')", arguments: [id, day])
        }
    }

    private func insertComposition(_ database: StorageDatabase, weightID: String, bodyFat: Double?, leanMass: Double?) throws {
        try database.write { db in
            try db.execute(sql: "INSERT INTO body_composition(weight_id, body_fat_percent, lean_mass_kilograms, created_at) VALUES (?, ?, ?, 2)",
                           arguments: [weightID, bodyFat, leanMass])
        }
    }

    func testTheMigrationIsRegisteredAfterTheExperimentsMigration() {
        let identifiers = StorageMigrationHarness.registeredMigrationIdentifiers(applicationVersion: "test")
        XCTAssertEqual(StorageMigrationIdentifier.bodyComposition, "storage-022-body-composition")
        XCTAssertEqual(identifiers.firstIndex(of: StorageMigrationIdentifier.experiments).map { $0 + 1 },
                       identifiers.firstIndex(of: StorageMigrationIdentifier.bodyComposition))
    }

    func testADatabaseThatRanEveryEarlierMigrationGainsTheTableAndKeepsItsData() throws {
        let url = makeURL()
        let identifiers = StorageMigrationHarness.registeredMigrationIdentifiers(applicationVersion: "1.0 (22)")
        let index = try XCTUnwrap(identifiers.firstIndex(of: StorageMigrationIdentifier.bodyComposition))
        let previous = identifiers[index - 1]

        let queue = try DatabaseQueue(path: url.path)
        try StorageMigrations.makeMigrator(applicationVersion: "1.0 (22)").migrate(queue, upTo: previous)
        try queue.write { db in
            XCTAssertFalse(try db.tableExists("body_composition"))
            try db.execute(sql: "INSERT INTO food_weight(id, local_day, measured_at, payload) VALUES ('kept-weight', '2026-10-20', 1, x'7B7D')")
            try db.execute(sql: "INSERT INTO capacity_result(id, test_kind, value, unit, side, recorded_at, time_zone_identifier, source, created_at) VALUES ('kept-grip', 'grip', 50, 'kg', 'left', 1, 'UTC', 'typed', 2)")
        }
        try queue.close()

        let upgraded = try StorageDatabase(url: url, applicationVersion: "1.0 (23)")
        defer { try? upgraded.databasePool.close() }
        XCTAssertFalse(try upgraded.hasPendingMigrations())
        try upgraded.read { db in
            for table in BodyCompositionStorageSchema.tableNames {
                XCTAssertTrue(try db.tableExists(table), "\(table) was not created on upgrade")
            }
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM food_weight WHERE id = 'kept-weight'"), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM capacity_result WHERE id = 'kept-grip'"), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM body_composition"), 0)
            let applied = try String.fetchAll(db, sql: "SELECT migration_identifier FROM storage_schema_metadata")
            XCTAssertTrue(applied.contains("storage-022-body-composition"))
        }
    }

    func testEveryRegisteredVersionStillConvergesOnTheCurrentSchema() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("body-composition-harness-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let results = try StorageMigrationHarness.verifyAllRegisteredVersions(directory: directory)
        XCTAssertTrue(results.contains { $0.migrationIdentifier == StorageMigrationIdentifier.bodyComposition })
        XCTAssertTrue(results.allSatisfy(\.schemaMatchesCurrent))
    }

    func testBodyFatAndLeanMassKeepToTheirRanges() throws {
        let database = try openDatabase()
        defer { try? database.databasePool.close() }
        for (index, value) in [1.9, 75.1, 0, -4].enumerated() {
            try insertWeight(database, id: "bf-\(index)")
            XCTAssertThrowsError(try insertComposition(database, weightID: "bf-\(index)", bodyFat: value, leanMass: nil), "body fat \(value)")
        }
        for (index, value) in [9.9, 200.1, 0].enumerated() {
            try insertWeight(database, id: "lm-\(index)")
            XCTAssertThrowsError(try insertComposition(database, weightID: "lm-\(index)", bodyFat: nil, leanMass: value), "lean mass \(value)")
        }
        try insertWeight(database, id: "edge-low")
        try insertWeight(database, id: "edge-high")
        XCTAssertNoThrow(try insertComposition(database, weightID: "edge-low", bodyFat: 2, leanMass: 10))
        XCTAssertNoThrow(try insertComposition(database, weightID: "edge-high", bodyFat: 75, leanMass: 200))
    }

    func testARowNeedsAtLeastOneValueAndAbsentIsNullNeverZero() throws {
        let database = try openDatabase()
        defer { try? database.databasePool.close() }
        try insertWeight(database, id: "w1")
        XCTAssertThrowsError(try insertComposition(database, weightID: "w1", bodyFat: nil, leanMass: nil))
        XCTAssertNoThrow(try insertComposition(database, weightID: "w1", bodyFat: 21.5, leanMass: nil))
        XCTAssertEqual(try database.readInteger(sql: "SELECT COUNT(*) FROM body_composition WHERE lean_mass_kilograms IS NULL"), 1)
        XCTAssertEqual(try database.readInteger(sql: "SELECT COUNT(*) FROM body_composition WHERE lean_mass_kilograms = 0"), 0)
    }

    func testARowBelongsToOneExistingWeightReading() throws {
        let database = try openDatabase()
        defer { try? database.databasePool.close() }
        XCTAssertThrowsError(try insertComposition(database, weightID: "nobody", bodyFat: 20, leanMass: nil))
        try insertWeight(database, id: "w1")
        XCTAssertNoThrow(try insertComposition(database, weightID: "w1", bodyFat: 20, leanMass: nil))
        XCTAssertThrowsError(try insertComposition(database, weightID: "w1", bodyFat: 21, leanMass: nil), "one row per reading")
    }

    func testDeletingAWeightOrItsDayTakesItsCompositionAndNothingElse() throws {
        let database = try openDatabase()
        defer { try? database.databasePool.close() }
        try insertWeight(database, id: "gone", day: "2026-10-20")
        try insertWeight(database, id: "stays", day: "2026-10-21")
        try insertComposition(database, weightID: "gone", bodyFat: 20, leanMass: 60)
        try insertComposition(database, weightID: "stays", bodyFat: 21, leanMass: 61)

        try database.delete(localDay: "2026-10-20")
        let counts = try database.tableRowCounts()
        XCTAssertEqual(counts["food_weight"], 1)
        XCTAssertEqual(counts["body_composition"], 1)
        XCTAssertEqual(try database.readString(sql: "SELECT weight_id FROM body_composition"), "stays")

        try database.write { db in try db.execute(sql: "DELETE FROM food_weight WHERE id = 'stays'") }
        XCTAssertEqual(try database.tableRowCounts()["body_composition"], 0, "a deleted weight leaves no orphan")
    }

    func testDeleteAllAccountDataEmptiesTheTable() throws {
        let database = try openDatabase()
        defer { try? database.databasePool.close() }
        try insertWeight(database, id: "w1")
        try insertComposition(database, weightID: "w1", bodyFat: 20, leanMass: 60)
        let seeded = try database.tableRowCounts()
        for table in BodyCompositionStorageSchema.tableNames { XCTAssertEqual(seeded[table], 1, "\(table) was not seeded") }

        try database.deleteAllAccountData()
        let after = try database.tableRowCounts()
        for table in BodyCompositionStorageSchema.tableNames { XCTAssertEqual(after[table], 0, "\(table) survived deleteAllAccountData") }
    }

    func testABackupWithoutTheTableIsNotAValidExportOrRestore() throws {
        let source = try openDatabase()
        defer { try? source.databasePool.close() }
        let exportURL = makeURL()
        try source.export(to: exportURL)

        let queue = try DatabaseQueue(path: exportURL.path)
        try queue.write { db in try db.execute(sql: "DROP TABLE body_composition;") }
        try queue.close()

        XCTAssertThrowsError(try source.restore(from: exportURL, applicationVersion: "body-composition-migration-test")) { error in
            guard case StorageLifecycleError.missingRequiredTables(let missing) = error else {
                return XCTFail("Expected missingRequiredTables, got \(error)")
            }
            XCTAssertEqual(Set(missing), Set(BodyCompositionStorageSchema.tableNames))
        }
    }

    func testAnExportedDatabaseRoundTripsItsBodyComposition() throws {
        let source = try openDatabase()
        defer { try? source.databasePool.close() }
        try insertWeight(source, id: "w1")
        try insertComposition(source, weightID: "w1", bodyFat: 21.5, leanMass: 61.2)
        let exportURL = makeURL()
        try source.export(to: exportURL)
        let live = try openDatabase()
        defer { try? live.databasePool.close() }
        let restored = try live.restore(from: exportURL, applicationVersion: "body-composition-migration-test")
        defer { try? restored.databasePool.close() }
        XCTAssertEqual(try restored.tableRowCounts()["body_composition"], 1)
        XCTAssertEqual(try restored.readInteger(sql: "SELECT COUNT(*) FROM body_composition WHERE body_fat_percent = 21.5 AND lean_mass_kilograms = 61.2"), 1)
    }

}
