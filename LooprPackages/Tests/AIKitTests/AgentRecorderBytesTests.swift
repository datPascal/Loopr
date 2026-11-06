import AIKit
import Foundation
import Testing

@Suite(.serialized) struct AgentRecorderBytesTests {
    private let schema = Data(#"{"type":"object"}"#.utf8)

    private func sse(_ provider: CoachProvider) -> BodyCapturingStub.Response {
        let lines = provider == .openAI
            ? [#"{"type":"response.output_text.delta","delta":"Hello"}"#, #"{"type":"response.completed"}"#]
            : [#"{"type":"content_block_delta","delta":{"type":"text_delta","text":"Hello"}}"#, #"{"type":"message_stop"}"#]
        let body = lines.map { "data: \($0)\n\n" }.joined()
        return .init(status: 200, contentType: "text/event-stream", body: Data(body.utf8))
    }
    private func json(_ data: Data, status: Int = 200) -> BodyCapturingStub.Response { .init(status: status, contentType: "application/json", body: data) }

    private func chat(_ provider: CoachProvider, context: AIRequestContext) -> CoachChatRequest {
        CoachChatRequest(configuration: AgentFixtures.configuration(provider, model: "m-\(provider.rawValue)"), instructions: "Brief.", context: "Sleep avg 7h.",
                         messages: [CoachChatMessage(role: .user, text: "Why am I tired?")], recording: context)
    }
    private func food(_ provider: CoachProvider, context: AIRequestContext? = nil) -> CoachStructuredRequest {
        let base = CoachStructuredRequest(configuration: AgentFixtures.configuration(provider), instructions: "Food only", text: "Two eggs", imageJPEG: nil, schema: schema)
        guard let context else { return base }
        return CoachStructuredRequest(configuration: base.configuration, instructions: base.instructions, text: base.text, imageJPEG: nil, schema: schema, recording: context)
    }
    private func structuredResponse(_ provider: CoachProvider) -> Data {
        Data((provider == .openAI
            ? #"{"status":"completed","output":[{"type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"{\"items\":[]}"}]}]}"#
            : #"{"type":"message","role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"{\"items\":[]}"}]}"#).utf8)
    }
    private func drain(_ stream: AsyncThrowingStream<CoachStreamEvent, Error>) async throws -> String {
        var text = ""
        for try await event in stream { if case .text(let value) = event { text += value } }
        return text
    }

    @Test func recordedBytesEqualTheSentBodyForStreamStructuredAndTurn() async throws {
        let session = BodyCapturingStub.session(); defer { session.invalidateAndCancel() }
        for provider in CoachProvider.allCases {
            let conversation = UUID()
            let chatContext = AIRequestContext(purpose: .chat, conversationID: conversation, origin: "Sleep, Tue 13 Oct")
            let toolContext = AIRequestContext(purpose: .toolRound, conversationID: conversation, origin: "Sleep, Tue 13 Oct")
            let agentRequest = AgentFixtures.request(provider, recording: toolContext)
            let chatRequest = chat(provider, context: chatContext)
            let foodRequest = food(provider)

            // stream
            var recorder = RecorderBox(); var transport = CoachURLSessionTransport(session: session, recorder: recorder)
            BodyCapturingStub.configure(.success(sse(provider)))
            #expect(try await drain(transport.stream(chatRequest, key: "fixture-key")) == "Hello")
            var sent = try #require(BodyCapturingStub.sentBodies.first)
            var record = try #require(recorder.records.first)
            #expect(recorder.records.count == 1 && BodyCapturingStub.sentBodies.count == 1)
            let expectedChat = try chatRequest.payload()
            #expect(record.body == sent && sent == expectedChat)
            #expect(record.purpose == .chat && record.conversationID == conversation && record.origin == "Sleep, Tue 13 Oct")
            #expect(record.provider == provider && record.model == "m-\(provider.rawValue)" && record.bodyBytes == sent.count)
            #expect(record.toolCalls.isEmpty && record.denials.isEmpty && record.status == .sent)
            #expect(recorder.finishes.map(\.status) == [.succeeded] && recorder.finishes.first?.id == record.id && recorder.finishes.first?.httpStatus == 200)

            // structured
            recorder = RecorderBox(); transport = CoachURLSessionTransport(session: session, recorder: recorder)
            BodyCapturingStub.configure(.success(json(structuredResponse(provider))))
            _ = try await transport.structured(foodRequest, key: "fixture-key")
            sent = try #require(BodyCapturingStub.sentBodies.first)
            record = try #require(recorder.records.first)
            let expectedFood = try foodRequest.payload()
            #expect(record.body == sent && sent == expectedFood && recorder.records.count == 1)
            #expect(record.purpose == .foodEstimate && record.conversationID == nil && record.origin == nil)
            #expect(recorder.finishes.map(\.status) == [.succeeded])

            // turn
            recorder = RecorderBox(); transport = CoachURLSessionTransport(session: session, recorder: recorder)
            let response = provider == .openAI ? AgentFixtures.openAIFinal("Fine.") : AgentFixtures.anthropicFinal("Fine.")
            BodyCapturingStub.configure(.success(json(response)))
            #expect(try await transport.turn(agentRequest, key: "fixture-key") == .final("Fine."))
            sent = try #require(BodyCapturingStub.sentBodies.first)
            record = try #require(recorder.records.first)
            let expectedAgent = try agentRequest.payload()
            #expect(record.body == sent && sent == expectedAgent && recorder.records.count == 1)
            #expect(record.purpose == .toolRound && record.conversationID == conversation && record.origin == "Sleep, Tue 13 Oct")
            #expect(recorder.finishes.map(\.status) == [.succeeded] && recorder.finishes.first?.httpStatus == 200)
        }
    }

    @Test func theRecorderRunsBeforeTheBytesLeave() async throws {
        let session = BodyCapturingStub.session(); defer { session.invalidateAndCancel() }
        let log = EventLog()
        let transport = CoachURLSessionTransport(session: session, recorder: RecorderBox(log: log))
        BodyCapturingStub.configure(.success(json(AgentFixtures.anthropicFinal("Fine."))), log: log)
        _ = try await transport.turn(AgentFixtures.request(.anthropic), key: "fixture-key")
        #expect(log.events == ["record", "send"])
    }

    @Test func aToolTurnRecordsEarlierCallsWithDomainResultBytesAndDenials() async throws {
        let session = BodyCapturingStub.session(); defer { session.invalidateAndCancel() }
        let recorder = RecorderBox()
        let transport = CoachURLSessionTransport(session: session, recorder: recorder)
        let denial = "Journal notes is off in Your data, so Ask did not read it."
        let round = AgentRound(
            calls: [AgentToolCall(id: "a", name: "get_sleep", arguments: #"{"days":7}"#), AgentToolCall(id: "b", name: "get_journal"),
                    AgentToolCall(id: "c", name: "show_chart", arguments: #"{"chartId":"x"}"#)],
            outcomes: [AgentToolOutcome(callID: "a", content: String(repeating: "é", count: 100)), .denied(callID: "b", message: denial),
                       AgentToolOutcome(callID: "c", content: "unknown chart", isError: true)])
        BodyCapturingStub.configure(.success(json(AgentFixtures.anthropicFinal("Fine."))))
        _ = try await transport.turn(AgentFixtures.request(.anthropic, rounds: [round]), key: "fixture-key")
        let record = try #require(recorder.records.first)
        #expect(record.toolCalls == [
            AIRecordedToolCall(name: "get_sleep", domain: "metrics", resultBytes: 200, isError: false, denied: false),
            AIRecordedToolCall(name: "get_journal", domain: "journalNotes", resultBytes: denial.utf8.count, isError: true, denied: true),
            AIRecordedToolCall(name: "show_chart", domain: AgentToolSpec.appDomain, resultBytes: 13, isError: true, denied: false),
        ])
        #expect(record.denials == [AIRecordedDenial(toolName: "get_journal", domain: "journalNotes", message: denial)])
        // The denial text is in the recorded body, so the log shows what the model saw.
        #expect(String(data: record.body, encoding: .utf8)?.contains(denial) == true)
    }

    @Test func failuresAreRecordedWithTheirStatus() async throws {
        let session = BodyCapturingStub.session(); defer { session.invalidateAndCancel() }
        let request = AgentFixtures.request(.openAI)
        let cases: [(Result<BodyCapturingStub.Response, URLError>, AIRequestStatus, Int?)] = [
            (.success(json(Data(#"{"error":{"type":"rate_limit_error"}}"#.utf8), status: 429)), .failed, 429),
            (.success(json(Data("broken".utf8))), .failed, 200),
            (.failure(URLError(.notConnectedToInternet)), .failed, nil),
            (.success(json(Data(#"{"status":"completed","output":[{"type":"message","role":"assistant","status":"completed","content":[{"type":"refusal","refusal":"no"}]}]}"#.utf8))), .refused, 200),
        ]
        for (response, status, http) in cases {
            let recorder = RecorderBox()
            let transport = CoachURLSessionTransport(session: session, recorder: recorder)
            BodyCapturingStub.configure(response)
            await #expect(throws: (any Error).self) { try await transport.turn(request, key: "fixture-key") }
            #expect(recorder.records.count == 1 && recorder.finishes.count == 1)
            #expect(recorder.finishes.first?.status == status && recorder.finishes.first?.httpStatus == http)
        }
    }

    @Test func requestsThatFailBeforeSendingAreNotRecorded() async throws {
        let session = BodyCapturingStub.session(); defer { session.invalidateAndCancel() }
        let recorder = RecorderBox()
        let transport = CoachURLSessionTransport(session: session, recorder: recorder)
        BodyCapturingStub.configure(.success(json(AgentFixtures.anthropicFinal("Fine."))))
        await #expect(throws: CoachProviderError.missingKey) { try await transport.turn(AgentFixtures.request(.anthropic), key: " ") }
        await #expect(throws: CoachAgentError.invalidRequest) { try await transport.turn(AgentFixtures.request(.anthropic, tools: []), key: "fixture-key") }
        #expect(recorder.records.isEmpty && BodyCapturingStub.sentBodies.isEmpty)
    }

    @Test func theDefaultTransportStillRefusesUnstubbedToolTurns() async throws {
        let recorder = RecorderBox()
        for provider in CoachProvider.allCases {
            await #expect(throws: CoachStructuredError.unstubbedTest) {
                // An empty key also stops before networking if the test guard regresses.
                try await CoachURLSessionTransport(recorder: recorder).turn(AgentFixtures.request(provider), key: "")
            }
        }
        #expect(recorder.records.isEmpty)
    }

    @Test func aTransportWithoutARecorderBehavesAsBefore() async throws {
        let session = BodyCapturingStub.session(); defer { session.invalidateAndCancel() }
        let transport = CoachURLSessionTransport(session: session)
        BodyCapturingStub.configure(.success(json(AgentFixtures.openAIFinal("Fine."))))
        #expect(try await transport.turn(AgentFixtures.request(.openAI), key: "fixture-key") == .final("Fine."))
        #expect(BodyCapturingStub.sentBodies.count == 1)
    }

    @Test func recordsRoundTripThroughCodable() throws {
        let record = AIRequestRecord(provider: .anthropic, model: "m", conversationID: UUID(), origin: "Today", purpose: .weeklyReview,
                                     body: Data("{}".utf8), toolCalls: [AIRecordedToolCall(name: "x", domain: "food", resultBytes: 4, isError: false, denied: false)],
                                     denials: [AIRecordedDenial(toolName: "y", domain: "cycle", message: "off")], status: .failed, httpStatus: 500)
        let decoded = try JSONDecoder().decode(AIRequestRecord.self, from: JSONEncoder().encode(record))
        #expect(decoded == record)
        #expect(AIRequestPurpose.allCases.map(\.rawValue) == ["chat", "toolRound", "briefing", "weeklyReview", "foodEstimate"])
    }
}
