import AIKit
import Foundation
import Testing

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String] = []
    func add(_ name: String) { lock.withLock { names.append(name) } }
    var all: [String] { lock.withLock { names } }
}

@Suite struct AgentToolLoopTests {
    private func calls(_ prefix: String, count: Int, name: String = "get_sleep") -> AgentTurn {
        .toolCalls((0..<count).map { AgentToolCall(id: "\(prefix)\($0)", name: name, arguments: #"{"days":7}"#) })
    }
    private func loop(_ transport: ScriptedAgentTransport) -> AgentToolLoop { AgentToolLoop(transport: transport, key: "fixture-key") }

    @Test func runsToolsSendsResultsBackAndReturnsTheFinalAnswer() async throws {
        let transport = ScriptedAgentTransport([.success(calls("a", count: 2)), .success(.final("Short nights followed late dinners."))])
        let seen = Counter()
        let result = try await loop(transport).run(AgentFixtures.request(.anthropic)) { call in
            seen.add(call.id)
            return AgentToolOutcome(callID: call.id, content: "result for \(call.id)")
        }
        #expect(result.text == "Short nights followed late dinners.")
        #expect(seen.all == ["a0", "a1"])
        #expect(result.rounds.count == 1 && result.calls.count == 2 && result.outcomes.map(\.content) == ["result for a0", "result for a1"])
        let requests = transport.requests
        #expect(requests.count == 2 && requests[0].rounds.isEmpty && requests[1].rounds == result.rounds)
    }

    @Test func answersWithoutToolsInOneRequest() async throws {
        let transport = ScriptedAgentTransport([.success(.final("Hello."))])
        let result = try await loop(transport).run(AgentFixtures.request(.openAI)) { _ in Issue.record("no tool should run"); return AgentToolOutcome(callID: "x", content: "") }
        #expect(result.text == "Hello." && result.rounds.isEmpty && transport.requests.count == 1)
    }

    @Test func stopsAfterSixRoundsWhenTheModelKeepsAsking() async throws {
        let transport = ScriptedAgentTransport([], repeating: calls("r", count: 1))
        let seen = Counter()
        await #expect(throws: CoachAgentError.roundLimit) {
            try await loop(transport).run(AgentFixtures.request(.anthropic)) { call in seen.add(call.id); return AgentToolOutcome(callID: call.id, content: "x") }
        }
        // Six rounds ran. The seventh request gave the model a chance to answer and it asked again.
        #expect(seen.all.count == 6 && transport.requests.count == 7)
        #expect(transport.requests.last?.rounds.count == 6)
    }

    @Test func answerAfterTheSixthRoundStillCounts() async throws {
        let script: [Result<AgentTurn, Error>] = (0..<6).map { .success(calls("r\($0)-", count: 1)) } + [.success(.final("Done."))]
        let result = try await loop(ScriptedAgentTransport(script)).run(AgentFixtures.request(.anthropic)) { AgentToolOutcome(callID: $0.id, content: "x") }
        #expect(result.text == "Done." && result.rounds.count == 6)
    }

    @Test func runsAtMostTwentyCallsAndTellsTheModelAboutTheRest() async throws {
        let transport = ScriptedAgentTransport([.success(calls("a", count: 15)), .success(calls("b", count: 10)), .success(.final("ok"))])
        let seen = Counter()
        let result = try await loop(transport).run(AgentFixtures.request(.anthropic)) { call in seen.add(call.id); return AgentToolOutcome(callID: call.id, content: "x") }
        #expect(seen.all.count == 20)
        let second = try #require(result.rounds.last)
        #expect(second.outcomes.prefix(5).allSatisfy { !$0.isError } && second.outcomes.suffix(5).allSatisfy { $0.isError && $0.content.hasPrefix("Not run") })
        #expect(result.outcomes.count == 25 && result.text == "ok")
    }

    @Test func capsEveryResultAtTwentyKilobytesOnACharacterBoundary() async throws {
        let transport = ScriptedAgentTransport([.success(calls("a", count: 1)), .success(.final("ok"))])
        let big = String(repeating: "Schlaf \u{1F634} ", count: 20_000)
        let result = try await loop(transport).run(AgentFixtures.request(.anthropic)) { AgentToolOutcome(callID: $0.id, content: big) }
        let content = try #require(result.outcomes.first?.content)
        #expect(content.utf8.count <= 20 * 1024 && content.utf8.count > 20 * 1024 - 200)
        #expect(content.contains("Cut at 20 KB"))
        #expect(String(data: Data(content.utf8), encoding: .utf8) == content)
        // The capped text is what the next request carries.
        let carried = try #require(transport.requests.last?.rounds.first?.outcomes.first?.content)
        #expect(carried == content)
    }

    @Test func leavesAResultOfExactlyTwentyKilobytesAlone() async throws {
        let transport = ScriptedAgentTransport([.success(calls("a", count: 1)), .success(.final("ok"))])
        let exact = String(repeating: "a", count: 20 * 1024)
        let result = try await loop(transport).run(AgentFixtures.request(.anthropic)) { AgentToolOutcome(callID: $0.id, content: exact) }
        #expect(result.outcomes.first?.content == exact)
    }

    @Test func doesNotRunToolsThatWereNeverOffered() async throws {
        let transport = ScriptedAgentTransport([.success(calls("a", count: 1, name: "get_cycle")), .success(.final("ok"))])
        let seen = Counter()
        let result = try await loop(transport).run(AgentFixtures.request(.anthropic, tools: [AgentFixtures.sleepTool])) { call in
            seen.add(call.name); return AgentToolOutcome(callID: call.id, content: "x")
        }
        #expect(seen.all.isEmpty)
        let outcome = try #require(result.outcomes.first)
        #expect(outcome.isError && !outcome.denied && outcome.content.contains("get_cycle"))
    }

    @Test func carriesDenialsToTheModelAndTheRecorder() async throws {
        let transport = ScriptedAgentTransport([.success(calls("a", count: 1, name: "get_journal")), .success(.final("I could not read your notes."))])
        let message = "Journal notes is off in Your data, so Ask did not read it."
        let result = try await loop(transport).run(AgentFixtures.request(.anthropic)) { .denied(callID: $0.id, message: message) }
        let outcome = try #require(result.outcomes.first)
        #expect(outcome.denied && outcome.isError && outcome.content == message)
        let second = try #require(transport.requests.last)
        let recorded = second.rounds.flatMap(\.outcomes)
        #expect(recorded.first?.denied == true)
        let text = String(data: try second.payload(), encoding: .utf8) ?? ""
        #expect(text.contains("Journal notes is off"))
    }

    @Test func ignoresACallIDTheExecutorGotWrongAndKeepsTheModelsID() async throws {
        let transport = ScriptedAgentTransport([.success(calls("a", count: 1)), .success(.final("ok"))])
        let result = try await loop(transport).run(AgentFixtures.request(.openAI)) { _ in AgentToolOutcome(callID: "wrong", content: "x") }
        #expect(result.outcomes.first?.callID == "a0")
    }

    @Test func transportErrorsAndCancellationPropagate() async throws {
        let failing = ScriptedAgentTransport([.failure(CoachProviderError.rateLimited)])
        await #expect(throws: CoachProviderError.rateLimited) {
            try await loop(failing).run(AgentFixtures.request(.anthropic)) { AgentToolOutcome(callID: $0.id, content: "x") }
        }
        let task = Task {
            try await loop(ScriptedAgentTransport([], repeating: calls("a", count: 1))).run(AgentFixtures.request(.anthropic)) { call in
                try? await Task.sleep(nanoseconds: 50_000_000)
                return AgentToolOutcome(callID: call.id, content: "x")
            }
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func lowerLimitsAreHonouredAndHigherOnesAreClamped() async throws {
        let one = ScriptedAgentTransport([], repeating: calls("a", count: 1))
        await #expect(throws: CoachAgentError.roundLimit) {
            try await AgentToolLoop(transport: one, key: "k", maxRounds: 2).run(AgentFixtures.request(.anthropic)) { AgentToolOutcome(callID: $0.id, content: "x") }
        }
        #expect(one.requests.count == 3)
        let many = ScriptedAgentTransport([], repeating: calls("a", count: 1))
        await #expect(throws: CoachAgentError.roundLimit) {
            try await AgentToolLoop(transport: many, key: "k", maxRounds: 99).run(AgentFixtures.request(.anthropic)) { AgentToolOutcome(callID: $0.id, content: "x") }
        }
        #expect(many.requests.count == 7)
    }
}
