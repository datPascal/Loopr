import Foundation
import XCTest

final class SIBodyCaptureUITests: XCTestCase {
    private var appearance: String { ProcessInfo.processInfo.environment["LOOPR_CAPTURE_APPEARANCE"] ?? "light" }
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor func testBodyReady() { captureBody(mode: "ready") }
    @MainActor func testBodyLearning() { captureBody(mode: "learning") }
    @MainActor func testBodyFlagged() { captureBody(mode: "flagged") }
    @MainActor func testBodyEmpty() { captureBody(mode: "empty") }

    @MainActor private func captureBody(mode: String) {
        let app = launch(mode: mode, link: "body/detail")
        XCTAssertTrue(element(app, "body-screen").waitForExistence(timeout: 20))
        XCTAssertTrue(element(app, "body-strain-lens").waitForExistence(timeout: 10))
        capture("\(mode)-strain-target")
        reveal(app, element(app, "body-strain-week"))
        capture("\(mode)-strain-recovery")
        reveal(app, element(app, "body-training-load"))
        capture("\(mode)-training-load")
        reveal(app, element(app, "body-cardio-fitness"))
        capture("\(mode)-cardio-fitness-empty")
    }
    @MainActor func testLoadDetailAndStrainDetail() {
        let app = launch(mode: "flagged", link: "body/detail")
        let back = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 20))
        back.tap()
        let bodyTab = app.tabBars.buttons["Body"]
        XCTAssertTrue(bodyTab.waitForExistence(timeout: 10))
        bodyTab.tap()
        let load = element(app, "body-training-load")
        reveal(app, load)
        load.tap()
        XCTAssertTrue(element(app, "body-load-screen").waitForExistence(timeout: 10))
        capture("flagged-load-detail")
        reveal(app, element(app, "body-load-form"))
        capture("flagged-load-numbers")
    }
    @MainActor func testStrainDetail() {
        let app = XCUIApplication()
        app.launchArguments = ["--loopr-launch-mode=populated", "--loopr-appearance=\(appearance)",
            "--loopr-si-body-fixture=flagged", "--loopr-open-metric=strain", "--loopr-metric-history-fixture"]
        app.launch()
        XCTAssertTrue(element(app, "metric-detail-strain-target").waitForExistence(timeout: 20))
        capture("flagged-strain-detail")
    }
    @MainActor func testWorkoutRecoveryReady() { captureWorkout(mode: "ready") }
    @MainActor func testWorkoutRecoveryLearning() { captureWorkout(mode: "learning") }
    @MainActor func testWorkoutRecoveryEmpty() { captureWorkout(mode: "empty") }
    @MainActor private func captureWorkout(mode: String) {
        let app = launch(mode: mode, link: "workouts/detail")
        XCTAssertTrue(element(app, "workout-detail-screen").waitForExistence(timeout: 20))
        let card = element(app, "workout-heart-rate-recovery")
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        reveal(app, card)
        capture("\(mode)-workout-recovery")
    }
    @MainActor private func launch(mode: String, link: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--loopr-launch-mode=populated", "--loopr-appearance=\(appearance)",
                               "--loopr-si-body-fixture=\(mode)", "--loopr-deep-link=\(link)"]
        app.launch()
        return app
    }
    @MainActor private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }
    @MainActor private func reveal(_ app: XCUIApplication, _ target: XCUIElement) {
        XCTAssertTrue(target.waitForExistence(timeout: 10))
        let window = app.windows.firstMatch
        let bottom = app.tabBars.firstMatch.exists ? app.tabBars.firstMatch.frame.minY : window.frame.maxY - 34
        for _ in 0..<12 {
            let frame = target.frame
            if frame.minY >= 110 && frame.maxY <= bottom - 8 { break }
            let dy = frame.maxY > bottom - 8 ? -min(frame.maxY - bottom + 50, window.frame.height * 0.45)
                : min(150 - frame.minY, window.frame.height * 0.45)
            let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: dy)),
                        withVelocity: .slow, thenHoldForDuration: 0.3)
        }
        XCTAssertTrue(target.isHittable)
    }
    @MainActor private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "\(appearance)-si-body-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
