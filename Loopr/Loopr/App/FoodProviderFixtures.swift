#if DEBUG
import AIKit
import FoodKit
import Foundation

@MainActor enum FoodProviderFixtures {
    static func runtime(arguments: [String] = ProcessInfo.processInfo.arguments) -> LooprAISettingsRuntime {
        let suite = "com.loopr.food.ui-fixture"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        if !arguments.contains("--loopr-food-fixture-no-provider") {
            let configuration = CoachProviderConfiguration(provider: .anthropic, model: CoachProvider.anthropic.defaultModel)
            defaults.set(try? JSONEncoder().encode([configuration]), forKey: LooprAISettingsRuntime.providersKey)
            defaults.set(CoachProvider.anthropic.rawValue, forKey: LooprAISettingsRuntime.selectedKey)
        }
        let failure = arguments.first { $0.hasPrefix("--loopr-food-fixture-fail=") }?.split(separator: "=").last.map(String.init)
        return LooprAISettingsRuntime(defaults: defaults,
            stores: [.openAI: FoodFixtureCredentials(), .anthropic: FoodFixtureCredentials()],
            transport: CoachFixtureTransport(), structuredTransport: FoodFixtureEstimateTransport(failure: failure))
    }
}

private actor FoodFixtureCredentials: AICredentialStore {
    private var data: Data? = Data("fixture-not-a-real-key".utf8)
    func read() -> Data? { data }
    func write(_ data: Data) { self.data = data }
    func remove() { data = nil }
}

/// Deliberately synthetic contract data. This is not a recorded provider response.
nonisolated private struct FoodFixtureEstimateTransport: CoachStructuredTransport {
    let failure: String?
    func structured(_ request: CoachStructuredRequest, key: String) async throws -> Data {
        switch failure {
        case "offline": throw CoachProviderError.offline
        case "rate-limit": throw CoachProviderError.rateLimited
        case "malformed": return Data("invalid fixture response".utf8)
        default: break
        }
        let brown = request.text.lowercased().contains("brown")
        var index = -1
        func item(_ name: String, _ amount: Double, _ energy: Double, _ protein: Double, _ carbs: Double, _ fat: Double, _ confidence: String) -> [String: Any] {
            index += 1
            var values: [String: Any] = Dictionary(uniqueKeysWithValues: FoodNutrient.allCases.map { ($0.rawValue, NSNull()) })
            values["energy"] = energy; values["protein"] = protein; values["carbs"] = carbs; values["fat"] = fat
            return ["replacesIndex": request.imageJPEG == nil ? index as Any : NSNull(), "name": name, "amount": amount, "unit": "grams", "confidence": confidence, "nutrients": values]
        }
        return try JSONSerialization.data(withJSONObject: ["items": [
            item("Grilled chicken breast", 150, 248, 40, 0, 8, "sure"),
            item(brown ? "Brown rice" : "White rice", 180, brown ? 222 : 234, 4, 51, 1, "check"),
            item("Avocado", 70, 112, 2, 6, 10, "sure"),
            item("Sesame dressing", 20, 118, 4, 11, 7, "guess")
        ], "uncertainty": "The dressing and portion sizes are estimated. Check them before saving."], options: [.sortedKeys])
    }
}
#endif
