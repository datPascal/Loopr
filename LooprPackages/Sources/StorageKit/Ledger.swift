import Foundation
import ProtocolKit

/// The five durable states of an inbound history chunk.  The raw SQLite
/// column is constrained to these values; callers do not pass arbitrary text
/// to the ledger.
public enum SyncBatchState: String, Codable, CaseIterable, Equatable, Sendable {
    case received
    case committed
    case acked
    case failed
    case redelivered
}

/// Source-order RR data attached to one canonical physiological second.
public struct RRBeat: Codable, Equatable, Sendable {
    public let index: Int
    public let intervalMilliseconds: Int
    public let timestampMilliseconds: Int64?

    public init(
        index: Int,
        intervalMilliseconds: Int,
        timestampMilliseconds: Int64? = nil
    ) {
        self.index = index
        self.intervalMilliseconds = intervalMilliseconds
        self.timestampMilliseconds = timestampMilliseconds
    }

    public var beatIndex: Int { index }
    public var rrMilliseconds: Int { intervalMilliseconds }
}

/// A canonical historical second ready for persistence.  Epoch values are
/// intentionally represented separately from the local-calendar day label:
/// local day calculations must remain DST-safe and must never be reconstructed
/// by dividing an epoch timestamp by 86,400.
public struct StoredHistoricalRecord: Codable, Equatable, Sendable {
    public let physiologicalTimestamp: Int64
    public let bandCounter: UInt32
    public let absoluteTimestamp: Int64
    public let localDay: String
    public let version: UInt8?
    public let subsecondTicks: UInt16?
    public let heartRate: UInt8?
    public let gravityX: Double?
    public let gravityY: Double?
    public let gravityZ: Double?
    public let ppgGreen: UInt16?
    public let ppgRedIR: UInt16?
    public let skinContact: UInt8?
    public let spo2RedRaw: UInt16?
    public let spo2IRRaw: UInt16?
    public let unidentified68: UInt16?
    public let skinTemperatureCelsius: Double?
    public let ambientRaw: UInt16?
    public let rrBeats: [RRBeat]
    public let rawPayload: Data?

    public init(
        physiologicalTimestamp: Int64,
        bandCounter: UInt32,
        absoluteTimestamp: Int64? = nil,
        localDay: String,
        version: UInt8? = nil,
        subsecondTicks: UInt16? = nil,
        heartRate: UInt8? = nil,
        gravityX: Double? = nil,
        gravityY: Double? = nil,
        gravityZ: Double? = nil,
        ppgGreen: UInt16? = nil,
        ppgRedIR: UInt16? = nil,
        skinContact: UInt8? = nil,
        spo2RedRaw: UInt16? = nil,
        spo2IRRaw: UInt16? = nil,
        unidentified68: UInt16? = nil,
        skinTemperatureCelsius: Double? = nil,
        ambientRaw: UInt16? = nil,
        rrBeats: [RRBeat] = [],
        rawPayload: Data? = nil
    ) {
        self.physiologicalTimestamp = physiologicalTimestamp
        self.bandCounter = bandCounter
        self.absoluteTimestamp = absoluteTimestamp ?? physiologicalTimestamp
        self.localDay = localDay
        self.version = version
        self.subsecondTicks = subsecondTicks
        self.heartRate = heartRate
        self.gravityX = gravityX
        self.gravityY = gravityY
        self.gravityZ = gravityZ
        self.ppgGreen = ppgGreen
        self.ppgRedIR = ppgRedIR
        self.skinContact = skinContact
        self.spo2RedRaw = spo2RedRaw
        self.spo2IRRaw = spo2IRRaw
        self.unidentified68 = unidentified68
        self.skinTemperatureCelsius = skinTemperatureCelsius
        self.ambientRaw = ambientRaw
        self.rrBeats = rrBeats
        self.rawPayload = rawPayload.map { Data($0) }
    }

    /// Builds a storage record from the pinned decoded fields. Callers may
    /// supply RR beats explicitly; otherwise verified decoded intervals retain
    /// the record's whole-second timestamp and source order.
    public init(
        decoded: DecodedHistoricalRecord,
        localDay: String,
        rrBeats: [RRBeat]? = nil,
        absoluteTimestamp: Int64? = nil
    ) {
        self.init(
            physiologicalTimestamp: Int64(decoded.timestampSeconds),
            bandCounter: decoded.counter,
            absoluteTimestamp: absoluteTimestamp ?? Int64(decoded.timestampSeconds),
            localDay: localDay,
            version: decoded.version,
            subsecondTicks: decoded.subsecondTicks,
            heartRate: decoded.heartRate,
            gravityX: decoded.gravity.map { Double($0.x) },
            gravityY: decoded.gravity.map { Double($0.y) },
            gravityZ: decoded.gravity.map { Double($0.z) },
            ppgGreen: decoded.ppgGreen,
            ppgRedIR: decoded.ppgRedIR,
            skinContact: decoded.skinContact,
            spo2RedRaw: decoded.spo2RedRaw,
            spo2IRRaw: decoded.spo2IRRaw,
            unidentified68: decoded.unidentified68,
            skinTemperatureCelsius: decoded.skinTemperatureCelsius,
            ambientRaw: decoded.ambientRaw,
            rrBeats: rrBeats ?? decoded.rrIntervalsMilliseconds.enumerated().map { index, interval in
                RRBeat(index: index, intervalMilliseconds: Int(interval), timestampMilliseconds: (absoluteTimestamp ?? Int64(decoded.timestampSeconds)) * 1_000)
            },
            rawPayload: decoded.raw
        )
    }

    public var timestamp: Int64 { physiologicalTimestamp }
    public var counter: UInt32 { bandCounter }

    private enum CodingKeys: String, CodingKey {
        case physiologicalTimestamp, bandCounter, absoluteTimestamp, localDay,
             version, subsecondTicks, heartRate, gravityX, gravityY, gravityZ,
             ppgGreen, ppgRedIR, skinContact, spo2RedRaw, spo2IRRaw,
             unidentified68, skinTemperatureCelsius, ambientRaw, rrBeats, rawPayload
        case legacyUnidentified68 = "skinTemperatureRaw"
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(physiologicalTimestamp, forKey: .physiologicalTimestamp)
        try values.encode(bandCounter, forKey: .bandCounter)
        try values.encode(absoluteTimestamp, forKey: .absoluteTimestamp)
        try values.encode(localDay, forKey: .localDay)
        try values.encodeIfPresent(version, forKey: .version)
        try values.encodeIfPresent(subsecondTicks, forKey: .subsecondTicks)
        try values.encodeIfPresent(heartRate, forKey: .heartRate)
        try values.encodeIfPresent(gravityX, forKey: .gravityX)
        try values.encodeIfPresent(gravityY, forKey: .gravityY)
        try values.encodeIfPresent(gravityZ, forKey: .gravityZ)
        try values.encodeIfPresent(ppgGreen, forKey: .ppgGreen)
        try values.encodeIfPresent(ppgRedIR, forKey: .ppgRedIR)
        try values.encodeIfPresent(skinContact, forKey: .skinContact)
        try values.encodeIfPresent(spo2RedRaw, forKey: .spo2RedRaw)
        try values.encodeIfPresent(spo2IRRaw, forKey: .spo2IRRaw)
        try values.encodeIfPresent(unidentified68, forKey: .unidentified68)
        try values.encodeIfPresent(skinTemperatureCelsius, forKey: .skinTemperatureCelsius)
        try values.encodeIfPresent(ambientRaw, forKey: .ambientRaw)
        try values.encode(rrBeats, forKey: .rrBeats)
        try values.encodeIfPresent(rawPayload, forKey: .rawPayload)
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            physiologicalTimestamp: try values.decode(Int64.self, forKey: .physiologicalTimestamp),
            bandCounter: try values.decode(UInt32.self, forKey: .bandCounter),
            absoluteTimestamp: try values.decodeIfPresent(Int64.self, forKey: .absoluteTimestamp),
            localDay: try values.decode(String.self, forKey: .localDay),
            version: try values.decodeIfPresent(UInt8.self, forKey: .version),
            subsecondTicks: try values.decodeIfPresent(UInt16.self, forKey: .subsecondTicks),
            heartRate: try values.decodeIfPresent(UInt8.self, forKey: .heartRate),
            gravityX: try values.decodeIfPresent(Double.self, forKey: .gravityX),
            gravityY: try values.decodeIfPresent(Double.self, forKey: .gravityY),
            gravityZ: try values.decodeIfPresent(Double.self, forKey: .gravityZ),
            ppgGreen: try values.decodeIfPresent(UInt16.self, forKey: .ppgGreen),
            ppgRedIR: try values.decodeIfPresent(UInt16.self, forKey: .ppgRedIR),
            skinContact: try values.decodeIfPresent(UInt8.self, forKey: .skinContact),
            spo2RedRaw: try values.decodeIfPresent(UInt16.self, forKey: .spo2RedRaw),
            spo2IRRaw: try values.decodeIfPresent(UInt16.self, forKey: .spo2IRRaw),
            unidentified68: try values.decodeIfPresent(UInt16.self, forKey: .unidentified68)
                ?? values.decodeIfPresent(UInt16.self, forKey: .legacyUnidentified68),
            skinTemperatureCelsius: try values.decodeIfPresent(Double.self, forKey: .skinTemperatureCelsius),
            ambientRaw: try values.decodeIfPresent(UInt16.self, forKey: .ambientRaw),
            rrBeats: try values.decodeIfPresent([RRBeat].self, forKey: .rrBeats) ?? [],
            rawPayload: try values.decodeIfPresent(Data.self, forKey: .rawPayload)
        )
    }
}

/// An unsupported or malformed historical payload.  Raw bytes are retained
/// exactly and are the deduplication identity; a reused counter cannot erase a
/// distinct unknown packet.
public struct ArchivedHistoricalRecord: Equatable, Sendable {
    public let rawPayload: Data
    public let packetType: UInt8?
    public let version: UInt8?
    public let bandCounter: UInt32?
    public let physiologicalTimestamp: Int64?
    public let capturedAt: Int64
    public let reason: String

    public init(
        rawPayload: Data,
        packetType: UInt8? = nil,
        version: UInt8? = nil,
        bandCounter: UInt32? = nil,
        physiologicalTimestamp: Int64? = nil,
        capturedAt: Int64,
        reason: String
    ) {
        self.rawPayload = Data(rawPayload)
        self.packetType = packetType
        self.version = version
        self.bandCounter = bandCounter
        self.physiologicalTimestamp = physiologicalTimestamp
        self.capturedAt = capturedAt
        self.reason = reason
    }

    public init(
        raw: Data,
        reason: String,
        capturedAt: Int64,
        packetType: UInt8? = nil,
        version: UInt8? = nil,
        bandCounter: UInt32? = nil,
        physiologicalTimestamp: Int64? = nil
    ) {
        self.init(
            rawPayload: raw,
            packetType: packetType,
            version: version,
            bandCounter: bandCounter,
            physiologicalTimestamp: physiologicalTimestamp,
            capturedAt: capturedAt,
            reason: reason
        )
    }

    public var raw: Data { rawPayload }
    public var counter: UInt32? { bandCounter }
}

/// Deterministic metadata supplied by the history coordinator for one batch.
/// No token is included here: the boundary value is the sole source of token
/// identity, which keeps the completion-tail result tokenless by construction.
public struct HistoryBatchDiagnostics: Equatable, Sendable {
    public let batchID: String
    public let receivedAt: Int64
    public let recordCount: Int
    public let archivedCount: Int

    public init(
        batchID: String = "batch-unknown",
        receivedAt: Int64 = 0,
        recordCount: Int = 0,
        archivedCount: Int = 0
    ) {
        self.batchID = batchID
        self.receivedAt = receivedAt
        self.recordCount = recordCount
        self.archivedCount = archivedCount
    }

    public var batchIdentifier: String { batchID }
}

/// The token-bearing durable result used by the future STO-03 ACK barrier.
/// STO-02 defines the value so the commit API can reuse it without redefining
/// protocol data in the transaction layer.
public struct CommittedHistoryBatch: Equatable, Sendable {
    public let token: HistoryToken
    public let batchID: String
    public let recordCount: Int
    public let archivedCount: Int

    public init(
        token: HistoryToken,
        batchID: String,
        recordCount: Int,
        archivedCount: Int
    ) {
        self.token = token
        self.batchID = batchID
        self.recordCount = recordCount
        self.archivedCount = archivedCount
    }

    public var committedToken: HistoryToken { token }
}

/// The tokenless durable result used by a history-completion tail.  There is
/// deliberately no token property or conversion method on this type.
public struct CommittedHistoryTail: Equatable, Sendable {
    public let batchID: String
    public let recordCount: Int
    public let archivedCount: Int

    public init(batchID: String, recordCount: Int, archivedCount: Int) {
        self.batchID = batchID
        self.recordCount = recordCount
        self.archivedCount = archivedCount
    }
}

/// The persisted high-water/cursor snapshot.  A missing token is represented
/// by nil; no zero-filled token is synthesized.
public struct SyncCursorSnapshot: Equatable, Sendable {
    public let token: HistoryToken?
    public let counterHighWater: UInt32?
    public let timestampHighWater: Int64?
    public let updatedAt: Int64

    public init(
        token: HistoryToken?,
        counterHighWater: UInt32?,
        timestampHighWater: Int64?,
        updatedAt: Int64
    ) {
        self.token = token
        self.counterHighWater = counterHighWater
        self.timestampHighWater = timestampHighWater
        self.updatedAt = updatedAt
    }
}

public extension StorageDatabase {
    /// Inserts or replaces one canonical second by physiological timestamp.
    /// The parent row is established before stale RR rows are deleted and new
    /// children are attached, all inside one SQLite transaction.
    func replaceHistoricalSecond(_ record: StoredHistoricalRecord) throws {
        // StorageDatabase.write intentionally uses GRDB's transactional write
        // helper. Use the non-transactional writer here so this method can
        // own the single explicit transaction required by replacement
        // atomicity, rather than attempting to BEGIN a nested transaction.
        try databasePool.writeWithoutTransaction { db in
            try db.inTransaction {
                let existingID = try Int64.fetchOne(
                    db,
                    sql: "SELECT id FROM decoded_second WHERE physiological_timestamp = ?",
                    arguments: [record.physiologicalTimestamp]
                )

                if let existingID {
                    try db.execute(
                        sql: """
                        UPDATE decoded_second
                        SET band_counter = ?, absolute_timestamp = ?, local_day = ?,
                            record_version = ?, subsecond_ticks = ?, heart_rate = ?,
                            gravity_x = ?, gravity_y = ?, gravity_z = ?, ppg_green = ?, ppg_red_ir = ?, skin_contact = ?, spo2_red_raw = ?, spo2_ir_raw = ?, unidentified_68 = ?, skin_temperature_celsius = ?, ambient_raw = ?, raw_payload = ?
                        WHERE id = ?
                        """,
                        arguments: [
                            Int64(record.bandCounter),
                            record.absoluteTimestamp,
                            record.localDay,
                            record.version.map { Int64($0) },
                            record.subsecondTicks.map { Int64($0) },
                            record.heartRate.map { Int64($0) },
                            record.gravityX,
                            record.gravityY,
                            record.gravityZ,
                            record.ppgGreen.map { Int64($0) }, record.ppgRedIR.map { Int64($0) }, record.skinContact.map { Int64($0) }, record.spo2RedRaw.map { Int64($0) }, record.spo2IRRaw.map { Int64($0) }, record.unidentified68.map { Int64($0) }, record.skinTemperatureCelsius, record.ambientRaw.map { Int64($0) },
                            record.rawPayload,
                            existingID
                        ]
                    )
                    try db.execute(
                        sql: "DELETE FROM rr_beat WHERE decoded_second_id = ?",
                        arguments: [existingID]
                    )
                } else {
                    try db.execute(
                        sql: """
                        INSERT INTO decoded_second(
                            physiological_timestamp, band_counter,
                            absolute_timestamp, local_day, record_version,
                            subsecond_ticks, heart_rate, gravity_x, gravity_y,
                            gravity_z, ppg_green, ppg_red_ir, skin_contact, spo2_red_raw, spo2_ir_raw, unidentified_68, skin_temperature_celsius, ambient_raw, raw_payload
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                        arguments: [
                            record.physiologicalTimestamp,
                            Int64(record.bandCounter),
                            record.absoluteTimestamp,
                            record.localDay,
                            record.version.map { Int64($0) },
                            record.subsecondTicks.map { Int64($0) },
                            record.heartRate.map { Int64($0) },
                            record.gravityX,
                            record.gravityY,
                            record.gravityZ,
                            record.ppgGreen.map { Int64($0) }, record.ppgRedIR.map { Int64($0) }, record.skinContact.map { Int64($0) }, record.spo2RedRaw.map { Int64($0) }, record.spo2IRRaw.map { Int64($0) }, record.unidentified68.map { Int64($0) }, record.skinTemperatureCelsius, record.ambientRaw.map { Int64($0) },
                            record.rawPayload
                        ]
                    )
                }

                let canonicalID = try Int64.fetchOne(
                    db,
                    sql: "SELECT id FROM decoded_second WHERE physiological_timestamp = ?",
                    arguments: [record.physiologicalTimestamp]
                )
                guard let canonicalID else {
                    throw StorageLedgerError.canonicalSecondMissing
                }

                for beat in record.rrBeats {
                    try db.execute(
                        sql: """
                        INSERT INTO rr_beat(
                            decoded_second_id, beat_index, rr_milliseconds,
                            beat_timestamp_milliseconds
                        ) VALUES (?, ?, ?, ?)
                        """,
                        arguments: [
                            canonicalID,
                            beat.index,
                            beat.intervalMilliseconds,
                            beat.timestampMilliseconds
                        ]
                    )
                }
                return .commit
            }
        }
    }

    /// Source-compatible spelling for callers that use the plan's
    /// insert-or-replace terminology.
    func insertOrReplaceHistoricalSecond(_ record: StoredHistoricalRecord) throws {
        try replaceHistoricalSecond(record)
    }

    func storedHistoricalSecond(
        physiologicalTimestamp: Int64
    ) throws -> StoredHistoricalRecord? {
        try read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT physiological_timestamp, band_counter, absolute_timestamp,
                       local_day, record_version, subsecond_ticks, heart_rate,
                       gravity_x, gravity_y, gravity_z, ppg_green, ppg_red_ir, skin_contact, spo2_red_raw, spo2_ir_raw, unidentified_68, skin_temperature_celsius, ambient_raw, raw_payload
                FROM decoded_second
                WHERE physiological_timestamp = ?
                """,
                arguments: [physiologicalTimestamp]
            ) else {
                return nil
            }
            return StoredHistoricalRecord(
                physiologicalTimestamp: row["physiological_timestamp"],
                bandCounter: UInt32(row["band_counter"] as Int64),
                absoluteTimestamp: row["absolute_timestamp"],
                localDay: row["local_day"],
                version: (row["record_version"] as Int64?).map { UInt8($0) },
                subsecondTicks: (row["subsecond_ticks"] as Int64?).map { UInt16($0) },
                heartRate: (row["heart_rate"] as Int64?).map { UInt8($0) },
                gravityX: row["gravity_x"],
                gravityY: row["gravity_y"],
                gravityZ: row["gravity_z"],
                ppgGreen: (row["ppg_green"] as Int64?).map { UInt16($0) },
                ppgRedIR: (row["ppg_red_ir"] as Int64?).map { UInt16($0) },
                skinContact: (row["skin_contact"] as Int64?).map { UInt8($0) },
                spo2RedRaw: (row["spo2_red_raw"] as Int64?).map { UInt16($0) },
                spo2IRRaw: (row["spo2_ir_raw"] as Int64?).map { UInt16($0) },
                unidentified68: (row["unidentified_68"] as Int64?).map { UInt16($0) },
                skinTemperatureCelsius: row["skin_temperature_celsius"],
                ambientRaw: (row["ambient_raw"] as Int64?).map { UInt16($0) },
                rrBeats: try rrBeats(db: db, canonicalTimestamp: physiologicalTimestamp),
                rawPayload: row["raw_payload"]
            )
        }
    }

    func archiveUnsupportedRecord(_ record: ArchivedHistoricalRecord) throws {
        try write { db in
            try db.execute(
                sql: """
                INSERT OR IGNORE INTO raw_archive(
                    raw_payload, packet_type, record_version, band_counter,
                    physiological_timestamp, captured_at, reason
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    record.rawPayload,
                    record.packetType.map { Int64($0) },
                    record.version.map { Int64($0) },
                    record.bandCounter.map { Int64($0) },
                    record.physiologicalTimestamp,
                    record.capturedAt,
                    record.reason
                ]
            )
        }
    }

    func archivedHistoricalRecords() throws -> [ArchivedHistoricalRecord] {
        try read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT raw_payload, packet_type, record_version, band_counter,
                       physiological_timestamp, captured_at, reason
                FROM raw_archive ORDER BY id
                """
            ).map { row in
                ArchivedHistoricalRecord(
                    rawPayload: row["raw_payload"],
                    packetType: (row["packet_type"] as Int64?).map { UInt8($0) },
                    version: (row["record_version"] as Int64?).map { UInt8($0) },
                    bandCounter: (row["band_counter"] as Int64?).map { UInt32($0) },
                    physiologicalTimestamp: row["physiological_timestamp"],
                    capturedAt: row["captured_at"],
                    reason: row["reason"]
                )
            }
        }
    }

    /// Writes a cursor snapshot while preserving opaque token bytes.  Passing
    /// nil intentionally clears the token; completion-tail callers should use
    /// `updateHighWaters` instead so the prior token is retained.
    func saveSyncCursor(_ snapshot: SyncCursorSnapshot) throws {
        try write { db in
            try db.execute(
                sql: """
                UPDATE sync_cursor
                SET token = ?, counter_high_water = ?,
                    timestamp_high_water = ?, updated_at = ?
                WHERE id = 1
                """,
                arguments: [
                    snapshot.token?.persistedBytes,
                    snapshot.counterHighWater.map { Int64($0) },
                    snapshot.timestampHighWater,
                    snapshot.updatedAt
                ]
            )
        }
    }

    func saveSyncCursor(
        token: HistoryToken,
        counterHighWater: UInt32?,
        timestampHighWater: Int64?,
        updatedAt: Int64 = 0
    ) throws {
        try saveSyncCursor(
            SyncCursorSnapshot(
                token: token,
                counterHighWater: counterHighWater,
                timestampHighWater: timestampHighWater,
                updatedAt: updatedAt
            )
        )
    }

    /// Advances high-water positions without touching the previously committed
    /// token.  This is the cursor operation required by a tokenless tail.
    func updateHighWaters(
        counterHighWater: UInt32?,
        timestampHighWater: Int64?,
        updatedAt: Int64 = 0
    ) throws {
        try write { db in
            try db.execute(
                sql: """
                UPDATE sync_cursor
                SET counter_high_water = ?, timestamp_high_water = ?, updated_at = ?
                WHERE id = 1
                """,
                arguments: [
                    counterHighWater.map { Int64($0) },
                    timestampHighWater,
                    updatedAt
                ]
            )
        }
    }

    func syncCursorSnapshot() throws -> SyncCursorSnapshot {
        try read { db in
            let row = try Row.fetchOne(
                db,
                sql: """
                SELECT token, counter_high_water, timestamp_high_water, updated_at
                FROM sync_cursor WHERE id = 1
                """
            )
            guard let row else { throw StorageLedgerError.cursorMissing }
            let bytes: Data? = row["token"]
            let token = try bytes.map(HistoryToken.init(bytes:))
            return SyncCursorSnapshot(
                token: token,
                counterHighWater: (row["counter_high_water"] as Int64?).map { UInt32($0) },
                timestampHighWater: row["timestamp_high_water"],
                updatedAt: row["updated_at"]
            )
        }
    }

    func recordSyncBatch(
        id: String,
        state: SyncBatchState,
        token: HistoryToken? = nil,
        receivedAt: Int64 = 0,
        updatedAt: Int64 = 0,
        error: String? = nil
    ) throws {
        try write { db in
            try db.execute(
                sql: """
                INSERT INTO sync_batch(batch_id, state, token, received_at, updated_at, error)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(batch_id) DO UPDATE SET
                    state = excluded.state,
                    token = excluded.token,
                    received_at = excluded.received_at,
                    updated_at = excluded.updated_at,
                    error = excluded.error
                """,
                arguments: [id, state.rawValue, token?.persistedBytes, receivedAt, updatedAt, error]
            )
        }
    }

    /// Advances a committed batch to `acked` without replacing its exact
    /// token.  ACK writes happen outside the SQLite commit transaction, so the
    /// token/cursor data must remain untouched when this ledger transition is
    /// recorded.
    func markSyncBatchAcknowledged(
        id: String,
        updatedAt: Int64 = 0
    ) throws {
        try write { db in
            try db.execute(
                sql: """
                UPDATE sync_batch
                SET state = ?, updated_at = ?, error = NULL
                WHERE batch_id = ? AND state IN (?, ?)
                """,
                arguments: [
                    SyncBatchState.acked.rawValue,
                    updatedAt,
                    id,
                    SyncBatchState.committed.rawValue,
                    SyncBatchState.redelivered.rawValue
                ]
            )
        }
    }

    private func rrBeats(db: Database, canonicalTimestamp: Int64) throws -> [RRBeat] {
        try Row.fetchAll(
            db,
            sql: """
            SELECT r.beat_index, r.rr_milliseconds, r.beat_timestamp_milliseconds
            FROM rr_beat r
            JOIN decoded_second d ON d.id = r.decoded_second_id
            WHERE d.physiological_timestamp = ?
            ORDER BY r.beat_index
            """,
            arguments: [canonicalTimestamp]
        ).map { row in
            RRBeat(
                index: row["beat_index"],
                intervalMilliseconds: row["rr_milliseconds"],
                timestampMilliseconds: row["beat_timestamp_milliseconds"]
            )
        }
    }
}

public enum StorageLedgerError: Error, Equatable, Sendable, LocalizedError {
    case canonicalSecondMissing
    case cursorMissing

    public var errorDescription: String? {
        switch self {
        case .canonicalSecondMissing: return "The canonical historical second was not found after insertion."
        case .cursorMissing: return "The singleton synchronization cursor row is missing."
        }
    }
}
