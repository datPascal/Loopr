import XCTest

final class IntervalTimerUITests: XCTestCase {
    @MainActor
    func testWorkoutsOpensStartsAndStopsIntervalTimer() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--loopr-launch-mode=populated"]
        app.launch()
        let workouts = app.tabBars.buttons["Fitness"].firstMatch
        XCTAssertTrue(workouts.waitForExistence(timeout: 10))
        workouts.tap()
        // The interval timer lives in the start sheet, under CrossFit.
        let more = app.descendants(matching: .any)["train-rail-more"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 5))
        for _ in 0..<4 where !more.isHittable { app.swipeUp() }
        more.tap()
        let entry = app.buttons["train-start-intervals"].firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        for _ in 0..<4 where !entry.isHittable { app.swipeUp() }
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
