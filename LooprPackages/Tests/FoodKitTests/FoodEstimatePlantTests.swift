import FoodKit
import Foundation
import Testing

struct FoodEstimatePlantTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    /// One item as a provider returns it. `plants` nil leaves the key out, like a response from before the field existed.
    private func body(plants: Any? = nil, includePlants: Bool = true, name: String = "Salad", replaces: Any = NSNull()) throws -> Data {
        var nutrients: [String: Any] = Dictionary(uniqueKeysWithValues: FoodNutrient.allCases.map { ($0.rawValue, NSNull()) })
        nutrients["energy"] = 180.0
        var item: [String: Any] = ["replacesIndex": replaces, "name": name, "amount": 250.0, "unit": "grams", "confidence": "check", "nutrients": nutrients]
        if includePlants { item["plants"] = plants ?? NSNull() }
        return try JSONSerialization.data(withJSONObject: ["items": [item], "uncertainty": "Dressing is a guess."])
    }
    private func decode(_ data: Data, previous: [FoodItem] = []) throws -> FoodEstimate {
        try FoodEstimate.decode(data, provider: "openai", model: "recorded-model", at: now, previousItems: previous)
    }

    @Test func responsesWithPlantsKeepThemOnTheItemAsTheProviderNamedThem() throws {
        let estimate = try decode(body(plants: ["spinach", "  chickpea ", "Spinach", "", "   ", "shiitake mushroom"]))
        #expect(estimate.items[0].estimatedPlants == ["spinach", "chickpea", "shiitake mushroom"])
        let list = try Longevity.list()
        #expect(estimate.items[0].plants(in: list).map(\.key) == ["chickpea", "shiitake", "spinach"])
        #expect(estimate.items[0].plants(in: list).allSatisfy { $0.source == .photoEstimate })
        // Estimates still start as proposals with provider provenance.
        #expect(estimate.items[0].isEstimated && estimate.items[0].provenance[0].provider == "openai")
    }

    @Test func olderResponsesWithoutPlantsDecodeAndLeaveThemUnknown() throws {
        let older = try decode(body(includePlants: false))
        #expect(older.items.count == 1 && older.items[0].estimatedPlants == nil && older.items[0].nutrients[.energy] == 180)
        #expect(older.items[0].plants(in: try Longevity.list()).isEmpty)
        // Null means the provider could not tell, which is not the same as an empty list.
        #expect(try decode(body(plants: nil)).items[0].estimatedPlants == nil)
        #expect(try decode(body(plants: [String]())).items[0].estimatedPlants == [])
    }

    @Test func malformedPlantsAreRejectedAndOversizedListsAreTrimmed() throws {
        for value: Any in ["spinach", 5, ["spinach", 5], [["name": "spinach"]], true, ["a": "b"]] {
            #expect(throws: FoodError.invalidRecord, "\(value)") { try decode(body(plants: value)) }
        }
        let many = (0..<60).map { "plant \($0)" }
        #expect(try decode(body(plants: many)).items[0].estimatedPlants?.count == 40)
        let long = String(repeating: "x", count: 101)
        #expect(try decode(body(plants: [long, "kale"])).items[0].estimatedPlants == ["kale"])
        // Other unknown keys on an item are still refused.
        var root = try #require(JSONSerialization.jsonObject(with: body(plants: ["kale"])) as? [String: Any])
        var items = try #require(root["items"] as? [[String: Any]])
        items[0]["extra"] = 1; root["items"] = items
        #expect(throws: FoodError.invalidRecord) { try decode(JSONSerialization.data(withJSONObject: root)) }
    }

    @Test func aCorrectionKeepsThePreviousPlantsAndEditsUnlessTheNewResponseNamesPlants() throws {
        let list = try Longevity.list()
        let first = try decode(body(plants: ["spinach", "fennel"])).items.first
        var original = try #require(first)
        try original.removePlant(key: "fennel", at: now)
        let silent = try decode(body(includePlants: false, name: "Big salad", replaces: 0), previous: [original]).items[0]
        #expect(silent.id == original.id && silent.estimatedPlants == ["spinach", "fennel"] && silent.plantEdits == original.plantEdits)
        #expect(silent.plants(in: list).map(\.key) == ["spinach"])
        let renamed = try decode(body(plants: ["kale"], name: "Big salad", replaces: 0), previous: [original]).items[0]
        #expect(renamed.estimatedPlants == ["kale"] && renamed.plants(in: list).map(\.key) == ["kale"])
        #expect(renamed.provenance.count == original.provenance.count + 1)
    }

    @Test func theProviderSchemaAsksForANullableArrayOfNamesWithoutUnsupportedBounds() throws {
        let root = try #require(JSONSerialization.jsonObject(with: FoodEstimate.schema) as? [String: Any])
        let item = try #require(((root["properties"] as? [String: Any])?["items"] as? [String: Any])?["items"] as? [String: Any])
        let properties = try #require(item["properties"] as? [String: Any])
        let plants = try #require(properties["plants"] as? [String: Any])
        #expect(plants["type"] as? [String] == ["array", "null"] && (plants["items"] as? [String: Any])?["type"] as? String == "string")
        #expect(item["required"] as? [String] == ["replacesIndex", "name", "amount", "unit", "confidence", "nutrients", "plants"])
        #expect(item["additionalProperties"] as? Bool == false)
        let encoded = String(decoding: try FoodEstimate.schema, as: UTF8.self)
        #expect(!encoded.contains("maximum") && !encoded.contains("maxItems") && !encoded.contains("minItems"))
        #expect(FoodEstimate.instructions.contains("plants") && FoodEstimate.instructions.contains("refined"))
    }
}
