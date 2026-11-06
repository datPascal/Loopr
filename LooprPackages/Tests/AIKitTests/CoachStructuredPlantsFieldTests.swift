import AIKit
import Foundation
import Testing

/// The photo estimate's schema gained an optional `plants` list per item. AIKit passes the schema and the
/// provider's JSON through untouched; these tests pin that for the new field.
struct CoachStructuredPlantsFieldTests {
    private let schema = Data(#"{"type":"object","additionalProperties":false,"required":["items"],"properties":{"items":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["name","plants"],"properties":{"name":{"type":"string"},"plants":{"type":["array","null"],"items":{"type":"string"}}}}}}}"#.utf8)

    @Test func theSchemaWithTheNullablePlantsArrayReachesBothProvidersUnchanged() throws {
        for provider in CoachProvider.allCases {
            let request = CoachStructuredRequest(configuration: .init(provider: provider, model: "selected-model"), instructions: "Food only",
                text: "Estimate", imageJPEG: nil, schema: schema)
            let root = try #require(JSONSerialization.jsonObject(with: request.payload()) as? [String: Any])
            let format: [String: Any]?
            if provider == .openAI { format = (root["text"] as? [String: Any])?["format"] as? [String: Any] }
            else { format = (root["output_config"] as? [String: Any])?["format"] as? [String: Any] }
            let sent = try #require(format?["schema"] as? [String: Any])
            let items = try #require(((sent["properties"] as? [String: Any])?["items"] as? [String: Any])?["items"] as? [String: Any])
            let plants = try #require((items["properties"] as? [String: Any])?["plants"] as? [String: Any])
            #expect(plants["type"] as? [String] == ["array", "null"] && (items["required"] as? [String])?.contains("plants") == true)
        }
    }

    @Test func aResponseWithAndWithoutPlantsPassesThroughTheDecoderAsTheProviderWroteIt() throws {
        let withPlants = #"{"items":[{"name":"Salad","plants":["spinach","fennel"]}]}"#
        let without = #"{"items":[{"name":"Salad"}]}"#
        for (text, expectsPlants) in [(withPlants, true), (without, false)] {
            let anthropic = try JSONSerialization.data(withJSONObject: ["type": "message", "role": "assistant", "stop_reason": "end_turn",
                "content": [["type": "text", "text": text]]])
            let decoded = try CoachStructuredDecoder.decode(anthropic, provider: .anthropic)
            #expect(decoded == Data(text.utf8))
            let items = try #require((JSONSerialization.jsonObject(with: decoded) as? [String: Any])?["items"] as? [[String: Any]])
            #expect((items[0]["plants"] as? [String]) == (expectsPlants ? ["spinach", "fennel"] : nil))
        }
    }
}
