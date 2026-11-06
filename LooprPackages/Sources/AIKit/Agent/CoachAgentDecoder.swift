import Foundation

/// Reads a non-streaming tool turn. As strict as `CoachStructuredDecoder`: an unknown item,
/// a missing field or a status other than the expected one is `malformedResponse`, never a guess.
public enum CoachAgentDecoder {
    public static let maxResponseBytes = 1_000_000
    public static let maxTextBytes = 100_000
    public static let maxCallsPerTurn = 20
    public static let maxArgumentBytes = 50_000

    public static func decode(_ data: Data, provider: CoachProvider) throws -> AgentTurn {
        guard data.count <= maxResponseBytes, let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CoachProviderError.malformedResponse
        }
        var text: [String] = []
        var calls: [(id: String, name: String, arguments: String)] = []
        var echo: [Data] = []
        switch provider {
        case .openAI:
            guard root["status"] as? String == "completed" else { throw CoachProviderError.incomplete }
            guard root["error"] == nil || root["error"] is NSNull,
                  root["incomplete_details"] == nil || root["incomplete_details"] is NSNull,
                  let output = root["output"] as? [[String: Any]] else { throw CoachProviderError.malformedResponse }
            for item in output {
                switch item["type"] as? String {
                case "reasoning":
                    echo.append(try raw(item))
                case "message":
                    guard item["role"] as? String == "assistant", item["status"] as? String == "completed",
                          let content = item["content"] as? [[String: Any]] else { throw CoachProviderError.malformedResponse }
                    for block in content {
                        if block["type"] as? String == "refusal" { throw CoachStructuredError.refused }
                        guard block["type"] as? String == "output_text", let value = block["text"] as? String else {
                            throw CoachProviderError.malformedResponse
                        }
                        text.append(value)
                    }
                    echo.append(try raw(item))
                case "function_call":
                    guard let id = item["call_id"] as? String, let name = item["name"] as? String,
                          let arguments = item["arguments"] as? String,
                          item["status"] == nil || item["status"] is NSNull || item["status"] as? String == "completed"
                    else { throw CoachProviderError.malformedResponse }
                    calls.append((id, name, try canonicalArguments(arguments)))
                    echo.append(try raw(item))
                default: throw CoachProviderError.malformedResponse
                }
            }
        case .anthropic:
            let reason = root["stop_reason"] as? String
            if reason == "refusal" { throw CoachStructuredError.refused }
            if ["max_tokens", "model_context_window_exceeded", "pause_turn"].contains(reason ?? "") { throw CoachProviderError.incomplete }
            guard reason == "end_turn" || reason == "tool_use", root["type"] as? String == "message",
                  root["role"] as? String == "assistant", let content = root["content"] as? [[String: Any]] else {
                throw CoachProviderError.malformedResponse
            }
            for block in content {
                switch block["type"] as? String {
                case "thinking", "redacted_thinking":
                    echo.append(try raw(block))
                case "text":
                    guard let value = block["text"] as? String else { throw CoachProviderError.malformedResponse }
                    text.append(value)
                    echo.append(try raw(block))
                case "tool_use":
                    guard let id = block["id"] as? String, let name = block["name"] as? String,
                          let input = block["input"] as? [String: Any] else { throw CoachProviderError.malformedResponse }
                    calls.append((id, name, try canonicalArguments(input)))
                    echo.append(try raw(block))
                default: throw CoachProviderError.malformedResponse
                }
            }
            // The stop reason and the blocks must agree.
            guard (reason == "tool_use") == !calls.isEmpty else { throw CoachProviderError.malformedResponse }
        }
        if !calls.isEmpty {
            guard calls.count <= maxCallsPerTurn, Set(calls.map(\.id)).count == calls.count,
                  calls.allSatisfy({ !$0.id.isEmpty && AgentToolSpec.validName($0.name) }) else { throw CoachProviderError.malformedResponse }
            let shared = AgentAssistantEcho(items: echo)
            return .toolCalls(calls.map { AgentToolCall(id: $0.id, name: $0.name, arguments: $0.arguments, echo: shared) })
        }
        let result = text.joined()
        guard !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, result.utf8.count <= maxTextBytes else {
            throw CoachProviderError.malformedResponse
        }
        return .final(result)
    }

    private static func raw(_ object: [String: Any]) throws -> Data {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { throw CoachProviderError.malformedResponse }
        return data
    }

    private static func canonicalArguments(_ string: String) throws -> String {
        // OpenAI sends a string. An empty string means no arguments.
        guard string.utf8.count <= maxArgumentBytes else { throw CoachProviderError.malformedResponse }
        let source = string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "{}" : string
        guard let object = try? JSONSerialization.jsonObject(with: Data(source.utf8)) as? [String: Any] else {
            throw CoachProviderError.malformedResponse
        }
        return try canonicalArguments(object)
    }

    private static func canonicalArguments(_ object: [String: Any]) throws -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              data.count <= maxArgumentBytes, let string = String(data: data, encoding: .utf8) else { throw CoachProviderError.malformedResponse }
        return string
    }
}
