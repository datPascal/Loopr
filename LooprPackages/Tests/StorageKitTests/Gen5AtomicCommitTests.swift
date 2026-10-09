import XCTest
import ProtocolKit
@testable import StorageKit

private func makeGen5CommitStore() throws -> (Gen5AtomicCommitStore, StorageDatabase, URL) {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("gen5-commit-\(UUID().uuidString).sqlite")
    let db = try StorageDatabase(url: url, applicationVersion: "test")
    return (try Gen5AtomicCommitStore(database: db), db, url)
}

private func makeGen5CommitRequest(
    model: BandModel = .whoop5,
    burst: UUID = UUID()
) throws -> Gen5CommitRequest {
    try Gen5CommitRequest(
        model: model,
        connectionGeneration: 4,
        burstID: burst,
        token: Data([0xde, 0xad, 0xbe, 0xef, 1, 2, 3, 4]),
        rawFrames: [Data([0xaa, 1])],
        canonicalRows: [.init(
            timestamp: 1_780_916_150, index: 25_443_699, heartRate: 102,
            rrMilliseconds: [602, 613], gravity: (-0.7252, 0.4944, 0.4969)
        )]
    )
}

final class Gen5AtomicCommitTests: XCTestCase {
    func testAckUsesExactTokenOnlyAfterAtomicDurability() throws {
        for model in [BandModel.whoop5, .whoopMG] {
            let (store, database, url) = try makeGen5CommitStore()
            defer {
                try? database.databasePool.close()
                try? FileManager.default.removeItem(at: url)
            }
            let request = try makeGen5CommitRequest(model: model)
            let ack = try store.commit(request, acknowledgementSequence: 7)
            XCTAssertEqual(ack, Data([0x23, 7, 0x17, 0x01, 0xde, 0xad, 0xbe, 0xef, 1, 2, 3, 4]))
            XCTAssertEqual(try store.committedToken(burstID: request.burstID, model: model), request.token)
            XCTAssertEqual(try store.counts().batches, 1)
        }
    }

    func testTransactionRollsBackEveryPrecommitFailure() throws {
        for boundary in [Gen5CommitBoundary.beforeCommit, .duringArchive, .duringCanonicalRows, .beforeCursor] {
            let (store, database, url) = try makeGen5CommitStore()
            defer {
                try? database.databasePool.close()
                try? FileManager.default.removeItem(at: url)
            }
            XCTAssertThrowsError(try store.commit(try makeGen5CommitRequest(), acknowledgementSequence: 1, injecting: boundary))
            XCTAssertEqual(try store.counts().batches, 0)
            XCTAssertEqual(try store.counts().archive, 0)
            XCTAssertEqual(try store.counts().canonical, 0)
        }
    }
}

final class Gen5V18CanonicalizationTests: XCTestCase {
    func testCanonicalTypeContainsOnlyValidatedSubstrateFields() throws {
        let row = Gen5CanonicalV18Row(
            timestamp: 1, index: 2, heartRate: 60,
            rrMilliseconds: [1000], gravity: (0, 0, 1)
        )
        XCTAssertEqual(row.timestamp, 1)
        XCTAssertEqual(row.index, 2)
        XCTAssertEqual(row.heartRate, 60)
        XCTAssertEqual(row.rrMilliseconds, [1000])
        XCTAssertEqual(row.gravity.2, 1)
        let reflected = Set(Mirror(reflecting: row).children.compactMap(\.label))
        XCTAssertEqual(reflected, ["timestamp", "index", "heartRate", "rrMilliseconds", "gravity"])
    }
}

final class Gen5AckBoundaryChaosTests: XCTestCase {
    func testTenBoundariesNeverAckWithoutCommittedBatchAndDuplicatesConverge() throws {
        XCTAssertEqual(Gen5CommitBoundary.allCases.count, 10)
        for (model, boundary) in product(
            [BandModel.whoop5, .whoopMG],
            Gen5CommitBoundary.allCases.filter { $0 != .duplicateDelivery }
        ) {
            let (store, database, url) = try makeGen5CommitStore()
            defer {
                try? database.databasePool.close()
                try? FileManager.default.removeItem(at: url)
            }
            let request = try makeGen5CommitRequest(model: model)
            XCTAssertThrowsError(try store.commit(request, acknowledgementSequence: 1, injecting: boundary))
            let committed = try store.committedToken(burstID: request.burstID, model: model)
            if [.afterCommit, .acknowledgementTimeout, .sessionReplacement, .lateEnd, .radioLoss].contains(boundary) {
                XCTAssertEqual(committed, request.token)
            } else {
                XCTAssertNil(committed)
            }
        }

        for model in [BandModel.whoop5, .whoopMG] {
            let (store, database, url) = try makeGen5CommitStore()
            defer {
                try? database.databasePool.close()
                try? FileManager.default.removeItem(at: url)
            }
            let request = try makeGen5CommitRequest(model: model)
            let first = try store.commit(request, acknowledgementSequence: 3)
            let second = try store.commit(request, acknowledgementSequence: 3, injecting: .duplicateDelivery)
            XCTAssertEqual(first, second)
            XCTAssertEqual(try store.counts().batches, 1)
            XCTAssertEqual(try store.counts().archive, 1)
            XCTAssertEqual(try store.counts().canonical, 1)
        }
    }
}

private func product<A, B>(_ lhs: [A], _ rhs: [B]) -> [(A, B)] {
    lhs.flatMap { left in rhs.map { (left, $0) } }
}
