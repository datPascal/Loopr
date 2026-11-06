import AIKit
import DesignSystem
import SwiftUI

struct AppAIProviderSettingsScreen: View {
    /// What is running now. One action at a time; the rest of the form waits.
    private enum Activity: Equatable { case idle, saving, selecting, checking, refreshing, removing }
    private enum KeyCheck: Equatable { case idle, checking, valid(Int), failed }
    private enum ModelList: Equatable { case idle, loading, loaded(Int), failed(String) }
    private enum Removal: Equatable { case key(CoachProvider), everything }

    private let runtime: LooprAISettingsRuntime
    private let onSaved: (() -> Void)?
    private let initialProvider: CoachProvider?

    @State private var provider: CoachProvider = .openAI
    /// Blank means the provider's default, so a newcomer never has to judge a model ID (ICP R3-NEW-6).
    @State private var model = ""
    @State private var apiKey = ""
    @State private var saved: [CoachProviderConfiguration] = []
    @State private var selected: CoachProvider?
    @State private var models: [String] = []
    @State private var modelList: ModelList = .idle
    @State private var keyCheck: KeyCheck = .idle
    @State private var feedback: CoachFeedback?
    @State private var activity: Activity = .idle
    @State private var loaded = false
    @State private var pendingRemoval: Removal?
    @State private var hasLegacy = false
    @State private var photoApprovals: Set<CoachProvider> = []
    @State private var haptic: LooprHaptic?
    @FocusState private var keyFocused: Bool

    /// - Parameter onSaved: Runs after a key is saved. The coach uses it to
    ///   close this screen; Settings leaves it nil and keeps the confirmation.
    init(runtime: LooprAISettingsRuntime = .shared, onSaved: (() -> Void)? = nil, initialProvider: CoachProvider? = nil) {
        self.runtime = runtime
        self.onSaved = onSaved
        self.initialProvider = initialProvider
        _provider = State(initialValue: initialProvider ?? .openAI)
        _model = State(initialValue: "")
    }

    var body: some View {
        ScrollViewReader { proxy in
            LooprDetailScaffold {
                providersSection
                editorSection
                privacySection
                if hasLegacy { legacySection }
            }
            .accessibilityIdentifier("settings-ai-provider-screen")
            .onChange(of: feedback) { _, value in
                guard value != nil else { return }
                withAnimation(LooprMotion.stateChange) { proxy.scrollTo(Self.feedbackID) }
            }
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        // Pinned above the keyboard, so Save stays in reach while a key is typed.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button(action: primaryAction) {
                CoachActionLabel(title: primaryTitle, progressTitle: primaryProgressTitle, isRunning: activity == .saving || activity == .selecting)
            }
            .buttonStyle(LooprPrimaryButtonStyle())
            .disabled(!primaryEnabled)
            .accessibilityIdentifier("settings-ai-save-provider")
            .padding(.horizontal, LooprSpacing.screenGutter)
            .padding(.vertical, LooprSpacing.sm)
            .frame(maxWidth: .infinity)
            .background { Color.loopr(.background).ignoresSafeArea(edges: .bottom) }
            .overlay(alignment: .top) { LooprHairline() }
        }
        .navigationTitle("AI providers")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .tint(Color.loopr(.brand))
        .looprHaptic(haptic)
        .confirmationDialog(
            removalTitle,
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible,
            presenting: pendingRemoval
        ) { removal in
            Button(removal == .everything ? "Remove old endpoint and keys" : "Remove key", role: .destructive) {
                Task { await remove(removal) }
            }
        } message: { removal in
            Text(removalMessage(removal))
        }
        .onChange(of: provider) { _, value in
            // A half-typed key never follows you to another provider.
            apiKey = ""; models = []; modelList = .idle; keyCheck = .idle; feedback = nil
            model = saved.first { $0.provider == value }?.model ?? ""
        }
        .onChange(of: apiKey) { _, _ in
            if keyCheck != .idle, keyCheck != .checking { keyCheck = .idle }
        }
        .onDisappear { apiKey = "" }
        .task { await load(selectActive: initialProvider == nil) }
    }

    private static let feedbackID = "coach-provider-feedback"

    // MARK: Sections

    private var providersSection: some View {
        LooprSectionGroup(title: "Your AI provider") {
            VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                ForEach(CoachProvider.allCases) { candidate in
                    CoachProviderCard(
                        provider: candidate,
                        configuration: saved.first { $0.provider == candidate },
                        isActive: selected == candidate,
                        isEditing: provider == candidate
                    ) {
                        guard provider != candidate else { return }
                        haptic = LooprHaptic(.selection)
                        provider = candidate
                    }
                    .disabled(isBusy)
                }
                LooprText(
                    "Use your own API account. ChatGPT and Claude app subscriptions do not include API usage.",
                    style: .prose, color: .inkSecondary
                )
                .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("coach-provider-picker")
        }
    }

    private var editorSection: some View {
        LooprSectionGroup(title: "\(provider.name) key and model") {
            LooprFormCard {
                VStack(alignment: .leading, spacing: LooprSpacing.md) {
                    keyStatusRow
                    keyField
                    keyLink
                    LooprHairline()
                    modelField
                    modelPicker
                }
            }
            .disabled(isBusy)
            actions
            if let feedback {
                LooprInlineMessage(feedback.text, tone: feedback.tone)
                    .padding(.horizontal, LooprSpacing.xxs)
                    .id(Self.feedbackID)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .accessibilityIdentifier("settings-ai-provider-status")
            }
        }
        .animation(.smooth(duration: LooprMotion.fast), value: feedback)
    }

    private var keyStatusRow: some View {
        HStack(spacing: LooprSpacing.xs) {
            Image(systemName: isSaved ? "lock.fill" : "lock.open")
                .looprTypography(.rowTitle)
                .foregroundStyle(Color.loopr(isSaved ? .brandInk : .inkMuted))
                .accessibilityHidden(true)
            LooprText(
                isSaved ? "Key saved in this iPhone's Keychain" : "No key saved for \(provider.name)",
                style: .rowTitle, color: isSaved ? .ink : .inkSecondary
            )
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var keyField: some View {
        CoachFieldWell(title: isSaved ? "Replace API key" : "API key") {
            SecureField(isSaved ? "Paste a new key, or leave blank" : "Paste your API key", text: $apiKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .privacySensitive()
                .focused($keyFocused)
                .submitLabel(.done)
                .onSubmit { keyFocused = false }
                .accessibilityLabel(isSaved ? "Replace API key" : "API key")
                .accessibilityIdentifier("settings-ai-api-key")
        } trailing: {
            PasteButton(payloadType: String.self) { @Sendable strings in
                guard let value = strings.first else { return }
                Task { @MainActor in
                    apiKey = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    keyCheck = .idle
                }
            }
            .labelStyle(.iconOnly)
            .buttonBorderShape(.capsule)
            .tint(Color.loopr(.brand))
            .accessibilityIdentifier("settings-ai-paste-key")
        }
    }

    private var keyLink: some View {
        Link(destination: provider.keyURL) {
            Label("Get \(article(for: provider)) \(provider.name) API key", systemImage: "arrow.up.right")
                .looprTypography(.label)
                .foregroundStyle(Color.loopr(.brandInk))
                .frame(minHeight: LooprSpacing.formButtonHeight, alignment: .leading)
        }
        .accessibilityIdentifier("settings-ai-get-key")
    }

    private var modelField: some View {
        CoachFieldWell(title: "Model, optional") {
            TextField("Leave blank for Loopr's pick", text: $model)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .accessibilityIdentifier("settings-ai-model")
        } trailing: {
            EmptyView()
        }
    }

    private var modelPicker: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: LooprSpacing.sm) { modelMenu; refreshButton }
                VStack(alignment: .leading, spacing: LooprSpacing.xs) { modelMenu; refreshButton }
            }
            switch modelList {
            case .idle:
                LooprText(
                    "Leave it blank and Loopr uses a model that works with a new \(provider.name) key. Type or choose another only if your account has it.",
                    style: .prose, color: .inkSecondary
                )
                .fixedSize(horizontal: false, vertical: true)
            case .loading:
                HStack(spacing: LooprSpacing.xs) {
                    ProgressView().controlSize(.small)
                    LooprText("Loading models from \(provider.name)", style: .prose, color: .inkSecondary)
                }
                .accessibilityElement(children: .combine)
            case .loaded(let count):
                LooprText(
                    count == 1 ? "1 model available to your key." : "\(count) models available to your key.",
                    style: .prose, color: .inkSecondary
                )
            case .failed(let message):
                LooprInlineMessage(message, tone: .warning)
                    .accessibilityIdentifier("settings-ai-models-status")
            }
        }
    }

    private var modelMenu: some View {
        Menu {
            ForEach(modelOptions, id: \.self) { value in
                Button {
                    model = value
                    haptic = LooprHaptic(.selection)
                } label: {
                    if value == model { Label(value, systemImage: "checkmark") } else { Text(value) }
                }
            }
        } label: {
            Label("Choose a model", systemImage: "chevron.up.chevron.down")
                .looprTypography(.label)
                .foregroundStyle(Color.loopr(.brandInk))
                .frame(minHeight: LooprSpacing.formButtonHeight, alignment: .leading)
        }
        .accessibilityIdentifier("settings-ai-model-menu")
    }

    private var refreshButton: some View {
        Button {
            Task { await fetchModels(refreshOnly: true) }
        } label: {
            if activity == .refreshing {
                ProgressView().controlSize(.small)
                    .frame(minWidth: LooprSpacing.formButtonHeight, minHeight: LooprSpacing.formButtonHeight)
            } else {
                Label("Refresh list", systemImage: "arrow.clockwise")
                    .looprTypography(.label)
                    .foregroundStyle(Color.loopr(canCheck ? .brandInk : .inkMuted))
                    .frame(minHeight: LooprSpacing.formButtonHeight, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .disabled(!canCheck || isBusy)
        .accessibilityLabel(activity == .refreshing ? "Loading models" : "Refresh model list")
        .accessibilityIdentifier("settings-ai-refresh-models")
    }

    private var actions: some View {
        VStack(spacing: LooprSpacing.sm) {
            Button { Task { await fetchModels(refreshOnly: false) } } label: {
                CoachActionLabel(title: checkTitle, progressTitle: "Checking key", isRunning: activity == .checking)
            }
            .buttonStyle(CoachSecondaryButtonStyle())
            .disabled(!canCheck || isBusy)
            .accessibilityIdentifier("coach-check-key")
            LooprText(
                "Checking sends your key to \(provider.name) and nothing else. It shares no health data and does not generate a reply.",
                style: .prose, color: .inkSecondary
            )
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)

            if isSaved {
                Button { pendingRemoval = .key(provider) } label: {
                    CoachActionLabel(title: "Remove \(provider.name) key", progressTitle: "Removing key", isRunning: activity == .removing)
                }
                .buttonStyle(LooprDestructiveButtonStyle())
                .disabled(isBusy)
                .accessibilityIdentifier("settings-ai-remove-provider")
            }
        }
    }

    private var privacySection: some View {
        LooprSectionGroup(title: "Privacy and billing") {
            LooprFormCard {
                VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                    note("Your key stays on this iPhone, in the Keychain. Loopr sends requests straight to \(provider.name) over HTTPS.")
                    note("You review the health summary before a chat sends its first message. A new key or model for a provider asks again before the next message in that provider's chats.")
                    note(photoApprovals.contains(provider) ? "Food photo access is allowed for \(provider.name). Each estimate sends only the selected food photo and note. Corrections send the reviewed food draft and text." : "Food photo access has not been approved for this provider. Loopr asks in meal review before sending a photo.")
                    if photoApprovals.contains(provider) {
                        Button("Revoke food photo access") {
                            let target = provider
                            Task {
                                await runtime.revokeFoodPhotoConsent(target)
                                photoApprovals.remove(target)
                            }
                        }.buttonStyle(LooprButtonStyle(prominent: false)).disabled(isBusy)
                            .accessibilityIdentifier("settings-ai-revoke-food-photos")
                    }
                    note("\(provider.name) bills you for API usage. Removing a key stops requests from Loopr. It does not delete data the provider already received.")
                    Link(destination: provider.privacyURL) {
                        Label("\(provider.name) privacy policy", systemImage: "arrow.up.right")
                            .looprTypography(.label)
                            .foregroundStyle(Color.loopr(.brandInk))
                            .frame(minHeight: LooprSpacing.formButtonHeight, alignment: .leading)
                    }
                }
            }
        }
        .padding(.top, LooprSpacing.sm)
    }

    private var legacySection: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.sm) {
            LooprInlineMessage(
                "An older custom endpoint is saved but not used. Add an OpenAI or Claude key above to use the coach.",
                tone: .warning
            )
            Button { pendingRemoval = .everything } label: {
                Text("Remove old endpoint and all keys")
                    .padding(.horizontal, LooprSpacing.sm)
            }
            .buttonStyle(LooprDestructiveButtonStyle())
            .disabled(isBusy)
            .accessibilityIdentifier("settings-ai-remove-legacy")
        }
        .padding(.top, LooprSpacing.sm)
    }

    private func note(_ text: String) -> some View {
        LooprText(text, style: .prose, color: .inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: State

    private var isBusy: Bool { activity != .idle || !loaded }
    private var isSaved: Bool { savedConfiguration != nil }
    private var savedConfiguration: CoachProviderConfiguration? { saved.first { $0.provider == provider } }
    private var hasKeyInput: Bool { !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var canCheck: Bool { hasKeyInput || isSaved }

    /// The model the form saves: the one typed or chosen, or the provider's default when the field is blank.
    private var effectiveModel: String {
        let value = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? provider.defaultModel : value
    }

    private var modelIsValid: Bool {
        let value = effectiveModel
        return !value.isEmpty && value.count <= 200 && !value.contains(where: \.isWhitespace)
    }

    private var modelOptions: [String] {
        Array(Set(provider.suggestedModels + models + [model].filter { !$0.isEmpty })).sorted()
    }

    private var hasChanges: Bool {
        guard let savedConfiguration else { return true }
        return hasKeyInput || effectiveModel != savedConfiguration.model
    }

    /// A saved provider with nothing edited only needs switching on.
    private var needsSwitch: Bool { isSaved && !hasChanges && selected != provider }

    private var primaryTitle: String {
        if needsSwitch { return "Use \(provider.name)" }
        return isSaved ? "Save changes" : "Save and use \(provider.name)"
    }

    private var primaryProgressTitle: String { needsSwitch ? "Switching" : "Saving" }

    private var primaryEnabled: Bool {
        guard loaded, activity == .idle else { return false }
        if needsSwitch { return true }
        return modelIsValid && hasChanges && (hasKeyInput || isSaved)
    }

    private var checkTitle: String {
        switch keyCheck {
        case .valid: "Check again"
        default: hasKeyInput || !isSaved ? "Check key" : "Check saved key"
        }
    }

    private var removalTitle: String {
        switch pendingRemoval {
        case .key(let provider): "Remove \(provider.name) from Loopr?"
        case .everything: "Remove the old endpoint and all keys?"
        case nil: ""
        }
    }

    private func removalMessage(_ removal: Removal) -> String {
        switch removal {
        case .key(let provider):
            "Loopr deletes the \(provider.name) key from this iPhone's Keychain. Saved chats stay on this iPhone. Open chats cannot send until you add a key."
        case .everything:
            "Loopr deletes the old endpoint and every saved API key from this iPhone. Saved chats stay on this iPhone."
        }
    }

    private func article(for provider: CoachProvider) -> String { provider == .openAI ? "an" : "a" }

    // MARK: Actions

    private func primaryAction() {
        Task { needsSwitch ? await use() : await save() }
    }

    private func present(_ value: CoachFeedback, haptic override: LooprHaptic? = nil) {
        feedback = value
        haptic = override ?? value.haptic
        AccessibilityNotification.Announcement(value.text).post()
    }

    private func fail(_ error: Error, provider: CoachProvider) {
        present(.failure(CoachSettingsCopy.message(for: error, provider: provider)))
    }

    private func load(selectActive: Bool) async {
        do {
            try await runtime.migrateLegacyOpenAI()
            saved = try await runtime.configurations()
            photoApprovals = []
            for configuration in saved {
                if try await runtime.foodPhotoConsentStored(configuration) { photoApprovals.insert(configuration.provider) }
            }
            selected = try await runtime.selectedConfiguration()?.provider
            if selectActive, let selected { provider = selected }
            model = saved.first { $0.provider == provider }?.model ?? ""
            hasLegacy = await runtime.hasLegacyConfiguration()
        } catch { fail(error, provider: provider) }
        loaded = true
    }

    private func save() async {
        guard activity == .idle, primaryEnabled else { return }
        let target = provider
        activity = .saving; defer { activity = .idle }
        feedback = nil
        do {
            try await runtime.configure(provider: target, model: effectiveModel, apiKey: apiKey)
            apiKey = ""; keyCheck = .idle; keyFocused = false
            await load(selectActive: false)
            present(.success("\(target.name) saved. Open the coach to start a chat."))
            onSaved?()
        } catch { fail(error, provider: target) }
    }

    private func use() async {
        guard activity == .idle else { return }
        let target = provider
        activity = .selecting; defer { activity = .idle }
        feedback = nil
        do {
            try await runtime.select(target)
            selected = target
            present(.success("\(target.name) is in use for new chats. Chats you already started stay with their own provider."))
        } catch { fail(error, provider: target) }
    }

    /// Asks the provider which models this key can use. "Check key" and
    /// "Refresh list" make the same call and report in different places.
    private func fetchModels(refreshOnly: Bool) async {
        guard activity == .idle, canCheck else { return }
        let target = provider
        activity = refreshOnly ? .refreshing : .checking; defer { activity = .idle }
        feedback = nil
        modelList = .loading
        if !refreshOnly { keyCheck = .checking }
        do {
            let found = try await runtime.models(provider: target, enteredKey: apiKey)
            guard provider == target else { return }
            models = found
            modelList = .loaded(found.count)
            if refreshOnly {
                haptic = .success
            } else {
                keyCheck = .valid(found.count)
                let count = found.count == 1 ? "1 model" : "\(found.count) models"
                present(.success("Key accepted. \(count) available. Credit is checked when you send a message."))
            }
        } catch {
            guard provider == target else { return }
            let message = CoachSettingsCopy.message(for: error, provider: target)
            if refreshOnly {
                modelList = .failed(message)
                haptic = .error
                AccessibilityNotification.Announcement(message).post()
            } else {
                modelList = .idle
                keyCheck = .failed
                present(.failure(message))
            }
        }
    }

    private func remove(_ removal: Removal) async {
        guard activity == .idle else { return }
        activity = .removing; defer { activity = .idle }
        feedback = nil
        do {
            switch removal {
            case .key(let target):
                try await runtime.remove(target)
                apiKey = ""; keyCheck = .idle
                await load(selectActive: false)
                present(.success("Key removed. Saved chats remain on this iPhone."), haptic: LooprHaptic(.impact(weight: .medium)))
            case .everything:
                try await runtime.removeProvider()
                apiKey = ""; keyCheck = .idle
                await load(selectActive: false)
                present(.success("Saved providers removed."), haptic: LooprHaptic(.impact(weight: .medium)))
            }
        } catch { fail(error, provider: provider) }
    }
}
