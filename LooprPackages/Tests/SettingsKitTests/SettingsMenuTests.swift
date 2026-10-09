import SettingsKit
import XCTest

final class SettingsMenuTests: XCTestCase {
    private let context = SettingsMenuContext(
        units: .imperial,
        appearance: .dark,
        bandSummary: "Connected",
        wakeAlarmSummary: "07:00",
        appVersion: "1.0 (42)"
    )

    func testEveryDestinationIsEitherARowOrDeliberatelyUnlisted() {
        let listed = Set(SettingsMenu.allEntries(context).map(\.destination))
        for destination in SettingsRouteDestination.allCases {
            XCTAssertTrue(
                listed.contains(destination) || SettingsMenu.unlistedDestinations.contains(destination),
                "\(destination) has no row and is not on the unlisted list"
            )
        }
        XCTAssertTrue(listed.isDisjoint(with: SettingsMenu.unlistedDestinations),
                      "An unlisted destination is also shown as a row")
    }

    func testNoRowOpensADeadDestination() {
        // Support was a single line of text and hidden diagnostics only said
        // it was not connected. Neither may come back as a visible row.
        let destinations = SettingsMenu.allEntries(context).map(\.destination)
        XCTAssertFalse(destinations.contains(.support))
        XCTAssertFalse(destinations.contains(.hiddenDiagnostics))
    }

    func testRowIdentifiersAreUniqueAndKeepTheOnesTestsUse() {
        let identifiers = SettingsMenu.allEntries(context).map(\.accessibilityIdentifier)
        XCTAssertEqual(identifiers.count, Set(identifiers).count, "Duplicate row identifiers: \(identifiers)")
        for kept in [
            "settings-device-center", "settings-apple-health", "settings-notifications",
            "settings-cycle-tracking", "settings-data-history", "settings-import-and-export",
            "settings-profile", "settings-units", "settings-goals", "settings-appearance",
            "settings-accessibility", "settings-privacy", "settings-ai-and-privacy",
            "settings-versions", "settings-legal-and-licenses"
        ] {
            XCTAssertTrue(identifiers.contains(kept), "Lost identifier \(kept)")
        }
    }

    func testGoalsHaveExactlyOneRow() {
        let goalRows = SettingsMenu.allEntries(context).filter { $0.destination == .goals }
        XCTAssertEqual(goalRows.count, 1)
    }

    func testBandAndAlarmComeFirstAndAdvancedHoldsDiagnosticsAndResets() {
        let sections = SettingsMenu.sections(context)
        XCTAssertEqual(sections.first?.entries.map(\.destination), [.deviceCenter, .wakeAlarm])
        XCTAssertEqual(sections.map(\.title), [
            "Band and alarm", "Alerts and notifications", "Health and data",
            "Profile, units and goals", "Appearance and accessibility", "Privacy", "About"
        ])
        XCTAssertEqual(SettingsMenu.advanced.entries.map(\.destination), [.diagnostics, .dataControls])
        XCTAssertFalse(sections.flatMap(\.entries).contains { $0.destination == .diagnostics })
    }

    func testHeartAlertsAndNotificationsBothHaveRows() {
        let alerts = SettingsMenu.sections(context).first { $0.id == "alerts" }
        XCTAssertEqual(alerts?.entries.map(\.accessibilityIdentifier), ["settings-heart-alerts", "settings-notifications"])
        XCTAssertEqual(alerts?.entries.first?.destination, SettingsMenu.heartAlertsDestination)
    }

    func testRowValuesComeFromTheContextAndAreAbsentWhenUnknown() {
        let entries = SettingsMenu.allEntries(context)
        XCTAssertEqual(entries.first { $0.destination == .units }?.value, "Imperial")
        XCTAssertEqual(entries.first { $0.destination == .appearance }?.value, "Dark")
        XCTAssertEqual(entries.first { $0.destination == .wakeAlarm }?.value, "07:00")
        XCTAssertEqual(entries.first { $0.destination == .deviceCenter }?.value, "Connected")
        XCTAssertEqual(entries.first { $0.destination == .versions }?.value, "1.0 (42)")

        let bare = SettingsMenu.allEntries(SettingsMenuContext())
        XCTAssertNil(bare.first { $0.destination == .wakeAlarm }?.value)
        XCTAssertNil(bare.first { $0.destination == .deviceCenter }?.value)
    }

    func testNewRoutesHaveCanonicalOwners() {
        XCTAssertEqual(SettingsRouteDestination.wakeAlarm.canonicalRoute, .wakeAlarm)
        XCTAssertEqual(SettingsRoute.wakeAlarm.owner, .deviceCenter)
        XCTAssertEqual(SettingsRouteDestination.dataControls.canonicalRoute, .dataControls)
        XCTAssertEqual(SettingsRoute.dataControls.owner, .data)
    }
}
