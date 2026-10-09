import XCTest
@testable import BluetoothKit

final class Gen5StaleGenerationSuppressionTests: XCTestCase {
    func testOldGenerationCannotAuthorizeWriteCommitOrAck() async throws {
        let fence = Gen5GenerationFence(initialGeneration: 40)
        let generation = await fence.beginNewConnection()
        XCTAssertEqual(generation, 41)
        try await fence.authorize(41)
        for operation in ["write", "commit", "ack"] {
            do {
                try await fence.authorize(40)
                XCTFail("stale generation reached \(operation)")
            } catch {
                XCTAssertEqual(error as? Gen5GenerationFenceError, .stale(expected: 41, received: 40))
            }
        }
    }
}
