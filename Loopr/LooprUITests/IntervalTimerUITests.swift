import XCTest

final class IntervalTimerUITests: XCTestCase {
    @MainActor
    func testWorkoutsOpensStartsAndStopsIntervalTimer() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--loopr-launch-mode=populated"]
        app.launch()
        let workouts = app.tabBars.buttons["Workouts"].firstMatch
        XCTAssertTrue(workouts.waitForExistence(timeout: 10))
        workouts.tap()
        let entry = app.buttons["workouts-interval-timer"].firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        entry.tap()
        let screen = app.descendants(matching: .any)["interval-timer-screen"].firstMatch
        XCTAssertTrue(screen.waitForExistence(timeout: 5))
        let start = app.buttons["interval-start"].firstMatch
        for _ in 0..<4 {
            if start.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(start.isHittable)
        start.tap()
        let stop = app.buttons["interval-stop"].firstMatch
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        let phase = app.staticTexts["interval-phase"].firstMatch
        if !phase.isHittable { app.swipeDown() }
        XCTAssertTrue(phase.waitForExistence(timeout: 5))
        XCTAssertEqual(phase.label, "Work")
        XCTAssertTrue(app.descendants(matching: .any)["interval-countdown"].firstMatch.exists)
        for _ in 0..<4 {
            if stop.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(stop.isHittable)
        stop.tap()
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        XCTAssertFalse(phase.exists)
    }
}
