import XCTest

/// Walks the redesigned onboarding in the fixture launch mode, where pairing
/// goes through the no-op coordinator and no system permission prompt can
/// appear. Every step is captured as a kept screenshot attachment.
final class OnboardingFlowUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testOnboardingWalksEveryStepToTheShellInDark() {
        walkFullFlow(appearance: "dark")
    }

    @MainActor
    func testOnboardingWalksEveryStepToTheShellInLight() {
        walkFullFlow(appearance: "light")
    }

    @MainActor
    func testBackReturnsToThePreviousStepAndKeepsTheProfile() {
        let app = launch(appearance: "dark")
        tap(app, "onboarding-continue")
        XCTAssertTrue(step(app, "whoopHandover").waitForExistence(timeout: 5))
        tap(app, "onboarding-handover-continue")
        XCTAssertTrue(step(app, "prepareBand").waitForExistence(timeout: 5))
        tap(app, "onboarding-back")
        XCTAssertTrue(step(app, "whoopHandover").waitForExistence(timeout: 5))
        tap(app, "onboarding-back")
        XCTAssertTrue(step(app, "welcomeDisclosures").waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["onboarding-back"].exists)

        tap(app, "onboarding-continue")
        tap(app, "onboarding-handover-continue")
        tap(app, "onboarding-prepare-later")
        XCTAssertTrue(element(app, "profile-setup-screen").waitForExistence(timeout: 5))
        type(app, "profile-age", "40")
        tap(app, "profile-save")
        XCTAssertTrue(step(app, "appleHealth").waitForExistence(timeout: 5))
        tap(app, "onboarding-back")
        XCTAssertTrue(element(app, "profile-setup-screen").waitForExistence(timeout: 5))
        let age = app.textFields["profile-age"]
        XCTAssertEqual(age.value as? String, "40")
        XCTAssertTrue(element(app, "profile-max-heart-rate").label.contains("180"))
    }

    @MainActor
    func testDataControlsStayReachableDuringOnboarding() {
        let app = launch(appearance: "dark")
        tap(app, "open-onboarding-data-controls")
        XCTAssertTrue(element(app, "onboarding-destructive-actions-screen").waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["onboarding-delete-all-data"].exists)
        tap(app, "onboarding-data-controls-done")
        XCTAssertTrue(step(app, "welcomeDisclosures").waitForExistence(timeout: 5))
    }

    @MainActor
    func testSkippingTheBandStepsEndsWithConnectLater() {
        let app = launch(appearance: "dark")
        tap(app, "onboarding-continue")
        XCTAssertTrue(step(app, "whoopHandover").waitForExistence(timeout: 5))
        tap(app, "onboarding-handover-later")
        XCTAssertTrue(element(app, "profile-setup-screen").waitForExistence(timeout: 5))
        tap(app, "profile-save")
        tap(app, "onboarding-health-skip")
        tap(app, "onboarding-notifications-skip")
        XCTAssertTrue(step(app, "sleepGoal").waitForExistence(timeout: 5))
        tap(app, "onboarding-sleep-goal-skip")
        XCTAssertTrue(step(app, "finish").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "onboarding-finish-later").waitForExistence(timeout: 5))
        tap(app, "onboarding-finish")
        XCTAssertTrue(element(app, "main-tab-shell").waitForExistence(timeout: 10))
    }

    @MainActor
    func testLargestAccessibilitySizeKeepsPrimaryActionsReachable() {
        let app = launch(
            appearance: "light",
            extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        )
        XCTAssertTrue(step(app, "welcomeDisclosures").waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["onboarding-continue"].isHittable)
        capture(app, "onboarding-ax5-welcome")
        tap(app, "onboarding-continue")

        XCTAssertTrue(step(app, "whoopHandover").waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["onboarding-handover-continue"].isHittable)
        capture(app, "onboarding-ax5-handover")
        tap(app, "onboarding-handover-continue")

        XCTAssertTrue(step(app, "prepareBand").waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["onboarding-prepare-continue"].isHittable)
        capture(app, "onboarding-ax5-prepare")
        tap(app, "onboarding-prepare-later")

        XCTAssertTrue(element(app, "profile-setup-screen").waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["profile-save"].isHittable)
        capture(app, "onboarding-ax5-profile")
        tap(app, "profile-save")

        XCTAssertTrue(step(app, "appleHealth").waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["onboarding-health-skip"].isHittable)
        capture(app, "onboarding-ax5-health")
        tap(app, "onboarding-health-skip")

        XCTAssertTrue(step(app, "notifications").waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["onboarding-notifications-skip"].isHittable)
        capture(app, "onboarding-ax5-notifications")
        tap(app, "onboarding-notifications-skip")

        XCTAssertTrue(step(app, "sleepGoal").waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["onboarding-sleep-goal-skip"].isHittable)
        capture(app, "onboarding-ax5-sleep-goal")
        tap(app, "onboarding-sleep-goal-skip")

        XCTAssertTrue(step(app, "finish").waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["onboarding-finish"].isHittable)
        capture(app, "onboarding-ax5-finish")
        tap(app, "onboarding-finish")

        XCTAssertTrue(element(app, "main-tab-shell").waitForExistence(timeout: 10))
        let connectBand = app.buttons["today-connect-band"]
        XCTAssertTrue(connectBand.isHittable)
        XCTAssertGreaterThan(connectBand.frame.width, 160)
        capture(app, "onboarding-ax5-tabs")
    }

    @MainActor
    func testPairingStatesCapture() {
        for appearance in ["dark", "light"] {
            for phase in ["choosing", "connecting", "connected", "failed", "bondRepair", "bluetoothOff"] {
                let app = launch(
                    appearance: appearance,
                    extra: ["--loopr-deep-link=onboarding/pairing", "--loopr-onboarding-pairing-phase=\(phase)"]
                )
                XCTAssertTrue(step(app, "pairing").waitForExistence(timeout: 10))
                let help = element(app, "onboarding-pairing-help")
                switch phase {
                case "choosing":
                    // While the sheet is up, help comes after a calm 12 seconds.
                    XCTAssertTrue(help.waitForExistence(timeout: 20))
                case "connecting":
                    // A chosen band is connecting: help about finding it never shows.
                    XCTAssertFalse(help.waitForExistence(timeout: 14))
                case "failed":
                    XCTAssertTrue(help.waitForExistence(timeout: 5))
                case "bondRepair":
                    XCTAssertTrue(element(app, "onboarding-pairing-bond-repair").waitForExistence(timeout: 5))
                    XCTAssertFalse(help.exists)
                default:
                    XCTAssertFalse(help.exists)
                }
                capture(app, "onboarding-\(appearance)-pairing-\(phase)")
                if phase != "connecting" && phase != "connected" {
                    scrollDown(app)
                    capture(app, "onboarding-\(appearance)-pairing-\(phase)-scrolled")
                }
                app.terminate()
            }
        }
    }

    @MainActor
    func testNoticesCapture() {
        for appearance in ["dark", "light"] {
            let hint = launch(
                appearance: appearance,
                extra: ["--loopr-deep-link=onboarding/pairing", "--loopr-onboarding-pairing-phase=connected",
                        "--loopr-onboarding-shared-link-hint"]
            )
            XCTAssertTrue(element(hint, "onboarding-pairing-shared-link").waitForExistence(timeout: 10))
            capture(hint, "onboarding-\(appearance)-pairing-shared-link-hint")
            hint.terminate()

            let refresh = launch(
                appearance: appearance,
                extra: ["--loopr-deep-link=onboarding/finish", "--loopr-onboarding-background-refresh-off"]
            )
            XCTAssertTrue(element(refresh, "onboarding-finish-background-refresh").waitForExistence(timeout: 10))
            XCTAssertTrue(refresh.buttons["onboarding-finish-open-settings"].exists)
            capture(refresh, "onboarding-\(appearance)-finish-background-refresh-off")
            refresh.terminate()
        }
    }

    // MARK: Walk

    @MainActor
    private func walkFullFlow(appearance: String) {
        let app = launch(appearance: appearance)
        var index = 1

        XCTAssertTrue(element(app, "onboarding-screen").waitForExistence(timeout: 10))
        XCTAssertTrue(step(app, "welcomeDisclosures").waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", "independent from WHOOP")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", "not a medical device")).firstMatch.exists)
        XCTAssertEqual(element(app, "onboarding-progress").label, "Step 1 of 9")
        capture(app, shot(appearance, &index, "welcome"))
        scrollDown(app)
        capture(app, shot(appearance, &index, "welcome-disclosures"))
        tap(app, "onboarding-continue")

        XCTAssertTrue(step(app, "whoopHandover").waitForExistence(timeout: 5))
        XCTAssertEqual(element(app, "onboarding-progress").label, "Step 2 of 9")
        XCTAssertTrue(app.buttons["onboarding-handover-open-settings"].exists)
        capture(app, shot(appearance, &index, "whoop-handover"))
        scrollDown(app)
        capture(app, shot(appearance, &index, "whoop-handover-steps"))
        tap(app, "onboarding-handover-continue")

        XCTAssertTrue(step(app, "prepareBand").waitForExistence(timeout: 5))
        XCTAssertEqual(element(app, "onboarding-progress").label, "Step 3 of 9")
        capture(app, shot(appearance, &index, "prepare"))
        scrollDown(app)
        capture(app, shot(appearance, &index, "prepare-steps"))
        tap(app, "onboarding-prepare-continue")

        XCTAssertTrue(step(app, "pairing").waitForExistence(timeout: 5))
        capture(app, shot(appearance, &index, "pairing"))
        tap(app, "onboarding-pair")
        XCTAssertTrue(app.buttons["onboarding-pair-next"].waitForExistence(timeout: 5))
        capture(app, shot(appearance, &index, "pairing-connected"))
        tap(app, "onboarding-pair-next")

        XCTAssertTrue(element(app, "profile-setup-screen").waitForExistence(timeout: 5))
        capture(app, shot(appearance, &index, "profile-empty"))
        type(app, "profile-age", "34")
        dismissKeyboard(app)
        tap(app, "profile-sex-female")
        XCTAssertTrue(element(app, "profile-setup-screen").exists)
        type(app, "profile-height", "172")
        type(app, "profile-weight", "64")
        dismissKeyboard(app)
        XCTAssertTrue(element(app, "profile-max-heart-rate").label.contains("184"))
        capture(app, shot(appearance, &index, "profile-filled"))
        tap(app, "profile-save")

        XCTAssertTrue(step(app, "appleHealth").waitForExistence(timeout: 5))
        // The step lists reads as well as saves: the sheet asks for both.
        XCTAssertTrue(element(app, "onboarding-health-writes").exists)
        XCTAssertTrue(element(app, "onboarding-health-reads").exists)
        capture(app, shot(appearance, &index, "health"))
        scrollDown(app)
        capture(app, shot(appearance, &index, "health-lists"))
        tap(app, "onboarding-health-skip")

        XCTAssertTrue(step(app, "notifications").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "onboarding-notifications-on").exists)
        capture(app, shot(appearance, &index, "notifications"))
        scrollDown(app)
        capture(app, shot(appearance, &index, "notifications-lists"))
        tap(app, "onboarding-notifications-skip")

        XCTAssertTrue(step(app, "sleepGoal").waitForExistence(timeout: 5))
        // The default sleep need is picked already, so Save works at once.
        XCTAssertTrue(app.buttons["onboarding-sleep-goal-save"].isEnabled)
        XCTAssertTrue(element(app, "onboarding-sleep-need-value").label.contains("8 hours"))
        tap(app, "onboarding-sleep-goal-7.5")
        XCTAssertTrue(element(app, "onboarding-sleep-need-value").label.contains("7.5 hours"))
        capture(app, shot(appearance, &index, "sleep-need"))
        tap(app, "onboarding-sleep-goal-save")

        XCTAssertTrue(step(app, "finish").waitForExistence(timeout: 5))
        XCTAssertEqual(element(app, "onboarding-progress").label, "Step 9 of 9")
        XCTAssertFalse(element(app, "onboarding-finish-later").exists)
        capture(app, shot(appearance, &index, "finish"))
        scrollDown(app)
        capture(app, shot(appearance, &index, "finish-next"))
        tap(app, "onboarding-finish")

        XCTAssertTrue(element(app, "main-tab-shell").waitForExistence(timeout: 10))
        XCTAssertFalse(element(app, "root-onboarding").exists)
    }

    // MARK: Helpers

    @MainActor
    private func launch(appearance: String, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--loopr-launch-mode=onboarding", "--loopr-appearance=\(appearance)"] + extra
        app.launch()
        // A fresh launch opens on the band intro; a deep link to a later
        // stage skips it. Get started appears once the film reveals its text.
        if !extra.contains(where: { $0.hasPrefix("--loopr-deep-link=") }) {
            let getStarted = app.buttons["band-intro-get-started"]
            XCTAssertTrue(getStarted.waitForExistence(timeout: 15), "Band intro did not offer Get started")
            getStarted.tap()
        }
        return app
    }

    @MainActor
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    @MainActor
    private func step(_ app: XCUIApplication, _ stage: String) -> XCUIElement {
        element(app, "onboarding-step-\(stage)")
    }

    @MainActor
    private func tap(_ app: XCUIApplication, _ identifier: String, file: StaticString = #filePath, line: UInt = #line) {
        let target = app.buttons[identifier].firstMatch
        XCTAssertTrue(target.waitForExistence(timeout: 5), "Missing \(identifier)", file: file, line: line)
        for _ in 0..<4 where !target.isHittable {
            app.swipeUp()
        }
        target.tap()
    }

    @MainActor
    private func type(_ app: XCUIApplication, _ identifier: String, _ text: String) {
        let field = app.textFields[identifier].firstMatch
        let profile = app.scrollViews["profile-setup-screen"].firstMatch
        for _ in 0..<6 where !field.exists {
            profile.swipeUp()
        }
        XCTAssertTrue(field.waitForExistence(timeout: 5), "Missing field \(identifier)")
        // The fixed Continue bar can cover a field that XCTest still calls hittable.
        for _ in 0..<6 where !field.isHittable || field.frame.midY > app.frame.height * 0.75 {
            profile.swipeUp()
        }
        field.tap()
        field.typeText(text)
    }

    @MainActor
    private func dismissKeyboard(_ app: XCUIApplication) {
        let done = app.toolbars.buttons["Done"].firstMatch
        if done.waitForExistence(timeout: 2) { done.tap() }
    }

    @MainActor
    private func scrollDown(_ app: XCUIApplication) {
        app.swipeUp()
    }

    private func shot(_ appearance: String, _ index: inout Int, _ name: String) -> String {
        defer { index += 1 }
        return String(format: "onboarding-%@-%02d-%@", appearance, index, name)
    }

    @MainActor
    private func capture(_ app: XCUIApplication, _ name: String) {
        // Let the step transition settle before the capture.
        _ = app.wait(for: .runningForeground, timeout: 1)
        Thread.sleep(forTimeInterval: 0.8)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
