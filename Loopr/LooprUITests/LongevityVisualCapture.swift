import XCTest

/// Captures for the longevity visual lane (`scripts/test-longevity-visual.py`).
///
/// A capture suite adds `LongevityVisualCapture.launchArguments` to its launch, opens a screen, then calls
/// `captureScreen(_:slug:root:end:)`. Each viewport becomes an attachment named
/// "Longevity Screen <slug>[-n]" and the run ends with "Longevity Coverage <slug>",
/// which proves the scroll reached the screen's last element.
enum LongevityVisualCapture {
    /// Final states only: entrances, count-ups and dot flights are skipped, so a still
    /// matches the contract opened with `#still`.
    /// Light and dark come from `simctl ui appearance`, set by the lane before each run.
    static let launchArguments = ["--loopr-entrance-final-state", "--loopr-visual-capture"]

    /// 16 viewports at the default text size. The accessibility lane passes a larger cap through
    /// `TEST_RUNNER_LOOPR_CAPTURE_MAX_VIEWPORTS`, since AX5 screens run about three times longer.
    static var maximumViewports: Int {
        ProcessInfo.processInfo.environment["LOOPR_CAPTURE_MAX_VIEWPORTS"].flatMap(Int.init) ?? 16
    }
}

extension XCTestCase {
    @MainActor func captureScreen(_ app: XCUIApplication, slug: String, root: String, end endID: String,
                                  maximumViewports: Int = LongevityVisualCapture.maximumViewports,
                                  file: StaticString = #filePath, line: UInt = #line) {
        // An identifier on a row container also lands on its field, so take the first match.
        let screen = app.descendants(matching: .any)[root].firstMatch
        XCTAssertTrue(screen.waitForExistence(timeout: 20), "\(root) did not appear", file: file, line: line)
        let end = app.descendants(matching: .any)[endID].firstMatch
        for index in 1...maximumViewports {
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "Longevity Screen \(index == 1 ? slug : "\(slug)-\(index)")"
            shot.lifetime = .keepAlways
            add(shot)
            let window = app.windows.firstMatch.frame
            // A sheet covers the tab bar, which XCTest still reports. Only a bar that takes taps bounds the screen.
            let bar = app.tabBars.firstMatch
            let bottom = bar.exists && bar.buttons.firstMatch.isHittable ? bar.frame.minY : window.maxY
            if end.exists, end.frame.height > 0, end.frame.minY >= window.minY, end.frame.maxY <= bottom {
                let record = ["screen": slug, "viewports": index, "reachedEnd": true, "lastElement": endID] as [String: Any]
                let coverage = XCTAttachment(data: try! JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
                                             uniformTypeIdentifier: "public.json")
                coverage.name = "Longevity Coverage \(slug)"
                coverage.lifetime = .keepAlways
                add(coverage)
                return
            }
            // Drag in the left gutter so charts and dials never take the scroll.
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.78))
            start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.34)))
        }
        XCTFail("\(slug) never reached \(endID) within \(maximumViewports) viewports", file: file, line: line)
    }
}
