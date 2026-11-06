import XCTest
@testable import Loopr

@MainActor
final class PublishLaunchTests: XCTestCase {
    #if DEBUG
    func testTheStartAtArgumentOpensPublishOnTheDataTab() {
        let state = MainTabLaunchState.startingAt(["Loopr", "--loopr-start-at=publish"])
        XCTAssertEqual(state, .init(tab: .data, healthPath: [.publish]))
    }

    func testOtherArgumentsLeaveTheLaunchAlone() {
        XCTAssertNil(MainTabLaunchState.startingAt(["Loopr"]))
        XCTAssertEqual(MainTabLaunchState.startingAt(["Loopr", "--loopr-start-at=somewhere"]), .init(tab: .today))
    }
    #endif

    func testPublishIsADistinctHealthRoute() {
        XCTAssertNotEqual(AppHealthRoute.publish, .yourData)
        XCTAssertEqual(AppHealthRoute.publish, .publish)
    }
}
