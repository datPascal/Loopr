import AIKit
import Foundation
import Testing

@Suite struct AgentDecoderTests {
    private func decode(_ json: String, _ provider: CoachProvider) throws -> AgentTurn {
        try CoachAgentDecoder.decode(Data(json.utf8), provider: provider)
    }

    // MARK: Anthropic

    @Test func anthropicToolUseBecomesCallsAndKeepsThinkingForTheNextRequest() throws {
        let turn = try CoachAgentDecoder.decode(AgentFixtures.anthropicToolUse(), provider: .anthropic)
        guard case .toolCalls(let calls) = turn else { Issue.record("expected tool calls"); return }
        #expect(calls.count == 1 && calls[0].id == "toolu_1" && calls[0].name == "get_sleep")
        #expect(calls[0].arguments == #"{"days":7}"#)
        let types = try calls[0].echo.items.map { try #require(AgentFixtures.json($0)["type"] as? String) }
        #expect(types == ["thinking", "text", "tool_use"])
        let thinking = try AgentFixtures.json(calls[0].echo.items[0])
        #expect(thinking["signature"] as? String == "sig-abc")
    }

    @Test func anthropicEndTurnBecomesFinalText() throws {
        #expect(try CoachAgentDecoder.decode(AgentFixtures.anthropicFinal("Your sleep dipped."), provider: .anthropic) == .final("Your sleep dipped."))
        let withThinking = #"{"type":"message","role":"assistant","stop_reason":"end_turn","content":[{"type":"thinking","thinking":"","signature":"s"},{"type":"text","text":"A"},{"type":"text","text":"B"}]}"#
        #expect(try decode(withThinking, .anthropic) == .final("AB"))
    }

    @Test func anthropicParallelCallsKeepOrderAndShareOneEcho() throws {
        let json = #"{"type":"message","role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","id":"a","name":"get_sleep","input":{}},{"type":"tool_use","id":"b","name":"get_food","input":{"days":3}}]}"#
        guard case .toolCalls(let calls) = try decode(json, .anthropic) else { Issue.record("expected tool calls"); return }
        #expect(calls.map(\.id) == ["a", "b"] && calls[0].arguments == "{}")
        #expect(calls[0].echo == calls[1].echo && calls[0].echo.items.count == 2)
    }

    @Test func anthropicStopReasonsMapToErrors() {
        func response(_ reason: String) -> String { #"{"type":"message","role":"assistant","stop_reason":"\#(reason)","content":[{"type":"text","text":"x"}]}"# }
        #expect(throws: CoachStructuredError.refused) { try decode(response("refusal"), .anthropic) }
        for reason in ["max_tokens", "pause_turn", "model_context_window_exceeded"] {
            #expect(throws: CoachProviderError.incomplete) { try decode(response(reason), .anthropic) }
        }
        for reason in ["stop_sequence", "weird"] {
            #expect(throws: CoachProviderError.malformedResponse) { try decode(response(reason), .anthropic) }
        }
    }

    @Test func anthropicRejectsInconsistentOrUnknownContent() {
        let cases = [
            // tool_use stop without a tool_use block
            #"{"type":"message","role":"assistant","stop_reason":"tool_use","content":[{"type":"text","text":"x"}]}"#,
            // end_turn that still carries a tool_use block
            #"{"type":"message","role":"assistant","stop_reason":"end_turn","content":[{"type":"tool_use","id":"a","name":"get_sleep","input":{}}]}"#,
            // unknown block, such as a server tool result
            #"{"type":"message","role":"assistant","stop_reason":"end_turn","content":[{"type":"web_search_tool_result","content":[]}]}"#,
            // input is not an object
            #"{"type":"message","role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","id":"a","name":"get_sleep","input":"7"}]}"#,
            // duplicate ids
            #"{"type":"message","role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","id":"a","name":"get_sleep","input":{}},{"type":"tool_use","id":"a","name":"get_sleep","input":{}}]}"#,
            // bad tool name
            #"{"type":"message","role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","id":"a","name":"get sleep","input":{}}]}"#,
            // empty text
            #"{"type":"message","role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"  "}]}"#,
            // wrong role and type
            #"{"type":"message","role":"user","stop_reason":"end_turn","content":[{"type":"text","text":"x"}]}"#,
            #"{"type":"error","error":{"type":"overloaded_error"}}"#,
            "not json", "[]", "{}",
        ]
        for json in cases {
            #expect(throws: CoachProviderError.malformedResponse, "\(json)") { try decode(json, .anthropic) }
        }
    }

    // MARK: OpenAI

    @Test func openAIFunctionCallBecomesCallsAndKeepsReasoningItems() throws {
        guard case .toolCalls(let calls) = try CoachAgentDecoder.decode(AgentFixtures.openAIToolCall(), provider: .openAI) else {
            Issue.record("expected tool calls"); return
        }
        #expect(calls.count == 1 && calls[0].id == "call_1" && calls[0].name == "get_sleep" && calls[0].arguments == #"{"days":7}"#)
        let types = try calls[0].echo.items.map { try #require(AgentFixtures.json($0)["type"] as? String) }
        #expect(types == ["reasoning", "function_call"])
        #expect(try AgentFixtures.json(calls[0].echo.items[0])["encrypted_content"] as? String == "enc-xyz")
    }

    @Test func openAIMessageBecomesFinalTextAndEmptyArgumentsBecomeAnObject() throws {
        #expect(try CoachAgentDecoder.decode(AgentFixtures.openAIFinal("Fine."), provider: .openAI) == .final("Fine."))
        let json = #"{"status":"completed","output":[{"type":"function_call","call_id":"c","name":"list_patterns","arguments":""}]}"#
        guard case .toolCalls(let calls) = try decode(json, .openAI) else { Issue.record("expected tool calls"); return }
        #expect(calls[0].arguments == "{}")
    }

    @Test func openAIStatusRefusalAndErrorsAreStrict() {
        #expect(throws: CoachProviderError.incomplete) { try decode(#"{"status":"incomplete","output":[]}"#, .openAI) }
        #expect(throws: CoachProviderError.incomplete) { try decode(#"{"status":"failed","output":[]}"#, .openAI) }
        let refusal = #"{"status":"completed","output":[{"type":"message","role":"assistant","status":"completed","content":[{"type":"refusal","refusal":"no"}]}]}"#
        #expect(throws: CoachStructuredError.refused) { try decode(refusal, .openAI) }
        let cases = [
            #"{"status":"completed","error":{"code":"x"},"output":[]}"#,
            #"{"status":"completed","incomplete_details":{"reason":"max_output_tokens"},"output":[]}"#,
            #"{"status":"completed","output":[{"type":"web_search_call","id":"w"}]}"#,
            #"{"status":"completed","output":[{"type":"function_call","call_id":"c","name":"get_sleep","arguments":"{bad"}]}"#,
            #"{"status":"completed","output":[{"type":"function_call","call_id":"c","name":"get_sleep","arguments":"[1]"}]}"#,
            #"{"status":"completed","output":[{"type":"function_call","call_id":"c","name":"get_sleep","arguments":"{}","status":"incomplete"}]}"#,
            #"{"status":"completed","output":[{"type":"function_call","name":"get_sleep","arguments":"{}"}]}"#,
            #"{"status":"completed","output":[{"type":"message","role":"assistant","status":"in_progress","content":[{"type":"output_text","text":"x"}]}]}"#,
            #"{"status":"completed","output":[{"type":"message","role":"assistant","status":"completed","content":[{"type":"image","text":"x"}]}]}"#,
            #"{"status":"completed","output":[{"type":"reasoning","id":"r"}]}"#,
            #"{"status":"completed","output":[]}"#,
            #"{"status":"completed","output":[{"type":"function_call","call_id":"c","name":"a","arguments":"{}"},{"type":"function_call","call_id":"c","name":"a","arguments":"{}"}]}"#,
        ]
        for json in cases {
            #expect(throws: CoachProviderError.malformedResponse, "\(json)") { try decode(json, .openAI) }
        }
    }

    @Test func sizeLimitsAreEnforced() {
        let calls = (0..<21).map { #"{"type":"function_call","call_id":"c\#($0)","name":"get_sleep","arguments":"{}"}"# }.joined(separator: ",")
        #expect(throws: CoachProviderError.malformedResponse) { try decode(#"{"status":"completed","output":[\#(calls)]}"#, .openAI) }
        let long = String(repeating: "a", count: 100_001)
        #expect(throws: CoachProviderError.malformedResponse) { try CoachAgentDecoder.decode(AgentFixtures.anthropicFinal(long), provider: .anthropic) }
        #expect(throws: CoachProviderError.malformedResponse) {
            try CoachAgentDecoder.decode(Data(repeating: 32, count: 1_000_001), provider: .openAI)
        }
    }

    // MARK: Decoder and request agree

    @Test func decodedTurnsRoundTripIntoTheNextRequest() throws {
        for (provider, response) in [(CoachProvider.anthropic, AgentFixtures.anthropicToolUse()), (.openAI, AgentFixtures.openAIToolCall())] {
            guard case .toolCalls(let calls) = try CoachAgentDecoder.decode(response, provider: provider) else { Issue.record("expected tool calls"); return }
            let round = AgentRound(calls: calls, outcomes: [AgentToolOutcome(callID: calls[0].id, content: #"{"ok":true}"#)])
            let body = try AgentFixtures.json(AgentFixtures.request(provider, rounds: [round]).payload())
            let key = provider == .openAI ? "input" : "messages"
            let items = try #require(body[key] as? [[String: Any]])
            #expect(items.count == (provider == .openAI ? 4 : 3))
            let text = String(data: try JSONSerialization.data(withJSONObject: items), encoding: .utf8) ?? ""
            #expect(text.contains(provider == .openAI ? "enc-xyz" : "sig-abc"))
        }
    }
}
