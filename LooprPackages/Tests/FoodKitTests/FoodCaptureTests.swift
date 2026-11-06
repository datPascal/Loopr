import FoodKit
import Foundation
import StorageKit
import Testing

private let captureNow = Date(timeIntervalSince1970: 1_700_000_000)
private func recordedFood(_ name: String = "success") throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name + "-response", withExtension: "json", subdirectory: "Fixtures/OpenFoodFacts"))
    return try Data(contentsOf: url)
}
private final class ProductCacheStub: FoodProductCache, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: FoodProductCacheEntry] = [:]
    func cachedProduct(barcode: String) throws -> FoodProductCacheEntry? { lock.withLock { entries[barcode] } }
    private let epoch = UUID()
    func productCacheGeneration() throws -> UUID { epoch }
    func cacheProduct(_ entry: FoodProductCacheEntry, generation: UUID) throws {
        guard generation == epoch else { throw FoodBarcodeError.storage }
        lock.withLock { entries[entry.barcode] = entry }
    }
}
private actor ProductTransportStub: FoodProductTransport {
    var responses: [Result<FoodProductHTTPResponse, Error>]
    var requests: [URLRequest] = []
    init(_ responses: [Result<FoodProductHTTPResponse, Error>]) { self.responses = responses }
    func send(_ request: URLRequest) async throws -> FoodProductHTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw FoodBarcodeError.unstubbedTest }
        return try responses.removeFirst().get()
    }
}

struct FoodBarcodeTests {
    @Test func numericNormalizationFollowsOFFWithoutInventingAChecksumGate() throws {
        for (raw, expected) in [("1234", "00001234"), ("123456789", "0000123456789"), ("034000470693", "0034000470693"),
                                 ("03017620422003", "3017620422003"), ("12345678901234", "12345678901234")] {
            #expect(try FoodBarcode.normalized(raw) == expected)
        }
        for raw in ["", "00000000", "00123", "https://example.com/1234", "１２３４", "12/34", String(repeating: "1", count: 41)] {
            #expect(throws: FoodBarcodeError.invalidCode) { try FoodBarcode.normalized(raw) }
        }
    }
    @Test func upceVectorsFromZXingAndZintPreserveSystemAndCheckDigit() throws {
        let vectors = [("03456703", "034000005673"), ("09847531", "098400000751"), ("04567840", "045670000080"),
            ("01234558", "012345000058"), ("01234565", "012345000065"), ("12345670", "123456000070"),
            ("01234514", "012100003454"), ("01234523", "012200003453")]
        for (raw, expanded) in vectors { #expect(try FoodBarcode.expandedUPCE(raw) == expanded) }
        for raw in ["0123456", "123456", "01234564", "22345670", "abcdefgh"] {
            #expect(throws: FoodBarcodeError.invalidCode) { try FoodBarcode.expandedUPCE(raw) }
        }
        #expect(try FoodBarcode.normalized("01234565") == "01234565") // EAN-8 remains unexpanded.
    }
    @Test func recordedProductKeepsBasisUnknownsDeclaredValuesAndLicence() throws {
        let data = try recordedFood()
        let product = try FoodProductDecoder.decode(data, barcode: "3017620422003", fetchedAt: captureNow)
        #expect(product.basis == .grams && product.basisAmount == 100)
        #expect(product.nutrients[.energy] == 539 && product.nutrients[.fibre] == 0)
        #expect(product.nutrients[.caffeine] == nil && product.nutrients[.alcoholUnits] == nil)
        #expect(product.source.rawResponse == data && product.source.databaseLicenseURL == FoodProductSource.databaseLicense)
        let item = try product.item(amount: 15, at: captureNow)
        #expect(abs((item.nutrients[.energy] ?? 0) - 80.85) < 0.001)
        let encoded = try JSONEncoder().encode(item)
        #expect(try JSONDecoder().decode(FoodItem.self, from: encoded) == item)
        #expect(String(decoding: encoded, as: UTF8.self).contains("Open Food Facts contributors"))
    }
    @Test func decoderKeepsMillilitresAndRejectsInvalidOrAmbiguousValues() throws {
        var root = try #require(JSONSerialization.jsonObject(with: recordedFood()) as? [String: Any])
        var product = try #require(root["product"] as? [String: Any])
        var nutrition = try #require(product["nutrition"] as? [String: Any])
        var aggregate = try #require(nutrition["aggregated_set"] as? [String: Any])
        aggregate["per"] = "100ml"
        aggregate["nutrients"] = ["energy-kcal": ["value": "24", "unit": "kcal"], "caffeine": ["value": 0.08, "unit": "g"],
            "salt": ["value": 100, "unit": "mg"], "fat": ["value": 2, "unit": "g", "modifier": "<"]]
        nutrition["aggregated_set"] = aggregate; product["nutrition"] = nutrition; root["product"] = product
        let decoded = try FoodProductDecoder.decode(JSONSerialization.data(withJSONObject: root), barcode: "3017620422003", fetchedAt: captureNow)
        #expect(decoded.basis == .millilitres && decoded.nutrients[.caffeine] == 80 && decoded.nutrients[.salt] == 0.1)
        #expect(decoded.nutrients[.fat] == nil && !decoded.warnings.isEmpty)
        aggregate["nutrients"] = ["fat": ["value": true, "unit": "g"]]
        nutrition["aggregated_set"] = aggregate; product["nutrition"] = nutrition; root["product"] = product
        #expect(throws: FoodBarcodeError.malformed) { try FoodProductDecoder.decode(JSONSerialization.data(withJSONObject: root), barcode: "3017620422003", fetchedAt: captureNow) }
        #expect(throws: FoodBarcodeError.malformed) { try FoodProductDecoder.decode(Data("<html>error</html>".utf8), barcode: "3017620422003", fetchedAt: captureNow) }
        #expect(throws: FoodBarcodeError.malformed) { try FoodProductDecoder.decode(recordedFood(), barcode: "12345678", fetchedAt: captureNow) }
    }
    @Test func freshAndStaleCacheWorkWithoutRequestsOrKeys() async throws {
        let cache = ProductCacheStub()
        try cache.cacheProduct(.init(barcode: "3017620422003", fetchedAt: captureNow, response: recordedFood()))
        let transport = ProductTransportStub([.failure(URLError(.notConnectedToInternet))])
        let fresh = FoodProductClient(transport: transport, cache: cache, clock: { captureNow })
        #expect(try await fresh.lookup("3017620422003").isStale == false)
        #expect(await transport.requests.isEmpty)
        let stale = FoodProductClient(transport: transport, cache: cache, clock: { captureNow.addingTimeInterval(31 * 86_400) })
        #expect(try await stale.lookup("3017620422003").isStale)
        #expect(await transport.requests.count == 1)
        let miss = FoodProductClient(transport: ProductTransportStub([.failure(URLError(.timedOut))]), cache: ProductCacheStub())
        await #expect(throws: FoodBarcodeError.offline) { try await miss.lookup("12345678") }
    }
    @Test func recordedLookupAndNegativeCacheUseOnlyExplicitTransport() async throws {
        let transport = ProductTransportStub([.success(.init(status: 200, body: try recordedFood())), .success(.init(status: 404, body: try recordedFood("not-found")))])
        let client = FoodProductClient(transport: transport, cache: ProductCacheStub(), clock: { captureNow })
        _ = try await client.lookup("03017620422003")
        _ = try await client.lookup("3017620422003")
        for _ in 0..<2 { await #expect(throws: FoodBarcodeError.notFound) { try await client.lookup("9900000123451") } }
        let requests = await transport.requests
        #expect(requests.count == 2)
        #expect(requests[0].url?.host == "world.openfoodfacts.org" && requests[0].httpBody == nil)
        #expect(requests[0].value(forHTTPHeaderField: "Authorization") == nil && requests[0].value(forHTTPHeaderField: "x-api-key") == nil)
        #expect(requests[0].value(forHTTPHeaderField: "User-Agent")?.hasPrefix("Loopr/") == true)
    }
    @Test func rateLimitMalformedAndRedirectsDoNotBecomeProducts() async throws {
        for status in [429, 503] {
            let transport = ProductTransportStub([.success(.init(status: status, body: Data(), retryAfter: "120"))])
            let cache = ProductCacheStub()
            let client = FoodProductClient(transport: transport, cache: cache, clock: { captureNow })
            for _ in 0..<2 {
                await #expect(throws: FoodBarcodeError.rateLimited(captureNow.addingTimeInterval(120))) { try await client.lookup("3017620422003") }
            }
            #expect(await transport.requests.count == 1)
            #expect(try cache.cachedProduct(barcode: "3017620422003") == nil)
        }
        for status in [200, 404, 302] {
            let client = FoodProductClient(transport: ProductTransportStub([.success(.init(status: status, body: Data("bad".utf8)))]), cache: ProductCacheStub())
            await #expect(throws: status == 302 ? FoodBarcodeError.unsupported : .malformed) { try await client.lookup("12345678") }
        }
    }
    @Test func persistentPublicCacheSurvivesReopenAndIsDeletedWithFood() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FoodCacheTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try StorageDatabase(url: root.appendingPathComponent("food.sqlite"), applicationVersion: "test")
        let store = FoodStore(database: database)
        try store.cacheProduct(.init(barcode: "3017620422003", fetchedAt: captureNow, response: recordedFood()))
        let reopened = try StorageDatabase(url: root.appendingPathComponent("food.sqlite"), applicationVersion: "test")
        #expect(try FoodStore(database: reopened).cachedProduct(barcode: "3017620422003")?.response == recordedFood())
        #expect(try store.meals().isEmpty)
        let tokenBeforeDeletion = try store.productCacheGeneration()
        try store.deleteAll()
        #expect(throws: FoodBarcodeError.storage) {
            try store.cacheProduct(.init(barcode: "3017620422003", fetchedAt: captureNow, response: recordedFood()), generation: tokenBeforeDeletion)
        }
        #expect(try store.cachedProduct(barcode: "3017620422003") == nil)
    }
}

struct FoodLocalCaptureTests {
    @Test func localTextAndVoiceKeepUnknownNutritionAndAmountsForReview() throws {
        for source in [FoodCaptureSource.typed, .voice] {
            let items = try FoodTextCapture.items("150 g chicken\n180 g rice", source: source, at: captureNow)
            #expect(items.map(\.amount) == [150, 180] && items.allSatisfy { $0.unit == .grams })
            #expect(items.allSatisfy { $0.nutrients.values.isEmpty && $0.provenance.first?.source == source })
        }
        #expect(throws: FoodError.invalidRecord) { try FoodTextCapture.items("0 g rice", source: .typed, at: captureNow) }
    }
    /// "2 eggs" was one serving named "2 eggs" (ICP R2-UPG-20). A bare leading number is how many pieces.
    @Test func aBareLeadingNumberIsTheAmountInPieces() throws {
        let items = try FoodTextCapture.items("2 eggs\n3x crackers\n1,5 bananas\n200 ml milk\n7up\nTwo slices of toast", source: .typed, at: captureNow)
        #expect(items.map(\.name) == ["eggs", "crackers", "bananas", "milk", "7up", "toast"])
        #expect(items.map(\.amount) == [2, 3, 1.5, 200, 1, 2])
        #expect(items.map(\.unit) == [.piece, .piece, .piece, .millilitres, .serving, .piece])
        #expect(throws: FoodError.invalidRecord) { try FoodTextCapture.items("0 eggs", source: .typed, at: captureNow) }
    }
    /// ICP R3-NEW-5: a first meal typed in words kept "two" and "one slice of" in the names, at 1 serving each.
    @Test func amountWordsAndMeasuresBecomeTheAmount() throws {
        let items = try FoodTextCapture.items("two scrambled eggs\none slice of sourdough toast\nblack coffee\nA banana\nhalf avocado\n2 cups of tea\nOne-pot pasta",
                                              source: .typed, at: captureNow)
        #expect(items.map(\.name) == ["scrambled eggs", "sourdough toast", "black coffee", "banana", "avocado", "tea", "One-pot pasta"])
        #expect(items.map(\.amount) == [2, 1, 1, 1, 0.5, 2, 1])
        #expect(items.map(\.unit) == [.piece, .piece, .serving, .piece, .piece, .serving, .serving])
    }
    /// Manual quick add: "600 kcal, 30 g protein" saves on its own, with or without a name.
    @Test func quickAddSavesTotalsAloneAndKeepsBlanksUnknown() throws {
        let item = try FoodTextCapture.quickItem(name: "  ", nutrients: .init([.energy: 600, .protein: 30]), at: captureNow)
        #expect(item.name == FoodTextCapture.quickAddName && item.amount == 1 && item.unit == .serving)
        #expect(item.nutrients[.energy] == 600 && item.nutrients[.protein] == 30 && item.nutrients[.carbs] == nil && item.nutrients[.fat] == nil)
        #expect(item.provenance.first?.source == .typed)
        #expect(try FoodTextCapture.quickItem(name: " Burrito ", nutrients: .init([.fat: 0]), at: captureNow).name == "Burrito")
        #expect(throws: FoodError.invalidRecord) { try FoodTextCapture.quickItem(name: "Burrito", nutrients: .init(), at: captureNow) }
        #expect(throws: FoodError.invalidRecord) { try FoodTextCapture.quickItem(name: "", nutrients: .init([.energy: -1]), at: captureNow) }
    }
    @Test func labelParserSeparatesKJAndKcalAndKeepsUnclearColumnsUnknown() throws {
        let result = FoodLabelParser.parse("Nutrition per 100 g\nEnergy 840 kJ 200 kcal\nProtein 12,5 g\nFat 4 g\nSalt 0 g")
        #expect(result.basis == .grams && result.nutrients[.energy] == 200 && result.nutrients[.protein] == 12.5)
        #expect(result.nutrients[.salt] == 0 && result.nutrients[.carbs] == nil)
        let item = try result.item(name: "Beans", at: captureNow)
        #expect(item.provenance[0].labelText == result.text)
        let conflicting = FoodLabelParser.parse("Per 100 g Per serving\nFat 4 g 2 g")
        #expect(conflicting.basis == nil && conflicting.nutrients.values.isEmpty)
        #expect(FoodLabelParser.parse("Per 100ml\nFat <1 g").nutrients[.fat] == nil)
        #expect(FoodLabelParser.parse("Per 100g\nFat 1 g\nFat 2 g").nutrients[.fat] == nil)
        #expect(FoodLabelParser.parse("").basis == nil)
    }
    @Test func importedTimeHonoursAssetEditsOffsetsAndMissingMetadata() throws {
        let zone = try #require(TimeZone(identifier: "Australia/Perth"))
        let asset = FoodPhotoImport.time(assetDate: captureNow, local: "2020:01:01 00:00:00", offset: "+08:00", assumedZone: zone, now: .distantPast)
        #expect(asset.0 == captureNow && asset.1.source == .libraryAsset)
        let exif = FoodPhotoImport.time(assetDate: nil, local: "2026:01:02 00:30:00", offset: "+08:00", fraction: "125", assumedZone: .gmt, now: .distantPast)
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        #expect(exif.0 == iso.date(from: "2026-01-01T16:30:00.125Z") && exif.1.source == .exif)
        let assumed = FoodPhotoImport.time(assetDate: nil, local: "2026:01:02 00:30:00", offset: nil, assumedZone: zone, now: .distantPast)
        #expect(assumed.1.needsReview && assumed.1.assumedTimeZone == zone.identifier)
        let missing = FoodPhotoImport.time(assetDate: nil, local: nil, offset: nil, assumedZone: zone, now: captureNow)
        #expect(missing.0 == captureNow && missing.1.source == .user && missing.1.needsReview)
        let gap = FoodPhotoImport.time(assetDate: nil, local: "2026:03:08 02:30:00", offset: nil,
            assumedZone: try #require(TimeZone(identifier: "America/New_York")), now: captureNow)
        #expect(gap.1.source == .user)
    }
}
