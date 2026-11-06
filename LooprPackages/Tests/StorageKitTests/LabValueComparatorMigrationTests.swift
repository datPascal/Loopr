import Foundation
import StorageKit
import XCTest

/// `storage-023-lab-value-comparator` adds the sign of a result printed as a limit ("<0.3", ">200") to `lab_value`. A
/// database that already holds blood tests must open, gain the column, keep every value as it was (an exact result,
/// NULL), and the column must refuse any sign other than the four.
final class LabValueComparatorMigrationTests: XCTestCase {
    private var urls: [URL] = []

    override func tearDown() {
        for url in urls {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
        }
        urls = []
        super.tearDown()
    }

    private func makeURL() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lab-comparator-migration-\(UUID().uuidString).sqlite")
        urls.append(url)
        return url
    }

    func testTheMigrationIsRegisteredAfterTheBodyCompositionMigration() {
        let identifiers = StorageMigrationHarness.registeredMigrationIdentifiers(applicationVersion: "test")
        XCTAssertEqual(StorageMigrationIdentifier.labValueComparator, "storage-023-lab-value-comparator")
        XCTAssertEqual(identifiers.firstIndex(of: StorageMigrationIdentifier.bodyComposition).map { $0 + 1 },
                       identifiers.firstIndex(of: StorageMigrationIdentifier.labValueComparator))
    }

    func testStoredBloodTestsGainTheColumnAndReadAsExactResults() throws {
        let url = makeURL()
        let identifiers = StorageMigrationHarness.registeredMigrationIdentifiers(applicationVersion: "1.0 (22)")
        let index = try XCTUnwrap(identifiers.firstIndex(of: StorageMigrationIdentifier.labValueComparator))
        let previous = identifiers[index - 1]

        let queue = try DatabaseQueue(path: url.path)
        try StorageMigrations.makeMigrator(applicationVersion: "1.0 (22)").migrate(queue, upTo: previous)
        try queue.write { db in
            XCTAssertFalse(try db.columns(in: "lab_value").map(\.name).contains("comparator"))
            try db.execute(sql: """
                INSERT INTO lab_report(id, collected_at, collected_day, time_zone_identifier, source, created_at)
                VALUES ('kept-report', 1, '2026-09-12', 'Europe/Berlin', 'scan', 2)
                """)
            try db.execute(sql: """
                INSERT INTO lab_value(id, report_id, position, marker_key, value_text, unit, flag_text, source, scan_confidence, needs_review)
                VALUES ('kept-value', 'kept-report', 0, 'crp', '0.6', 'mg/L', 'H', 'scan', 0.9, 0)
                """)
        }
        try queue.close()

        let upgraded = try StorageDatabase(url: url, applicationVersion: "1.0 (23)")
        defer { try? upgraded.databasePool.close() }
        XCTAssertFalse(try upgraded.hasPendingMigrations())
        try upgraded.read { db in
            XCTAssertTrue(try db.columns(in: "lab_value").map(\.name).contains("comparator"))
            let row = try XCTUnwrap(try Row.fetchOne(db, sql: "SELECT value_text, unit, flag_text, comparator FROM lab_value WHERE id = 'kept-value'"))
            XCTAssertEqual(row["value_text"] as String, "0.6")
            XCTAssertEqual(row["unit"] as String, "mg/L")
            XCTAssertEqual(row["flag_text"] as String, "H")
            XCTAssertNil(row["comparator"] as String?)
            let applied = try String.fetchAll(db, sql: "SELECT migration_identifier FROM storage_schema_metadata")
            XCTAssertTrue(applied.contains("storage-023-lab-value-comparator"))
        }
    }

    func testOnlyTheFourSignsAreStored() throws {
        let database = try StorageDatabase(url: makeURL(), applicationVersion: "lab-comparator-test")
        defer { try? database.databasePool.close() }
        try database.write { db in
            try db.execute(sql: """
                INSERT INTO lab_report(id, collected_at, collected_day, time_zone_identifier, source, created_at)
                VALUES ('r1', 1, '2026-09-12', 'Europe/Berlin', 'typed', 2)
                """)
        }
        func insert(_ comparator: String?) throws {
            try database.write { db in
                try db.execute(sql: "INSERT INTO lab_value(id, report_id, position, marker_key, value_text, comparator, source) VALUES (?, 'r1', 0, 'crp', '0.3', ?, 'typed')",
                               arguments: [UUID().uuidString, comparator])
            }
        }
        for sign in ["<", "<=", ">", ">="] { XCTAssertNoThrow(try insert(sign), sign) }
        XCTAssertNoThrow(try insert(nil))
        for sign in ["=", "≤", "~", ""] { XCTAssertThrowsError(try insert(sign), sign) }
    }

    func testEveryRegisteredVersionStillConvergesOnTheCurrentSchema() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lab-comparator-harness-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let results = try StorageMigrationHarness.verifyAllRegisteredVersions(directory: directory)
        XCTAssertTrue(results.contains { $0.migrationIdentifier == StorageMigrationIdentifier.labValueComparator })
        XCTAssertTrue(results.allSatisfy(\.schemaMatchesCurrent))
    }
}
