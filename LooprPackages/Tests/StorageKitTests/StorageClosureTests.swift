import Foundation
import GRDB
import StorageKit
import XCTest

private enum ClosureTestSupport {
    static func url(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("Loopr-STO05-\(name)-\(UUID().uuidString).sqlite")
    }
    static func database(_ name: String) throws -> StorageDatabase {
        try StorageDatabase(url: url(name), applicationVersion: "STO-05")
    }
}

private actor DeletionParticipantSpy: StorageDeletionParticipant {
    nonisolated let identifier: String
    nonisolated let surfaces: Set<StorageClosureSurface>
    private var count: Int
    init(identifier: String, surfaces: Set<StorageClosureSurface>, count: Int = 1) {
        self.identifier = identifier; self.surfaces = surfaces; self.count = count
    }
    func itemCount() -> Int { count }
    func deleteAll() { count = 0 }
}

final class SchemaMigrationMatrixTests: XCTestCase {
    func testEveryRegisteredHistoricalSchemaMigratesToCurrentChecksum() throws {
        let result = try StorageMigrationHarness.verifyAllRegisteredVersions(
            applicationVersion: "STO-05",
            directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("STO05-migration-\(UUID().uuidString)", isDirectory: true)
        )
        XCTAssertEqual(result.map(\.migrationIdentifier),
                       StorageMigrationHarness.registeredMigrationIdentifiers(applicationVersion: "STO-05"))
        XCTAssertTrue(result.allSatisfy(\.schemaMatchesCurrent))
    }
}

final class FullDeletionAuditTests: XCTestCase {
    func testInventoryIsExhaustiveAndEveryLocalSurfaceIsEmptyAfterDeletion() async throws {
        XCTAssertEqual(StorageClosureInventory.entries.count, StorageProducerPackage.allCases.count)
        XCTAssertEqual(Set(StorageClosureInventory.entries.map(\.producer)), Set(StorageProducerPackage.allCases))
        XCTAssertEqual(StorageClosureInventory.checklistNarrativeCount, StorageProducerPackage.allCases.count)
        XCTAssertEqual(StorageProducerPackage.allCases.count, 30, "The stable producer inventory must match the explicit 30-package checklist list")
        XCTAssertEqual(
            StorageClosureInventory.entries.first(where: { $0.producer == .sfc05 })?.surfaces,
            [.appGroup, .watchConnectivity],
            "Watch delivery is durable outside the App Group and must stay in the deletion inventory"
        )

        let database = try ClosureTestSupport.database("deletion")
        defer { try? database.databasePool.close() }
        try database.write { db in
            try db.execute(sql: "INSERT INTO metric_series(local_day, metric_key, value, updated_at) VALUES ('2026-08-23', 'recovery', 81, 1)")
            // Product packages add tables and namespaces outside StorageKit's
            // base migrator. A future table is included as a regression fence:
            // full deletion must discover it rather than rely on a stale list.
            try db.execute(sql: "CREATE TABLE loopr_product_document(namespace TEXT NOT NULL, document_key TEXT NOT NULL, payload BLOB NOT NULL, updated_at REAL NOT NULL, PRIMARY KEY(namespace, document_key))")
            try db.execute(sql: "INSERT INTO loopr_product_document VALUES ('today', '2026-08-23', X'01', 1)")
            try db.execute(sql: "CREATE TABLE profile(id TEXT PRIMARY KEY, display_name TEXT NOT NULL)")
            try db.execute(sql: "INSERT INTO profile VALUES ('profile-1', 'Alex')")
            try db.execute(sql: "CREATE TABLE app_future_owned_fixture(id INTEGER PRIMARY KEY AUTOINCREMENT, payload TEXT NOT NULL)")
            try db.execute(sql: "INSERT INTO app_future_owned_fixture(payload) VALUES ('must be deleted')")
        }
        let participants: [DeletionParticipantSpy] = StorageClosureInventory.entries.flatMap { entry in
            entry.surfaces
                .subtracting([.sqlite, .none, .healthKitSamples])
                .map {
                    DeletionParticipantSpy(
                        identifier: "\(entry.producer.rawValue).\($0.rawValue)",
                        surfaces: [$0]
                    )
                }
        }
        let healthKit = DeletionParticipantSpy(identifier: "healthkit-explicit", surfaces: [.healthKitSamples])
        let coordinator = StorageFullDeletionCoordinator(database: database,
                                                         participants: participants + [healthKit])
        let report = try await coordinator.deleteLocalAccount()
        XCTAssertTrue(report.isComplete)
        for participant in participants {
            let count = await participant.itemCount()
            XCTAssertEqual(count, 0)
        }
        let healthKitCount = await healthKit.itemCount()
        XCTAssertEqual(healthKitCount, 1, "HealthKit removal requires separate confirmation")
        let localRows = try database.read { db -> [String: Int] in
            let preserved: Set<String> = [
                StorageMigrations.metadataTable,
                "grdb_migrations",
                "sync_cursor",
                "analytics_input_revision" // Non-user generation counter; prevents deleted inputs matching an old cache.
            ]
            let names = try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name"
            )
            return try Dictionary(uniqueKeysWithValues: names.compactMap { name in
                guard !preserved.contains(name) else { return nil }
                let escaped = name.replacingOccurrences(of: "\"", with: "\"\"")
                let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \"\(escaped)\"") ?? -1
                return (name, count)
            })
        }
        XCTAssertFalse(localRows.isEmpty)
        XCTAssertTrue(localRows.values.allSatisfy { $0 == 0 }, "Remaining rows: \(localRows)")
        let cursor = try database.syncCursorSnapshot()
        XCTAssertNil(cursor.token)
        XCTAssertNil(cursor.counterHighWater)
        XCTAssertNil(cursor.timestampHighWater)
        XCTAssertEqual(cursor.updatedAt, 0)
    }
}

final class FullDeletionTests: XCTestCase {
    func testDatabaseSnapshotsKeychainNotificationsAndLiveActivitiesAreCleared() async throws {
        let database = try ClosureTestSupport.database("release-full-deletion")
        defer { try? database.databasePool.close() }
        try database.write { db in
            try db.execute(sql: "INSERT INTO metric_series(local_day, metric_key, value, updated_at) VALUES ('2026-08-23', 'strain', 9, 1)")
        }
        let participants = [
            DeletionParticipantSpy(identifier: "snapshots", surfaces: [.appGroup]),
            DeletionParticipantSpy(identifier: "keychain", surfaces: [.keychain]),
            DeletionParticipantSpy(identifier: "notifications", surfaces: [.notification]),
            DeletionParticipantSpy(identifier: "live-activities", surfaces: [.liveActivity])
        ]
        let report = try await StorageFullDeletionCoordinator(
            database: database,
            participants: participants
        ).deleteLocalAccount()

        XCTAssertTrue(report.isComplete)
        XCTAssertEqual(Set(report.remainingByParticipant.keys),
                       ["snapshots", "keychain", "notifications", "live-activities"])
        XCTAssertTrue(report.remainingByParticipant.values.allSatisfy { $0 == 0 })
        XCTAssertEqual(try database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM metric_series") ?? -1
        }, 0)
    }
}

final class SecretScanTests: XCTestCase {
    func testCredentialsCannotEnterExternalArchiveAndSafePayloadRoundTrips() throws {
        XCTAssertThrowsError(try StorageExternalArchive(payloads: ["provider": Data("Bearer secret".utf8)])) {
            XCTAssertEqual($0 as? StorageClosureError, .credentialShapedExport)
        }
        let archive = try StorageExternalArchive(payloads: ["proposal": Data("unconfirmed journal proposal".utf8)])
        let encoded = try JSONEncoder().encode(archive)
        try StorageSecretScanner.validate([encoded])
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("secret"))
    }
}

final class BackupRestoreClosureTests: XCTestCase {
    func testDatabaseAndExternalLedgersRoundTripWithPendingStates() throws {
        let liveURL = ClosureTestSupport.url("backup-live")
        let exportURL = ClosureTestSupport.url("backup-export")
        let database = try StorageDatabase(url: liveURL, applicationVersion: "STO-05")
        try database.write { db in
            try db.execute(sql: "INSERT INTO health_export_item(object_id, object_type, status, error, updated_at) VALUES ('h1', 'heart_rate', 'pending', NULL, 1)")
        }
        try database.export(to: exportURL)
        try database.write { db in try db.execute(sql: "DELETE FROM health_export_item") }
        let restored = try database.restore(from: exportURL, applicationVersion: "STO-05")
        defer { try? restored.databasePool.close() }
        let status = try restored.read { db in
            try String.fetchOne(db, sql: "SELECT status FROM health_export_item WHERE object_id = 'h1'")
        }
        XCTAssertEqual(status, "pending")

        let external = try StorageExternalArchive(payloads: [
            "ai-proposal": Data("{\"confirmed\":false}".utf8),
            "notification-claim": Data("pending".utf8)
        ])
        let roundTrip = try JSONDecoder().decode(StorageExternalArchive.self,
                                                 from: JSONEncoder().encode(external))
        XCTAssertEqual(roundTrip, external)
    }
}
