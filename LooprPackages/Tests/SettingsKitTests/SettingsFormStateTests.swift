import SettingsKit
import XCTest

/// A settings form is built before its repository has been read. These cover
/// the rule that decides when the loaded snapshot may replace the copy on
/// screen, which is what kept saved profile values from ever appearing.
final class SettingsFormStateTests: XCTestCase {
    private func stored() -> SettingsSnapshot {
        SettingsSnapshot(
            profile: ProfileSettings(displayName: "Alex", age: 34),
            units: .imperial,
            appearance: .dark
        )
    }

    func testUneditedFormTakesTheSnapshotThatArrivesAfterTheFirstRender() {
        var form = SettingsFormState()
        XCTAssertNil(form.snapshot.profile.displayName)

        form.adopt(stored())

        XCTAssertEqual(form.snapshot.profile.displayName, "Alex")
        XCTAssertEqual(form.snapshot.profile.age, 34)
        XCTAssertEqual(form.snapshot.units, .imperial)
    }

    func testALoadDoesNotDiscardAnEditMadeWhileItWasInFlight() {
        var form = SettingsFormState(snapshot: stored())
        form.edit { $0.profile.displayName = "Alex B" }

        form.adopt(stored())

        XCTAssertEqual(form.snapshot.profile.displayName, "Alex B")
        XCTAssertTrue(form.hasPendingEdits)
    }

    func testSubmittingLetsTheNextLoadShowWhatWasActuallyStored() {
        var form = SettingsFormState(snapshot: stored())
        form.edit { $0.profile.age = 35 }
        XCTAssertTrue(form.hasPendingEdits)

        form.markSubmitted()
        XCTAssertFalse(form.hasPendingEdits)

        var saved = stored()
        saved.profile.age = 35
        form.adopt(saved)
        XCTAssertEqual(form.snapshot.profile.age, 35)
    }

    func testEditingOneSectionSubmitsEveryOtherSectionUnchanged() {
        var form = SettingsFormState(snapshot: stored())

        form.edit { $0.appearance = .light }

        // Each destination screen submits the whole snapshot, so the values it
        // did not edit have to be the loaded ones rather than defaults.
        XCTAssertEqual(form.snapshot.appearance, .light)
        XCTAssertEqual(form.snapshot.profile.displayName, "Alex")
        XCTAssertEqual(form.snapshot.profile.age, 34)
        XCTAssertEqual(form.snapshot.units, .imperial)
    }
}
