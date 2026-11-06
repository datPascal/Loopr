import Foundation

public enum CoachStructuredError: Error, Equatable, Sendable, LocalizedError {
    case refused, consentRequired, unstubbedTest
    public var errorDescription: String? {
        switch self {
        case .refused: "The provider could not estimate this food. You can enter it yourself."
        case .consentRequired: "Review photo access before sending to this provider."
        case .unstubbedTest: "This test request needs an explicit provider stub."
        }
    }
}

/// Structured proposals never perform a write. The caller validates domain values and requests confirmation.
public struct CoachStructuredRequest: Sendable {
    public let configuration: CoachProviderConfiguration
    public let instructions: String
    public let text: String
    public let imageJPEG: Data?
    public let schema: Data
    /// Log metadata only. It is never sent to the provider.
    public var recording: AIRequestContext
    public init(configuration: CoachProviderConfiguration, instructions: String, text: String, imageJPEG: Data?, schema: Data,
                recording: AIRequestContext = AIRequestContext(purpose: .foodEstimate)) {
        self.configuration = configuration; self.instructions = instructions; self.text = text
        self.imageJPEG = imageJPEG; self.schema = schema; self.recording = recording
    }
    public func payload() throws -> Data {
        guard !text.isEmpty, text.utf8.count + instructions.utf8.count <= 60_000,
              schema.count <= 50_000, imageJPEG == nil || !(imageJPEG?.isEmpty ?? true),
              (imageJPEG?.count ?? 0) <= 3_000_000,
              let schemaObject = try JSONSerialization.jsonObject(with: schema) as? [String: Any],
              schemaObject["type"] as? String == "object" else { throw CoachProviderError.emptyMessage }
        var object: [String: Any]
        switch configuration.provider {
        case .openAI:
            var content: [[String: Any]] = []
            if let imageJPEG { content.append(["type": "input_image", "image_url": "data:image/jpeg;base64," + imageJPEG.base64EncodedString()]) }
            content.append(["type": "input_text", "text": text])
            object = ["model": configuration.model, "instructions": instructions,
                "input": [["role": "user", "content": content]], "max_output_tokens": 8192, "store": false, "stream": false,
                "text": ["format": ["type": "json_schema", "name": "food_draft", "strict": true, "schema": schemaObject]]]
            if configuration.model.hasPrefix("gpt-6") { object["reasoning"] = ["effort": "low"] }
        case .anthropic:
            var content: [[String: Any]] = []
            if let imageJPEG {
                content.append(["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": imageJPEG.base64EncodedString()]])
            }
            content.append(["type": "text", "text": text])
            var output: [String: Any] = ["format": ["type": "json_schema", "schema": schemaObject]]
            if configuration.model.contains("5-5") { output["effort"] = "low" }
            object = ["model": configuration.model, "system": instructions,
                "messages": [["role": "user", "content": content]], "max_tokens": 8192, "stream": false, "output_config": output]
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}

public protocol CoachStructuredTransport: Sendable {
    func structured(_ request: CoachStructuredRequest, key: String) async throws -> Data
}

public enum CoachStructuredDecoder {
    public static func decode(_ data: Data, provider: CoachProvider) throws -> Data {
        guard data.count <= 1_000_000, let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CoachProviderError.malformedResponse
        }
        var text: [String] = []
        switch provider {
        case .openAI:
            guard root["status"] as? String == "completed" else { throw CoachProviderError.incomplete }
            guard root["error"] == nil || root["error"] is NSNull,
                  root["incomplete_details"] == nil || root["incomplete_details"] is NSNull,
                  let output = root["output"] as? [[String: Any]] else { throw CoachProviderError.malformedResponse }
            for item in output {
                if item["type"] as? String == "reasoning" { continue }
                guard item["type"] as? String == "message", item["role"] as? String == "assistant",
                      item["status"] as? String == "completed", let content = item["content"] as? [[String: Any]] else {
                    throw CoachProviderError.malformedResponse
                }
                for block in content {
                    if block["type"] as? String == "refusal" { throw CoachStructuredError.refused }
                    guard block["type"] as? String == "output_text", let value = block["text"] as? String else {
                        throw CoachProviderError.malformedResponse
                    }
                    text.append(value)
                }
            }
        case .anthropic:
            let reason = root["stop_reason"] as? String
            if reason == "refusal" { throw CoachStructuredError.refused }
            if ["max_tokens", "model_context_window_exceeded"].contains(reason ?? "") { throw CoachProviderError.incomplete }
            guard reason == "end_turn", root["type"] as? String == "message", root["role"] as? String == "assistant",
                  let content = root["content"] as? [[String: Any]] else { throw CoachProviderError.malformedResponse }
            for block in content {
                if ["thinking", "redacted_thinking"].contains(block["type"] as? String ?? "") { continue }
                guard block["type"] as? String == "text", let value = block["text"] as? String else { throw CoachProviderError.malformedResponse }
                text.append(value)
            }
        }
        let result = Data(text.joined().utf8)
        guard !result.isEmpty, result.count <= 100_000,
              (try? JSONSerialization.jsonObject(with: result)) is [String: Any] else { throw CoachProviderError.malformedResponse }
        return result
    }
}
