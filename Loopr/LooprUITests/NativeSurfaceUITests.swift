import XCTest

final class NativeSurfaceUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testWorkoutLiveActivityNativePresentations() {
        let app = launch(mode: "activeWorkout")
        XCTAssertTrue(app.buttons["active-workout-mini-player"].waitForExistence(timeout: 10))

        showHomeScreen()
        attachDisplay(named: "Native Workout Live Activity compact")
        expandDynamicIsland()
        attachDisplay(named: "Native Workout Live Activity expanded")
        showNotificationCenter()
        attachDisplay(named: "Native Workout Live Activity banner")
    }

    @MainActor
    func testBreathingLiveActivityNativePresentations() {
        let app = XCUIApplication()
        app.launchArguments = ["--loopr-launch-mode=populated"]
        app.launchEnvironment["LOOPR_LAUNCH_MODE"] = "populated"
        app.launchEnvironment["LOOPR_NATIVE_SURFACE_PROBE"] = "breathing"
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["main-tab-shell"].firstMatch.waitForExistence(timeout: 10))

        showHomeScreen()
        attachDisplay(named: "Native Breathing Live Activity compact")
        expandDynamicIsland()
        attachDisplay(named: "Native Breathing Live Activity expanded")
        showNotificationCenter()
        attachDisplay(named: "Native Breathing Live Activity banner")
    }

    @MainActor
    func testZZConcurrentLiveActivitiesRemainPresent() {
        let app = XCUIApplication()
        app.launchArguments = ["--loopr-launch-mode=activeWorkout"]
        app.launchEnvironment["LOOPR_LAUNCH_MODE"] = "activeWorkout"
        app.launchEnvironment["LOOPR_NATIVE_SURFACE_PROBE"] = "both"
        app.launch()
        XCTAssertTrue(app.buttons["active-workout-mini-player"].waitForExistence(timeout: 10))

        showHomeScreen()
        attachDisplay(named: "Native concurrent Live Activities present")
    }

    @MainActor
    func testWidgetGalleryCandidates() {
        let app = XCUIApplication()
        app.launchArguments = ["--loopr-launch-mode=populated"]
        app.launchEnvironment["LOOPR_LAUNCH_MODE"] = "populated"
        app.launchEnvironment["LOOPR_NATIVE_SURFACE_PROBE"] = "widget"
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["main-tab-shell"].firstMatch.waitForExistence(timeout: 10))

        showHomeScreen()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
            .press(forDuration: 1.2)

        let edit = springboard.buttons["Edit"]
        XCTAssertTrue(edit.waitForExistence(timeout: 3))
        edit.tap()

        let addWidget = springboard.buttons["Add Widget"]
        XCTAssertTrue(addWidget.waitForExistence(timeout: 3))
        addWidget.tap()

        let search = springboard.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        search.tap()
        search.typeText("Loopr")
        let loopr = springboard.cells["Loopr"].firstMatch
        XCTAssertTrue(loopr.waitForExistence(timeout: 3))
        loopr.tap()
        attachDisplay(named: "Native Loopr widget gallery page 1")
        swipeWidgetGalleryForward(in: springboard)
        attachDisplay(named: "Native Loopr widget gallery page 2")
        swipeWidgetGalleryForward(in: springboard)
        attachDisplay(named: "Native Loopr widget gallery page 3")
    }

    @MainActor
    func testDeterministicCandidatesForSystemHiddenFamilies() {
        let app = XCUIApplication()
        app.launchEnvironment["LOOPR_NATIVE_SURFACE_PROBE"] = "candidates"
        app.launch()
        XCTAssertTrue(
            app.descendants(matching: .any)["native-surface-candidate-root"]
                .firstMatch.waitForExistence(timeout: 10)
        )

        let candidates = [
            ("native-candidate-today-system-small", "Today system small"),
            ("native-candidate-today-system-medium", "Today system medium"),
            ("native-candidate-today-accessory-rectangular", "Today accessory rectangular"),
            ("native-candidate-today-accessory-inline", "Today accessory inline"),
            ("native-candidate-band-accessory-circular", "Band accessory circular"),
            ("native-candidate-band-system-small", "Band system small"),
            ("native-candidate-band-accessory-rectangular", "Band accessory rectangular"),
            ("native-candidate-band-accessory-inline", "Band accessory inline"),
            ("native-candidate-workout-minimal", "Workout Dynamic Island minimal"),
            ("native-candidate-breathing-minimal", "Breathing Dynamic Island minimal"),
        ]
        for (identifier, name) in candidates {
            let element = app.descendants(matching: .any)[identifier].firstMatch
            XCTAssertTrue(element.waitForExistence(timeout: 3), "Missing \(name)")
            bringIntoView(element, in: app)
            attach(element: element, named: name)
        }
    }

    @MainActor
    private func launch(mode: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--loopr-launch-mode=\(mode)"]
        app.launchEnvironment["LOOPR_LAUNCH_MODE"] = mode
        app.launch()
        return app
    }

    @MainActor
    private func expandDynamicIsland() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        springboard.activate()
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.035))
            .press(forDuration: 1.0)
    }

    @MainActor
    private func showNotificationCenter() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        springboard.activate()
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let start = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.005))
        let end = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
        start.press(forDuration: 0.1, thenDragTo: end)
        let allow = springboard.buttons["Allow"]
        if allow.waitForExistence(timeout: 2) {
            allow.tap()
        }
        let alwaysAllow = springboard.buttons["Always Allow"]
        if alwaysAllow.waitForExistence(timeout: 2) {
            alwaysAllow.tap()
        }
    }

    @MainActor
    private func showHomeScreen() {
        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        springboard.activate()
        XCTAssertTrue(springboard.icons["Loopr"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func swipeWidgetGalleryForward(in springboard: XCUIApplication) {
        let start = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.55))
        let end = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.55))
        start.press(forDuration: 0.1, thenDragTo: end)
    }

    private func attachDisplay(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func attach(element: XCUIElement, named name: String) {
        let attachment = XCTAttachment(screenshot: element.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func bringIntoView(_ element: XCUIElement, in app: XCUIApplication) {
        let viewport = app.frame.insetBy(dx: 0, dy: 20)
        for _ in 0..<8 {
            let frame = element.frame
            if frame.minY >= viewport.minY, frame.maxY <= viewport.maxY {
                return
            }
            app.swipeUp()
        }
        XCTFail("Candidate is outside the visible viewport: \(element.identifier)")
    }
}
