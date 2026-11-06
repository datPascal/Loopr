import Foundation

/// One tool the model may call. `jsonSchema` is the JSON Schema (an object schema) for the arguments.
/// `domain` names the Your data domain the tool reads, as the raw value of the app's `AgentDataDomain`
/// ("metrics", "food", "training", "journalAnswers", "journalNotes", "cycle", "supplements", "labs"). Tools that read no
/// personal domain, such as proposals and charts, use `AgentToolSpec.appDomain`.
public struct AgentToolSpec: Codable, Equatable, Sendable {
    public static let appDomain = "app"
    public let name: String
    public let description: String
    public let jsonSchema: Data
    public let domain: String
    public init(name: String, description: String, jsonSchema: Data, domain: String = AgentToolSpec.appDomain) {
        self.name = name; self.description = description; self.jsonSchema = jsonSchema; self.domain = domain
    }
    static func validName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 64 && name.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || $0 == 95 || $0 == 45
        }
    }
}

/// The provider items from one assistant turn, kept verbatim so the next request can send them back.
/// Anthropic needs thinking blocks next to their `tool_use` blocks. OpenAI with `store: false` needs
/// the reasoning items next to their `function_call` items. Each element is one JSON object.
public struct AgentAssistantEcho: Equatable, Sendable {
    public let items: [Data]
    public init(items: [Data] = []) { self.items = items }
    public static let empty = AgentAssistantEcho()
}

/// A tool call from the model. `arguments` is a JSON object serialized as a string.
public struct AgentToolCall: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let arguments: String
    /// Shared by every call from the same assistant turn. Empty for calls built by hand (tests, fixtures).
    public let echo: AgentAssistantEcho
    public init(id: String, name: String, arguments: String = "{}", echo: AgentAssistantEcho = .empty) {
        self.id = id; self.name = name; self.arguments = arguments; self.echo = echo
    }
    /// The arguments as a dictionary, or nil when they are not a JSON object.
    public var argumentObject: [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) as? [String: Any]
    }
}

/// What the app returns for one call. `content` is data for the model to read, never an instruction.
public struct AgentToolOutcome: Equatable, Sendable {
    public let callID: String
    public let content: String
    public let isError: Bool
    /// True when Your data blocked the read. `content` carries the denial message the model sees.
    public let denied: Bool
    public init(callID: String, content: String, isError: Bool = false, denied: Bool = false) {
        self.callID = callID; self.content = content; self.isError = isError || denied; self.denied = denied
    }
    public static func denied(callID: String, message: String) -> Self {
        .init(callID: callID, content: message, isError: true, denied: true)
    }
    public var contentBytes: Int { content.utf8.count }
}

/// One model turn that asked for tools, and what came back.
public struct AgentRound: Equatable, Sendable {
    public let calls: [AgentToolCall]
    public let outcomes: [AgentToolOutcome]
    public init(calls: [AgentToolCall], outcomes: [AgentToolOutcome]) { self.calls = calls; self.outcomes = outcomes }
}

public enum AgentTurn: Equatable, Sendable {
    case toolCalls([AgentToolCall])
    case final(String)
}

public enum CoachAgentError: Error, Equatable, Sendable, LocalizedError {
    /// The request is not well formed: bad tool name or schema, or a call without exactly one result.
    case invalidRequest
    /// The model kept asking for tools after the round limit.
    case roundLimit
    public var errorDescription: String? {
        switch self {
        case .invalidRequest: "Ask could not build this request."
        case .roundLimit: "Ask used too many lookups without an answer. Try a narrower question."
        }
    }
}
