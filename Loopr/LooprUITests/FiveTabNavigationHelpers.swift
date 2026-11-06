import XCTest

extension XCUIApplication {
    /// Older feature tests still name the screen they exercise. The shell now
    /// reaches Sleep, Heart and Body through Health's Explore rows.
    @MainActor @discardableResult
    func openLooprArea(_ name: String, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let health: [String: (String, String)] = [
            "Sleep": ("health-explore-sleep", "sleep-screen"),
            "Heart": ("health-explore-heart", "heart-screen"),
            "Body": ("health-explore-body", "body-screen"),
            "Records": ("health-explore-records", "records-screen"),
            "Stress": ("health-explore-stress", "stress-screen")
        ]
        let tabName = health[name] == nil ? (name == "Workouts" ? "Fitness" : name) : "Data"
        let tab = tabBars.buttons[tabName].firstMatch
        guard tab.waitForExistence(timeout: 10), tab.isHittable else {
            XCTFail("Missing tab \(tabName)", file: file, line: line)
            return false
        }
        tab.tap()
        guard let (rowID, rootID) = health[name] else { return true }
        let root = descendants(matching: .any)[rootID].firstMatch
        if root.waitForExistence(timeout: 1), root.isHittable { return true }
        // The tab keeps its navigation path. Return from a different pushed
        // Health screen before opening the requested Explore destination.
        for _ in 0..<8 where navigationBars.firstMatch.exists {
            let back = navigationBars.buttons.firstMatch
            guard back.exists && back.isHittable else { break }
            back.tap()
        }
        let row = descendants(matching: .any)[rowID].firstMatch
        for _ in 0..<10 {
            if row.exists && row.isHittable {
                row.tap()
                return root.waitForExistence(timeout: 10)
            }
            swipeUp()
        }
        XCTFail("Missing Explore row \(rowID)", file: file, line: line)
        return false
    }
    /// Opens the Settings sheet from the avatar's menu, which is how the older Settings tests reach it. Your data's
    /// All settings row pushes the same screen inside Your data instead.
    @MainActor @discardableResult
    func openLooprSettings() -> Bool {
        let avatar = buttons["open-settings"].firstMatch
        guard avatar.waitForExistence(timeout: 10), avatar.isHittable else { return false }
        let item = buttons["your-data-settings"].firstMatch
        // A press that lands while the header is still settling opens nothing; try again before giving up.
        for _ in 0..<3 {
            avatar.press(forDuration: 1.2)
            if item.waitForExistence(timeout: 4) { break }
        }
        guard item.exists else { return false }
        item.tap()
        return descendants(matching: .any)["settings-screen"].firstMatch.waitForExistence(timeout: 10)
    }

    /// The buttons of a tab's header. Not filtered by `isHittable`: since iOS 27 XCTest's hit test returns the
    /// content scrolled under the header, so the header's own buttons read as not hittable.
    /// Empty while a sheet covers the tab, which leaves the tab bar without taps.
    @MainActor private var tabHeaderParts: [XCUIElement] {
        guard tabBars.firstMatch.buttons.firstMatch.isHittable else { return [] }
        return descendants(matching: .any).matching(NSPredicate(
            format: "identifier IN %@ OR identifier ENDSWITH '-header-ask' OR identifier ENDSWITH '-header-start'",
            ["open-settings", "tab-header-title", "day-navigator-today", "day-navigator-previous", "day-navigator-next"]))
            .allElementsBoundByIndex.filter { $0.frame.height > 0 && $0.frame.minY < frame.midY }
    }

    /// The bottom edge of a tab's header. Since iOS 27 XCTest reports content scrolled under
    /// the header's glass as hittable, and a tap there lands on the header. Zero on pushed screens.
    @MainActor var tabHeaderBottom: CGFloat { tabHeaderParts.map(\.frame.maxY).max() ?? 0 }

    /// True when `element` can take a tap: it is a top-bar control (a header button, Back, a sheet's
    /// Cancel), or its centre is in the visible content, between the header and the tab bar.
    @MainActor func showsInContent(_ element: XCUIElement) -> Bool {
        guard element.exists else { return false }
        let target = element.frame
        let parts = tabHeaderParts
        let barButtons = navigationBars.descendants(matching: .any).allElementsBoundByIndex
        if (parts + barButtons).contains(where: { $0.frame == target }) { return true }
        guard element.isHittable else { return false }
        // A sheet covers the tab bar, which XCTest still reports. Only a bar that takes taps bounds the content.
        let bar = tabBars.firstMatch
        let tabBarTop = bar.exists && bar.buttons.firstMatch.isHittable ? bar.frame.minY : frame.maxY
        let headerBottom = parts.map(\.frame.maxY).max() ?? 0
        return target.midY < tabBarTop - 8 && target.midY > headerBottom + 8
    }

    /// Scrolls the content by about a third of the screen without a fling, so a row cannot jump
    /// from below the content past the header in one step.
    @MainActor func dragContent(up: Bool) {
        let from = coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.6 : 0.3))
        from.press(forDuration: 0.05, thenDragTo: coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.3 : 0.6)))
    }
}
