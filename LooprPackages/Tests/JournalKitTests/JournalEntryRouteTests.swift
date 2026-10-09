import Foundation
import JournalKit
import XCTest

/// Every entry row used to route to `.history`, so tapping one entry landed on
/// the list of all of them.
final class JournalEntryRouteTests: XCTestCase {
    func testEntryRouteCarriesTheIdentityThatWasTapped() {
        let first = UUID(uuidString: "00000000-0000-0000-0000-0000000000a1")!
        let second = UUID(uuidString: "00000000-0000-0000-0000-0000000000a2")!
        XCTAssertNotEqual(JournalRoute.entry(first), JournalRoute.entry(second))
        XCTAssertEqual(JournalRoute.entry(first), JournalRoute.entry(first))
        XCTAssertNotEqual(JournalRoute.entry(first), JournalRoute.history)
    }

    func testFixturesCoverTheEntryRoute() {
        let hasEntryRoute = JournalRoute.fixtures.contains {
            if case .entry = $0 { return true }
            return false
        }
        XCTAssertTrue(hasEntryRoute)
    }
}
