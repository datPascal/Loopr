import FoodKit
import Foundation
import StorageKit
import Testing

private let now = Date(timeIntervalSince1970: 1_700_000_000)
private let barcode = "3017620422003"

private func recorded() throws -> Data {
    let url = try #require(Bundle.module.url(forResource: "success-response", withExtension: "json", subdirectory: "Fixtures/OpenFoodFacts"))
    return try Data(contentsOf: url)
}

/// The recorded response with product fields added or removed, as Open Food Facts would send them.
private func response(_ change: (inout [String: Any]) -> Void) throws -> Data {
    var root = try #require(JSONSerialization.jsonObject(with: recorded()) as? [String: Any])
    var product = try #require(root["product"] as? [String: Any])
    change(&product)
    root["product"] = product
    return try JSONSerialization.data(withJSONObject: root)
}

private final class CacheStub: FoodProductCache, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: FoodProductCacheEntry] = [:]
    private let epoch = UUID()
    init(_ entry: FoodProductCacheEntry? = nil) { if let entry { entries[entry.barcode] = entry } }
    var stored: FoodProductCacheEntry? { lock.withLock { entries[barcode] } }
    func cachedProduct(barcode: String) throws -> FoodProductCacheEntry? { lock.withLock { entries[barcode] } }
    func productCacheGeneration() throws -> UUID { epoch }
    func cacheProduct(_ entry: FoodProductCacheEntry, generation: UUID) throws { lock.withLock { entries[entry.barcode] = entry } }
}

private actor TransportStub: FoodProductTransport {
    var responses: [Result<FoodProductHTTPResponse, Error>]
    var requests: [URLRequest] = []
    init(_ responses: [Result<FoodProductHTTPResponse, Error>]) { self.responses = responses }
    func send(_ request: URLRequest) async throws -> FoodProductHTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw FoodBarcodeError.unstubbedTest }
        return try responses.removeFirst().get()
    }
}

struct FoodProductLongevityTests {
    @Test func theRequestAsksForNovaGroupAndIngredientsAndKeepsItsOtherFields() throws {
        let request = try FoodProductClient.request(barcode: barcode)
        let url = try #require(request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.host == "world.openfoodfacts.org" && components.path == "/api/v3.6/product/\(barcode).json")
        let fieldValue = try #require(components.queryItems?.first { $0.name == "fields" }?.value)
        let fields = fieldValue.split(separator: ",").map(String.init)
        #expect(fields == FoodProductClient.requestedFields.split(separator: ",").map(String.init))
        for field in ["code", "product_name", "brands", "quantity", "serving_size", "nutrition", "last_modified_t", "schema_version", "nova_group", "ingredients_tags"] {
            #expect(fields.contains(field), "\(field)")
        }
        #expect(Set(fields).count == fields.count && components.queryItems?.count == 1)
        // Still one GET with the same two headers and no body or key: no new destination, nothing more sent.
        #expect(request.httpMethod == "GET" && request.httpBody == nil && request.allHTTPHeaderFields?.keys.sorted() == ["Accept", "User-Agent"])
    }

    @Test func decodingReadsNovaGroupAndIngredientsAndCarriesThemOntoTheSavedItem() throws {
        let body = try response { $0["nova_group"] = 4; $0["ingredients_tags"] = ["en:sugar", "EN:Palm-Oil", " en:hazelnut "] }
        let product = try FoodProductDecoder.decode(body, barcode: barcode, fetchedAt: now)
        #expect(product.novaGroup == 4 && product.ingredientTags == ["en:sugar", "en:palm-oil", "en:hazelnut"])
        let item = try product.item(amount: 30, at: now)
        #expect(item.novaGroup == 4 && item.ingredientTags == product.ingredientTags)
        try item.validate()
        // The raw response stays in the item's provenance unchanged.
        #expect(item.provenance[0].product?.rawResponse == body)
        let list = try Longevity.list()
        #expect(item.plants(in: list).map(\.key) == ["hazelnut"])
    }

    @Test func responsesWithoutTheFieldsStillDecodeAsUnknownNotZero() throws {
        let product = try FoodProductDecoder.decode(recorded(), barcode: barcode, fetchedAt: now)
        #expect(product.novaGroup == nil && product.ingredientTags == nil)
        let item = try product.item(amount: 15, at: now)
        #expect(item.novaGroup == nil && item.ingredientTags == nil)
        // A product that has ingredients but no group, and one with an empty list.
        let noGroup = try FoodProductDecoder.decode(response { $0["ingredients_tags"] = [String]() }, barcode: barcode, fetchedAt: now)
        #expect(noGroup.novaGroup == nil && noGroup.ingredientTags == [])
    }

    @Test func novaGroupOutsideOneToFourOrOfTheWrongTypeIsNotAClassification() throws {
        func nova(_ value: Any) throws -> Int? {
            try FoodProductDecoder.decode(response { $0["nova_group"] = value }, barcode: barcode, fetchedAt: now).novaGroup
        }
        #expect(try nova(1) == 1 && nova(2) == 2 && nova(3) == 3 && nova(4) == 4 && nova("3") == 3)
        for value: Any in [0, 5, -1, 2.5, "x", "", true, NSNull(), [4], ["a": 4]] { #expect(try nova(value) == nil, "\(value)") }
    }

    @Test func ingredientTagsThatAreNotAStringArrayCountAsAbsentAndOddEntriesAreDropped() throws {
        func tags(_ value: Any) throws -> [String]? {
            try FoodProductDecoder.decode(response { $0["ingredients_tags"] = value }, barcode: barcode, fetchedAt: now).ingredientTags
        }
        #expect(try tags("en:sugar") == nil && tags(NSNull()) == nil && tags(["a": 1]) == nil)
        #expect(try tags(["en:sugar", 5, "", "  ", NSNull(), "en:salt"]) == ["en:sugar", "en:salt"])
        #expect(try tags(Array(repeating: "en:salt", count: 600))?.count == 500)
        #expect(try tags([String(repeating: "x", count: 121), "en:salt"]) == ["en:salt"])
    }

    @Test func oldCachedRowsStillDecodeAndAreRefreshedWhileOnline() async throws {
        // A row written before Loopr asked for the new fields has no fieldSet key.
        let current = FoodProductCacheEntry(barcode: barcode, fetchedAt: now, response: try recorded())
        #expect(current.fieldSet == FoodProductClient.fieldSet)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as? [String: Any])
        #expect(object["fieldSet"] as? Int == FoodProductClient.fieldSet)
        object["fieldSet"] = nil
        let old = try JSONDecoder().decode(FoodProductCacheEntry.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old.fieldSet == nil && old.response == current.response && old.barcode == barcode)

        let fresh = try response { $0["nova_group"] = 4; $0["ingredients_tags"] = ["en:hazelnut"] }
        let cache = CacheStub(old)
        let transport = TransportStub([.success(.init(status: 200, body: fresh))])
        let client = FoodProductClient(transport: transport, cache: cache, clock: { now })
        let lookup = try await client.lookup(barcode)
        #expect(lookup.product.novaGroup == 4 && !lookup.isStale)
        #expect(await transport.requests.count == 1)
        #expect(cache.stored?.fieldSet == FoodProductClient.fieldSet && cache.stored?.response == fresh)
        // The refreshed row is current, so the next lookup is served from the cache.
        _ = try await client.lookup(barcode)
        #expect(await transport.requests.count == 1)
    }

    @Test func anOldCachedRowStillServesOfflineAsStaleWithoutTheNewFields() async throws {
        let old = FoodProductCacheEntry(barcode: barcode, fetchedAt: now, response: try recorded(), fieldSet: nil)
        let client = FoodProductClient(transport: TransportStub([.failure(URLError(.notConnectedToInternet))]), cache: CacheStub(old), clock: { now })
        let lookup = try await client.lookup(barcode)
        #expect(lookup.isStale && lookup.product.novaGroup == nil && lookup.product.ingredientTags == nil)
        #expect(lookup.product.name == "Nutella")
    }

    @Test func aStoredRowKeepsItsFieldSetAndAnOldPayloadInTheDatabaseDecodes() throws {
        let context = try LongevityStore()
        let store = context.store
        let body = try response { $0["nova_group"] = 4 }
        try store.cacheProduct(.init(barcode: barcode, fetchedAt: now, response: body))
        #expect(try store.cachedProduct(barcode: barcode)?.fieldSet == FoodProductClient.fieldSet)
        let oldPayload = try JSONSerialization.data(withJSONObject: ["barcode": barcode, "fetchedAt": now.timeIntervalSinceReferenceDate, "response": try recorded().base64EncodedString()])
        try context.database.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO food_product_cache VALUES (?, ?, ?)", arguments: [barcode, now.timeIntervalSince1970, oldPayload])
        }
        let stored = try store.cachedProduct(barcode: barcode)
        let row = try #require(stored)
        let original = try recorded()
        #expect(row.fieldSet == nil && row.response == original)
        let product = try FoodProductDecoder.decode(#require(row.response), barcode: barcode, fetchedAt: row.fetchedAt)
        #expect(product.novaGroup == nil)
    }

    @Test func aScannedItemKeepsItsClassificationThroughSavingAndRepeating() throws {
        let context = try LongevityStore()
        let body = try response { $0["nova_group"] = 4; $0["ingredients_tags"] = ["en:hazelnut", "en:sugar"] }
        let item = try FoodProductDecoder.decode(body, barcode: barcode, fetchedAt: now).item(amount: 30, at: now)
        let saved = try context.meal(at: now, zone: Longevity.berlin, items: [item])
        let loaded = try context.store.meal(id: saved.id)
        let reloaded = try #require(loaded)
        #expect(reloaded.items[0].novaGroup == 4 && reloaded.items[0].ingredientTags == ["en:hazelnut", "en:sugar"])
        #expect(reloaded == saved)
        let repeated = reloaded.items[0].duplicated(addingEditAt: now)
        #expect(repeated.novaGroup == 4 && repeated.id != item.id)
        // A meal saved before these fields existed decodes: its items have no keys for them.
        let older = Longevity.typedItem()
        let meal = try context.meal(at: now.addingTimeInterval(60), zone: Longevity.berlin, items: [older])
        #expect(try context.store.meal(id: meal.id)?.items[0].novaGroup == nil)
    }
}
