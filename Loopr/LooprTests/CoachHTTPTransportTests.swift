import AIKit
import Foundation
import Testing

private final class CoachHTTPFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var body = Data()
    private var status = 200
    private var contentType = "text/event-stream"
    private var captured: URLRequest?
    func set(_ text: String, status: Int = 200, contentType: String = "text/event-stream") {
        lock.withLock { self.body = Data(text.utf8); self.status = status; self.contentType = contentType; captured = nil }
    }
    func response(_ request: URLRequest) -> (Data, Int, String) {
        lock.withLock { captured = request; return (body, status, contentType) }
    }
    func request() -> URLRequest? { lock.withLock { captured } }
}
private final class CoachHTTPProtocol: URLProtocol, @unchecked Sendable {
    static let fixture = CoachHTTPFixture()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (body, status, contentType) = Self.fixture.response(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": contentType])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized)
struct CoachHTTPTransportTests {
    private func request(_ provider: CoachProvider) -> CoachChatRequest {
        .init(configuration: .init(provider: provider, model: provider.defaultModel), instructions: "", context: "Fixture only", messages: [.init(role: .user, text: "Hello")])
    }
    private func transport() -> CoachURLSessionTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CoachHTTPProtocol.self]
        return .init(session: URLSession(configuration: configuration))
    }
    @Test func openAIStreamUsesResponsesAndDeliversText() async throws {
        CoachHTTPProtocol.fixture.set("data: {\"type\":\"response.output_text.delta\",\"delta\":\"Hello\"}\n\ndata: {\"type\":\"response.completed\"}\n\n")
        var events: [CoachStreamEvent] = []
        for try await event in transport().stream(request(.openAI), key: "test-key") { events.append(event) }
        #expect(events == [.text("Hello"), .completed])
        let sent = try #require(CoachHTTPProtocol.fixture.request())
        #expect(sent.url?.path == "/v1/responses")
        #expect(sent.httpMethod == "POST")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
    }
    @Test func claudeStreamUsesMessagesAndVersionHeader() async throws {
        CoachHTTPProtocol.fixture.set("event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"Hello\"}}\n\ndata: {\"type\":\"message_stop\"}\n\n")
        var events: [CoachStreamEvent] = []
        for try await event in transport().stream(request(.anthropic), key: "test-key") { events.append(event) }
        #expect(events == [.text("Hello"), .completed])
        let sent = try #require(CoachHTTPProtocol.fixture.request())
        #expect(sent.url?.path == "/v1/messages")
        #expect(sent.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(sent.value(forHTTPHeaderField: "x-api-key") == "test-key")
    }
    @Test func disconnectWithoutTerminalEventIsAnIncompleteReply() async throws {
        CoachHTTPProtocol.fixture.set("data: {\"type\":\"response.output_text.delta\",\"delta\":\"Partial\"}\n\n")
        do {
            for try await _ in transport().stream(request(.openAI), key: "test-key") {}
            Issue.record("An incomplete stream was accepted")
        } catch { #expect(error as? CoachProviderError == .incomplete) }
    }
    @Test func HTTPBillingErrorIsSanitized() async throws {
        CoachHTTPProtocol.fixture.set("{\"error\":{\"code\":\"insufficient_quota\",\"message\":\"secret-health-context\"}}", status: 429, contentType: "application/json")
        do {
            for try await _ in transport().stream(request(.openAI), key: "test-key") {}
            Issue.record("Expected billing error")
        } catch {
            #expect(error as? CoachProviderError == .quota)
            #expect(!error.localizedDescription.contains("secret-health-context"))
        }
    }
    @Test func modelListingMakesOnlyAuthenticationRequest() async throws {
        CoachHTTPProtocol.fixture.set("{\"data\":[{\"id\":\"model-b\"},{\"id\":\"model-a\"}]}", contentType: "application/json")
        #expect(try await transport().models(provider: .openAI, key: "test-key") == ["model-a", "model-b"])
        let sent = try #require(CoachHTTPProtocol.fixture.request())
        #expect(sent.url?.path == "/v1/models")
        #expect(sent.httpBody == nil)
    }
}
