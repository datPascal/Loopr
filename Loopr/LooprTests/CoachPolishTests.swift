import AIKit
import Combine
import Foundation
import StorageKit
import Testing
@testable import Loopr

private actor PolishCredentials: AICredentialStore {
    var value: Data?
    func write(_ value: Data) { self.value = value }
    func read() -> Data? { value }
    func remove() { value = nil }
}
private actor PolishRepository: CoachConversationRepository {
    var rows: [UUID: CoachConversation] = [:]
    var prefs = CoachPreferences()
    var delay: Duration?
    func slow(_ value: Duration) { delay = value }
    func conversations() async -> [CoachConversation] {
        if let delay { try? await Task.sleep(for: delay) }
        return rows.values.sorted { $0.updatedAt > $1.updatedAt }
    }
    func save(_ conversation: CoachConversation) { rows[conversation.id] = conversation }
    func delete(id: UUID) { rows[id] = nil }
    func preferences() -> CoachPreferences { prefs }
    func savePreferences(_ preferences: CoachPreferences) { prefs = preferences }
}
private actor PolishContext: LooprCoachContextSource {
    var days: Int? = 12
    func setDays(_ value: Int?) { days = value }
    func summary(sharing: CoachSharing, at date: Date) -> String {
        "metrics=\(sharing.metrics),journal=\(sharing.journal),cycle=\(sharing.cycle)"
    }
    func summaryResult(sharing: CoachSharing, at date: Date) -> LooprCoachSummary {
        LooprCoachSummary(text: summary(sharing: sharing, at: date), daysWithData: sharing.metrics ? days : nil)
    }
    func saveAdvice(message: CoachChatMessage, at date: Date) -> UUID { message.id }
}
private struct PolishTransport: CoachChatTransport {
    enum Behavior { case reply, dropAfterText, dropBeforeText, offlineBeforeText }
    var behavior = Behavior.reply
    func stream(_ request: CoachChatRequest, key: String) -> AsyncThrowingStream<CoachStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            switch behavior {
            case .reply:
                continuation.yield(.text("Keep today easy.")); continuation.yield(.completed); continuation.finish()
            case .dropAfterText:
                continuation.yield(.text("Keep today"))
                continuation.finish(throwing: URLError(.networkConnectionLost))
            case .dropBeforeText:
                continuation.finish(throwing: URLError(.networkConnectionLost))
            case .offlineBeforeText:
                continuation.finish(throwing: URLError(.notConnectedToInternet))
            }
        }
    }
    func models(provider: CoachProvider, key: String) async throws -> [String] { [provider.defaultModel] }
}

@Suite(.serialized)
@MainActor
struct CoachPolishTests {
    private func fixture(_ behavior: PolishTransport.Behavior = .reply, configured: Bool = true, origin: AskOrigin? = nil) async throws -> (CoachChatViewModel, PolishRepository, PolishContext) {
        let suite = "LooprCoachPolish.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let runtime = LooprAISettingsRuntime(defaults: defaults, stores: [.openAI: PolishCredentials(), .anthropic: PolishCredentials()], transport: PolishTransport(behavior: behavior))
        if configured { try await runtime.configure(provider: .openAI, model: "gpt-6-luna", apiKey: "fixture-openai") }
        let repository = PolishRepository(); let context = PolishContext()
        let model = CoachChatViewModel(repository: repository, context: context, runtime: runtime, origin: origin)
        return (model, repository, context)
    }
    private func drain(_ model: CoachChatViewModel) async throws {
        for _ in 0..<400 {
            if !model.sending { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Coach request did not finish")
    }
    private func consented(_ model: CoachChatViewModel, text: String = "Training advice") async throws {
        model.draft = text; await model.send(); await model.confirmConsent(); try await drain(model)
    }

    // MARK: Phases

    @Test func loadingIsTheFirstPhaseAndNeverNeedsProviderWhileSlow() async throws {
        let (model, repository, _) = try await fixture()
        await repository.slow(.milliseconds(200))
        #expect(model.phase == .loading)
        let load = Task { await model.load() }
        try await Task.sleep(for: .milliseconds(60))
        #expect(model.phase == .loading)
        await load.value
        #expect(model.phase == .ready)
    }
    @Test func withoutAKeyThePhaseNeedsAProvider() async throws {
        let (model, _, _) = try await fixture(configured: false)
        await model.load()
        #expect(model.phase == .needsProvider)
        #expect(model.conversation == nil)
    }
    @Test func removingTheKeyKeepsTheChatAndAsksToReconnect() async throws {
        let (model, _, _) = try await fixture()
        await model.load()
        #expect(model.reconnectProblem == nil)
        try await model.runtime.remove(.openAI)
        await model.load()
        #expect(model.phase == .ready)
        #expect(model.conversation != nil)
        #expect(model.reconnectProblem?.kind == .reconnect)
        #expect(model.displayProblem?.actions == [.openProviders("Open AI providers")])
    }

    // MARK: Consent

    @Test func cancellingAReviewRestoresTheToggles() async throws {
        let (model, _, _) = try await fixture()
        await model.load()
        try await consented(model)
        let chatID = try #require(model.conversation?.id)
        let approved = try #require(model.conversation?.sharing)
        await model.prepareConsent()
        model.sharing.journal = true
        await model.refreshPreview()
        #expect(model.sharing.journal)
        model.cancelConsent()
        #expect(!model.showingConsent)
        #expect(model.sharing == approved)
        await model.prepareConsent()
        #expect(model.sharing == approved)
        await model.confirmConsent()
        #expect(!model.showingConsent)
        #expect(model.conversation?.id == chatID)
        #expect(model.conversation?.sharing == approved)
    }
    @Test func swipingTheSheetAwayAlsoRestoresTheToggles() async throws {
        let (model, _, _) = try await fixture()
        await model.load()
        try await consented(model)
        await model.prepareConsent()
        model.sharing.cycle = true
        model.showingConsent = false
        model.consentDismissed()
        #expect(!model.sharing.cycle)
    }
    @Test func cancellingTheFirstReviewForgetsTheQueuedSend() async throws {
        let (model, repository, _) = try await fixture()
        await model.load()
        model.draft = "Help"; await model.send()
        #expect(model.showingConsent)
        model.cancelConsent()
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.conversation?.messages.isEmpty == true)
        #expect(model.conversation?.consentedAt == nil)
        #expect(await repository.rows.values.allSatisfy { $0.messages.isEmpty })
    }
    @Test func changingSharingTellsThePersonAboutTheNewChat() async throws {
        let (model, _, _) = try await fixture()
        await model.load()
        try await consented(model)
        var events: [CoachEvent.Kind] = []
        let token = model.events.sink { events.append($0.kind) }
        await model.prepareConsent(); model.sharing.journal = true; await model.refreshPreview(); await model.confirmConsent()
        token.cancel()
        #expect(events.contains(.startedFreshChat))
        #expect(model.notice == "Started a new chat because the shared data changed.")
    }
    @Test func consentSheetFailuresStayOutOfTheChat() async throws {
        let (model, _, _) = try await fixture()
        await model.load()
        model.draft = "Help"; await model.send()
        try await model.runtime.remove(.openAI)
        await model.confirmConsent()
        #expect(model.consentError != nil)
        #expect(model.problem == nil)
    }
    @Test func emptyHealthDataIsReportedToTheConsentSheet() async throws {
        let (model, _, context) = try await fixture()
        await context.setDays(0)
        await model.load()
        model.draft = "Help"; await model.send()
        #expect(model.previewDaysWithData == 0)
        await context.setDays(nil)
        await model.refreshPreview()
        #expect(model.previewDaysWithData == nil)
    }
    @Test func configurationChangeExplainsWhyConsentOpened() async throws {
        let (model, _, _) = try await fixture()
        await model.load()
        try await consented(model)
        try await model.runtime.configure(provider: .openAI, model: "gpt-6-luna", apiKey: "replacement")
        model.draft = "Again"; await model.send()
        #expect(model.showingConsent)
        #expect(model.consentReason != nil)
    }

    // MARK: One-shot open, consent capture, damaged chats

    @Test func aRequestedChatOpensOnceAndNeverComesBack() async throws {
        let (model, repository, _) = try await fixture()
        await model.load()
        let configuration = try #require(model.configuration)
        var briefing = CoachConversation(configuration: configuration)
        briefing.isBriefing = true; briefing.title = "Morning briefing"
        briefing.messages = [.init(role: .assistant, text: "Plan", status: .complete)]
        await repository.save(briefing)
        model.requestOpen(briefing.id)
        for _ in 0..<100 where model.conversation?.id != briefing.id { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.conversation?.id == briefing.id)
        // The person moves on to another chat. Loading again, as the screen does when it comes
        // back, must not pull the briefing back up.
        await model.newChat()
        let other = try #require(model.conversation?.id)
        await model.load()
        await model.load()
        #expect(model.conversation?.id == other)
    }
    @Test func aRequestedChatSavesTheDraftOfTheChatItReplaces() async throws {
        let (model, repository, _) = try await fixture()
        await model.load()
        let configuration = try #require(model.configuration)
        var target = CoachConversation(configuration: configuration)
        target.messages = [.init(role: .user, text: "Earlier")]; target.draft = "Target draft"
        await repository.save(target)
        model.draft = "Unsent words"
        let current = try #require(model.conversation?.id)
        model.requestOpen(target.id)
        for _ in 0..<100 where model.conversation?.id != target.id { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.conversation?.id == target.id)
        #expect(model.draft == "Target draft")
        #expect(model.sending == false)
        #expect(await repository.rows[current]?.draft == "Unsent words")
    }
    @Test func approvedCategoriesAreFixedWhenAllowIsTapped() async throws {
        let (model, _, _) = try await fixture()
        await model.load()
        model.draft = "Help"; await model.send()
        let approved = model.sharing
        let approvedPreview = model.preview
        let confirm = Task { await model.confirmConsent() }
        await Task.yield()
        // A late toggle or dismissal while Allow is saving must not change what gets stored.
        model.sharing.journal = true
        model.cancelConsent()
        #expect(model.showingConsent, "Cancel is ignored while Allow is saving")
        await confirm.value
        #expect(model.conversation?.sharing == approved)
        #expect(model.conversation?.context == approvedPreview)
        #expect(model.conversation?.consentedAt != nil)
        #expect(!model.confirming)
        try await drain(model)
    }
    @Test func theNewChatNoticeSurvivesTheReplyThatFollows() async throws {
        let (model, _, _) = try await fixture()
        await model.load()
        try await consented(model)
        model.draft = "Next"
        await model.prepareConsent(sendAfter: true)
        model.sharing.journal = true; await model.refreshPreview(); await model.confirmConsent()
        try await drain(model)
        #expect(model.notice == "Started a new chat because the shared data changed.")
    }
    @Test func aKeychainOrStorageFailureIsNotBlamedOnTheProvider() {
        struct Plain: Error {}
        let card = CoachProblem.make(Plain(), provider: .openAI, hadPartialReply: false)
        #expect(card?.title == "Something went wrong")
        #expect(card?.kind == .other)
        #expect(CoachProblem.make(CoachSettingsError.keychainRead, provider: .openAI, hadPartialReply: false)?.message
                == CoachSettingsError.keychainRead.errorDescription)
        #expect(CoachProblem.make(CancellationError(), provider: .openAI, hadPartialReply: false) == nil)
        #expect(CoachProblem.make(URLError(.notConnectedToInternet), provider: .openAI, hadPartialReply: false)?.kind == .offline)
    }
    @Test func oneDamagedChatDoesNotHideTheOthers() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("coach-damaged-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let database = try StorageDatabase(url: url, applicationVersion: "test")
        let repository = try SQLiteCoachConversationRepository(database: database)
        var good = CoachConversation(configuration: .init(provider: .openAI, model: "test"))
        good.title = "Kept"
        try await repository.save(good)
        let raw = try StorageDocumentStore(database: database, namespace: "coach")
        try raw.writeData(Data("{\"id\": \"not a chat\"}".utf8), key: "chat.\(UUID().uuidString)")
        let rows = try await repository.conversations()
        #expect(rows.map(\.title) == ["Kept"])
        // Saving over a damaged document still works.
        let damagedID = UUID()
        try raw.writeData(Data("[]".utf8), key: "chat.\(damagedID.uuidString)")
        let replacement = CoachConversation(id: damagedID, configuration: .init(provider: .openAI, model: "test"))
        try await repository.save(replacement)
        #expect(try await repository.conversations().count == 2)
    }
    @Test func summaryOffersShowAllOnlyWhenSomethingIsHidden() {
        #expect(!CoachSummaryText.hidesLines(in: "Header:\none\ntwo"))
        #expect(CoachSummaryText.hidesLines(in: "A:\n1\n2\n3\n4"))
        #expect(CoachSummaryText.hidesLines(in: "A:\n1\nB:\n1\nC:\n1\nD:\n1"))
    }

    // MARK: Errors

    @Test func aDropAfterTextIsAnInterruptionThatKeepsTheText() async throws {
        let (model, repository, _) = try await fixture(.dropAfterText)
        await model.load()
        try await consented(model)
        #expect(model.problem?.kind == .interrupted)
        #expect(model.problem?.hasRetry == true)
        let last = try #require(model.conversation?.messages.last)
        #expect(last.text == "Keep today")
        #expect(last.status == .interrupted)
        #expect(last.stopReason == .connectionLost)
        #expect(await repository.rows.values.first?.messages.last?.stopReason == .connectionLost)
    }
    @Test func goingOfflineMidReplyIsAlsoAnInterruption() {
        // The system can report the same drop as "not connected" once the radio is gone.
        #expect(CoachProblem.make(.offline, provider: .openAI, hadPartialReply: true)?.kind == .interrupted)
        #expect(CoachProblem.make(.offline, provider: .openAI, hadPartialReply: false)?.kind == .offline)
    }
    @Test func offlineBeforeAnyTextIsOffline() async throws {
        let (model, _, _) = try await fixture(.offlineBeforeText)
        await model.load()
        try await consented(model)
        #expect(model.problem?.kind == .offline)
        #expect(model.conversation?.messages.last?.status == .failed)
    }
    @Test func retryClearsTheProblemAndStartsAFreshReply() async throws {
        let (model, _, _) = try await fixture(.dropBeforeText)
        await model.load()
        try await consented(model)
        #expect(model.problem?.kind == .interrupted)
        #expect(model.problem?.message.contains("before a reply arrived") == true)
        await model.retry(); try await drain(model)
        #expect(model.conversation?.messages.filter { $0.role == .user }.count == 1)
    }
    @Test func unfinishedReplyBlocksANewQuestionWithRetryAndNewChat() async throws {
        let (model, _, _) = try await fixture(.dropAfterText)
        await model.load()
        try await consented(model)
        model.dismissProblem()
        model.draft = "Another question"; await model.send()
        #expect(model.problem?.kind == .unfinishedReply)
        #expect(model.problem?.actions == [.retry, .newChat])
        #expect(model.draft == "Another question")
    }
    @Test func providerErrorsOfferTheRightAction() throws {
        func actions(_ error: CoachProviderError) -> [CoachProblem.Action]? {
            CoachProblem.make(error, provider: .anthropic, hadPartialReply: false)?.actions
        }
        #expect(actions(.invalidKey) == [.openProviders("Review key")])
        #expect(actions(.missingKey) == [.openProviders("Add API key")])
        #expect(actions(.quota) == [.billing(CoachProvider.anthropic.billingURL), .openProviders("Open AI providers")])
        #expect(actions(.rateLimited) == [.retry])
        #expect(actions(.server) == [.retry])
        #expect(actions(.conversationFull) == [.newChat])
        #expect(actions(.cancelled) == nil)
    }
    @Test func tooLongDraftIsRejectedAndClearsWhenEdited() async throws {
        let (model, repository, _) = try await fixture()
        await model.load()
        model.draft = String(repeating: "x", count: CoachChatViewModel.draftLimit + 1)
        #expect(model.draftIsTooLong)
        await model.send()
        #expect(model.problem?.kind == .tooLong)
        #expect(await repository.rows.isEmpty)
        model.draft = "short"; model.draftChanged()
        #expect(model.problem == nil)
    }

    // MARK: Events

    @Test func eachReplyPublishesOneStartAndOneFinish() async throws {
        let (model, _, _) = try await fixture()
        await model.load()
        var events: [CoachEvent.Kind] = []
        let token = model.events.sink { events.append($0.kind) }
        try await consented(model)
        model.draft = "Why?"; await model.send(); try await drain(model)
        token.cancel()
        #expect(events.filter { $0 == .replyStarted }.count == 2)
        #expect(events.filter { $0 == .replyFinished }.count == 2)
        #expect(events.filter { $0 == .consentAllowed }.count == 1)
    }
    @Test func savingAdviceAndDeletingPublishEvents() async throws {
        let (model, _, _) = try await fixture()
        await model.load()
        try await consented(model)
        var events: [CoachEvent.Kind] = []
        let token = model.events.sink { events.append($0.kind) }
        let message = try #require(model.conversation?.messages.last)
        await model.saveAdvice(message)
        await model.delete(try #require(model.conversation))
        token.cancel()
        #expect(events == [.journalSaved, .chatDeleted])
    }

    // MARK: Opening a chat from a notification

    @Test func requestOpenSelectsThatChatOnTheNextLoad() async throws {
        let (model, repository, _) = try await fixture()
        await model.load()
        var briefing = CoachConversation(configuration: try #require(try await model.runtime.selectedConfiguration()), now: Date().addingTimeInterval(-3600))
        briefing.isBriefing = true; briefing.title = "Morning briefing"
        await repository.save(briefing)
        model.requestOpen(briefing.id)
        await model.load()
        #expect(model.conversation?.id == briefing.id)
    }

    // MARK: Ask origin prompt

    private func sleepOrigin(prompt: String? = "What was different about this night?") -> AskOrigin {
        AskOrigin(screen: "Sleep", day: "2026-10-12", date: Date(timeIntervalSince1970: 1_760_000_000),
                  prompt: prompt, dayLabel: "Mon night")
    }

    @Test func anOriginPromptFillsTheFieldAndSendsNothing() async throws {
        let (model, repository, _) = try await fixture(origin: sleepOrigin())
        await model.load()
        #expect(model.phase == .ready)
        #expect(model.draft == "What was different about this night?")
        #expect(model.conversation?.messages.isEmpty == true)
        #expect(!model.sending)
        #expect(!model.showingConsent)
        #expect(await repository.rows.isEmpty)
    }
    @Test func theUntouchedPromptIsNeverSavedAsADraft() async throws {
        let (model, repository, _) = try await fixture(origin: sleepOrigin())
        await model.load()
        await model.saveDraftNow()
        await model.leave()
        #expect(await repository.rows.isEmpty)
    }
    @Test func aPromptThePersonEditsIsSavedLikeAnyDraft() async throws {
        let (model, repository, _) = try await fixture(origin: sleepOrigin())
        await model.load()
        model.draft += " Be brief."
        await model.saveDraftNow()
        let saved = await repository.rows.values.first
        #expect(saved?.draft == "What was different about this night? Be brief.")
    }
    @Test func theOriginPromptDoesNotComeBackAfterNewChat() async throws {
        let (model, _, _) = try await fixture(origin: sleepOrigin())
        await model.load()
        await model.newChat()
        #expect(model.draft.isEmpty)
    }
    @Test func aPromptNeverReplacesTextAlreadyInTheField() async throws {
        let (model, _, _) = try await fixture(origin: sleepOrigin())
        model.draft = "Already typing"
        await model.load()
        #expect(model.draft == "Already typing")
    }
    @Test func withoutAPromptTheFieldStaysEmpty() async throws {
        let (model, _, _) = try await fixture(origin: sleepOrigin(prompt: nil))
        await model.load()
        #expect(model.draft.isEmpty)
    }
    @Test func anOriginPromptWaitsForAKeyThenFillsTheField() async throws {
        let (model, _, _) = try await fixture(configured: false, origin: sleepOrigin())
        await model.load()
        #expect(model.phase == .needsProvider)
        #expect(model.draft.isEmpty)
        try await model.runtime.configure(provider: .openAI, model: "gpt-6-luna", apiKey: "fixture-openai")
        await model.load()
        #expect(model.draft == "What was different about this night?")
    }
    @Test func theConsentPreviewNamesTheOriginButNotThePrompt() async throws {
        let (model, _, _) = try await fixture(origin: sleepOrigin())
        await model.load()
        await model.send()
        #expect(model.showingConsent)
        #expect(model.preview.hasPrefix("Opened from Sleep, selected day 2026-10-12."))
        #expect(!model.preview.contains("What was different"))
    }
}

struct CoachErrorMappingTests {
    @Test func aConnectionThatDropsIsNotOffline() {
        #expect(CoachProviderError.normalize(URLError(.networkConnectionLost)) == .connectionLost)
        #expect(CoachProviderError.normalize(URLError(.notConnectedToInternet)) == .offline)
        #expect(CoachProviderError.normalize(URLError(.dataNotAllowed)) == .offline)
        #expect(CoachProviderError.normalize(URLError(.timedOut)) == .timeout)
        #expect(CoachProviderError.normalize(URLError(.cancelled)) == .cancelled)
    }
    @Test func tlsFailuresAreTheirOwnCase() {
        for code in [URLError.Code.secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .clientCertificateRejected] {
            #expect(CoachProviderError.normalize(URLError(code)) == .secureConnection)
        }
    }
    @Test func newCasesHaveReadableCopy() {
        for error in [CoachProviderError.connectionLost, .secureConnection, .missingKey] {
            let text = error.localizedDescription
            #expect(!text.isEmpty && !text.contains("coach settings") && !text.contains("—"))
        }
    }
    @Test func billingLinksAreHTTPS() {
        for provider in CoachProvider.allCases { #expect(provider.billingURL.scheme == "https" && provider.billingURL.host != nil) }
    }
    @Test func stopReasonSurvivesCodingAndOldChatsStillDecode() throws {
        var message = CoachChatMessage(role: .assistant, text: "Partial", status: .interrupted)
        message.stopReason = .connectionLost
        let data = try JSONEncoder().encode(message)
        #expect(try JSONDecoder().decode(CoachChatMessage.self, from: data).stopReason == .connectionLost)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["stopReason"] = nil
        let old = try JSONSerialization.data(withJSONObject: object)
        #expect(try JSONDecoder().decode(CoachChatMessage.self, from: old).stopReason == nil)
    }
}

struct CoachMarkdownParserTests {
    private func kinds(_ text: String, streaming: Bool = false) -> [CoachMarkdownBlock.Kind] {
        CoachMarkdownParser.parse(text, streaming: streaming).map(\.kind)
    }
    @Test func headingsParagraphsAndRules() {
        #expect(kinds("# Plan\nBody line\nsecond line\n\n---\n\n### Small") == [.heading(1), .paragraph, .rule, .heading(3)])
        #expect(CoachMarkdownParser.parse("Body line\nsecond line").first?.text == "Body line\nsecond line")
    }
    @Test func orderedAndNestedLists() {
        let blocks = CoachMarkdownParser.parse("1. Warm up\n2. Main set\n- Sleep\n  - Deep\n    - Very deep\n- HRV")
        #expect(blocks.map(\.kind) == [.ordered(number: 1, depth: 0), .ordered(number: 2, depth: 0),
                                       .bullet(depth: 0), .bullet(depth: 1), .bullet(depth: 2), .bullet(depth: 0)])
        #expect(blocks[1].text == "Main set")
    }
    @Test func wrappedListLinesJoinTheirItem() {
        let blocks = CoachMarkdownParser.parse("- First item\n  continues here\n- Second")
        #expect(blocks.count == 2)
        #expect(blocks[0].text == "First item continues here")
    }
    @Test func quotesTablesAndCode() {
        #expect(kinds("> one\n> two\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n```swift\nlet x = 1\n```") ==
                [.quote, .table, .code(language: "swift")])
        let blocks = CoachMarkdownParser.parse("> one\n> two\n\n| a | b |\n|---|---|\n| 1 | 2 |")
        #expect(blocks[0].text == "one\ntwo")
        #expect(blocks[1].text == "| a | b |\n| 1 | 2 |")
    }
    @Test func unterminatedCodeFenceStillRendersWhileStreaming() {
        let blocks = CoachMarkdownParser.parse("Here:\n```\nlet x = 1\nlet y", streaming: true)
        #expect(blocks.map(\.kind) == [.paragraph, .code(language: nil)])
        #expect(blocks[1].text == "let x = 1\nlet y")
    }
    @Test func danglingMarkersAreClosedOnlyWhileStreaming() {
        #expect(CoachMarkdownParser.parse("Start with **an easy", streaming: true).first?.text == "Start with **an easy**")
        #expect(CoachMarkdownParser.parse("Start with **an easy", streaming: false).first?.text == "Start with **an easy")
        #expect(CoachMarkdownParser.parse("Use `code", streaming: true).first?.text == "Use `code`")
        #expect(CoachMarkdownParser.parse("Fine **bold** text", streaming: true).first?.text == "Fine **bold** text")
        #expect(CoachMarkdownParser.parse("Some *emph", streaming: true).first?.text == "Some *emph*")
    }
    @Test func linksLoseTheirTargetInPlainText() {
        let blocks = CoachMarkdownParser.parse("See [the guide](https://example.invalid/x) for **more**.")
        #expect(CoachMarkdownParser.plainText(blocks) == "See the guide for more.")
    }
    @Test func plainTextNumbersListsAndSkipsRules() {
        let blocks = CoachMarkdownParser.parse("# Plan\n1. One\n2. Two\n---\n- Done")
        #expect(CoachMarkdownParser.plainText(blocks) == "Plan\n1. One\n2. Two\nDone")
    }
}
