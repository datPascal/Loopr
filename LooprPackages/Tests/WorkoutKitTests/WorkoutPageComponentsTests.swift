import XCTest
@testable import WorkoutKit

final class WorkoutPageComponentsTests: XCTestCase {
    func testDurationUsesTimeUnits() {
        XCTAssertEqual(WorkoutDurationText.formatted(1_800), "30 min")
        XCTAssertEqual(WorkoutDurationText.formatted(5_400), "1 h 30 m")
        XCTAssertNil(WorkoutDurationText.formatted(nil))
    }
}
