import XCTest

/// The coach entry point on Today and the settings screens behind it.
final class CoachEntryUITests: XCTestCase {
    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--loopr-launch-mode=populated", "--loopr-coach-fixture"] + extra
        app.launch()
        return app
    }

    private func any(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    func testHeaderButtonOpensCoachFromTheTopOfToday() {
        continueAfterFailure = false
        let app = launch()
        let button = app.buttons["today-header-coach"]
        XCTAssertTrue(button.waitForExistence(timeout: 15))
        XCTAssertEqual(button.label, "Ask about Today", "every tab names its Ask button after the screen (FT-05.1)")
        XCTAssertTrue(button.isHittable)
        button.tap()
        XCTAssertTrue(any(app, "coach-screen").waitForExistence(timeout: 10))
    }

    @MainActor
    func testHeaderButtonStaysReachableAfterScrollingDeepIntoToday() {
        continueAfterFailure = false
        let app = launch()
        XCTAssertTrue(any(app, "today-screen").waitForExistence(timeout: 15))
        for _ in 0..<4 { app.swipeUp() }
        let button = app.buttons["today-header-coach"]
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        XCTAssertTrue(button.isHittable)
        button.tap()
        XCTAssertTrue(any(app, "coach-screen").waitForExistence(timeout: 10))
    }

    @MainActor
    func testProviderSettingsDisableSaveUntilAKeyIsEntered() {
        continueAfterFailure = false
        let app = launch()
        app.buttons["today-header-coach"].tap()
        XCTAssertTrue(app.buttons["ask-history"].waitForExistence(timeout: 10))
        app.buttons["ask-history"].tap()
        app.buttons["ask-history-providers"].tap()
        let claude = app.buttons["Claude"]
        XCTAssertTrue(claude.waitForExistence(timeout: 5))
        claude.tap()
        let save = app.buttons["settings-ai-save-provider"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertFalse(save.isEnabled, "Save must wait for a key")
        XCTAssertFalse(app.buttons["coach-check-key"].isEnabled)
        let field = app.secureTextFields["settings-ai-api-key"]
        field.tap()
        field.typeText("fixture-claude-key")
        XCTAssertTrue(save.isEnabled)
        capture("providers-key-entered")
        save.tap()
        // Ask closes the sheet after a save and shows the new provider in its chip.
        let chip = any(app, "ask-provider")
        XCTAssertTrue(chip.waitForExistence(timeout: 8))
        XCTAssertTrue(chip.label.contains("Claude"), chip.label)
        capture("providers-saved")
    }

    @MainActor
    func testPreferencesShowCounterAndSaveState() {
        continueAfterFailure = false
        let app = launch()
        app.buttons["today-header-coach"].tap()
        XCTAssertTrue(app.buttons["ask-history"].waitForExistence(timeout: 10))
        app.buttons["ask-history"].tap()
        app.buttons["ask-history-preferences"].tap()
        let save = app.buttons["coach-instructions-save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertFalse(save.isEnabled, "Nothing to save yet")
        let editor = any(app, "coach-instructions")
        editor.tap()
        editor.typeText("Keep answers short.")
        XCTAssertTrue(save.isEnabled)
        save.tap()
        XCTAssertTrue(app.staticTexts["Saved for new chats"].waitForExistence(timeout: 5))
    }

    /// Writes screenshots to a folder the reviewer can open, and attaches
    /// them to the result bundle.
    @MainActor
    func testCaptureEntryAndSettingsScreens() throws {
        let variants: [(String, [String])] = [
            ("light", []),
            ("dark", ["-AppleInterfaceStyle", "Dark"]),
            ("ax", ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"])
        ]
        for (name, arguments) in variants {
            let app = launch(arguments)
            XCTAssertTrue(app.buttons["today-header-coach"].waitForExistence(timeout: 15))
            capture("today-top-\(name)")
            if name == "ax" { app.terminate(); continue }
            app.buttons["today-header-coach"].tap()
            XCTAssertTrue(app.buttons["ask-history"].waitForExistence(timeout: 10))
            app.buttons["ask-history"].tap()
            app.buttons["ask-history-providers"].tap()
            XCTAssertTrue(app.secureTextFields["settings-ai-api-key"].waitForExistence(timeout: 5))
            capture("providers-\(name)")
            app.swipeUp()
            capture("providers-\(name)-scrolled")
            app.buttons["ask-sheet-done"].tap()
            app.buttons["ask-history"].tap()
            app.buttons["ask-history-preferences"].tap()
            XCTAssertTrue(app.buttons["coach-instructions-save"].waitForExistence(timeout: 5))
            capture("preferences-\(name)")
            app.swipeUp()
            capture("preferences-\(name)-scrolled")
            app.terminate()
        }
    }

    @MainActor private func capture(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        let folder = "/tmp/coach-polish/shots/laneB"
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: "\(folder)/\(name).png"))
    }
}
