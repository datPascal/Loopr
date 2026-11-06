import XCTest

/// Train controls that push a screen, keyed to an element only that screen shows.
/// The Food helper is `tapCommitting(in:identifier:)`. This one has its own name so both files
/// can live in the same target.
private let trainNavigationTargets = [
    "train-template-upper-a": "template-describe",
    "train-program-strength-block": "program-hero"
]

extension XCUIElement {
    /// Under heavy host load a synthesized tap can land without committing the push
    /// while the app stays responsive. Tap once more only if the control is still on
    /// screen and its destination has not appeared.
    @MainActor func tapCommittingTrain(in app: XCUIApplication, identifier: String) {
        tap()
        guard let target = trainNavigationTargets[identifier] else { return }
        if app.descendants(matching: .any)[target].firstMatch.waitForExistence(timeout: 10) { return }
        if exists && isHittable { tap() }
    }
}
