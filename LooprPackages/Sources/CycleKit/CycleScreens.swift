import Combine
import SwiftUI
import DesignSystem

public enum CycleRoute: Hashable, Sendable, CaseIterable {
    case overview
    case log
    case reminders
    case export
}

public enum CycleScreenStateFixtures {
    public static let allStates = MetricState.allCases
    public static let accessibilityIdentifiers = ["cycle-screen", "cycle-opt-in", "cycle-log", "cycle-reminders"]
    public static let statesByScreen = Dictionary(uniqueKeysWithValues: accessibilityIdentifiers.map { ($0, allStates) })
    public static func accessibilitySummary(for state: MetricState) -> String { "\(state.title). \(state.detail)" }
}

@MainActor
public final class CycleViewModel: ObservableObject {
    @Published public private(set) var snapshot: CycleScreenSnapshot
    @Published public private(set) var history: [CycleEntry] = []
    @Published public private(set) var settings = CycleSettings()
    @Published public private(set) var export: CycleExport?
    @Published public private(set) var actionError: CycleError?
    private let repository: (any CycleStore)?
    private let reminderScheduler: any CycleReminderScheduler
    private let exportWriter: any CycleExportWriter

    public init(
        repository: (any CycleStore)? = nil,
        reminderScheduler: any CycleReminderScheduler = UnavailableCycleReminderScheduler(),
        exportWriter: any CycleExportWriter = LocalCycleExportWriter()
    ) {
        self.repository = repository
        self.reminderScheduler = reminderScheduler
        self.exportWriter = exportWriter
        snapshot = CycleScreenSnapshot(state: .loading, estimate: CycleEstimate(phase: .unknown, confidence: 0, uncertainty: "Loading", sampleSize: 0))
    }

    @discardableResult
    public func load(today: String? = nil) async -> Bool {
        guard let repository else {
            snapshot = CycleScreenSnapshot(state: .optedOut, estimate: CycleEstimate(phase: .unknown, confidence: 0, uncertainty: "Cycle tracking is not enabled.", sampleSize: 0))
            return true
        }
        do {
            history = try await repository.history()
            settings = try await repository.currentSettings()
            snapshot = CycleScreenSnapshot(
                state: try await repository.state(),
                estimate: try await repository.estimate(today: today)
            )
            actionError = nil
            return true
        } catch let error as CycleError {
            actionError = error
        } catch {
            actionError = .storageUnavailable
        }
        snapshot = CycleScreenSnapshot(state: .error, estimate: snapshot.estimate)
        return false
    }

    @discardableResult
    public func optIn() async -> Bool {
        guard let repository else { actionError = .optedOut; return false }
        do {
            try await repository.optIn()
            actionError = nil
            return await load()
        } catch let error as CycleError {
            actionError = error
        } catch {
            actionError = .storageUnavailable
        }
        return false
    }

    public func log(_ entry: CycleEntry, today: String? = nil) async {
        guard let repository else { actionError = .optedOut; return }
        do {
            try await repository.optIn()
            _ = try await repository.log(entry)
            actionError = nil
            _ = await load(today: today)
        } catch let error as CycleError {
            actionError = error
        } catch {
            actionError = .storageUnavailable
        }
    }

    public func updateReminders(enabled: Bool, hour: Int) async {
        guard (0...23).contains(hour) else { actionError = .invalidReminderHour; return }
        guard let repository else { actionError = .optedOut; return }
        let newSettings = CycleSettings(remindersEnabled: enabled, reminderHour: enabled ? hour : nil)
        do {
            if enabled {
                try await reminderScheduler.schedule(settings: newSettings)
            } else {
                try await reminderScheduler.cancel()
            }
        } catch let error as CycleError {
            actionError = error
            return
        } catch {
            actionError = .reminderUnavailable
            return
        }
        do {
            try await repository.updateSettings(newSettings)
            settings = newSettings
            actionError = nil
        } catch let error as CycleError {
            actionError = error
        } catch {
            actionError = .storageUnavailable
        }
        if actionError != nil, enabled {
            do {
                try await reminderScheduler.cancel()
            } catch {
                actionError = .reminderCleanupFailed
            }
        } else if actionError != nil, !enabled, settings.remindersEnabled {
            do {
                try await reminderScheduler.schedule(settings: settings)
            } catch {
                actionError = .reminderRestoreFailed
            }
        }
    }

    public func disable() async {
        guard let repository else { actionError = .optedOut; return }
        let previousSettings: CycleSettings
        do {
            previousSettings = try await repository.currentSettings()
        } catch let error as CycleError {
            actionError = error
            return
        } catch {
            actionError = .storageUnavailable
            return
        }
        do {
            try await reminderScheduler.cancel()
        } catch let error as CycleError {
            actionError = error
            return
        } catch {
            actionError = .reminderCleanupFailed
            return
        }
        do {
            try await repository.disable()
            actionError = nil
            _ = await load()
        } catch let error as CycleError {
            actionError = error
            await restoreReminderIfNeeded(previousSettings)
        } catch {
            actionError = .storageUnavailable
            await restoreReminderIfNeeded(previousSettings)
        }
    }

    public func deleteAll() async {
        guard let repository else { return }
        let previousSettings = try? await repository.currentSettings()
        var reminderCleanupFailed = false
        do {
            try await reminderScheduler.cancel()
        } catch {
            reminderCleanupFailed = true
        }
        do {
            try await repository.deleteAll()
            actionError = nil
            _ = await load()
            if reminderCleanupFailed {
                actionError = .reminderCleanupFailed
            }
        } catch let error as CycleError {
            actionError = error
            if !reminderCleanupFailed, let previousSettings {
                await restoreReminderIfNeeded(previousSettings)
            }
        } catch {
            actionError = .storageUnavailable
            if !reminderCleanupFailed, let previousSettings {
                await restoreReminderIfNeeded(previousSettings)
            }
        }
    }

    public func prepareExport() async {
        guard let repository else { actionError = .optedOut; return }
        do {
            let value = try await repository.export()
            _ = try await exportWriter.write(value)
            export = value
            actionError = nil
        } catch {
            actionError = .exportUnavailable
        }
    }

    private func restoreReminderIfNeeded(_ previousSettings: CycleSettings) async {
        guard previousSettings.remindersEnabled else { return }
        do {
            try await reminderScheduler.schedule(settings: previousSettings)
        } catch {
            actionError = .reminderRestoreFailed
        }
    }
}

public enum CycleFixtures {
    public static let optedInEstimate = CycleEstimate(
        phase: .follicular,
        nextPeriodDay: "2026-09-23",
        fertileWindow: "2026-09-05"..."2026-09-11",
        ovulationDay: "2026-09-09",
        confidence: 0.66,
        uncertainty: "Estimate from logged period starts; dates may vary.",
        sampleSize: 2
    )
}

public struct CycleScreen: View {
    @ObservedObject private var viewModel: CycleViewModel
    private let route: (CycleRoute) -> Void

    public init(viewModel: CycleViewModel, route: @escaping (CycleRoute) -> Void = { _ in }) {
        self.viewModel = viewModel
        self.route = route
    }

    public var body: some View {
        LooprDetailScaffold {
            VStack(alignment: .leading, spacing: LooprSpacing.lg) {
                stateContent

                if showsNavigation {
                    navigationRows
                }

                if let error = viewModel.actionError {
                    LooprSectionGroup(title: "Status") {
                        LooprFormCard {
                            LooprInlineMessage(error.localizedDescription, tone: .critical)
                                .accessibilityIdentifier("cycle-action-error")
                        }
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
        .navigationTitle("Cycle")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .tint(Color.loopr(.cycle))
        .accessibilityIdentifier("cycle-screen")
    }

    @ViewBuilder
    private var stateContent: some View {
        switch viewModel.snapshot.state {
        case .loading:
            loadingState
        case .optedOut:
            optIn
        case .disabled:
            disabledState
        case .empty, .optedIn:
            emptyState
        case .populated:
            phaseHero
        case .unavailable, .error:
            unavailableState
        }
    }

    private var showsNavigation: Bool {
        switch viewModel.snapshot.state {
        case .empty, .optedIn, .populated:
            true
        default:
            false
        }
    }

    private var loadingState: some View {
        LooprSurface(emphasis: .hero(.cycle)) {
            VStack(alignment: .leading, spacing: LooprSpacing.md) {
                LooprSkeleton()
                LooprSkeleton(height: LooprSpacing.xxl)
                LooprSkeleton(height: LooprSpacing.sm)
            }
        }
    }

    private var optIn: some View {
        LooprSurface(emphasis: .hero(.cycle)) {
            VStack(alignment: .leading, spacing: LooprSpacing.md) {
                LooprText("Cycle tracking is optional", style: .title)
                LooprText(
                    "Nothing is inferred until you opt in and log a period start. Estimates are not medical predictions.",
                    style: .prose,
                    color: .inkSecondary
                )
                Button("Review and opt in") { route(.overview) }
                    .buttonStyle(LooprPrimaryButtonStyle(accent: .cycle))
                    .accessibilityIdentifier("cycle-opt-in")
            }
        }
    }

    private var disabledState: some View {
        LooprSurface(emphasis: .hero(.cycle)) {
            VStack(alignment: .leading, spacing: LooprSpacing.md) {
                LooprInlineMessage("Cycle tracking is disabled.", tone: .neutral)
                LooprText(
                    "Your logged history stays saved until you delete it.",
                    style: .prose,
                    color: .inkSecondary
                )
            }
        }
    }

    private var emptyState: some View {
        LooprSurface(emphasis: .hero(.cycle)) {
            VStack(alignment: .leading, spacing: LooprSpacing.md) {
                StateMessage(.absent, compact: true)
                LooprText("Log a period start to begin.", style: .title)
                LooprText(
                    viewModel.snapshot.estimate.uncertainty,
                    style: .prose,
                    color: .inkSecondary
                )
            }
        }
    }

    private var unavailableState: some View {
        LooprSurface(emphasis: .hero(.cycle)) {
            VStack(alignment: .leading, spacing: LooprSpacing.md) {
                StateMessage(.recoverableError)
                Button("Try again") {
                    Task { _ = await viewModel.load() }
                }
                .buttonStyle(LooprButtonStyle(prominent: false))
                .accessibilityIdentifier("cycle-retry")
            }
        }
    }

    private var phaseHero: some View {
        let estimate = viewModel.snapshot.estimate

        return LooprSurface(emphasis: .hero(.cycle)) {
            VStack(alignment: .leading, spacing: LooprSpacing.md) {
                HStack(alignment: .center, spacing: LooprSpacing.sm) {
                    LooprText("CURRENT PHASE", style: .sectionLabel, color: .inkSecondary)
                    Spacer(minLength: LooprSpacing.sm)
                    StatusChip(phaseName, symbol: "circle.fill", accent: .cycle)
                }

                LooprText(phaseName, style: .titleLarge, color: .cycle)

                if let nextPeriodDay = estimate.nextPeriodDay {
                    phaseValueRow(title: "Next period", value: nextPeriodDay, accent: .cycle)
                }

                if estimate.sampleSize >= 2, let fertileWindow = estimate.fertileWindow {
                    phaseValueRow(
                        title: "Fertile window",
                        value: "\(fertileWindow.lowerBound) to \(fertileWindow.upperBound)",
                        accent: .cyclePlum
                    )
                } else {
                    phaseValueRow(
                        title: "Fertile window",
                        value: MetricState.absent.title,
                        accent: .inkSecondary
                    )
                }

                if estimate.sampleSize >= 2, let ovulationDay = estimate.ovulationDay {
                    phaseValueRow(title: "Ovulation", value: ovulationDay, accent: .cyclePlum)
                } else {
                    phaseValueRow(
                        title: "Ovulation",
                        value: MetricState.absent.title,
                        accent: .inkSecondary
                    )
                }

                LooprText(estimate.uncertainty, style: .prose, color: .inkSecondary)

                if let confidenceLine {
                    LooprText(confidenceLine, style: .confidence, color: .inkSecondary)
                }
            }
        }
    }

    private func phaseValueRow(title: String, value: String, accent: LooprColorToken) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.sm) {
            LooprText(title, style: .rowTitle)
            Spacer(minLength: LooprSpacing.sm)
            LooprText(value, style: .metricUnit, color: accent)
                .multilineTextAlignment(.trailing)
        }
    }

    private var phaseName: String {
        viewModel.snapshot.estimate.phase.rawValue.capitalized
    }

    private var confidenceLine: String? {
        let estimate = viewModel.snapshot.estimate
        guard estimate.sampleSize > 0 else { return nil }
        let confidence = Int((min(max(estimate.confidence, 0), 1) * 100).rounded())
        let startsLabel = estimate.sampleSize == 1 ? "LOGGED START" : "LOGGED STARTS"
        return "\(confidence)% CONFIDENCE · \(estimate.sampleSize) \(startsLabel)"
    }

    private var navigationRows: some View {
        LooprSectionGroup(title: "Manage") {
            LooprFormCard(padding: LooprSpacing.none) {
                VStack(spacing: LooprSpacing.none) {
                    navigationRow(
                        title: "Log symptoms or flow",
                        subtitle: "Record a cycle event",
                        symbol: "plus.circle",
                        destination: .log,
                        identifier: "cycle-log"
                    )
                    LooprHairline()
                    navigationRow(
                        title: "Reminders",
                        subtitle: "Optional local reminders",
                        symbol: "bell",
                        destination: .reminders,
                        identifier: "cycle-reminders"
                    )
                    LooprHairline()
                    navigationRow(
                        title: "Export",
                        subtitle: "Prepare a private local export",
                        symbol: "square.and.arrow.up",
                        destination: .export,
                        identifier: "cycle-export"
                    )
                }
            }
        }
    }

    private func navigationRow(
        title: String,
        subtitle: String,
        symbol: String,
        destination: CycleRoute,
        identifier: String
    ) -> some View {
        Button { route(destination) } label: {
            LooprRow(title: title, subtitle: subtitle, symbol: symbol)
                .padding(.horizontal, LooprSpacing.formCardPadding)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }
}

public struct CycleLogScreen: View {
    public let onSave: (CycleEntry) -> Void
    private let errorMessage: String?
    @State private var day = CycleDate.string(Date())
    @State private var kind: CycleEventKind = .periodStart
    @State private var flow: FlowLevel = .medium
    @State private var note = ""

    public init(errorMessage: String? = nil, onSave: @escaping (CycleEntry) -> Void = { _ in }) {
        self.errorMessage = errorMessage
        self.onSave = onSave
    }

    public var body: some View {
        LooprDetailScaffold {
            VStack(alignment: .leading, spacing: LooprSpacing.lg) {
                LooprSectionGroup(title: "Cycle event") {
                    LooprFormCard(padding: LooprSpacing.none) {
                        VStack(spacing: LooprSpacing.none) {
                            LooprTextFieldRow(
                                title: "Local day",
                                placeholder: "YYYY-MM-DD",
                                text: $day
                            )
                            .textInputAutocapitalization(.never)
                            .accessibilityIdentifier("cycle-day-input")

                            LooprHairline()

                            LooprPickerRow(
                                title: "Event",
                                selection: $kind,
                                options: CycleEventKind.allCases,
                                label: { $0.displayName }
                            )
                            .accessibilityIdentifier("cycle-event-picker")

                            if kind == .flow {
                                LooprHairline()
                                LooprPickerRow(
                                    title: "Flow",
                                    selection: $flow,
                                    options: FlowLevel.allCases,
                                    label: { $0.rawValue.capitalized }
                                )
                                .accessibilityIdentifier("cycle-flow-picker")
                            }

                            LooprHairline()

                            LooprTextFieldRow(
                                title: "Note",
                                placeholder: "Optional",
                                text: $note
                            )
                            .accessibilityIdentifier("cycle-log-note")
                        }
                    }
                }

                LooprSectionGroup(title: "Actions") {
                    Button("Save cycle entry") {
                        onSave(
                            CycleEntry(
                                day: day,
                                kind: kind,
                                flow: kind == .flow ? flow : nil,
                                note: note.isEmpty ? nil : note
                            )
                        )
                    }
                    .buttonStyle(LooprPrimaryButtonStyle())
                    .accessibilityIdentifier("cycle-log-save")
                }

                if let errorMessage {
                    LooprSectionGroup(title: "Status") {
                        LooprFormCard {
                            LooprInlineMessage(errorMessage, tone: .critical)
                                .accessibilityIdentifier("cycle-log-error")
                        }
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
        .navigationTitle("Log cycle")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .tint(Color.loopr(.cycle))
        .accessibilityIdentifier("cycle-log-screen")
    }
}

public struct CycleRemindersScreen: View {
    @State private var enabled: Bool
    @State private var hour: Int
    /// True once a control on this screen has been changed and not yet
    /// saved. The stored settings arrive after the first render, so they are
    /// only taken while this is false; otherwise a load in flight would undo
    /// what the person just set.
    @State private var hasPendingEdits = false
    @State private var isDisableConfirmationPresented = false
    private let settings: CycleSettings
    private let onSave: (Bool, Int) async -> Void
    private let onDisable: () async -> Void
    private let errorMessage: String?

    public init(
        settings: CycleSettings = .init(),
        errorMessage: String? = nil,
        onSave: @escaping (Bool, Int) async -> Void = { _, _ in },
        onDisable: @escaping () async -> Void = {}
    ) {
        self.settings = settings
        _enabled = State(initialValue: settings.remindersEnabled)
        _hour = State(initialValue: settings.reminderHour ?? 9)
        self.errorMessage = errorMessage
        self.onSave = onSave
        self.onDisable = onDisable
    }

    public var body: some View {
        LooprDetailScaffold {
            VStack(alignment: .leading, spacing: LooprSpacing.lg) {
                LooprSectionGroup(title: "Reminders") {
                    LooprFormCard(padding: LooprSpacing.none) {
                        VStack(spacing: LooprSpacing.none) {
                            LooprToggleRow(
                                title: "Local reminders",
                                subtitle: "Optional reminders stay on this device.",
                                isOn: Binding(
                                    get: { enabled },
                                    set: { newValue in
                                        enabled = newValue
                                        hasPendingEdits = true
                                    }
                                )
                            )
                            .accessibilityIdentifier("cycle-reminders-toggle")

                            if enabled {
                                LooprHairline()
                                LooprPickerRow(
                                    title: "Reminder time",
                                    selection: Binding(
                                        get: { hour },
                                        set: { newValue in
                                            hour = newValue
                                            hasPendingEdits = true
                                        }
                                    ),
                                    options: Array(0...23),
                                    label: reminderTimeLabel
                                )
                                .accessibilityIdentifier("cycle-reminders-hour")
                            }
                        }
                    }
                }

                LooprSectionGroup(title: "Actions") {
                    VStack(spacing: LooprSpacing.sm) {
                        Button("Save reminder settings") {
                            hasPendingEdits = false
                            Task { await onSave(enabled, hour) }
                        }
                        .buttonStyle(LooprPrimaryButtonStyle())
                        .accessibilityIdentifier("cycle-reminders-save")

                        Button("Disable cycle tracking", role: .destructive) {
                            isDisableConfirmationPresented = true
                        }
                        .buttonStyle(LooprDestructiveButtonStyle())
                        .accessibilityIdentifier("cycle-disable")
                    }
                }

                LooprSectionGroup(title: "Privacy") {
                    LooprFormCard {
                        LooprText(
                            "Reminders are optional and stay on this device.",
                            style: .prose,
                            color: .inkSecondary
                        )
                    }
                }

                if let errorMessage {
                    LooprSectionGroup(title: "Status") {
                        LooprFormCard {
                            LooprInlineMessage(errorMessage, tone: .critical)
                                .accessibilityIdentifier("cycle-reminders-error")
                        }
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
        .navigationTitle("Cycle reminders")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .tint(Color.loopr(.cycle))
        .accessibilityIdentifier("cycle-reminders-screen")
        // The owning view model loads after the first render, so the stored
        // reminder settings have to replace the starting values when they
        // land. Without this the screen always shows reminders off at 09:00
        // and saving writes that back over what was stored.
        .onChange(of: settings) { _, value in
            guard !hasPendingEdits else { return }
            enabled = value.remindersEnabled
            hour = value.reminderHour ?? 9
        }
        .confirmationDialog(
            "Disable cycle tracking?",
            isPresented: $isDisableConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Disable cycle tracking", role: .destructive) {
                Task { await onDisable() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your cycle history stays saved until you delete it.")
        }
    }

    private func reminderTimeLabel(_ hour: Int) -> String {
        hour < 10 ? "0\(hour):00" : "\(hour):00"
    }
}

public struct CycleExportScreen: View {
    public let export: CycleExport
    public let onExport: () -> Void
    private let onExportFile: (() async throws -> URL)?
    @State private var exportURL: URL?
    @State private var errorMessage: String?

    public init(export: CycleExport, onExport: @escaping () -> Void = {}, onExportFile: (() async throws -> URL)? = nil) {
        self.export = export
        self.onExport = onExport
        self.onExportFile = onExportFile
    }

    public var body: some View {
        LooprDetailScaffold {
            VStack(alignment: .leading, spacing: LooprSpacing.lg) {
                LooprSectionGroup(title: "Private export") {
                    HairlineMetricList(rows: [
                        HairlineMetricRow(
                            id: "cycle-export-entries",
                            title: "Entries",
                            value: String(export.entries.count)
                        ),
                        HairlineMetricRow(
                            id: "cycle-export-reminders",
                            title: "Reminders",
                            value: export.settings.remindersEnabled ? "Enabled" : "Off"
                        )
                    ])
                }

                LooprSectionGroup(title: "Privacy") {
                    LooprFormCard {
                        LooprText(
                            "Cycle history is included only after you explicitly choose export.",
                            style: .prose,
                            color: .inkSecondary
                        )
                    }
                }

                LooprSectionGroup(title: "Actions") {
                    Button("Prepare export") {
                        guard let onExportFile else {
                            onExport()
                            return
                        }
                        errorMessage = nil
                        Task { @MainActor in
                            do { exportURL = try await onExportFile() }
                            catch { errorMessage = error.localizedDescription }
                        }
                    }
                    .buttonStyle(LooprPrimaryButtonStyle())
                    .accessibilityIdentifier("cycle-export-create")
                }

                exportReady

                if let errorMessage {
                    LooprSectionGroup(title: "Status") {
                        LooprFormCard {
                            LooprInlineMessage(errorMessage, tone: .critical)
                                .accessibilityIdentifier("cycle-export-error")
                        }
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
        .navigationTitle("Cycle export")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .tint(Color.loopr(.cycle))
        .accessibilityIdentifier("cycle-export-screen")
    }

    @ViewBuilder
    private var exportReady: some View {
        if let exportURL {
            LooprSectionGroup(title: "Ready") {
                LooprFormCard {
                    VStack(alignment: .leading, spacing: LooprSpacing.md) {
                        LooprInlineMessage("Export saved locally.", tone: .positive)

                        if #available(iOS 16.0, macOS 13.0, *) {
                            ShareLink(item: exportURL) {
                                Label("Share export", systemImage: "square.and.arrow.up")
                            }
                            .buttonStyle(LooprPrimaryButtonStyle())
                            .accessibilityIdentifier("cycle-export-share")
                        } else {
                            LooprText(
                                "Export saved locally.",
                                style: .prose,
                                color: .inkSecondary
                            )
                        }
                    }
                }
            }
        }
    }
}

public struct CycleDestinationScreen: View {
    public let route: CycleRoute
    public let export: CycleExport
    public let onLog: (CycleEntry) -> Void
    public let onExport: () -> Void
    public let repository: (any CycleStore)?
    public let settings: CycleSettings
    public let actionError: String?
    private let onSaveReminders: (Bool, Int) async -> Void
    private let onDisable: () async -> Void

    public init(
        route: CycleRoute,
        export: CycleExport = CycleExport(entries: [], settings: CycleSettings()),
        onLog: @escaping (CycleEntry) -> Void,
        onExport: @escaping () -> Void,
        repository: (any CycleStore)? = nil,
        settings: CycleSettings = .init(),
        actionError: String? = nil,
        onSaveReminders: @escaping (Bool, Int) async -> Void = { _, _ in },
        onDisable: @escaping () async -> Void = {}
    ) {
        self.route = route
        self.export = export
        self.onLog = onLog
        self.onExport = onExport
        self.repository = repository
        self.settings = settings
        self.actionError = actionError
        self.onSaveReminders = onSaveReminders
        self.onDisable = onDisable
    }

    public var body: some View {
        Group {
            switch route {
            case .overview:
                CycleScreen(viewModel: CycleViewModel(repository: repository))
            case .log:
                CycleLogScreen(errorMessage: actionError, onSave: onLog)
            case .reminders:
                CycleRemindersScreen(settings: settings, errorMessage: actionError, onSave: onSaveReminders, onDisable: onDisable)
            case .export:
                CycleExportScreen(export: export, onExport: onExport)
            }
        }
        .accessibilityIdentifier(identifier)
    }

    private var identifier: String {
        switch route {
        case .overview: "cycle-overview-screen"
        case .log: "cycle-log-screen"
        case .reminders: "cycle-reminders-screen"
        case .export: "cycle-export-screen"
        }
    }
}
