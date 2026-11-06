import Foundation

public struct FoodProductHTTPResponse: Sendable {
    public let status: Int
    public let body: Data
    public let retryAfter: String?
    public init(status: Int, body: Data, retryAfter: String? = nil) {
        self.status = status; self.body = body; self.retryAfter = retryAfter
    }
}

public protocol FoodProductTransport: Sendable {
    func send(_ request: URLRequest) async throws -> FoodProductHTTPResponse
}

private final class FoodProductRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public struct FoodProductURLSessionTransport: FoodProductTransport {
    private let session: URLSession
    private let testRequiresStub: Bool
    /// Tests supply a session with an explicit URLProtocol stub or inject FoodProductTransport.
    public init(stubbedSession: URLSession? = nil) {
        testRequiresStub = stubbedSession == nil && (ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil || NSClassFromString("XCTestCase") != nil)
        if let stubbedSession { session = stubbedSession }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil; configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = 20; configuration.timeoutIntervalForResource = 30
            session = URLSession(configuration: configuration, delegate: FoodProductRedirectDelegate(), delegateQueue: nil)
        }
    }
    public func send(_ request: URLRequest) async throws -> FoodProductHTTPResponse {
        guard !testRequiresStub else { throw FoodBarcodeError.unstubbedTest }
        guard let url = request.url, url.scheme == "https", url.host == "world.openfoodfacts.org", url.port == nil,
              url.user == nil, url.password == nil, request.httpMethod == "GET", request.httpBody == nil,
              request.value(forHTTPHeaderField: "Authorization") == nil,
              request.value(forHTTPHeaderField: "x-api-key") == nil else { throw FoodBarcodeError.unsupported }
        let (bytes, rawResponse) = try await session.bytes(for: request)
        guard let response = rawResponse as? HTTPURLResponse, response.url == url else { throw FoodBarcodeError.unsupported }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 1_048_576 else { throw FoodBarcodeError.malformed }
            data.append(byte)
        }
        return .init(status: response.statusCode, body: data, retryAfter: response.value(forHTTPHeaderField: "Retry-After"))
    }
}

public struct FoodProductCacheEntry: Codable, Equatable, Sendable {
    public let barcode: String
    public let fetchedAt: Date
    /// nil is a confirmed HTTP 404, not a malformed or failed response.
    public let response: Data?
    /// The `fields=` list the response was requested with (`FoodProductClient.fieldSet`). Nil on rows cached before
    /// Loopr asked for `nova_group` and `ingredients_tags`; those still decode, and the next lookup asks again.
    public let fieldSet: Int?
    public init(barcode: String, fetchedAt: Date, response: Data?, fieldSet: Int? = FoodProductClient.fieldSet) {
        self.barcode = barcode; self.fetchedAt = fetchedAt; self.response = response; self.fieldSet = fieldSet
    }
}
public protocol FoodProductCache: Sendable {
    func cachedProduct(barcode: String) throws -> FoodProductCacheEntry?
    func productCacheGeneration() throws -> UUID
    func cacheProduct(_ entry: FoodProductCacheEntry, generation: UUID) throws
}
public extension FoodProductCache {
    func cacheProduct(_ entry: FoodProductCacheEntry) throws {
        try cacheProduct(entry, generation: productCacheGeneration())
    }
}
public struct FoodProductLookup: Equatable, Sendable {
    public let product: FoodProduct
    public let isStale: Bool
}

public actor FoodProductClient {
    private let transport: any FoodProductTransport
    private let cache: any FoodProductCache
    private let clock: @Sendable () -> Date
    private var inFlight: [String: Task<FoodProductLookup, Error>] = [:]
    private var requests: [Date] = []
    private var pausedUntil: Date?
    public init(transport: any FoodProductTransport, cache: any FoodProductCache, clock: @escaping @Sendable () -> Date = Date.init) {
        self.transport = transport; self.cache = cache; self.clock = clock
    }
    /// Version of the `fields=` list below. Version 1 was the list without `nova_group` and `ingredients_tags`.
    public static let fieldSet = 2
    /// Every field Loopr asks Open Food Facts for. `nova_group` (integer 1 to 4) and `ingredients_tags` (array of
    /// taxonomy ids) are product fields in the Open Food Facts API v3 schema (`product_base.yaml` and
    /// `product_ingredients.yaml` in github.com/openfoodfacts/openfoodfacts-server, docs/api/ref/schemas).
    public static let requestedFields = "code,product_name,brands,quantity,serving_size,nutrition,last_modified_t,schema_version,nova_group,ingredients_tags"
    public static func request(barcode: String) throws -> URLRequest {
        let code = try FoodBarcode.normalized(barcode)
        var components = URLComponents(string: "https://world.openfoodfacts.org/api/v3.6/product/\(code).json")!
        components.queryItems = [.init(name: "fields", value: requestedFields)]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Loopr/1.0 (pascallindenau@googlemail.com)", forHTTPHeaderField: "User-Agent")
        return request
    }
    public func lookup(_ input: String, refresh: Bool = false) async throws -> FoodProductLookup {
        let code = try FoodBarcode.normalized(input)
        let now = clock()
        let cached: FoodProductCacheEntry?
        let generation: UUID
        do { generation = try cache.productCacheGeneration(); cached = try cache.cachedProduct(barcode: code) } catch { throw FoodBarcodeError.storage }
        var previous: FoodProduct?
        if let cached {
            if let data = cached.response {
                previous = try? FoodProductDecoder.decode(data, barcode: code, fetchedAt: cached.fetchedAt)
                if let previous, !refresh, cached.fieldSet == Self.fieldSet, (0..<(30 * 86_400)).contains(now.timeIntervalSince(cached.fetchedAt)) {
                    return .init(product: previous, isStale: false)
                }
            } else if !refresh, (0..<3_600).contains(now.timeIntervalSince(cached.fetchedAt)) { throw FoodBarcodeError.notFound }
        }
        if let running = inFlight[code] { return try await result(running, previous: previous) }
        if let pausedUntil, pausedUntil > now {
            if let previous { return .init(product: previous, isStale: true) }
            throw FoodBarcodeError.rateLimited(pausedUntil)
        }
        requests.removeAll { now.timeIntervalSince($0) >= 60 }
        guard requests.count < 12 else {
            if let previous { return .init(product: previous, isStale: true) }
            throw FoodBarcodeError.rateLimited(requests[0].addingTimeInterval(60))
        }
        requests.append(now)
        let transport = self.transport
        let task = Task<FoodProductLookup, Error> {
            let response = try await transport.send(Self.request(barcode: code))
            try Task.checkCancellation()
            if [429, 503].contains(response.status) {
                throw FoodBarcodeError.rateLimited(Self.retryDate(response.retryAfter, now: now))
            }
            if (300..<400).contains(response.status) { throw FoodBarcodeError.unsupported }
            if response.status == 404 {
                guard let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
                      (object["result"] as? [String: Any])?["id"] as? String == "product_not_found" else { throw FoodBarcodeError.malformed }
                do { try cache.cacheProduct(.init(barcode: code, fetchedAt: now, response: nil), generation: generation) }
                catch { throw FoodBarcodeError.storage }
                throw FoodBarcodeError.notFound
            }
            guard response.status == 200 else { throw FoodBarcodeError.malformed }
            let product = try FoodProductDecoder.decode(response.body, barcode: code, fetchedAt: now)
            do { try cache.cacheProduct(.init(barcode: code, fetchedAt: now, response: response.body), generation: generation) }
            catch { throw FoodBarcodeError.storage }
            return .init(product: product, isStale: false)
        }
        inFlight[code] = task
        defer { inFlight[code] = nil }
        return try await result(task, previous: previous)
    }
    private func result(_ task: Task<FoodProductLookup, Error>, previous: FoodProduct?) async throws -> FoodProductLookup {
        do { return try await task.value }
        catch {
            if case FoodBarcodeError.rateLimited(let until) = error { pausedUntil = until }
            if error is CancellationError { throw error }
            if let previous, (error as? FoodBarcodeError) != .notFound, (error as? FoodBarcodeError) != .storage { return .init(product: previous, isStale: true) }
            if let failure = error as? FoodBarcodeError { throw failure }
            throw FoodBarcodeError.offline
        }
    }
    private static func retryDate(_ value: String?, now: Date) -> Date {
        if let value, let seconds = Double(value), seconds.isFinite, seconds >= 0 { return now.addingTimeInterval(max(1, seconds)) }
        if let value {
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
            if let date = formatter.date(from: value), date > now { return date }
        }
        return now.addingTimeInterval(60)
    }
}
