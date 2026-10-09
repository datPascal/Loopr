import Foundation

/// One row on the Settings home screen.
public struct SettingsMenuEntry: Identifiable, Equatable, Sendable {
    public let title: String
    public let value: String?
    public let destination: SettingsRouteDestination
    /// Kept stable across layout changes: UI tests and the screenshot lane
    /// find rows by it.
    public let accessibilityIdentifier: String

    public var id: String { accessibilityIdentifier }

    public init(
        _ title: String,
        _ destination: SettingsRouteDestination,
        value: String? = nil,
        accessibilityIdentifier: String? = nil
    ) {
        self.title = title
        self.destination = destination
        self.value = value
        self.accessibilityIdentifier = accessibilityIdentifier
            ?? "settings-" + title.lowercased().replacingOccurrences(of: " ", with: "-")
    }
}

public struct SettingsMenuSection: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let entries: [SettingsMenuEntry]

    public init(id: String, title: String, entries: [SettingsMenuEntry]) {
        self.id = id
        self.title = title
        self.entries = entries
    }
}

/// Short values the home screen shows beside a row. Anything unknown stays
/// nil and the row shows no value, never a placeholder.
public struct SettingsMenuContext: Equatable, Sendable {
    public var units: UnitSystem
    public var appearance: AppearanceChoice
    /// For example "Connected" or "Not paired".
    public var bandSummary: String?
    /// For example "07:00" or "Off".
    public var wakeAlarmSummary: String?
    public var appVersion: String?

    public init(
        units: UnitSystem = .metric,
        appearance: AppearanceChoice = .system,
        bandSummary: String? = nil,
        wakeAlarmSummary: String? = nil,
        appVersion: String? = nil
    ) {
        self.units = units
        self.appearance = appearance
        self.bandSummary = bandSummary
        self.wakeAlarmSummary = wakeAlarmSummary
        self.appVersion = appVersion
    }
}

/// The Settings home screen as data, so its structure can be tested without
/// rendering it.
///
/// Common settings sit in labelled groups, in the order people look for
/// them: the band and its alarm first, then alerts, health data, the
/// person's own details, how the app looks, privacy, and about. Diagnostics
/// and destructive resets live behind one "Advanced" disclosure.
public enum SettingsMenu {
    public static func sections(_ context: SettingsMenuContext) -> [SettingsMenuSection] {
        [
            SettingsMenuSection(id: "band", title: "Band and alarm", entries: [
                SettingsMenuEntry("Band", .deviceCenter, value: context.bandSummary, accessibilityIdentifier: "settings-device-center"),
                SettingsMenuEntry("Wake alarm", .wakeAlarm, value: context.wakeAlarmSummary)
            ]),
            SettingsMenuSection(id: "alerts", title: "Alerts and notifications", entries: [
                SettingsMenuEntry("Heart alerts", heartAlertsDestination),
                SettingsMenuEntry("Notifications", .notifications)
            ]),
            SettingsMenuSection(id: "health", title: "Health and data", entries: [
                SettingsMenuEntry("Apple Health", .healthKit),
                SettingsMenuEntry("Cycle tracking", .cycle),
                SettingsMenuEntry("Data history", .dataHistory),
                SettingsMenuEntry("Import and export", .importExport)
            ]),
            SettingsMenuSection(id: "profile", title: "Profile, units and goals", entries: [
                SettingsMenuEntry("Profile", .profile),
                SettingsMenuEntry("Units", .units, value: context.units.rawValue.capitalized),
                SettingsMenuEntry("Goals", .goals)
            ]),
            SettingsMenuSection(id: "appearance", title: "Appearance and accessibility", entries: [
                SettingsMenuEntry("Appearance", .appearance, value: context.appearance.rawValue.capitalized),
                SettingsMenuEntry("Accessibility", .accessibility)
            ]),
            SettingsMenuSection(id: "privacy", title: "Privacy", entries: [
                SettingsMenuEntry("Widgets and Watch", .privacy, accessibilityIdentifier: "settings-privacy"),
                SettingsMenuEntry("AI and privacy", .aiPrivacy)
            ]),
            SettingsMenuSection(id: "about", title: "About", entries: [
                SettingsMenuEntry("Versions", .versions, value: context.appVersion),
                SettingsMenuEntry("Legal and licenses", .legal)
            ])
        ]
    }

    /// The rows behind the "Advanced and diagnostics" disclosure.
    public static let advanced = SettingsMenuSection(id: "advanced", title: "Advanced and diagnostics", entries: [
        SettingsMenuEntry("Diagnostics", .diagnostics),
        SettingsMenuEntry("Reset and delete", .dataControls, accessibilityIdentifier: "settings-data-controls")
    ])

    /// Where the Heart alerts row goes: the app's heart alerts screen.
    public static let heartAlertsDestination: SettingsRouteDestination = .heartAlerts

    /// Destinations that are deliberately not rows. `surfacePrivacy` is the
    /// same screen as `privacy`; `support` had no content beyond one line;
    /// `hiddenDiagnostics` is the debug-only long press.
    public static let unlistedDestinations: Set<SettingsRouteDestination> = [
        .surfacePrivacy, .support, .hiddenDiagnostics
    ]

    public static func allEntries(_ context: SettingsMenuContext) -> [SettingsMenuEntry] {
        sections(context).flatMap(\.entries) + advanced.entries
    }
}
