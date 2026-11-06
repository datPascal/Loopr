import XCTest

/// LV-10.4: each tab's entrance animation drops no frames. The app wraps every entrance in an
/// animation signpost interval (`LooprPerformanceSignposts`, subsystem `com.loopr.ios`, category
/// `performance`, name `entrance.<tab>`), so `XCTOSSignpostMetric` reports hitch time and hitch
/// ratio for exactly the frames the entrance covers.
///
/// An entrance plays once per tab per local day, so every iteration relaunches the app with the
/// DEBUG argument `--loopr-entrance-reset`, which forgets the day's records. The suite never passes
/// `--loopr-entrance-final-state`: that argument turns the entrance off.
///
/// The budget is 5 ms of hitch per second. `measure` hands the test no values, and XCTest sets up the
/// signpost probe only for a raw `XCTOSSignpostMetric` (a wrapping metric breaks it), so the test only
/// measures. `scripts/test-longevity-step.py` reads the hitch ratio from the result bundle and fails the
/// `lv10-4` and `lv10-4e` steps above the budget. Run one test at a time on a quiet simulator.
final class EntrancePerformanceUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor func testTodayEntrance() { measureEntrance(Tab("Today", signpost: "today", root: "today-screen", duration: 1.8)) }
    @MainActor func testFoodEntrance() { measureEntrance(Tab("Food", signpost: "food", root: "food-screen", duration: 2.2)) }
    @MainActor func testFitnessEntrance() { measureEntrance(Tab("Fitness", signpost: "fitness", root: "workouts-screen", duration: 2.0)) }
    @MainActor func testProtocolEntrance() { measureEntrance(Tab("Protocol", signpost: "protocol", root: "journal-screen", duration: 1.0)) }
    @MainActor func testDataEntrance() {
        // The age ruler's pins drop once the ruler has loaded, so Data needs its fixture.
        measureEntrance(Tab("Data", signpost: "data", root: "health-screen", duration: 1.4, extra: ["--loopr-data-fixture"]))
    }

    private struct Tab {
        let title: String
        let signpost: String
        let root: String
        /// How long the entrance runs, in seconds (the tab's `entranceDuration`).
        let duration: TimeInterval
        let extra: [String]

        init(_ title: String, signpost: String, root: String, duration: TimeInterval, extra: [String] = []) {
            self.title = title; self.signpost = signpost; self.root = root; self.duration = duration; self.extra = extra
        }
    }

    @MainActor
    private func measureEntrance(_ tab: Tab) {
        let signpost = XCTOSSignpostMetric(subsystem: "com.loopr.ios", category: "performance",
                                           name: "entrance.\(tab.signpost)")
        let options = XCTMeasureOptions()
        options.iterationCount = 2
        options.invocationOptions = [.manuallyStart, .manuallyStop]
        // Today opens at launch, so its entrance plays while the app starts. The other tabs
        // play theirs when the tab opens, once Today's own entrance has settled.
        let opensAtLaunch = tab.title == "Today"
        measure(metrics: [signpost], options: options) {
            let app = XCUIApplication()
            app.launchArguments = ["--loopr-launch-mode=populated", "--loopr-entrance-reset",
                                   "-AppleInterfaceStyle", "Dark", "-AppleLanguages", "(en)", "-AppleLocale", "en_AU"] + tab.extra
            if opensAtLaunch { startMeasuring() }
            app.launch()
            XCTAssertTrue(app.descendants(matching: .any)["main-tab-shell"].firstMatch.waitForExistence(timeout: 30))
            if !opensAtLaunch {
                settle(seconds: 3)
                startMeasuring()
                let button = app.tabBars.buttons[tab.title].firstMatch
                XCTAssertTrue(button.waitForExistence(timeout: 10))
                button.tap()
            }
            XCTAssertTrue(app.descendants(matching: .any)[tab.root].firstMatch.waitForExistence(timeout: 30))
            // The interval closes when the entrance settles; leave a second past it.
            settle(seconds: tab.duration + 1)
            stopMeasuring()
            app.terminate()
        }
    }

    /// Waits without polling anything, so the wait itself adds no load to the animation. The app runs in its own
    /// process, so sleeping the runner's thread does not touch it; an expectation wait inside `measure` breaks the
    /// manual start and stop.
    @MainActor
    private func settle(seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }
}
