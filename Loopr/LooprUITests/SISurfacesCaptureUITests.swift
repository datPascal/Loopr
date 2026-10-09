import XCTest

final class SISurfacesCaptureUITests: XCTestCase {
    private var appearance: String { ProcessInfo.processInfo.environment["LOOPR_CAPTURE_APPEARANCE"] ?? "light" }
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testEstimatedStepLabels() {
        for (surface, arguments) in [
            ("today-step-label", [String]()),
            ("body-step-label", ["--loopr-deep-link=body/detail"]),
            ("goals-step-label", ["--loopr-deep-link=settings/goals"]),
            ("estimated-steps-page-empty", ["--loopr-deep-link=body/detail", "--loopr-open-metric=steps", "--loopr-si-surfaces-state=empty"])
        ] {
            let app = XCUIApplication()
            app.launchArguments = ["--loopr-launch-mode=populated", "--loopr-appearance=\(appearance)"] + arguments
            app.launch()
            if surface == "estimated-steps-page-empty" {
                let empty = app.descendants(matching: .any)["metric-detail-empty"].firstMatch
                XCTAssertTrue(empty.waitForExistence(timeout: 20))
                XCTAssertTrue(empty.isHittable)
            }
            let label = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Estimated steps")).firstMatch
            XCTAssertTrue(label.waitForExistence(timeout: 20))
            for _ in 0..<5 {
                if label.isHittable { break }
                app.swipeUp()
            }
            XCTAssertTrue(label.isHittable)
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = "\(appearance)-si-surfaces-\(surface)"
            attachment.lifetime = .keepAlways
            add(attachment)
            app.terminate()
        }
    }

    @MainActor
    func testHeartMetricPages() {
        for metric in ["heart_rate_dip", "sleeping_heart_rate", "max_heart_rate"] {
            for state in ["ready", "empty", "learning", "flagged"] {
                let app = XCUIApplication()
                app.launchArguments = ["--loopr-launch-mode=populated", "--loopr-appearance=\(appearance)",
                    "--loopr-deep-link=heart/detail", "--loopr-open-metric=\(metric)", "--loopr-si-surfaces-state=\(state)"]
                app.launch()
                let screen = app.descendants(matching: .any)["metric-detail-screen"].firstMatch
                XCTAssertTrue(screen.waitForExistence(timeout: 20), metric)
                XCTAssertTrue(app.tabBars.buttons["Heart"].firstMatch.isSelected)
                let loading = app.activityIndicators.firstMatch
                if loading.exists {
                    let finished = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: loading)
                    XCTAssertEqual(XCTWaiter.wait(for: [finished], timeout: 10), .completed)
                }
                let content = app.descendants(matching: .any)[state == "empty" ? "metric-detail-empty" : "metric-detail-value"].firstMatch
                XCTAssertTrue(content.waitForExistence(timeout: 10))
                let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                attachment.name = "\(appearance)-si-surfaces-\(metric)-\(state)"
                attachment.lifetime = .keepAlways
                add(attachment)
                app.terminate()
            }
        }
    }
}
