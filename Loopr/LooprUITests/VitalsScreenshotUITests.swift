import XCTest

/// Captures beat-to-beat and Cardio Age after the archived vitals cards were removed
/// against a real history database.
///
/// It only runs when `LOOPR_VITALS_SHOTS` names an output directory: the
/// harness installs the app, copies a history snapshot into its container,
/// and then runs this test against the production composition.
final class VitalsScreenshotUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = true }

    private var outputDirectory: URL? {
        ProcessInfo.processInfo.environment["LOOPR_VITALS_SHOTS"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    private func capture(_ name: String, in app: XCUIApplication) {
        let shot = app.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let directory = outputDirectory {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? shot.pngRepresentation.write(to: directory.appendingPathComponent("\(name).png"))
        }
    }

    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    @discardableResult
    private func scroll(to identifier: String, in app: XCUIApplication, attempts: Int = 12) -> Bool {
        let target = element(identifier, in: app)
        for _ in 0..<attempts {
            if target.exists, target.isHittable { return true }
            app.swipeUp()
        }
        return target.exists
    }

    private func type(_ text: String, intoFieldLabelled label: String, in app: XCUIApplication) {
        let field = app.textFields.matching(NSPredicate(format: "label CONTAINS[c] %@ OR identifier CONTAINS[c] %@ OR placeholderValue CONTAINS[c] %@", label, label, label)).firstMatch
        if field.waitForExistence(timeout: 3) {
            field.tap()
            field.typeText(text)
        }
    }

    @MainActor
    func testCaptureVitalsOnRealData() throws {
        try XCTSkipIf(outputDirectory == nil, "Set LOOPR_VITALS_SHOTS to capture vitals screenshots")
        let app = XCUIApplication()
        app.launch()

        if app.buttons["onboarding-continue"].waitForExistence(timeout: 30) {
            app.buttons["onboarding-continue"].tap()
            // The first band step after welcome is the WHOOP app step; its
            // "later" skips every band step at once.
            if app.buttons["onboarding-handover-later"].waitForExistence(timeout: 15) {
                app.buttons["onboarding-handover-later"].tap()
            }
            type("Alex", intoFieldLabelled: "Display name", in: app)
            type("1993", intoFieldLabelled: "Birth year", in: app)
            let sexToggle = app.switches.matching(NSPredicate(format: "label CONTAINS[c] %@", "biological sex")).firstMatch
            if sexToggle.waitForExistence(timeout: 3) { sexToggle.tap() }
            capture("vitals-00-profile", in: app)
            if scroll(to: "profile-save", in: app) { element("profile-save", in: app).tap() }
        }

        XCTAssertTrue(element("main-tab-shell", in: app).waitForExistence(timeout: 60))
        app.tabBars.buttons["Heart"].tap()
        // A Debug derivation of the real days takes a while on first open.
        XCTAssertTrue(element("heart-advanced-disclosure", in: app).waitForExistence(timeout: 240))
        capture("vitals-01-heart-top", in: app)
        XCTAssertTrue(element("heart-vitals-section", in: app).exists)
        XCTAssertFalse(element("heart-vital-blood-oxygen", in: app).exists)
        // The Heart navigation lane owns its vitals cards. The temperature
        // detail route is available independently of that layout.
        app.terminate()
        app.launchArguments = ["--loopr-launch-mode=populated", "--loopr-metric-history-fixture", "--loopr-open-metric=skin_temperature_deviation", "--loopr-si-vitals-fixture=normal"]
        app.launch()
        XCTAssertTrue(element("metric-detail-temperature-approximate", in: app).waitForExistence(timeout: 30))
        capture("vitals-01-temperature-detail", in: app)
        app.terminate()
        app.launchArguments = []
        app.launch()
        app.tabBars.buttons["Heart"].tap()
        scroll(to: "heart-advanced-disclosure", in: app)
        capture("vitals-02-heart-details", in: app)

        if scroll(to: "heart-advanced-disclosure", in: app) {
            element("heart-advanced-disclosure", in: app).tap()
            XCTAssertTrue(element("heart-advanced-section", in: app).waitForExistence(timeout: 30))
            scroll(to: "heart-beat-to-beat-section", in: app)
            XCTAssertTrue(element("heart-vitals-section", in: app).exists)
            capture("vitals-03-detail-beat-to-beat", in: app)
            scroll(to: "heart-beat-poincare", in: app)
            capture("vitals-04-detail-poincare", in: app)
            scroll(to: "heart-beat-tachogram", in: app)
            capture("vitals-05-detail-tachogram", in: app)
        }

        app.tabBars.buttons["Body"].tap()
        let age = element("body-cardio-age", in: app)
        scroll(to: "body-cardio-age", in: app)
        XCTAssertTrue(age.waitForExistence(timeout: 5))
        capture("vitals-06-body-cardio-age", in: app)
    }
}
