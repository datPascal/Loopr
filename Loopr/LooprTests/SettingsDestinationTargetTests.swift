import SettingsKit
import Testing
@testable import Loopr

/// Every row on the Settings home screen has to land on a screen with
/// something on it. The SettingsKit form falls back to "this route is owned
/// by its package" for destinations it does not render, so reaching the form
/// for one of those would be a dead row.
struct SettingsDestinationTargetTests {
    private let context = SettingsMenuContext(bandSummary: "Connected", wakeAlarmSummary: "07:00", appVersion: "1.0")

    @Test(arguments: [true, false])
    func everyRowOpensARealScreen(isProduction: Bool) {
        for entry in SettingsMenu.allEntries(context) {
            let target = SettingsDestinationTarget.resolve(
                entry.destination, isProduction: isProduction, isVisualCapture: false
            )
            #expect(target != .hiddenDiagnosticsUnavailable, "\(entry.title) opens an unavailable screen")
            if target == .settingsForm {
                #expect(
                    SettingsDestinationTarget.formDestinations.contains(entry.destination),
                    "\(entry.title) would open the package filler text"
                )
            }
        }
    }

    @Test
    func theNewRowsOpenTheirOwnScreens() {
        func target(_ destination: SettingsRouteDestination) -> SettingsDestinationTarget {
            SettingsDestinationTarget.resolve(destination, isProduction: true, isVisualCapture: false)
        }
        #expect(target(.wakeAlarm) == .wakeAlarm)
        #expect(target(.goals) == .goals)
        #expect(target(.dataControls) == .dataControls)
        #expect(target(.diagnostics) == .dataDiagnostics)
        #expect(target(.deviceCenter) == .deviceCenter)
        #expect(target(.aiPrivacy) == .aiProvider)
        #expect(target(.healthKit) == .appleHealth)
    }

    /// The settings and monitors lanes both reached Notifications. The
    /// monitors screen replaces the SettingsKit form, and the Heart alerts row
    /// opens the monitors screen instead of falling back to Notifications.
    @Test(arguments: [true, false])
    func heartAlertsAndNotificationsOpenTheMonitorsScreens(isProduction: Bool) {
        #expect(SettingsMenu.heartAlertsDestination == .heartAlerts)
        #expect(SettingsDestinationTarget.resolve(.heartAlerts, isProduction: isProduction, isVisualCapture: false)
            == .heartAlerts)
        #expect(SettingsDestinationTarget.resolve(.notifications, isProduction: isProduction, isVisualCapture: false)
            == .notifications)
        #expect(!SettingsDestinationTarget.formDestinations.contains(.notifications))
        #expect(!SettingsDestinationTarget.formDestinations.contains(.heartAlerts))
    }

    @Test
    func hiddenDiagnosticsStaysClosedInRelease() {
        #expect(SettingsDestinationTarget.resolve(.hiddenDiagnostics, isProduction: true, isVisualCapture: false)
            == .hiddenDiagnosticsUnavailable)
        #expect(SettingsDestinationTarget.resolve(.hiddenDiagnostics, isProduction: false, isVisualCapture: false)
            == .dataDiagnostics)
    }

    @Test
    func versionsShowTheRealAnalyticsGeneration() {
        #expect(LooprSettingsVersionSource.algorithmGeneration("loopr.daily.6") == 6)
        #expect(LooprSettingsVersionSource.algorithmGeneration("garbled") == 0)
        #expect(LooprSettingsVersionSource.algorithmVersion
            == LooprSettingsVersionSource.algorithmGeneration(CanonicalDailyAnalytics.version))
    }
}
