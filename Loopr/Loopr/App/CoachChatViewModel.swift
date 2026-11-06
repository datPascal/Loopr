import AIKit
import Combine
import Foundation

@MainActor
final class CoachChatViewModel: ObservableObject {
    private static let instances = NSHashTable<CoachChatViewModel>.weakObjects()
    private var deleted = false
    /// What the screen shows. `loading` is only the first load, so reloads after a sheet never flash it.
    enum Phase: Hashable { case loading, ready, needsProvider, failed(String) }
    static let draftLimit = 8000
    @Published private(set) var phase = Phase.loading
    @Published private(set) var conversation: CoachConversation?
    @Published private(set) var history: [CoachConversation] = []
    @Published private(set) var preferences = CoachPreferences()
    @Published private(set) var configuration: CoachProviderConfiguration?
    /// Every provider that has a key on this iPhone.
    @Published private(set) var configurations: [CoachProviderConfiguration] = []
    @Published var draft = ""
    @Published var sharing = CoachSharing()
    @Published private(set) var preview = ""
    @Published private(set) var previewDaysWithData: Int?
    @Published private(set) var previewLoading = false
    @Published var showingConsent = false
    /// Why the consent sheet opened when the person did not ask for it, or nil.
    @Published private(set) var consentReason: String?
    /// Failures of the consent sheet itself, kept apart from the chat's own problem.
    @Published private(set) var consentError: String?
    @Published private(set) var sending = false
    /// True while Allow is saving the approved choices. The review cannot be cancelled then.
    @Published private(set) var confirming = false
    @Published private(set) var problem: CoachProblem?
    @Published private(set) var info: CoachInfo?
    /// Haptic and announcement cues. A subject, not a property, so two cues in a row both arrive.
    let events = PassthroughSubject<CoachEvent, Never>()
    var error: String? { problem?.message }
    var notice: String? { info?.message }
    /// The problem to show: a real failure first, then a missing key for this chat's provider.
    var displayProblem: CoachProblem? { problem ?? reconnectProblem }
    var reconnectProblem: CoachProblem? {
        guard phase == .ready, let provider = conversation?.configuration.provider,
              !configurations.contains(where: { $0.provider == provider }) else { return nil }
        return .reconnect(provider: provider)
    }
    var draftCharacterCount: Int { draft.count }
    var draftIsTooLong: Bool { draft.count > Self.draftLimit }
    let runtime: LooprAISettingsRuntime
    let repository: any CoachConversationRepository
    let origin: AskOrigin?
    let context: any LooprCoachContextSource
    /// Tool mode. Nil keeps the plain streaming chat.
    let agent: (any CoachAgentRunning)?
    /// Turns off every domain that Your data has switched off. Applied before each send, so a switch
    /// flipped mid-chat starts a clean chat instead of reusing a summary that holds the domain.
    let sharingFilter: (@Sendable (CoachSharing) -> CoachSharing)?
    /// Confirmation cards for the open chat, by the assistant message they sit under.
    @Published private(set) var agentProposals: [UUID: [StoredAIProposal]] = [:]
    private var requestTask: Task<Void, Never>?
    private var draftTask: Task<Void, Never>?
    private var requestID = UUID()
    private var previewID = UUID()
    private var previewSharing: CoachSharing?
    private var pendingSend = false
    private var submitting = false
    private var loaded = false
    private var infoTask: Task<Void, Never>?
    private var pendingOpenID: UUID?
    private var navigationID = UUID()
    private var navigating = false
    /// The origin's prompt while it sits in the field untouched. It is never saved as a draft, so
    /// opening Ask from Sleep does not leave a "New chat" row in history.
    private var unsavedPrefill: String?
    /// The origin's question, asked while no provider was connected. Once one is, it goes in the field and is sent,
    /// through the usual consent review (ICP R3-NEW-6).
    private var questionWaitingForProvider: String?

    private func isCurrent(_ id: UUID) -> Bool { !deleted && navigationID == id }

    private func beginNavigation() -> UUID {
        navigationID = UUID(); navigating = true
        draftTask?.cancel()
        previewID = UUID(); previewLoading = false; previewSharing = nil
        showingConsent = false; pendingSend = false; consentReason = nil; consentError = nil
        return navigationID
    }

    private func endNavigation(_ id: UUID) {
        if navigationID == id { navigating = false }
    }

    init(repository: any CoachConversationRepository, context: any LooprCoachContextSource, runtime: LooprAISettingsRuntime = .shared,
         origin: AskOrigin? = nil, agent: (any CoachAgentRunning)? = nil,
         sharingFilter: (@Sendable (CoachSharing) -> CoachSharing)? = nil) {
        self.repository = repository
        self.origin = origin
        self.context = origin.map { OriginCoachContext(base: context, origin: $0) as any LooprCoachContextSource } ?? context
        self.runtime = runtime
        self.agent = agent
        if let sharingFilter { self.sharingFilter = sharingFilter }
        else if let agent { self.sharingFilter = { @Sendable (sharing: CoachSharing) -> CoachSharing in agent.effectiveSharing(sharing) } }
        else { self.sharingFilter = nil }
        Self.instances.add(self)
    }
    func load() async {
        guard !deleted, !navigating else { return }
        let navigation = navigationID
        if !loaded, case .failed = phase { phase = .loading }
        do {
            try await runtime.migrateLegacyOpenAI()
            let selected = try await runtime.selectedConfiguration()
            let available = try await runtime.configurations()
            let savedPreferences = try await repository.preferences()
            let savedHistory = try await repository.conversations()
            guard isCurrent(navigation) else { return }
            configuration = selected; configurations = available
            preferences = savedPreferences; history = savedHistory
            if !loaded {
                if origin == nil, let recent = history.first(where: { $0.configuration.provider == configuration?.provider && !$0.isBriefing }) {
                    conversation = recent; draft = recent.draft; sharing = recent.sharing
                }
                loaded = true
            }
            if let id = pendingOpenID {
                // One shot: the request is spent whether or not the chat still exists.
                pendingOpenID = nil
                if let requested = history.first(where: { $0.id == id }), conversation?.id != id {
                    // Same as picking the chat in history: stop a running reply, keep the draft.
                    await open(requested)
                    return
                }
            }
            if let configuration, conversation == nil || (conversation?.messages.isEmpty == true && conversation?.configuration.provider != configuration.provider) {
                var fresh = CoachConversation(configuration: configuration, instructions: preferences.instructions)
                fresh.draft = draft; conversation = fresh; sharing = .init()
                prefillOriginPrompt()
            } else if let configuration, let conversation, conversation.configuration.provider != configuration.provider {
                setInfo("New chats use \(configuration.provider.name). This chat stays with \(conversation.configuration.provider.name).")
            }
            updatePhase()
            await reloadProposals()
            if phase == .ready, let waiting = questionWaitingForProvider {
                questionWaitingForProvider = nil
                if draft == waiting { await send() }
            }
        } catch {
            guard isCurrent(navigation) else { return }
            if loaded { present(error) }
            else { phase = .failed("Loopr could not open your saved chats. Check that your iPhone has free storage, then try again.") }
        }
    }
    /// Opens a chat on the next load, once. A briefing notification passes the briefing it announced.
    func requestOpen(_ id: UUID) {
        pendingOpenID = id
        if loaded { Task { await load() } }
    }
    func refreshHistory() async {
        guard !deleted, let rows = try? await repository.conversations(), !deleted else { return }
        history = rows
    }
    private func updatePhase() {
        if case .failed = phase { return }
        phase = conversation == nil && configurations.isEmpty ? .needsProvider : .ready
        if phase == .needsProvider, let prompt = origin?.prompt { questionWaitingForProvider = prompt }
    }
    func newChat() async {
        guard !deleted else { return }
        let navigation = beginNavigation()
        defer { endNavigation(navigation) }
        await stop()
        guard isCurrent(navigation) else { return }
        await saveDraftNow()
        guard isCurrent(navigation) else { return }
        do {
            let selected = try await runtime.selectedConfiguration()
            let available = try await runtime.configurations()
            guard isCurrent(navigation) else { return }
            configuration = selected; configurations = available
            guard let configuration else { conversation = nil; draft = ""; updatePhase(); return }
            conversation = .init(configuration: configuration, instructions: preferences.instructions)
            draft = ""; sharing = .init(); preview = ""; previewDaysWithData = nil; problem = nil; info = nil
            updatePhase()
            await reloadProposals()
        } catch { if isCurrent(navigation) { present(error) } }
    }
    func open(_ value: CoachConversation) async {
        guard !deleted else { return }
        let navigation = beginNavigation()
        defer { endNavigation(navigation) }
        await stop()
        guard isCurrent(navigation) else { return }
        await saveDraftNow()
        guard isCurrent(navigation) else { return }
        conversation = value; draft = value.draft; sharing = value.sharing; preview = value.context; problem = nil; info = nil
        updatePhase()
        await reloadProposals()
    }
    func delete(_ value: CoachConversation) async {
        guard !deleted else { return }
        let changesSelection = conversation?.id == value.id
        let navigation = changesSelection ? beginNavigation() : navigationID
        defer { if changesSelection { endNavigation(navigation) } }
        if conversation?.id == value.id {
            await stop()
            guard isCurrent(navigation) else { return }
            conversation = nil; draft = ""
        }
        do {
            try await repository.delete(id: value.id)
            // The confirmation cards go with the chat. Nothing the person confirmed is undone.
            await agent?.proposals.deleteProposals(conversationID: value.id)
            let rows = try await repository.conversations()
            guard isCurrent(navigation) else { return }
            history = rows
            if conversation == nil { await newChat() }
            emit(.chatDeleted)
        } catch { if isCurrent(navigation) { problem = .other(title: "Could not delete this chat", message: "Loopr could not remove it. Try again.") } }
    }
    /// Puts the origin's question in an empty field of a new chat. The person still taps Send.
    private func prefillOriginPrompt() {
        guard let prompt = origin?.prompt, draft.isEmpty, conversation?.messages.isEmpty == true else { return }
        draft = prompt; unsavedPrefill = prompt
    }
    func draftChanged() {
        if problem?.kind == .tooLong { problem = nil }
        draftTask?.cancel()
        draftTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await saveDraftNow()
        }
    }
    func saveDraftNow() async {
        guard !deleted else { return }
        guard var value = conversation else { return }
        value.draft = draft; value.updatedAt = Date(); conversation = value
        guard !value.messages.isEmpty || !draft.isEmpty else { return }
        if value.messages.isEmpty, draft == unsavedPrefill { return }
        do { try await persist(value) }
        catch { present(error) }
    }
    func prepareConsent(sendAfter: Bool = false) async {
        guard !deleted, !navigating, !sending else { return }
        pendingSend = sendAfter
        guard conversation != nil else { return }
        consentError = nil
        if !sendAfter { consentReason = nil }
        showingConsent = true
        if !sendAfter, let value = conversation, value.consentedAt != nil {
            // Reopen the review with exactly what this chat approved. Toggles changed in an
            // earlier review that was cancelled must not survive, or Allow would compare
            // them with a preview they never produced.
            sharing = value.sharing
            preview = value.context; previewSharing = value.sharing; previewLoading = false; previewDaysWithData = nil
        } else { await refreshPreview() }
    }
    /// Changes one shared category and rebuilds the preview for it.
    func setShare(_ keyPath: WritableKeyPath<CoachSharing, Bool>, _ value: Bool) {
        guard sharing[keyPath: keyPath] != value else { return }
        sharing[keyPath: keyPath] = value
        Task { await refreshPreview() }
    }
    func refreshPreview() async {
        guard !deleted, !navigating else { return }
        let id = UUID(); previewID = id
        let categories = sharing
        previewLoading = true; preview = ""; previewSharing = nil; previewDaysWithData = nil; consentError = nil
        do {
            let result = try await context.summaryResult(sharing: categories, at: Date())
            guard id == previewID else { return }
            preview = result.text; previewSharing = categories; previewDaysWithData = result.daysWithData; previewLoading = false
        } catch {
            guard id == previewID else { return }
            previewLoading = false
            consentError = "Loopr could not prepare the summary. Tap Refresh summary to try again."
        }
    }
    /// The Cancel button.
    func cancelConsent() {
        guard !confirming else { return }
        showingConsent = false
        consentDismissed()
    }
    /// Runs when the consent sheet is gone, by Cancel, a swipe down or Allow.
    func consentDismissed() {
        guard !showingConsent, !confirming else { return }
        pendingSend = false
        previewID = UUID(); previewLoading = false; consentError = nil
        if let value = conversation { sharing = value.sharing }
    }
    func confirmConsent() async {
        guard !deleted, !navigating, !confirming, !previewLoading, !preview.isEmpty, previewSharing == sharing, var value = conversation else { return }
        let navigation = navigationID
        // What the person approved is fixed here. Nothing below reads the live toggles or preview again.
        let approvedSharing = sharing
        let approvedPreview = preview
        confirming = true; defer { confirming = false }
        // Changing shared categories starts a clean transcript. Prior replies can quote revoked data.
        var startedFresh = false
        if !value.messages.isEmpty && (value.sharing != approvedSharing || value.context != approvedPreview) {
            await saveDraftNow()
            guard isCurrent(navigation) else { return }
            var previous = value
            previous.consentedAt = nil; previous.updatedAt = Date()
            do { try await persist(previous) }
            catch { if isCurrent(navigation) { consentError = CoachProviderError.storage.localizedDescription }; return }
            guard isCurrent(navigation) else { return }
            let savedDraft = draft
            value = .init(configuration: value.configuration, instructions: preferences.instructions)
            value.draft = savedDraft
            startedFresh = true
        }
        do {
            guard let current = try await runtime.configurations().first(where: { $0.provider == value.configuration.provider }) else {
                throw CoachProviderError.missingKey
            }
            guard isCurrent(navigation) else { return }
            value.configuration = current; value.context = approvedPreview; value.sharing = approvedSharing
            value.instructions = preferences.instructions; value.consentedAt = Date(); value.updatedAt = Date()
            try await persist(value)
            guard isCurrent(navigation) else { return }
            conversation = value; showingConsent = false; consentReason = nil
            emit(.consentAllowed)
            if pendingSend { pendingSend = false; await send() }
            // After the send, so starting the reply does not wipe the notice.
            if startedFresh, isCurrent(navigation) {
                setInfo("Started a new chat because the shared data changed.")
                emit(.startedFreshChat)
            }
        } catch { if isCurrent(navigation) { consentError = CoachProviderError.normalize(error).localizedDescription } }
    }
    func send() async {
        guard !deleted, !navigating else { return }
        let navigation = navigationID
        guard !sending, !submitting, !previewLoading else { return }
        submitting = true; defer { submitting = false }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard text.count <= Self.draftLimit else { problem = .tooLong(limit: Self.draftLimit); return }
        guard var value = conversation else { present(CoachProviderError.missingKey); return }
        do {
            guard let current = try await runtime.configurations().first(where: { $0.provider == value.configuration.provider }) else {
                throw CoachProviderError.missingKey
            }
            guard isCurrent(navigation) else { return }
            if value.consentedAt == nil || current != value.configuration {
                if value.consentedAt != nil {
                    consentReason = "Your provider settings changed since this chat started. Review what is shared before you continue."
                } else { consentReason = nil }
                await prepareConsent(sendAfter: true); return
            }
            // A failed assistant turn must be retried or removed before a new user turn is added.
            if value.messages.last?.status != .complete && value.messages.last?.role == .assistant {
                problem = .unfinishedReply(); return
            }
            // Your data may have turned off something this chat was sharing since its summary was built.
            var narrowed = false
            if let fresh = try await narrowedConversation(from: value, current: current) {
                guard isCurrent(navigation) else { return }
                value = fresh; narrowed = true
            }
            value.messages.append(.init(role: .user, text: text))
            if value.messages.count == 1 { value.title = String(text.prefix(70)) }
            value.draft = ""; value.updatedAt = Date()
            _ = try value.request.payload()
            try await persist(value)
            guard isCurrent(navigation) else { return }
            conversation = value; draft = ""; draftTask?.cancel()
            sharing = value.sharing
            beginReply()
            if narrowed { setInfo("Started a new chat because Your data changed."); emit(.startedFreshChat) }
        } catch { if isCurrent(navigation) { present(error) } }
    }
    /// A clean chat with what Your data still allows, when it now blocks something `value` shares. The first
    /// chat stays as it was. Earlier replies may quote what was turned off, so they do not carry over.
    private func narrowedConversation(from value: CoachConversation, current: CoachProviderConfiguration) async throws -> CoachConversation? {
        guard let sharingFilter else { return nil }
        let allowed = sharingFilter(value.sharing)
        guard allowed != value.sharing else { return nil }
        let summary = try await context.summaryResult(sharing: allowed, at: Date())
        var fresh = CoachConversation(configuration: current, instructions: preferences.instructions)
        fresh.sharing = allowed; fresh.context = summary.text; fresh.consentedAt = value.consentedAt
        return fresh
    }
    func retry() async {
        guard !deleted, !navigating, !sending, !submitting, var value = conversation else { return }
        let navigation = navigationID
        submitting = true; defer { submitting = false }
        if value.messages.last?.role == .assistant && value.messages.last?.status != .complete { value.messages.removeLast() }
        guard value.messages.last?.role == .user else { return }
        do {
            guard let current = try await runtime.configurations().first(where: { $0.provider == value.configuration.provider }) else {
                throw CoachProviderError.missingKey
            }
            guard isCurrent(navigation) else { return }
            if value.consentedAt == nil || current != value.configuration {
                // A renewed consent review must not silently reuse the previous transcript.
                await saveDraftNow()
                guard isCurrent(navigation) else { return }
                conversation = .init(configuration: current, instructions: preferences.instructions)
                draft = value.messages.last?.text ?? ""; sharing = .init(); preview = ""
                consentReason = value.consentedAt != nil
                    ? "Your provider settings changed since this chat started. Review what is shared before you continue." : nil
                await prepareConsent(sendAfter: true); return
            }
            var narrowed = false
            if let fresh = try await narrowedConversation(from: value, current: current), let last = value.messages.last {
                guard isCurrent(navigation) else { return }
                var moved = fresh; moved.messages = [last]; value = moved; narrowed = true
            }
            _ = try value.request.payload(); value.updatedAt = Date()
            try await persist(value)
            guard isCurrent(navigation) else { return }
            conversation = value; sharing = value.sharing; beginReply()
            if narrowed { setInfo("Started a new chat because Your data changed."); emit(.startedFreshChat) }
        } catch { if isCurrent(navigation) { present(error) } }
    }
    private func beginReply() {
        guard var value = conversation else { return }
        var built = value.request
        built.recording = AIRequestContext(purpose: .chat, conversationID: value.id, origin: origin.map { "\($0.screen), \($0.day)" })
        let request = built
        // The tool path sends this chat as it is now, before the empty reply is added.
        let asked = value
        let id = UUID(); requestID = id
        let placeholder = CoachChatMessage(role: .assistant, text: "", status: .streaming)
        value.messages.append(placeholder); value.updatedAt = Date()
        conversation = value; sending = true; problem = nil
        emit(.replyStarted)
        let toolMode = agent
        let askedFrom = origin
        requestTask = Task {
            var terminal = false
            var lastSave = Date()
            do {
                try Task.checkCancellation()
                try await persist(value)
                try Task.checkCancellation()
                if let toolMode {
                    // Tool mode does not stream. The reply arrives whole, after any lookups.
                    let output = try await toolMode.run(conversation: asked, assistantMessageID: placeholder.id, origin: askedFrom)
                    try Task.checkCancellation()
                    guard requestID == id, conversation?.id == value.id else { return }
                    guard !output.text.isEmpty else { throw CoachProviderError.incomplete }
                    if var updated = conversation, !updated.messages.isEmpty {
                        // Sources, charts and card ids are saved with the reply, so they are still there after a relaunch.
                        updated.messages[updated.messages.count - 1].text = output.text
                        updated.messages[updated.messages.count - 1].attachments = output.artifacts.attachments
                        conversation = updated
                    }
                    // Cards first, so they are there the moment the reply counts as finished.
                    await reloadProposals()
                    await finish(id: id, status: .complete, reason: nil)
                    return
                }
                let replyStream = try await runtime.stream(request)
                for try await event in replyStream {
                    try Task.checkCancellation()
                    guard requestID == id, conversation?.id == value.id else { return }
                    switch event {
                    case .text(let text):
                        if var updated = conversation, !updated.messages.isEmpty {
                            updated.messages[updated.messages.count - 1].text += text; conversation = updated
                        }
                    case .completed: terminal = true
                    }
                    if Date().timeIntervalSince(lastSave) > 1, var snapshot = conversation {
                        snapshot.updatedAt = Date(); conversation = snapshot
                        try await persist(snapshot); lastSave = Date()
                    }
                }
                guard terminal, conversation?.messages.last?.text.isEmpty == false else { throw CoachProviderError.incomplete }
                try Task.checkCancellation()
                await finish(id: id, status: .complete, reason: nil)
            } catch {
                guard requestID == id else { return }
                let failure: CoachProviderError = Task.isCancelled ? .cancelled : CoachProviderError.normalize(error)
                let partial = conversation?.messages.last?.text.isEmpty == false
                if let card = CoachProblem.make(failure, provider: request.configuration.provider, hadPartialReply: partial) {
                    // A drop after text arrived is an interruption: keep the partial reply and offer Retry.
                    let dropped = card.kind == .interrupted
                    problem = card
                    await finish(id: id, status: dropped ? .interrupted : .failed, reason: dropped ? .connectionLost : .failed)
                } else {
                    await finish(id: id, status: .interrupted, reason: .stopped)
                }
                await reloadProposals()
            }
        }
    }
    private func finish(id: UUID, status: CoachChatMessage.Status, reason: CoachChatMessage.StopReason?) async {
        guard requestID == id, var value = conversation else { return }
        defer { if requestID == id { sending = false } }
        if !value.messages.isEmpty {
            value.messages[value.messages.count - 1].status = status
            value.messages[value.messages.count - 1].stopReason = reason
        }
        value.updatedAt = Date(); conversation = value
        if status == .complete { emit(.replyFinished) }
        do { try await persist(value); history = try await repository.conversations() }
        catch { present(error) }
    }
    func stop() async {
        let id = requestID
        let task = requestTask
        task?.cancel()
        await task?.value
        if requestID == id { requestTask = nil }
    }
    func leave() async {
        let navigation = beginNavigation()
        defer { endNavigation(navigation) }
        await stop()
        guard isCurrent(navigation) else { return }
        await saveDraftNow()
    }
    func saveAdvice(_ message: CoachChatMessage) async {
        guard !deleted, message.role == .assistant, message.status == .complete, !message.text.isEmpty else { return }
        let navigation = navigationID
        do {
            let entryID = try await context.saveAdvice(message: message, at: Date())
            guard isCurrent(navigation), var value = conversation, let index = value.messages.firstIndex(where: { $0.id == message.id }) else { return }
            value.messages[index].journalEntryID = entryID; value.updatedAt = Date()
            conversation = value
            try await persist(value)
            guard isCurrent(navigation) else { return }
            setInfo("Saved to your notes.")
            emit(.journalSaved)
        } catch { if isCurrent(navigation) { problem = .other(title: "Could not save to your notes", message: "Loopr could not save this reply. Try again.") } }
    }
    /// Loads the confirmation cards for the open chat, grouped under their reply.
    func reloadProposals() async {
        guard !deleted, let agent, let id = conversation?.id else { agentProposals = [:]; return }
        let rows = await agent.proposals.proposals(conversationID: id)
        guard conversation?.id == id, !deleted else { return }
        agentProposals = Dictionary(grouping: rows.filter { $0.messageID != nil }, by: { $0.messageID! })
    }
    /// The Confirm tap. This is the only way an agent proposal turns into a saved change.
    func confirmProposal(_ id: UUID) async {
        guard !deleted, let agent else { return }
        let result = await agent.proposals.confirm(id: id)
        await reloadProposals()
        if let failure = result.failure {
            problem = .other(title: "Could not save this", message: failure)
        } else if result.applied, let done = result.proposal?.card?.doneText {
            setInfo(done)
        }
    }
    /// "Not now". Nothing is saved.
    func dismissProposal(_ id: UUID) async {
        guard !deleted, let agent else { return }
        _ = await agent.proposals.dismiss(id: id)
        await reloadProposals()
        setInfo(AgentProposalCopy.dismissedText)
    }
    func dismissProblem() { problem = nil }
    /// Clears a key or billing problem once the person has been to the provider settings.
    func providersReviewed() {
        if problem?.kind == .credentials || problem?.kind == .quota { problem = nil }
    }
    private func present(_ error: Error) {
        let provider = conversation?.configuration.provider ?? configuration?.provider ?? .openAI
        problem = CoachProblem.make(error, provider: provider, hadPartialReply: false)
    }
    private func persist(_ value: CoachConversation) async throws {
        do { try await repository.save(value) } catch { throw CoachProviderError.storage }
    }
    private func emit(_ kind: CoachEvent.Kind) { events.send(CoachEvent(kind: kind)) }
    private func setInfo(_ message: String) {
        infoTask?.cancel()
        info = CoachInfo(message: message)
        infoTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            info = nil
        }
    }
    static func resetAllForDeletion() async {
        for model in instances.allObjects where model.runtime === LooprAISettingsRuntime.shared {
            model.deleted = true; _ = model.beginNavigation(); await model.stop()
            model.conversation = nil; model.history = []; model.draft = ""
            model.problem = nil; model.info = nil; model.configurations = []; model.configuration = nil
            model.agentProposals = [:]
            model.phase = .needsProvider
        }
    }
    func savePreferences(_ value: CoachPreferences) async throws {
        guard value.instructions.count <= 4000 else { throw CoachProviderError.conversationFull }
        try await repository.savePreferences(value); preferences = value
    }
}
