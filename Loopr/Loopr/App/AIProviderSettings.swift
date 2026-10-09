import AIKit
import DesignSystem
import Foundation
import SettingsKit
import SwiftUI

enum LooprAIConfigurationError: Error, LocalizedError {
    case invalidEndpoint, missingModel, missingKey
    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "Enter a valid HTTP or HTTPS provider endpoint."
        case .missingModel: "Enter a model name."
        case .missingKey: "Enter an API key."
        }
    }
}

actor LooprAISettingsRuntime: AIPrivacySettingsEntryPoint {
    static let shared = LooprAISettingsRuntime()
    static let endpointKey = "loopr.ai.provider.endpoint.v1"
    static let modelKey = "loopr.ai.provider.model.v1"
    private let settings: AISettings
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard,
         credentials: (any AICredentialStore)? = nil) {
        self.defaults = defaults
        self.settings = AISettings(credentials: credentials ?? KeychainCredentialStore(bundleIdentifier: Bundle.main.bundleIdentifier ?? "com.loopr.ios"))
    }

    func state() async -> SettingsIntegrationState {
        guard configurationFromDefaults() != nil else { return .permissionRequired }
        do { return try await settings.credential() == nil ? .permissionRequired : .available }
        catch { return .recoverableError(error.localizedDescription) }
    }

    func setEnabled(_ enabled: Bool) async throws -> SettingsIntegrationState {
        if !enabled { try await removeProvider(); return .permissionRequired }
        return await state()
    }

    func reset() async throws { try await removeProvider() }

    func configure(endpoint: String, model: String, apiKey: String) async throws {
        guard let url = URL(string: endpoint), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), url.host != nil else {
            throw LooprAIConfigurationError.invalidEndpoint
        }
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty else { throw LooprAIConfigurationError.missingModel }
        guard !apiKey.isEmpty else { throw LooprAIConfigurationError.missingKey }
        try await settings.configure(.init(baseURL: url, model: trimmedModel), apiKey: Data(apiKey.utf8))
        defaults.set(url.absoluteString, forKey: Self.endpointKey)
        defaults.set(trimmedModel, forKey: Self.modelKey)
    }

    func removeProvider() async throws {
        try await settings.removeProvider()
        defaults.removeObject(forKey: Self.endpointKey)
        defaults.removeObject(forKey: Self.modelKey)
    }

    func publicConfiguration() -> AIProviderConfiguration? { configurationFromDefaults() }

    private func configurationFromDefaults() -> AIProviderConfiguration? {
        guard let endpoint = defaults.string(forKey: Self.endpointKey),
              let url = URL(string: endpoint),
              let model = defaults.string(forKey: Self.modelKey), !model.isEmpty else { return nil }
        return AIProviderConfiguration(baseURL: url, model: model)
    }
}

@MainActor
struct AppAIProviderSettingsScreen: View {
    @Environment(\.colorScheme) private var colorScheme
    private let runtime: LooprAISettingsRuntime
    @State private var endpoint = ""
    @State private var model = ""
    @State private var apiKey = ""
    @State private var status = "AI is off. No provider requests are made."
    @State private var statusTone: ChipTone = .neutral
    @State private var showingRemoveConfirmation = false

    init(runtime: LooprAISettingsRuntime = .shared) { self.runtime = runtime }

    var body: some View {
        LooprDetailScaffold {
            LooprSectionGroup(title: "Custom provider") {
                LooprFormCard(padding: LooprSpacing.none) {
                    VStack(spacing: LooprSpacing.none) {
                        LooprTextFieldRow(
                            title: "Endpoint",
                            placeholder: "https://provider.example/v1",
                            text: $endpoint
                        )
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .accessibilityIdentifier("settings-ai-endpoint")

                        LooprHairline()

                        LooprTextFieldRow(
                            title: "Model",
                            placeholder: "Model name",
                            text: $model
                        )
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("settings-ai-model")

                        LooprHairline()

                        apiKeyRow
                    }
                }

                VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                    Button("Save provider") { Task { await save() } }
                        .buttonStyle(LooprPrimaryButtonStyle())
                        .accessibilityIdentifier("settings-ai-save-provider")

                    Button("Remove provider", role: .destructive) {
                        showingRemoveConfirmation = true
                    }
                    .buttonStyle(LooprDestructiveButtonStyle())
                    .accessibilityIdentifier("settings-ai-remove-provider")
                }
            }

            LooprSectionGroup(title: "Storage and requests") {
                LooprFormCard {
                    VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                        LooprText("Key storage", style: .cardTitle)
                        LooprText(
                            "The API key is stored in the iOS Keychain with device-only protection. Loopr does not put it in UserDefaults.",
                            style: .prose,
                            color: .inkSecondary
                        )
                        LooprText(
                            "Requests go to the endpoint you enter. If it has no path, Loopr appends /v1/chat/completions and sends the model name in an X-Loopr-Model header.",
                            style: .prose,
                            color: .inkSecondary
                        )
                        LooprText(
                            "Each request sends your daily metrics for the selected range. It also sends your journal text and cycle data unless those are excluded. Nothing else in Loopr sends data off this iPhone.",
                            style: .prose,
                            color: .inkSecondary
                        )
                    }
                }
            }

            LooprSectionGroup(title: "Status") {
                LooprFormCard {
                    LooprInlineMessage(status, tone: statusTone)
                        .accessibilityIdentifier("settings-ai-provider-status")
                }
            }
        }
        .navigationTitle("AI and privacy")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(LooprAppearance.isDark(colorScheme) ? .dark : .light, for: .navigationBar)
        .tint(Color.loopr(.brand))
        .accessibilityIdentifier("settings-ai-provider-screen")
        .confirmationDialog(
            "Remove this provider?",
            isPresented: $showingRemoveConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove provider", role: .destructive) {
                Task { await remove() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the saved provider details and API key from Loopr.")
        }
        .task { await load() }
    }

    private var apiKeyRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.sm) {
            LooprText("API key", style: .settingsRow)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)

            Spacer(minLength: LooprSpacing.sm)

            SecureField("Enter API key", text: $apiKey)
                .textFieldStyle(.plain)
                .looprTypography(.metricUnit)
                .foregroundStyle(Color.loopr(.ink))
                .tint(Color.loopr(.brand))
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(.never)
                .textContentType(.password)
                .privacySensitive()
                .accessibilityIdentifier("settings-ai-api-key")
        }
        .padding(.horizontal, LooprSpacing.formCardPadding)
        .padding(.vertical, LooprSpacing.formRowVerticalPadding)
        .frame(maxWidth: .infinity, minHeight: LooprSpacing.interactiveRowHeight, alignment: .leading)
    }

    private func load() async {
        if let configuration = await runtime.publicConfiguration() {
            endpoint = configuration.baseURL.absoluteString
            model = configuration.model
            status = "Provider configured. Enter the key to save changes."
            statusTone = .positive
        }
    }

    private func save() async {
        do {
            try await runtime.configure(endpoint: endpoint, model: model, apiKey: apiKey)
            apiKey = ""
            status = "Provider saved."
            statusTone = .positive
        } catch {
            status = error.localizedDescription
            statusTone = .critical
        }
    }

    private func remove() async {
        do {
            try await runtime.removeProvider(); endpoint = ""; model = ""; apiKey = ""
            status = "Provider removed. AI provider access is off."
            statusTone = .neutral
        } catch {
            status = error.localizedDescription
            statusTone = .critical
        }
    }
}
