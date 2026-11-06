import AIKit
import Foundation
import Testing

private final class StructuredHTTPStub: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var response: Result<(Int, Data), URLError>?
    nonisolated(unsafe) private static var captured: [URLRequest] = []
    static func configure(_ value: Result<(Int, Data), URLError>) { lock.withLock { response = value; captured = [] } }
    static var requests: [URLRequest] { lock.withLock { captured } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let result = Self.lock.withLock { Self.captured.append(request); return Self.response }
        guard let result else { client?.urlProtocol(self, didFailWithError: CoachStructuredError.unstubbedTest); return }
        switch result {
        case .failure(let error): client?.urlProtocol(self, didFailWithError: error)
        case .success(let value):
            let response = HTTPURLResponse(url: request.url!, statusCode: value.0, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: value.1)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

@Suite(.serialized) struct CoachStructuredHTTPTests {
    @Test func providerRequestsUseExplicitStubsForSuccessOfflineRateLimitAndMalformedBodies() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StructuredHTTPStub.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let transport = CoachURLSessionTransport(session: session)
        for provider in CoachProvider.allCases {
            let request = CoachStructuredRequest(configuration: .init(provider: provider, model: "chosen-model"), instructions: "Food only", text: "Food note", imageJPEG: nil, schema: Data(#"{"type":"object"}"#.utf8))
            let success = provider == .openAI
                ? #"{"status":"completed","output":[{"type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"{\"items\":[]}"}]}]}"#
                : #"{"type":"message","role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"{\"items\":[]}"}]}"#
            StructuredHTTPStub.configure(.success((200, Data(success.utf8))))
            #expect(try await transport.structured(request, key: "fixture-key") == Data(#"{"items":[]}"#.utf8))
            let sent = try #require(StructuredHTTPStub.requests.first)
            #expect(sent.url?.host == provider.host && sent.httpMethod == "POST")
            #expect(sent.value(forHTTPHeaderField: provider == .openAI ? "Authorization" : "x-api-key") == (provider == .openAI ? "Bearer fixture-key" : "fixture-key"))
            #expect(sent.value(forHTTPHeaderField: provider == .openAI ? "x-api-key" : "Authorization") == nil)
            StructuredHTTPStub.configure(.failure(URLError(.notConnectedToInternet)))
            await #expect(throws: CoachProviderError.offline) { try await transport.structured(request, key: "fixture-key") }
            StructuredHTTPStub.configure(.success((429, Data(#"{"error":{"type":"rate_limit_error"}}"#.utf8))))
            await #expect(throws: CoachProviderError.rateLimited) { try await transport.structured(request, key: "fixture-key") }
            StructuredHTTPStub.configure(.success((200, Data("broken".utf8))))
            await #expect(throws: CoachProviderError.malformedResponse) { try await transport.structured(request, key: "fixture-key") }
        }
    }
}
