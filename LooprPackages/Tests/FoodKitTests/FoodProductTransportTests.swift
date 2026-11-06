import FoodKit
import Foundation
import Testing

private final class FoodHTTPStub: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var captured: [URLRequest] = []
    static func clear() { lock.withLock { captured.removeAll() } }
    static var requests: [URLRequest] { lock.withLock { captured } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.withLock { Self.captured.append(request) }
        guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: 429, httpVersion: "HTTP/1.1", headerFields: ["Retry-After": "60"]) else {
            client?.urlProtocol(self, didFailWithError: FoodBarcodeError.unstubbedTest); return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("rate limited".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized) struct FoodProductTransportTests {
    @Test func URLSessionUsesExplicitStubAndRejectsOtherHostsAndProviderKeysBeforeSending() async throws {
        FoodHTTPStub.clear()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FoodHTTPStub.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let transport = FoodProductURLSessionTransport(stubbedSession: session)
        let request = try FoodProductClient.request(barcode: "3017620422003")
        let response = try await transport.send(request)
        #expect(response.status == 429 && response.retryAfter == "60")
        #expect(response.body == Data("rate limited".utf8))
        for url in ["http://world.openfoodfacts.org/api/v3.6/product/1234.json", "https://example.com/", "https://world.openfoodfacts.org:443/"] {
            await #expect(throws: FoodBarcodeError.unsupported) { try await transport.send(URLRequest(url: URL(string: url)!)) }
        }
        var keyed = request; keyed.setValue("fixture-secret", forHTTPHeaderField: "Authorization")
        await #expect(throws: FoodBarcodeError.unsupported) { try await transport.send(keyed) }
        #expect(FoodHTTPStub.requests.count == 1)
        #expect(FoodHTTPStub.requests[0].httpBody == nil)
        #expect(request.allHTTPHeaderFields?.keys.sorted() == ["Accept", "User-Agent"])
    }
}
