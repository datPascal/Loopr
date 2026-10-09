import Foundation

/// The STO-02 migration identifier is kept in this file with the ledger
/// schema so StorageDatabase.swift remains the STO-01 opener/configuration
/// surface.  The owner of the migrator calls
/// `StorageMigrations.registerSensorLedgerMigration` after the metadata step.
public extension StorageMigrationIdentifier {
    static let sensorLedger = "storage-002-sensor-ledger"
}

/// SQL schema owned by STO-02.  Keep these names stable: later migrations and
/// export/deletion packages use the inventory as their dependency contract.
internal enum StorageLedgerSchema {
    static let tableNames: [String] = [
        "decoded_second",
        "rr_beat",
        "raw_archive",
        "sync_cursor",
        "sync_batch",
        "sync_failure",
        "day_result",
        "metric_series",
        "baseline",
        "workout",
        "route_point",
        "health_import_cursor",
        "health_export_item",
        "notification_claim",
        "surface_generation"
    ]

    static func createAll(in db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE decoded_second (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                physiological_timestamp INTEGER NOT NULL UNIQUE,
                band_counter INTEGER NOT NULL,
                absolute_timestamp INTEGER NOT NULL,
                local_day TEXT NOT NULL,
                record_version INTEGER,
                subsecond_ticks INTEGER,
                heart_rate INTEGER,
                gravity_x REAL,
                gravity_y REAL,
                gravity_z REAL,
                raw_payload BLOB
            )
            """)
        try db.execute(sql: """
            CREATE TABLE rr_beat (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                decoded_second_id INTEGER NOT NULL
                    REFERENCES decoded_second(id) ON DELETE CASCADE,
                beat_index INTEGER NOT NULL,
                rr_milliseconds INTEGER NOT NULL,
                beat_timestamp_milliseconds INTEGER,
                UNIQUE(decoded_second_id, beat_index)
            )
            """)
        try db.execute(sql: """
            CREATE TABLE raw_archive (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                raw_payload BLOB NOT NULL UNIQUE,
                packet_type INTEGER,
                record_version INTEGER,
                band_counter INTEGER,
                physiological_timestamp INTEGER,
                captured_at INTEGER NOT NULL,
                reason TEXT NOT NULL
            )
            """)
        try db.execute(sql: """
            CREATE TABLE sync_cursor (
                id INTEGER PRIMARY KEY CHECK (id = 1),
                token BLOB CHECK (token IS NULL OR length(token) = 8),
                counter_high_water INTEGER,
                timestamp_high_water INTEGER,
                updated_at INTEGER NOT NULL
            )
            """)
        try db.execute(sql: """
            INSERT INTO sync_cursor(id, token, counter_high_water,
                                    timestamp_high_water, updated_at)
            VALUES (1, NULL, NULL, NULL, 0)
            """)
        try db.execute(sql: """
            CREATE TABLE sync_batch (
                batch_id TEXT PRIMARY KEY,
                state TEXT NOT NULL CHECK (
                    state IN ('received', 'committed', 'acked', 'failed', 'redelivered')
                ),
                token BLOB CHECK (token IS NULL OR length(token) = 8),
                received_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL,
                error TEXT
            )
            """)
        try db.execute(sql: """
            CREATE TABLE sync_failure (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                batch_id TEXT,
                stage TEXT NOT NULL,
                retry_classification TEXT NOT NULL,
                reason TEXT NOT NULL,
                created_at INTEGER NOT NULL
            )
            """)
        try db.execute(sql: """
            CREATE TABLE day_result (
                day_id TEXT NOT NULL,
                algorithm_version INTEGER NOT NULL,
                status TEXT NOT NULL,
                payload BLOB,
                computed_at INTEGER NOT NULL,
                PRIMARY KEY(day_id, algorithm_version)
            )
            """)
        try db.execute(sql: """
            CREATE TABLE metric_series (
                local_day TEXT NOT NULL,
                metric_key TEXT NOT NULL,
                value REAL,
                updated_at INTEGER NOT NULL,
                PRIMARY KEY(local_day, metric_key)
            )
            """)
        try db.execute(sql: """
            CREATE TABLE baseline (
                baseline_key TEXT NOT NULL,
                version INTEGER NOT NULL,
                payload BLOB NOT NULL,
                updated_at INTEGER NOT NULL,
                PRIMARY KEY(baseline_key, version)
            )
            """)
        try db.execute(sql: """
            CREATE TABLE workout (
                id TEXT PRIMARY KEY,
                kind TEXT NOT NULL,
                status TEXT NOT NULL,
                started_at INTEGER,
                ended_at INTEGER,
                payload BLOB,
                updated_at INTEGER NOT NULL
            )
            """)
        try db.execute(sql: """
            CREATE TABLE route_point (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                workout_id TEXT NOT NULL REFERENCES workout(id) ON DELETE CASCADE,
                sequence INTEGER NOT NULL,
                timestamp_milliseconds INTEGER NOT NULL,
                latitude REAL NOT NULL,
                longitude REAL NOT NULL,
                altitude REAL
            )
            """
        )
        try db.execute(sql: """
            CREATE TABLE health_import_cursor (
                source TEXT PRIMARY KEY,
                anchor BLOB,
                updated_at INTEGER NOT NULL
            )
            """)
        try db.execute(sql: """
            CREATE TABLE health_export_item (
                object_id TEXT PRIMARY KEY,
                object_type TEXT NOT NULL,
                status TEXT NOT NULL,
                error TEXT,
                updated_at INTEGER NOT NULL
            )
            """)
        try db.execute(sql: """
            CREATE TABLE notification_claim (
                claim_key TEXT PRIMARY KEY,
                claimed_at INTEGER NOT NULL
            )
            """)
        try db.execute(sql: """
            CREATE TABLE surface_generation (
                id INTEGER PRIMARY KEY CHECK (id = 1),
                generation INTEGER NOT NULL,
                snapshot BLOB,
                published_at INTEGER NOT NULL
            )
            """)
    }
}

public extension StorageMigrations {
    /// Schema version represented by the STO-02 ledger migration.
    static let ledgerSchemaVersion = "2"

    static let v24ADCFields = "storage-007-v24-adc-fields"

    /// Registers the STO-02 migration without coupling the migration's SQL to
    /// the STO-01 database opener.  Call this after the schema-metadata
    /// migration has been registered.
    static func registerSensorLedgerMigration(
        on migrator: inout DatabaseMigrator,
        applicationVersion: String
    ) {
        migrator.registerMigration(StorageMigrationIdentifier.sensorLedger) { db in
            try StorageLedgerSchema.createAll(in: db)
            try db.execute(
                sql: """
                INSERT INTO \(StorageMigrations.metadataTable)
                    (migration_identifier, schema_version, application_version)
                VALUES (?, ?, ?)
                """,
                arguments: [
                    StorageMigrationIdentifier.sensorLedger,
                    StorageMigrations.ledgerSchemaVersion,
                    applicationVersion
                ]
            )
        }
    }

    /// Applies the schema directly for focused STO-02 tests when the caller
    /// intentionally opens a database with an STO-01-only migrator. Production
    /// composition should register the migration above instead.
    static func applySensorLedgerSchema(to database: StorageDatabase) throws {
        try database.write { db in
            try StorageLedgerSchema.createAll(in: db)
        }
    }

    static func registerV24ADCFieldsMigration(
        on migrator: inout DatabaseMigrator,
        applicationVersion: String
    ) {
        migrator.registerMigration(v24ADCFields) { db in
            for column in ["ppg_green", "ppg_red_ir", "skin_contact", "spo2_red_raw", "spo2_ir_raw", "skin_temp_raw", "ambient_raw"] {
                try db.execute(sql: "ALTER TABLE decoded_second ADD COLUMN \(column) INTEGER")
            }
            let rows = try Row.fetchCursor(db, sql: "SELECT id, raw_payload FROM decoded_second WHERE record_version = 24 AND raw_payload IS NOT NULL")
            while let row = try rows.next() {
                guard let payload: Data = row["raw_payload"],
                      payload.count >= 89,
                      payload[0] == 0x2f,
                      payload[1] == 24 else { continue }
                func u16(_ offset: Int) -> Int64 { Int64(payload[offset]) | (Int64(payload[offset + 1]) << 8) }
                try db.execute(sql: "UPDATE decoded_second SET ppg_green = ?, ppg_red_ir = ?, skin_contact = ?, spo2_red_raw = ?, spo2_ir_raw = ?, skin_temp_raw = ?, ambient_raw = ? WHERE id = ?", arguments: [u16(29), u16(31), Int64(payload[51]), u16(64), u16(66), u16(68), u16(70), row["id"] as Int64])
            }
            try db.execute(sql: "INSERT INTO \(StorageMigrations.metadataTable) (migration_identifier, schema_version, application_version) VALUES (?, ?, ?)", arguments: [v24ADCFields, "7", applicationVersion])
        }
    }
    static func registerSkinTemperatureMigration(on migrator: inout DatabaseMigrator, applicationVersion: String) {
        let identifier = "storage-009-v24-skin-temperature"
        migrator.registerMigration(identifier) { db in
            try db.execute(sql: "ALTER TABLE decoded_second RENAME COLUMN skin_temp_raw TO unidentified_68")
            try db.execute(sql: "ALTER TABLE decoded_second ADD COLUMN skin_temperature_celsius REAL")
            // Frozen byte layout: offset 72, u16le, tenths of a degree Celsius.
            // Scan every retained raw record; do not reinterpret offset 68 or synthesize absent data.
            let rows = try Row.fetchCursor(db, sql: "SELECT id, raw_payload FROM decoded_second WHERE record_version = 24 AND raw_payload IS NOT NULL")
            while let row = try rows.next() {
                let payload: Data = row["raw_payload"]
                guard payload.count >= 89, payload[0] == 0x2f, payload[1] == 24 else { continue }
                let celsius = Double(UInt16(payload[72]) | UInt16(payload[73]) << 8) / 10
                guard (15...45).contains(celsius) else { continue }
                try db.execute(sql: "UPDATE decoded_second SET skin_temperature_celsius = ? WHERE id = ?", arguments: [celsius, row["id"] as Int64])
            }
            try db.execute(sql: "INSERT INTO \(StorageMigrations.metadataTable) (migration_identifier, schema_version, application_version) VALUES (?, ?, ?)", arguments: [identifier, "9", applicationVersion])
        }
    }

}

public extension StorageDatabase {
    /// All §10.2 table names, in migration order.
    static var requiredLedgerTableNames: [String] { StorageLedgerSchema.tableNames }

    /// Returns the current SQLite table inventory for schema tests and
    /// diagnostics. The metadata table is intentionally included as well.
    func tableNames() throws -> Set<String> {
        try read { db in
            Set(try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'table'"
            ))
        }
    }
}
