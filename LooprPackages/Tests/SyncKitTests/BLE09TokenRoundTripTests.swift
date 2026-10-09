import Foundation
import ProtocolKit
import StorageKit
import XCTest

private enum BLE09TokenDatabase {
    static func url(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("LooprSyncKit-BLE09-\(name)")
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

private struct BLE09ByteGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func nextByte() -> UInt8 {
        // A fixed, local generator keeps the fuzz corpus reproducible while
        // exercising every byte position through a nontrivial distribution.
        state = state &* 6_364_136_223_846_793_005 &+ 1
        return UInt8(truncatingIfNeeded: state >> 32)
    }

    mutating func nextTokenBytes() -> Data {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(HistoryToken.byteCount)
        for _ in 0..<HistoryToken.byteCount {
            bytes.append(nextByte())
        }
        return Data(bytes)
    }
}

/// BLE-09 regression: the one opaque token value must survive durable cursor
/// storage and reload byte-for-byte before it is handed to the ACK builder.
/// This intentionally uses the canonical ProtocolKit.HistoryToken consumed by
/// StorageKit and SyncKit; no test-only token model is introduced.
final class TokenRoundTripTests: XCTestCase {
    func testFuzzedOpaqueTokensPersistReloadAndBuildExactACK() throws {
        let (database, url) = try BLE09TokenDatabase.open("fuzz")
        defer {
            try? database.databasePool.close()
            BLE09TokenDatabase.remove(url)
        }

        var generator = BLE09ByteGenerator(seed: 0xB1E0_0908_2026_0817)
        for iteration in 0..<256 {
            let sourceBytes = generator.nextTokenBytes()
            let token = try HistoryToken(bytes: sourceBytes)
            try database.saveSyncCursor(
                token: token,
                counterHighWater: UInt32(iteration),
                timestampHighWater: Int64(iteration),
                updatedAt: Int64(iteration)
            )

            let loaded = try XCTUnwrap(database.syncCursorSnapshot().token)
            XCTAssertEqual(
                loaded.persistedBytes,
                sourceBytes,
                "cursor token changed at fuzz iteration \(iteration)"
            )

            // A caller receives an immutable copy.  Mutating that copy must
            // not alter what a subsequent ACK build sees.
            if iteration.isMultiple(of: 17) {
                var copiedBytes = loaded.persistedBytes
                copiedBytes[0] ^= 0xFF
                XCTAssertEqual(loaded.persistedBytes, sourceBytes)
            }

            let sequence = UInt8(truncatingIfNeeded: iteration)
            let acknowledgement = try CommandBuilder.historyAcknowledgement(
                sequence: sequence,
                token: loaded
            )
            let paddedInner = try FrameDecoder().decode(acknowledgement).paddedInner
            XCTAssertEqual(
                paddedInner,
                Data([0x23, sequence, 0x17, 0x01]) + sourceBytes,
                "ACK token bytes changed at fuzz iteration \(iteration)"
            )
        }
    }

    func testWrongLengthCorpusNeverReachesStorageOrACKBuilder() throws {
        let (database, url) = try BLE09TokenDatabase.open("lengths")
        defer {
            try? database.databasePool.close()
            BLE09TokenDatabase.remove(url)
        }

        for length in [0, 1, 2, 7, 9, 10, 15, 31, 64] {
            let bytes = Data(repeating: UInt8(length), count: length)
            XCTAssertThrowsError(try HistoryToken(bytes: bytes)) { error in
                XCTAssertTrue(error is ProtocolDecodeError)
            }
            XCTAssertThrowsError(
                try database.write { db in
                    try db.execute(
                        sql: "UPDATE sync_cursor SET token = ? WHERE id = 1",
                        arguments: [bytes]
                    )
                },
                "malformed token length \(length) must be rejected by the cursor constraint"
            )
        }
    }
}
