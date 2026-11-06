import Foundation

public struct AgentLoopResult: Equatable, Sendable {
    public let text: String
    /// Every round that ran, in order, for persistence and the request log.
    public let rounds: [AgentRound]
    public var calls: [AgentToolCall] { rounds.flatMap(\.calls) }
    public var outcomes: [AgentToolOutcome] { rounds.flatMap(\.outcomes) }
    public init(text: String, rounds: [AgentRound]) { self.text = text; self.rounds = rounds }
}

/// Runs model turns until the model answers. Limits: at most 6 tool rounds, 20 tool calls and 20 KB per
/// result. Past a limit the loop stops running tools and tells the model so. A model that still asks for
/// tools after round 6 ends the loop with `CoachAgentError.roundLimit`.
///
/// Results are data. The loop never reads their text. It only caps their size and sends them back
/// in tool-result items, never in instructions or user text.
public struct AgentToolLoop: Sendable {
    public static let maxRounds = 6
    public static let maxCalls = 20
    public static let maxResultBytes = 20 * 1024
    public typealias Execute = @Sendable (AgentToolCall) async -> AgentToolOutcome

    private let transport: CoachAgentTransport
    private let key: String
    private let roundLimit: Int
    private let callLimit: Int
    private let resultLimit: Int

    /// Lower limits are allowed, higher ones are clamped to the maximums above.
    public init(transport: CoachAgentTransport, key: String, maxRounds: Int = AgentToolLoop.maxRounds,
                maxCalls: Int = AgentToolLoop.maxCalls, maxResultBytes: Int = AgentToolLoop.maxResultBytes) {
        self.transport = transport; self.key = key
        roundLimit = max(0, min(maxRounds, Self.maxRounds))
        callLimit = max(0, min(maxCalls, Self.maxCalls))
        resultLimit = max(64, min(maxResultBytes, Self.maxResultBytes))
    }

    public func run(_ request: CoachAgentRequest, execute: Execute) async throws -> AgentLoopResult {
        var request = request
        var rounds: [AgentRound] = []
        var used = 0
        let advertised = Set(request.tools.map(\.name))
        while true {
            try Task.checkCancellation()
            switch try await transport.turn(request, key: key) {
            case .final(let text):
                return AgentLoopResult(text: text, rounds: rounds)
            case .toolCalls(let calls):
                guard rounds.count < roundLimit else { throw CoachAgentError.roundLimit }
                var outcomes: [AgentToolOutcome] = []
                for call in calls {
                    try Task.checkCancellation()
                    let outcome: AgentToolOutcome
                    if used >= callLimit {
                        outcome = AgentToolOutcome(callID: call.id, content: "Not run. This question already used \(callLimit) tool calls. Answer with what you have.", isError: true)
                    } else if !advertised.contains(call.name) {
                        outcome = AgentToolOutcome(callID: call.id, content: "Not run. \(call.name) is not an available tool.", isError: true)
                    } else {
                        used += 1
                        let raw = await execute(call)
                        outcome = AgentToolOutcome(callID: call.id, content: Self.cap(raw.content, to: resultLimit),
                                                   isError: raw.isError, denied: raw.denied)
                    }
                    outcomes.append(outcome)
                }
                let round = AgentRound(calls: calls, outcomes: outcomes)
                rounds.append(round)
                request = request.appending(round)
            }
        }
    }

    /// Cuts at a character boundary and says so, so the total stays within `limit` bytes.
    static func cap(_ text: String, to limit: Int) -> String {
        guard text.utf8.count > limit else { return text }
        let note = "\n[Cut at \(limit / 1024) KB. Ask for a narrower range to see the rest.]"
        let room = max(0, limit - note.utf8.count)
        var end = text.startIndex
        var bytes = 0
        for index in text.indices {
            let size = String(text[index]).utf8.count
            if bytes + size > room { break }
            bytes += size; end = text.index(after: index)
        }
        return String(text[..<end]) + note
    }
}
