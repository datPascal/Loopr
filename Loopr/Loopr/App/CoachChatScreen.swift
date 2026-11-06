import AIKit
import DesignSystem
import SwiftUI
import UIKit

struct AppCoachScreen: View {
    @ObservedObject var model: CoachChatViewModel
    /// Opens Food photo capture from the composer. Nil hides the camera button.
    var attachPhoto: (@MainActor @Sendable () -> Void)?
    /// A source button under an answer. Nil leaves the source strip out.
    var openSource: (@MainActor @Sendable (AgentSourceLink) -> Void)?
    @StateObject private var dictation = CoachDictation()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var sheet: Sheet?
    @State private var historyPath: [HistoryRoute] = []
    /// A key, model or instruction screen was open, so the next load must pick up its changes.
    @State private var settingsOpened = false
    @State private var providersOpened = false
    @State private var afterDismiss: AfterDismiss?
    @State private var followReply = true
    @State private var nearBottom = true
    @State private var scrollRequest = ScrollRequest()
    @State private var advice: CoachChatMessage?
    @State private var haptic: LooprHaptic?
    @FocusState private var composerFocused: Bool
    private enum Sheet: String, Identifiable { case providers, history; var id: String { rawValue } }
    /// Screens pushed inside the history sheet.
    private enum HistoryRoute: Hashable { case providers, preferences }
    /// Work that waits for the sheet to finish closing, so two sheets never swap in one frame.
    private enum AfterDismiss { case reviewSharedData }
    private struct ScrollRequest: Equatable { var id = 0; var animated = false }

    private var reduces: Bool { LooprMotion.reducesMotion(reduceMotion) }
    /// At accessibility sizes a pinned card would cover the thread, so it scrolls with it.
    private var problemInThread: Bool { dynamicTypeSize.isAccessibilitySize }

    var body: some View {
        LooprPhaseContainer(phase: model.phase) { content }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.loopr(.background).ignoresSafeArea())
            .tint(Color.loopr(.brand))
            .navigationTitle("Ask")
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("coach-screen")
            .safeAreaInset(edge: .top, spacing: 0) { chipRow }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        haptic = .light
                        sheet = .history
                    } label: { Image(systemName: "text.document").accessibilityLabel("Chats and settings") }
                        .accessibilityIdentifier("ask-history")
                }
            }
            .sheet(item: $sheet, onDismiss: sheetDismissed) { route in
                NavigationStack(path: $historyPath) {
                    Group {
                        switch route {
                        case .providers: AppAIProviderSettingsScreen(runtime: model.runtime, onSaved: { sheet = nil })
                        case .history:
                            CoachHistorySheet(model: model, open: { chat in
                                Task { await model.open(chat); requestScroll(animated: false); sheet = nil }
                            }, actions: historyActions)
                        }
                    }
                    .toolbar { sheetDone }
                    .navigationDestination(for: HistoryRoute.self) { destination in
                        Group {
                            switch destination {
                            case .providers: AppAIProviderSettingsScreen(runtime: model.runtime, onSaved: { sheet = nil })
                            case .preferences: CoachPreferencesScreen(model: model)
                            }
                        }
                        .toolbar { sheetDone }
                    }
                }
                .tint(Color.loopr(.brand))
            }
            .sheet(isPresented: $model.showingConsent, onDismiss: { model.consentDismissed() }) { CoachConsentSheet(model: model) }
            .confirmationDialog("Save this advice to your notes?", isPresented: Binding(get: { advice != nil }, set: { if !$0 { advice = nil } }), titleVisibility: .visible) {
                if let advice { Button("Save to notes") { Task { await model.saveAdvice(advice); self.advice = nil } } }
            } message: { Text("Loopr saves the reply as a note in Protocol, on this iPhone.") }
            .looprHaptic(haptic)
            .onChange(of: sheet) { _, route in if route == .providers { settingsOpened = true; providersOpened = true } }
            .onChange(of: historyPath) { _, path in
                guard !path.isEmpty else { return }
                settingsOpened = true
                if path.contains(.providers) { providersOpened = true }
            }
            .task { await model.load() }
            .onDisappear { dictation.stop(); Task { await model.leave() } }
            .onChange(of: scenePhase) { _, phase in
                // Dictation stops whenever the app is not active. A reply keeps streaming through a
                // Notification Centre pull or a Face ID prompt (.inactive) and stops only in the background.
                if phase != .active { dictation.stop() }
                if phase == .background { Task { await model.leave() } }
            }
            .onChange(of: model.draft) { _, _ in model.draftChanged() }
            .onReceive(model.events) { handle($0) }
            .onChange(of: model.displayProblem?.id) { _, _ in
                guard let problem = model.displayProblem else { return }
                requestScroll(animated: true)
                guard problem.kind != .reconnect else { return }
                haptic = .error
                announce(problem.announcement)
            }
            .onChange(of: dictation.recording) { _, recording in
                haptic = .light
                announce(recording ? "Dictation on" : "Dictation off")
            }
            .onChange(of: dictation.issue) { _, issue in
                if let issue { announce(issue.message) }
            }
    }

    // MARK: Phases

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .loading:
            ScrollView { LooprLoadingPlaceholder(.cards(3)) }.scrollIndicators(.hidden)
        case .needsProvider:
            ScrollView { CoachConnectCard(question: model.origin?.prompt) { sheet = .providers } }.scrollIndicators(.hidden)
        case .failed(let message):
            ScrollView { CoachLoadFailedCard(message: message) { Task { await model.load() } } }.scrollIndicators(.hidden)
        case .ready:
            chat
        }
    }

    /// Done closes the whole sheet, from the menu and from every screen pushed inside it.
    @ToolbarContentBuilder private var sheetDone: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) {
            Button("Done") { sheet = nil }.accessibilityIdentifier("ask-sheet-done")
        }
    }

    private var historyActions: CoachHistoryActions {
        CoachHistoryActions(
            newChat: {
                haptic = .light
                Task { await model.newChat(); requestScroll(animated: false) }
                sheet = nil
            },
            reviewSharedData: { afterDismiss = .reviewSharedData; sheet = nil },
            preferences: { historyPath.append(.preferences) },
            providers: { historyPath.append(.providers) }
        )
    }

    // MARK: Chips

    private var providerName: String? { model.conversation?.configuration.provider.name }

    /// Where Ask opened from, and which provider answers. The provider chip opens AI providers.
    @ViewBuilder private var chipRow: some View {
        if model.origin != nil || providerName != nil {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: LooprSpacing.xs) { originChip; providerChip }
                VStack(alignment: .leading, spacing: LooprSpacing.xs) { originChip; providerChip }
                VStack(alignment: .leading, spacing: LooprSpacing.xs) { originText; providerChip }
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, LooprSpacing.screenGutter)
            .padding(.vertical, LooprSpacing.xs)
            // The thread scrolls under the chips, so they carry their own backdrop. It is opaque: a see-through
            // one lets the scrolled text show behind the chips.
            .background(Color.loopr(.background))
        }
    }

    @ViewBuilder private var originChip: some View {
        if let origin = model.origin {
            StatusChip(origin.chipText, symbol: nil, tone: .neutral)
                .accessibilityIdentifier("ask-origin")
        }
    }

    @ViewBuilder private var originText: some View {
        if let origin = model.origin {
            LooprText(origin.chipText, style: .caption, color: .inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("ask-origin")
        }
    }

    @ViewBuilder private var providerChip: some View {
        if let conversation = model.conversation {
            let provider = conversation.configuration.provider.name
            Button {
                haptic = .light
                sheet = .providers
            } label: {
                StatusChip("\(provider) · your key", symbol: nil, tone: .brand)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(provider), model \(conversation.configuration.model), your key")
            .looprAccessibilityHint("Opens AI providers.")
            .accessibilityIdentifier("ask-provider")
        }
    }

    // MARK: Thread

    private var chat: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: LooprSpacing.md) {
                    if let conversation = model.conversation {
                        header(conversation)
                        if conversation.messages.isEmpty { CoachIntroduction(prompts: AskPrompts.suggestions(for: model.origin), pick: pickStarter, showsStarters: model.draft.isEmpty) }
                        ForEach(conversation.messages) { message in
                            // The problem card says what went wrong, so the last reply drops its own note.
                            CoachMessageRow(message: message, providerName: conversation.configuration.provider.name,
                                            showsStopCaption: model.displayProblem == nil || message.id != conversation.messages.last?.id,
                                            proposals: model.agentProposals[message.id] ?? [],
                                            onSave: { advice = $0 }, onCopy: copy,
                                            onOpenSource: openSource,
                                            onConfirmProposal: { @MainActor @Sendable id in await model.confirmProposal(id) },
                                            onDismissProposal: { @MainActor @Sendable id in await model.dismissProposal(id) })
                                .equatable()
                                .transition(reduces ? .opacity : .opacity.combined(with: .offset(y: 6)))
                        }
                        if showsStandaloneRetry(conversation) {
                            CoachRetryRow { followReply = true; Task { await model.retry() } }
                        }
                        if problemInThread, let problem = model.displayProblem {
                            CoachProblemCard(problem: problem, perform: perform)
                                .transition(.opacity)
                        }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, LooprSpacing.screenGutter)
                .padding(.top, LooprSpacing.sm)
                .padding(.bottom, LooprSpacing.md)
                .animation(reduces ? nil : LooprMotion.stateChange, value: model.conversation?.messages.count)
            }
            .id(model.conversation?.id)
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .scrollEdgeEffectStyle(.soft, for: .top)
            .scrollEdgeEffectStyle(.soft, for: .bottom)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentSize.height + geometry.contentInsets.bottom - geometry.contentOffset.y - geometry.containerSize.height < 100
            } action: { _, value in nearBottom = value }
            .onScrollPhaseChange { _, phase in
                if phase == .interacting { followReply = false }
                if phase == .idle, nearBottom { followReply = true }
            }
            .onChange(of: model.conversation?.messages.last?.text) { _, _ in
                if followReply, model.sending { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: model.conversation?.messages.count) { _, _ in requestScroll(animated: true) }
            .onChange(of: composerFocused) { _, focused in
                if focused { requestScroll(animated: true) }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
                if composerFocused { requestScroll(animated: true) }
            }
            .onChange(of: scrollRequest) { _, request in
                if request.animated && !reduces {
                    withAnimation(LooprMotion.navigation) { proxy.scrollTo("bottom", anchor: .bottom) }
                } else {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
        }
    }

    /// The Shared data button and the Briefing tag. Nothing at all when neither applies, so a new
    /// chat does not start with an empty row.
    @ViewBuilder private func header(_ conversation: CoachConversation) -> some View {
        if conversation.isBriefing || conversation.consentedAt != nil {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: LooprSpacing.sm) {
                    briefingChip(conversation)
                    Spacer(minLength: LooprSpacing.xs)
                    sharedDataButton(conversation)
                }
                VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                    briefingChip(conversation)
                    sharedDataButton(conversation)
                }
            }
        }
    }

    @ViewBuilder private func briefingChip(_ conversation: CoachConversation) -> some View {
        if conversation.isBriefing { StatusChip("Briefing", symbol: "sun.max", tone: .brand) }
    }

    @ViewBuilder private func sharedDataButton(_ conversation: CoachConversation) -> some View {
        if let date = conversation.consentedAt {
            Button { Task { await model.prepareConsent() } } label: {
                Label("Shared data", systemImage: "hand.raised")
            }
            .buttonStyle(CoachCardButtonStyle())
            .disabled(model.sending)
            .accessibilityLabel("Shared data from \(date.formatted(date: .abbreviated, time: .omitted))")
            .looprAccessibilityHint("Review what this chat shares.")
            .accessibilityIdentifier("coach-shared-data")
        }
    }

    private func showsStandaloneRetry(_ conversation: CoachConversation) -> Bool {
        // One place for the action: while a problem card shows, Retry lives there and nowhere else.
        guard !model.sending, model.displayProblem == nil else { return false }
        guard let last = conversation.messages.last else { return false }
        if last.role == .user { return true }
        return last.role == .assistant && (last.status == .failed || last.status == .interrupted)
    }

    private var bottomBar: some View {
        VStack(spacing: LooprSpacing.xs) {
            if model.sending && !nearBottom {
                Button {
                    followReply = true
                    requestScroll(animated: true)
                } label: {
                    Label("Latest", systemImage: "arrow.down")
                        .looprTypography(.label)
                        .foregroundStyle(Color.loopr(.ink))
                        .padding(.horizontal, LooprSpacing.md)
                        .frame(minHeight: 44)
                        .background(.regularMaterial, in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.loopr(.divider), lineWidth: 1))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Jump to latest message")
                .accessibilityIdentifier("coach-jump-latest")
                .transition(.opacity)
            }
            if !problemInThread, let problem = model.displayProblem {
                CoachProblemCard(problem: problem, perform: perform)
                    .padding(.horizontal, LooprSpacing.screenGutter)
                    .transition(.opacity)
            }
            if let info = model.info {
                LooprInlineMessage(info.message, tone: .brand)
                    .padding(.horizontal, LooprSpacing.screenGutter)
                    .transition(.opacity)
                    .accessibilityIdentifier("coach-notice")
            }
            CoachComposer(model: model, dictation: dictation, focus: $composerFocused,
                          sendOrStop: sendOrStop, toggleDictation: toggleDictation, attachPhoto: attachPhoto)
                .disabled(model.reconnectProblem != nil)
        }
        .animation(reduces ? nil : LooprMotion.stateChange, value: model.displayProblem?.id)
        .animation(reduces ? nil : LooprMotion.stateChange, value: model.info?.id)
        .animation(reduces ? nil : LooprMotion.stateChange, value: model.sending && !nearBottom)
    }

    // MARK: Actions

    private func requestScroll(animated: Bool) {
        scrollRequest = ScrollRequest(id: scrollRequest.id + 1, animated: animated)
    }

    private func pickStarter(_ prompt: String) {
        haptic = LooprHaptic(.selection)
        model.draft = prompt
        composerFocused = true
    }

    private func sendOrStop() {
        dictation.stop()
        if model.sending {
            haptic = LooprHaptic(.impact(weight: .medium))
            Task { await model.stop() }
        } else {
            followReply = true; composerFocused = false
            Task { await model.send() }
        }
    }

    private func toggleDictation() {
        if dictation.recording { dictation.stop(); return }
        let original = model.draft
        Task { await dictation.start { model.draft = original + (original.isEmpty ? "" : " ") + $0 } }
    }

    private func copy(_ message: CoachChatMessage) {
        let text = message.role == .user ? message.text : CoachMarkdownParser.plainText(CoachMarkdownParser.parse(message.text))
        UIPasteboard.general.string = text
        haptic = .success
        announce("Reply copied")
    }

    private func perform(_ action: CoachProblem.Action) {
        switch action {
        case .retry: followReply = true; Task { await model.retry() }
        case .openProviders: sheet = .providers
        case .newChat: Task { await model.newChat() }
        case .billing(let url): openURL(url)
        case .dismiss: model.dismissProblem()
        }
    }

    private func sheetDismissed() {
        let reviewData = afterDismiss == .reviewSharedData
        afterDismiss = nil
        historyPath = []
        // A key, model or instruction change in a sheet takes effect on the next load.
        let reload = settingsOpened, reviewedProviders = providersOpened
        settingsOpened = false; providersOpened = false
        Task {
            if reload {
                await model.load()
                if reviewedProviders { model.providersReviewed() }
            }
            if reviewData { await model.prepareConsent() }
        }
    }

    private func handle(_ event: CoachEvent) {
        let name = model.conversation?.configuration.provider.name ?? "Ask"
        switch event.kind {
        case .replyStarted: haptic = .light; announce("\(name) is replying")
        case .replyFinished: haptic = .success; announce("Reply finished")
        case .consentAllowed: haptic = .success
        case .journalSaved: haptic = .success; announce("Saved to your notes")
        case .chatDeleted: haptic = LooprHaptic(.impact(weight: .medium))
        case .startedFreshChat: announce("Started a new chat because the shared data changed")
        }
    }

    private func announce(_ text: String) {
        AccessibilityNotification.Announcement(text).post()
    }
}
