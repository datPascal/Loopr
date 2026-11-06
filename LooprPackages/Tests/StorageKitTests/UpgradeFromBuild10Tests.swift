import Foundation
import StorageKit
import XCTest

/// TestFlight build 10 shipped every migration up to `storage-009-v24-skin-temperature`. A database it wrote must open
/// in this build, gain the Food and Train tables, and keep what it held.
final class UpgradeFromBuild10Tests: XCTestCase {
    func testABuild10DatabaseOpensGainsTheNewTablesAndKeepsItsData() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("build10-upgrade-\(UUID().uuidString).sqlite")
        defer {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
        }
        let shipped = StorageMigrations.makeMigrator(applicationVersion: "1.0 (10)")
        let queue = try DatabaseQueue(path: url.path)
        try shipped.migrate(queue, upTo: "storage-009-v24-skin-temperature")
        try queue.write { db in
            try db.execute(sql: "INSERT INTO decoded_second(physiological_timestamp, band_counter, absolute_timestamp, local_day, record_version) VALUES (1, 1, 1, '2026-10-10', 24)")
        }
        try queue.close()

        // Build 10 also kept settings and records in the document table, created on first use.
        let opened = try StorageDatabase(url: url, applicationVersion: "1.0 (11)")
        let settings = try StorageDocumentStore(database: opened, namespace: "settings")
        try settings.write(["units": "metric"], key: "snapshot")
        try opened.databasePool.close()

        let upgraded = try StorageDatabase(url: url, applicationVersion: "1.0 (11)")
        defer { try? upgraded.databasePool.close() }
        XCTAssertFalse(try upgraded.hasPendingMigrations())
        try upgraded.read { db in
            for table in FoodStorageSchema.tableNames + TrainStorageSchema.tableNames + RoutineStorageSchema.tableNames {
                XCTAssertTrue(try db.tableExists(table), "\(table) was not created on upgrade")
            }
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM decoded_second WHERE local_day = '2026-10-10'"), 1)
            let applied = try String.fetchAll(db, sql: "SELECT migration_identifier FROM storage_schema_metadata")
            XCTAssertTrue(applied.contains("storage-013-food-review") && applied.contains("storage-014-train") && applied.contains("storage-015-food-weight"))
        }
        let kept = try StorageDocumentStore(database: upgraded, namespace: "settings").read([String: String].self, key: "snapshot")
        XCTAssertEqual(kept, ["units": "metric"])
    }
}
