import Foundation
import ProfileKit
import DesignSystem

public enum SettingsRoute: String, Codable, CaseIterable, Sendable {
    case profile, units, appearance, accessibility, goals, deviceCenter, healthKit, notifications, cycle, aiPrivacy, surfacePrivacy, dataHistory, importExport, versions, legal, support, hiddenDiagnostics
    case wakeAlarm, dataControls

    public var isOwningRoute: Bool {
        switch self {
        case .appearance, .accessibility, .surfacePrivacy: return true
        default: return false
        }
    }

    /// The package that owns the canonical surface for a route. SettingsKit
    /// only owns presentation preferences; it must not create shadow stores
    /// for profile, goals, device, platform permissions, or data history.
    public var owner: SettingsRouteOwner {
        switch self {
        case .profile, .units, .goals: .profile
        case .appearance, .accessibility: .designSystem
        case .deviceCenter: .deviceCenter
        case .healthKit: .healthKit
        case .notifications: .notifications
        case .cycle: .cycle
        case .aiPrivacy: .aiPrivacy
        case .surfacePrivacy: .surfaces
        case .dataHistory, .importExport: .data
        case .versions, .legal, .support: .settings
        case .hiddenDiagnostics: .data
        case .wakeAlarm: .deviceCenter
        case .dataControls: .data
        }
    }

    public var isReleaseVisible: Bool { self != .hiddenDiagnostics }
}

public enum SettingsRouteOwner: String, Codable, CaseIterable, Sendable {
    case profile = "APP-02A"
    case designSystem = "DSN-01"
    case deviceCenter = "APP-02"
    case healthKit = "HLT-01"
    case notifications = "NTF-01"
    case cycle = "APP-10"
    case aiPrivacy = "AI-01"
    case surfaces = "SFC-01"
    case data = "APP-16"
    case settings = "APP-15"
}

public enum AppearanceChoice: String, Codable, CaseIterable, Sendable { case system, light, dark }
public enum UnitSystem: String, Codable, CaseIterable, Sendable {
    case metric, imperial

    /// What the screens format against. Storage keeps its own enum; rendering
    /// goes through the DesignSystem one so no kit has to depend on Settings.
    public var looprMeasurementSystem: LooprMeasurementSystem {
        self == .imperial ? .imperial : .metric
    }
}

public struct ProfileSettings: Codable, Equatable, Sendable {
    public var displayName: String?
    public var age: Int?
    public var heightCentimeters: Double?
    public var weightKilograms: Double?
    public var biologicalSex: String?
    public init(displayName: String? = nil, age: Int? = nil, heightCentimeters: Double? = nil, weightKilograms: Double? = nil, biologicalSex: String? = nil) { self.displayName = displayName; self.age = age; self.heightCentimeters = heightCentimeters; self.weightKilograms = weightKilograms; self.biologicalSex = biologicalSex }
}

public struct AccessibilitySettings: Codable, Equatable, Sendable {
    public var reduceMotionOverride: Bool?
    public var increasedContrastPreview: Bool
    public var voiceOverHints: Bool
    public init(reduceMotionOverride: Bool? = nil, increasedContrastPreview: Bool = false, voiceOverHints: Bool = true) { self.reduceMotionOverride = reduceMotionOverride; self.increasedContrastPreview = increasedContrastPreview; self.voiceOverHints = voiceOverHints }
}

public struct GoalSettings: Codable, Equatable, Sendable {
    public var stepGoal: Int?
    public var strainTarget: Double?
    public init(stepGoal: Int? = nil, strainTarget: Double? = nil) { self.stepGoal = stepGoal; self.strainTarget = strainTarget }
}

public struct SurfacePrivacySettings: Codable, Equatable, Sendable {
    public var todayWidget: Bool
    public var batteryWidget: Bool
    public var watchSnapshot: Bool
    public var liveActivity: Bool
    public init(todayWidget: Bool = true, batteryWidget: Bool = true, watchSnapshot: Bool = true, liveActivity: Bool = true) { self.todayWidget = todayWidget; self.batteryWidget = batteryWidget; self.watchSnapshot = watchSnapshot; self.liveActivity = liveActivity }
}

public struct SettingsSnapshot: Codable, Equatable, Sendable {
    public var profile: ProfileSettings
    public var units: UnitSystem
    public var appearance: AppearanceChoice
    public var accessibility: AccessibilitySettings
    public var goals: GoalSettings
    public var surfacePrivacy: SurfacePrivacySettings
    public init(profile: ProfileSettings = .init(), units: UnitSystem = .metric, appearance: AppearanceChoice = .system, accessibility: AccessibilitySettings = .init(), goals: GoalSettings = .init(), surfacePrivacy: SurfacePrivacySettings = .init()) { self.profile = profile; self.units = units; self.appearance = appearance; self.accessibility = accessibility; self.goals = goals; self.surfacePrivacy = surfacePrivacy }
}

/// The editing state of a settings form.
///
/// A settings screen renders before its repository has been read, so the
/// form starts on an empty snapshot and the real values arrive later. Keeping
/// the loaded snapshot and the edited copy in one value makes the rule
/// explicit: a load replaces the form only while nothing has been typed into
/// it. Without that rule the form keeps showing blanks after a successful
/// load, and saving writes those blanks back over every stored section.
public struct SettingsFormState: Equatable, Sendable {
    /// The copy the form renders and submits.
    public private(set) var snapshot: SettingsSnapshot
    /// True once a field has been edited and not yet submitted.
    public private(set) var hasPendingEdits: Bool

    public init(snapshot: SettingsSnapshot = .init(), hasPendingEdits: Bool = false) {
        self.snapshot = snapshot
        self.hasPendingEdits = hasPendingEdits
    }

    /// Applies a field edit and records that a load must not overwrite it.
    public mutating func edit(_ body: (inout SettingsSnapshot) -> Void) {
        body(&snapshot)
        hasPendingEdits = true
    }

    /// Takes a snapshot that was just read from storage. An unedited form
    /// adopts it; an edited one keeps what the person typed.
    public mutating func adopt(_ loaded: SettingsSnapshot) {
        guard !hasPendingEdits else { return }
        snapshot = loaded
    }

    /// Records that the current copy was submitted, so the reload that
    /// follows a successful save is adopted and the form shows what was
    /// actually stored. A failed save leaves the snapshot untouched, so the
    /// edits stay on screen either way.
    public mutating func markSubmitted() {
        hasPendingEdits = false
    }
}

public struct VersionRegistry: Codable, Equatable, Sendable {
    public let appVersion: String
    public let algorithmVersion: Int
    public let protocolVersion: String
    public init(appVersion: String, algorithmVersion: Int, protocolVersion: String) { self.appVersion = appVersion; self.algorithmVersion = algorithmVersion; self.protocolVersion = protocolVersion }
}

/// A version source can be injected by the app composition. Screens should
/// never hardcode protocol or algorithm versions because those values change
/// independently of the SettingsKit release.
public protocol SettingsVersionRegistryProvider: Sendable {
    func current() async -> VersionRegistry
}

public struct StaticSettingsVersionRegistryProvider: SettingsVersionRegistryProvider {
    private let value: VersionRegistry

    public init(_ value: VersionRegistry) { self.value = value }
    public func current() async -> VersionRegistry { value }
}

public enum SettingsIntegration: String, Codable, CaseIterable, Sendable {
    case healthKit
    case notifications
    case aiPrivacy
}

/// Platform integrations are deliberately represented as states rather than
/// booleans. A missing platform adapter must render as unavailable or needing
/// permission, never as an enabled feature backed by fabricated data.
public enum SettingsIntegrationState: Codable, Equatable, Sendable {
    case available
    case permissionRequired
    case denied
    case unavailable
    case unsupported
    case recoverableError(String)
}

public protocol HealthKitSettingsEntryPoint: Sendable {
    func state() async -> SettingsIntegrationState
    func requestPermission() async -> SettingsIntegrationState
    func reset() async throws
}

public protocol NotificationSettingsEntryPoint: Sendable {
    func state() async -> SettingsIntegrationState
    func requestPermission() async -> SettingsIntegrationState
    func reset() async throws
    func preferences() async -> [NotificationPreferenceSetting]
    func setPreference(id: String, enabled: Bool) async throws
}

public struct NotificationPreferenceSetting: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let isEnabled: Bool

    public init(id: String, title: String, isEnabled: Bool) {
        self.id = id
        self.title = title
        self.isEnabled = isEnabled
    }
}

public extension NotificationSettingsEntryPoint {
    func preferences() async -> [NotificationPreferenceSetting] { [] }
    func setPreference(id: String, enabled: Bool) async throws {}
}

public protocol AIPrivacySettingsEntryPoint: Sendable {
    func state() async -> SettingsIntegrationState
    func setEnabled(_ enabled: Bool) async throws -> SettingsIntegrationState
    func reset() async throws
}

public struct UnavailableHealthKitSettingsEntryPoint: HealthKitSettingsEntryPoint {
    public init() {}
    public func state() async -> SettingsIntegrationState { .unavailable }
    public func requestPermission() async -> SettingsIntegrationState { .unavailable }
    public func reset() async throws {}
}

public struct UnavailableNotificationSettingsEntryPoint: NotificationSettingsEntryPoint {
    public init() {}
    public func state() async -> SettingsIntegrationState { .unavailable }
    public func requestPermission() async -> SettingsIntegrationState { .unavailable }
    public func reset() async throws {}
}

public struct UnavailableAIPrivacySettingsEntryPoint: AIPrivacySettingsEntryPoint {
    public init() {}
    public func state() async -> SettingsIntegrationState { .unavailable }
    public func setEnabled(_ enabled: Bool) async throws -> SettingsIntegrationState { .unavailable }
    public func reset() async throws {}
}

public struct SettingsIntegrationClients: Sendable {
    public let healthKit: (any HealthKitSettingsEntryPoint)?
    public let notifications: (any NotificationSettingsEntryPoint)?
    public let aiPrivacy: (any AIPrivacySettingsEntryPoint)?

    public init(
        healthKit: (any HealthKitSettingsEntryPoint)? = nil,
        notifications: (any NotificationSettingsEntryPoint)? = nil,
        aiPrivacy: (any AIPrivacySettingsEntryPoint)? = nil
    ) {
        self.healthKit = healthKit
        self.notifications = notifications
        self.aiPrivacy = aiPrivacy
    }
}

/// DesignSystem owns the visual token implementation. SettingsKit talks to
/// it through this narrow seam so an app can apply an appearance choice and
/// accessibility override without introducing a second local token system.
public struct DesignSystemTokenState: Codable, Equatable, Sendable {
    public var appearance: AppearanceChoice
    public var increasedContrastPreview: Bool
    public var reduceMotionOverride: Bool?
    /// Metric or imperial. Screens format against it; storage stays SI.
    public var units: UnitSystem
    /// Whether screens add the longer VoiceOver hints.
    public var voiceOverHints: Bool

    public init(
        appearance: AppearanceChoice = .system,
        increasedContrastPreview: Bool = false,
        reduceMotionOverride: Bool? = nil,
        units: UnitSystem = .metric,
        voiceOverHints: Bool = true
    ) {
        self.appearance = appearance
        self.increasedContrastPreview = increasedContrastPreview
        self.reduceMotionOverride = reduceMotionOverride
        self.units = units
        self.voiceOverHints = voiceOverHints
    }

    private enum CodingKeys: String, CodingKey {
        case appearance, increasedContrastPreview, reduceMotionOverride, units, voiceOverHints
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        appearance = try container.decodeIfPresent(AppearanceChoice.self, forKey: .appearance) ?? .system
        increasedContrastPreview = try container.decodeIfPresent(Bool.self, forKey: .increasedContrastPreview) ?? false
        reduceMotionOverride = try container.decodeIfPresent(Bool.self, forKey: .reduceMotionOverride)
        units = try container.decodeIfPresent(UnitSystem.self, forKey: .units) ?? .metric
        voiceOverHints = try container.decodeIfPresent(Bool.self, forKey: .voiceOverHints) ?? true
    }
}

public protocol DesignSystemTokenBridge: Sendable {
    func state() async -> DesignSystemTokenState
    func apply(_ state: DesignSystemTokenState) async throws
    func reset() async throws
}

public struct UnavailableDesignSystemTokenBridge: DesignSystemTokenBridge {
    public init() {}
    public func state() async -> DesignSystemTokenState { .init() }
    public func apply(_ state: DesignSystemTokenState) async throws {
        throw SettingsError.tokenBridgeUnavailable
    }
    public func reset() async throws {}
}

public actor InMemoryDesignSystemTokenBridge: DesignSystemTokenBridge {
    private var value: DesignSystemTokenState

    public init(initial: DesignSystemTokenState = .init()) { value = initial }
    public func state() async -> DesignSystemTokenState { value }
    public func apply(_ state: DesignSystemTokenState) async throws {
        value = state
        DesignSystemRuntime.apply(.init(
            appearance: LooprAppearanceOverride(rawValue: state.appearance.rawValue) ?? .system,
            increasedContrast: state.increasedContrastPreview,
            reduceMotion: state.reduceMotionOverride
        ))
    }

    public func reset() async throws {
        value = DesignSystemTokenState()
        DesignSystemRuntime.reset()
    }
}

/// Canonical APP-02A repositories injected by the app. SettingsKit may read
/// and write through these protocols, but it never stores a duplicate profile
/// or goals record of its own.
public struct CanonicalSettingsRepositories: Sendable {
    public let profile: any ProfileRepository
    public let goals: any GoalsRepository

    public init(profile: any ProfileRepository, goals: any GoalsRepository) {
        self.profile = profile
        self.goals = goals
    }
}

public enum SettingsResetSection: String, Codable, CaseIterable, Sendable {
    case profile
    case units
    case appearance
    case accessibility
    case goals
    case surfacePrivacy
    case healthKit
    case notifications
    case aiPrivacy
}

public protocol SettingsSectionResetting: Sendable {
    func reset(section: SettingsResetSection) async throws
}

public struct LicenseNotice: Codable, Equatable, Sendable {
    public let name: String
    public let text: String
    public init(name: String, text: String) { self.name = name; self.text = text }
}

public enum SettingsSurface: String, CaseIterable, Codable, Sendable {
    case todayWidget
    case batteryWidget
    case watchSnapshot
    case liveActivity
}

public struct LegalDocument: Equatable, Sendable {
    public let title: String
    public let url: URL
    public let accessibilityIdentifier: String
}

public enum SettingsLegalDocuments {
    /// Hosted on the public `datPascal/loopr-legal` GitHub Pages site so App
    /// Store Connect, TestFlight testers and the app all read the same text.
    public static let siteURL = URL(string: "https://datpascal.github.io/loopr-legal/")!

    public static let all = [
        LegalDocument(title: "Privacy policy", url: page("privacy.html"), accessibilityIdentifier: "settings-legal-privacy"),
        LegalDocument(title: "Terms", url: page("terms.html"), accessibilityIdentifier: "settings-legal-terms"),
        LegalDocument(title: "Notice", url: page("notice.html"), accessibilityIdentifier: "settings-legal-notice"),
        LegalDocument(title: "Imprint", url: page("imprint.html"), accessibilityIdentifier: "settings-legal-imprint")
    ]

    private static func page(_ name: String) -> URL {
        siteURL.appending(path: name)
    }
}

public enum SettingsLicenseCatalog {
    /// The production settings surface exposes notices copied from the
    /// reviewed DesignSystem inventory; it never exposes the gallery or a
    /// protocol console as a user-facing route.
    public static let notices = [
        LicenseNotice(
            name: "WHOOP non-affiliation",
            text: "Loopr is an independent open-source project. It is not affiliated with, sponsored by, endorsed by, or connected to WHOOP, Inc. WHOOP is a trademark of WHOOP, Inc. The name is used only to identify hardware that Loopr is designed to communicate with."
        ),
        LicenseNotice(
            name: "Wellness, not medical care",
            text: "Loopr is intended for general fitness and wellness use. It is not a medical device and does not provide medical advice. Its metrics are estimates, not clinical measurements. Do not use Loopr to diagnose, treat, cure, or prevent a disease or health condition."
        ),
        LicenseNotice(name: "OpenStrap Edge, protocol, and analytics", text: """
            Loopr incorporates or derives portions of its Bluetooth, protocol, and analytics behavior from OpenStrap work.

            MIT License

            Copyright (c) 2026 OpenStrap

            Permission is hereby granted, free of charge, to any person obtaining a copy
            of this software and associated documentation files (the "Software"), to deal
            in the Software without restriction, including without limitation the rights
            to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
            copies of the Software, and to permit persons to whom the Software is
            furnished to do so, subject to the following conditions:

            The above copyright notice and this permission notice shall be included in all
            copies or substantial portions of the Software.

            THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
            IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
            FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
            AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
            LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
            OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
            SOFTWARE.
            """),
        LicenseNotice(name: "BodyParts3D onboarding film", text: """
            The hand and forearm in the onboarding film and poster are adapted from BodyParts3D, © The Database Center for Life Science. The film and poster are licensed under Creative Commons Attribution-Share Alike 2.1 Japan (CC BY-SA 2.1 JP).

            We smoothed the wrist rig weights, posed the hand, subdivided the skin, rendered it as a translucent shell, and animated it with a band modelled for Loopr.

            Source: https://dbarchive.biosciencedbc.jp/en/bodyparts3d/download.html
            License: https://creativecommons.org/licenses/by-sa/2.1/jp/deed.en
            """),
        LicenseNotice(name: "GRDB", text: "Copyright (C) 2015-2025 Gwendal Roué. MIT License."),
        LicenseNotice(name: "Manrope", text: "Licensed under the SIL Open Font License 1.1."),
        LicenseNotice(name: "Barlow Condensed", text: "Licensed under the SIL Open Font License 1.1."),
        LicenseNotice(name: "Space Grotesk", text: "Licensed under the SIL Open Font License 1.1."),
        LicenseNotice(name: "IBM Plex Mono", text: "Licensed under the SIL Open Font License 1.1.")
    ]
}

public enum SettingsError: Error, Equatable, Sendable {
    case invalidGoal
    case invalidProfile
    case hiddenRouteUnavailable
    case canonicalRepositoryUnavailable
    case tokenBridgeUnavailable
    case integrationUnavailable
    case resetUnavailable(SettingsResetSection)
}

public protocol SettingsRepository: Sendable {
    func snapshot() async -> SettingsSnapshot
    func update(_ snapshot: SettingsSnapshot) async throws
    func resetProfile() async
    func resetAll() async
    /// Checked destructive variants are the app boundary for durable
    /// repositories.  The legacy methods remain for deterministic fixtures
    /// and older callers, while production adapters override these methods to
    /// propagate a failed profile/settings write.
    func resetProfileChecked() async throws
    func resetAllChecked() async throws
}

public extension SettingsRepository {
    func resetProfileChecked() async throws { await resetProfile() }
    func resetAllChecked() async throws { await resetAll() }
}

public actor InMemorySettingsRepository: SettingsRepository, SettingsSectionResetting {
    private var value = SettingsSnapshot()
    public init(initial: SettingsSnapshot = .init()) { value = initial }
    public func snapshot() -> SettingsSnapshot { value }
    public func update(_ snapshot: SettingsSnapshot) throws {
        if let goal = snapshot.goals.stepGoal, goal <= 0 { throw SettingsError.invalidGoal }
        if let age = snapshot.profile.age, !(0...130).contains(age) { throw SettingsError.invalidProfile }
        value = snapshot
    }
    public func resetProfile() { value.profile = ProfileSettings(); value.goals = GoalSettings() }
    public func resetAll() { value = SettingsSnapshot() }

    public func reset(section: SettingsResetSection) async throws {
        switch section {
        case .profile: value.profile = ProfileSettings()
        case .units: value.units = .metric
        case .appearance: value.appearance = .system
        case .accessibility: value.accessibility = AccessibilitySettings()
        case .goals: value.goals = GoalSettings()
        case .surfacePrivacy: value.surfacePrivacy = SurfacePrivacySettings()
        case .healthKit, .notifications, .aiPrivacy:
            // These settings belong to injected platform owners. The
            // in-memory repository has no local copy to mutate.
            throw SettingsError.resetUnavailable(section)
        }
    }
}

public struct HiddenDiagnosticsGate: Sendable, Equatable {
    public let releaseBuild: Bool
    public init(releaseBuild: Bool) { self.releaseBuild = releaseBuild }
    public func canOpen(route: SettingsRoute) -> Bool { !releaseBuild && route == .hiddenDiagnostics }
}

public struct SettingsNavigationEntry: Equatable, Sendable {
    public let route: SettingsRoute
    public let owner: String
    public let typedOwner: SettingsRouteOwner
    public let isHidden: Bool
    public init(route: SettingsRoute, owner: String? = nil, isHidden: Bool = false) {
        self.route = route
        typedOwner = route.owner
        self.owner = owner ?? route.owner.rawValue
        self.isHidden = isHidden
    }
}

public actor SettingsViewModel {
    public let repository: any SettingsRepository
    public let versions: VersionRegistry
    public let diagnosticsGate: HiddenDiagnosticsGate
    public let integrationClients: SettingsIntegrationClients
    public let tokenBridge: (any DesignSystemTokenBridge)?
    public let canonicalRepositories: CanonicalSettingsRepositories?
    private var state: ScreenState = .loading

    public enum ScreenState: String, CaseIterable, Sendable { case loading, ready, noRecords, absent, measuredZero, partial, lowConfidence, settling, stale, disconnected, bluetoothOff, permissionDenied, unsupportedHardware, recoverableError, destructiveFailure, migrationFailure }

    public init(
        repository: any SettingsRepository,
        versions: VersionRegistry,
        releaseBuild: Bool,
        integrationClients: SettingsIntegrationClients = .init(),
        tokenBridge: (any DesignSystemTokenBridge)? = nil,
        canonicalRepositories: CanonicalSettingsRepositories? = nil
    ) {
        self.repository = repository
        self.versions = versions
        self.diagnosticsGate = HiddenDiagnosticsGate(releaseBuild: releaseBuild)
        self.integrationClients = integrationClients
        self.tokenBridge = tokenBridge
        self.canonicalRepositories = canonicalRepositories
    }
    public func screenState() -> ScreenState { state }
    public func load() async -> SettingsSnapshot {
        let snapshot = await repository.snapshot()
        if let tokenBridge {
            do {
                try await tokenBridge.apply(DesignSystemTokenState(
                    appearance: snapshot.appearance,
                    increasedContrastPreview: snapshot.accessibility.increasedContrastPreview,
                    reduceMotionOverride: snapshot.accessibility.reduceMotionOverride,
                    units: snapshot.units,
                    voiceOverHints: snapshot.accessibility.voiceOverHints
                ))
            } catch {
                // The caller still receives the canonical settings snapshot;
                // an unavailable visual owner is not silently treated as a
                // different persisted preference.
            }
        }
        state = .ready
        return snapshot
    }
    public func update(_ snapshot: SettingsSnapshot) async throws {
        try await repository.update(snapshot)
        if let tokenBridge {
            try await tokenBridge.apply(DesignSystemTokenState(
                appearance: snapshot.appearance,
                increasedContrastPreview: snapshot.accessibility.increasedContrastPreview,
                reduceMotionOverride: snapshot.accessibility.reduceMotionOverride,
                units: snapshot.units,
                voiceOverHints: snapshot.accessibility.voiceOverHints
            ))
        }
        state = .ready
    }
    public func resetProfile() async { await repository.resetProfile() }
    public func resetAll() async { await repository.resetAll() }
    public func resetProfileChecked() async throws { try await repository.resetProfileChecked() }
    public func resetAllChecked() async throws { try await repository.resetAllChecked() }
    public func reset(section: SettingsResetSection) async throws {
        guard let resetter = repository as? any SettingsSectionResetting else {
            throw SettingsError.resetUnavailable(section)
        }
        try await resetter.reset(section: section)
        if section == .appearance || section == .accessibility {
            try await tokenBridge?.reset()
        }
    }

    public func canonicalProfile() async throws -> Profile? {
        guard let canonicalRepositories else { throw SettingsError.canonicalRepositoryUnavailable }
        return try await canonicalRepositories.profile.readProfile()
    }

    public func saveCanonicalProfile(_ draft: ProfileDraft) async throws -> Profile {
        guard let canonicalRepositories else { throw SettingsError.canonicalRepositoryUnavailable }
        return try await canonicalRepositories.profile.saveProfile(draft)
    }

    public func canonicalGoals() async throws -> [Goal] {
        guard let canonicalRepositories else { throw SettingsError.canonicalRepositoryUnavailable }
        return try await canonicalRepositories.goals.readGoals()
    }

    public func saveCanonicalGoal(type: GoalType, target: Double, unit: String, isEnabled: Bool = true) async throws -> Goal {
        guard let canonicalRepositories else { throw SettingsError.canonicalRepositoryUnavailable }
        return try await canonicalRepositories.goals.saveGoal(type: type, target: target, unit: unit, isEnabled: isEnabled)
    }

    public func integrationState(for integration: SettingsIntegration) async -> SettingsIntegrationState {
        switch integration {
        case .healthKit: await integrationClients.healthKit?.state() ?? .unavailable
        case .notifications: await integrationClients.notifications?.state() ?? .unavailable
        case .aiPrivacy: await integrationClients.aiPrivacy?.state() ?? .unavailable
        }
    }

    public func requestPermission(for integration: SettingsIntegration) async -> SettingsIntegrationState {
        switch integration {
        case .healthKit: await integrationClients.healthKit?.requestPermission() ?? .unavailable
        case .notifications: await integrationClients.notifications?.requestPermission() ?? .unavailable
        case .aiPrivacy: await integrationClients.aiPrivacy?.state() ?? .unavailable
        }
    }

    public func setAIPrivacyEnabled(_ enabled: Bool) async throws -> SettingsIntegrationState {
        guard let client = integrationClients.aiPrivacy else { throw SettingsError.integrationUnavailable }
        return try await client.setEnabled(enabled)
    }

    public func resetIntegration(_ integration: SettingsIntegration) async throws {
        switch integration {
        case .healthKit:
            guard let client = integrationClients.healthKit else { throw SettingsError.integrationUnavailable }
            try await client.reset()
        case .notifications:
            guard let client = integrationClients.notifications else { throw SettingsError.integrationUnavailable }
            try await client.reset()
        case .aiPrivacy:
            guard let client = integrationClients.aiPrivacy else { throw SettingsError.integrationUnavailable }
            try await client.reset()
        }
    }

    public func notificationPreferences() async -> [NotificationPreferenceSetting] {
        await integrationClients.notifications?.preferences() ?? []
    }

    public func setNotificationPreference(id: String, enabled: Bool) async throws {
        guard let client = integrationClients.notifications else { throw SettingsError.integrationUnavailable }
        try await client.setPreference(id: id, enabled: enabled)
    }
    public func navigate(to route: SettingsRoute) throws -> SettingsNavigationEntry {
        guard route != .hiddenDiagnostics || diagnosticsGate.canOpen(route: route) else { throw SettingsError.hiddenRouteUnavailable }
        return SettingsNavigationEntry(route: route, isHidden: route == .hiddenDiagnostics)
    }
}

public struct SettingsSurfaceSnapshot: Codable, Equatable, Sendable {
    public let surface: SettingsSurface
    public let includesHealthData: Bool
    public let generatedAt: Date
    public init(surface: SettingsSurface, includesHealthData: Bool, generatedAt: Date = Date()) { self.surface = surface; self.includesHealthData = includesHealthData; self.generatedAt = generatedAt }
}

/// The decision every widget, watch snapshot, and live activity consumer must
/// make before publishing health data.  A disabled surface returns a redacted
/// value rather than an empty-but-successful payload, so callers cannot
/// accidentally present stale private data as current.
public enum SurfacePrivacyDecision: Codable, Equatable, Sendable {
    case allowed(SettingsSurfaceSnapshot)
    case redacted(surface: SettingsSurface, reason: String)

    public var includesHealthData: Bool {
        if case .allowed(let snapshot) = self { return snapshot.includesHealthData }
        return false
    }

    public var isRedacted: Bool {
        if case .redacted = self { return true }
        return false
    }
}

public protocol SurfacePrivacyConsumer: Sendable {
    func decision(for surface: SettingsSurface, settings: SettingsSnapshot) async -> SurfacePrivacyDecision
}

/// Canonical fail-closed gate for shared surfaces.  It deliberately accepts a
/// complete SettingsSnapshot instead of a boolean supplied by a feature so a
/// stale or missing preference cannot be interpreted as permission.
public struct SettingsSurfacePrivacyGate: SurfacePrivacyConsumer {
    public init() {}

    public func decision(
        for surface: SettingsSurface,
        settings: SettingsSnapshot
    ) async -> SurfacePrivacyDecision {
        guard settings.includesData(on: surface) else {
            return .redacted(surface: surface, reason: "Surface privacy is disabled.")
        }
        return .allowed(settings.surfaceSnapshot(for: surface))
    }
}

/// Used by compositions that do not have the owning SettingsRepository yet.
/// An unavailable settings owner must never default to publishing private
/// data; this is intentionally not an in-memory permissive fixture.
public struct UnavailableSurfacePrivacyConsumer: SurfacePrivacyConsumer {
    public init() {}

    public func decision(
        for surface: SettingsSurface,
        settings _: SettingsSnapshot
    ) async -> SurfacePrivacyDecision {
        .redacted(surface: surface, reason: "Surface privacy settings are unavailable.")
    }
}

public extension SettingsSnapshot {
    func includesData(on surface: SettingsSurface) -> Bool {
        switch surface {
        case .todayWidget: surfacePrivacy.todayWidget
        case .batteryWidget: surfacePrivacy.batteryWidget
        case .watchSnapshot: surfacePrivacy.watchSnapshot
        case .liveActivity: surfacePrivacy.liveActivity
        }
    }

    func surfaceSnapshot(for surface: SettingsSurface, generatedAt: Date = Date()) -> SettingsSurfaceSnapshot {
        SettingsSurfaceSnapshot(surface: surface, includesHealthData: includesData(on: surface), generatedAt: generatedAt)
    }
}
