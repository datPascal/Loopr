import Foundation

/// One consistent SQLite read of the canonical seconds and their ordered RR beats.
public struct HistoricalAnalyticsSnapshot: Sendable {
    public let revision: Int64
    public let records: [StoredHistoricalRecord]
}

public extension StorageMigrations {
    static func registerAnalyticsRevisionMigration(on migrator: inout DatabaseMigrator, applicationVersion: String) {
        migrator.registerMigration("storage-005-analytics-revision") { db in
            try db.execute(sql: "CREATE TABLE analytics_input_revision (id INTEGER PRIMARY KEY CHECK(id = 1), revision INTEGER NOT NULL)")
            try db.execute(sql: "INSERT INTO analytics_input_revision VALUES (1, 0)")
            for table in ["decoded_second", "rr_beat"] {
                for operation in ["INSERT", "UPDATE", "DELETE"] {
                    try db.execute(sql: """
                        CREATE TRIGGER analytics_revision_\(table)_\(operation.lowercased())
                        AFTER \(operation) ON \(table) BEGIN
                            UPDATE analytics_input_revision SET revision = revision + 1 WHERE id = 1;
                        END
                        """)
                }
            }
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS decoded_second_absolute_time ON decoded_second(absolute_timestamp)")
            // Earlier builds archived the v24 bytes but omitted their RR block.
            // Backfill only records without existing beats, using this pinned
            // layout so subsequent decoder changes cannot alter a migration.
            let rows = try Row.fetchCursor(db, sql: "SELECT id, absolute_timestamp, raw_payload FROM decoded_second d WHERE record_version = 24 AND raw_payload IS NOT NULL AND NOT EXISTS (SELECT 1 FROM rr_beat r WHERE r.decoded_second_id = d.id)")
            while let row = try rows.next() {
                let bytes = [UInt8](row["raw_payload"] as Data)
                guard bytes.count >= 27, bytes[0] == 0x2f, bytes[1] == 24, bytes[18] <= 4 else { continue }
                for index in 0..<Int(bytes[18]) {
                    let offset = 19 + index * 2
                    let interval = Int16(bitPattern: UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8)
                    guard interval > 0 else { continue }
                    try db.execute(sql: "INSERT INTO rr_beat(decoded_second_id, beat_index, rr_milliseconds, beat_timestamp_milliseconds) VALUES (?, ?, ?, ?)", arguments: [row["id"] as Int64, index, Int(interval), (row["absolute_timestamp"] as Int64) * 1_000])
                }
            }

            try db.execute(sql: "INSERT INTO storage_schema_metadata (migration_identifier, schema_version, application_version) VALUES (?, ?, ?)", arguments: ["storage-005-analytics-revision", "5", applicationVersion])
        }
        migrator.registerMigration("storage-006-analytics-range-revision") { db in
            try db.execute(sql: "CREATE TABLE IF NOT EXISTS analytics_range_revision (utc_day INTEGER PRIMARY KEY, revision INTEGER NOT NULL)")
            try db.execute(sql: "INSERT OR REPLACE INTO analytics_range_revision SELECT absolute_timestamp / 86400, (SELECT revision FROM analytics_input_revision WHERE id = 1) FROM decoded_second GROUP BY absolute_timestamp / 86400")
            for table in ["decoded_second", "rr_beat"] {
                for operation in ["INSERT", "UPDATE", "DELETE"] {
                    let references = operation == "INSERT" ? ["NEW"] : operation == "DELETE" ? ["OLD"] : ["OLD", "NEW"]
                    let updates: String = references.map { reference -> String in
                        let time = table == "decoded_second" ? "\(reference).absolute_timestamp" : "(SELECT absolute_timestamp FROM decoded_second WHERE id = \(reference).decoded_second_id)"
                        return "INSERT INTO analytics_range_revision(utc_day, revision) SELECT \(time) / 86400, revision FROM analytics_input_revision WHERE id = 1 AND \(time) IS NOT NULL ON CONFLICT(utc_day) DO UPDATE SET revision = excluded.revision;"
                    }.joined(separator: "\n")
                    try db.execute(sql: "DROP TRIGGER IF EXISTS analytics_revision_\(table)_\(operation.lowercased())")
                    try db.execute(sql: """
                        CREATE TRIGGER analytics_revision_\(table)_\(operation.lowercased())
                        AFTER \(operation) ON \(table) BEGIN
                            UPDATE analytics_input_revision SET revision = revision + 1 WHERE id = 1;
                            \(updates)
                        END
                        """)
                }
            }
            try db.execute(sql: "INSERT INTO storage_schema_metadata (migration_identifier, schema_version, application_version) VALUES (?, ?, ?)", arguments: ["storage-006-analytics-range-revision", "6", applicationVersion])
        }

    }
}

public extension StorageDatabase {
    func historicalAnalyticsRevision() throws -> Int64 {
        try read { db in try Int64.fetchOne(db, sql: "SELECT revision FROM analytics_input_revision WHERE id = 1") ?? 0 }
    }

    func historicalAnalyticsRevision(from start: Int64, to end: Int64) throws -> Int64 {
        try read { db in try Self.analyticsRevision(db, from: start, to: end) }
    }

    private static func analyticsRevision(_ db: Database, from start: Int64, to end: Int64) throws -> Int64 {
        // UTC buckets only invalidate caches. Civil-day membership is still
        // resolved using the caller's exact absolute-time interval.
        //
        // A window that holds no recorded day is revision 0 and stays there.
        // The earlier fallback to the global counter made every empty window
        // change on every inserted second, so a derived day whose movement
        // baseline window was empty was thrown away once per second while the
        // band streamed, and nothing cached ever survived. The first second
        // written into such a window creates its bucket row, which carries the
        // global counter and is therefore never 0.
        try Int64.fetchOne(db, sql: "SELECT COALESCE(MAX(revision), 0) FROM analytics_range_revision WHERE utc_day >= ? AND utc_day <= ?", arguments: [start / 86_400, (end - 1) / 86_400]) ?? 0
    }

    /// Half-open absolute-time range. Local labels saved during an earlier
    /// timezone are not used to filter the physiological record stream.
    func historicalAnalyticsSnapshot(from start: Int64, to end: Int64) throws -> HistoricalAnalyticsSnapshot {
        try read { db in
            let revision = try Self.analyticsRevision(db, from: start, to: end)
            let beats = try Row.fetchCursor(db, sql: """
                SELECT r.decoded_second_id, r.beat_index, r.rr_milliseconds, r.beat_timestamp_milliseconds
                FROM rr_beat r JOIN decoded_second d ON r.decoded_second_id = d.id
                WHERE d.absolute_timestamp >= ? AND d.absolute_timestamp < ?
                ORDER BY d.absolute_timestamp, r.beat_index
                """, arguments: [start, end])
            var grouped: [Int64: [RRBeat]] = [:]
            while let row = try beats.next() {
                grouped[row["decoded_second_id"], default: []].append(RRBeat(
                    index: row["beat_index"], intervalMilliseconds: row["rr_milliseconds"],
                    timestampMilliseconds: row["beat_timestamp_milliseconds"]
                ))
            }
            let rows = try Row.fetchCursor(db, sql: """
                SELECT id, physiological_timestamp, band_counter, absolute_timestamp, local_day,
                       record_version, subsecond_ticks, heart_rate, gravity_x, gravity_y, gravity_z,
                       ppg_green, ppg_red_ir, skin_contact, spo2_red_raw, spo2_ir_raw, unidentified_68, skin_temperature_celsius, ambient_raw
                FROM decoded_second WHERE absolute_timestamp >= ? AND absolute_timestamp < ?
                ORDER BY absolute_timestamp, physiological_timestamp
                """, arguments: [start, end])
            var records: [StoredHistoricalRecord] = []
            while let row = try rows.next() {
                records.append(StoredHistoricalRecord(
                    physiologicalTimestamp: row["physiological_timestamp"],
                    bandCounter: UInt32(row["band_counter"] as Int64), absoluteTimestamp: row["absolute_timestamp"],
                    localDay: row["local_day"], version: (row["record_version"] as Int64?).flatMap(UInt8.init(exactly:)),
                    subsecondTicks: (row["subsecond_ticks"] as Int64?).flatMap(UInt16.init(exactly:)),
                    heartRate: (row["heart_rate"] as Int64?).flatMap(UInt8.init(exactly:)),
                    gravityX: row["gravity_x"], gravityY: row["gravity_y"], gravityZ: row["gravity_z"],
                    ppgGreen: (row["ppg_green"] as Int64?).flatMap(UInt16.init(exactly:)),
                    ppgRedIR: (row["ppg_red_ir"] as Int64?).flatMap(UInt16.init(exactly:)),
                    skinContact: (row["skin_contact"] as Int64?).flatMap(UInt8.init(exactly:)),
                    spo2RedRaw: (row["spo2_red_raw"] as Int64?).flatMap(UInt16.init(exactly:)),
                    spo2IRRaw: (row["spo2_ir_raw"] as Int64?).flatMap(UInt16.init(exactly:)),
                    unidentified68: (row["unidentified_68"] as Int64?).flatMap(UInt16.init(exactly:)),
                    skinTemperatureCelsius: row["skin_temperature_celsius"],
                    ambientRaw: (row["ambient_raw"] as Int64?).flatMap(UInt16.init(exactly:)),
                    rrBeats: grouped[row["id"], default: []]
                ))
            }
            return HistoricalAnalyticsSnapshot(revision: revision, records: records)
        }
    }
}

public struct StoredAccelerationSample: Sendable {
    public let timestamp: Int64
    public let x: Double
    public let y: Double
    public let z: Double
}

public extension StorageDatabase {
    func historicalAcceleration(from start: Int64, to end: Int64) throws -> [StoredAccelerationSample] {
        try read { db in
            let rows = try Row.fetchCursor(db, sql: """
                SELECT absolute_timestamp, gravity_x, gravity_y, gravity_z FROM decoded_second
                WHERE absolute_timestamp >= ? AND absolute_timestamp < ?
                  AND gravity_x IS NOT NULL AND gravity_y IS NOT NULL AND gravity_z IS NOT NULL
                ORDER BY absolute_timestamp
                """, arguments: [start, end])
            var output: [StoredAccelerationSample] = []
            while let row = try rows.next() {
                output.append(StoredAccelerationSample(timestamp: row["absolute_timestamp"], x: row["gravity_x"], y: row["gravity_y"], z: row["gravity_z"]))
            }
            return output
        }
    }
}
