import AIKit
import FoodKit
import Foundation
import Testing
@testable import Loopr

private actor FoodProviderTestCredentials: AICredentialStore {
    private var data: Data?
    func read() -> Data? { data }
    func write(_ data: Data) { self.data = data }
    func remove() { data = nil }
}
private actor FoodProviderTestTransport: CoachStructuredTransport {
    var requests: [CoachStructuredRequest] = []
    private let suspended: Bool
    private var response: CheckedContinuation<Data, Error>?
    private var started: CheckedContinuation<Void, Never>?
    init(suspended: Bool = false) { self.suspended = suspended }
    func structured(_ request: CoachStructuredRequest, key: String) async throws -> Data {
        #expect(key == "fixture-key")
        requests.append(request)
        if !suspended { return Data(#"{"items":[],"uncertainty":"Too unclear"}"#.utf8) }
        return try await withCheckedThrowingContinuation { response = $0; started?.resume(); started = nil }
    }
    func waitUntilStarted() async { if response != nil { return }; await withCheckedContinuation { started = $0 } }
    func finish() { response?.resume(returning: Data(#"{"items":[],"uncertainty":"Late"}"#.utf8)); response = nil }
}

@MainActor struct FoodProviderRuntimeTests {
    @Test func reviewEditsPreserveSourceAndOnlyFavoriteConfirmationWrites() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let repository = AppFoodRepository(environment: .make(arguments: ["--loopr-launch-mode=empty"], environment: [:]))
        let source = FoodProvenance(source: .photoAI, recordedAt: now, provider: "anthropic", model: "fixture-model", confidence: .check)
        let rice = FoodItem(name: "White rice", amount: 180, unit: .grams, nutrients: .init([.energy: 234]), provenance: [source])
        let draft = FoodMealDraft(slot: .lunch, occurredAt: now, timeZoneIdentifier: "Australia/Perth", items: [rice])
        let model = FoodReviewModel(draft: draft, repository: repository, now: now)
        model.scale(id: rice.id, amount: 90)
        #expect(model.draft.items[0].nutrients[.energy] == 117)
        model.swapRice(id: rice.id, type: "Brown")
        #expect(model.draft.items[0].id == rice.id && model.draft.items[0].name == "Brown rice")
        #expect(model.draft.items[0].nutrients[.energy] == nil)
        #expect(model.draft.items[0].provenance.first == source)
        #expect(try await repository.favorites().isEmpty)
        await model.saveFavorite()
        #expect(model.favoriteSaved && model.favorites.count == 1)
        #expect(try await repository.overview(from: "2023-11-14", through: "2023-11-14").meals.isEmpty)
        model.remove(id: rice.id)
        #expect(model.draft.items.isEmpty && !model.favoriteSaved)
        #expect(try await repository.favorites().count == 1)
    }
    @Test func correctionSendsOnlyReviewedFoodFieldsAndNoPhoto() async throws {
        let suite = "FoodCorrectionPrivacy-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let transport = FoodProviderTestTransport(suspended: true)
        let runtime = LooprAISettingsRuntime(defaults: defaults, stores: [.openAI: FoodProviderTestCredentials()], structuredTransport: transport)
        try await runtime.configure(provider: .openAI, model: "chosen-model", apiKey: "fixture-key")
        try await runtime.grantFoodPhotoConsent(try #require(await runtime.selectedConfiguration()))
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let rice = FoodItem(name: "White rice", amount: 180, unit: .grams, nutrients: .init([.energy: 234]),
            provenance: [.init(source: .photoAI, recordedAt: now, provider: "private-source", model: "private-model", confidence: .check)])
        let draft = FoodMealDraft(slot: .lunch, occurredAt: now, timeZoneIdentifier: "Australia/Perth", items: [rice],
            photos: [try FoodCaptureFixtures.photo(at: now)], note: "Private meal note")
        let repository = AppFoodRepository(environment: .make(arguments: ["--loopr-launch-mode=empty"], environment: [:]))
        let model = FoodReviewModel(draft: draft, repository: repository, runtime: runtime, now: now)
        await model.load()
        model.correction = "The rice was brown"
        model.estimate()
        await transport.waitUntilStarted()
        let sent = try #require(await transport.requests.first)
        #expect(sent.configuration.model == "chosen-model" && sent.imageJPEG == nil)
        #expect(sent.text.contains("White rice") && sent.text.contains("The rice was brown"))
        for privateField in ["private-source", "private-model", "Private meal note", "Australia/Perth", rice.id.uuidString] {
            #expect(!sent.text.contains(privateField))
        }
        #expect(model.draft == draft)
        #expect(try await repository.overview(from: "2023-11-14", through: "2023-11-14").meals.isEmpty)
        model.stop()
        await transport.finish()
    }
    private func request(_ configuration: CoachProviderConfiguration) -> CoachStructuredRequest {
        .init(configuration: configuration, instructions: "Food only", text: "One food", imageJPEG: Data([1]), schema: Data(#"{"type":"object"}"#.utf8))
    }
    @Test func separatePhotoConsentIsRequiredPerProviderAndConfiguration() async throws {
        let suite = "FoodProviderRuntime-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let transport = FoodProviderTestTransport()
        let runtime = LooprAISettingsRuntime(defaults: defaults, stores: [.openAI: FoodProviderTestCredentials(), .anthropic: FoodProviderTestCredentials()], structuredTransport: transport)
        try await runtime.configure(provider: .openAI, model: "chosen-model", apiKey: "fixture-key")
        let openAI = try #require(await runtime.selectedConfiguration())
        await #expect(throws: CoachStructuredError.consentRequired) { try await runtime.structured(request(openAI)) }
        #expect(await transport.requests.isEmpty)
        try await runtime.grantFoodPhotoConsent(openAI)
        _ = try await runtime.structured(request(openAI))
        #expect(await transport.requests.count == 1)
        try await runtime.configure(provider: .anthropic, model: "other-model", apiKey: "fixture-key")
        let claude = try #require(await runtime.selectedConfiguration())
        await #expect(throws: CoachStructuredError.consentRequired) { try await runtime.structured(request(claude)) }
        await #expect(throws: CoachStructuredError.consentRequired) { try await runtime.structured(request(openAI)) }
        try await runtime.select(.openAI)
        #expect(try await runtime.hasFoodPhotoConsent(openAI))
        try await runtime.configure(provider: .openAI, model: "changed-model", apiKey: "")
        let changed = try #require(await runtime.selectedConfiguration())
        #expect(try await runtime.hasFoodPhotoConsent(changed) == false)
        #expect(await transport.requests.count == 1)
    }
    @Test func revocationRejectsLateResponseEvenIfTransportIgnoresCancellation() async throws {
        let suite = "FoodProviderCancellation-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let transport = FoodProviderTestTransport(suspended: true)
        let runtime = LooprAISettingsRuntime(defaults: defaults, stores: [.openAI: FoodProviderTestCredentials()], structuredTransport: transport)
        try await runtime.configure(provider: .openAI, model: "chosen-model", apiKey: "fixture-key")
        let configuration = try #require(await runtime.selectedConfiguration())
        try await runtime.grantFoodPhotoConsent(configuration)
        let task = Task { try await runtime.structured(request(configuration)) }
        await transport.waitUntilStarted()
        await runtime.revokeFoodPhotoConsent(.openAI)
        await transport.finish()
        await #expect(throws: CoachProviderError.configurationChanged) { try await task.value }
        #expect(try await runtime.hasFoodPhotoConsent(configuration) == false)
    }
    @Test func removingProviderErasesPhotoConsent() async throws {
        let suite = "FoodProviderRemoval-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let runtime = LooprAISettingsRuntime(defaults: defaults, stores: [.openAI: FoodProviderTestCredentials()], structuredTransport: FoodProviderTestTransport())
        try await runtime.configure(provider: .openAI, model: "chosen-model", apiKey: "fixture-key")
        let configuration = try #require(await runtime.selectedConfiguration())
        try await runtime.grantFoodPhotoConsent(configuration)
        try await runtime.remove(.openAI)
        #expect(defaults.string(forKey: "loopr.ai.food-photo-consent.v1.openAI") == nil)
    }
}
