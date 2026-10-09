import Foundation
import ProtocolKit
import StorageKit
import XCTest

private enum STO02Database {
    static func url(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("LooprStorageKit-STO02-\(name)")
            .appendingPathExtension("sqlite")
    }

    static func remove(_ url: URL) {
        let manager = FileManager.default
        try? manager.removeItem(at: url)
        try? manager.removeItem(atPath: "\(url.path)-wal")
        try? manager.removeItem(atPath: "\(url.path)-shm")
    }

    static func open(_ name: String) throws -> (StorageDatabase, URL) {
        let url = url(name)
        remove(url)
        let database = try StorageDatabase(url: url, applicationVersion: "1.0 (1)")
        // Keep the direct helper as a focused-test fallback for a database
        // opened with an STO-01-only migrator; the production opener registers
        // the ledger migration after the metadata migration.
        if try !database.tableNames().contains("decoded_second") {
            try StorageMigrations.applySensorLedgerSchema(to: database)
        }
        return (database, url)
    }
}

private func closeAndRemove(_ database: StorageDatabase, _ url: URL) {
    try? database.databasePool.close()
    STO02Database.remove(url)
}

private func sampleRecord(
    timestamp: Int64 = 1_700_000_000,
    counter: UInt32 = 10,
    localDay: String = "2026-03-08",
    rr: [RRBeat] = [RRBeat(index: 0, intervalMilliseconds: 800)]
) -> StoredHistoricalRecord {
    StoredHistoricalRecord(
        physiologicalTimestamp: timestamp,
        bandCounter: counter,
        absoluteTimestamp: timestamp,
        localDay: localDay,
        version: 12,
        subsecondTicks: 304,
        heartRate: 86,
        gravityX: 0.0,
        gravityY: 0.0,
        gravityZ: 1.0,
        rrBeats: rr,
        rawPayload: Data([0x2F, 0x0C, UInt8(counter & 0xFF)])
    )
}

final class STO02SchemaConstraintTests: XCTestCase {
    func test_decodedSecondRejectsDuplicatePhysiologicalTimestampUsingPlainSQL() throws {
        let (database, url) = try STO02Database.open("unique")
        defer { closeAndRemove(database, url) }

        try database.write { db in
            try db.execute(sql: """
                INSERT INTO decoded_second(
                    physiological_timestamp, band_counter, absolute_timestamp, local_day
                ) VALUES (100, 1, 100, '2026-01-01')
                """)
        }
        XCTAssertThrowsError(
            try database.write { db in
                try db.execute(sql: """
                    INSERT INTO decoded_second(
                        physiological_timestamp, band_counter, absolute_timestamp, local_day
                    ) VALUES (100, 2, 100, '2026-01-01')
                    """)
            }
        )
    }

    func test_rrBeatForeignKeyCascadesWhenCanonicalSecondIsDeleted() throws {
        let (database, url) = try STO02Database.open("cascade")
        defer { closeAndRemove(database, url) }

        try database.replaceHistoricalSecond(sampleRecord())
        XCTAssertEqual(try database.readInteger(sql: "SELECT COUNT(*) FROM rr_beat"), 1)

        try database.write { db in
            try db.execute(
                sql: "DELETE FROM decoded_second WHERE physiological_timestamp = 1_700_000_000"
            )
        }
        XCTAssertEqual(try database.readInteger(sql: "SELECT COUNT(*) FROM rr_beat"), 0)
    }

    func test_syncBatchStateConstraintAcceptsExactlyFiveTypedStates() throws {
        let (database, url) = try STO02Database.open("states")
        defer { closeAndRemove(database, url) }

        for (index, state) in SyncBatchState.allCases.enumerated() {
            try database.recordSyncBatch(
                id: "batch-\(index)",
                state: state,
                receivedAt: Int64(index),
                updatedAt: Int64(index)
            )
        }
        XCTAssertEqual(
            try database.readInteger(sql: "SELECT COUNT(*) FROM sync_batch"),
            Int64(SyncBatchState.allCases.count)
        )
        XCTAssertThrowsError(
            try database.write { db in
                try db.execute(sql: """
                    INSERT INTO sync_batch(batch_id, state, received_at, updated_at)
                    VALUES ('invalid', 'unknown', 0, 0)
                    """)
            }
        )
    }
}

final class STO02TokenStorageTests: XCTestCase {
    func testOpaqueEightByteTokensRoundTripByteForByte() throws {
        let (database, url) = try STO02Database.open("tokens")
        defer { closeAndRemove(database, url) }

        let values: [Data] = [
            Data(repeating: 0, count: 8),
            Data(repeating: 0xFF, count: 8),
            Data([0x00, 0xAA, 0x10, 0x80, 0xDE, 0xAD, 0xBE, 0xEF]),
            Data([0xEF, 0xBE, 0xAD, 0xDE, 0x80, 0x10, 0xAA, 0x00])
        ]
        for bytes in values {
            let token = try HistoryToken(bytes: bytes)
            try database.saveSyncCursor(
                token: token,
                counterHighWater: 123,
                timestampHighWater: 456,
                updatedAt: 789
            )
            XCTAssertEqual(try database.syncCursorSnapshot().token?.persistedBytes, bytes)
        }
    }

    func testCursorBLOBRejectsNonEightByteToken() throws {
        let (database, url) = try STO02Database.open("token-length")
        defer { closeAndRemove(database, url) }

        XCTAssertThrowsError(
            try database.write { db in
                try db.execute(
                    sql: "UPDATE sync_cursor SET token = ? WHERE id = 1",
                    arguments: [Data([0x01])]
                )
            }
        )
    }
}

final class STO02RawArchiveTests: XCTestCase {
    func testExactRedeliveryDeduplicatesButDistinctPayloadsRemain() throws {
        let (database, url) = try STO02Database.open("archive-dedupe")
        defer { closeAndRemove(database, url) }

        let first = ArchivedHistoricalRecord(
            raw: Data([0x2F, 0xFE, 0x01]),
            reason: "unsupported version",
            capturedAt: 10,
            packetType: 0x2F,
            version: 0xFE,
            bandCounter: 1
        )
        let distinct = ArchivedHistoricalRecord(
            raw: Data([0x2F, 0xFE, 0x02]),
            reason: "unsupported version",
            capturedAt: 11,
            packetType: 0x2F,
            version: 0xFE,
            bandCounter: 1
        )
        try database.archiveUnsupportedRecord(first)
        try database.archiveUnsupportedRecord(first)
        try database.archiveUnsupportedRecord(distinct)

        let rows = try database.archivedHistoricalRecords()
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.map(\.rawPayload), [first.rawPayload, distinct.rawPayload])
        XCTAssertEqual(rows[0].reason, first.reason)
    }

    func testArchiveSurvivesVacuumAndMaintenanceFreeReadPath() throws {
        let (database, url) = try STO02Database.open("archive-retention")
        defer { closeAndRemove(database, url) }

        let record = ArchivedHistoricalRecord(
            raw: Data([0x2F, 0x12, 0x80]),
            reason: "malformed",
            capturedAt: 1,
            packetType: 0x2F,
            version: 0x12
        )
        try database.archiveUnsupportedRecord(record)
        try database.databasePool.writeWithoutTransaction { db in
            try db.execute(sql: "VACUUM")
        }
        XCTAssertEqual(try database.archivedHistoricalRecords().map(\.rawPayload), [record.rawPayload])
    }
}

final class STO02ReplacementTests: XCTestCase {
    func testReplacementUsesTimestampNotCounterAndReplacesRRChildrenAtomically() throws {
        let (database, url) = try STO02Database.open("replacement")
        defer { closeAndRemove(database, url) }

        try database.replaceHistoricalSecond(sampleRecord(counter: 100, rr: [
            RRBeat(index: 0, intervalMilliseconds: 700),
            RRBeat(index: 1, intervalMilliseconds: 710)
        ]))
        try database.replaceHistoricalSecond(sampleRecord(counter: 2, rr: [
            RRBeat(index: 0, intervalMilliseconds: 900)
        ]))

        XCTAssertEqual(try database.readInteger(sql: "SELECT COUNT(*) FROM decoded_second"), 1)
        XCTAssertEqual(try database.readInteger(sql: "SELECT COUNT(*) FROM rr_beat"), 1)
        let row = try XCTUnwrap(database.storedHistoricalSecond(physiologicalTimestamp: 1_700_000_000))
        XCTAssertEqual(row.bandCounter, 2)
        XCTAssertEqual(row.rrBeats.map(\.intervalMilliseconds), [900])
    }

    func testAbsoluteTimestampAndLocalDayRemainIndependent() throws {
        let (database, url) = try STO02Database.open("dst")
        defer { closeAndRemove(database, url) }

        let record = StoredHistoricalRecord(
            physiologicalTimestamp: 1_772_953_199,
            bandCounter: 7,
            absoluteTimestamp: 1_772_953_199,
            localDay: "2026-03-08",
            rrBeats: []
        )
        try database.replaceHistoricalSecond(record)
        let loaded = try XCTUnwrap(
            database.storedHistoricalSecond(physiologicalTimestamp: record.physiologicalTimestamp)
        )
        XCTAssertEqual(loaded.absoluteTimestamp, record.absoluteTimestamp)
        XCTAssertEqual(loaded.localDay, "2026-03-08")
    }

    func testReplacementAbsentPriorRowInsertsCanonicalSecond() throws {
        let (database, url) = try STO02Database.open("replacement-absent")
        defer { closeAndRemove(database, url) }

        let record = sampleRecord(timestamp: 1_800_000_000, counter: 1, rr: [])
        XCTAssertNil(try database.storedHistoricalSecond(physiologicalTimestamp: record.physiologicalTimestamp))
        try database.replaceHistoricalSecond(record)
        XCTAssertNotNil(try database.storedHistoricalSecond(physiologicalTimestamp: record.physiologicalTimestamp))
    }
}

final class STO02SchemaInventoryTests: XCTestCase {
    func testAllPlanTablesExistAfterLedgerSchemaMigration() throws {
        let (database, url) = try STO02Database.open("inventory")
        defer { closeAndRemove(database, url) }

        let names = try database.tableNames()
        for required in StorageDatabase.requiredLedgerTableNames {
            XCTAssertTrue(names.contains(required), "Missing required table \(required)")
        }
        XCTAssertEqual(StorageDatabase.requiredLedgerTableNames.count, 15)
    }
}
