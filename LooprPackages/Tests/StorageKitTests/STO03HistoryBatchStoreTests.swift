import Foundation
import GRDB
import ProtocolKit
import StorageKit
import XCTest

private enum STO03Database {
    static func url(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("LooprStorageKit-STO03-\(name)")
            .appendingPathExtension("sqlite")
    }

    static func remove(_ url: URL) {
        let manager = FileManager.default
        try? manager.removeItem(at: url)
        try? manager.removeItem(atPath: "\(url.path)-wal")
        try? manager.removeItem(atPath: "\(url.path)-shm")
    }

    static func open(_ name: String) throws -> (StorageDatabase, URL) {
        let databaseURL = url(name)
        remove(databaseURL)
        let database = try StorageDatabase(url: databaseURL, applicationVersion: "1.0 (1)")
        if try !database.tableNames().contains("decoded_second") {
            try StorageMigrations.applySensorLedgerSchema(to: database)
        }
        return (database, databaseURL)
    }
}

private func closeAndRemoveSTO03(_ database: StorageDatabase, _ url: URL) {
    try? database.databasePool.close()
    STO03Database.remove(url)
}

private func token(_ bytes: [UInt8]) throws -> HistoryToken {
    try HistoryToken(bytes: Data(bytes))
}

private func historyRecord(
    timestamp: Int64 = 1_700_000_000,
    counter: UInt32 = 10,
    rr: [RRBeat] = [RRBeat(index: 0, intervalMilliseconds: 800)]
) -> StoredHistoricalRecord {
    StoredHistoricalRecord(
        physiologicalTimestamp: timestamp,
        bandCounter: counter,
        absoluteTimestamp: timestamp,
        localDay: "2026-03-08",
        version: 12,
        subsecondTicks: 304,
        heartRate: 86,
        gravityX: 0,
        gravityY: 0,
        gravityZ: 1,
        rrBeats: rr,
        rawPayload: Data([0x2F, 0x0C, UInt8(counter & 0xFF)])
    )
}

private func unsupportedArchive(
    bytes: [UInt8] = [0x2F, 0xFE, 0x01],
    counter: UInt32 = 1
) -> ArchivedHistoricalRecord {
    ArchivedHistoricalRecord(
        raw: Data(bytes),
        reason: "unsupported version",
        capturedAt: 123,
        packetType: 0x2F,
        version: 0xFE,
        bandCounter: counter
    )
}

private func assertCandidateAbsent(_ database: StorageDatabase) throws {
    XCTAssertEqual(
        try database.readInteger(
            sql: "SELECT COUNT(*) FROM decoded_second WHERE physiological_timestamp = 1_700_000_001"
        ),
        0
    )
    XCTAssertEqual(try database.readInteger(sql: "SELECT COUNT(*) FROM raw_archive"), 1)
    XCTAssertEqual(try database.readInteger(sql: "SELECT COUNT(*) FROM sync_batch"), 0)
    XCTAssertNil(try database.syncCursorSnapshot().token)
}

final class NoAckFromCompletionTailTests: XCTestCase {
    func testDurableCommitSwitchIsExhaustiveAndCompletionTailHasNoToken() throws {
        let completion = DurableHistoryCommit.completionTail(
            CommittedHistoryTail(batchID: "tail", recordCount: 2, archivedCount: 1)
        )

        // This exhaustive switch is the compile-time no-ACK proof: the tail
        // branch has no token value from which a trim/ACK command can be built.
        switch completion {
        case .ackEligible(let batch):
            XCTFail("completion-tail result unexpectedly carried ACK token \(batch.token)")
        case .completionTail(let tail):
            XCTAssertEqual(tail.batchID, "tail")
            XCTAssertEqual(tail.recordCount, 2)
            XCTAssertEqual(tail.archivedCount, 1)
        }
    }

    func testCompletionTailCommitsDataAndPreservesPriorCursorToken() async throws {
        let (database, url) = try STO03Database.open("tail-preserves-token")
        defer { closeAndRemoveSTO03(database, url) }

        let priorToken = try token([0x00, 0xAA, 0x10, 0x80, 0xDE, 0xAD, 0xBE, 0xEF])
        try database.saveSyncCursor(
            token: priorToken,
            counterHighWater: 20,
            timestampHighWater: 1_700_000_000,
            updatedAt: 10
        )
        let store = SQLiteHistoryBatchStore(database: database)

        let result = try await store.commit(
            records: [historyRecord(timestamp: 1_700_000_001, counter: 2)],
            archived: [unsupportedArchive()],
            boundary: .completionTail,
            diagnostics: HistoryBatchDiagnostics(batchID: "tail-1", receivedAt: 20)
        )

        switch result {
        case .ackEligible:
            XCTFail("completion tail must never be ACK eligible")
        case .completionTail(let tail):
            XCTAssertEqual(tail.batchID, "tail-1")
            XCTAssertEqual(tail.recordCount, 1)
            XCTAssertEqual(tail.archivedCount, 1)
        }
        let cursor = try database.syncCursorSnapshot()
        XCTAssertEqual(cursor.token?.persistedBytes, priorToken.persistedBytes)
        XCTAssertEqual(cursor.counterHighWater, 20)
        XCTAssertEqual(cursor.timestampHighWater, 1_700_000_001)
    }
}

final class DuplicateSecondCommitTests: XCTestCase {
    /// A real WHOOP 4.0 burst carried the same second twice. The commit
    /// failed on the rr_beat unique key, so no chunk with wear data could
    /// ever be stored or acknowledged.
    func testTheSameSecondTwiceInOneBurstKeepsTheLastRecordsBeats() async throws {
        let (database, url) = try STO03Database.open("duplicate-second")
        defer { closeAndRemoveSTO03(database, url) }
        let store = SQLiteHistoryBatchStore(database: database)

        let first = historyRecord(
            timestamp: 1_700_000_050,
            counter: 1,
            rr: [
                RRBeat(index: 0, intervalMilliseconds: 800),
                RRBeat(index: 1, intervalMilliseconds: 810),
                RRBeat(index: 2, intervalMilliseconds: 820)
            ]
        )
        let second = historyRecord(
            timestamp: 1_700_000_050,
            counter: 2,
            rr: [RRBeat(index: 0, intervalMilliseconds: 900)]
        )

        _ = try await store.commit(
            records: [first, second],
            archived: [],
            boundary: .tokenized(try token([0x01, 0x02, 0x03, 0x04, 0x1E, 0x00, 0x00, 0x00])),
            diagnostics: HistoryBatchDiagnostics(batchID: "duplicate-second", receivedAt: 30)
        )

        let beats = try await database.databasePool.read { db in
            try Int.fetchAll(db, sql: "SELECT rr_milliseconds FROM rr_beat ORDER BY beat_index")
        }
        XCTAssertEqual(beats, [900])
        let seconds = try await database.databasePool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM decoded_second") ?? 0
        }
        XCTAssertEqual(seconds, 1)
    }
}

final class AtomicCommitTests: XCTestCase {
    func testEightActionsCommitCanonicalReplacementArchiveCursorAndBatchTogether() async throws {
        let (database, url) = try STO03Database.open("atomic")
        defer { closeAndRemoveSTO03(database, url) }

        let timestamp: Int64 = 1_700_000_000
        try database.replaceHistoricalSecond(
            historyRecord(
                timestamp: timestamp,
                counter: 100,
                rr: [
                    RRBeat(index: 0, intervalMilliseconds: 700),
                    RRBeat(index: 1, intervalMilliseconds: 710)
                ]
            )
        )
        let oldToken = try token([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])
        try database.saveSyncCursor(
            token: oldToken,
            counterHighWater: 100,
            timestampHighWater: timestamp,
            updatedAt: 1
        )

        let newToken = try token([0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01])
        let store = SQLiteHistoryBatchStore(database: database)
        let result = try await store.commit(
            records: [
                historyRecord(
                    timestamp: timestamp,
                    counter: 2,
                    rr: [RRBeat(index: 0, intervalMilliseconds: 900)]
                )
            ],
            archived: [unsupportedArchive()],
            boundary: .tokenized(newToken),
            diagnostics: HistoryBatchDiagnostics(batchID: "atomic-1", receivedAt: 2)
        )

        guard case .ackEligible(let committed) = result else {
            return XCTFail("tokenized commit must be ACK eligible after durability")
        }
        XCTAssertEqual(committed.token.persistedBytes, newToken.persistedBytes)
        XCTAssertEqual(committed.recordCount, 1)
        XCTAssertEqual(committed.archivedCount, 1)

        let loaded = try XCTUnwrap(
            database.storedHistoricalSecond(physiologicalTimestamp: timestamp)
        )
        XCTAssertEqual(loaded.bandCounter, 2)
        XCTAssertEqual(loaded.rrBeats.map(\.intervalMilliseconds), [900])

        let committedSnapshot = try database.read { db in
            try Row.fetchOne(
                db,
                sql: """
                SELECT
                    (SELECT COUNT(*) FROM decoded_second) AS canonical_count,
                    (SELECT COUNT(*) FROM rr_beat) AS rr_count,
                    (SELECT COUNT(*) FROM raw_archive) AS archive_count,
                    (SELECT token FROM sync_cursor WHERE id = 1) AS cursor_token,
                    (SELECT state FROM sync_batch WHERE batch_id = 'atomic-1') AS batch_state
                """
            )
        }
        XCTAssertEqual(try XCTUnwrap(committedSnapshot?["canonical_count"] as Int64?), 1)
        XCTAssertEqual(try XCTUnwrap(committedSnapshot?["rr_count"] as Int64?), 1)
        XCTAssertEqual(try XCTUnwrap(committedSnapshot?["archive_count"] as Int64?), 1)
        XCTAssertEqual(
            (committedSnapshot?["cursor_token"] as Data?)?.count,
            newToken.persistedBytes.count
        )
        XCTAssertEqual(
            committedSnapshot?["batch_state"] as String?,
            SyncBatchState.committed.rawValue
        )
        XCTAssertEqual(try database.readInteger(sql: "SELECT COUNT(*) FROM decoded_second"), 1)
        XCTAssertEqual(try database.readInteger(sql: "SELECT COUNT(*) FROM rr_beat"), 1)
        XCTAssertEqual(try database.readInteger(sql: "SELECT COUNT(*) FROM raw_archive"), 1)
        XCTAssertEqual(try database.syncCursorSnapshot().token?.persistedBytes, newToken.persistedBytes)
        XCTAssertEqual(
            try database.readString(sql: "SELECT state FROM sync_batch WHERE batch_id = 'atomic-1'"),
            SyncBatchState.committed.rawValue
        )
    }
}

final class BatchBoundaryConflictTests: XCTestCase {
    func testSameBatchIDWithDifferentTokenFailsClosedBeforeAnyMutation() async throws {
        let (database, url) = try STO03Database.open("boundary-token-conflict")
        defer { closeAndRemoveSTO03(database, url) }

        let firstToken = try token([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])
        let secondToken = try token([0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01])
        let diagnostics = HistoryBatchDiagnostics(
            batchID: "boundary-conflict",
            receivedAt: 10
        )
        let store = SQLiteHistoryBatchStore(database: database)

        guard case .ackEligible = try await store.commit(
            records: [historyRecord(timestamp: 1_700_000_000, counter: 10)],
            archived: [unsupportedArchive(bytes: [0x2F, 0xFE, 0x01])],
            boundary: .tokenized(firstToken),
            diagnostics: diagnostics
        ) else {
            return XCTFail("initial tokenized batch should be ACK eligible")
        }

        do {
            _ = try await store.commit(
                records: [historyRecord(timestamp: 1_700_000_001, counter: 99)],
                archived: [unsupportedArchive(bytes: [0x2F, 0xFE, 0x99])],
                boundary: .tokenized(secondToken),
                diagnostics: HistoryBatchDiagnostics(
                    batchID: diagnostics.batchID,
                    receivedAt: 11
                )
            )
            XCTFail("a different token for the same batch ID must fail closed")
        } catch let error as HistoryCommitError {
            XCTAssertEqual(
                error,
                .batchTokenConflict(batchID: diagnostics.batchID)
            )
        } catch {
            XCTFail("unexpected boundary-conflict error: \(error)")
        }

        // The rejection happens before the second batch can alter any
        // canonical, RR, archive, cursor, or ledger row.
        XCTAssertEqual(
            try database.readInteger(sql: "SELECT COUNT(*) FROM decoded_second"),
            1
        )
        XCTAssertEqual(
            try database.readInteger(sql: "SELECT COUNT(*) FROM rr_beat"),
            1
        )
        XCTAssertEqual(
            try database.readInteger(sql: "SELECT COUNT(*) FROM raw_archive"),
            1
        )
        XCTAssertEqual(
            try database.readInteger(sql: "SELECT COUNT(*) FROM sync_batch"),
            1
        )
        let canonical = try XCTUnwrap(
            database.storedHistoricalSecond(
                physiologicalTimestamp: 1_700_000_000
            )
        )
        XCTAssertEqual(canonical.bandCounter, 10)
        XCTAssertNil(
            try database.storedHistoricalSecond(
                physiologicalTimestamp: 1_700_000_001
            )
        )
        XCTAssertEqual(
            try database.syncCursorSnapshot().token?.persistedBytes,
            firstToken.persistedBytes
        )
        XCTAssertEqual(
            try database.syncCursorSnapshot().timestampHighWater,
            1_700_000_000
        )
        XCTAssertEqual(
            try database.readString(
                sql: "SELECT state FROM sync_batch WHERE batch_id = ?",
                arguments: [diagnostics.batchID]
            ),
            SyncBatchState.committed.rawValue
        )
    }
}

final class FailureInjectionTests: XCTestCase {
    private func run(_ point: HistoryCommitFailurePoint) async throws {
        let (database, url) = try STO03Database.open("failure-\(point.rawValue)-\(UUID().uuidString)")
        defer { closeAndRemoveSTO03(database, url) }
        try database.archiveUnsupportedRecord(unsupportedArchive())
        let candidate = historyRecord(timestamp: 1_700_000_001, counter: 2)
        let candidateToken = try token([0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88])
        let store = SQLiteHistoryBatchStore(database: database, failurePoints: [point])

        do {
            _ = try await store.commit(
                records: [candidate],
                archived: [unsupportedArchive(bytes: [0x2F, 0xFE, 0x02])],
                boundary: .tokenized(candidateToken),
                diagnostics: HistoryBatchDiagnostics(batchID: "failure-\(point.rawValue)", receivedAt: 10)
            )
            XCTFail("failure injection \(point.rawValue) unexpectedly succeeded")
        } catch {
            if point == .duringCancellation {
                XCTAssertTrue(error is CancellationError, "unexpected error: \(error)")
            } else {
                XCTAssertEqual(
                    error as? HistoryCommitError,
                    .injected(point),
                    "unexpected error at \(point.rawValue): \(error)"
                )
            }
        }

        if point == .afterCommitBeforeReturn {
            XCTAssertNotNil(
                try database.storedHistoricalSecond(
                    physiologicalTimestamp: candidate.physiologicalTimestamp
                )
            )
            XCTAssertEqual(try database.readInteger(sql: "SELECT COUNT(*) FROM raw_archive"), 2)
            XCTAssertEqual(
                try database.syncCursorSnapshot().token?.persistedBytes,
                candidateToken.persistedBytes
            )
            XCTAssertEqual(
                try database.readString(
                    sql: "SELECT state FROM sync_batch WHERE batch_id = ?",
                    arguments: ["failure-\(point.rawValue)"]
                ),
                SyncBatchState.committed.rawValue
            )

            // The caller saw an error after SQLite committed. Redelivering
            // the exact same batch must converge without duplicate canonical,
            // RR, archive, or batch rows and must return the same exact ACK
            // token.
            let redeliveryStore = SQLiteHistoryBatchStore(database: database)
            guard case .ackEligible(let redelivery) = try await redeliveryStore.commit(
                records: [candidate],
                archived: [unsupportedArchive(bytes: [0x2F, 0xFE, 0x02])],
                boundary: .tokenized(candidateToken),
                diagnostics: HistoryBatchDiagnostics(
                    batchID: "failure-\(point.rawValue)",
                    receivedAt: 10
                )
            ) else {
                return XCTFail("post-commit redelivery must remain ACK eligible")
            }
            XCTAssertEqual(redelivery.token.persistedBytes, candidateToken.persistedBytes)
            XCTAssertEqual(
                try database.readInteger(sql: "SELECT COUNT(*) FROM decoded_second"),
                1
            )
            XCTAssertEqual(
                try database.readInteger(sql: "SELECT COUNT(*) FROM rr_beat"),
                1
            )
            XCTAssertEqual(
                try database.readInteger(sql: "SELECT COUNT(*) FROM raw_archive"),
                2
            )
            XCTAssertEqual(
                try database.readInteger(sql: "SELECT COUNT(*) FROM sync_batch"),
                1
            )
            XCTAssertEqual(
                try database.readString(
                    sql: "SELECT state FROM sync_batch WHERE batch_id = ?",
                    arguments: ["failure-\(point.rawValue)"]
                ),
                SyncBatchState.redelivered.rawValue
            )
        } else {
            try assertCandidateAbsent(database)
        }
    }

    func testEveryStorageFailurePointIsDeterministicAndAtomic() async throws {
        for point in HistoryCommitFailurePoint.allCases {
            try await run(point)
        }
    }

    func test_beforeTransactionStart() async throws {
        try await run(.beforeTransactionStart)
    }

    func test_afterDeletingOldRRRows() async throws {
        try await run(.afterDeletingOldRRRows)
    }

    func test_afterDecodedInserts() async throws {
        try await run(.afterDecodedInserts)
    }

    func test_afterArchiveInserts() async throws {
        try await run(.afterArchiveInserts)
    }

    func test_afterCursorUpdate() async throws {
        try await run(.afterCursorUpdate)
    }

    func test_immediatelyBeforeCommit() async throws {
        try await run(.immediatelyBeforeCommit)
    }

    func test_afterCommitBeforeReturn() async throws {
        try await run(.afterCommitBeforeReturn)
    }

    func test_duringCancellation() async throws {
        try await run(.duringCancellation)

        // Also cancel the calling task before the actor enters SQLite. The
        // deterministic injected case above exercises cancellation after the
        // RR-delete action; this assertion covers the public async seam.
        let (database, url) = try STO03Database.open("cancelled-task")
        defer { closeAndRemoveSTO03(database, url) }
        try database.archiveUnsupportedRecord(unsupportedArchive())
        let store = SQLiteHistoryBatchStore(database: database)
        let task = Task { () throws -> DurableHistoryCommit in
            await Task.yield()
            try Task.checkCancellation()
            return try await store.commit(
                records: [historyRecord(timestamp: 1_700_000_001, counter: 2)],
                archived: [unsupportedArchive(bytes: [0x2F, 0xFE, 0x05])],
                boundary: .tokenized(try token([8, 7, 6, 5, 4, 3, 2, 1])),
                diagnostics: HistoryBatchDiagnostics(batchID: "cancelled-task", receivedAt: 12)
            )
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("cancelled commit unexpectedly returned an ACK result")
        } catch {
            XCTAssertTrue(error is CancellationError, "unexpected cancellation error: \(error)")
        }
        try assertCandidateAbsent(database)
    }

    func test_afterProcessDeathReopen() async throws {
        let (database, url) = try STO03Database.open("process-death")
        try database.archiveUnsupportedRecord(unsupportedArchive())
        let failing = SQLiteHistoryBatchStore(
            database: database,
            failurePoints: [.afterProcessDeathReopen]
        )
        do {
            _ = try await failing.commit(
                records: [historyRecord(timestamp: 1_700_000_001, counter: 2)],
                archived: [],
                boundary: .tokenized(try token([1, 2, 3, 4, 5, 6, 7, 8])),
                diagnostics: HistoryBatchDiagnostics(batchID: "process-death", receivedAt: 1)
            )
            XCTFail("process-death injection unexpectedly succeeded")
        } catch {
            XCTAssertEqual(error as? HistoryCommitError, .injected(.afterProcessDeathReopen))
        }
        try assertCandidateAbsent(database)

        try database.databasePool.close()
        let reopened = try StorageDatabase(url: url, applicationVersion: "1.0 (1)")
        defer { closeAndRemoveSTO03(reopened, url) }
        if try !reopened.tableNames().contains("decoded_second") {
            try StorageMigrations.applySensorLedgerSchema(to: reopened)
        }
        // The failure was injected after all batch actions had written inside
        // the transaction, so a close/reopen must observe the rolled-back WAL
        // state before the retry begins.
        try assertCandidateAbsent(reopened)
        let retry = SQLiteHistoryBatchStore(database: reopened)
        let result = try await retry.commit(
            records: [historyRecord(timestamp: 1_700_000_001, counter: 2)],
            archived: [],
            boundary: .tokenized(try token([1, 2, 3, 4, 5, 6, 7, 8])),
            diagnostics: HistoryBatchDiagnostics(batchID: "process-death", receivedAt: 2)
        )
        guard case .ackEligible = result else {
            return XCTFail("retry after reopen should be ACK eligible")
        }
    }
}

final class AckBoundaryChaosTests: XCTestCase {
    private func runStorageBoundary(_ point: HistoryCommitFailurePoint) async throws {
        let (database, url) = try STO03Database.open("chaos-\(point.rawValue)-\(UUID().uuidString)")
        defer { closeAndRemoveSTO03(database, url) }
        let store = SQLiteHistoryBatchStore(database: database, failurePoints: [point])
        let candidate = historyRecord(timestamp: 1_700_000_001, counter: 2)
        let commitToken = try token([0x91, 0x82, 0x73, 0x64, 0x55, 0x46, 0x37, 0x28])

        do {
            _ = try await store.commit(
                records: [candidate],
                archived: [unsupportedArchive(bytes: [0x2F, 0xFE, 0x04])],
                boundary: .tokenized(commitToken),
                diagnostics: HistoryBatchDiagnostics(batchID: "chaos-\(point.rawValue)", receivedAt: 11)
            )
            XCTFail("boundary \(point.rawValue) returned an ACK result")
        } catch {
            if point == .duringCancellation {
                XCTAssertTrue(error is CancellationError)
            } else {
                XCTAssertEqual(error as? HistoryCommitError, .injected(point))
            }
        }

        let canonicalCount = try database.readInteger(sql: "SELECT COUNT(*) FROM decoded_second")
        if point == .afterCommitBeforeReturn {
            XCTAssertEqual(canonicalCount, 1)
        } else {
            XCTAssertEqual(canonicalCount, 0)
            XCTAssertEqual(try database.readInteger(sql: "SELECT COUNT(*) FROM raw_archive"), 0)
            XCTAssertEqual(try database.readInteger(sql: "SELECT COUNT(*) FROM sync_batch"), 0)
        }
    }

    func testAllNineStorageFailureBoundariesNeverPermitPrematureACK() async throws {
        for point in HistoryCommitFailurePoint.allCases {
            try await runStorageBoundary(point)
        }
        // TODO(BLE-06): ACK timeout, session replacement, late END and radio
        // loss require BluetoothKit/SyncKit transport context; keep them in
        // the future coordinator-level ChaosTransport suite.
    }

    func testDuplicateDeliveryConvergesAndPreservesExactArchiveBytes() async throws {
        let (database, url) = try STO03Database.open("duplicate")
        defer { closeAndRemoveSTO03(database, url) }
        let store = SQLiteHistoryBatchStore(database: database)
        let tokenValue = try token([0x10, 0x20, 0x30, 0x40, 0x50, 0x60, 0x70, 0x80])
        let records = [historyRecord()]
        let archive = [unsupportedArchive()]
        let diagnostics = HistoryBatchDiagnostics(batchID: "duplicate", receivedAt: 7)

        guard case .ackEligible = try await store.commit(
            records: records,
            archived: archive,
            boundary: .tokenized(tokenValue),
            diagnostics: diagnostics
        ) else {
            return XCTFail("first tokenized delivery must be ACK eligible")
        }
        guard case .ackEligible(let redelivery) = try await store.commit(
            records: records,
            archived: archive,
            boundary: .tokenized(tokenValue),
            diagnostics: diagnostics
        ) else {
            return XCTFail("redelivery must converge to an ACK-eligible durable result")
        }
        XCTAssertEqual(redelivery.token.persistedBytes, tokenValue.persistedBytes)
        XCTAssertEqual(try database.readInteger(sql: "SELECT COUNT(*) FROM decoded_second"), 1)
        XCTAssertEqual(try database.readInteger(sql: "SELECT COUNT(*) FROM rr_beat"), 1)
        XCTAssertEqual(try database.readInteger(sql: "SELECT COUNT(*) FROM raw_archive"), 1)
        XCTAssertEqual(
            try database.readString(sql: "SELECT state FROM sync_batch WHERE batch_id = 'duplicate'"),
            SyncBatchState.redelivered.rawValue
        )
    }

    func testFailureThenRedeliveryDoesNotACKUntilTheRetryCommits() async throws {
        let (database, url) = try STO03Database.open("failure-retry")
        defer { closeAndRemoveSTO03(database, url) }
        let tokenValue = try token([0x81, 0x70, 0x60, 0x50, 0x40, 0x30, 0x20, 0x10])
        let diagnostics = HistoryBatchDiagnostics(batchID: "failure-retry", receivedAt: 8)
        let candidate = historyRecord(timestamp: 1_700_000_001, counter: 2)

        let failing = SQLiteHistoryBatchStore(
            database: database,
            failurePoints: [.afterArchiveInserts]
        )
        do {
            _ = try await failing.commit(
                records: [candidate],
                archived: [unsupportedArchive(bytes: [0x2F, 0xFE, 0x03])],
                boundary: .tokenized(tokenValue),
                diagnostics: diagnostics
            )
            XCTFail("injected failure unexpectedly returned an ACK result")
        } catch {
            XCTAssertEqual(error as? HistoryCommitError, .injected(.afterArchiveInserts))
        }
        XCTAssertEqual(try database.readInteger(sql: "SELECT COUNT(*) FROM decoded_second"), 0)
        XCTAssertEqual(try database.readInteger(sql: "SELECT COUNT(*) FROM raw_archive"), 0)
        XCTAssertEqual(try database.readInteger(sql: "SELECT COUNT(*) FROM sync_batch"), 0)

        let retry = SQLiteHistoryBatchStore(database: database)
        guard case .ackEligible = try await retry.commit(
            records: [candidate],
            archived: [unsupportedArchive(bytes: [0x2F, 0xFE, 0x03])],
            boundary: .tokenized(tokenValue),
            diagnostics: diagnostics
        ) else {
            return XCTFail("only the successful retry may become ACK eligible")
        }
        XCTAssertEqual(try database.readInteger(sql: "SELECT COUNT(*) FROM decoded_second"), 1)
        XCTAssertEqual(try database.readInteger(sql: "SELECT COUNT(*) FROM raw_archive"), 1)

        // BLE-session disconnect/reconnect boundaries are intentionally kept
        // out of this deterministic storage test. TODO(BLE-06): exercise them
        // at the coordinator/session layer with a CoreBluetooth-free fake.
    }

    func testCounterReuseDoesNotCollapseDistinctUnsupportedPayloads() async throws {
        let (database, url) = try STO03Database.open("counter-reset")
        defer { closeAndRemoveSTO03(database, url) }
        let store = SQLiteHistoryBatchStore(database: database)
        let diagnostics = HistoryBatchDiagnostics(batchID: "counter-reset", receivedAt: 9)

        guard case .ackEligible = try await store.commit(
            records: [],
            archived: [unsupportedArchive(bytes: [0x2F, 0xFE, 0x01], counter: 7)],
            boundary: .tokenized(try token([1, 1, 1, 1, 1, 1, 1, 1])),
            diagnostics: diagnostics
        ) else {
            return XCTFail("archive-only tokenized commit should still be durable")
        }
        _ = try await store.commit(
            records: [],
            archived: [unsupportedArchive(bytes: [0x2F, 0xFE, 0x02], counter: 7)],
            boundary: .completionTail,
            diagnostics: HistoryBatchDiagnostics(batchID: "counter-reset-tail", receivedAt: 10)
        )
        XCTAssertEqual(try database.readInteger(sql: "SELECT COUNT(*) FROM raw_archive"), 2)
    }
}
