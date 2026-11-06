import AIKit
import Foundation
import SettingsKit

actor LooprAISettingsRuntime: AIPrivacySettingsEntryPoint {
    static let shared = LooprAISettingsRuntime()
    static let endpointKey = "loopr.ai.provider.endpoint.v1"
    static let modelKey = "loopr.ai.provider.model.v1"
    static let providersKey = "loopr.ai.providers.v2"
    static let selectedKey = "loopr.ai.selected.v2"
    private let defaults: UserDefaults
    private let credentials: [CoachProvider: any AICredentialStore]
    private let legacy: any AICredentialStore
    private let transport: any CoachChatTransport
    private var active: [UUID: Task<Void, Never>] = [:]
    private let structuredTransport: (any CoachStructuredTransport)?
    private var structuredActive: [UUID: Task<Data, Error>] = [:]
    private let agentTransport: (any CoachAgentTransport)?
    private var agentActive: [UUID: @Sendable () -> Void] = [:]
    private var foodGeneration = UUID()
    private var requestGeneration = UUID()
    private var mutating = false

    /// The default transport records every request it sends in the request log, through the shared hub.
    init(defaults: UserDefaults = .standard, credentials: (any AICredentialStore)? = nil,
         stores: [CoachProvider: any AICredentialStore]? = nil,
         transport: any CoachChatTransport = CoachURLSessionTransport(recorder: AgentRequestLogHub.shared),
         structuredTransport: (any CoachStructuredTransport)? = nil, agentTransport: (any CoachAgentTransport)? = nil) {
        self.defaults = defaults; self.transport = transport
        self.structuredTransport = structuredTransport ?? (transport as? any CoachStructuredTransport)
        self.agentTransport = agentTransport ?? (transport as? any CoachAgentTransport)
        let bundle = Bundle.main.bundleIdentifier ?? "com.loopr.ios"
        legacy = credentials ?? KeychainCredentialStore(bundleIdentifier: bundle)
        self.credentials = stores ?? Dictionary(uniqueKeysWithValues: CoachProvider.allCases.map {
            ($0, credentials ?? KeychainCredentialStore(bundleIdentifier: bundle, account: "coach-\($0.rawValue)-api-key", accessibility: .afterFirstUnlockThisDeviceOnly))
        })
    }
    func configurations() throws -> [CoachProviderConfiguration] {
        guard let data = defaults.data(forKey: Self.providersKey) else { return [] }
        return try JSONDecoder().decode([CoachProviderConfiguration].self, from: data)
    }
    func selectedConfiguration() throws -> CoachProviderConfiguration? {
        let all = try configurations()
        return all.first { $0.provider.rawValue == defaults.string(forKey: Self.selectedKey) } ?? all.first
    }
    func state() async -> SettingsIntegrationState {
        do {
            guard let selected = try selectedConfiguration(), try await credentials[selected.provider]?.read() != nil else { return .permissionRequired }
            return .available
        } catch { return .recoverableError("Loopr could not read your saved provider settings.") }
    }
    func setEnabled(_ enabled: Bool) async throws -> SettingsIntegrationState {
        if !enabled { try await removeProvider() }
        return await state()
    }
    func reset() async throws { try await removeProvider() }
    func configure(provider: CoachProvider, model: String, apiKey: String) async throws {
        guard !mutating else { throw CoachSettingsError.busy }
        mutating = true; defer { mutating = false }
        var all = try configurations().filter { $0.provider != provider }
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty, model.count <= 200, !model.contains(where: \.isWhitespace) else { throw CoachSettingsError.invalidModel }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let store = credentials[provider] else { throw CoachProviderError.missingKey }
        if !key.isEmpty {
            guard key.count <= 4096, !key.contains(where: \.isWhitespace) else { throw CoachSettingsError.invalidKey }
            do { try await store.write(Data(key.utf8)) } catch { throw CoachSettingsError.keychainWrite }
        } else {
            let existing: Data?
            do { existing = try await store.read() } catch { throw CoachSettingsError.keychainRead }
            if existing == nil { throw CoachProviderError.missingKey }
        }
        cancelRequests()
        all.append(.init(provider: provider, model: model))
        defaults.set(try JSONEncoder().encode(all), forKey: Self.providersKey)
        defaults.set(provider.rawValue, forKey: Self.selectedKey)
    }
    func select(_ provider: CoachProvider) throws {
        guard !mutating else { throw CoachSettingsError.busy }
        guard try configurations().contains(where: { $0.provider == provider }) else { throw CoachProviderError.missingKey }
        cancelRequests(); defaults.set(provider.rawValue, forKey: Self.selectedKey)
    }
    func remove(_ provider: CoachProvider) async throws {
        guard !mutating else { throw CoachSettingsError.busy }
        mutating = true; defer { mutating = false }
        cancelRequests()
        do { try await credentials[provider]?.remove() } catch { throw CoachSettingsError.keychainRemove }
        defaults.removeObject(forKey: foodConsentKey(provider))
        let remaining = try configurations().filter { $0.provider != provider }
        defaults.set(try JSONEncoder().encode(remaining), forKey: Self.providersKey)
        if defaults.string(forKey: Self.selectedKey) == provider.rawValue { defaults.removeObject(forKey: Self.selectedKey) }
    }
    func removeProvider() async throws {
        guard !mutating else { throw CoachSettingsError.busy }
        mutating = true; defer { mutating = false }
        cancelRequests()
        do {
            for provider in CoachProvider.allCases { try await credentials[provider]?.remove() }
            try await legacy.remove()
        } catch { throw CoachSettingsError.keychainRemove }
        for provider in CoachProvider.allCases { defaults.removeObject(forKey: foodConsentKey(provider)) }
        for key in [Self.providersKey, Self.selectedKey, Self.endpointKey, Self.modelKey] { defaults.removeObject(forKey: key) }
    }
    func hasLegacyConfiguration() -> Bool { defaults.string(forKey: Self.endpointKey) != nil }
    func migrateLegacyOpenAI() async throws {
        guard try configurations().isEmpty, let endpoint = defaults.string(forKey: Self.endpointKey),
              URL(string: endpoint)?.host == "api.openai.com", let model = defaults.string(forKey: Self.modelKey),
              let key = try await legacy.read() else { return }
        try await configure(provider: .openAI, model: model, apiKey: String(decoding: key, as: UTF8.self))
        try await legacy.remove()
        defaults.removeObject(forKey: Self.endpointKey); defaults.removeObject(forKey: Self.modelKey)
    }
    private func credential(for configuration: CoachProviderConfiguration) async throws -> String {
        guard !mutating, try configurations().contains(configuration) else { throw CoachProviderError.configurationChanged }
        guard let data = try await credentials[configuration.provider]?.read(), !data.isEmpty else { throw CoachProviderError.missingKey }
        guard !mutating, try configurations().contains(configuration) else { throw CoachProviderError.configurationChanged }
        return String(decoding: data, as: UTF8.self)
    }
    func credentialAvailable(_ configuration: CoachProviderConfiguration) async -> Bool {
        (try? await credential(for: configuration)) != nil
    }
    func models(provider: CoachProvider, enteredKey: String = "") async throws -> [String] {
        let key: String
        if !enteredKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { key = enteredKey }
        else {
            guard let configuration = try configurations().first(where: { $0.provider == provider }) else { throw CoachProviderError.missingKey }
            key = try await credential(for: configuration)
        }
        return try await transport.models(provider: provider, key: key)
    }
    func stream(_ request: CoachChatRequest) async throws -> AsyncThrowingStream<CoachStreamEvent, Error> {
        try Task.checkCancellation()
        let generation = requestGeneration
        let key = try await credential(for: request.configuration)
        try Task.checkCancellation()
        guard generation == requestGeneration else { throw CoachProviderError.cancelled }
        let id = UUID()
        return AsyncThrowingStream { continuation in
            let task = Task {
                defer { active[id] = nil }
                do {
                    try Task.checkCancellation()
                    for try await event in transport.stream(request, key: key) {
                        try Task.checkCancellation()
                        guard try configurations().contains(request.configuration) else { throw CoachProviderError.configurationChanged }
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: CoachProviderError.normalize(error)) }
            }
            active[id] = task
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    /// One tool turn. It checks the key, the provider revision and cancellation the way `stream` does:
    /// a changed or removed provider, or a cancel, discards the result.
    func agentTurn(_ request: CoachAgentRequest) async throws -> AgentTurn {
        guard let agentTransport else { throw CoachProviderError.modelUnavailable }
        try Task.checkCancellation()
        let generation = requestGeneration
        let key = try await credential(for: request.configuration)
        try Task.checkCancellation()
        guard generation == requestGeneration else { throw CoachProviderError.cancelled }
        let id = UUID()
        let task = Task<AgentTurn, Error> { try await agentTransport.turn(request, key: key) }
        agentActive[id] = { task.cancel() }
        defer { agentActive[id] = nil }
        let turn = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        try Task.checkCancellation()
        guard generation == requestGeneration, try configurations().contains(request.configuration) else { throw CoachProviderError.configurationChanged }
        return turn
    }

    /// Runs a whole tool loop. Every turn is checked against the key, the provider revision and
    /// cancellation, so removing the provider or starting a new chat stops it at the next turn.
    func runAgent(_ request: CoachAgentRequest, execute: @escaping AgentToolLoop.Execute) async throws -> AgentLoopResult {
        guard let agentTransport else { throw CoachProviderError.modelUnavailable }
        try Task.checkCancellation()
        let generation = requestGeneration
        let key = try await credential(for: request.configuration)
        try Task.checkCancellation()
        guard generation == requestGeneration else { throw CoachProviderError.cancelled }
        let id = UUID()
        let guarded = RevisionCheckedAgentTransport(base: agentTransport, runtime: self, generation: generation, configuration: request.configuration)
        let task = Task<AgentLoopResult, Error> { try await AgentToolLoop(transport: guarded, key: key).run(request, execute: execute) }
        agentActive[id] = { task.cancel() }
        defer { agentActive[id] = nil }
        let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        try Task.checkCancellation()
        guard generation == requestGeneration, try configurations().contains(request.configuration) else { throw CoachProviderError.configurationChanged }
        return result
    }

    fileprivate func verifyAgent(generation: UUID, configuration: CoachProviderConfiguration) throws {
        guard generation == requestGeneration, try configurations().contains(configuration) else { throw CoachProviderError.configurationChanged }
    }

    private func foodConsentKey(_ provider: CoachProvider) -> String { "loopr.ai.food-photo-consent.v1." + provider.rawValue }
    func hasFoodPhotoConsent(_ configuration: CoachProviderConfiguration) throws -> Bool {
        try selectedConfiguration() == configuration && defaults.string(forKey: foodConsentKey(configuration.provider)) == configuration.revision.uuidString
    }
    func grantFoodPhotoConsent(_ configuration: CoachProviderConfiguration) async throws {
        guard try selectedConfiguration() == configuration else { throw CoachProviderError.configurationChanged }
        _ = try await credential(for: configuration)
        guard try selectedConfiguration() == configuration else { throw CoachProviderError.configurationChanged }
        defaults.set(configuration.revision.uuidString, forKey: foodConsentKey(configuration.provider))
    }
    func revokeFoodPhotoConsent(_ provider: CoachProvider) {
        defaults.removeObject(forKey: foodConsentKey(provider))
        for task in structuredActive.values { task.cancel() }
        structuredActive.removeAll()
        foodGeneration = UUID()
    }
    func structured(_ request: CoachStructuredRequest) async throws -> Data {
        try Task.checkCancellation()
        guard try hasFoodPhotoConsent(request.configuration) else { throw CoachStructuredError.consentRequired }
        guard let structuredTransport else { throw CoachProviderError.modelUnavailable }
        let generation = requestGeneration, foodRevision = foodGeneration
        let key = try await credential(for: request.configuration)
        guard generation == requestGeneration, foodRevision == foodGeneration,
              try hasFoodPhotoConsent(request.configuration) else { throw CoachProviderError.configurationChanged }
        let id = UUID()
        let task = Task { try await structuredTransport.structured(request, key: key) }
        structuredActive[id] = task
        defer { structuredActive[id] = nil }
        let data = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        try Task.checkCancellation()
        guard generation == requestGeneration, foodRevision == foodGeneration,
              try hasFoodPhotoConsent(request.configuration) else { throw CoachProviderError.configurationChanged }
        return data
    }
    func foodPhotoConsentStored(_ configuration: CoachProviderConfiguration) throws -> Bool {
        try configurations().contains(configuration) && defaults.string(forKey: foodConsentKey(configuration.provider)) == configuration.revision.uuidString
    }
    func cancelRequests() {
        requestGeneration = UUID(); foodGeneration = UUID()
        for task in structuredActive.values { task.cancel() }
        structuredActive.removeAll()
        for task in active.values { task.cancel() }
        active.removeAll()
        for cancel in agentActive.values { cancel() }
        agentActive.removeAll()
    }
}

/// Checks the provider revision before a tool turn leaves and again before its result is used.
private struct RevisionCheckedAgentTransport: CoachAgentTransport {
    let base: any CoachAgentTransport
    let runtime: LooprAISettingsRuntime
    let generation: UUID
    let configuration: CoachProviderConfiguration
    func turn(_ request: CoachAgentRequest, key: String) async throws -> AgentTurn {
        try await runtime.verifyAgent(generation: generation, configuration: configuration)
        let result = try await base.turn(request, key: key)
        try await runtime.verifyAgent(generation: generation, configuration: configuration)
        return result
    }
}

nonisolated enum CoachSettingsError: Error, LocalizedError {
    case invalidModel, invalidKey, busy, keychainWrite, keychainRead, keychainRemove
    var errorDescription: String? {
        switch self {
        case .busy: "Loopr is still saving your last change. Try again in a moment."
        case .keychainWrite: "Loopr could not save the key to this iPhone's Keychain. Unlock your iPhone and try again."
        case .keychainRead: "Loopr could not read the saved key from this iPhone's Keychain. Unlock your iPhone and try again."
        case .keychainRemove: "Loopr could not remove the key from this iPhone's Keychain. Try again."

        case .invalidModel: "Enter a model ID without spaces."
        case .invalidKey: "Enter the API key without spaces or line breaks."
        }
    }
}
