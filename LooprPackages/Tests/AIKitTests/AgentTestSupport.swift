import AIKit
import Testing
import Foundation

enum AgentFixtures {
    static let schema = Data(#"{"type":"object","properties":{"days":{"type":"integer"}},"required":["days"]}"#.utf8)
    static let sleepTool = AgentToolSpec(name: "get_sleep", description: "Sleep records for a date range.", jsonSchema: schema, domain: "metrics")
    static let notesTool = AgentToolSpec(name: "get_journal", description: "Journal answers and notes.", jsonSchema: schema, domain: "journalNotes")
    static let chartTool = AgentToolSpec(name: "show_chart", description: "Show a chart from a stored candidate.", jsonSchema: Data(#"{"type":"object","properties":{"chartId":{"type":"string"}}}"#.utf8))

    static func configuration(_ provider: CoachProvider, model: String? = nil) -> CoachProviderConfiguration {
        CoachProviderConfiguration(provider: provider, model: model ?? "chosen-model")
    }

    static func request(_ provider: CoachProvider, tools: [AgentToolSpec] = [sleepTool, notesTool, chartTool], rounds: [AgentRound] = [],
                        model: String? = nil, recording: AIRequestContext = AIRequestContext(purpose: .toolRound)) -> CoachAgentRequest {
        CoachAgentRequest(configuration: configuration(provider, model: model), instructions: "Be brief.", context: "Sleep avg 7h.",
                          messages: [CoachChatMessage(role: .user, text: "Why did I sleep badly?")], tools: tools, rounds: rounds, recording: recording)
    }

    static func json(_ data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    static func echo(_ objects: [[String: Any]]) throws -> AgentAssistantEcho {
        AgentAssistantEcho(items: try objects.map { try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) })
    }

    // Provider responses.
    static func anthropicToolUse(id: String = "toolu_1", name: String = "get_sleep", input: String = #"{"days":7}"#, thinking: Bool = true) -> Data {
        let think = thinking ? #"{"type":"thinking","thinking":"plan","signature":"sig-abc"},"# : ""
        return Data(#"{"type":"message","role":"assistant","stop_reason":"tool_use","content":[\#(think){"type":"text","text":"Checking."},{"type":"tool_use","id":"\#(id)","name":"\#(name)","input":\#(input)}]}"#.utf8)
    }
    static func anthropicFinal(_ text: String) -> Data {
        Data(#"{"type":"message","role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"\#(text)"}]}"#.utf8)
    }
    static func openAIToolCall(callID: String = "call_1", name: String = "get_sleep", arguments: String = #"{\"days\":7}"#) -> Data {
        Data(#"{"status":"completed","output":[{"type":"reasoning","id":"rs_1","summary":[],"encrypted_content":"enc-xyz"},{"type":"function_call","id":"fc_1","call_id":"\#(callID)","name":"\#(name)","arguments":"\#(arguments)","status":"completed"}]}"#.utf8)
    }
    static func openAIFinal(_ text: String) -> Data {
        Data(#"{"status":"completed","output":[{"type":"message","id":"msg_1","role":"assistant","status":"completed","content":[{"type":"output_text","text":"\#(text)"}]}]}"#.utf8)
    }
}

/// Plays back scripted turns and keeps every request it saw.
final class ScriptedAgentTransport: CoachAgentTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var script: [Result<AgentTurn, Error>]
    private var seen: [CoachAgentRequest] = []
    /// When the script runs out, repeat this turn. Nil makes the transport fail the test run with a thrown error.
    private let repeating: AgentTurn?
    init(_ script: [Result<AgentTurn, Error>], repeating: AgentTurn? = nil) { self.script = script; self.repeating = repeating }
    var requests: [CoachAgentRequest] { lock.withLock { seen } }
    func turn(_ request: CoachAgentRequest, key: String) async throws -> AgentTurn {
        let next: Result<AgentTurn, Error>? = lock.withLock {
            seen.append(request)
            return script.isEmpty ? nil : script.removeFirst()
        }
        if let next { return try next.get() }
        if let repeating { return repeating }
        throw CoachProviderError.malformedResponse
    }
}

final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ event: String) { lock.withLock { items.append(event) } }
    var events: [String] { lock.withLock { items } }
}

final class RecorderBox: AIRequestRecording, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [AIRequestRecord] = []
    private var finished: [(UUID, AIRequestStatus, Int?)] = []
    private let log: EventLog?
    init(log: EventLog? = nil) { self.log = log }
    var records: [AIRequestRecord] { lock.withLock { recorded } }
    var finishes: [(id: UUID, status: AIRequestStatus, httpStatus: Int?)] { lock.withLock { finished.map { ($0.0, $0.1, $0.2) } } }
    func willSend(_ record: AIRequestRecord) { lock.withLock { recorded.append(record) }; log?.add("record") }
    func didFinish(id: UUID, status: AIRequestStatus, httpStatus: Int?) { lock.withLock { finished.append((id, status, httpStatus)) } }
}

/// Serves one canned response and keeps the exact bytes of every request body. Nothing reaches the network.
final class BodyCapturingStub: URLProtocol, @unchecked Sendable {
    struct Response: Sendable { var status: Int; var contentType: String; var body: Data }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var response: Result<Response, URLError>?
    nonisolated(unsafe) private static var bodies: [Data] = []
    nonisolated(unsafe) private static var log: EventLog?
    static func configure(_ value: Result<Response, URLError>, log: EventLog? = nil) {
        lock.withLock { response = value; bodies = []; Self.log = log }
    }
    static var sentBodies: [Data] { lock.withLock { bodies } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body = Self.readBody(request)
        let (result, log) = Self.lock.withLock { () -> (Result<Response, URLError>?, EventLog?) in
            Self.bodies.append(body)
            return (Self.response, Self.log)
        }
        log?.add("send")
        guard let result else { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return }
        switch result {
        case .failure(let error): client?.urlProtocol(self, didFailWithError: error)
        case .success(let value):
            let http = HTTPURLResponse(url: request.url!, statusCode: value.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": value.contentType])!
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: value.body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
    private static func readBody(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BodyCapturingStub.self]
        return URLSession(configuration: config)
    }
}
