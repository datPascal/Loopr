import AIKit
import Foundation
import Testing
@testable import Loopr

/// Holds a tool turn open until the test lets it go, so a provider change or a cancel can land in the middle.
private final class GatedAgentTransport: CoachAgentTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var entered = 0
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private let turns: [AgentTurn]
    private var index = 0
    init(_ turns: [AgentTurn]) { self.turns = turns }
    var enteredCount: Int { lock.withLock { entered } }
    func release() {
        let waiting: CheckedContinuation<Void, Never>? = lock.withLock { released = true; defer { continuation = nil }; return continuation }
        waiting?.resume()
    }
    func turn(_ request: CoachAgentRequest, key: String) async throws -> AgentTurn {
        lock.withLock { entered += 1 }
        await withCheckedContinuation { (waiting: CheckedContinuation<Void, Never>) in
            let resumeNow: Bool = lock.withLock {
                if released { return true }
                continuation = waiting; return false
            }
            if resumeNow { waiting.resume() }
        }
        return lock.withLock { defer { index += 1 }; return turns[min(index, turns.count - 1)] }
    }
}

@Suite(.serialized)
struct AgentRuntimeTests {
    private func request(_ configuration: CoachProviderConfiguration) -> CoachAgentRequest {
        CoachAgentRequest(configuration: configuration, instructions: "", context: "", messages: [CoachChatMessage(role: .user, text: "Why did I sleep badly?")],
                          tools: AgentToolRegistry.specs(allowed: [.metrics], capabilities: .init()))
    }
    private func makeRuntime(_ suite: AgentFixtures.Suite, transport: any CoachAgentTransport) async throws -> (LooprAISettingsRuntime, CoachProviderConfiguration) {
        let runtime = LooprAISettingsRuntime(defaults: suite.defaults, credentials: AgentTestCredentials(), transport: NoStreamTransport(), agentTransport: transport)
        try await runtime.configure(provider: .anthropic, model: "claude-haiku-5-5", apiKey: "test-key")
        return (runtime, try #require(try await runtime.selectedConfiguration()))
    }
    private func waitUntilEntered(_ transport: GatedAgentTransport) async {
        for _ in 0..<500 where transport.enteredCount == 0 { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func agentTurnReturnsWhatTheTransportAnswers() async throws {
        let suite = AgentFixtures.Suite()
        let scripted = ScriptedAgentTransport([.final("Fine."), .toolCalls([AgentFixtures.call(AgentToolName.getMetrics, ["metrics": ["rmssd"]], id: "c1")])])
        let (runtime, configuration) = try await makeRuntime(suite, transport: scripted)
        #expect(try await runtime.agentTurn(request(configuration)) == .final("Fine."))
        guard case .toolCalls(let calls) = try await runtime.agentTurn(request(configuration)) else { Issue.record("expected tool calls"); return }
        #expect(calls.map(\.name) == [AgentToolName.getMetrics])
        #expect(scripted.requests.count == 2)
    }

    @Test func aMissingKeyOrProviderFailsBeforeAnythingIsSent() async throws {
        let suite = AgentFixtures.Suite()
        let scripted = ScriptedAgentTransport([.final("Never sent.")])
        let (runtime, configuration) = try await makeRuntime(suite, transport: scripted)
        try await runtime.remove(.anthropic)
        await #expect(throws: CoachProviderError.self) { _ = try await runtime.agentTurn(request(configuration)) }
        #expect(scripted.requests.isEmpty)
    }

    @Test func aTransportWithoutToolSupportIsAnErrorNotACrash() async throws {
        let suite = AgentFixtures.Suite()
        let runtime = LooprAISettingsRuntime(defaults: suite.defaults, credentials: AgentTestCredentials(), transport: NoStreamTransport())
        try await runtime.configure(provider: .anthropic, model: "claude-haiku-5-5", apiKey: "k")
        let configuration = try #require(try await runtime.selectedConfiguration())
        await #expect(throws: CoachProviderError.self) { _ = try await runtime.agentTurn(request(configuration)) }
    }

    @Test func removingTheProviderMidTurnDiscardsTheAnswer() async throws {
        let suite = AgentFixtures.Suite()
        let gated = GatedAgentTransport([.final("Late answer.")])
        let (runtime, configuration) = try await makeRuntime(suite, transport: gated)
        let work = Task { try await runtime.agentTurn(request(configuration)) }
        await waitUntilEntered(gated)
        try await runtime.remove(.anthropic)
        gated.release()
        await #expect(throws: (any Error).self) { _ = try await work.value }
    }

    @Test func changingTheModelMidTurnDiscardsTheAnswer() async throws {
        let suite = AgentFixtures.Suite()
        let gated = GatedAgentTransport([.final("Late answer.")])
        let (runtime, configuration) = try await makeRuntime(suite, transport: gated)
        let work = Task { try await runtime.agentTurn(request(configuration)) }
        await waitUntilEntered(gated)
        try await runtime.configure(provider: .anthropic, model: "claude-sonnet-5-5", apiKey: "")   // a new revision
        gated.release()
        do { _ = try await work.value; Issue.record("a stale answer was returned") }
        catch { #expect(CoachProviderError.normalize(error) == .cancelled || CoachProviderError.normalize(error) == .configurationChanged) }
    }

    @Test func cancellingTheRequestsStopsAToolLoopBeforeItsNextRound() async throws {
        let suite = AgentFixtures.Suite()
        let gated = GatedAgentTransport([.toolCalls([AgentFixtures.call(AgentToolName.getMetrics, ["metrics": ["rmssd"]], id: "c1")]), .final("Never reached.")])
        let (runtime, configuration) = try await makeRuntime(suite, transport: gated)
        let executed = ExecutedCalls()
        let work = Task { try await runtime.runAgent(request(configuration)) { call in executed.add(call.name); return AgentToolOutcome(callID: call.id, content: "{}") } }
        await waitUntilEntered(gated)
        await runtime.cancelRequests()
        gated.release()
        await #expect(throws: (any Error).self) { _ = try await work.value }
        #expect(gated.enteredCount == 1, "no second round after the cancel")
        #expect(executed.count == 0, "no lookup ran after the cancel")
    }

    @Test func aWholeLoopRunsToItsAnswerAndHandsBackEveryRound() async throws {
        let suite = AgentFixtures.Suite()
        let scripted = ScriptedAgentTransport([.toolCalls([AgentFixtures.call(AgentToolName.getMetrics, ["metrics": ["rmssd"]], id: "c1")]), .final("Done.")])
        let (runtime, configuration) = try await makeRuntime(suite, transport: scripted)
        let result = try await runtime.runAgent(request(configuration)) { call in AgentToolOutcome(callID: call.id, content: "{\"ok\":true}") }
        #expect(result.text == "Done." && result.rounds.count == 1 && result.calls.map(\.name) == [AgentToolName.getMetrics])
        #expect(scripted.requests[1].rounds.first?.outcomes.first?.content == "{\"ok\":true}")
    }
}

private final class ExecutedCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String] = []
    func add(_ name: String) { lock.withLock { names.append(name) } }
    var count: Int { lock.withLock { names.count } }
}
