import XCTest
@testable import AnalyticsKit

final class CancellationBudgetTests: XCTestCase {
    func testLargeDerivationCancelsBeforePublishingAndDoesNotRequireMainActor() async {
        let task = Task.detached {
            try await CancellableAnalytics.rrQuality(Array(repeating: 1_000.0, count: 100_000))
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("cancelled derivation must not publish")
        } catch is CancellationError {
            XCTAssertTrue(task.isCancelled)
        } catch {
            XCTFail("unexpected cancellation error: \(error)")
        }
    }
}
