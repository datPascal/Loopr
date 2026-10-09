import Foundation
import XCTest

final class LooprScreenshotCaptureUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testCaptureRound1Dark() {
        captureRound1(appearance: "dark")
    }

    @MainActor
    func testCaptureRound1Light() {
        captureRound1(appearance: "light")
    }

    @MainActor
    func testCaptureHabitFlowLight() {
        captureHabitFlow(appearance: "light")
    }

    @MainActor
    func testCaptureHabitFlowDark() {
        captureHabitFlow(appearance: "dark")
    }

    @MainActor
    func testCaptureHabitInsightStatesLight() {
        for state in [
            "collecting", "earlySignal", "enoughData", "clearAssociation",
            "noClearAssociation", "cannotSeparate", "stale", "unavailable"
        ] {
            let app = launchHabit(
                link: "journal/habit-insights",
                state: state,
                appearance: "light"
            )
            waitForSettledScreen(app, root: "habit-insights-screen")
            capture(app, name: "habit-insights-\(state)-light")
            app.terminate()
        }
    }

    @MainActor
    private func captureRound1(appearance: String) {
        let app = launch(mode: "populated", appearance: appearance)
        XCTAssertTrue(element(app, "main-tab-shell").waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, "today-screen").waitForExistence(timeout: 10))

        let screens = [
            (tab: "Today", root: "today-screen", name: "today-\(appearance)"),
            (tab: "Sleep", root: "sleep-screen", name: "sleep-\(appearance)"),
            (tab: "Heart", root: "heart-screen", name: "heart-\(appearance)"),
            (tab: "Body", root: "body-screen", name: "body-\(appearance)"),
            (tab: "Workouts", root: "workouts-screen", name: "workouts-\(appearance)")
        ]

        // Settings goes last on purpose. Opening it applies the stored
        // appearance override, which would repaint any tab captured after it.
        captureTabs(app, screens: screens)
        selectTab(app, "Today", root: "today-screen")
        openSettings(app)
        waitForSettledScreen(app, root: "settings-modal")
        capture(app, name: "settings-\(appearance)")
        dismissSettings(app)
    }

    @MainActor
    private func captureHabitFlow(appearance: String) {
        let destinations = [
            ("journal/habit-setup", "habit-setup-screen", "habit-setup"),
            ("journal/habit-management", "habit-management-screen", "habit-management"),
            ("journal/habit-check-in", "habit-check-in-screen", "habit-check-in"),
            ("journal/habit-history", "habit-history-screen", "habit-history"),
            ("journal/habit-insights", "habit-insights-screen", "habit-insights"),
            ("journal/habit-detail", "habit-detail-screen", "habit-detail")
        ]

        for (link, root, name) in destinations {
            let app = launchHabit(
                link: link,
                state: "clearAssociation",
                appearance: appearance
            )
            waitForSettledScreen(app, root: root)
            capture(app, name: "\(name)-\(appearance)")
            app.terminate()
        }
    }

    @MainActor
    private func captureTabs(
        _ app: XCUIApplication,
        screens: [(tab: String, root: String, name: String)]
    ) {
        for screen in screens {
            selectTab(app, screen.tab, root: screen.root)
            waitForSettledScreen(app, root: screen.root)
            scrollToTop(app, root: screen.root)
            waitForSettledScreen(app, root: screen.root)
            capture(app, name: screen.name)
        }
    }

    @MainActor
    private func launch(mode: String, appearance: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--loopr-launch-mode=\(mode)",
            "-AppleInterfaceStyle",
            appearance.capitalized
        ]
        app.launch()
        return app
    }

    @MainActor
    private func launchHabit(link: String, state: String, appearance: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--loopr-launch-mode=populated",
            "--loopr-deep-link=\(link)",
            "--loopr-habit-insight-state=\(state)",
            "-AppleInterfaceStyle",
            appearance.capitalized
        ]
        app.launch()
        return app
    }

    @MainActor
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    @MainActor
    private func openSettings(_ app: XCUIApplication) {
        XCTAssertTrue(element(app, "today-screen").waitForExistence(timeout: 10))
        let settingsButton = app.buttons["open-settings"].firstMatch
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 5))
        tapWhenHittable(settingsButton, in: app)
        XCTAssertTrue(element(app, "settings-modal").waitForExistence(timeout: 10))
    }

    @MainActor
    private func selectTab(_ app: XCUIApplication, _ tab: String, root identifier: String) {
        for _ in 0..<6 {
            let tabBar = app.tabBars.firstMatch
            let tabButton = tabBar.buttons[tab].firstMatch
            if tabBar.waitForExistence(timeout: 2),
               tabButton.waitForExistence(timeout: 2),
               tabButton.isHittable {
                tabButton.tap()
                if tabButton.waitForExistence(timeout: 2),
                   tabButton.isSelected,
                   element(app, identifier).waitForExistence(timeout: 5) {
                    return
                }
            }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.25))
        }

        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "screenshot-tab-selection-failed-\(tab)-\(identifier)"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        XCTFail("Could not select \(tab) and reach \(identifier)")
    }

    @MainActor
    private func waitForSettledScreen(_ app: XCUIApplication, root identifier: String) {
        let root = element(app, identifier)
        XCTAssertTrue(root.waitForExistence(timeout: 10), "Missing \(identifier)")

        let deadline = Date(timeIntervalSinceNow: 10)
        repeat {
            let rootHasActivity = !root.activityIndicators.allElementsBoundByIndex.isEmpty
            let settingsRootIsLoading = identifier == "settings-modal" && element(app, "settings-loading").exists
            if rootHasActivity || settingsRootIsLoading {
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.25))
                continue
            }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.75))
            return
        } while Date() < deadline

        XCTFail("\(identifier) did not settle with accessible content")
    }

    @MainActor
    private func scrollToTop(_ app: XCUIApplication, root identifier: String) {
        let screen = element(app, identifier)
        let scrollView = screen.scrollViews.firstMatch
        guard scrollView.waitForExistence(timeout: 2), scrollView.isHittable else { return }

        for _ in 0..<6 {
            let start = scrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
            let end = scrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
            start.press(forDuration: 0.1, thenDragTo: end)
        }
    }

    @MainActor
    private func dismissSettings(_ app: XCUIApplication) {
        let done = app.buttons["Done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 5), "Settings Done button is missing")
        tapWhenHittable(done, in: app)
        XCTAssertTrue(element(app, "today-screen").waitForExistence(timeout: 10), "Settings did not dismiss")
    }

    @MainActor
    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func tapWhenHittable(_ element: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(element.waitForExistence(timeout: 5), "Element \(element.identifier) did not appear")
        for _ in 0..<5 {
            let tabBarTop = app.tabBars.firstMatch.exists ? app.tabBars.firstMatch.frame.minY : app.frame.maxY
            let isTabBarButton = app.tabBars.firstMatch.buttons
                .matching(NSPredicate(format: "label == %@", element.label))
                .firstMatch
                .exists
            if element.isHittable && (isTabBarButton || element.frame.midY < tabBarTop - 8) {
                element.tap()
                return
            }
            app.swipeUp()
        }
        XCTFail("Element \(element.identifier) is not hittable")
    }
}
