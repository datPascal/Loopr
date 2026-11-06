import XCTest

/// Food controls that push a screen, keyed to an element only that screen shows.
private let foodNavigationTargets = [
    "food-log-meal": "food-capture-close",
    "food-manual": "food-capture-close",
    "food-voice": "food-capture-close",
    // A close or back tap that lands while the previous pop is still animating can be dropped.
    "food-cancel-meal": "food-capture-close",
    "food-capture-close": "food-log-meal",
    "food-week": "food-week-page",
]

extension XCUIElement {
    /// Under heavy host load a synthesized tap can land without committing the push
    /// while the app stays responsive. Tap once more only if the control is still on
    /// screen and its destination has not appeared.
    @MainActor func tapCommitting(in app: XCUIApplication, identifier: String) {
        tap()
        guard let target = foodNavigationTargets[identifier] else { return }
        if app.descendants(matching: .any)[target].firstMatch.waitForExistence(timeout: 10) { return }
        if exists && isHittable { tap() }
    }
}
