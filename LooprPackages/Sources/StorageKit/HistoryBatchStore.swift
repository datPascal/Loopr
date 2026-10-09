import Foundation
import ProtocolKit

/// The boundary that terminates a history burst.
///
/// A completion tail is deliberately tokenless.  It proves that the records
/// received so far are durable, but it does not authorize a trim/ACK write.
public enum HistoryCommitBoundary: Sendable {
    case tokenized(HistoryToken)
    case completionTail
}

/// The only durable results that the history coordinator may receive.
///
/// Notice that `CommittedHistoryTail` has no token-bearing member.  This is a
/// safety property of the public API, not merely a convention at call sites.
public enum DurableHistoryCommit: Sendable {
    case ackEligible(CommittedHistoryBatch)
    case completionTail(CommittedHistoryTail)
}

/// STO-02 owns the canonical ledger value types.  Keep this compatibility
/// alias while routing the transaction seam through that single RR model.
public typealias StoredRRBeat = RRBeat

/// The one storage seam used by the ordered history coordinator.
public protocol HistoryBatchStore: Sendable {
    func commit(
        records: [StoredHistoricalRecord],
        archived: [ArchivedHistoricalRecord],
        boundary: HistoryCommitBoundary,
        diagnostics: HistoryBatchDiagnostics
    ) async throws -> DurableHistoryCommit
}

/// Optional second half of the durable ACK barrier.  The commit transaction
/// itself never marks a batch `acked`; callers invoke this seam only after a
/// write-with-response has succeeded.  Keeping it optional preserves the
/// narrow `HistoryBatchStore` test seam for stores that intentionally model
/// only commit durability.
public protocol HistoryBatchAcknowledger: Sendable {
    func markAcknowledged(batchID: String, updatedAt: Int64) async throws
}

/// Named transaction boundaries used by deterministic chaos tests.
public enum HistoryCommitFailurePoint: String, CaseIterable, Hashable, Sendable {
    case beforeTransactionStart
    case afterDeletingOldRRRows
    case afterDecodedInserts
    case afterArchiveInserts
    case afterCursorUpdate
    case immediatelyBeforeCommit
    case afterCommitBeforeReturn
    case duringCancellation
    case afterProcessDeathReopen
}

public enum HistoryCommitError: Error, Sendable, Equatable, LocalizedError {
    case injected(HistoryCommitFailurePoint)
    /// The same durable batch identity was presented with a different
    /// boundary. Reject it before any canonical, archive, cursor, or ledger
    /// row can be changed.
    case batchTokenConflict(batchID: String)

    public var errorDescription: String? {
        switch self {
        case .injected(let point):
            return "history commit failure injected at \(point.rawValue)"
        case .batchTokenConflict(let batchID):
            return "history batch \(batchID) was already committed with a different boundary token"
        }
    }
}

/// Names and column conventions shared by the STO-02 schema and this commit
/// implementation.  Migrations own table creation; this type only prevents
/// SQL spelling drift between the transaction and focused tests.
public enum HistoryCommitSchema {
    public static let decodedSecond = "decoded_second"
    public static let rrBeat = "rr_beat"
    public static let rawArchive = "raw_archive"
    public static let syncCursor = "sync_cursor"
    public static let syncBatch = "sync_batch"

    public static let timestamp = "physiological_timestamp"
}

/// GRDB-backed implementation of the commit-before-ACK boundary.
///
/// The actor serializes all calls at the StorageKit seam.  GRDB additionally
/// serializes the underlying writer connection; the two layers together make
/// the ordering explicit and prevent a caller from racing a restore/commit
/// operation through a second facade.
public actor SQLiteHistoryBatchStore: HistoryBatchStore, HistoryBatchAcknowledger {
    private let database: StorageDatabase
    private let failurePoints: Set<HistoryCommitFailurePoint>

    public init(
        database: StorageDatabase,
        failurePoints: Set<HistoryCommitFailurePoint> = []
    ) {
        self.database = database
        self.failurePoints = failurePoints
    }

    public func commit(
        records: [StoredHistoricalRecord],
        archived: [ArchivedHistoricalRecord],
        boundary: HistoryCommitBoundary,
        diagnostics: HistoryBatchDiagnostics
    ) async throws -> DurableHistoryCommit {
        try check(point: .beforeTransactionStart)

        // A cancellation is observed before any transaction work. Once SQLite
        // enters this closure, every thrown error rolls back all eight actions.
        try Self.checkCancellation()

        try database.write { db in
                // Validate the durable batch boundary before the first write
                // in this transaction. A redelivery with a different token,
                // or a tokenized boundary where this batch already recorded a
                // completion tail, must fail closed without changing any
                // canonical, archive, cursor, or batch data.
                let existingBatch = try Row.fetchOne(
                    db,
                    sql: "SELECT state, token FROM \(HistoryCommitSchema.syncBatch) WHERE batch_id = ?",
                    arguments: [diagnostics.batchID]
                )
                let existingBatchState: String? = existingBatch?["state"]
                let existingBatchToken: Data? = existingBatch?["token"]
                try Self.validateBoundary(
                    boundary,
                    existingState: existingBatchState,
                    existingToken: existingBatchToken,
                    batchID: diagnostics.batchID
                )

                // (1): replace canonical seconds by physiological timestamp.
                // The upsert preserves the parent id, so its children can be
                // removed and rebuilt deterministically in the next action.
                for record in records {
                    try db.execute(
                        sql: """
                        INSERT INTO \(HistoryCommitSchema.decodedSecond)(
                            physiological_timestamp, band_counter,
                            absolute_timestamp, local_day, record_version,
                            subsecond_ticks, heart_rate, gravity_x, gravity_y,
                            gravity_z, ppg_green, ppg_red_ir, skin_contact,
                            spo2_red_raw, spo2_ir_raw, unidentified_68, skin_temperature_celsius, ambient_raw,
                            raw_payload
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(physiological_timestamp) DO UPDATE SET
                            band_counter = excluded.band_counter,
                            absolute_timestamp = excluded.absolute_timestamp,
                            local_day = excluded.local_day,
                            record_version = excluded.record_version,
                            subsecond_ticks = excluded.subsecond_ticks,
                            heart_rate = excluded.heart_rate,
                            gravity_x = excluded.gravity_x,
                            gravity_y = excluded.gravity_y,
                            gravity_z = excluded.gravity_z,
                            ppg_green = excluded.ppg_green,
                            ppg_red_ir = excluded.ppg_red_ir,
                            skin_contact = excluded.skin_contact,
                            spo2_red_raw = excluded.spo2_red_raw,
                            spo2_ir_raw = excluded.spo2_ir_raw,
                            unidentified_68 = excluded.unidentified_68,
                            skin_temperature_celsius = excluded.skin_temperature_celsius,
                            ambient_raw = excluded.ambient_raw,
                            raw_payload = excluded.raw_payload
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
                            record.ppgGreen.map { Int64($0) },
                            record.ppgRedIR.map { Int64($0) },
                            record.skinContact.map { Int64($0) },
                            record.spo2RedRaw.map { Int64($0) },
                            record.spo2IRRaw.map { Int64($0) },
                            record.unidentified68.map { Int64($0) },
                            record.skinTemperatureCelsius,
                            record.ambientRaw.map { Int64($0) },
                            record.rawPayload
                        ]
                    )
                }
                try Self.failIfConfigured(failurePoints, point: .afterDecodedInserts)
                try Self.checkCancellation()

                // (2): remove stale RR children by parent identity. This is
                // deliberately after the parent upsert and before new children.
                for record in records {
                    guard let parentID = try Int64.fetchOne(
                        db,
                        sql: "SELECT id FROM \(HistoryCommitSchema.decodedSecond) WHERE physiological_timestamp = ?",
                        arguments: [record.physiologicalTimestamp]
                    ) else {
                        throw StorageLedgerError.canonicalSecondMissing
                    }
                    try db.execute(
                        sql: "DELETE FROM \(HistoryCommitSchema.rrBeat) WHERE decoded_second_id = ?",
                        arguments: [parentID]
                    )
                }
                try Self.checkCancellationOrInjection(
                    failurePoints: failurePoints,
                    point: .duringCancellation
                )
                try Self.failIfConfigured(failurePoints, point: .afterDeletingOldRRRows)

                // (3): attach current children only after every parent exists.
                for record in records {
                    guard let parentID = try Int64.fetchOne(
                        db,
                        sql: "SELECT id FROM \(HistoryCommitSchema.decodedSecond) WHERE physiological_timestamp = ?",
                        arguments: [record.physiologicalTimestamp]
                    ) else {
                        throw StorageLedgerError.canonicalSecondMissing
                    }
                    // A real burst can carry the same second twice. The
                    // parent upsert keeps the last record, so its beats
                    // replace the earlier ones instead of colliding on
                    // (decoded_second_id, beat_index).
                    try db.execute(
                        sql: "DELETE FROM \(HistoryCommitSchema.rrBeat) WHERE decoded_second_id = ?",
                        arguments: [parentID]
                    )
                    for beat in record.rrBeats {
                        try db.execute(
                            sql: """
                            INSERT INTO \(HistoryCommitSchema.rrBeat)(
                                decoded_second_id, beat_index, rr_milliseconds,
                                beat_timestamp_milliseconds
                            ) VALUES (?, ?, ?, ?)
                            """,
                            arguments: [
                                parentID,
                                beat.index,
                                beat.intervalMilliseconds,
                                beat.timestampMilliseconds
                            ]
                        )
                    }
                }
                try Self.checkCancellation()

                // (4): unsupported bytes are durable before any ACK can be
                // built. The exact payload is the conflict key.
                for archive in archived {
                    try db.execute(
                        sql: """
                        INSERT OR IGNORE INTO \(HistoryCommitSchema.rawArchive)(
                            raw_payload, packet_type, record_version, band_counter,
                            physiological_timestamp, captured_at, reason
                        ) VALUES (?, ?, ?, ?, ?, ?, ?)
                        """,
                        arguments: [
                            archive.rawPayload,
                            archive.packetType.map { Int64($0) },
                            archive.version.map { Int64($0) },
                            archive.bandCounter.map { Int64($0) },
                            archive.physiologicalTimestamp,
                            archive.capturedAt,
                            archive.reason
                        ]
                    )
                }
                try Self.failIfConfigured(failurePoints, point: .afterArchiveInserts)

                // (5) and (6): update high-waters and either replace the exact
                // token or preserve the prior token for a completion tail.
                guard let cursor = try Row.fetchOne(
                    db,
                    sql: "SELECT token, counter_high_water, timestamp_high_water FROM \(HistoryCommitSchema.syncCursor) WHERE id = 1"
                ) else {
                    throw StorageLedgerError.cursorMissing
                }
                let currentTimestamp: Int64? = cursor["timestamp_high_water"]
                let currentCounter: Int64? = cursor["counter_high_water"]
                let highWaterTimestamp = Self.highWater(
                    current: currentTimestamp,
                    values: records.map(\.physiologicalTimestamp)
                )
                let highWaterCounter = Self.highWater(
                    current: currentCounter,
                    values: records.map { Int64($0.bandCounter) }
                )
                let tokenBytes: Data?
                switch boundary {
                case .tokenized(let token):
                    tokenBytes = token.persistedBytes
                case .completionTail:
                    tokenBytes = cursor["token"]
                }
                try db.execute(
                    sql: """
                    UPDATE \(HistoryCommitSchema.syncCursor)
                    SET token = ?, counter_high_water = ?,
                        timestamp_high_water = ?, updated_at = ?
                    WHERE id = 1
                    """,
                    arguments: [
                        tokenBytes,
                        highWaterCounter,
                        highWaterTimestamp,
                        diagnostics.receivedAt
                    ]
                )
                try Self.failIfConfigured(failurePoints, point: .afterCursorUpdate)

                // (7): ledger status is committed in the same transaction.
                // Existing ids are marked redelivered; payload/cursor writes
                // remain idempotent on retry.
                let state = existingBatchState == nil
                    ? SyncBatchState.committed.rawValue
                    : SyncBatchState.redelivered.rawValue
                let batchToken: Data? = {
                    if case .tokenized(let token) = boundary { return token.persistedBytes }
                    return nil
                }()
                try db.execute(
                    sql: """
                    INSERT INTO \(HistoryCommitSchema.syncBatch)(
                        batch_id, state, token, received_at, updated_at, error
                    ) VALUES (?, ?, ?, ?, ?, NULL)
                    ON CONFLICT(batch_id) DO UPDATE SET
                        state = excluded.state,
                        token = COALESCE(excluded.token, \(HistoryCommitSchema.syncBatch).token),
                        received_at = excluded.received_at,
                        updated_at = excluded.updated_at,
                        error = excluded.error
                    """,
                    arguments: [
                        diagnostics.batchID,
                        state,
                        batchToken,
                        diagnostics.receivedAt,
                        diagnostics.receivedAt
                    ]
                )

                // This hook is intentionally after all eight durable actions
                // have emitted writes inside the transaction. The injected
                // error models process death at a WAL/transaction boundary;
                // GRDB must roll the transaction back before the caller can
                // close and reopen the database in the recovery test.
                try Self.failIfConfigured(
                    failurePoints,
                    point: .afterProcessDeathReopen
                )

                // (8): last hook inside SQLite. Any injected error rolls back
                // every preceding action, so it cannot produce an ACK.
                try Self.failIfConfigured(
                    failurePoints,
                    point: .immediatelyBeforeCommit
                )
            return ()
        }

        // This point is intentionally outside the transaction. The database is
        // already durable, but the caller receives an error and must redeliver;
        // a subsequent call converges via timestamp replacement and payload
        // deduplication.
        try check(point: .afterCommitBeforeReturn)

        switch boundary {
        case .tokenized(let token):
            return .ackEligible(
                CommittedHistoryBatch(
                    token: token,
                    batchID: diagnostics.batchID,
                    recordCount: records.count,
                    archivedCount: archived.count
                )
            )
        case .completionTail:
            return .completionTail(
                CommittedHistoryTail(
                    batchID: diagnostics.batchID,
                    recordCount: records.count,
                    archivedCount: archived.count
                )
            )
        }
    }

    public func markAcknowledged(batchID: String, updatedAt: Int64) async throws {
        try database.markSyncBatchAcknowledged(id: batchID, updatedAt: updatedAt)
    }

    private static func validateBoundary(
        _ boundary: HistoryCommitBoundary,
        existingState: String?,
        existingToken: Data?,
        batchID: String
    ) throws {
        guard let existingState else { return }

        switch boundary {
        case .tokenized(let token):
            let requestedToken = token.persistedBytes
            if let existingToken {
                guard existingToken == requestedToken else {
                    throw HistoryCommitError.batchTokenConflict(batchID: batchID)
                }
            } else if existingState != SyncBatchState.received.rawValue {
                // A durable completion-tail row has no token by design. Do
                // not let a later tokenized call reuse that batch identity.
                throw HistoryCommitError.batchTokenConflict(batchID: batchID)
            }
        case .completionTail:
            if existingToken != nil {
                // The batch was already associated with a trim/ACK token.
                // A tokenless tail cannot reuse that identity.
                throw HistoryCommitError.batchTokenConflict(batchID: batchID)
            }
        }
    }

    private func check(point: HistoryCommitFailurePoint) throws {
        try Self.checkCancellationOrInjection(
            failurePoints: failurePoints,
            point: point
        )
    }

    private static func checkCancellationOrInjection(
        failurePoints: Set<HistoryCommitFailurePoint>,
        point: HistoryCommitFailurePoint
    ) throws {
        if Task.isCancelled {
            throw CancellationError()
        }
        try failIfConfigured(failurePoints, point: point)
    }

    private static func checkCancellation() throws {
        if Task.isCancelled {
            throw CancellationError()
        }
    }

    private static func highWater(current: Int64?, values: [Int64]) -> Int64? {
        values.reduce(current) { partial, value in
            guard let partial else { return value }
            return max(partial, value)
        }
    }

    private static func failIfConfigured(
        _ failurePoints: Set<HistoryCommitFailurePoint>,
        point: HistoryCommitFailurePoint
    ) throws {
        guard failurePoints.contains(point) else { return }
        if point == .duringCancellation {
            throw CancellationError()
        }
        throw HistoryCommitError.injected(point)
    }
}

/// Compatibility spelling for callers that prefer a database-oriented name.
public typealias HistoryBatchStoreActor = SQLiteHistoryBatchStore
