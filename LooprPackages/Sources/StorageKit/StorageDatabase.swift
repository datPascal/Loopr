import Foundation
@_exported import GRDB
import os

/// Launch timing for database opens. Matches `LooprPerformance` in
/// DesignSystem, which StorageKit cannot import.
enum StorageSignposts {
    static let signposter = OSSignposter(subsystem: "com.loopr.ios", category: .pointsOfInterest)
    static let logger = Logger(subsystem: "com.loopr.ios", category: "Performance")

    static func measure<T>(_ name: StaticString, _ detail: String, _ work: () throws -> T) rethrows -> T {
        let state = signposter.beginInterval(name, id: signposter.makeSignpostID(), "\(detail, privacy: .public)")
        let start = DispatchTime.now().uptimeNanoseconds
        defer {
            signposter.endInterval(name, state)
            let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            let thread = Thread.isMainThread ? "main" : "background"
            logger.notice("interval \(String(describing: name), privacy: .public) \(detail, privacy: .public) \(milliseconds, format: .fixed(precision: 1), privacy: .public) ms on \(thread, privacy: .public)")
        }
        return try work()
    }
}

/// The identifiers of the migrations owned by StorageKit.
///
/// Migration identifiers are durable database data. They must not be renamed or
/// removed after a release; add a new identifier for every schema change.
public enum StorageMigrationIdentifier {
    public static let schemaMetadata = "storage-001-schema-metadata"
}

/// A row in the schema metadata ledger.
public struct SchemaMetadata: Sendable, Equatable {
    public let migrationIdentifier: String
    public let schemaVersion: String
    public let applicationVersion: String

    public init(
        migrationIdentifier: String,
        schemaVersion: String,
        applicationVersion: String
    ) {
        self.migrationIdentifier = migrationIdentifier
        self.schemaVersion = schemaVersion
        self.applicationVersion = applicationVersion
    }
}

/// A typed result of SQLite's `PRAGMA integrity_check`.
public enum IntegrityCheckResult: Sendable, Equatable {
    /// SQLite reported a healthy database.
    case ok

    /// SQLite reported corruption, or the check could not be executed.
    case failed(IntegrityCheckFailure)

    public var isHealthy: Bool {
        if case .ok = self { return true }
        return false
    }

    public var messages: [String] {
        switch self {
        case .ok:
            return ["ok"]
        case .failed(let failure):
            return failure.messages
        }
    }
}

public typealias DatabaseIntegrityResult = IntegrityCheckResult

/// Details returned when an integrity check does not report `ok`.
public struct IntegrityCheckFailure: Error, Sendable, Equatable, LocalizedError {
    public let messages: [String]

    public init(messages: [String]) {
        self.messages = messages.isEmpty ? ["integrity check failed"] : messages
    }

    public var errorDescription: String? {
        messages.joined(separator: "\n")
    }
}

public enum StorageError: Error, Sendable, Equatable, LocalizedError {
    case invalidApplicationVersion
    case sourceAndDestinationAreTheSame
    case fileProtectionApplicationFailed(path: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .invalidApplicationVersion:
            return "The application version must not be empty."
        case .sourceAndDestinationAreTheSame:
            return "A database cannot be backed up to itself."
        case .fileProtectionApplicationFailed(let path, let reason):
            return "Could not apply database file protection to \(path): \(reason)"
        }
    }
}

/// Builds the explicit, ordered migrations owned by StorageKit.
public enum StorageMigrations {
    public static let metadataTable = "storage_schema_metadata"

    public static func makeMigrator(applicationVersion: String) -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration(StorageMigrationIdentifier.schemaMetadata) { db in
            try db.create(table: metadataTable) { table in
                table.column("migration_identifier", .text).primaryKey()
                table.column("schema_version", .text).notNull()
                table.column("application_version", .text).notNull()
            }

            try db.execute(
                sql: """
                INSERT INTO \(metadataTable)
                    (migration_identifier, schema_version, application_version)
                VALUES (?, ?, ?)
                """,
                arguments: [
                    StorageMigrationIdentifier.schemaMetadata,
                    "1",
                    applicationVersion
                ]
            )
        }
        registerSensorLedgerMigration(
            on: &migrator,
            applicationVersion: applicationVersion
        )
        registerGen5BetaMigration(
            on: &migrator,
            applicationVersion: applicationVersion
        )
        registerReleaseAuditMigration(
            on: &migrator,
            applicationVersion: applicationVersion
        )
        registerAnalyticsRevisionMigration(on: &migrator, applicationVersion: applicationVersion)
        registerV24ADCFieldsMigration(on: &migrator, applicationVersion: applicationVersion)
        registerMetricSeriesSourceMigration(on: &migrator, applicationVersion: applicationVersion)
        registerSkinTemperatureMigration(on: &migrator, applicationVersion: applicationVersion)
        return migrator
    }
}

/// The configured GRDB database used by Loopr's persistence layer.
///
/// `DatabasePool` owns one serialized writer and a pool of read-only
/// connections. StorageDatabase does not expose schema-reset behavior: schema
/// evolution is always performed by the explicit migrations in
/// `StorageMigrations`.
public final class StorageDatabase: @unchecked Sendable {
    public static let defaultReaderCount = 5

    /// The protection class applied to the database and its SQLite sidecars.
    ///
    /// This permits callers and tests to share the exact policy that is
    /// applied by `applyFileProtection()`. The class remains available after
    /// first unlock while protecting data at rest before the first unlock.
    public static let fileProtectionClass: FileProtectionType =
        .completeUntilFirstUserAuthentication

    /// A non-empty fallback used by package tests and previews when no app
    /// bundle version is available.
    public static var defaultApplicationVersion: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let marketing = info["CFBundleShortVersionString"] as? String
        let build = info["CFBundleVersion"] as? String

        switch (marketing?.isEmpty == false, build?.isEmpty == false) {
        case (true, true):
            return "\(marketing!) (\(build!))"
        case (true, false):
            return marketing!
        case (false, true):
            return build!
        case (false, false):
            return "0.1 (0)"
        }
    }

    public let path: String
    public let applicationVersion: String
    public let databasePool: DatabasePool
    public let migrator: DatabaseMigrator

    /// When the cold-launch integrity check runs.
    public enum IntegrityCheckTiming: Sendable, Equatable {
        /// Inside `init`, before the database is handed out.
        case onOpen
        /// On the first read of `coldLaunchIntegrityResult`. The caller
        /// owns running it, for example in a utility-priority task once the
        /// first frame is up. A large history file takes seconds to check,
        /// and the launch path must not wait for it.
        case deferred
    }

    /// The integrity result for this open of the database.
    ///
    /// Every open records this result once so a cold launch can surface a
    /// recoverable integrity problem without silently continuing on corrupt
    /// data. With `.onOpen` it is captured inside `init`; with `.deferred` the
    /// first read runs the full check and later reads return the same value.
    /// Call `integrityCheck()` whenever a fresh on-demand check is required.
    public var coldLaunchIntegrityResult: IntegrityCheckResult {
        coldLaunchIntegrity.value { Self.runIntegrityCheck(on: databasePool, label: fileName) }
    }

    /// Whether the cold-launch check has already produced its result.
    public var hasColdLaunchIntegrityResult: Bool { coldLaunchIntegrity.isResolved }

    public var pool: DatabasePool { databasePool }

    private let coldLaunchIntegrity = ColdLaunchIntegrity()
    private let completedSetup = CompletedSetup()

    /// Runs idempotent schema setup at most once per open database, such as
    /// the `CREATE TABLE IF NOT EXISTS` every document store issues. The key
    /// is recorded only when `work` succeeds, so a failure is retried by the
    /// next caller.
    public func performSetupOnce(_ key: String, _ work: () throws -> Void) rethrows {
        try completedSetup.perform(key, work)
    }
    private var fileName: String { URL(fileURLWithPath: path).lastPathComponent }

    public convenience init(
        path: String,
        applicationVersion: String = StorageDatabase.defaultApplicationVersion
    ) throws {
        try self.init(
            url: URL(fileURLWithPath: path),
            applicationVersion: applicationVersion
        )
    }

    public init(
        url: URL,
        applicationVersion: String = StorageDatabase.defaultApplicationVersion,
        integrityCheck timing: IntegrityCheckTiming = .onOpen
    ) throws {
        let version = applicationVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !version.isEmpty else { throw StorageError.invalidApplicationVersion }

        let databaseURL = url.standardizedFileURL
        let fileManager = FileManager.default
        let directory = databaseURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.journalMode = .wal
        configuration.maximumReaderCount = Self.defaultReaderCount

        let fileName = databaseURL.lastPathComponent
        let (pool, migrations) = try StorageSignposts.measure("StorageOpen", fileName) {
            let pool = try DatabasePool(path: databaseURL.path, configuration: configuration)
            let migrations = StorageMigrations.makeMigrator(applicationVersion: version)
            try migrations.migrate(pool)
            try Self.applyFileProtection(
                to: databaseURL,
                fileManager: fileManager
            )
            return (pool, migrations)
        }

        self.path = databaseURL.path
        self.applicationVersion = version
        self.databasePool = pool
        self.migrator = migrations
        if timing == .onOpen {
            _ = coldLaunchIntegrityResult
        }
    }

    /// Reads using one of the pool's concurrent read connections.
    public func read<T>(_ value: (Database) throws -> T) throws -> T {
        try databasePool.read(value)
    }

    /// Writes through the pool's single serialized writer connection.
    public func write<T>(_ updates: (Database) throws -> T) throws -> T {
        try databasePool.write(updates)
    }

    /// Executes a read-only SQL scalar query. This small convenience keeps
    /// package consumers from needing to construct a second pool just to
    /// inspect database configuration or metadata.
    public func readString(sql: String, arguments: StatementArguments = []) throws -> String? {
        try databasePool.read { db in
            try String.fetchOne(db, sql: sql, arguments: arguments)
        }
    }

    public func readInteger(sql: String, arguments: StatementArguments = []) throws -> Int64? {
        try databasePool.read { db in
            try Int64.fetchOne(db, sql: sql, arguments: arguments)
        }
    }

    /// Returns true when all registered migrations have been applied.
    public func hasPendingMigrations() throws -> Bool {
        try databasePool.read { db in
            try !migrator.hasCompletedMigrations(db)
        }
    }

    /// Returns metadata for every migration, in migration order.
    public func schemaMetadata() throws -> [SchemaMetadata] {
        try databasePool.read { db in
            try Row.fetchAll(
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
    }

    /// Runs SQLite's full integrity check and converts both corruption and
    /// low-level SQLite errors into a typed failure result.
    public func integrityCheck() throws -> IntegrityCheckResult {
        Self.runIntegrityCheck(on: databasePool, label: fileName)
    }

    /// Runs an integrity check on an existing database file without applying
    /// migrations. This is useful to inspect a copy after an abnormal
    /// termination or while deciding whether a restore is safe.
    public static func integrityCheck(at url: URL) -> IntegrityCheckResult {
        var configuration = Configuration()
        configuration.readonly = true
        configuration.foreignKeysEnabled = true
        configuration.maximumReaderCount = 1
        do {
            let pool = try DatabasePool(path: url.standardizedFileURL.path, configuration: configuration)
            defer { try? pool.close() }
            return runIntegrityCheck(on: pool)
        } catch {
            return .failed(IntegrityCheckFailure(messages: [String(describing: error)]))
        }
    }

    public static func integrityCheck(at path: String) -> IntegrityCheckResult {
        integrityCheck(at: URL(fileURLWithPath: path))
    }

    /// Applies the health-appropriate protection class to the primary file and
    /// any currently materialized WAL/SHM sidecars.
    public func applyFileProtection() throws {
        try Self.applyFileProtection(
            to: URL(fileURLWithPath: path),
            fileManager: .default
        )
    }

    /// Creates a transactionally consistent online backup of this database.
    /// Concurrent source writes may or may not be represented in the backup,
    /// as specified by GRDB's online backup semantics, but never make the
    /// backup internally inconsistent.
    public func backup(to destinationURL: URL) throws {
        let destination = destinationURL.standardizedFileURL
        let source = URL(fileURLWithPath: path).standardizedFileURL
        guard destination.path != source.path else {
            throw StorageError.sourceAndDestinationAreTheSame
        }

        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.journalMode = .wal
        configuration.maximumReaderCount = 1

        let destinationQueue = try DatabaseQueue(
            path: destination.path,
            configuration: configuration
        )
        try databasePool.backup(to: destinationQueue)
        try destinationQueue.close()
        try Self.applyFileProtection(to: destination, fileManager: fileManager)
    }

    public func backup(to destinationPath: String) throws {
        try backup(to: URL(fileURLWithPath: destinationPath))
    }

    public var sidecarPaths: [String] {
        ["\(path)-wal", "\(path)-shm"]
    }

    private static func runIntegrityCheck(on pool: DatabasePool, label: String) -> IntegrityCheckResult {
        StorageSignposts.measure("IntegrityCheck", label) { runIntegrityCheck(on: pool) }
    }

    private static func runIntegrityCheck(on pool: DatabasePool) -> IntegrityCheckResult {
        do {
            let messages = try pool.read { db in
                try String.fetchAll(db, sql: "PRAGMA integrity_check")
            }
            guard messages.count == 1, messages[0].caseInsensitiveCompare("ok") == .orderedSame else {
                return .failed(IntegrityCheckFailure(messages: messages))
            }
            return .ok
        } catch {
            return .failed(IntegrityCheckFailure(messages: [String(describing: error)]))
        }
    }

    private static func applyFileProtection(
        to databaseURL: URL,
        fileManager: FileManager
    ) throws {
        let paths = [
            databaseURL.path,
            "\(databaseURL.path)-wal",
            "\(databaseURL.path)-shm"
        ]
        for path in paths where fileManager.fileExists(atPath: path) {
            do {
                try fileManager.setAttributes(
                    [.protectionKey: Self.fileProtectionClass],
                    ofItemAtPath: path
                )
            } catch {
                throw StorageError.fileProtectionApplicationFailed(
                    path: path,
                    reason: String(describing: error)
                )
            }
        }
    }
}

/// The once-per-open integrity result. Concurrent first readers wait for the
/// one check instead of each running their own.
private final class ColdLaunchIntegrity: @unchecked Sendable {
    private let lock = NSLock()
    private var result: IntegrityCheckResult?

    var isResolved: Bool {
        lock.lock()
        defer { lock.unlock() }
        return result != nil
    }

    func value(_ check: () -> IntegrityCheckResult) -> IntegrityCheckResult {
        lock.lock()
        defer { lock.unlock() }
        if let result { return result }
        let checked = check()
        result = checked
        return checked
    }
}

private final class CompletedSetup: @unchecked Sendable {
    private let lock = NSLock()
    private var keys: Set<String> = []

    func perform(_ key: String, _ work: () throws -> Void) rethrows {
        lock.lock()
        defer { lock.unlock() }
        guard !keys.contains(key) else { return }
        try work()
        keys.insert(key)
    }
}
