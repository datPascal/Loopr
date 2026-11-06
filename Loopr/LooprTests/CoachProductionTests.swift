import AIKit
import Foundation
import StorageKit
import Testing
@testable import Loopr

private actor CoachTestCredentials: AICredentialStore {
    var value: Data?
    private var readGate: CoachSaveGate?
    func write(_ value: Data) { self.value = value }
    func read() async -> Data? {
        if let gate = readGate {
            readGate = nil
            await gate.pause()
        }
        return value
    }
    func pauseRead(_ gate: CoachSaveGate) { readGate = gate }
    func remove() { value = nil }
}
private actor CoachTestRepository: CoachConversationRepository {
    var rows: [UUID: CoachConversation] = [:]
    var prefs = CoachPreferences()
    var failWrites = false
    private var pausedSave: (CoachSaveGate, @Sendable (CoachConversation) -> Bool)?
    private var preferenceGate: CoachSaveGate?
    func conversations() -> [CoachConversation] { rows.values.sorted { $0.updatedAt > $1.updatedAt } }
    func save(_ conversation: CoachConversation) async throws {
        if failWrites { throw CoachProviderError.storage }
        if let (gate, matches) = pausedSave, matches(conversation) {
            pausedSave = nil
            await gate.pause()
        }
        rows[conversation.id] = conversation
    }
    func pauseSave(_ gate: CoachSaveGate, matching predicate: @escaping @Sendable (CoachConversation) -> Bool) {
        pausedSave = (gate, predicate)
    }
    func delete(id: UUID) { rows[id] = nil }
    func preferences() -> CoachPreferences { prefs }
    func savePreferences(_ preferences: CoachPreferences) async {
        if let gate = preferenceGate {
            preferenceGate = nil
            await gate.pause()
        }
        prefs = preferences
    }
    func pausePreferencesSave(_ gate: CoachSaveGate) { preferenceGate = gate }
    func fail() { failWrites = true }
}
private actor CoachSaveGate {
    private var entered = false
    private var entryWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    func pause() async {
        entered = true
        entryWaiter?.resume(); entryWaiter = nil
        await withCheckedContinuation { releaseWaiter = $0 }
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { entryWaiter = $0 }
    }
    func release() { releaseWaiter?.resume(); releaseWaiter = nil }
}
private actor CoachTestContext: LooprCoachContextSource {
    var sharing: [CoachSharing] = []
    var notes: [UUID: String] = [:]
    private var summaryGate: CoachSaveGate?
    func pauseSummary(_ gate: CoachSaveGate) { summaryGate = gate }
    func summary(sharing: CoachSharing, at date: Date) async -> String {
        self.sharing.append(sharing)
        if let gate = summaryGate {
            summaryGate = nil
            await gate.pause()
        }
        return "metrics=\(sharing.metrics),journal=\(sharing.journal),cycle=\(sharing.cycle)"
    }
    func saveAdvice(message: CoachChatMessage, at date: Date) -> UUID { notes[message.id] = message.text; return message.id }
    func noteCount() -> Int { notes.count }
}
private actor CoachRequestRecorder {
    var requests: [CoachChatRequest] = []
    func append(_ request: CoachChatRequest) { requests.append(request) }
    func count() -> Int { requests.count }
}
private struct CoachTestTransport: CoachChatTransport {
    let recorder: CoachRequestRecorder
    var delay = false
    var fail = false
    func stream(_ request: CoachChatRequest, key: String) -> AsyncThrowingStream<CoachStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await recorder.append(request)
                continuation.yield(.text("Keep today easy."))
                do {
                    if delay { try await Task.sleep(for: .seconds(60)) }
                    if fail { throw CoachProviderError.rateLimited }
                    continuation.yield(.completed); continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    func models(provider: CoachProvider, key: String) async throws -> [String] { [provider.defaultModel] }
}

@Suite(.serialized)
@MainActor
struct CoachProductionTests {
    private func fixture(delay: Bool = false, fail: Bool = false) async throws -> (CoachChatViewModel, CoachRequestRecorder, CoachTestRepository, CoachTestContext, String) {
        let suite = "LooprCoachTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let recorder = CoachRequestRecorder()
        let runtime = LooprAISettingsRuntime(defaults: defaults, stores: [.openAI: CoachTestCredentials(), .anthropic: CoachTestCredentials()], transport: CoachTestTransport(recorder: recorder, delay: delay, fail: fail))
        try await runtime.configure(provider: .openAI, model: "gpt-6-luna", apiKey: "fixture-openai")
        let repository = CoachTestRepository(); let context = CoachTestContext()
        let model = CoachChatViewModel(repository: repository, context: context, runtime: runtime)
        await model.load()
        return (model, recorder, repository, context, suite)
    }
    private func drain(_ model: CoachChatViewModel) async throws {
        for _ in 0..<200 {
            if !model.sending { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Coach request did not finish")
    }
    @Test func openingAndDraftingNeverSendsAndConsentIsRequired() async throws {
        let (model, recorder, _, _, suite) = try await fixture()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        #expect(await recorder.count() == 0)
        model.draft = "What should I do today?"
        await model.send()
        #expect(model.showingConsent)
        #expect(await recorder.count() == 0)
        #expect(!model.sharing.journal && !model.sharing.cycle)
        await model.confirmConsent(); try await drain(model)
        #expect(await recorder.count() == 1)
        #expect(model.conversation?.messages.count == 2)
        #expect(model.conversation?.messages.last?.status == .complete)
        model.draft = "Why?"; await model.send(); try await drain(model)
        #expect(await recorder.count() == 2)
        #expect(!model.showingConsent)
    }
    @Test func changingSharingStartsCleanConversationWithoutPriorSensitiveReplies() async throws {
        let (model, recorder, repository, _, suite) = try await fixture()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        model.sharing.journal = true; model.draft = "Help with recovery"
        await model.send(); await model.confirmConsent(); try await drain(model)
        let oldID = model.conversation?.id
        await model.prepareConsent(); model.sharing.journal = false; await model.refreshPreview(); await model.confirmConsent()
        #expect(model.conversation?.id != oldID)
        #expect(model.conversation?.messages.isEmpty == true)
        #expect(model.conversation?.context.contains("journal=false") == true)
        #expect(await repository.conversations().count == 2)
        #expect(await repository.conversations().first(where: { $0.id == oldID })?.consentedAt == nil)
        #expect(await recorder.count() == 1)
    }
    @Test func interruptedReplyIsPersistedAndRetryDoesNotDuplicateUserTurn() async throws {
        let (model, recorder, repository, _, suite) = try await fixture(delay: true)
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        model.draft = "Training advice"; await model.send(); await model.confirmConsent()
        for _ in 0..<200 { if await recorder.count() > 0 { break }; await Task.yield() }
        await model.stop()
        #expect(!model.sending)
        #expect(model.conversation?.messages.last?.status == .interrupted)
        #expect(await repository.conversations().first?.messages.last?.status == .interrupted)
        await model.retry()
        for _ in 0..<200 { if await recorder.count() > 1 { break }; await Task.yield() }
        await model.stop()
        #expect(model.conversation?.messages.filter { $0.role == .user }.count == 1)
    }
    @Test func failedPersistencePreventsPaidRequest() async throws {
        let (model, recorder, repository, _, suite) = try await fixture()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        await model.prepareConsent(); await model.confirmConsent()
        await repository.fail(); model.draft = "Do not send"
        await model.send()
        #expect(await recorder.count() == 0)
        #expect(model.error != nil)
        #expect(model.draft == "Do not send")
    }
    @Test func retryAfterConsentRevocationRequiresFreshReviewAndTranscript() async throws {
        let (model, recorder, _, _, suite) = try await fixture(fail: true)
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        model.sharing.journal = true; model.draft = "Training advice"
        await model.send(); await model.confirmConsent(); try await drain(model)
        var archived = try #require(model.conversation)
        archived.consentedAt = nil
        await model.open(archived); await model.retry()
        #expect(await recorder.count() == 1)
        #expect(model.showingConsent)
        #expect(model.conversation?.id != archived.id)
        #expect(model.conversation?.messages.isEmpty == true)
        #expect(!model.sharing.journal && !model.sharing.cycle)
        await model.confirmConsent(); try await drain(model)
        #expect(await recorder.count() == 2)
        #expect(model.conversation?.messages.filter { $0.role == .user }.count == 1)
    }
    @Test func retryAfterKeyReplacementRequiresConsentEvenWhenSummaryIsUnchanged() async throws {
        let (model, recorder, _, _, suite) = try await fixture(fail: true)
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        model.draft = "Training advice"
        await model.send(); await model.confirmConsent(); try await drain(model)
        let oldID = model.conversation?.id
        try await model.runtime.configure(provider: .openAI, model: "gpt-6-luna", apiKey: "replacement-fixture")
        await model.retry()
        #expect(await recorder.count() == 1)
        #expect(model.showingConsent)
        #expect(model.conversation?.id != oldID)
        await model.confirmConsent(); try await drain(model)
        #expect(await recorder.count() == 2)
        #expect(model.conversation?.messages.filter { $0.role == .user }.count == 1)
    }
    @Test func consentCannotApproveCategoriesThatWereNotPreviewed() async throws {
        let (model, recorder, _, _, suite) = try await fixture()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        model.draft = "Help"; await model.send()
        model.sharing.journal = true
        await model.confirmConsent()
        #expect(await recorder.count() == 0)
        #expect(model.conversation?.consentedAt == nil)
        await model.refreshPreview(); await model.confirmConsent(); try await drain(model)
        #expect(await recorder.count() == 1)
        #expect(model.conversation?.context.contains("journal=true") == true)
    }
    @Test func providerRemovalCancelsActiveRequestAndLeavesHistory() async throws {
        let (model, recorder, _, _, suite) = try await fixture(delay: true)
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        model.draft = "Help"; await model.send(); await model.confirmConsent()
        for _ in 0..<200 { if await recorder.count() > 0 { break }; await Task.yield() }
        try await model.runtime.remove(.openAI); try await drain(model)
        #expect(!model.sending)
        #expect(model.conversation?.messages.last?.status != .complete)
        #expect(try await model.runtime.configurations().isEmpty)
    }
    @Test func savingAdviceRequiresUserActionAndIsIdempotent() async throws {
        let (model, _, _, context, suite) = try await fixture()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        model.draft = "Help"; await model.send(); await model.confirmConsent(); try await drain(model)
        #expect(await context.noteCount() == 0)
        let message = try #require(model.conversation?.messages.last)
        await model.saveAdvice(message); await model.saveAdvice(message)
        #expect(await context.noteCount() == 1)
        #expect(model.conversation?.messages.last?.journalEntryID == message.id)
    }
    @Test func stopDuringInitialReplySaveDoesNotDispatchProviderRequest() async throws {
        let (model, recorder, repository, _, suite) = try await fixture()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        await model.prepareConsent(); await model.confirmConsent()
        let gate = CoachSaveGate()
        await repository.pauseSave(gate) { $0.messages.last?.status == .streaming }
        model.draft = "Cancel before sending"; await model.send()
        await gate.waitUntilEntered()
        let stopping = Task { await model.stop() }
        for _ in 0..<100 { await Task.yield() }
        await gate.release(); await stopping.value
        #expect(await recorder.count() == 0)
        #expect(!model.sending)
        #expect(model.conversation?.messages.last?.status == .interrupted)
    }
    @Test func replyRemainsBusyUntilItsFinalSaveCompletes() async throws {
        let (model, _, repository, _, suite) = try await fixture()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        await model.prepareConsent(); await model.confirmConsent()
        let gate = CoachSaveGate()
        await repository.pauseSave(gate) { $0.messages.last?.role == .assistant && $0.messages.last?.status == .complete }
        model.draft = "Help"; await model.send()
        await gate.waitUntilEntered()
        #expect(model.sending)
        await gate.release(); try await drain(model)
        #expect(!model.sending)
    }
    @Test func delayedAdviceSaveDoesNotReopenPreviousChat() async throws {
        let (model, _, repository, _, suite) = try await fixture()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        model.draft = "Help"; await model.send(); await model.confirmConsent(); try await drain(model)
        let message = try #require(model.conversation?.messages.last)
        let other = CoachConversation(configuration: try #require(model.configuration))
        let gate = CoachSaveGate()
        await repository.pauseSave(gate) { $0.messages.last?.journalEntryID != nil }
        let saving = Task { await model.saveAdvice(message) }
        await gate.waitUntilEntered()
        await model.open(other)
        await gate.release(); await saving.value
        #expect(model.conversation?.id == other.id)
    }
    @Test func newChatInvalidatesSendWaitingForPersistence() async throws {
        let (model, recorder, repository, _, suite) = try await fixture()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        await model.prepareConsent(); await model.confirmConsent()
        let gate = CoachSaveGate()
        await repository.pauseSave(gate) { $0.messages.last?.role == .user }
        model.draft = "Do not send after leaving"
        let sending = Task { await model.send() }
        await gate.waitUntilEntered()
        await model.newChat()
        let newID = model.conversation?.id
        await gate.release(); await sending.value; try await drain(model)
        #expect(model.conversation?.id == newID)
        #expect(await recorder.count() == 0)
    }
    @Test func openingAnotherChatInvalidatesPendingConsentSave() async throws {
        let (model, recorder, repository, _, suite) = try await fixture()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        model.draft = "Help"; await model.send()
        let other = CoachConversation(configuration: try #require(model.configuration))
        let gate = CoachSaveGate()
        await repository.pauseSave(gate) { $0.consentedAt != nil }
        let allowing = Task { await model.confirmConsent() }
        await gate.waitUntilEntered()
        await model.open(other)
        await gate.release(); await allowing.value
        #expect(model.conversation?.id == other.id)
        #expect(!model.showingConsent)
        #expect(await recorder.count() == 0)
    }
    @Test func newChatDiscardsSummaryFromPreviousConsentReview() async throws {
        let (model, _, _, context, suite) = try await fixture()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let gate = CoachSaveGate()
        await context.pauseSummary(gate)
        let previewing = Task { await model.prepareConsent() }
        await gate.waitUntilEntered()
        await model.newChat()
        await gate.release(); await previewing.value
        #expect(model.preview.isEmpty)
        #expect(!model.previewLoading)
        #expect(!model.showingConsent)
    }
    @Test func cancellingBriefingDuringAttemptSavePreventsProviderRequest() async throws {
        let (model, recorder, repository, context, suite) = try await fixture()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        var preferences = CoachPreferences()
        preferences.morningEnabled = true; preferences.morningHour = 0
        preferences.morningConfiguration = try await model.runtime.selectedConfiguration()
        preferences.morningConsentAt = Date()
        await repository.savePreferences(preferences)
        let gate = CoachSaveGate()
        await repository.pausePreferencesSave(gate)
        let scheduler = CoachBriefingRuntime(repository: repository, context: context, runtime: model.runtime, notify: { _, _ in Issue.record("Cancelled briefing notified") })
        let work = Task { await scheduler.runIfDue() }
        await gate.waitUntilEntered()
        let stopping = Task { await scheduler.cancel() }
        for _ in 0..<100 { await Task.yield() }
        await gate.release(); await stopping.value; await work.value
        #expect(await recorder.count() == 0)
        #expect(await repository.conversations().isEmpty)
    }
    @Test func cancellingBriefingDuringChatSavePreventsNotification() async throws {
        let (model, _, repository, context, suite) = try await fixture()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        var preferences = CoachPreferences()
        preferences.morningEnabled = true; preferences.morningHour = 0
        preferences.morningConfiguration = try await model.runtime.selectedConfiguration()
        preferences.morningConsentAt = Date()
        await repository.savePreferences(preferences)
        let gate = CoachSaveGate()
        await repository.pauseSave(gate) { $0.isBriefing }
        let scheduler = CoachBriefingRuntime(repository: repository, context: context, runtime: model.runtime, notify: { _, _ in Issue.record("Cancelled briefing notified") })
        let work = Task { await scheduler.runIfDue() }
        await gate.waitUntilEntered()
        let stopping = Task { await scheduler.cancel() }
        for _ in 0..<100 { await Task.yield() }
        await gate.release(); await stopping.value; await work.value
        #expect(await repository.preferences().lastBriefingDay == nil)
    }
    @Test(arguments: [true, false]) func cancellingWhileCredentialsLoadNeverStartsTransport(cancelCaller: Bool) async throws {
        let suite = "LooprCoachPendingKey.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CoachTestCredentials()
        let recorder = CoachRequestRecorder()
        let runtime = LooprAISettingsRuntime(defaults: defaults, stores: [.openAI: store], transport: CoachTestTransport(recorder: recorder))
        try await runtime.configure(provider: .openAI, model: "gpt-6-luna", apiKey: "fixture")
        let configuration = try #require(try await runtime.selectedConfiguration())
        let request = CoachChatRequest(configuration: configuration, instructions: "", context: "", messages: [.init(role: .user, text: "Help")])
        let gate = CoachSaveGate()
        await store.pauseRead(gate)
        let work = Task {
            do {
                for try await _ in try await runtime.stream(request) {}
                return false
            } catch { return CoachProviderError.normalize(error) == .cancelled }
        }
        await gate.waitUntilEntered()
        if cancelCaller { work.cancel() } else { await runtime.cancelRequests() }
        await gate.release()
        #expect(await work.value)
        #expect(await recorder.count() == 0)
    }
    @Test func keysStaySeparateAcrossProvidersAndRelaunch() async throws {
        let suite = "LooprCoachKeys.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let openAI = CoachTestCredentials(); let claude = CoachTestCredentials()
        let stores: [CoachProvider: any AICredentialStore] = [.openAI: openAI, .anthropic: claude]
        let runtime = LooprAISettingsRuntime(defaults: defaults, stores: stores)
        try await runtime.configure(provider: .openAI, model: "gpt-6-luna", apiKey: "  openai-secret  ")
        try await runtime.configure(provider: .anthropic, model: "claude-haiku-5-5", apiKey: "claude-secret")
        #expect(await openAI.read() == Data("openai-secret".utf8))
        #expect(await claude.read() == Data("claude-secret".utf8))
        let relaunched = LooprAISettingsRuntime(defaults: defaults, stores: stores)
        #expect(try await relaunched.selectedConfiguration()?.provider == .anthropic)
        try await relaunched.configure(provider: .anthropic, model: "custom-model", apiKey: "")
        #expect(await claude.read() == Data("claude-secret".utf8))
        try await relaunched.remove(.openAI)
        #expect(await openAI.read() == nil)
        #expect(await claude.read() != nil)
        #expect(!defaults.dictionaryRepresentation().description.contains("secret"))
    }
    @Test func morningBriefingNeedsSeparateConsentAndRunsOnlyOncePerDay() async throws {
        let (model, recorder, repository, context, suite) = try await fixture()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let scheduler = CoachBriefingRuntime(repository: repository, context: context, runtime: model.runtime, notify: { _, _ in })
        let now = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
        await scheduler.runIfDue(now: now)
        #expect(await recorder.count() == 0)
        var preferences = CoachPreferences()
        preferences.morningEnabled = true; preferences.morningConfiguration = try await model.runtime.selectedConfiguration()
        await repository.savePreferences(preferences)
        await scheduler.runIfDue(now: now)
        #expect(await recorder.count() == 0)
        preferences.morningConsentAt = now
        await repository.savePreferences(preferences)
        await scheduler.runIfDue(now: now); await scheduler.runIfDue(now: now)
        #expect(await recorder.count() == 1)
        #expect(await repository.conversations().first?.isBriefing == true)
        #expect(await repository.preferences().lastBriefingDay == LooprCoachContextBuilder.dayString(now))
    }
    @Test func cancellingMorningBriefingCannotPublishAfterConsentIsRevoked() async throws {
        let (model, recorder, repository, context, suite) = try await fixture(delay: true)
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        var preferences = CoachPreferences()
        preferences.morningEnabled = true; preferences.morningHour = 0
        preferences.morningConfiguration = try await model.runtime.selectedConfiguration(); preferences.morningConsentAt = Date()
        await repository.savePreferences(preferences)
        let scheduler = CoachBriefingRuntime(repository: repository, context: context, runtime: model.runtime, notify: { _, _ in Issue.record("Revoked briefing published a notification") })
        let work = Task { await scheduler.runIfDue() }
        for _ in 0..<200 { if await recorder.count() > 0 { break }; await Task.yield() }
        preferences.morningEnabled = false; preferences.morningConsentAt = nil
        await repository.savePreferences(preferences)
        await scheduler.cancel(); await work.value
        #expect(await repository.conversations().isEmpty)
        #expect(await repository.preferences().lastBriefingDay == nil)
    }
    @Test func sqliteChatRecoversInterruptedRepliesAndCannotResurrectDeletedChat() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("coach-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let db = try StorageDatabase(url: url, applicationVersion: "test")
        let store = try SQLiteCoachConversationRepository(database: db)
        var chat = CoachConversation(configuration: .init(provider: .openAI, model: "test"))
        chat.draft = "Saved draft"; chat.messages = [.init(role: .assistant, text: "Partial", status: .streaming)]
        try await store.save(chat)
        let reopened = try SQLiteCoachConversationRepository(database: db)
        let restored = try #require(try await reopened.conversations().first)
        #expect(restored.draft == "Saved draft")
        #expect(restored.messages.last?.status == .interrupted)
        try await store.delete(id: chat.id); try await store.save(chat)
        #expect(try await store.conversations().isEmpty)
    }
}

struct CoachProviderContractTests {
    @Test func providerPayloadsUseCorrectEnvelopesAndNeverIncludeKeys() throws {
        for provider in CoachProvider.allCases {
            let request = CoachChatRequest(configuration: .init(provider: provider, model: provider.defaultModel), instructions: "Be brief", context: "Recovery 60, partial", messages: [.init(role: .user, text: "How should I train?")])
            let data = try request.payload()
            let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(json["model"] as? String == provider.defaultModel)
            #expect(json["stream"] as? Bool == true)
            #expect(json["temperature"] == nil)
            if provider == .openAI { #expect(json["store"] as? Bool == false); #expect(json["input"] != nil); #expect(json["messages"] == nil) }
            else { #expect(json["system"] != nil); #expect(json["messages"] != nil); #expect(json["input"] == nil) }
            let urlRequest = try CoachURLSessionTransport.urlRequest(provider: provider, path: "/v1/models", key: "fixture")
            #expect(urlRequest.url?.scheme == "https")
            #expect(urlRequest.url?.host == provider.host)
            #expect(urlRequest.value(forHTTPHeaderField: provider == .openAI ? "Authorization" : "x-api-key") == (provider == .openAI ? "Bearer fixture" : "fixture"))
            #expect(urlRequest.value(forHTTPHeaderField: provider == .openAI ? "x-api-key" : "Authorization") == nil)
        }
    }
    @Test func streamingParsesTextAndRequiresTerminalEvent() throws {
        var parser = CoachSSEParser(provider: .openAI)
        #expect(try parser.consume("data: {\"type\":\"response.output_text.delta\",\"delta\":\"hello\"}").isEmpty)
        #expect(try parser.consume("") == [.text("hello")])
        #expect(!parser.completed)
        _ = try parser.consume("data: {\"type\":\"response.completed\"}")
        #expect(try parser.consume("") == [.completed])
        #expect(parser.completed)
    }
    @Test func claudeThinkingIsExcludedAndMidStreamErrorsAreNotSuccess() throws {
        var parser = CoachSSEParser(provider: .anthropic)
        _ = try parser.consume("data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"private reasoning\"}}")
        #expect(try parser.consume("").isEmpty)
        _ = try parser.consume("data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"hello\"}}")
        #expect(try parser.consume("") == [.text("hello")])
        _ = try parser.consume("data: {\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\"}}")
        #expect(throws: CoachProviderError.server) { try parser.consume("") }
        #expect(!parser.completed)
    }
    @Test func byteDecoderPreservesEmptyLinesCRLFAndUnicodeAcrossChunks() throws {
        var decoder = CoachSSEDecoder(provider: .openAI)
        let body = "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Grüße 🌿\"}\r\n\r\ndata: {\"type\":\"response.completed\"}\r\n\r\n"
        var events: [CoachStreamEvent] = []
        for byte in body.utf8 { events += try decoder.consume(byte) }
        #expect(events == [.text("Grüße 🌿"), .completed])
        #expect(decoder.completed)
    }
    @Test func limitsAndBillingFailuresAreActionable() throws {
        let quota = Data("{\"error\":{\"code\":\"insufficient_quota\"}}".utf8)
        #expect(CoachProviderError.response(status: 429, body: quota) == .quota)
        #expect(CoachProviderError.response(status: 429) == .rateLimited)
        #expect(CoachProviderError.response(status: 402) == .quota)
        #expect(CoachProviderError.response(status: 401) == .invalidKey)
        #expect(CoachProviderError.normalize(URLError(.cancelled)) == .cancelled)
        let request = CoachChatRequest(configuration: .init(provider: .openAI, model: "test"), instructions: "", context: "", messages: [.init(role: .user, text: String(repeating: "x", count: 100_001))])
        #expect(throws: CoachProviderError.conversationFull) { try request.payload() }
    }
}
