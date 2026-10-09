import AIKit
import Foundation
import SettingsKit
import Testing

@testable import Loopr

private actor AppMemoryAICredentials: AICredentialStore {
    private var value: Data?
    func write(_ value: Data) { self.value = value }
    func read() -> Data? { value }
    func remove() { value = nil }
}

struct AIProviderSettingsTests {
    @Test
    func configurationStoresOnlyPublicFieldsInDefaultsAndRemovalReturnsNetworkOffState() async throws {
        let suite = "LooprAISettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = AppMemoryAICredentials()
        let runtime = LooprAISettingsRuntime(defaults: defaults, credentials: credentials)
        let secret = "sk-fixture-keychain-only"

        #expect(await runtime.state() == .permissionRequired)
        try await runtime.configure(endpoint: "https://provider.example/v1", model: "fixture", apiKey: secret)
        #expect(await runtime.state() == .available)
        #expect(await runtime.publicConfiguration()?.model == "fixture")
        #expect(await credentials.read() == Data(secret.utf8))
        let defaultsText = defaults.dictionaryRepresentation().description
        #expect(!defaultsText.contains(secret))

        try await runtime.removeProvider()
        #expect(await runtime.state() == .permissionRequired)
        #expect(await credentials.read() == nil)
    }
}
