import Foundation
import GRDB

public extension StorageMigrationIdentifier {
    static let gen5Beta = "storage-003-gen5-beta"
}

public enum Gen5StorageSchema {
    public static let schemaVersion = "3"
    public static let tableNames = [
        "gen5_research_frames",
        "gen5_raw_archive",
        "gen5_v18_canonical",
        "gen5_committed_batch",
        "gen5_capability_state",
        "gen5_band_profile"
    ]

    static func createAll(in db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS gen5_research_frames (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                model TEXT NOT NULL,
                connection_generation INTEGER NOT NULL,
                burst_id TEXT NOT NULL,
                ordinal INTEGER NOT NULL,
                raw_frame BLOB NOT NULL,
                decode_succeeded INTEGER NOT NULL CHECK (decode_succeeded IN (0, 1)),
                decode_outcome TEXT NOT NULL,
                marker BLOB NOT NULL,
                token BLOB CHECK (token IS NULL OR length(token) = 8),
                UNIQUE(connection_generation, burst_id, ordinal)
            );
            CREATE TABLE IF NOT EXISTS gen5_raw_archive (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                model TEXT NOT NULL,
                raw_payload BLOB NOT NULL,
                record_version INTEGER,
                UNIQUE(model, raw_payload)
            );
            CREATE TABLE IF NOT EXISTS gen5_v18_canonical (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                model TEXT NOT NULL,
                physiological_timestamp INTEGER NOT NULL,
                record_index INTEGER NOT NULL,
                heart_rate INTEGER,
                rr_le BLOB NOT NULL,
                gravity_x REAL NOT NULL,
                gravity_y REAL NOT NULL,
                gravity_z REAL NOT NULL,
                UNIQUE(model, physiological_timestamp, record_index)
            );
            CREATE TABLE IF NOT EXISTS gen5_committed_batch (
                model TEXT NOT NULL,
                connection_generation INTEGER NOT NULL,
                burst_id TEXT NOT NULL,
                token BLOB NOT NULL CHECK(length(token) = 8),
                PRIMARY KEY(model, burst_id)
            );
            CREATE TABLE IF NOT EXISTS gen5_capability_state (
                model TEXT NOT NULL,
                capability TEXT NOT NULL,
                state TEXT NOT NULL,
                firmware TEXT,
                PRIMARY KEY(model, capability)
            );
            CREATE TABLE IF NOT EXISTS gen5_band_profile (
                peripheral_id TEXT PRIMARY KEY,
                model TEXT NOT NULL,
                model_confidence REAL NOT NULL CHECK(model_confidence BETWEEN 0 AND 1),
                service_uuid TEXT NOT NULL,
                name TEXT,
                hello_identity BLOB,
                firmware TEXT
            );
            """)
    }
}

public extension StorageMigrations {
    static func registerGen5BetaMigration(
        on migrator: inout DatabaseMigrator,
        applicationVersion: String
    ) {
        migrator.registerMigration(StorageMigrationIdentifier.gen5Beta) { db in
            try Gen5StorageSchema.createAll(in: db)
            try db.execute(
                sql: """
                    INSERT INTO \(StorageMigrations.metadataTable)
                    (migration_identifier, schema_version, application_version)
                    VALUES (?, ?, ?)
                    """,
                arguments: [StorageMigrationIdentifier.gen5Beta,
                            Gen5StorageSchema.schemaVersion, applicationVersion]
            )
        }
    }
}

public struct Gen5ExportRow: Codable, Equatable, Sendable {
    public let model: String
    public let timestamp: Int64
    public let index: Int64
    public let heartRate: Int?
    public let rrLittleEndian: Data
    public let gravityX: Double
    public let gravityY: Double
    public let gravityZ: Double
}

public struct Gen5ValidatedExport: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let validatedV18: [Gen5ExportRow]

    public init(schemaVersion: Int = 1, validatedV18: [Gen5ExportRow]) {
        self.schemaVersion = schemaVersion
        self.validatedV18 = validatedV18
    }
}

public extension StorageDatabase {
    func exportValidatedGen5JSON() throws -> Data {
        let rows: [Gen5ExportRow] = try read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM gen5_v18_canonical ORDER BY physiological_timestamp, record_index")
                .map { row in
                    Gen5ExportRow(
                        model: row["model"], timestamp: row["physiological_timestamp"],
                        index: row["record_index"], heartRate: row["heart_rate"],
                        rrLittleEndian: row["rr_le"], gravityX: row["gravity_x"],
                        gravityY: row["gravity_y"], gravityZ: row["gravity_z"]
                    )
                }
        }
        return try JSONEncoder().encode(Gen5ValidatedExport(validatedV18: rows))
    }
}

public protocol Gen5ExternalDeletionParticipant: Sendable {
    var kind: String { get }
    func deleteGen5Artifacts() async throws
    func remainingGen5Artifacts() async throws -> Int
}

public actor Gen5DeletionCoordinator {
    private let database: StorageDatabase
    private let external: [any Gen5ExternalDeletionParticipant]

    public init(database: StorageDatabase, external: [any Gen5ExternalDeletionParticipant]) {
        self.database = database
        self.external = external
    }

    public func deleteAll() async throws -> [String: Int] {
        try database.write { db in
            for table in Gen5StorageSchema.tableNames {
                try db.execute(sql: "DELETE FROM \(table)")
            }
        }
        for participant in external { try await participant.deleteGen5Artifacts() }
        var remaining: [String: Int] = [:]
        for participant in external {
            remaining[participant.kind] = try await participant.remainingGen5Artifacts()
        }
        for table in Gen5StorageSchema.tableNames {
            remaining[table] = try database.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
            }
        }
        return remaining
    }
}
