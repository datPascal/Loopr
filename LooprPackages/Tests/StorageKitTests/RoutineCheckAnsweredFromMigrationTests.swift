import Foundation
import StorageKit
import XCTest

/// `storage-025-routine-check-answered-from` adds where an answer came from, such as a rule reminder (ICP round 4, SEN and
/// VET). A database that already holds checks must open with every check as it was and no origin, and then store one.
final class RoutineCheckAnsweredFromMigrationTests: XCTestCase {
    private var urls: [URL] = []

    override func tearDown() {
        for url in urls {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
        }
        urls = []
        super.tearDown()
    }

    private func makeURL() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("routine-origin-migration-\(UUID().uuidString).sqlite")
        urls.append(url)
        return url
    }

    func testTheMigrationIsRegisteredLast() {
        let identifiers = StorageMigrationHarness.registeredMigrationIdentifiers(applicationVersion: "test")
        XCTAssertEqual(StorageMigrationIdentifier.routineCheckAnsweredFrom, "storage-025-routine-check-answered-from")
        XCTAssertEqual(identifiers.firstIndex(of: StorageMigrationIdentifier.routineCheckSkipped).map { $0 + 1 },
                       identifiers.firstIndex(of: StorageMigrationIdentifier.routineCheckAnsweredFrom))
    }

    func testStoredChecksSurviveWithoutAnOriginAndANewOneCanBeStored() throws {
        let url = makeURL()
        let identifiers = StorageMigrationHarness.registeredMigrationIdentifiers(applicationVersion: "1.0 (29)")
        let index = try XCTUnwrap(identifiers.firstIndex(of: StorageMigrationIdentifier.routineCheckAnsweredFrom))
        let queue = try DatabaseQueue(path: url.path)
        try StorageMigrations.makeMigrator(applicationVersion: "1.0 (29)").migrate(queue, upTo: identifiers[index - 1])
        try queue.write { db in
            try db.execute(sql: "INSERT INTO routine_protocol VALUES ('p1', 'Mine', 1, 1, x'7B7D')")
            try db.execute(sql: "INSERT INTO routine_version VALUES ('p1', 1, 1, x'7B7D')")
            try db.execute(sql: "INSERT INTO routine_check VALUES ('p1', 'mg', '2023-11-13', 1, 'kept', 'manual', NULL, 0, 5)")
            try db.execute(sql: "INSERT INTO routine_check VALUES ('p1', 'bed', '2023-11-13', 1, 'skipped', 'manual', NULL, 1, 6)")
        }
        try queue.close()

        let upgraded = try StorageDatabase(url: url, applicationVersion: "1.0 (30)")
        defer { try? upgraded.databasePool.close() }
        XCTAssertFalse(try upgraded.hasPendingMigrations())
        try upgraded.write { db in
            let rows = try Row.fetchAll(db, sql: "SELECT rule_key, state, recorded_at, answered_from FROM routine_check ORDER BY rule_key")
            XCTAssertEqual(rows.map { $0["rule_key"] as String }, ["bed", "mg"])
            XCTAssertEqual(rows.map { $0["state"] as String }, ["skipped", "kept"])
            XCTAssertEqual(rows.map { $0["answered_from"] as String? }, [nil, nil], "no stored answer claims a reminder")
            try db.execute(sql: "UPDATE routine_check SET answered_from = 'reminder' WHERE rule_key = 'mg'")
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT answered_from FROM routine_check WHERE rule_key = 'mg'"), "reminder")
            try db.execute(sql: "DELETE FROM routine_protocol WHERE id = 'p1'")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM routine_check"), 0, "The cascade still removes checks")
        }
    }
}
