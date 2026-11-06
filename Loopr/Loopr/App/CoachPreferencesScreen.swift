import AIKit
import DesignSystem
import SettingsKit
import SwiftUI

struct CoachPreferencesScreen: View {
    private enum NotificationAccess { case unknown, allowed, askable, denied }

    static let instructionLimit = 4_000
    static let instructionWarning = 3_800

    @ObservedObject var model: CoachChatViewModel
    /// Patterns opens this screen to switch the briefing on. The sharing review then opens without another tap.
    var startsMorningReview = false
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var preferences = CoachPreferences()
    @State private var instructions = ""
    @State private var savedInstructions = ""
    @State private var savingInstructions = false
    @State private var instructionsFailure: String?
    @State private var summary = ""
    @State private var reviewingMorning = false
    @State private var busy = false
    @State private var enabling = false
    @State private var briefingFeedback: CoachFeedback?
    @State private var reviewFailure: String?
    @State private var summaryID = UUID()
    @State private var reviewedSharing: CoachSharing?
    @State private var morningOn = false
    @State private var notificationAccess: NotificationAccess = .unknown
    @State private var haptic: LooprHaptic?

    var body: some View {
        LooprDetailScaffold {
            instructionsSection
            briefingSection
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Coach preferences")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .tint(Color.loopr(.brand))
        .accessibilityIdentifier("coach-preferences-screen")
        .looprHaptic(haptic)
        .task {
            preferences = model.preferences
            instructions = preferences.instructions
            savedInstructions = preferences.instructions
            morningOn = preferences.morningEnabled
            await refreshNotificationAccess()
            if startsMorningReview, !preferences.morningEnabled {
                morningOn = true
                await prepareMorning()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refreshNotificationAccess() } }
        }
        .sheet(isPresented: $reviewingMorning, onDismiss: { Task { await reloadSavedBriefing() } }) {
            reviewSheet
        }
    }

    // MARK: Instructions

    private var instructionCount: Int { instructions.count }
    private var overLimit: Bool { instructionCount > Self.instructionLimit }
    private var isDirty: Bool { instructions != savedInstructions }

    private var instructionsSection: some View {
        LooprSectionGroup(title: "Coaching preferences") {
            LooprFormCard(padding: LooprSpacing.none) {
                VStack(alignment: .leading, spacing: LooprSpacing.none) {
                    LooprTextEditorRow(
                        title: "Coach instructions",
                        placeholder: "For example: I train for a half marathon. Keep answers short.",
                        text: $instructions,
                        minimumHeight: 110
                    )
                    .accessibilityIdentifier("coach-instructions")
                    LooprHairline()
                    VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                        counterAndState
                        if let instructionsFailure {
                            LooprInlineMessage(instructionsFailure, tone: .critical)
                                .accessibilityIdentifier("coach-instructions-failure")
                        }
                        instructionButtons
                    }
                    .padding(LooprSpacing.formCardPadding)
                }
            }
            LooprText(
                "Tell your coach about your goals, preferred activities, or how you like replies. These instructions go to your provider with new chats. Chats you already started keep the instructions they began with.",
                style: .prose, color: .inkSecondary
            )
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, LooprSpacing.xxs)
        }
    }

    private var counterAndState: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline) { stateLabel; Spacer(minLength: LooprSpacing.sm); counter }
            VStack(alignment: .leading, spacing: LooprSpacing.xxs) { stateLabel; counter }
        }
    }

    private var counter: some View {
        let remaining = Self.instructionLimit - instructionCount
        let color: LooprColorToken = overLimit ? .critical : (instructionCount >= Self.instructionWarning ? .caution : .inkSecondary)
        return LooprText(
            overLimit
                ? "\(-remaining) over the \(Self.instructionLimit.formatted()) limit"
                : "\(instructionCount.formatted()) of \(Self.instructionLimit.formatted())",
            style: .metricUnit, color: color
        )
        .accessibilityLabel(overLimit
            ? "\(-remaining) characters over the limit"
            : "\(instructionCount) of \(Self.instructionLimit) characters")
        .accessibilityIdentifier("coach-instructions-count")
    }

    @ViewBuilder
    private var stateLabel: some View {
        if savingInstructions {
            Label("Saving", systemImage: "arrow.triangle.2.circlepath")
                .looprTypography(.caption).foregroundStyle(Color.loopr(.inkSecondary))
        } else if isDirty {
            Label("Not saved yet", systemImage: "circle.dotted")
                .looprTypography(.caption).foregroundStyle(Color.loopr(.caution))
        } else if !savedInstructions.isEmpty {
            Label("Saved for new chats", systemImage: "checkmark.circle.fill")
                .looprTypography(.caption).foregroundStyle(Color.loopr(.brandInk))
        } else {
            Label("No instructions yet", systemImage: "circle")
                .looprTypography(.caption).foregroundStyle(Color.loopr(.inkSecondary))
        }
    }

    private var instructionButtons: some View {
        VStack(spacing: LooprSpacing.xs) {
            Button { Task { await saveInstructions() } } label: {
                CoachActionLabel(title: "Save instructions", progressTitle: "Saving", isRunning: savingInstructions)
            }
            .buttonStyle(LooprPrimaryButtonStyle())
            .disabled(!isDirty || overLimit || savingInstructions)
            .accessibilityIdentifier("coach-instructions-save")
            if !instructions.isEmpty {
                Button {
                    instructions = ""
                    instructionsFailure = nil
                } label: {
                    Text("Clear instructions").padding(.horizontal, LooprSpacing.sm)
                }
                .buttonStyle(CoachSecondaryButtonStyle())
                .disabled(savingInstructions)
                .accessibilityIdentifier("coach-instructions-clear")
            }
        }
    }

    private func saveInstructions() async {
        guard isDirty, !overLimit, !savingInstructions else { return }
        savingInstructions = true; defer { savingInstructions = false }
        let text = instructions
        do {
            var latest = try await model.repository.preferences(); latest.instructions = text
            try await model.savePreferences(latest)
            preferences.instructions = text; savedInstructions = text; instructionsFailure = nil
            haptic = .success
            AccessibilityNotification.Announcement("Instructions saved for new chats.").post()
        } catch {
            let message = CoachSettingsCopy.message(for: error)
            instructionsFailure = message
            haptic = .error
            AccessibilityNotification.Announcement(message).post()
        }
    }

    // MARK: Morning briefing

    private var briefingSection: some View {
        LooprSectionGroup(title: "Morning briefing") {
            LooprFormCard(padding: LooprSpacing.none) {
                VStack(spacing: LooprSpacing.none) {
                    LooprToggleRow(
                        title: "Automatic morning briefing",
                        subtitle: "A short plan for the day, once each morning.",
                        isOn: Binding(get: { morningOn }, set: { setMorning($0) })
                    )
                    .disabled(busy)
                    .accessibilityIdentifier("coach-morning-toggle")
                    LooprHairline()
                    LooprPickerRow(
                        title: "Preferred time",
                        selection: $preferences.morningHour,
                        options: Array(0..<24),
                        label: { CoachSettingsCopy.hourLabel($0) }
                    )
                    .disabled(busy)
                    .accessibilityIdentifier("coach-morning-time")
                    .onChange(of: preferences.morningHour) { _, hour in saveHour(hour) }
                    if morningOn, let config = preferences.morningConfiguration {
                        LooprHairline()
                        infoRow("Provider", "\(config.provider.name), \(config.model)")
                            .accessibilityIdentifier("coach-morning-provider")
                    }
                    if morningOn {
                        LooprHairline()
                        infoRow("Next briefing", CoachSettingsCopy.nextBriefingText(hour: preferences.morningHour))
                            .accessibilityIdentifier("coach-morning-next")
                    }
                    if let day = preferences.lastBriefingDay {
                        LooprHairline()
                        infoRow("Last briefing", CoachSettingsCopy.dayText(day))
                            .accessibilityIdentifier("coach-morning-last")
                    }
                }
            }
            if let briefingFeedback {
                LooprInlineMessage(briefingFeedback.text, tone: briefingFeedback.tone)
                    .padding(.horizontal, LooprSpacing.xxs)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .accessibilityIdentifier("coach-preferences-status")
            }
            if busy && !reviewingMorning {
                HStack(spacing: LooprSpacing.xs) {
                    ProgressView().controlSize(.small)
                    LooprText("Working", style: .prose, color: .inkSecondary)
                }
                .accessibilityElement(children: .combine)
            }
            if morningOn { reviewButton }
            if let error = preferences.lastBriefingError { briefingErrorCard(error) }
            if morningOn || preferences.morningEnabled, notificationAccess == .denied || notificationAccess == .askable {
                notificationCard
            }
            LooprText(
                "Loopr sends a fresh summary to your chosen provider once each morning. iOS decides the exact minute. If a briefing runs late, Loopr catches up when you open the app. API charges apply.",
                style: .prose, color: .inkSecondary
            )
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, LooprSpacing.xxs)
            LooprText(
                "Briefings appear in chat history. To get one on demand, ask for a morning briefing in a new chat.",
                style: .prose, color: .inkSecondary
            )
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, LooprSpacing.xxs)
        }
        .padding(.top, LooprSpacing.sm)
        .animation(.smooth(duration: LooprMotion.fast), value: briefingFeedback)
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.sm) {
            LooprText(title, style: .settingsRow)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
            Spacer(minLength: LooprSpacing.sm)
            LooprText(value, style: .metricUnit, color: .inkMuted)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, LooprSpacing.formCardPadding)
        .padding(.vertical, LooprSpacing.formRowVerticalPadding)
        .frame(maxWidth: .infinity, minHeight: LooprSpacing.interactiveRowHeight, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var reviewButton: some View {
        Button { Task { await prepareMorning() } } label: {
            Text("Review briefing data").padding(.horizontal, LooprSpacing.sm)
        }
        .buttonStyle(CoachSecondaryButtonStyle())
        .disabled(busy)
        .accessibilityIdentifier("coach-morning-review")
    }

    private func briefingErrorCard(_ message: String) -> some View {
        LooprCard(style: .warning, density: .compact) {
            VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                LooprText("Last briefing did not run", style: .rowTitle)
                    .accessibilityAddTraits(.isHeader)
                LooprText(message, style: .prose, color: .inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !preferences.morningEnabled {
                    Button { Task { await prepareMorning() } } label: {
                        Text("Review and turn on").padding(.horizontal, LooprSpacing.sm)
                    }
                    .buttonStyle(CoachSecondaryButtonStyle())
                    .disabled(busy)
                    .accessibilityIdentifier("coach-morning-error-review")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("coach-morning-error")
    }

    private var notificationCard: some View {
        LooprCard(style: .warning, density: .compact) {
            VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                LooprText(
                    notificationAccess == .denied ? "Notifications are off" : "Notifications are not allowed yet",
                    style: .rowTitle
                )
                .accessibilityAddTraits(.isHeader)
                LooprText(
                    notificationAccess == .denied
                        ? "Briefings still run and appear in your chat history, but Loopr cannot alert you when one is ready."
                        : "Allow notifications to get an alert when a briefing is ready. Briefings appear in your chat history either way.",
                    style: .prose, color: .inkSecondary
                )
                .fixedSize(horizontal: false, vertical: true)
                Button {
                    if notificationAccess == .denied {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    } else {
                        Task {
                            _ = await LooprNotificationRuntime.shared.requestPermission()
                            await refreshNotificationAccess()
                        }
                    }
                } label: {
                    Text(notificationAccess == .denied ? "Open Settings" : "Allow notifications")
                        .padding(.horizontal, LooprSpacing.sm)
                }
                .buttonStyle(CoachSecondaryButtonStyle())
                .accessibilityIdentifier("coach-notifications-action")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("coach-notifications-card")
    }

    private func refreshNotificationAccess() async {
        switch await LooprNotificationRuntime.shared.state() {
        case .available: notificationAccess = .allowed
        case .denied: notificationAccess = .denied
        case .permissionRequired: notificationAccess = .askable
        default: notificationAccess = .unknown
        }
    }

    private func setMorning(_ enabled: Bool) {
        morningOn = enabled
        briefingFeedback = nil
        Task { enabled ? await prepareMorning() : await disableMorning() }
    }

    private func saveHour(_ hour: Int) {
        guard preferences.morningEnabled else { return }
        Task {
            do {
                var latest = try await model.repository.preferences()
                guard latest.morningHour != hour else { return }
                latest.morningHour = hour
                try await model.savePreferences(latest); await CoachBriefingRuntime.shared.schedule()
                haptic = LooprHaptic(.selection)
            } catch { showBriefing(.failure(CoachSettingsCopy.message(for: error))) }
        }
    }

    private func showBriefing(_ value: CoachFeedback) {
        briefingFeedback = value
        haptic = value.haptic
        AccessibilityNotification.Announcement(value.text).post()
        guard value.tone != .critical else { return }
        Task {
            try? await Task.sleep(for: .seconds(4))
            if briefingFeedback == value { briefingFeedback = nil }
        }
    }

    // MARK: Review sheet

    private var reviewSheet: some View {
        NavigationStack {
            LooprDetailScaffold {
                VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                    LooprText(
                        "Allow daily sharing with \(preferences.morningConfiguration?.provider.name ?? "your provider")?",
                        style: .title
                    )
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    LooprText(
                        "This sample shows what Loopr will send. The dates and measurements update each morning. Briefings use the categories you choose here and your coaching preferences. They do not include previous chats.",
                        style: .prose, color: .inkSecondary
                    )
                    .fixedSize(horizontal: false, vertical: true)
                }
                LooprSectionGroup(title: "Shared categories") {
                    LooprFormCard(padding: LooprSpacing.none) {
                        VStack(spacing: LooprSpacing.none) {
                            LooprToggleRow(title: "Health measurements and goals", isOn: $preferences.morningSharing.metrics)
                            LooprHairline()
                            LooprToggleRow(title: "Journal entries", isOn: $preferences.morningSharing.journal)
                            LooprHairline()
                            LooprToggleRow(title: "Cycle records", isOn: $preferences.morningSharing.cycle)
                        }
                    }
                }
                .padding(.top, LooprSpacing.sm)
                LooprSectionGroup(title: "What Loopr will send") {
                    LooprCard(style: .sunk, density: .compact) {
                        if busy && summary.isEmpty {
                            HStack(spacing: LooprSpacing.xs) {
                                ProgressView().controlSize(.small)
                                LooprText("Preparing the sample", style: .prose, color: .inkSecondary)
                            }
                            .accessibilityElement(children: .combine)
                        } else {
                            LooprText(summary.isEmpty ? "No sample yet." : summary, style: .metricUnit, color: summary.isEmpty ? .inkMuted : .ink)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .accessibilityIdentifier("coach-morning-summary")
                }
                .padding(.top, LooprSpacing.sm)
                if let reviewFailure {
                    LooprInlineMessage(reviewFailure, tone: .critical)
                        .accessibilityIdentifier("coach-morning-review-failure")
                }
                LooprText(
                    "You can turn this off at any time. It stops future requests. It cannot recall data the provider already received.",
                    style: .prose, color: .inkSecondary
                )
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, LooprSpacing.xs)
            }
            .scrollIndicators(.hidden)
            .safeAreaInset(edge: .bottom) {
                Button { Task { await enableMorning() } } label: {
                    CoachActionLabel(title: "Enable morning briefings", progressTitle: "Enabling", isRunning: enabling)
                }
                .buttonStyle(LooprPrimaryButtonStyle())
                .disabled(busy || enabling || summary.isEmpty || reviewedSharing != preferences.morningSharing)
                .padding(.horizontal, LooprSpacing.screenGutter)
                .padding(.vertical, LooprSpacing.sm)
                .background { Color.loopr(.background).ignoresSafeArea(edges: .bottom) }
                .overlay(alignment: .top) { LooprHairline() }
                .accessibilityIdentifier("coach-morning-enable")
            }
            .navigationTitle("Review daily sharing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { reviewingMorning = false } } }
            .onChange(of: preferences.morningSharing) { _, _ in
                guard reviewingMorning else { return }
                Task { await refreshSummary() }
            }
            .tint(Color.loopr(.brand))
        }
        .presentationDragIndicator(.visible)
    }

    // MARK: Consent flow

    private func prepareMorning() async {
        do {
            guard let config = try await model.runtime.selectedConfiguration() else { throw CoachProviderError.missingKey }
            preferences.morningConfiguration = config; reviewingMorning = true
            await refreshSummary()
        } catch {
            morningOn = preferences.morningEnabled
            showBriefing(.failure(Self.briefingMessage(error)))
        }
    }

    private static func briefingMessage(_ error: Error) -> String {
        if let error = error as? CoachProviderError, error == .missingKey {
            return "Add an AI provider key first. Briefings need one to write the summary."
        }
        return CoachSettingsCopy.message(for: error)
    }

    private func refreshSummary() async {
        let id = UUID(); summaryID = id
        let sharing = preferences.morningSharing
        busy = true; summary = ""; reviewedSharing = nil; reviewFailure = nil
        do {
            let text = try await model.context.summary(sharing: sharing, at: Date())
            guard summaryID == id else { return }
            summary = text; reviewedSharing = sharing; busy = false
        } catch {
            guard summaryID == id else { return }
            reviewFailure = CoachSettingsCopy.message(for: error); busy = false
            haptic = .error
        }
    }

    private func enableMorning() async {
        guard !busy, !enabling, !summary.isEmpty, reviewedSharing == preferences.morningSharing else { return }
        enabling = true; defer { enabling = false }
        do {
            var latest = try await model.repository.preferences()
            latest.morningEnabled = true; latest.morningHour = preferences.morningHour
            latest.morningConfiguration = preferences.morningConfiguration
            latest.morningSharing = preferences.morningSharing; latest.morningConsentAt = Date()
            latest.lastBriefingError = nil
            await CoachBriefingRuntime.shared.cancel()
            try await model.savePreferences(latest); preferences = latest; reviewingMorning = false
            morningOn = true
            _ = await LooprNotificationRuntime.shared.requestPermission()
            await refreshNotificationAccess()
            await CoachBriefingRuntime.shared.schedule()
            showBriefing(.success("Morning briefings are on."))
            await CoachBriefingRuntime.shared.runIfDue()
            await refreshPreferences()
        } catch { reviewFailure = CoachSettingsCopy.message(for: error); haptic = .error }
    }

    private func disableMorning() async {
        await CoachBriefingRuntime.shared.cancel()
        do {
            var latest = try await model.repository.preferences()
            latest.morningEnabled = false; latest.morningConsentAt = nil
            try await model.savePreferences(latest)
            preferences.morningEnabled = false; preferences.morningConsentAt = nil
            morningOn = false
            showBriefing(.success("Morning briefings are off."))
        } catch {
            morningOn = preferences.morningEnabled
            showBriefing(.failure(CoachSettingsCopy.message(for: error)))
        }
    }

    /// Closing the review without enabling drops what the sheet changed. The screen shows the
    /// briefing configuration and categories that are saved, because those decide where data goes.
    private func reloadSavedBriefing() async {
        guard let saved = try? await model.repository.preferences() else {
            morningOn = preferences.morningEnabled
            return
        }
        preferences.morningEnabled = saved.morningEnabled
        preferences.morningConfiguration = saved.morningConfiguration
        preferences.morningSharing = saved.morningSharing
        preferences.morningConsentAt = saved.morningConsentAt
        morningOn = saved.morningEnabled
    }

    /// Picks up what a briefing run wrote: the last day and any error.
    private func refreshPreferences() async {
        guard let latest = try? await model.repository.preferences() else { return }
        preferences.lastBriefingDay = latest.lastBriefingDay
        preferences.lastBriefingError = latest.lastBriefingError
    }
}
