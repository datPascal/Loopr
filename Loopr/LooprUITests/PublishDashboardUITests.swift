import XCTest

/// LV-08b step 4: Publish a page opens from a launch argument, lists the metrics that have stored data, and builds
/// a preview with its size and a save control once two metrics are picked.
final class PublishDashboardUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor func testPickingTwoMetricsShowsThePreviewAndTheSaveControl() {
        let app = launch()
        XCTAssertTrue(element(app, "publish-screen").waitForExistence(timeout: 20))
        XCTAssertTrue(element(app, "publish-period").exists)
        XCTAssertTrue(element(app, "publish-include-labs").exists)
        XCTAssertFalse(element(app, "publish-preview").exists, "nothing is picked by default, so there is no preview")

        tapMetric(app, "publish-metric-rmssd")
        tapMetric(app, "publish-metric-resting_heart_rate")

        XCTAssertTrue(scrollTo(app, "publish-preview"), "the preview did not appear")
        XCTAssertTrue(scrollTo(app, "publish-size"), "the file size did not appear")
        XCTAssertTrue(element(app, "publish-size").label.contains("HTML"))
        XCTAssertTrue(app.staticTexts["Only the metrics you picked are in this file. Nothing is uploaded."].exists)
        XCTAssertTrue(scrollTo(app, "publish-save"), "the save control did not appear")
        XCTAssertTrue(app.buttons["publish-save"].firstMatch.isEnabled)
        let web = element(app, "publish-preview-web")
        XCTAssertTrue(web.exists || app.webViews.firstMatch.exists, "the web preview is missing")
    }

    @MainActor func testAMetricWithNoDataCannotBePicked() {
        let app = launch()
        XCTAssertTrue(element(app, "publish-screen").waitForExistence(timeout: 20))
        // The fixture history has no max heart rate, so the row is listed as absent.
        let absent = element(app, "publish-metric-max_heart_rate")
        XCTAssertTrue(scrollTo(app, "publish-metric-max_heart_rate"))
        XCTAssertFalse(absent.isEnabled)
        absent.tap()
        XCTAssertFalse(element(app, "publish-preview").exists)
    }

    @MainActor private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--loopr-launch-mode=populated", "--loopr-metric-history-fixture",
            "--loopr-start-at=publish", "--loopr-appearance=system", "-AppleLanguages", "(en)", "-AppleLocale", "en_AU"]
        app.launch()
        XCTAssertTrue(element(app, "main-tab-shell").waitForExistence(timeout: 30))
        return app
    }

    @MainActor private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    /// Scrolls down, then back up, until the element is on screen.
    @MainActor private func scrollTo(_ app: XCUIApplication, _ id: String) -> Bool {
        for direction in [true, false] {
            for _ in 0..<12 {
                let target = element(app, id)
                if target.exists, target.isHittable { return true }
                if direction { app.swipeUp() } else { app.swipeDown() }
            }
        }
        return element(app, id).exists
    }

    @MainActor private func tapMetric(_ app: XCUIApplication, _ id: String) {
        XCTAssertTrue(scrollTo(app, id), "Could not reach \(id)")
        element(app, id).tap()
    }
}
