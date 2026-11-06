import FoodKit
import Foundation
import Testing

struct FoodEstimateTests {
    private func response(amount: Any = 150.0, energy: Any = 248.0) throws -> Data {
        var nutrients: [String: Any] = Dictionary(uniqueKeysWithValues: FoodNutrient.allCases.map { ($0.rawValue, NSNull()) })
        nutrients["energy"] = energy
        return try JSONSerialization.data(withJSONObject: ["items": [["replacesIndex": NSNull(), "name": "Chicken", "amount": amount, "unit": "grams",
            "confidence": "check", "nutrients": nutrients]], "uncertainty": "Portion size is estimated."])
    }
    @Test func estimatesPreserveUnknownsAndProviderProvenanceUntilConfirmation() throws {
        let value = try FoodEstimate.decode(response(), provider: "openai", model: "selected-model", at: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(value.items.count == 1 && value.items[0].isEstimated)
        #expect(value.items[0].nutrients[.energy] == 248 && value.items[0].nutrients[.protein] == nil)
        #expect(value.items[0].provenance[0].model == "selected-model" && value.items[0].confidence == .check)
        var item = value.items[0]
        try item.changeAmount(to: 75, at: Date(timeIntervalSince1970: 1_700_000_001))
        #expect(item.nutrients[.energy] == 124 && item.nutrients[.protein] == nil)
        #expect(item.provenance.count == 2 && item.provenance.first == value.items[0].provenance.first)
    }
    @Test func schemaRejectsMissingUnknownExtraAndInvalidFields() throws {
        for data in [try response(amount: true), try response(amount: 0), try response(amount: -1),
            try response(amount: 100_001), try response(energy: true), try response(energy: -1), try response(energy: "248")] {
            #expect(throws: FoodError.invalidRecord) { try FoodEstimate.decode(data, provider: "openai", model: "selected", at: Date()) }
        }
        var root = try #require(JSONSerialization.jsonObject(with: response()) as? [String: Any])
        root["save"] = true
        #expect(throws: FoodError.invalidRecord) { try FoodEstimate.decode(JSONSerialization.data(withJSONObject: root), provider: "openai", model: "selected", at: Date()) }
        root["save"] = nil
        var items = try #require(root["items"] as? [[String: Any]])
        items[0]["nutrients"] = ["energy": 248]; root["items"] = items
        #expect(throws: FoodError.invalidRecord) { try FoodEstimate.decode(JSONSerialization.data(withJSONObject: root), provider: "openai", model: "selected", at: Date()) }
    }
    @Test func correctionRetainsOriginalSourceAndRejectsUnknownOrDuplicateReferences() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let old = try FoodEstimate.decode(response(), provider: "anthropic", model: "first-model", at: now).items[0]
        var root = try #require(JSONSerialization.jsonObject(with: response()) as? [String: Any])
        var objects = try #require(root["items"] as? [[String: Any]])
        objects[0]["name"] = "Roast chicken"; objects[0]["replacesIndex"] = 0; root["items"] = objects
        let corrected = try FoodEstimate.decode(JSONSerialization.data(withJSONObject: root), provider: "openai", model: "second-model",
            at: now.addingTimeInterval(1), previousItems: [old]).items[0]
        #expect(corrected.id == old.id && corrected.name == "Roast chicken")
        #expect(corrected.provenance.first == old.provenance.first && corrected.provenance.last?.model == "second-model")
        root["items"] = objects + objects
        #expect(throws: FoodError.invalidRecord) {
            try FoodEstimate.decode(JSONSerialization.data(withJSONObject: root), provider: "openai", model: "second", at: now, previousItems: [old])
        }
        for reference in [1.0, -1, 0.5] {
            objects[0]["replacesIndex"] = reference; root["items"] = objects
            #expect(throws: FoodError.invalidRecord) {
                try FoodEstimate.decode(JSONSerialization.data(withJSONObject: root), provider: "openai", model: "second", at: now, previousItems: [old])
            }
        }
    }
    @Test func providerSchemaRequiresEveryNullableNutrientWithoutUnsupportedBounds() throws {
        let root = try #require(JSONSerialization.jsonObject(with: FoodEstimate.schema) as? [String: Any])
        #expect(root["additionalProperties"] as? Bool == false)
        let encoded = String(decoding: try FoodEstimate.schema, as: UTF8.self)
        #expect(!encoded.contains("maximum") && !encoded.contains("maxItems"))
        for nutrient in FoodNutrient.allCases { #expect(encoded.contains(nutrient.rawValue)) }
    }
}
