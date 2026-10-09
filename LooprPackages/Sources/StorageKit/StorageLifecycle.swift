import Foundation
@_exported import GRDB

/// A stable, value-type description of one SQLite column.
public struct StorageColumnSnapshot: Equatable, Sendable {
    public let name: String
    public let type: String
    public let isNotNull: Bool
    public let defaultValueSQL: String?
    public let primaryKeyIndex: Int

    public init(
        name: String,
        type: String,
        isNotNull: Bool,
        defaultValueSQL: String?,
        primaryKeyIndex: Int
    ) {
        self.name = name
        self.type = type
        self.isNotNull = isNotNull
        self.defaultValueSQL = defaultValueSQL
        self.primaryKeyIndex = primaryKeyIndex
    }
}

/// A stable, value-type description of one SQLite table.
public struct StorageTableSnapshot: Equatable, Sendable {
    public let name: String
    public let columns: [StorageColumnSnapshot]
    public let createSQL: String?

    public init(name: String, columns: [StorageColumnSnapshot], createSQL: String?) {
        self.name = name
        self.columns = columns
        self.createSQL = createSQL
    }
}

/// SQLite schema introspection used by the migration harness and restore
/// validation. It intentionally records constraints through sqlite_master's
/// CREATE statement in addition to column metadata.
public struct StorageSchemaSnapshot: Equatable, Sendable {
    public let tables: [StorageTableSnapshot]

    public init(tables: [StorageTableSnapshot]) {
        self.tables = tables.sorted { $0.name < $1.name }
    }

    public var tableNames: Set<String> {
        Set(tables.map(\.name))
    }

    public func table(named name: String) -> StorageTableSnapshot? {
        tables.first { $0.name == name }
    }

    public func isEquivalent(to other: StorageSchemaSnapshot) -> Bool {
        self == other
    }
}

/// The result for one frozen migration version in the migration harness.
public struct StorageMigrationVerification: Equatable, Sendable {
    public let migrationIdentifier: String
    public let schemaMatchesCurrent: Bool

    public init(migrationIdentifier: String, schemaMatchesCurrent: Bool) {
        self.migrationIdentifier = migrationIdentifier
        self.schemaMatchesCurrent = schemaMatchesCurrent
    }
}

public enum StorageLifecycleError: Error, Equatable, Sendable, LocalizedError {
    case invalidLocalDay
    case sameFile
    case missingRequiredTables([String])
    case integrityCheckFailed([String])
    case foreignKeyCheckFailed([String])
    case schemaMismatch(migrationIdentifier: String)
    case crossDayWorkoutDeletionUnsupported([String])
    case restoreFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidLocalDay:
            return "A local day identity must not be empty."
        case .sameFile:
            return "The source and destination database files must differ."
        case .missingRequiredTables(let tables):
            return "The database is missing required StorageKit tables: \(tables.joined(separator: ", "))."
        case .integrityCheckFailed(let messages):
            return "The database failed SQLite integrity validation: \(messages.joined(separator: " | "))."
        case .foreignKeyCheckFailed(let messages):
            return "The database failed SQLite foreign-key validation: \(messages.joined(separator: " | "))."
        case .schemaMismatch(let migrationIdentifier):
            return "The schema after migration \(migrationIdentifier) does not match the current schema."
        case .crossDayWorkoutDeletionUnsupported(let workoutIDs):
            return "The requested day deletion cannot safely redact cross-day workouts: \(workoutIDs.joined(separator: ", "))."
        case .restoreFailed(let reason):
            return "The database restore failed: \(reason)"
        }
    }
}

/// A public extension point for callers that need an explicit local-day
/// timestamp range for tables that store epoch values instead of a day key.
/// The range is half-open and uses Unix seconds.
public struct StorageLocalDayWindow: Equatable, Sendable {
    public let localDay: String
    public let unixSeconds: Range<Int64>

    public init(localDay: String, unixSeconds: Range<Int64>) {
        self.localDay = localDay
        self.unixSeconds = unixSeconds
    }
}

private enum StorageLifecycleInternals {
    static let restoreLock = NSLock()

    static func quotedIdentifier(_ identifier: String) -> String {
        "\"\(identifier.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    static func removeSQLiteFiles(at url: URL, fileManager: FileManager) {
        try? fileManager.removeItem(at: url)
        removeSQLiteSidecars(at: url, fileManager: fileManager)
    }

    static func removeSQLiteSidecars(at url: URL, fileManager: FileManager) {
        try? fileManager.removeItem(atPath: "\(url.path)-wal")
        try? fileManager.removeItem(atPath: "\(url.path)-shm")
    }

    static func copySQLiteFiles(
        from source: URL,
        to destination: URL,
        fileManager: FileManager
    ) throws {
        try fileManager.copyItem(at: source, to: destination)
        for suffix in ["-wal", "-shm"] {
            let sourceSidecar = "\(source.path)\(suffix)"
            let destinationSidecar = "\(destination.path)\(suffix)"
            if fileManager.fileExists(atPath: sourceSidecar) {
                try fileManager.copyItem(atPath: sourceSidecar, toPath: destinationSidecar)
            }
        }
    }

    static func moveSQLiteSidecars(
        from source: URL,
        to destination: URL,
        fileManager: FileManager
    ) throws {
        for suffix in ["-wal", "-shm"] {
            let sourceSidecar = "\(source.path)\(suffix)"
            let destinationSidecar = "\(destination.path)\(suffix)"
            try? fileManager.removeItem(atPath: destinationSidecar)
            if fileManager.fileExists(atPath: sourceSidecar) {
                try fileManager.moveItem(atPath: sourceSidecar, toPath: destinationSidecar)
            }
        }
    }

    static func restoreSnapshot(
        from source: URL,
        to destination: URL,
        fileManager: FileManager
    ) throws {
        // Keep the source snapshot intact until the copy has completed. This
        // makes a partial sidecar failure recoverable and leaves the original
        // rollback image available for a subsequent attempt.
        removeSQLiteFiles(at: destination, fileManager: fileManager)
        try copySQLiteFiles(from: source, to: destination, fileManager: fileManager)
    }

    static func userTableNames(in db: Database) throws -> [String] {
        try String.fetchAll(
            db,
            sql: """
            SELECT name
            FROM sqlite_master
            WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
            ORDER BY name
            """
        )
    }

    static func schemaSnapshot(in db: Database) throws -> StorageSchemaSnapshot {
        let tables = try userTableNames(in: db).map { tableName in
            let columns = try db.columns(in: tableName).map { column in
                StorageColumnSnapshot(
                    name: column.name,
                    type: column.type,
                    isNotNull: column.isNotNull,
                    defaultValueSQL: column.defaultValueSQL,
                    primaryKeyIndex: column.primaryKeyIndex
                )
            }
            let createSQL = try String.fetchOne(
                db,
                sql: "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?",
                arguments: [tableName]
            )
            return StorageTableSnapshot(
                name: tableName,
                columns: columns,
                createSQL: createSQL
            )
        }
        return StorageSchemaSnapshot(tables: tables)
    }

    static func schemaObjectDefinitions(in db: Database) throws -> [String] {
        try String.fetchAll(
            db,
            sql: """
            SELECT type || '|' || name || '|' || IFNULL(tbl_name, '') || '|' || IFNULL(sql, '')
            FROM sqlite_master
            WHERE name NOT LIKE 'sqlite_%'
            ORDER BY type, name
            """
        )
    }

    static func schemaMetadata(in db: Database) throws -> [SchemaMetadata] {
        guard try db.tableExists(StorageMigrations.metadataTable) else { return [] }
        return try Row.fetchAll(
            db,
            sql: """
            SELECT migration_identifier, schema_version, application_version
            FROM \(StorageMigrations.metadataTable)
            ORDER BY rowid
            """
        ).map { row in
            SchemaMetadata(
                migrationIdentifier: row["migration_identifier"],
                schemaVersion: row["schema_version"],
                applicationVersion: row["application_version"]
            )
        }
    }

    static func migrationIdentifiers(in db: Database) throws -> [String] {
        guard try db.tableExists("grdb_migrations") else { return [] }
        return try String.fetchAll(
            db,
            sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid"
        )
    }

    static func foreignKeyViolations(in db: Database) throws -> [String] {
        let rows = try Row.fetchAll(db, sql: "PRAGMA foreign_key_check")
        return rows.enumerated().map { index, _ in
            "foreign_key_check row \(index + 1)"
        }
    }

    static func createConsistentStage(
        from source: URL,
        to stage: URL,
        fileManager: FileManager
    ) throws {
        removeSQLiteFiles(at: stage, fileManager: fileManager)

        var sourceConfiguration = Configuration()
        sourceConfiguration.readonly = true
        sourceConfiguration.foreignKeysEnabled = true
        sourceConfiguration.maximumReaderCount = 1
        let sourceQueue = try DatabaseQueue(
            path: source.standardizedFileURL.path,
            configuration: sourceConfiguration
        )

        var destinationConfiguration = Configuration()
        destinationConfiguration.foreignKeysEnabled = true
        destinationConfiguration.journalMode = .wal
        destinationConfiguration.maximumReaderCount = 1
        let destinationQueue = try DatabaseQueue(
            path: stage.standardizedFileURL.path,
            configuration: destinationConfiguration
        )
        defer {
            try? destinationQueue.close()
            try? sourceQueue.close()
        }

        // A direct primary/WAL copy can observe a live source between WAL
        // frames. GRDB's online backup reads one consistent source snapshot.
        try sourceQueue.backup(to: destinationQueue)
    }

    static func validateRestoreCandidate(
        at url: URL,
        expectedSchema: StorageSchemaSnapshot,
        expectedSchemaObjects: [String],
        expectedMetadata: [SchemaMetadata],
        expectedMigrationIdentifiers: [String]
    ) throws {
        var configuration = Configuration()
        configuration.readonly = true
        configuration.foreignKeysEnabled = true
        configuration.maximumReaderCount = 1
        let queue = try DatabaseQueue(path: url.standardizedFileURL.path, configuration: configuration)
        defer { try? queue.close() }

        try queue.read { db in
            let integrityMessages = try String.fetchAll(db, sql: "PRAGMA integrity_check")
            guard integrityMessages.count == 1,
                  integrityMessages[0].caseInsensitiveCompare("ok") == .orderedSame else {
                throw StorageLifecycleError.integrityCheckFailed(
                    integrityMessages.isEmpty ? ["integrity check failed"] : integrityMessages
                )
            }

            let foreignKeyViolations = try foreignKeyViolations(in: db)
            guard foreignKeyViolations.isEmpty else {
                throw StorageLifecycleError.foreignKeyCheckFailed(foreignKeyViolations)
            }

            let actualSchema = try schemaSnapshot(in: db)
            try validateRequiredTables(in: actualSchema)
            guard actualSchema == expectedSchema,
                  try schemaObjectDefinitions(in: db) == expectedSchemaObjects else {
                throw StorageLifecycleError.schemaMismatch(
                    migrationIdentifier: "restore-current-schema"
                )
            }
            let actualMetadata = try schemaMetadata(in: db)
            let actualContract = actualMetadata.map {
                "\($0.migrationIdentifier)|\($0.schemaVersion)"
            }
            let expectedContract = expectedMetadata.map {
                "\($0.migrationIdentifier)|\($0.schemaVersion)"
            }
            guard actualContract == expectedContract,
                  actualMetadata.allSatisfy({ !$0.applicationVersion.isEmpty }) else {
                throw StorageLifecycleError.restoreFailed("migration metadata mismatch")
            }
            guard try migrationIdentifiers(in: db) == expectedMigrationIdentifiers else {
                throw StorageLifecycleError.restoreFailed("GRDB migration ledger mismatch")
            }
        }
    }

    static func resetAutoincrementSequences(in db: Database) throws {
        guard try Int.fetchOne(
            db,
            sql: "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'sqlite_sequence'"
        ) != nil else {
            return
        }
        // This database is wholly owned by Loopr. Reset every sequence so a
        // feature-owned table added after this release cannot retain deletion
        // metadata merely because it was absent from a hand-maintained list.
        try db.execute(sql: "DELETE FROM sqlite_sequence")
    }

    static func restoreSyncCursorSeed(in db: Database, tables: Set<String>) throws {
        guard tables.contains("sync_cursor") else { return }
        try db.execute(
            sql: """
            INSERT INTO sync_cursor(
                id, token, counter_high_water, timestamp_high_water, updated_at
            ) VALUES (1, NULL, NULL, NULL, 0)
            ON CONFLICT(id) DO UPDATE SET
                token = excluded.token,
                counter_high_water = excluded.counter_high_water,
                timestamp_high_water = excluded.timestamp_high_water,
                updated_at = excluded.updated_at
            """
        )
    }

    static func millisecondsRange(for seconds: Range<Int64>) throws -> Range<Int64> {
        let lower = seconds.lowerBound.multipliedReportingOverflow(by: 1_000)
        let upper = seconds.upperBound.multipliedReportingOverflow(by: 1_000)
        guard !lower.overflow, !upper.overflow, lower.partialValue < upper.partialValue else {
            throw StorageLifecycleError.invalidLocalDay
        }
        return lower.partialValue..<upper.partialValue
    }

    static func crossDayWorkoutIDs(
        in db: Database,
        timestampRange: Range<Int64>,
        routeTimestampRange: Range<Int64>,
        tables: Set<String>
    ) throws -> [String] {
        guard tables.contains("workout") else { return [] }

        var ids = try String.fetchAll(
            db,
            sql: """
            SELECT id
            FROM workout
            WHERE (started_at IS NULL OR started_at < ?)
              AND (ended_at IS NULL OR ended_at > ?)
              AND NOT (
                  started_at IS NOT NULL
                  AND ended_at IS NOT NULL
                  AND started_at >= ?
                  AND ended_at <= ?
              )
            ORDER BY id
            """,
            arguments: [
                timestampRange.upperBound,
                timestampRange.lowerBound,
                timestampRange.lowerBound,
                timestampRange.upperBound
            ]
        )

        // A wholly-contained workout can still carry an out-of-window route
        // point. Deleting that workout would cascade the adjacent point, so it
        // is treated as unsupported rather than silently losing it.
        guard tables.contains("route_point") else { return ids }
        let routeIDs = try String.fetchAll(
            db,
            sql: """
            SELECT DISTINCT w.id
            FROM workout w
            JOIN route_point p ON p.workout_id = w.id
            WHERE w.started_at >= ?
              AND w.ended_at <= ?
              AND (
                  p.timestamp_milliseconds < ?
                  OR p.timestamp_milliseconds >= ?
              )
            ORDER BY w.id
            """,
            arguments: [
                timestampRange.lowerBound,
                timestampRange.upperBound,
                routeTimestampRange.lowerBound,
                routeTimestampRange.upperBound
            ]
        )
        ids.append(contentsOf: routeIDs)
        return Array(Set(ids)).sorted()
    }

    static func requiredTableNames() -> [String] {
        StorageDatabase.requiredLedgerTableNames + Gen5StorageSchema.tableNames + ["release_action_audit"]
    }

    static func validateRequiredTables(in snapshot: StorageSchemaSnapshot) throws {
        let missing = requiredTableNames().filter { !snapshot.tableNames.contains($0) }
        guard missing.isEmpty else {
            throw StorageLifecycleError.missingRequiredTables(missing)
        }
    }

    static func integrityFailure(for url: URL) -> StorageLifecycleError? {
        let result = StorageDatabase.integrityCheck(at: url)
        guard case .failed(let failure) = result else { return nil }
        return .integrityCheckFailed(failure.messages)
    }

    static func unixSeconds(forISO8601Day localDay: String) -> Range<Int64>? {
        let components = localDay.split(separator: "-").compactMap { Int($0) }
        guard components.count == 3,
              components[0] >= 1,
              components[1] >= 1,
              components[1] <= 12,
              components[2] >= 1,
              components[2] <= 31 else {
            return nil
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let startDate = calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: components[0],
            month: components[1],
            day: components[2]
        )), let endDate = calendar.date(byAdding: .day, value: 1, to: startDate) else {
            return nil
        }

        let start = Int64(startDate.timeIntervalSince1970)
        let end = Int64(endDate.timeIntervalSince1970)
        return start..<end
    }
}

public extension StorageDatabase {
    /// Exports the database through the STO-01 online-backup primitive. The
    /// destination is integrity checked and schema checked before this method
    /// returns; no second export implementation exists.
    @discardableResult
    func export(to destinationURL: URL) throws -> URL {
        let destination = destinationURL.standardizedFileURL
        guard destination.path != path else { throw StorageLifecycleError.sameFile }

        try backup(to: destination)
        if let failure = StorageLifecycleInternals.integrityFailure(for: destination) {
            throw failure
        }
        try StorageLifecycleInternals.validateRequiredTables(
            in: StorageDatabase.schemaSnapshot(at: destination)
        )
        return destination
    }

    @discardableResult
    func export(to destinationPath: String) throws -> URL {
        try export(to: URL(fileURLWithPath: destinationPath))
    }

    /// An explicit spelling for callers that prefer a verb rather than the
    /// short `export(to:)` API.
    @discardableResult
    func exportDatabase(to destinationURL: URL) throws -> URL {
        try export(to: destinationURL)
    }

    /// Returns row counts for every user table, including metadata and GRDB's
    /// migration ledger. Counts are useful for deterministic export/restore
    /// verification without exposing GRDB rows as a public storage contract.
    func tableRowCounts() throws -> [String: Int64] {
        try read { db in
            var counts: [String: Int64] = [:]
            for tableName in try StorageLifecycleInternals.userTableNames(in: db) {
                counts[tableName] = try Int64.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM \(StorageLifecycleInternals.quotedIdentifier(tableName))"
                ) ?? 0
            }
            return counts
        }
    }

    /// Returns the complete table/column/constraint snapshot of the live
    /// database.
    func schemaSnapshot() throws -> StorageSchemaSnapshot {
        try read { db in
            try StorageLifecycleInternals.schemaSnapshot(in: db)
        }
    }

    /// Introspects a database without applying migrations or mutating it.
    static func schemaSnapshot(at url: URL) throws -> StorageSchemaSnapshot {
        var configuration = Configuration()
        configuration.readonly = true
        configuration.foreignKeysEnabled = true
        configuration.maximumReaderCount = 1
        let queue = try DatabaseQueue(path: url.standardizedFileURL.path, configuration: configuration)
        defer { try? queue.close() }
        return try queue.read { db in
            try StorageLifecycleInternals.schemaSnapshot(in: db)
        }
    }

    static func schemaSnapshot(at path: String) throws -> StorageSchemaSnapshot {
        try schemaSnapshot(at: URL(fileURLWithPath: path))
    }

    /// Atomically restores a validated export. Validation and staging happen
    /// while the live pool is open. Only after the staged file has passed
    /// integrity and schema validation is the pool closed and the primary file
    /// swapped. A consistent backup of the old live file provides rollback if
    /// reopening the replacement unexpectedly fails.
    func restore(
        from backupURL: URL,
        applicationVersion: String? = nil
    ) throws -> StorageDatabase {
        StorageLifecycleInternals.restoreLock.lock()
        defer { StorageLifecycleInternals.restoreLock.unlock() }

        let source = backupURL.standardizedFileURL
        let target = URL(fileURLWithPath: path).standardizedFileURL
        guard source.path != target.path else { throw StorageLifecycleError.sameFile }

        let expectedSchema = try schemaSnapshot()
        let expectedSchemaObjects = try read { db in
            try StorageLifecycleInternals.schemaObjectDefinitions(in: db)
        }
        let expectedMetadata = try schemaMetadata()
        let expectedMigrationIdentifiers = try read { db in
            try StorageLifecycleInternals.migrationIdentifiers(in: db)
        }

        let fileManager = FileManager.default
        let directory = target.deletingLastPathComponent()
        let baseName = target.deletingPathExtension().lastPathComponent
        let restoreID = UUID().uuidString
        let stagedURL = directory.appendingPathComponent(
            ".\(baseName).restore-stage-\(restoreID).sqlite"
        )
        let originalURL = directory.appendingPathComponent(
            ".\(baseName).restore-original-\(restoreID).sqlite"
        )
        StorageLifecycleInternals.removeSQLiteFiles(at: stagedURL, fileManager: fileManager)
        StorageLifecycleInternals.removeSQLiteFiles(at: originalURL, fileManager: fileManager)

        var primaryReplaced = false
        var reopenedDatabase: StorageDatabase?

        do {
            try StorageLifecycleInternals.createConsistentStage(
                from: source,
                to: stagedURL,
                fileManager: fileManager
            )
            try StorageLifecycleInternals.validateRestoreCandidate(
                at: stagedURL,
                expectedSchema: expectedSchema,
                expectedSchemaObjects: expectedSchemaObjects,
                expectedMetadata: expectedMetadata,
                expectedMigrationIdentifiers: expectedMigrationIdentifiers
            )

            // Capture the currently live state before closing the pool. This
            // is also the rollback image if the replacement cannot reopen.
            try backup(to: originalURL)
            try databasePool.close()

            // Leave the primary file in place so replaceItem performs an
            // atomic replacement. Only stale sidecars must be removed.
            StorageLifecycleInternals.removeSQLiteSidecars(at: target, fileManager: fileManager)
            if fileManager.fileExists(atPath: target.path) {
                _ = try fileManager.replaceItem(
                    at: target,
                    withItemAt: stagedURL,
                    backupItemName: nil,
                    options: [],
                    resultingItemURL: nil
                )
            } else {
                try fileManager.moveItem(at: stagedURL, to: target)
            }
            primaryReplaced = true
            try StorageLifecycleInternals.moveSQLiteSidecars(
                from: stagedURL,
                to: target,
                fileManager: fileManager
            )

            let restored = try StorageDatabase(
                url: target,
                applicationVersion: applicationVersion ?? self.applicationVersion
            )
            // Keep the newly opened pool reachable by the rollback path even
            // when the post-open validation below fails.  Otherwise SQLite can
            // still hold the replacement file open while the rollback copy is
            // being installed.
            reopenedDatabase = restored
            try StorageLifecycleInternals.validateRestoreCandidate(
                at: target,
                expectedSchema: expectedSchema,
                expectedSchemaObjects: expectedSchemaObjects,
                expectedMetadata: expectedMetadata,
                expectedMigrationIdentifiers: expectedMigrationIdentifiers
            )
            reopenedDatabase = restored
            StorageLifecycleInternals.removeSQLiteFiles(at: originalURL, fileManager: fileManager)
            StorageLifecycleInternals.removeSQLiteFiles(at: stagedURL, fileManager: fileManager)
            return restored
        } catch {
            // Once the primary has been replaced, every subsequent failure —
            // including a half-moved sidecar or failed reopen — must restore
            // the original primary and sidecars before the error escapes.
            var rollbackFailure: Error?
            if primaryReplaced {
                try? reopenedDatabase?.databasePool.close()
                do {
                    try StorageLifecycleInternals.restoreSnapshot(
                        from: originalURL,
                        to: target,
                        fileManager: fileManager
                    )
                } catch {
                    rollbackFailure = error
                }
            }

            StorageLifecycleInternals.removeSQLiteFiles(at: stagedURL, fileManager: fileManager)
            if !primaryReplaced || rollbackFailure == nil {
                StorageLifecycleInternals.removeSQLiteFiles(at: originalURL, fileManager: fileManager)
            }
            if let rollbackFailure {
                throw StorageLifecycleError.restoreFailed(
                    "\(error); rollback failed: \(rollbackFailure)"
                )
            }
            if let lifecycleError = error as? StorageLifecycleError {
                throw lifecycleError
            }
            throw StorageLifecycleError.restoreFailed(String(describing: error))
        }
    }

    /// Static restore convenience for code that has only a database URL.
    static func restore(
        from backupURL: URL,
        replacing databaseURL: URL,
        applicationVersion: String = StorageDatabase.defaultApplicationVersion
    ) throws -> StorageDatabase {
        let live = try StorageDatabase(url: databaseURL, applicationVersion: applicationVersion)
        return try live.restore(from: backupURL, applicationVersion: applicationVersion)
    }

    /// Deletes the canonical StorageKit ledger in one transaction while
    /// preserving extension-owned tables, schema metadata, GRDB's migration
    /// ledger, and the seeded synchronization cursor.
    func deleteAllData() throws {
        try write { db in
            let tables = Set(try StorageLifecycleInternals.userTableNames(in: db))
            for tableName in StorageLifecycleInternals.requiredTableNames()
                where tables.contains(tableName) {
                try db.execute(
                    sql: "DELETE FROM \(StorageLifecycleInternals.quotedIdentifier(tableName))"
                )
            }
            try StorageLifecycleInternals.resetAutoincrementSequences(in: db)
            try StorageLifecycleInternals.restoreSyncCursorSeed(in: db, tables: tables)
        }
    }

    /// Deletes all account data from this Loopr-owned database. This is the
    /// destructive account-closure primitive, not the ledger-only maintenance
    /// API above. Live-schema discovery prevents a newly introduced feature
    /// table from being omitted by a stale deletion list.
    func deleteAllAccountData() throws {
        try write { db in
            let tables = Set(try StorageLifecycleInternals.userTableNames(in: db))
            let preservedTables: Set<String> = [
                StorageMigrations.metadataTable,
                "grdb_migrations",
                "analytics_input_revision"
            ]
            try db.execute(sql: "PRAGMA defer_foreign_keys = ON")
            for tableName in tables.subtracting(preservedTables).sorted() {
                try db.execute(
                    sql: "DELETE FROM \(StorageLifecycleInternals.quotedIdentifier(tableName))"
                )
            }
            if tables.contains("analytics_range_revision") { try db.execute(sql: "DELETE FROM analytics_range_revision") }
            try StorageLifecycleInternals.resetAutoincrementSequences(in: db)
            try StorageLifecycleInternals.restoreSyncCursorSeed(in: db, tables: tables)
        }
    }

    func deleteAllUserData() throws {
        try deleteAllData()
    }

    /// Deletes all records belonging to one local day. Day-keyed tables are
    /// discovered from the migrated schema; epoch-only tables use the supplied
    /// range, or a UTC ISO-date range when the key is YYYY-MM-DD. RR rows
    /// disappear through their declared cascades. Route points are owned by
    /// their millisecond timestamp and are deleted directly so an adjacent
    /// day's point is never removed as a side effect.
    func delete(localDay: String) throws {
        guard let timestampRange = StorageLifecycleInternals.unixSeconds(forISO8601Day: localDay) else {
            throw StorageLifecycleError.invalidLocalDay
        }
        try delete(localDay: localDay, timestampRange: timestampRange)
    }

    func delete(localDay: String, timestampRange: Range<Int64>) throws {
        guard !timestampRange.isEmpty else { throw StorageLifecycleError.invalidLocalDay }
        try delete(localDay: localDay, timestampRange: Optional(timestampRange))
    }

    func delete(localDayWindow: StorageLocalDayWindow) throws {
        try delete(localDay: localDayWindow.localDay, timestampRange: localDayWindow.unixSeconds)
    }

    func deleteData(forLocalDay localDay: String) throws {
        try delete(localDay: localDay)
    }

    private func delete(localDay: String, timestampRange: Range<Int64>?) throws {
        guard !localDay.isEmpty else { throw StorageLifecycleError.invalidLocalDay }

        try write { db in
            let tables = Set(try StorageLifecycleInternals.userTableNames(in: db))
            let decodedTableExists = tables.contains("decoded_second")
            let routeTimestampRange = try timestampRange.map {
                try StorageLifecycleInternals.millisecondsRange(for: $0)
            }

            // A workout is an indivisible row and its payload may contain
            // aggregate data for the whole activity. Deleting an overlapping
            // cross-midnight row would therefore either erase an adjacent day
            // or leave target-day data behind. Reject it before the first
            // mutation. The same guard covers inconsistent route timestamps
            // that a cascade would otherwise destroy with an adjacent day.
            if let timestampRange,
               let routeTimestampRange,
               tables.contains("workout") {
                let crossDayWorkoutIDs = try StorageLifecycleInternals.crossDayWorkoutIDs(
                    in: db,
                    timestampRange: timestampRange,
                    routeTimestampRange: routeTimestampRange,
                    tables: tables
                )
                guard crossDayWorkoutIDs.isEmpty else {
                    throw StorageLifecycleError.crossDayWorkoutDeletionUnsupported(crossDayWorkoutIDs)
                }
            }

            // raw_archive intentionally has no local_day column. Delete
            // its payloads by canonical timestamp before deleting the
            // decoded rows, and also handle archive capture times.
            if tables.contains("raw_archive") && decodedTableExists {
                try db.execute(
                    sql: """
                    DELETE FROM raw_archive
                    WHERE physiological_timestamp IN (
                        SELECT physiological_timestamp FROM decoded_second WHERE local_day = ?
                    )
                    """,
                    arguments: [localDay]
                )
            }
            if let timestampRange, tables.contains("raw_archive") {
                try db.execute(
                    sql: """
                    DELETE FROM raw_archive
                    WHERE captured_at >= ? AND captured_at < ?
                    """,
                    arguments: [timestampRange.lowerBound, timestampRange.upperBound]
                )
            }

            // Only wholly-contained workouts are deleted. Their route points
            // are removed by the declared cascade after the preflight above
            // has proved that no adjacent-day point would be lost.
            if let timestampRange, tables.contains("workout") {
                try db.execute(
                    sql: """
                    DELETE FROM workout
                    WHERE started_at >= ?
                      AND ended_at <= ?
                    """,
                    arguments: [timestampRange.lowerBound, timestampRange.upperBound]
                )
            }

            // Route points have no local_day column. Derive ownership from
            // their timestamp in milliseconds and delete only the requested
            // half-open window. This also handles points attached to a
            // non-day-scoped/incomplete workout without touching neighbours.
            if let routeTimestampRange, tables.contains("route_point") {
                try db.execute(
                    sql: """
                    DELETE FROM route_point
                    WHERE timestamp_milliseconds >= ?
                      AND timestamp_milliseconds < ?
                    """,
                    arguments: [
                        routeTimestampRange.lowerBound,
                        routeTimestampRange.upperBound
                    ]
                )
            }

            for tableName in StorageLifecycleInternals.requiredTableNames()
                where tables.contains(tableName) {
                let columns = Set(try db.columns(in: tableName).map(\.name))
                if columns.contains("local_day") {
                    try db.execute(
                        sql: "DELETE FROM \(StorageLifecycleInternals.quotedIdentifier(tableName)) WHERE local_day = ?",
                        arguments: [localDay]
                    )
                }
                if columns.contains("day_id") {
                    try db.execute(
                        sql: "DELETE FROM \(StorageLifecycleInternals.quotedIdentifier(tableName)) WHERE day_id = ?",
                        arguments: [localDay]
                    )
                }
            }
        }
    }
}

/// A deterministic migration harness for every migration identifier currently
/// registered by StorageKit. Each prior version is materialized, then reopened
/// through the production migrator so all subsequent migrations are exercised.
public enum StorageMigrationHarness {
    public static func registeredMigrationIdentifiers(
        applicationVersion: String = StorageDatabase.defaultApplicationVersion
    ) -> [String] {
        StorageMigrations.makeMigrator(applicationVersion: applicationVersion).migrations
    }

    public static func verifyAllRegisteredVersions(
        applicationVersion: String = StorageDatabase.defaultApplicationVersion,
        directory: URL? = nil
    ) throws -> [StorageMigrationVerification] {
        let fileManager = FileManager.default
        let root = (directory ?? fileManager.temporaryDirectory
            .appendingPathComponent("LooprStorageMigrationHarness", isDirectory: true))
            .standardizedFileURL
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        let freshURL = root.appendingPathComponent("fresh.sqlite")
        StorageLifecycleInternals.removeSQLiteFiles(at: freshURL, fileManager: fileManager)
        defer {
            StorageLifecycleInternals.removeSQLiteFiles(at: freshURL, fileManager: fileManager)
            for identifier in registeredMigrationIdentifiers(applicationVersion: applicationVersion) {
                let safeIdentifier = identifier.replacingOccurrences(of: "/", with: "_")
                StorageLifecycleInternals.removeSQLiteFiles(
                    at: root.appendingPathComponent("\(safeIdentifier).sqlite"),
                    fileManager: fileManager
                )
            }
        }

        let fresh = try StorageDatabase(url: freshURL, applicationVersion: applicationVersion)
        let expected = try fresh.schemaSnapshot()
        try fresh.databasePool.close()

        let migrator = StorageMigrations.makeMigrator(applicationVersion: applicationVersion)
        var verification: [StorageMigrationVerification] = []
        for identifier in migrator.migrations {
            let safeIdentifier = identifier.replacingOccurrences(of: "/", with: "_")
            let versionURL = root.appendingPathComponent("\(safeIdentifier).sqlite")
            StorageLifecycleInternals.removeSQLiteFiles(at: versionURL, fileManager: fileManager)

            var configuration = Configuration()
            configuration.foreignKeysEnabled = true
            configuration.journalMode = .wal
            let queue = try DatabaseQueue(path: versionURL.path, configuration: configuration)
            try migrator.migrate(queue, upTo: identifier)
            try queue.close()

            let migrated = try StorageDatabase(url: versionURL, applicationVersion: applicationVersion)
            let actual = try migrated.schemaSnapshot()
            try migrated.databasePool.close()
            guard actual.isEquivalent(to: expected) else {
                throw StorageLifecycleError.schemaMismatch(migrationIdentifier: identifier)
            }
            verification.append(
                StorageMigrationVerification(
                    migrationIdentifier: identifier,
                    schemaMatchesCurrent: true
                )
            )
        }
        return verification
    }

    public static func verifyAllMigrations(
        applicationVersion: String = StorageDatabase.defaultApplicationVersion,
        directory: URL? = nil
    ) throws -> [StorageMigrationVerification] {
        try verifyAllRegisteredVersions(
            applicationVersion: applicationVersion,
            directory: directory
        )
    }
}
