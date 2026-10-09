import XCTest
import ProtocolKit
@testable import StorageKit

final class Gen5ResearchLedgerSchemaTests: XCTestCase {
    func testRawOutcomeMarkerAndTokenRoundTripWithoutCanonicalWrites() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gen5-ledger-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let database = try StorageDatabase(url: url, applicationVersion: "test")
        let ledger = try Gen5ResearchLedger(database: database)
        let burst = UUID()
        let token = Data([1, 2, 3, 4, 5, 6, 7, 8])
        let entry = Gen5ResearchLedgerEntry(
            model: .whoop5,
            connectionGeneration: 17,
            burstID: burst,
            ordinal: 0,
            rawFrame: Data([0xaa, 0x01, 0x08]),
            decodeSucceeded: false,
            decodeOutcome: "truncated(offset: 3)",
            marker: Data([0x01, 0x00]),
            token: token
        )
        _ = try ledger.append(entry)
        let stored = try XCTUnwrap(ledger.entries(burstID: burst).first)
        XCTAssertEqual(stored.model, .whoop5)
        XCTAssertEqual(stored.rawFrame, entry.rawFrame)
        XCTAssertEqual(stored.decodeOutcome, entry.decodeOutcome)
        XCTAssertEqual(stored.marker, entry.marker)
        XCTAssertEqual(stored.token, token)

        let canonicalCount = try database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM decoded_second")
        }
        XCTAssertEqual(canonicalCount, 0)
    }

    func testLedgerIsAdditiveOnlyAndBurstOrdered() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gen5-ledger-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let database = try StorageDatabase(url: url, applicationVersion: "test")
        let ledger = try Gen5ResearchLedger(database: database)
        let burst = UUID()
        for ordinal in 0..<3 {
            _ = try ledger.append(.init(
                model: .whoopMG, connectionGeneration: 1, burstID: burst,
                ordinal: ordinal, rawFrame: Data([UInt8(ordinal)]),
                decodeSucceeded: true, decodeOutcome: "rawArchive",
                marker: Data([1, 0]), token: nil
            ))
        }
        XCTAssertEqual(try ledger.entries(burstID: burst).map(\.ordinal), [0, 1, 2])
    }
}
