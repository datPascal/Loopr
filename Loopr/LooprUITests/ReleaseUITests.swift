import XCTest

private func releaseLaunch(_ mode: String) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["--loopr-launch-mode=\(mode)"]
    app.launchEnvironment["LOOPR_LAUNCH_MODE"] = mode
    app.launch()
    return app
}

private func textContaining(_ value: String, in app: XCUIApplication) -> XCUIElement {
    app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", value)).firstMatch
}

private func scrollToAndTap(_ identifier: String, in app: XCUIApplication) {
    let element = app.descendants(matching: .any)[identifier].firstMatch
    for _ in 0..<10 {
        if element.waitForExistence(timeout: 0.3), element.isHittable {
            element.tap()
            return
        }
        app.swipeUp()
    }
    XCTFail("Could not reach \(identifier)")
}

private func assertAccessibleLabel(prefix: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
    for _ in 0..<12 {
        let element = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH[c] %@", prefix)).firstMatch
        if element.waitForExistence(timeout: 0.3) { return }
        app.swipeUp()
    }
    XCTFail("Missing accessible graphic summary beginning with \(prefix)", file: file, line: line)
}

final class LegalDisclosureUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testOnboardingAndSettingsExposeNonAffiliationAndNonMedicalCopy() {
        let onboarding = releaseLaunch("onboarding")
        // A new user sees the band intro first. Its button becomes reachable
        // once the text is revealed.
        let getStarted = onboarding.buttons["band-intro-get-started"]
        XCTAssertTrue(getStarted.waitForExistence(timeout: 15))
        getStarted.tap()
        // The production repository and migration graph initialize before the
        // first presentable onboarding stage appears.
        XCTAssertTrue(onboarding.buttons["onboarding-continue"].waitForExistence(timeout: 15))
        XCTAssertTrue(textContaining("independent from WHOOP", in: onboarding).waitForExistence(timeout: 15))
        XCTAssertTrue(textContaining("not a medical device", in: onboarding).waitForExistence(timeout: 15))
        onboarding.terminate()

        let app = releaseLaunch("populated")
        app.buttons["open-settings"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["settings-modal"].firstMatch.waitForExistence(timeout: 15))
        scrollToAndTap("settings-legal-and-licenses", in: app)
        XCTAssertTrue(textContaining("not affiliated", in: app).waitForExistence(timeout: 15))
        XCTAssertTrue(textContaining("does not provide medical advice", in: app).waitForExistence(timeout: 15))
    }
}

final class DeletionFlowUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testHealthKitPersistenceDisclosureAndSeparateRemovalControlExist() {
        let app = releaseLaunch("populated")
        app.buttons["open-settings"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["settings-modal"].firstMatch.waitForExistence(timeout: 5))
        scrollToAndTap("settings-data-history", in: app)
        XCTAssertTrue(app.descendants(matching: .any)["data-screen"].firstMatch.waitForExistence(timeout: 5))
        scrollToAndTap("data-deletion", in: app)
        XCTAssertTrue(textContaining("does not delete Loopr's local records", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["data-delete-healthkit-samples"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["data-delete-all"].waitForExistence(timeout: 5))
    }
}

final class LaunchPerformanceTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testFixtureLaunchPerformanceBudget() {
        let app = XCUIApplication()
        app.launchArguments = ["--loopr-launch-mode=populated"]
        app.launchEnvironment["LOOPR_LAUNCH_MODE"] = "populated"
        measure(metrics: [XCTApplicationLaunchMetric(waitUntilResponsive: true)]) {
            app.launch()
            XCTAssertTrue(app.descendants(matching: .any)["main-tab-shell"].firstMatch.waitForExistence(timeout: 5))
            app.terminate()
        }
    }
}

final class LiveHRUpdateBudgetTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    /// The package-level budget test drives 1,000 packets through the real
    /// throttler. This UI boundary test proves the projection remains a
    /// single accessible live card instead of materializing packet rows.
    @MainActor
    func testLiveHeartProjectionIsOneBoundedAccessibleRegion() {
        let app = releaseLaunch("populated")
        app.tabBars.buttons["Heart"].tap()
        let card = app.descendants(matching: .any)["heart-live-card"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "heart-live-packet-")).count, 1)
    }
}

final class AccessibilityMatrixTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testCustomGraphicSummariesAtAccessibilityTextSizeAndRTL() {
        let configurations: [(String, String)] = [
            ("UICTContentSizeCategoryAccessibilityXXXL", "en"),
            ("UICTContentSizeCategoryAccessibilityXXXL", "ar")
        ]
        for (size, language) in configurations {
            let app = XCUIApplication()
            app.launchArguments = [
                "--loopr-launch-mode=populated",
                "--loopr-open-design-system",
                "-AppleLanguages",
                "(\(language))"
            ]
            app.launchEnvironment["LOOPR_LAUNCH_MODE"] = "populated"
            app.launchEnvironment["UICTContentSizeCategory"] = size
            app.launchEnvironment["UIAccessibilityReduceMotionEnabled"] = "YES"
            app.launchEnvironment["UIAccessibilityDarkerSystemColorsEnabled"] = "YES"
            app.launch()
            XCTAssertTrue(app.descendants(matching: .any)["main-tab-shell"].firstMatch.waitForExistence(timeout: 5))
            XCTAssertEqual(app.tabBars.buttons.count, 5)
            XCTAssertTrue(app.descendants(matching: .any)["design-system-gallery"].firstMatch.waitForExistence(timeout: 5))
            for prefix in [
                "Score 82 percent", "Seven-day HRV", "awake, 12 minutes",
                "Recovery, 9 minutes", "W1, 68", "Route, 5.2 kilometers"
            ] {
                assertAccessibleLabel(prefix: prefix, in: app)
            }
            app.terminate()
        }
    }
}

final class NavigationMatrixTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testEveryTabAndActiveWorkoutModalPreserveNavigationState() {
        let app = releaseLaunch("activeWorkout")
        let roots = [
            ("Today", "today-screen"),
            ("Sleep", "sleep-screen"),
            ("Heart", "heart-screen"),
            ("Body", "body-screen"),
            ("Workouts", "workouts-screen")
        ]
        for (tab, root) in roots {
            app.tabBars.buttons[tab].tap()
            XCTAssertTrue(app.descendants(matching: .any)[root].firstMatch.waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["active-workout-mini-player"].waitForExistence(timeout: 5))
        }
        app.buttons["active-workout-mini-player"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["active-workout-modal"].firstMatch.waitForExistence(timeout: 5))
    }

    @MainActor
    func testSettingsModalDismissesBackToSelectedTab() {
        let app = releaseLaunch("populated")
        XCTAssertTrue(app.descendants(matching: .any)["today-screen"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["open-settings"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["settings-modal"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(app.tabBars.buttons["Today"].isSelected)
        XCTAssertTrue(app.descendants(matching: .any)["today-screen"].firstMatch.waitForExistence(timeout: 5))
    }
}
