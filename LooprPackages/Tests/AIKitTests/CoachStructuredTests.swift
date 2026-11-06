import AIKit
import Foundation
import Testing

struct CoachStructuredTests {
    private let schema = Data(#"{"type":"object","properties":{},"required":[],"additionalProperties":false}"#.utf8)
    private func request(_ provider: CoachProvider) -> CoachStructuredRequest {
        .init(configuration: .init(provider: provider, model: "selected-model"), instructions: "Food only", text: "Food note", imageJPEG: Data([1, 2, 3]), schema: schema)
    }
    @Test func requestsPreserveSelectedModelAndUseProviderSpecificImageAndSchemaFields() throws {
        for provider in CoachProvider.allCases {
            let payload = try request(provider).payload()
            let root = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
            #expect(root["model"] as? String == "selected-model" && root["stream"] as? Bool == false)
            #expect(root["response_format"] == nil && root["tools"] == nil)
            let encoded = String(decoding: payload, as: UTF8.self)
            #expect(!encoded.contains("capturedAt") && !encoded.contains("timeZone") && !encoded.contains("journal"))
            if provider == .openAI {
                #expect(root["store"] as? Bool == false)
                let input = try #require(root["input"] as? [[String: Any]])
                let content = try #require(input.first?["content"] as? [[String: Any]])
                #expect(content.first?["type"] as? String == "input_image")
                #expect(content.first?["image_url"] as? String == "data:image/jpeg;base64,AQID")
                #expect((root["text"] as? [String: Any])?["format"] != nil)
            } else {
                let messages = try #require(root["messages"] as? [[String: Any]])
                let content = try #require(messages.first?["content"] as? [[String: Any]])
                let image = try #require(content.first?["source"] as? [String: Any])
                #expect(content.first?["type"] as? String == "image")
                #expect(image["media_type"] as? String == "image/jpeg" && image["data"] as? String == "AQID")
                #expect((root["output_config"] as? [String: Any])?["format"] != nil)
            }
        }
    }
    @Test func defaultTransportRejectsUnstubbedRequestsBeforeNetworking() async throws {
        for provider in CoachProvider.allCases {
            await #expect(throws: CoachStructuredError.unstubbedTest) {
                // An empty key also stops before networking if the test guard regresses.
                try await CoachURLSessionTransport().structured(request(provider), key: "")
            }
        }
    }
    @Test func providerTerminalStatesAreCheckedBeforeAcceptingDraftJSON() throws {
        let openAI = Data(#"{"status":"completed","error":null,"incomplete_details":null,"output":[{"type":"reasoning"},{"type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"{\"items\":[]}"}]}]}"#.utf8)
        let claude = Data(#"{"type":"message","role":"assistant","stop_reason":"end_turn","content":[{"type":"thinking","thinking":"not food"},{"type":"text","text":"{\"items\":[]}"}]}"#.utf8)
        for (provider, data) in [(CoachProvider.openAI, openAI), (.anthropic, claude)] {
            #expect(try CoachStructuredDecoder.decode(data, provider: provider) == Data(#"{"items":[]}"#.utf8))
            #expect(throws: (any Error).self) { try CoachStructuredDecoder.decode(Data("broken".utf8), provider: provider) }
        }
        #expect(throws: CoachProviderError.incomplete) {
            try CoachStructuredDecoder.decode(Data(#"{"status":"incomplete","output":[]}"#.utf8), provider: .openAI)
        }
        #expect(throws: CoachStructuredError.refused) {
            try CoachStructuredDecoder.decode(Data(#"{"status":"completed","output":[{"type":"message","role":"assistant","status":"completed","content":[{"type":"refusal","refusal":"No"}]}]}"#.utf8), provider: .openAI)
        }
        for reason in ["max_tokens", "model_context_window_exceeded"] {
            #expect(throws: CoachProviderError.incomplete) {
                try CoachStructuredDecoder.decode(JSONSerialization.data(withJSONObject: ["stop_reason": reason]), provider: .anthropic)
            }
        }
        #expect(throws: CoachStructuredError.refused) {
            try CoachStructuredDecoder.decode(Data(#"{"stop_reason":"refusal"}"#.utf8), provider: .anthropic)
        }
        for reason in ["tool_use", "pause_turn", "stop_sequence", "unknown"] {
            #expect(throws: CoachProviderError.malformedResponse) {
                try CoachStructuredDecoder.decode(JSONSerialization.data(withJSONObject: ["stop_reason": reason]), provider: .anthropic)
            }
        }
    }
    @Test func boundsAndMultipleJSONDocumentsFailWithoutADraft() throws {
        let configuration = CoachProviderConfiguration(provider: .openAI, model: "selected")
        #expect(throws: CoachProviderError.emptyMessage) {
            try CoachStructuredRequest(configuration: configuration, instructions: "", text: "food", imageJPEG: Data(repeating: 0, count: 3_000_001), schema: schema).payload()
        }
        for text in ["", "{", "{}{}", "[]", "42", "```json\n{}\n```"] {
            let body = try JSONSerialization.data(withJSONObject: ["type": "message", "role": "assistant", "stop_reason": "end_turn", "content": [["type": "text", "text": text]]])
            #expect(throws: CoachProviderError.malformedResponse) { try CoachStructuredDecoder.decode(body, provider: .anthropic) }
        }
    }
}
