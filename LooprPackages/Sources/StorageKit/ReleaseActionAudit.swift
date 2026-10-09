import Foundation
import GRDB

public extension StorageMigrationIdentifier {
    static let releaseActionAudit = "storage-004-release-action-audit"
}

public enum ReleaseActionKind: String, Codable, Sendable {
    case export
    case deletion
}

public struct ReleaseActionAuditRow: Equatable, Sendable {
    public let id: Int64
    public let action: ReleaseActionKind
    public let scope: String
    public let performedAt: Date
}

public enum ReleaseActionAuditError: Error, Equatable, Sendable {
    case confirmationRequired
    case emptyScope
    case invalidStoredAction(String)
}

public extension StorageMigrations {
    static func registerReleaseAuditMigration(
        on migrator: inout DatabaseMigrator,
        applicationVersion: String
    ) {
        migrator.registerMigration(StorageMigrationIdentifier.releaseActionAudit) { db in
            try db.execute(sql: """
                CREATE TABLE release_action_audit (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    action TEXT NOT NULL CHECK(action IN ('export', 'deletion')),
                    scope TEXT NOT NULL CHECK(length(scope) > 0),
                    performed_at REAL NOT NULL
                )
                """)
            try db.execute(
                sql: """
                    INSERT INTO \(StorageMigrations.metadataTable)
                    (migration_identifier, schema_version, application_version)
                    VALUES (?, '4', ?)
                    """,
                arguments: [StorageMigrationIdentifier.releaseActionAudit, applicationVersion]
            )
        }
    }
}

public struct ReleaseActionAuditStore: Sendable {
    private let database: StorageDatabase

    public init(database: StorageDatabase) {
        self.database = database
    }

    @discardableResult
    public func record(
        _ action: ReleaseActionKind,
        scope: String,
        performedAt: Date,
        userConfirmed: Bool
    ) throws -> Int64 {
        guard userConfirmed else { throw ReleaseActionAuditError.confirmationRequired }
        let normalizedScope = scope.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedScope.isEmpty else { throw ReleaseActionAuditError.emptyScope }
        return try database.write { db in
            try db.execute(
                sql: "INSERT INTO release_action_audit(action, scope, performed_at) VALUES (?, ?, ?)",
                arguments: [action.rawValue, normalizedScope, performedAt.timeIntervalSince1970]
            )
            return db.lastInsertedRowID
        }
    }

    public func rows() throws -> [ReleaseActionAuditRow] {
        try database.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM release_action_audit ORDER BY id").map { row in
                let rawAction: String = row["action"]
                guard let action = ReleaseActionKind(rawValue: rawAction) else {
                    throw ReleaseActionAuditError.invalidStoredAction(rawAction)
                }
                return ReleaseActionAuditRow(
                    id: row["id"],
                    action: action,
                    scope: row["scope"],
                    performedAt: Date(timeIntervalSince1970: row["performed_at"])
                )
            }
        }
    }
}
