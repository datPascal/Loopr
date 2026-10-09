import Foundation
import XCTest

final class TempSettingsDestinationCaptureUITests: XCTestCase {
    @MainActor
    func testCaptureSettingsLight() {
        let app = XCUIApplication()
        app.launchArguments = ["--loopr-launch-mode=populated", "-AppleInterfaceStyle", "Light"]
        app.launch()

        XCTAssertTrue(app.descendants(matching: .any)["today-screen"].firstMatch.waitForExistence(timeout: 20))
        let settingsButton = app.buttons["open-settings"].firstMatch
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 10))
        settingsButton.tap()
        XCTAssertTrue(app.descendants(matching: .any)["settings-modal"].firstMatch.waitForExistence(timeout: 15))
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 2.0))
        attach(name: "tempcap-settings-light")

        for (rowID, name) in [("settings-goals", "goals")] {
            let row = app.descendants(matching: .any)[rowID].firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 10), "missing \(rowID)")
            row.tap()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 2.0))
            attach(name: "tempcap-\(name)")
        }
    }

    @MainActor
    private func attach(name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
