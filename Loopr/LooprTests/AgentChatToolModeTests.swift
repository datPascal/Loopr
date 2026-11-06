import AIKit
import DesignSystem
import Foundation
import Testing
@testable import Loopr

private actor ToolModeRepository: CoachConversationRepository {
    var rows: [UUID: CoachConversation] = [:]
    var prefs = CoachPreferences()
    func conversations() -> [CoachConversation] { rows.values.sorted { $0.updatedAt > $1.updatedAt } }
    func save(_ conversation: CoachConversation) { rows[conversation.id] = conversation }
    func delete(id: UUID) { rows[id] = nil }
    func preferences() -> CoachPreferences { prefs }
    func savePreferences(_ preferences: CoachPreferences) { prefs = preferences }
}

private actor ToolModeContext: LooprCoachContextSource {
    private(set) var sharings: [CoachSharing] = []
    func summary(sharing: CoachSharing, at date: Date) -> String { summaryResult(sharing: sharing, at: date).text }
    func summaryResult(sharing: CoachSharing, at date: Date) -> LooprCoachSummary {
        sharings.append(sharing)
        return LooprCoachSummary(text: "Summary. notes=\(sharing.journalNotes) cycle=\(sharing.cycle) food=\(sharing.food)", daysWithData: 5)
    }
    func saveAdvice(message: CoachChatMessage, at date: Date) -> UUID { message.id }
}

@MainActor
@Suite(.serialized)
struct AgentChatToolModeTests {
    private struct Rig {
        let model: CoachChatViewModel
        let transport: ScriptedAgentTransport
        let suite: AgentFixtures.Suite
        let harness: ProposalHarness
        let repository: ToolModeRepository
        let context: ToolModeContext
        let runtime: LooprAISettingsRuntime
        let mode: LooprAgentToolMode
    }

    private func makeRig(_ script: [AgentTurn], onTurn: (@Sendable (Int, CoachAgentRequest) -> Void)? = nil, suite: AgentFixtures.Suite? = nil) async throws -> Rig {
        let suite = suite ?? { let s = AgentFixtures.Suite(); s.setOnly(Set(AgentDataDomain.allCases)); return s }()
        let transport = ScriptedAgentTransport(script, onTurn: onTurn)
        let runtime = LooprAISettingsRuntime(defaults: suite.defaults, credentials: AgentTestCredentials(), transport: NoStreamTransport(), agentTransport: transport)
        try await runtime.configure(provider: .anthropic, model: "claude-haiku-5-5", apiKey: "test-key")
        let writes = SpyWriteStore()
        let harness = try ProposalHarness.make(writes: writes)
        let repository = ToolModeRepository(), context = ToolModeContext()
        let mode = LooprAgentToolMode(runtime: runtime, source: FakeAgentSource(), writes: writes, proposals: harness.center, defaults: suite.defaults,
                                      now: { AgentFixtures.now }, timeZone: { AgentFixtures.zone })
        let model = CoachChatViewModel(repository: repository, context: context, runtime: runtime, agent: mode)
        await model.load()
        return Rig(model: model, transport: transport, suite: suite, harness: harness, repository: repository, context: context, runtime: runtime, mode: mode)
    }

    private func consent(_ rig: Rig, journal: Bool = false, cycle: Bool = false) async {
        await rig.model.prepareConsent()
        rig.model.sharing.journal = journal; rig.model.sharing.cycle = cycle
        await rig.model.refreshPreview(); await rig.model.confirmConsent()
    }
    private func ask(_ rig: Rig, _ text: String) async {
        rig.model.draft = text
        await rig.model.send()
        for _ in 0..<500 where rig.model.sending { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func toolModeAnswersWholeAndKeepsTheReply() async throws {
        let rig = try await makeRig([.final("A late dinner and a short night go together this week.")]); defer { rig.harness.cleanup() }
        await consent(rig)
        await ask(rig, "Why did I sleep badly?")

        let chat = try #require(rig.model.conversation)
        #expect(chat.messages.map(\.role) == [.user, .assistant])
        #expect(chat.messages.last?.text == "A late dinner and a short night go together this week.")
        #expect(chat.messages.last?.status == .complete)
        #expect(rig.model.problem == nil && !rig.model.sending)
        let request = try #require(rig.transport.requests.first)
        #expect(request.messages.map(\.text) == ["Why did I sleep badly?"], "the empty reply is not sent")
        #expect(request.tools.contains { $0.name == AgentToolName.getFood })
        #expect(request.context.contains("Today is "), "the model is told today's date")
        #expect(request.context.contains("Summary."), "the approved summary still travels")
        #expect(rig.model.history.first?.messages.count == 2, "the reply is saved with the chat")
    }

    @Test func aFailedToolTurnKeepsTheQuestionAndShowsTheProblem() async throws {
        let rig = try await makeRig([]); defer { rig.harness.cleanup() }   // the transport has nothing to answer with
        await consent(rig)
        await ask(rig, "Why did I sleep badly?")
        let chat = try #require(rig.model.conversation)
        #expect(chat.messages.first?.text == "Why did I sleep badly?")
        #expect(chat.messages.last?.status == .failed)
        #expect(rig.model.problem != nil)
    }

    @Test func proposalCardsSitUnderTheReplyAndConfirmThroughTheChat() async throws {
        let call = AgentFixtures.call(AgentToolName.proposeMeal, ["slot": "dinner", "day": "2026-10-15", "time": "21:30", "estimate": AgentFixtures.estimate()], id: "p1")
        let rig = try await makeRig([.toolCalls([call]), .final("I prepared that dinner. Confirm it to log it.")]); defer { rig.harness.cleanup() }
        await consent(rig)
        await ask(rig, "Log my dinner: salmon and potatoes")

        let reply = try #require(rig.model.conversation?.messages.last)
        let cards = try #require(rig.model.agentProposals[reply.id])
        #expect(cards.count == 1 && cards[0].state == .pending && cards[0].card?.title == "Log this meal?")
        #expect(rig.harness.writes.writeCount == 0, "nothing is logged until Confirm")
        #expect(reply.attachments == [.proposal(cards[0].id)])

        await rig.model.confirmProposal(cards[0].id)
        #expect(rig.harness.writes.meals.count == 1)
        #expect(rig.model.agentProposals[reply.id]?.first?.state == .applied)
        #expect(rig.model.info?.message == "Meal logged.")
        await rig.model.confirmProposal(cards[0].id)
        #expect(rig.harness.writes.meals.count == 1, "a second tap saves nothing more")
    }

    @Test func notNowKeepsTheChatAndSavesNothing() async throws {
        let call = AgentFixtures.call(AgentToolName.proposeJournalQuestion, ["name": "Screens", "question": "Did you use screens late?"], id: "p1")
        let rig = try await makeRig([.toolCalls([call]), .final("Prepared.")]); defer { rig.harness.cleanup() }
        await consent(rig)
        await ask(rig, "Add a question about screens")
        let reply = try #require(rig.model.conversation?.messages.last)
        let id = try #require(rig.model.agentProposals[reply.id]?.first?.id)
        await rig.model.dismissProposal(id)
        #expect(rig.model.agentProposals[reply.id]?.first?.state == .dismissed)
        #expect(rig.model.info?.message == "Nothing was saved.")
        #expect(rig.harness.writes.writeCount == 0)
    }

    @Test func cardsComeBackAfterARelaunch() async throws {
        let call = AgentFixtures.call(AgentToolName.proposeReminder, ["title": "Wind down", "time": "20:15"], id: "p1")
        let rig = try await makeRig([.toolCalls([call]), .final("Prepared.")]); defer { rig.harness.cleanup() }
        await consent(rig)
        await ask(rig, "Remind me to wind down")
        let replyID = try #require(rig.model.conversation?.messages.last?.id)

        // A new model on the same stores, as after a restart.
        let restarted = try rig.harness.restarted()
        let mode = LooprAgentToolMode(runtime: rig.runtime, source: FakeAgentSource(), writes: rig.harness.writes, proposals: restarted.center, defaults: rig.suite.defaults,
                                      now: { AgentFixtures.now }, timeZone: { AgentFixtures.zone })
        let again = CoachChatViewModel(repository: rig.repository, context: rig.context, runtime: rig.runtime, agent: mode)
        await again.load()
        #expect(again.conversation?.id == rig.model.conversation?.id)
        let card = try #require(again.agentProposals[replyID]?.first)
        #expect(card.state == .pending && card.card?.title == "Remind you at \(LooprClockFormat.text(minuteOfDay: 20 * 60 + 15))?")
        await again.confirmProposal(card.id)
        #expect(rig.harness.reminders.scheduled.count == 1)
    }

    @Test func deletingTheChatDeletesItsCards() async throws {
        let call = AgentFixtures.call(AgentToolName.proposeJournalQuestion, ["name": "Screens", "question": "Did you use screens late?"], id: "p1")
        let rig = try await makeRig([.toolCalls([call]), .final("Prepared.")]); defer { rig.harness.cleanup() }
        await consent(rig)
        await ask(rig, "Add a question about screens")
        let chat = try #require(rig.model.conversation)
        #expect(await rig.harness.center.proposals(conversationID: chat.id).count == 1)
        await rig.model.delete(chat)
        #expect(await rig.harness.center.proposals(conversationID: chat.id).isEmpty)
    }

    // MARK: A switch flipped in the middle of a chat

    @Test func aSwitchTurnedOffMidChatStartsACleanChatWithoutTheOldReplies() async throws {
        let rig = try await makeRig([.final("First answer, with a note quoted."), .final("Second answer.")]); defer { rig.harness.cleanup() }
        rig.suite.set(.journalNotes, true)
        await consent(rig, journal: true)
        await ask(rig, "How was my week?")
        let firstChat = try #require(rig.model.conversation)
        #expect(firstChat.sharing.journalNotes && firstChat.messages.count == 2)

        rig.suite.set(.journalNotes, false)          // the person turns notes off in Your data
        await ask(rig, "And today?")

        let secondChat = try #require(rig.model.conversation)
        #expect(secondChat.id != firstChat.id, "a new chat, so the first reply can not carry notes forward")
        #expect(!secondChat.sharing.journalNotes && secondChat.sharing.journalAnswers)
        #expect(secondChat.context.contains("notes=false"), "the summary was rebuilt without notes")
        #expect(await rig.context.sharings.last?.journalNotes == false)
        let sent = try #require(rig.transport.requests.last)
        #expect(sent.messages.map(\.text) == ["And today?"], "earlier messages are not sent")
        #expect(!sent.context.contains("notes=true"))
        #expect(rig.model.info?.message == "Started a new chat because Your data changed.")
        // The first chat is untouched in history.
        let saved = try await rig.repository.conversations().first { $0.id == firstChat.id }
        #expect(saved?.sharing.journalNotes == true && saved?.messages.count == 2)
    }

    @Test func nothingChangesWhileTheSwitchesStayAsApproved() async throws {
        let rig = try await makeRig([.final("One."), .final("Two.")]); defer { rig.harness.cleanup() }
        await consent(rig)
        await ask(rig, "First")
        let id = rig.model.conversation?.id
        await ask(rig, "Second")
        #expect(rig.model.conversation?.id == id)
        #expect(rig.transport.requests.last?.messages.map(\.text) == ["First", "One.", "Second"])
        #expect(rig.model.info == nil)
    }

    @Test func aSwitchTurnedOffBeforeRetryAlsoStartsCleanWithTheQuestion() async throws {
        let rig = try await makeRig([.final("Answer."), .final("Answer again.")]); defer { rig.harness.cleanup() }
        rig.suite.set(.cycle, true)
        await consent(rig, cycle: true)
        await ask(rig, "How is my cycle affecting sleep?")
        let id = rig.model.conversation?.id
        // Drop the reply so the question is the last message, then turn the switch off and retry.
        var chat = try #require(rig.model.conversation)
        chat.messages.removeLast(); chat.messages.append(.init(role: .assistant, text: "partial", status: .failed))
        await rig.model.open(chat)
        rig.suite.set(.cycle, false)
        await rig.model.retry()
        for _ in 0..<500 where rig.model.sending { try? await Task.sleep(for: .milliseconds(10)) }
        let now = try #require(rig.model.conversation)
        #expect(now.id != id && !now.sharing.cycle)
        #expect(rig.transport.requests.last?.messages.map(\.text) == ["How is my cycle affecting sleep?"])
    }

    @Test func withNoToolModeTheChatStaysTheStreamingChat() async throws {
        // The default view model has no agent and no filter, so existing behavior is unchanged.
        let model = CoachChatViewModel(repository: ToolModeRepository(), context: ToolModeContext(), runtime: LooprAISettingsRuntime(defaults: AgentFixtures.Suite().defaults, credentials: AgentTestCredentials(), transport: NoStreamTransport()))
        #expect(model.agent == nil && model.sharingFilter == nil && model.agentProposals.isEmpty)
    }
}
