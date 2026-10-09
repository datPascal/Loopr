import XCTest
@testable import StorageKit

final class BacklogMemoryBudgetTests: XCTestCase {
    func testHundredThousandRowsUseAtMostOneBoundedWindow() throws {
        let records = Array(0..<100_000)
        var expected = 0
        let report = BoundedBacklogProcessor.process(records) { window in
            XCTAssertLessThanOrEqual(window.count, StoragePerformanceBudget.maximumBacklogWindowRecords)
            XCTAssertEqual(window.first, expected)
            expected += window.count
        }
        XCTAssertEqual(report.processedRecords, records.count)
        XCTAssertEqual(report.peakWindowRecords, StoragePerformanceBudget.maximumBacklogWindowRecords)
    }
}

final class BatchSizeBudgetTests: XCTestCase {
    func testCompatibleWindowsStayBoundedAndTokenBatchesNeverSplit() {
        let batches = (0..<20).map { AtomicTransactionBatch(boundaryID: "token-\($0)", recordCount: 100) }
        let windows = StorageBatchPlanner.plan(batches)
        XCTAssertTrue(windows.allSatisfy {
            $0.reduce(0) { $0 + $1.recordCount } <= StoragePerformanceBudget.maximumCompatibleTransactionRecords
        })
        XCTAssertEqual(windows.flatMap { $0 }.map(\.boundaryID), batches.map(\.boundaryID))

        let oversized = AtomicTransactionBatch(boundaryID: "one-indivisible-token", recordCount: 900)
        XCTAssertEqual(StorageBatchPlanner.plan([oversized]), [[oversized]])
    }
}
