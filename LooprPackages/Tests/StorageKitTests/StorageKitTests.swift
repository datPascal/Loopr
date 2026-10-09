import Foundation
import StorageKit
import XCTest

private enum StorageTestDatabase {
    static func makeURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("LooprStorageKit-\(name)", isDirectory: false)
            .appendingPathExtension("sqlite")
    }

    static func remove(_ url: URL) {
        let manager = FileManager.default
        try? manager.removeItem(at: url)
        try? manager.removeItem(atPath: "\(url.path)-wal")
        try? manager.removeItem(atPath: "\(url.path)-shm")
    }

    static func open(_ name: String, applicationVersion: String = "1.0 (1)") throws -> (StorageDatabase, URL) {
        let url = makeURL(name)
        remove(url)
        let database = try StorageDatabase(url: url, applicationVersion: applicationVersion)
        return (database, url)
    }
}

private final class BackupResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Void, Error>?

    func set(_ result: Result<Void, Error>) {
        lock.lock()
        self.result = result
        lock.unlock()
    }

    func get() -> Result<Void, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return result
    }
}

final class DatabaseConfigurationTests: XCTestCase {
    func test_databasePoolEnablesWALAndForeignKeys() throws {
        let (database, url) = try StorageTestDatabase.open("configuration")
        defer {
            try? database.databasePool.close()
            StorageTestDatabase.remove(url)
        }

        XCTAssertEqual(try database.readString(sql: "PRAGMA journal_mode")?.lowercased(), "wal")
        XCTAssertEqual(try database.readInteger(sql: "PRAGMA foreign_keys"), 1)
        XCTAssertEqual(database.databasePool.configuration.maximumReaderCount, StorageDatabase.defaultReaderCount)

        try database.write { db in
            try db.execute(sql: "CREATE TABLE parent (id INTEGER PRIMARY KEY)")
            try db.execute(sql: "CREATE TABLE child (id INTEGER PRIMARY KEY, parent_id INTEGER NOT NULL REFERENCES parent(id))")
        }
        XCTAssertThrowsError(
            try database.write { db in
                try db.execute(sql: "INSERT INTO child (id, parent_id) VALUES (1, 999)")
            }
        )
    }

    func test_databasePoolReaderCanReadWhileWriterTransactionIsOpen() throws {
        let (database, url) = try StorageTestDatabase.open("reader-writer")
        defer {
            try? database.databasePool.close()
            StorageTestDatabase.remove(url)
        }

        try database.write { db in
            try db.execute(sql: "CREATE TABLE reader_writer_probe (id INTEGER PRIMARY KEY, value TEXT NOT NULL)")
            try db.execute(sql: "INSERT INTO reader_writer_probe (id, value) VALUES (1, 'before')")
        }

        let writerEntered = DispatchSemaphore(value: 0)
        let releaseWriter = DispatchSemaphore(value: 0)
        let writerFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .default).async {
            defer { writerFinished.signal() }
            do {
                try database.write { db in
                    try db.execute(sql: "UPDATE reader_writer_probe SET value = 'during' WHERE id = 1")
                    writerEntered.signal()
                    _ = releaseWriter.wait(timeout: .now() + 5)
                }
            } catch {
                writerEntered.signal()
            }
        }

        XCTAssertEqual(writerEntered.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(try database.readString(sql: "SELECT value FROM reader_writer_probe WHERE id = 1"), "before")
        releaseWriter.signal()
        XCTAssertEqual(writerFinished.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(try database.readString(sql: "SELECT value FROM reader_writer_probe WHERE id = 1"), "during")
    }
}

final class MigrationTests: XCTestCase {
    func test_freshDatabaseAppliesOrderedMigrationsAndReopenIsIdempotent() throws {
        let url = StorageTestDatabase.makeURL("migrations")
        StorageTestDatabase.remove(url)
        defer { StorageTestDatabase.remove(url) }

        let database = try StorageDatabase(url: url, applicationVersion: "2.4 (17)")
        defer { try? database.databasePool.close() }
        XCTAssertFalse(try database.hasPendingMigrations())
        let completedMigrations = try database.read { db in
            try database.migrator.completedMigrations(db)
        }
        XCTAssertEqual(completedMigrations, database.migrator.migrations)
        XCTAssertEqual(
            try database.readInteger(sql: "SELECT COUNT(*) FROM \(StorageMigrations.metadataTable)"),
            Int64(database.migrator.migrations.count)
        )

        try database.databasePool.close()
        let reopened = try StorageDatabase(url: url, applicationVersion: "2.4 (17)")
        defer { try? reopened.databasePool.close() }
        XCTAssertFalse(try reopened.hasPendingMigrations())
        XCTAssertEqual(
            try reopened.readInteger(sql: "SELECT COUNT(*) FROM \(StorageMigrations.metadataTable)"),
            Int64(reopened.migrator.migrations.count)
        )
    }
}

final class SchemaMetadataTests: XCTestCase {
    func test_migrationRecordsSchemaAndApplicationVersions() throws {
        let (database, url) = try StorageTestDatabase.open("metadata", applicationVersion: "3.7 (42)")
        defer {
            try? database.databasePool.close()
            StorageTestDatabase.remove(url)
        }

        let rows = try database.schemaMetadata()
        XCTAssertEqual(rows.count, database.migrator.migrations.count)
        XCTAssertEqual(rows[0].migrationIdentifier, StorageMigrationIdentifier.schemaMetadata)
        XCTAssertFalse(rows[0].schemaVersion.isEmpty)
        XCTAssertEqual(rows[0].applicationVersion, "3.7 (42)")
    }
}

final class FileProtectionTests: XCTestCase {
    func test_databaseFileUsesUntilFirstUnlockProtection() throws {
        let (database, url) = try StorageTestDatabase.open("protection")
        defer {
            try? database.databasePool.close()
            StorageTestDatabase.remove(url)
        }
        try database.applyFileProtection()

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual(
            StorageDatabase.fileProtectionClass,
            .completeUntilFirstUserAuthentication
        )
        // FileManager exposes NSFileProtection attributes on device. The
        // iOS Simulator's APFS shim may omit the read-back attribute even
        // though setAttributes succeeds, so only assert the OS value when it
        // is available.
        if let protection = attributes[.protectionKey] as? FileProtectionType {
            XCTAssertEqual(protection, StorageDatabase.fileProtectionClass)
            XCTAssertNotEqual(protection, .none)
            XCTAssertNotEqual(protection, .complete)
        }

        for sidecarPath in database.sidecarPaths where FileManager.default.fileExists(atPath: sidecarPath) {
            let sidecarAttributes = try FileManager.default.attributesOfItem(atPath: sidecarPath)
            if let sidecarProtection = sidecarAttributes[.protectionKey] as? FileProtectionType {
                XCTAssertEqual(sidecarProtection, StorageDatabase.fileProtectionClass)
                XCTAssertNotEqual(sidecarProtection, .none)
                XCTAssertNotEqual(sidecarProtection, .complete)
            }
        }
    }
}

final class IntegrityCheckTests: XCTestCase {
    func test_healthyDatabasePassesIntegrityCheck() throws {
        let (database, url) = try StorageTestDatabase.open("integrity-healthy")
        defer {
            try? database.databasePool.close()
            StorageTestDatabase.remove(url)
        }
        XCTAssertEqual(try database.integrityCheck(), .ok)
        XCTAssertEqual(database.coldLaunchIntegrityResult, .ok)
    }

    func test_onOpenTimingRecordsTheResultInsideInit() throws {
        let (database, url) = try StorageTestDatabase.open("integrity-on-open")
        defer {
            try? database.databasePool.close()
            StorageTestDatabase.remove(url)
        }
        XCTAssertTrue(database.hasColdLaunchIntegrityResult)
    }

    func test_deferredTimingRunsTheCheckOnFirstReadAndKeepsIt() throws {
        let url = StorageTestDatabase.makeURL("integrity-deferred")
        StorageTestDatabase.remove(url)
        let database = try StorageDatabase(url: url, applicationVersion: "1.0 (1)", integrityCheck: .deferred)
        defer {
            try? database.databasePool.close()
            StorageTestDatabase.remove(url)
        }
        XCTAssertFalse(database.hasColdLaunchIntegrityResult)
        XCTAssertEqual(database.coldLaunchIntegrityResult, .ok)
        XCTAssertTrue(database.hasColdLaunchIntegrityResult)
        XCTAssertEqual(database.coldLaunchIntegrityResult, .ok)
    }

    func test_setupOnceRunsOnceAndRetriesAfterAFailure() throws {
        let (database, url) = try StorageTestDatabase.open("setup-once")
        defer {
            try? database.databasePool.close()
            StorageTestDatabase.remove(url)
        }
        struct Probe: Error {}
        var runs = 0
        XCTAssertThrowsError(try database.performSetupOnce("probe") { runs += 1; throw Probe() })
        try database.performSetupOnce("probe") { runs += 1 }
        try database.performSetupOnce("probe") { runs += 1 }
        XCTAssertEqual(runs, 2)
    }

    func test_corruptedDatabaseReturnsTypedFailureWithoutCrashing() throws {
        let (database, sourceURL) = try StorageTestDatabase.open("integrity-corrupt-source")
        try database.write { db in
            try db.execute(sql: "CREATE TABLE corruption_probe (value TEXT NOT NULL)")
            try db.execute(sql: "INSERT INTO corruption_probe (value) VALUES ('payload')")
        }
        try database.databasePool.close()

        let corruptURL = StorageTestDatabase.makeURL("integrity-corrupt-copy")
        StorageTestDatabase.remove(corruptURL)
        defer {
            StorageTestDatabase.remove(sourceURL)
            StorageTestDatabase.remove(corruptURL)
        }
        try FileManager.default.copyItem(at: sourceURL, to: corruptURL)
        let bytes = try Data(contentsOf: corruptURL)
        XCTAssertGreaterThan(bytes.count, 1)
        try Data(bytes.prefix(max(1, bytes.count / 2))).write(to: corruptURL, options: .atomic)

        let result = StorageDatabase.integrityCheck(at: corruptURL)
        guard case .failed(let failure) = result else {
            return XCTFail("A truncated database must produce a typed integrity failure")
        }
        XCTAssertFalse(failure.messages.isEmpty)
    }
}

final class BackupTests: XCTestCase {
    func test_onlineBackupIsRestorableDuringConcurrentWriteTransaction() throws {
        let (source, sourceURL) = try StorageTestDatabase.open("backup-source")
        let destinationURL = StorageTestDatabase.makeURL("backup-destination")
        StorageTestDatabase.remove(destinationURL)
        defer {
            try? source.databasePool.close()
            StorageTestDatabase.remove(sourceURL)
            StorageTestDatabase.remove(destinationURL)
        }

        try source.write { db in
            try db.execute(sql: "CREATE TABLE backup_probe (id INTEGER PRIMARY KEY, value TEXT NOT NULL)")
            try db.execute(sql: "INSERT INTO backup_probe (id, value) VALUES (1, 'initial')")
        }

        let writerEntered = DispatchSemaphore(value: 0)
        let releaseWriter = DispatchSemaphore(value: 0)
        let writerFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .default).async {
            defer { writerFinished.signal() }
            do {
                try source.write { db in
                    try db.execute(sql: "INSERT INTO backup_probe (id, value) VALUES (2, 'in-flight')")
                    writerEntered.signal()
                    _ = releaseWriter.wait(timeout: .now() + 5)
                }
            } catch {
                writerEntered.signal()
            }
        }

        XCTAssertEqual(writerEntered.wait(timeout: .now() + 5), .success)
        let backupStarted = DispatchSemaphore(value: 0)
        let backupFinished = DispatchSemaphore(value: 0)
        let backupResult = BackupResultBox()
        DispatchQueue.global(qos: .utility).async {
            backupStarted.signal()
            do {
                try source.backup(to: destinationURL)
                backupResult.set(.success(()))
            } catch {
                backupResult.set(.failure(error))
            }
            backupFinished.signal()
        }

        // Release the writer from an independent task while the online
        // backup is in flight. This proves the test does not depend on the
        // backup returning before its source transaction can finish.
        XCTAssertEqual(backupStarted.wait(timeout: .now() + 5), .success)
        DispatchQueue.global(qos: .default).async {
            releaseWriter.signal()
        }
        XCTAssertEqual(backupFinished.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(writerFinished.wait(timeout: .now() + 5), .success)
        if case .failure(let error)? = backupResult.get() {
            throw error
        }

        let backup = try StorageDatabase(url: destinationURL, applicationVersion: "1.0 (1)")
        defer { try? backup.databasePool.close() }
        XCTAssertEqual(try backup.integrityCheck(), .ok)
        let rowCount = try XCTUnwrap(backup.readInteger(sql: "SELECT COUNT(*) FROM backup_probe"))
        XCTAssertTrue((1...2).contains(rowCount))
    }
}
