import Combine
import ProfileKit
import SwiftUI
import DesignSystem

public enum SettingsRouteDestination: Hashable, Sendable, CaseIterable {
    case profile
    case units
    case appearance
    case accessibility
    case goals
    case deviceCenter
    case healthKit
    case notifications
    case cycle
    case aiPrivacy
    case privacy
    case surfacePrivacy
    case dataHistory
    case importExport
    case versions
    case legal
    case support
    case diagnostics
    case hiddenDiagnostics
    case wakeAlarm
    case dataControls
    /// High and low heart rate, the overnight check. The app renders it.
    case heartAlerts

    public var canonicalRoute: SettingsRoute {
        switch self {
        case .profile: .profile
        case .units: .units
        case .appearance: .appearance
        case .accessibility: .accessibility
        case .goals: .goals
        case .deviceCenter: .deviceCenter
        case .healthKit: .healthKit
        case .notifications: .notifications
        case .cycle: .cycle
        case .aiPrivacy: .aiPrivacy
        case .privacy, .surfacePrivacy: .surfacePrivacy
        case .dataHistory: .dataHistory
        case .importExport: .importExport
        case .versions: .versions
        case .legal: .legal
        case .support: .support
        case .diagnostics, .hiddenDiagnostics: .hiddenDiagnostics
        case .wakeAlarm: .wakeAlarm
        case .dataControls: .dataControls
        case .heartAlerts: .notifications
        }
    }
}

public enum SettingsScreenStateFixtures {
    public static let allStates = MetricState.allCases
    public static let accessibilityIdentifiers = [
        "settings-screen", "settings-loading", "settings-profile", "settings-privacy",
        "settings-health-kit", "settings-notifications", "settings-ai-privacy",
        "settings-surface-privacy", "settings-data-history", "settings-hidden-diagnostics"
    ]
    public static let statesByScreen = Dictionary(uniqueKeysWithValues: accessibilityIdentifiers.map { ($0, allStates) })
    public static func accessibilitySummary(for state: MetricState) -> String { "\(state.title). \(state.detail)" }
}

@MainActor
public final class SettingsScreenViewModel: ObservableObject {
    @Published public private(set) var snapshot: SettingsSnapshot
    @Published public private(set) var isLoading = true
    private let repository: any SettingsRepository
    private let tokenBridge: (any DesignSystemTokenBridge)?

    public init(repository: any SettingsRepository, tokenBridge: (any DesignSystemTokenBridge)? = nil) {
        self.repository = repository
        self.tokenBridge = tokenBridge
        snapshot = SettingsSnapshot()
    }

    public func load() async {
        snapshot = await repository.snapshot()
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
                // A missing visual bridge is surfaced by the owning
                // composition as an unavailable integration; it must not
                // prevent settings from loading its canonical snapshot.
            }
        }
        isLoading = false
    }

    public func update(_ newValue: SettingsSnapshot) async throws {
        try await repository.update(newValue)
        if let tokenBridge {
            try await tokenBridge.apply(DesignSystemTokenState(
                appearance: newValue.appearance,
                increasedContrastPreview: newValue.accessibility.increasedContrastPreview,
                reduceMotionOverride: newValue.accessibility.reduceMotionOverride,
                units: newValue.units,
                voiceOverHints: newValue.accessibility.voiceOverHints
            ))
        }
        snapshot = newValue
    }
}

public enum CanonicalGoalsEditorState: Equatable, Sendable {
    case loading
    case ready
    case saving(GoalType)
    case saved(GoalType)
    case failure(String)

    public var message: String? {
        switch self {
        case .loading: "Loading goals…"
        case .ready: nil
        case .saving: "Saving goal…"
        case .saved: "Goal saved."
        case .failure(let message): message
        }
    }
}

/// Package-owned editor that reads and writes only the injected APP-02A
/// GoalsRepository.  SettingsKit never mirrors these values into its own
/// SettingsSnapshot, which prevents the Settings route from becoming a
/// second source of truth.
@MainActor
public final class CanonicalGoalsEditorModel: ObservableObject {
    @Published public private(set) var goals: [Goal] = []
    @Published public private(set) var drafts: [GoalType: String] = [:]
    @Published public private(set) var enabled: [GoalType: Bool] = [:]
    @Published public private(set) var state: CanonicalGoalsEditorState = .loading

    private let repository: any GoalsRepository

    public init(repository: any GoalsRepository) {
        self.repository = repository
    }

    public func load() async {
        state = .loading
        do {
            let values = try await repository.readGoals()
            goals = values.sorted { $0.type.rawValue < $1.type.rawValue }
            var nextDrafts: [GoalType: String] = [:]
            var nextEnabled: [GoalType: Bool] = [:]
            for type in GoalType.allCases {
                if let goal = values.first(where: { $0.type == type }) {
                    nextDrafts[type] = Self.format(goal.target)
                    nextEnabled[type] = goal.isEnabled
                } else {
                    nextDrafts[type] = ""
                    nextEnabled[type] = true
                }
            }
            drafts = nextDrafts
            enabled = nextEnabled
            state = .ready
        } catch {
            state = .failure("Goals could not be loaded: " + error.localizedDescription)
        }
    }

    public func setDraft(_ value: String, for type: GoalType) {
        drafts[type] = value
    }

    public func setEnabled(_ value: Bool, for type: GoalType) {
        enabled[type] = value
    }

    public func save(_ type: GoalType) async {
        guard let raw = drafts[type]?.replacingOccurrences(of: ",", with: "."),
              let target = Double(raw), target.isFinite, target > 0 else {
            state = .failure("Enter a target greater than zero.")
            return
        }
        state = .saving(type)
        do {
            _ = try await repository.saveGoal(
                type: type,
                target: target,
                unit: Self.defaultUnit(for: type),
                isEnabled: enabled[type] ?? true
            )
            goals = (try await repository.readGoals()).sorted { $0.type.rawValue < $1.type.rawValue }
            state = .saved(type)
            if type == .sleep { NotificationCenter.default.post(name: SleepNeed.didChange, object: nil) }
        } catch {
            state = .failure("Goal could not be saved: " + error.localizedDescription)
        }
    }

    public static func defaultUnit(for type: GoalType) -> String {
        switch type {
        case .recovery: "%"
        case .sleep: "hours"
        case .strain: "strain"
        case .steps: "steps"
        case .workouts: "workouts"
        }
    }

    private static func format(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(value)
    }
}

public struct CanonicalGoalsEditorScreen: View {
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var model: CanonicalGoalsEditorModel
    private let accessibilityIdentifier: String

    /// `accessibilityIdentifier` lets the Today entry point keep the
    /// identifier its UI tests have always used for the goals screen.
    public init(repository: any GoalsRepository, accessibilityIdentifier: String = "settings-goals-editor") {
        _model = StateObject(wrappedValue: CanonicalGoalsEditorModel(repository: repository))
        self.accessibilityIdentifier = accessibilityIdentifier
    }

    public var body: some View {
        editorContent
        .navigationTitle("Goals")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(LooprAppearance.isDark(colorScheme) ? .dark : .light, for: .navigationBar)
        .tint(Color.loopr(.brand))
        .accessibilityIdentifier(accessibilityIdentifier)
        .task { await model.load() }
    }

    private var editorContent: some View {
        SettingsSheetSurface {
            ScrollView {
                VStack(alignment: .leading, spacing: LooprSpacing.lg) {
                    LooprFormCard {
                        LooprText(
                            "Your daily targets. Today and the coach both read them from here.",
                            style: .prose,
                            color: .inkSecondary
                        )
                    }

                    ForEach(GoalType.allCases, id: \.self) { type in
                        goalSection(type)
                    }

                    goalStatus
                }
                .padding(.horizontal, LooprSpacing.screenGutter)
                .padding(.top, 18)
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func goalSection(_ type: GoalType) -> some View {
        LooprSectionGroup(title: Self.title(for: type)) {
            LooprFormCard(padding: 0) {
                VStack(spacing: 0) {
                    TextField(
                        "Target",
                        text: Binding(
                            get: { model.drafts[type] ?? "" },
                            set: { model.setDraft($0, for: type) }
                        )
                    )
                    #if canImport(UIKit)
                    .keyboardType(.decimalPad)
                    #endif
                    .looprTypography(.settingsRow)
                    .foregroundStyle(Color.loopr(.ink))
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 17)
                    .padding(.vertical, 13)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("settings-goal-" + type.rawValue + "-target")

                    LooprHairline()

                    LabeledContent("Unit", value: CanonicalGoalsEditorModel.defaultUnit(for: type))
                        .looprTypography(.settingsRow)
                        .foregroundStyle(Color.loopr(.ink))
                        .padding(.horizontal, 17)
                        .padding(.vertical, 13)

                    LooprHairline()

                    Toggle(
                        isOn: Binding(
                            get: { model.enabled[type] ?? true },
                            set: { model.setEnabled($0, for: type) }
                        )
                    ) {
                        LooprText("Enabled", style: .settingsRow)
                    }
                    .tint(Color.loopr(.brand))
                    .padding(.horizontal, 17)
                    .padding(.vertical, 13)

                    LooprHairline()

                    Button("Save \(Self.title(for: type)) goal") {
                        Task { await model.save(type) }
                    }
                    .buttonStyle(LooprPrimaryButtonStyle())
                    .padding(.horizontal, 17)
                    .padding(.vertical, 13)
                    .accessibilityIdentifier("settings-goal-" + type.rawValue + "-save")
                }
            }
        }
    }

    @ViewBuilder
    private var goalStatus: some View {
        if let message = model.state.message {
            LooprFormCard {
                LooprText(
                    message,
                    style: .prose,
                    color: model.state.isFailure ? .critical : .inkSecondary
                )
                .accessibilityIdentifier("settings-goals-editor-status")
            }
        }
    }

    private static func title(for type: GoalType) -> String {
        switch type {
        case .recovery: "Recovery"
        case .sleep: "Sleep"
        case .strain: "Strain"
        case .steps: "Estimated steps"
        case .workouts: "Workouts"
        }
    }
}

private extension CanonicalGoalsEditorState {
    var isFailure: Bool {
        if case .failure = self { return true }
        return false
    }
}

public enum SettingsFixtures {
    public static let darkPrivate = SettingsSnapshot(
        profile: ProfileSettings(displayName: "Fixture", age: 34),
        units: .metric,
        appearance: .dark,
        surfacePrivacy: SurfacePrivacySettings(todayWidget: false, batteryWidget: true, watchSnapshot: false, liveActivity: false)
    )
}

public extension SettingsIntegrationState {
    var title: String {
        switch self {
        case .available: "Available"
        case .permissionRequired: "Permission needed"
        case .denied: "Permission denied"
        case .unavailable: "Unavailable"
        case .unsupported: "Not supported"
        case .recoverableError: "Temporarily unavailable"
        }
    }

    var detail: String {
        switch self {
        case .available: "This integration is ready to use."
        case .permissionRequired: "Allow access to enable this setting."
        case .denied: "Access was denied. Review permissions in system Settings."
        case .unavailable: "The owning platform adapter is not available in this build."
        case .unsupported: "This device or account does not support the integration."
        case .recoverableError(let message): message
        }
    }

    var symbol: String {
        switch self {
        case .available: "checkmark.circle"
        case .permissionRequired: "hand.raised"
        case .denied: "lock.slash"
        case .unavailable: "minus.circle"
        case .unsupported: "xmark.circle"
        case .recoverableError: "arrow.clockwise"
        }
    }
}

public struct SettingsScreen: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @ObservedObject private var viewModel: SettingsScreenViewModel
    private let route: (SettingsRouteDestination) -> Void
    private let releaseBuild: Bool
    private let bandSummary: String?
    private let wakeAlarmSummary: String?
    private let appVersion: String?
    @State private var isAdvancedExpanded = false
    /// Placeholder rows show only when loading takes longer than a blink, so
    /// a quick load never flashes grey bars.
    @State private var loadIsSlow = false
    private let developerRows: [LooprMenuItem]

    /// `developerRows` is for DEBUG-only tools the app composes. Release
    /// builds pass none, so the group never renders.
    public init(
        viewModel: SettingsScreenViewModel,
        route: @escaping (SettingsRouteDestination) -> Void = { _ in },
        releaseBuild: Bool = true,
        bandSummary: String? = nil,
        wakeAlarmSummary: String? = nil,
        appVersion: String? = nil,
        developerRows: [LooprMenuItem] = []
    ) {
        self.viewModel = viewModel
        self.route = route
        self.releaseBuild = releaseBuild
        self.bandSummary = bandSummary
        self.wakeAlarmSummary = wakeAlarmSummary
        self.appVersion = appVersion
        self.developerRows = developerRows
    }

    public var body: some View {
        SettingsSheetSurface {
            List {
                VStack(alignment: .leading, spacing: 0) {
                    Color.clear
                        .frame(height: 1)
                        .accessibilityElement()
                        .accessibilityLabel("Settings")
                        .accessibilityIdentifier("settings-screen")
                    VStack(alignment: .leading, spacing: LooprSpacing.lg) {
                        ForEach(SettingsMenu.sections(menuContext)) { section in
                            LooprMenuGroup(
                                title: section.title,
                                rows: section.entries.map(menuItem),
                                headingIdentifier: "settings-group-\(section.id)"
                            )
                        }

                        advancedGroup

                        #if DEBUG
                        if !developerRows.isEmpty {
                            LooprMenuGroup(title: "Developer", rows: developerRows)
                        }
                        #endif
                    }
                    .padding(.top, LooprSpacing.lg)
                    .padding(.horizontal, LooprSpacing.screenGutter)
                    .padding(.bottom, 32)
                    .redacted(reason: viewModel.isLoading && loadIsSlow ? .placeholder : [])
                    .animation(LooprMotion.phaseChange(reduceMotion: accessibilityReduceMotion), value: viewModel.isLoading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollIndicators(.hidden)
            .accessibilityIdentifier("settings-modal")
        }
        // Loading the snapshot is what pushes the stored appearance into the
        // design system. That store is not observable, so rows built during the
        // first pass keep the colours they resolved then. Ink stayed at its
        // light value on a dark panel. Rebuilding the subtree when the
        // appearance changes forces every token to resolve again.
        .id(appearanceIdentity)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(LooprAppearance.isDark(colorScheme) ? .dark : .light, for: .navigationBar)
        .tint(Color.loopr(.brand))
        // The diagnostics route is deliberately not a normal menu item. A
        // debug-only long press is the hidden entry point; release builds do
        // nothing even if a gesture is synthesized by UI automation.
        #if DEBUG
        .onLongPressGesture(minimumDuration: 1.5) {
            route(.hiddenDiagnostics)
        }
        #endif
        .overlay {
            if viewModel.isLoading {
                Color.clear
                    .allowsHitTesting(false)
                    .accessibilityElement()
                    .accessibilityLabel("Loading settings")
                    .accessibilityIdentifier("settings-loading")
            }
        }
        .task {
            try? await Task.sleep(for: .milliseconds(300))
            loadIsSlow = true
        }
    }

    private var menuContext: SettingsMenuContext {
        SettingsMenuContext(
            units: viewModel.snapshot.units,
            appearance: viewModel.snapshot.appearance,
            bandSummary: bandSummary,
            wakeAlarmSummary: wakeAlarmSummary,
            appVersion: appVersion
        )
    }

    private var appearanceIdentity: String {
        let accessibility = viewModel.snapshot.accessibility
        return [
            viewModel.snapshot.appearance.rawValue,
            String(accessibility.increasedContrastPreview),
            accessibility.reduceMotionOverride.map(String.init) ?? "system"
        ].joined(separator: "-")
    }

    private func menuItem(_ entry: SettingsMenuEntry) -> LooprMenuItem {
        // The app owns the Settings flow's NavigationStack. Routing through
        // the injected callback keeps package-owned destinations from being
        // appended as a second, type-erased path value in that stack.
        LooprMenuItem(
            title: entry.title,
            value: entry.value,
            accessibilityIdentifier: entry.accessibilityIdentifier,
            action: { route(entry.destination) }
        )
    }

    /// Diagnostics and resets are rarely needed, so they sit behind one row
    /// that expands in place instead of taking a group of their own.
    private var advancedGroup: some View {
        LooprFormCard(padding: LooprSpacing.none) {
            VStack(spacing: LooprSpacing.none) {
                Button {
                    withAnimation(accessibilityReduceMotion ? nil : LooprMotion.stateChange) { isAdvancedExpanded.toggle() }
                } label: {
                    HStack(alignment: .center, spacing: LooprSpacing.sm) {
                        LooprText(SettingsMenu.advanced.title, style: .settingsRow)
                        Spacer(minLength: LooprSpacing.sm)
                        Image(systemName: "chevron.down")
                            .looprTypography(.metricUnit)
                            .foregroundStyle(Color.loopr(.inkMuted))
                            .rotationEffect(.degrees(isAdvancedExpanded ? 180 : 0))
                            .accessibilityHidden(true)
                    }
                    .padding(.horizontal, LooprSpacing.formCardPadding)
                    .padding(.vertical, LooprSpacing.formRowVerticalPadding)
                    .frame(maxWidth: .infinity, minHeight: LooprSpacing.interactiveRowHeight, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(SettingsMenu.advanced.title)
                .accessibilityValue(isAdvancedExpanded ? "Expanded" : "Collapsed")
                .accessibilityHint("Shows diagnostics and reset options.")
                .accessibilityIdentifier("settings-advanced")

                if isAdvancedExpanded {
                    ForEach(SettingsMenu.advanced.entries) { entry in
                        LooprHairline()
                        Button { route(entry.destination) } label: {
                            HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.sm) {
                                LooprText(entry.title, style: .settingsRow)
                                Spacer(minLength: LooprSpacing.sm)
                                LooprChevron()
                            }
                            .padding(.leading, LooprSpacing.formCardPadding + LooprSpacing.sm)
                            .padding(.trailing, LooprSpacing.formCardPadding)
                            .padding(.vertical, LooprSpacing.formRowVerticalPadding)
                            .frame(maxWidth: .infinity, minHeight: LooprSpacing.interactiveRowHeight, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(entry.title), Opens details")
                        .accessibilityIdentifier(entry.accessibilityIdentifier)
                    }
                }
            }
        }
    }
}

public struct SettingsDestinationScreen: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL
    @Environment(\.profileAgeFocusRequested) private var profileAgeFocusRequested
    @FocusState private var ageFieldFocused: Bool
    public let destination: SettingsRouteDestination
    public let snapshot: SettingsSnapshot
    public let versions: VersionRegistry
    public let integrationState: SettingsIntegrationState
    public let onSave: (SettingsSnapshot) -> Void
    public let onResetProfile: () -> Void
    public let onResetAll: () -> Void
    public let onRequestPermission: () -> Void
    public let onSetAIPrivacy: (Bool) -> Void
    public let notificationPreferences: [NotificationPreferenceSetting]
    public let onSetNotificationPreference: (String, Bool) -> Void
    public let releaseBuild: Bool
    public let canonicalGoalsRepository: (any GoalsRepository)?
    /// True while the owning view model is still reading storage. Saving
    /// during that window would write the empty starting snapshot over the
    /// stored settings, so the save control stays disabled until the real
    /// values have arrived.
    public let isLoading: Bool
    @State private var isResetConfirmationPresented = false
    @State private var isDeleteConfirmationPresented = false
    @State private var form: SettingsFormState
    @State private var aiEnabled = false
    @State private var localNotificationPreferences: [NotificationPreferenceSetting]

    /// The unit the form is currently set to, not the saved one, so the height
    /// and weight fields follow the picker as soon as it moves.
    private var measurementSystem: LooprMeasurementSystem {
        form.snapshot.units.looprMeasurementSystem
    }

    public init(
        destination: SettingsRouteDestination,
        snapshot: SettingsSnapshot = SettingsFixtures.darkPrivate,
        versions: VersionRegistry = VersionRegistry(appVersion: "Unavailable", algorithmVersion: 0, protocolVersion: "Unavailable"),
        integrationState: SettingsIntegrationState = .unavailable,
        onSave: @escaping (SettingsSnapshot) -> Void = { _ in },
        onResetProfile: @escaping () -> Void = {},
        onResetAll: @escaping () -> Void = {},
        onRequestPermission: @escaping () -> Void = {},
        onSetAIPrivacy: @escaping (Bool) -> Void = { _ in },
        notificationPreferences: [NotificationPreferenceSetting] = [],
        onSetNotificationPreference: @escaping (String, Bool) -> Void = { _, _ in },
        releaseBuild: Bool = true,
        canonicalGoalsRepository: (any GoalsRepository)? = nil,
        isLoading: Bool = false
    ) {
        self.destination = destination
        self.snapshot = snapshot
        self.versions = versions
        self.integrationState = integrationState
        self.onSave = onSave
        self.onResetProfile = onResetProfile
        self.onResetAll = onResetAll
        self.onRequestPermission = onRequestPermission
        self.onSetAIPrivacy = onSetAIPrivacy
        self.notificationPreferences = notificationPreferences
        self.onSetNotificationPreference = onSetNotificationPreference
        self.releaseBuild = releaseBuild
        self.canonicalGoalsRepository = canonicalGoalsRepository
        self.isLoading = isLoading
        _form = State(initialValue: SettingsFormState(snapshot: snapshot))
        _localNotificationPreferences = State(initialValue: notificationPreferences)
    }

    public var body: some View {
        destinationSurface
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(LooprAppearance.isDark(colorScheme) ? .dark : .light, for: .navigationBar)
        .tint(Color.loopr(.brand))
        .accessibilityIdentifier("settings-destination-\(String(describing: destination))")
        .confirmationDialog("Reset profile and goals?", isPresented: $isResetConfirmationPresented, titleVisibility: .visible) {
            Button("Reset profile", role: .destructive, action: onResetProfile)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This clears your profile and goals but keeps device history.")
        }
        .confirmationDialog("Delete all Loopr data?", isPresented: $isDeleteConfirmationPresented, titleVisibility: .visible) {
            Button("Delete all data", role: .destructive, action: onResetAll)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes Loopr-owned data. HealthKit requires a separate explicit action.")
        }
        .onChange(of: notificationPreferences) { _, value in
            localNotificationPreferences = value
        }
        // The owning view model starts on an empty snapshot and fills it in
        // from storage after the first render, so the form has to take the
        // loaded values when they land.
        .onChange(of: snapshot) { _, value in
            form.adopt(value)
        }
        .task {
            if destination == .profile && profileAgeFocusRequested {
                ageFieldFocused = true
            }
        }
    }

    @ViewBuilder
    private var destinationSurface: some View {
        if destination == .goals, canonicalGoalsRepository != nil {
            canonicalGoals
        } else {
            SettingsSheetSurface {
                ScrollView {
                    VStack(alignment: .leading, spacing: LooprSpacing.lg) {
                        destinationContent
                    }
                    .padding(.horizontal, LooprSpacing.screenGutter)
                    .padding(.top, 18)
                    .padding(.bottom, 32)
                }
                .scrollIndicators(.hidden)
                .scrollDismissesKeyboard(.interactively)
            }
        }
    }

    @ViewBuilder
    private var destinationContent: some View {
        switch destination {
        case .profile:
            LooprSectionGroup(title: "Profile") { profile }
        case .units:
            LooprSectionGroup(title: "Profile, units and goals") {
                VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                    LooprFormCard(padding: 0) {
                        Picker("Units", selection: Binding(
                            get: { form.snapshot.units },
                            set: { newValue in form.edit { $0.units = newValue } }
                        )) {
                            ForEach(UnitSystem.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                        }
                        .tint(Color.loopr(.brand))
                        .looprTypography(.settingsRow)
                        .padding(.horizontal, 17)
                        .padding(.vertical, 13)
                    }
                    saveButton
                }
            }
        case .appearance:
            LooprSectionGroup(title: "Appearance and accessibility") {
                VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                    LooprFormCard(padding: 0) {
                        Picker("Appearance", selection: Binding(
                            get: { form.snapshot.appearance },
                            set: { newValue in form.edit { $0.appearance = newValue } }
                        )) {
                            ForEach(AppearanceChoice.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                        }
                        .tint(Color.loopr(.brand))
                        .looprTypography(.settingsRow)
                        .padding(.horizontal, 17)
                        .padding(.vertical, 13)
                    }
                    saveButton
                }
            }
        case .accessibility:
            LooprSectionGroup(title: "Appearance and accessibility") {
                VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                    LooprFormCard(padding: 0) {
                        VStack(spacing: 0) {
                            Toggle(isOn: Binding(
                                get: { form.snapshot.accessibility.increasedContrastPreview },
                                set: { newValue in form.edit { $0.accessibility.increasedContrastPreview = newValue } }
                            )) {
                                LooprText("Increased contrast preview", style: .settingsRow)
                            }
                            .tint(Color.loopr(.brand))
                            .padding(.horizontal, 17)
                            .padding(.vertical, 13)

                            LooprHairline()

                            Toggle(isOn: Binding(
                                get: { form.snapshot.accessibility.voiceOverHints },
                                set: { newValue in form.edit { $0.accessibility.voiceOverHints = newValue } }
                            )) {
                                LooprText("VoiceOver hints", style: .settingsRow)
                            }
                            .tint(Color.loopr(.brand))
                            .padding(.horizontal, 17)
                            .padding(.vertical, 13)
                        }
                    }
                    saveButton
                }
            }
        case .goals:
            LooprSectionGroup(title: "Profile") { canonicalGoalsNotice }
        case .privacy, .surfacePrivacy:
            LooprSectionGroup(title: "Privacy") { privacy }
        case .healthKit:
            LooprSectionGroup(title: "Health and data") {
                integrationSurface(title: "Apple Health", symbol: "heart.text.square")
            }
        case .notifications:
            LooprSectionGroup(title: "Alerts and notifications") {
                VStack(alignment: .leading, spacing: LooprSpacing.lg) {
                    integrationSurface(title: "Notifications", symbol: "bell.badge")
                    notificationPreferenceControls
                }
            }
        case .aiPrivacy:
            LooprSectionGroup(title: "Privacy") { aiPrivacy }
        case .deviceCenter, .cycle, .dataHistory, .importExport, .wakeAlarm, .dataControls, .heartAlerts:
            LooprSectionGroup(title: "Data") {
                LooprFormCard {
                    LooprText(
                        "This route is owned by its package and is opened from the Settings flow.",
                        style: .prose,
                        color: .inkSecondary
                    )
                }
            }
        case .versions:
            LooprSectionGroup(title: "About") {
                LooprFormCard(padding: 0) {
                    VStack(spacing: 0) {
                        settingsValueRow("App", value: versions.appVersion)
                        LooprHairline()
                        settingsValueRow("Algorithm", value: "v\(versions.algorithmVersion)")
                        LooprHairline()
                        settingsValueRow("Protocol", value: versions.protocolVersion)
                    }
                }
            }
        case .legal:
            LooprMenuGroup(title: "Documents", rows: SettingsLegalDocuments.all.map { document in
                LooprMenuItem(
                    title: document.title,
                    accessibilityIdentifier: document.accessibilityIdentifier,
                    action: { openURL(document.url) }
                )
            })
            LooprSectionGroup(title: "About") { legalNotices }
        case .support:
            LooprSectionGroup(title: "About") {
                LooprFormCard {
                    LooprText(
                        "Support is local-first. Export a diagnostics bundle from Device Center before contacting support.",
                        style: .prose,
                        color: .inkSecondary
                    )
                }
            }
        case .diagnostics, .hiddenDiagnostics:
            hiddenDiagnostics
        }
    }

    private var notificationPreferenceControls: some View {
        LooprSectionGroup(title: "Alerts") {
            LooprFormCard(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(localNotificationPreferences.enumerated()), id: \.element.id) { index, preference in
                        Toggle(isOn: Binding(
                            get: { localNotificationPreferences.first(where: { $0.id == preference.id })?.isEnabled ?? false },
                            set: { enabled in
                                guard let index = localNotificationPreferences.firstIndex(where: { $0.id == preference.id }) else { return }
                                localNotificationPreferences[index] = NotificationPreferenceSetting(
                                    id: preference.id,
                                    title: preference.title,
                                    isEnabled: enabled
                                )
                                onSetNotificationPreference(preference.id, enabled)
                            }
                        )) {
                            LooprText(preference.title, style: .settingsRow)
                        }
                        .tint(Color.loopr(.brand))
                        .padding(.horizontal, 17)
                        .padding(.vertical, 13)
                        .accessibilityIdentifier("settings-notification-\(preference.id)")

                        if index < localNotificationPreferences.count - 1 {
                            LooprHairline()
                        }
                    }
                }
            }
        }
    }

    private var title: String {
        switch destination {
        case .profile: "Profile"
        case .units: "Units"
        case .appearance: "Appearance"
        case .accessibility: "Accessibility"
        case .goals: "Goals"
        case .privacy: "Widgets and Watch"
        case .surfacePrivacy: "Widgets and Watch"
        case .deviceCenter: "Device Center"
        case .healthKit: "Apple Health"
        case .notifications: "Notifications"
        case .cycle: "Cycle tracking"
        case .aiPrivacy: "AI and privacy"
        case .dataHistory: "Data history"
        case .importExport: "Import and export"
        case .versions: "Versions"
        case .legal: "Legal and licenses"
        case .support: "Support"
        case .diagnostics: "Diagnostics"
        case .hiddenDiagnostics: "Hidden diagnostics"
        case .wakeAlarm: "Wake alarm"
        case .dataControls: "Reset and delete"
        case .heartAlerts: "Heart alerts"
        }
    }

    private var canonicalGoalsNotice: some View {
        LooprSectionGroup(title: "Goals") {
            LooprFormCard {
                VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                    LooprText("Goals cannot be edited right now.", style: .settingsRow)
                        .accessibilityIdentifier("settings-goals-owner")
                    LooprText("Loopr could not open the store that holds your goals. Close Settings and try again.", style: .prose, color: .inkSecondary)
                }
            }
        }
    }

    @ViewBuilder
    private var canonicalGoals: some View {
        if let canonicalGoalsRepository {
            CanonicalGoalsEditorScreen(repository: canonicalGoalsRepository)
        } else {
            canonicalGoalsNotice
        }
    }

    private var profile: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.sm) {
            LooprFormCard(padding: 0) {
                VStack(spacing: 0) {
                    TextField("Display name", text: Binding(
                        get: { form.snapshot.profile.displayName ?? "" },
                        set: { newValue in form.edit { $0.profile.displayName = newValue.isEmpty ? nil : newValue } }
                    ))
                    .looprTypography(.settingsRow)
                    .foregroundStyle(Color.loopr(.ink))
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 17)
                    .padding(.vertical, 13)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("settings-profile-name")

                    LooprHairline()

                    TextField("Age", text: Binding(
                        get: { form.snapshot.profile.age.map(String.init) ?? "" },
                        set: { newValue in form.edit { $0.profile.age = Int(newValue) } }
                    ))
                    .focused($ageFieldFocused)
                    #if canImport(UIKit)
                    .keyboardType(.numberPad)
                    #endif
                    .looprTypography(.settingsRow)
                    .foregroundStyle(Color.loopr(.ink))
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 17)
                    .padding(.vertical, 13)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("settings-profile-age")

                    LooprHairline()

                    // Active energy cannot be computed without height and
                    // weight, and onboarding was the only place that ever
                    // asked for them. Anyone who skipped it had no way back.
                    TextField(LooprUnitFormatter.heightFieldLabel(measurementSystem), text: Binding(
                        get: {
                            LooprUnitFormatter.heightFieldText(
                                centimeters: form.snapshot.profile.heightCentimeters,
                                system: measurementSystem
                            )
                        },
                        set: { newValue in
                            form.edit {
                                $0.profile.heightCentimeters = LooprUnitFormatter.heightCentimeters(
                                    fromField: newValue,
                                    system: measurementSystem
                                )
                            }
                        }
                    ))
                    #if canImport(UIKit)
                    .keyboardType(.decimalPad)
                    #endif
                    .looprTypography(.settingsRow)
                    .foregroundStyle(Color.loopr(.ink))
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 17)
                    .padding(.vertical, 13)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("settings-profile-height")

                    LooprHairline()

                    TextField(LooprUnitFormatter.weightFieldLabel(measurementSystem), text: Binding(
                        get: {
                            LooprUnitFormatter.weightFieldText(
                                kilograms: form.snapshot.profile.weightKilograms,
                                system: measurementSystem
                            )
                        },
                        set: { newValue in
                            form.edit {
                                $0.profile.weightKilograms = LooprUnitFormatter.weightKilograms(
                                    fromField: newValue,
                                    system: measurementSystem
                                )
                            }
                        }
                    ))
                    #if canImport(UIKit)
                    .keyboardType(.decimalPad)
                    #endif
                    .looprTypography(.settingsRow)
                    .foregroundStyle(Color.loopr(.ink))
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 17)
                    .padding(.vertical, 13)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("settings-profile-weight")

                    if let canonicalGoalsRepository {
                        LooprHairline()
                        SleepNeedSetting(repository: canonicalGoalsRepository)
                    }
                }
            }

            saveButton

            Button("Reset profile", role: .destructive) { isResetConfirmationPresented = true }
                .buttonStyle(LooprDestructiveButtonStyle())
                .accessibilityIdentifier("settings-reset-profile")
        }
    }

    private var privacy: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.sm) {
            LooprFormCard(padding: 0) {
                VStack(spacing: 0) {
                    privacyToggle("Today widget", isOn: Binding(
                        get: { form.snapshot.surfacePrivacy.todayWidget },
                        set: { newValue in form.edit { $0.surfacePrivacy.todayWidget = newValue } }
                    ))

                    LooprHairline()

                    privacyToggle("Battery widget", isOn: Binding(
                        get: { form.snapshot.surfacePrivacy.batteryWidget },
                        set: { newValue in form.edit { $0.surfacePrivacy.batteryWidget = newValue } }
                    ))

                    LooprHairline()

                    privacyToggle("Watch snapshot", isOn: Binding(
                        get: { form.snapshot.surfacePrivacy.watchSnapshot },
                        set: { newValue in form.edit { $0.surfacePrivacy.watchSnapshot = newValue } }
                    ))

                    LooprHairline()

                    privacyToggle("Live Activity", isOn: Binding(
                        get: { form.snapshot.surfacePrivacy.liveActivity },
                        set: { newValue in form.edit { $0.surfacePrivacy.liveActivity = newValue } }
                    ))
                }
            }

            LooprFormCard {
                LooprText(
                    "Loopr stores health data on this iPhone. Apple Health saves what you allow. This build does not send AI requests. Database backups can include journal and route data.",
                    style: .prose,
                    color: .inkSecondary
                )
            }

            saveButton

            Button("Delete all Loopr data", role: .destructive) { isDeleteConfirmationPresented = true }
                .buttonStyle(LooprDestructiveButtonStyle())
                .accessibilityIdentifier("settings-delete-all")
        }
    }

    private func integrationSurface(title: String, symbol: String) -> some View {
        LooprSectionGroup(title: title) {
            LooprFormCard {
                VStack(alignment: .leading, spacing: LooprSpacing.md) {
                    Label {
                        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                            LooprText(integrationState.title, style: .rowTitle)
                            LooprText(integrationState.detail, style: .prose, color: .inkSecondary)
                        }
                    } icon: {
                        Image(systemName: integrationState.symbol)
                            .foregroundStyle(Color.loopr(integrationState == .available ? .recovery : .warning))
                    }

                    if integrationState == .permissionRequired {
                        Button("Allow \(title) access", action: onRequestPermission)
                            .buttonStyle(LooprPrimaryButtonStyle())
                            .accessibilityIdentifier("settings-\(destination)-request-permission")
                    }
                }
            }
        }
        .accessibilityIdentifier("settings-\(destination)-surface")
    }

    private var aiPrivacy: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.lg) {
            LooprFormCard(padding: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    Toggle(isOn: Binding(
                        get: { aiEnabled },
                        set: {
                            guard integrationState == .available else {
                                aiEnabled = false
                                return
                            }
                            aiEnabled = $0
                            onSetAIPrivacy($0)
                        }
                    )) {
                        LooprText("Allow private AI suggestions", style: .settingsRow)
                    }
                    .tint(Color.loopr(.brand))
                    .disabled(integrationState != .available)
                    .accessibilityHint(integrationState == .available ? "Double tap to change AI privacy." : integrationState.detail)
                    .padding(.horizontal, 17)
                    .padding(.vertical, 13)

                    LooprHairline()

                    LooprText(
                        "AI suggestions are optional and must never write journal content without explicit review.",
                        style: .prose,
                        color: .inkSecondary
                    )
                    .padding(17)
                }
            }

            integrationSurface(title: "AI and privacy", symbol: "wand.and.stars")
        }
    }

    private var hiddenDiagnostics: some View {
        Group {
            #if DEBUG
            if releaseBuild {
                LooprFormCard {
                    LooprText(
                        "Hidden diagnostics are unavailable in release builds.",
                        style: .prose,
                        color: .inkSecondary
                    )
                    .accessibilityIdentifier("settings-hidden-diagnostics-unavailable")
                }
            } else {
                LooprSectionGroup(title: "Developer diagnostics") {
                    LooprFormCard {
                        LooprText(
                            "Detailed capture, storage, and analysis status is not connected in this build.",
                            style: .prose,
                            color: .inkSecondary
                        )
                        .accessibilityIdentifier("settings-hidden-diagnostics")
                    }
                }
            }
            #else
            LooprFormCard {
                LooprText(
                    "Hidden diagnostics are unavailable in release builds.",
                    style: .prose,
                    color: .inkSecondary
                )
                .accessibilityIdentifier("settings-hidden-diagnostics-unavailable")
            }
            #endif
        }
    }

    private var saveButton: some View {
        Button(destination == .profile ? "Save profile" : "Save changes") {
            onSave(form.snapshot)
            form.markSubmitted()
        }
            .buttonStyle(LooprPrimaryButtonStyle())
            .disabled(isLoading)
            .accessibilityIdentifier("settings-save")
    }

    private func privacyToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            LooprText(title, style: .settingsRow)
        }
        .tint(Color.loopr(.brand))
        .padding(.horizontal, 17)
        .padding(.vertical, 13)
    }

    private func settingsValueRow(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.sm) {
            LooprText(title, style: .settingsRow)
            Spacer(minLength: LooprSpacing.sm)
            LooprText(value, style: .metricUnit, color: .inkMuted)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 17)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var legalNotices: some View {
        LooprFormCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(SettingsLicenseCatalog.notices.enumerated()), id: \.element.name) { index, notice in
                    VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                        LooprText(notice.name, style: .rowTitle)
                        LooprText(notice.text, style: .prose, color: .inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 17)
                    .padding(.vertical, 13)

                    if index < SettingsLicenseCatalog.notices.count - 1 {
                        LooprHairline()
                    }
                }
            }
        }
    }

}

/// The Settings flow is already inside a presented sheet with its own card,
/// corner radius, and toolbar. Drawing a second rounded panel inset below the
/// toolbar stacked two sheet edges on top of each other and left the content
/// floating under a seam. This is a plain background: one surface that runs the
/// full height of the real sheet, with the brand glow behind the toolbar.
private struct SettingsSheetSurface<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background {
                backdrop.ignoresSafeArea()
            }
    }

    private var backdrop: some View {
        ZStack(alignment: .top) {
            Color.loopr(.settingsBackground)

            RadialGradient(
                colors: [Color.loopr(.brand).opacity(0.08), .clear],
                center: .top,
                startRadius: 0,
                endRadius: 360
            )
            .frame(height: 280)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityHidden(true)
    }
}
