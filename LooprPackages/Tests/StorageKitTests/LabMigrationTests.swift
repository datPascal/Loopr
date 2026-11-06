import Foundation
import StorageKit
import XCTest

/// `storage-017-labs` adds the blood test tables. A database that already ran every earlier migration must open,
/// gain the tables and keep its data, and the tables must refuse rows that break the schema's rules.
final class LabMigrationTests: XCTestCase {
    private var urls: [URL] = []

    override func tearDown() {
        for url in urls {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
        }
        urls = []
        super.tearDown()
    }

    private func makeURL() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lab-migration-\(UUID().uuidString).sqlite")
        urls.append(url)
        return url
    }

    private func openDatabase() throws -> StorageDatabase {
        try StorageDatabase(url: makeURL(), applicationVersion: "lab-migration-test")
    }

    private func insertReport(_ db: Database, id: String = "r1") throws {
        try db.execute(sql: """
            INSERT INTO lab_report(id, collected_at, collected_day, time_zone_identifier, source, created_at)
            VALUES (?, 1, '2026-09-12', 'Europe/Berlin', 'typed', 2)
            """, arguments: [id])
    }

    func testTheMigrationIsRegisteredAfterTheFoodWeightMigration() {
        let identifiers = StorageMigrationHarness.registeredMigrationIdentifiers(applicationVersion: "test")
        XCTAssertEqual(StorageMigrationIdentifier.labs, "storage-017-labs")
        let labs = identifiers.firstIndex(of: StorageMigrationIdentifier.labs)
        XCTAssertNotNil(labs)
        XCTAssertLessThan(identifiers.firstIndex(of: StorageMigrationIdentifier.foodWeight) ?? .max, labs ?? 0)
    }

    func testADatabaseThatRanEveryEarlierMigrationGainsTheLabTablesAndKeepsItsData() throws {
        let url = makeURL()
        let identifiers = StorageMigrationHarness.registeredMigrationIdentifiers(applicationVersion: "1.0 (21)")
        let labsIndex = try XCTUnwrap(identifiers.firstIndex(of: StorageMigrationIdentifier.labs))
        let previous = identifiers[labsIndex - 1]

        let queue = try DatabaseQueue(path: url.path)
        try StorageMigrations.makeMigrator(applicationVersion: "1.0 (21)").migrate(queue, upTo: previous)
        try queue.write { db in
            XCTAssertFalse(try db.tableExists("lab_report"))
            try db.execute(sql: "INSERT INTO decoded_second(physiological_timestamp, band_counter, absolute_timestamp, local_day, record_version) VALUES (1, 1, 1, '2026-09-12', 24)")
            try db.execute(sql: "INSERT INTO food_weight(id, local_day, measured_at, payload) VALUES ('w1', '2026-09-12', 1, x'7B7D')")
        }
        try queue.close()

        let upgraded = try StorageDatabase(url: url, applicationVersion: "1.0 (22)")
        defer { try? upgraded.databasePool.close() }
        XCTAssertFalse(try upgraded.hasPendingMigrations())
        try upgraded.read { db in
            for table in LabStorageSchema.tableNames {
                XCTAssertTrue(try db.tableExists(table), "\(table) was not created on upgrade")
            }
            for index in ["lab_value_report", "lab_value_marker", "lab_report_collected", "lab_clock_result_collected"] {
                XCTAssertNotNil(try String.fetchOne(db, sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND name = ?", arguments: [index]), index)
            }
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM decoded_second WHERE local_day = '2026-09-12'"), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM food_weight"), 1)
            let applied = try String.fetchAll(db, sql: "SELECT migration_identifier FROM storage_schema_metadata")
            XCTAssertTrue(applied.contains("storage-017-labs"))
        }
    }

    func testEveryRegisteredVersionStillConvergesOnTheCurrentSchema() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lab-harness-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let results = try StorageMigrationHarness.verifyAllRegisteredVersions(directory: directory)
        XCTAssertTrue(results.contains { $0.migrationIdentifier == StorageMigrationIdentifier.labs })
        XCTAssertTrue(results.allSatisfy(\.schemaMatchesCurrent))
    }

    func testAValueNeedsExactlyOneOfMarkerKeyOrOtherName() throws {
        let database = try openDatabase()
        defer { try? database.databasePool.close() }
        try database.write { db in try insertReport(db) }
        func insert(marker: String?, other: String?) throws {
            try database.write { db in
                try db.execute(sql: "INSERT INTO lab_value(id, report_id, position, marker_key, other_name, value_text, source) VALUES (?, 'r1', 0, ?, ?, '1', 'typed')",
                    arguments: [UUID().uuidString, marker, other])
            }
        }
        XCTAssertThrowsError(try insert(marker: nil, other: nil))
        XCTAssertThrowsError(try insert(marker: "apob", other: "Apo B"))
        XCTAssertNoThrow(try insert(marker: "apob", other: nil))
        XCTAssertNoThrow(try insert(marker: nil, other: "Vitamin B12"))
    }

    func testOnlyAScannedValueCanCarryAConfidenceOrAReviewFlag() throws {
        let database = try openDatabase()
        defer { try? database.databasePool.close() }
        try database.write { db in try insertReport(db) }
        func insert(source: String, confidence: Double?, review: Int) throws {
            try database.write { db in
                try db.execute(sql: "INSERT INTO lab_value(id, report_id, position, marker_key, value_text, source, scan_confidence, needs_review) VALUES (?, 'r1', 0, 'apob', '1', ?, ?, ?)",
                    arguments: [UUID().uuidString, source, confidence, review])
            }
        }
        XCTAssertThrowsError(try insert(source: "typed", confidence: 0.9, review: 0))
        XCTAssertThrowsError(try insert(source: "typed", confidence: nil, review: 1))
        XCTAssertThrowsError(try insert(source: "scan", confidence: 1.5, review: 0))
        XCTAssertThrowsError(try insert(source: "manual", confidence: nil, review: 0))
        XCTAssertNoThrow(try insert(source: "scan", confidence: 0.62, review: 1))
        XCTAssertNoThrow(try insert(source: "typed", confidence: nil, review: 0))
    }

    func testDeletingAReportCascadesItsValuesAndAValueNeedsAReport() throws {
        let database = try openDatabase()
        defer { try? database.databasePool.close() }
        try database.write { db in
            try insertReport(db, id: "keep")
            try insertReport(db, id: "drop")
            for report in ["keep", "drop", "drop"] {
                try db.execute(sql: "INSERT INTO lab_value(id, report_id, position, marker_key, value_text, source) VALUES (?, ?, 0, 'ldl-cholesterol', '90', 'typed')",
                    arguments: [UUID().uuidString, report])
            }
        }
        XCTAssertThrowsError(try database.write { db in
            try db.execute(sql: "INSERT INTO lab_value(id, report_id, position, marker_key, value_text, source) VALUES ('orphan', 'nobody', 0, 'apob', '1', 'typed')")
        })
        try database.write { db in try db.execute(sql: "DELETE FROM lab_report WHERE id = 'drop'") }
        XCTAssertEqual(try database.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM lab_value") }, 1)
    }

    func testAnOtherClockNeedsANameAndANamedClockHasNone() throws {
        let database = try openDatabase()
        defer { try? database.databasePool.close() }
        func insert(kind: String, name: String?) throws {
            try database.write { db in
                try db.execute(sql: "INSERT INTO lab_clock_result(id, clock_kind, clock_name, value_text, lab_name, collected_at, time_zone_identifier, created_at) VALUES (?, ?, ?, '1.02', 'TruDiagnostic', 1, 'UTC', 2)",
                    arguments: [UUID().uuidString, kind, name])
            }
        }
        XCTAssertThrowsError(try insert(kind: "other", name: nil))
        XCTAssertThrowsError(try insert(kind: "dunedinpace", name: "DunedinPACE"))
        XCTAssertThrowsError(try insert(kind: "horvath", name: nil))
        XCTAssertNoThrow(try insert(kind: "dunedinpace", name: nil))
        XCTAssertNoThrow(try insert(kind: "other", name: "Horvath"))
    }

    func testDeleteAllAccountDataEmptiesTheLabTablesAndDayDeletionLeavesThem() throws {
        let database = try openDatabase()
        defer { try? database.databasePool.close() }
        try database.write { db in
            try insertReport(db)
            try db.execute(sql: "INSERT INTO lab_value(id, report_id, position, marker_key, value_text, source) VALUES ('v1', 'r1', 0, 'apob', '78', 'typed')")
            try db.execute(sql: "INSERT INTO lab_clock_result(id, clock_kind, value_text, lab_name, collected_at, time_zone_identifier, created_at) VALUES ('c1', 'grimage', '41', 'Lab', 1, 'UTC', 2)")
        }
        let seeded = try database.tableRowCounts()
        for table in LabStorageSchema.tableNames { XCTAssertEqual(seeded[table], 1, "\(table) was not seeded") }

        try database.delete(localDay: "2026-09-12")
        let afterDay = try database.tableRowCounts()
        for table in LabStorageSchema.tableNames { XCTAssertEqual(afterDay[table], 1, "\(table) must survive a band day deletion") }

        try database.deleteAllAccountData()
        let after = try database.tableRowCounts()
        for table in LabStorageSchema.tableNames { XCTAssertEqual(after[table], 0, "\(table) survived deleteAllAccountData") }
    }

    func testABackupWithoutTheLabTablesIsNotAValidExportOrRestore() throws {
        let source = try openDatabase()
        defer { try? source.databasePool.close() }
        let exportURL = makeURL()
        try source.export(to: exportURL)

        let queue = try DatabaseQueue(path: exportURL.path)
        try queue.write { db in
            try db.execute(sql: "DROP TABLE lab_value; DROP TABLE lab_report; DROP TABLE lab_clock_result;")
        }
        try queue.close()

        XCTAssertThrowsError(try source.restore(from: exportURL, applicationVersion: "lab-migration-test")) { error in
            guard case StorageLifecycleError.missingRequiredTables(let missing) = error else {
                return XCTFail("Expected missingRequiredTables, got \(error)")
            }
            XCTAssertEqual(Set(missing), Set(LabStorageSchema.tableNames))
        }
    }
}
