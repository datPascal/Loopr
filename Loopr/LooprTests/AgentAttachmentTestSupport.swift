import AIKit
import Foundation
import Testing
@testable import Loopr

/// A chat on a scripted agent transport, for the FT-05.3 suites. Alex, Australia/Perth, no network.
actor AttachmentRepository: CoachConversationRepository {
    private(set) var rows: [UUID: CoachConversation] = [:]
    var prefs = CoachPreferences()
    func conversations() -> [CoachConversation] { rows.values.sorted { $0.updatedAt > $1.updatedAt } }
    func save(_ conversation: CoachConversation) { rows[conversation.id] = conversation }
    func delete(id: UUID) { rows[id] = nil }
    func preferences() -> CoachPreferences { prefs }
    func savePreferences(_ preferences: CoachPreferences) { prefs = preferences }
}

struct AttachmentContext: LooprCoachContextSource {
    func summary(sharing: CoachSharing, at date: Date) async throws -> String { "Health summary for Alex." }
    func saveAdvice(message: CoachChatMessage, at date: Date) async throws -> UUID { message.id }
}

@MainActor
struct AttachmentRig {
    let model: CoachChatViewModel
    let transport: ScriptedAgentTransport
    let suite: AgentFixtures.Suite
    let harness: ProposalHarness
    let repository: AttachmentRepository
    let runtime: LooprAISettingsRuntime
    let source: FakeAgentSource

    static func make(_ script: [AgentTurn], source: FakeAgentSource = FakeAgentSource()) async throws -> AttachmentRig {
        let suite = AgentFixtures.Suite(); suite.setOnly(Set(AgentDataDomain.allCases))
        let transport = ScriptedAgentTransport(script)
        let runtime = LooprAISettingsRuntime(defaults: suite.defaults, credentials: AgentTestCredentials(), transport: NoStreamTransport(), agentTransport: transport)
        try await runtime.configure(provider: .anthropic, model: "claude-haiku-5-5", apiKey: "test-key")
        let harness = try ProposalHarness.make()
        let repository = AttachmentRepository()
        let mode = LooprAgentToolMode(runtime: runtime, source: source, writes: harness.writes, proposals: harness.center, defaults: suite.defaults,
                                      now: { AgentFixtures.now }, timeZone: { AgentFixtures.zone })
        let model = CoachChatViewModel(repository: repository, context: AttachmentContext(), runtime: runtime, agent: mode)
        await model.load()
        await model.prepareConsent()
        await model.refreshPreview(); await model.confirmConsent()
        return AttachmentRig(model: model, transport: transport, suite: suite, harness: harness, repository: repository, runtime: runtime, source: source)
    }

    func ask(_ text: String) async {
        model.draft = text
        await model.send()
        for _ in 0..<500 where model.sending { try? await Task.sleep(for: .milliseconds(10)) }
    }

    /// A new view model on the same chat file and proposal file, as after a relaunch.
    func relaunched() async throws -> CoachChatViewModel {
        let again = try harness.restarted()
        let mode = LooprAgentToolMode(runtime: runtime, source: source, writes: harness.writes, proposals: again.center, defaults: suite.defaults,
                                      now: { AgentFixtures.now }, timeZone: { AgentFixtures.zone })
        let next = CoachChatViewModel(repository: repository, context: AttachmentContext(), runtime: runtime, agent: mode)
        await next.load()
        return next
    }

    var reply: CoachChatMessage? { model.conversation?.messages.last }
    func cleanup() { harness.cleanup() }
}

extension CoachChatMessage {
    var chartSnapshots: [AgentChartSnapshot] { attachments.compactMap { if case .chart(let chart) = $0 { chart } else { nil } } }
    var attachedSources: [AgentSource] { attachments.flatMap { attachment -> [AgentSource] in if case .sources(let list) = attachment { list } else { [] } } }
    var proposalIDs: [UUID] { attachments.compactMap { if case .proposal(let id) = $0 { id } else { nil } } }
}
