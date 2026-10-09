import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct AIProviderConfiguration: Equatable, Codable, Sendable {
    public let baseURL: URL
    public let model: String
    public init(baseURL: URL, model: String) { self.baseURL = baseURL; self.model = model }
}
public protocol AICredentialStore: Sendable {
    func write(_ value: Data) async throws
    func read() async throws -> Data?
    func remove() async throws
}
public actor AISettings {
    private let credentials: any AICredentialStore
    private(set) public var configuration: AIProviderConfiguration?
    private(set) public var isEnabled = false
    public init(credentials: any AICredentialStore) { self.credentials = credentials }
    public func configure(_ configuration: AIProviderConfiguration, apiKey: Data) async throws {
        try await credentials.write(apiKey)
        self.configuration = configuration
        isEnabled = true
    }
    public func removeProvider() async throws {
        try await credentials.remove()
        configuration = nil
        isEnabled = false
    }
    public func credential() async throws -> Data? { try await credentials.read() }
}

public enum AISensitiveCategory: String, Codable, Hashable, Sendable { case journalText, cycleData }
public struct AIContext: Equatable, Codable, Sendable {
    public let metrics: [String: Double]
    public let journalText: String?
    public let cycleData: [String: String]?
    public let dateRange: ClosedRange<Date>
    public init(metrics: [String: Double], journalText: String?, cycleData: [String: String]?,
                dateRange: ClosedRange<Date>) {
        self.metrics = metrics; self.journalText = journalText; self.cycleData = cycleData
        self.dateRange = dateRange
    }
}
public enum AIContextBuilder {
    public static func payload(context: AIContext, excluding: Set<AISensitiveCategory>) throws -> Data {
        let filtered = AIContext(metrics: context.metrics,
            journalText: excluding.contains(.journalText) ? nil : context.journalText,
            cycleData: excluding.contains(.cycleData) ? nil : context.cycleData,
            dateRange: context.dateRange)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(filtered)
    }
    public static func exactPreview(context: AIContext, excluding: Set<AISensitiveCategory>) throws -> String {
        String(decoding: try payload(context: context, excluding: excluding), as: UTF8.self)
    }
}

public enum AIProviderFailure: Error, Equatable, Sendable {
    case disabled, missingCredential, timeout, http(Int), malformedResponse, cancelled
}
public protocol AITransport: Sendable { func send(payload: Data, configuration: AIProviderConfiguration, key: Data) async throws -> Data }

/// A single-attempt OpenAI-compatible transport. Retry policy deliberately lives nowhere in
/// AIKit: a user action produces at most one provider request.
public struct URLSessionAITransport: AITransport {
    private let session: URLSession
    private let timeout: TimeInterval
    public init(session: URLSession = .shared, timeout: TimeInterval = 30) {
        self.session = session; self.timeout = timeout
    }
    public func send(payload: Data, configuration: AIProviderConfiguration, key: Data) async throws -> Data {
        guard var components = URLComponents(url: configuration.baseURL, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(), ["https", "http"].contains(scheme) else {
            throw AIProviderFailure.malformedResponse
        }
        if components.path.isEmpty || components.path == "/" { components.path = "/v1/chat/completions" }
        guard let url = components.url else { throw AIProviderFailure.malformedResponse }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"; request.httpBody = payload
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(configuration.model, forHTTPHeaderField: "X-Loopr-Model")
        request.setValue("Bearer " + String(decoding: key, as: UTF8.self), forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw AIProviderFailure.malformedResponse }
            guard (200..<300).contains(http.statusCode) else { throw AIProviderFailure.http(http.statusCode) }
            guard !data.isEmpty,
                  (try? JSONSerialization.jsonObject(with: data)) != nil else {
                throw AIProviderFailure.malformedResponse
            }
            return data
        } catch let failure as AIProviderFailure { throw failure }
        catch is CancellationError { throw AIProviderFailure.cancelled }
        catch let error as URLError where error.code == .timedOut { throw AIProviderFailure.timeout }
        catch { throw AIProviderFailure.malformedResponse }
    }
}

public actor AIProviderClient {
    private let settings: AISettings
    private let transport: any AITransport
    private var generation: UInt64 = 0
    private var activeRequest: Task<Data, Error>?
    public init(settings: AISettings, transport: any AITransport) { self.settings = settings; self.transport = transport }
    public func request(context: AIContext, excluding: Set<AISensitiveCategory> = []) async throws -> Data {
        guard await settings.isEnabled, let configuration = await settings.configuration else { throw AIProviderFailure.disabled }
        guard let key = try await settings.credential() else { throw AIProviderFailure.missingCredential }
        generation &+= 1; let current = generation
        let payload = try AIContextBuilder.payload(context: context, excluding: excluding)
        let request = Task {
            try await transport.send(payload: payload, configuration: configuration, key: key)
        }
        activeRequest?.cancel()
        activeRequest = request
        defer {
            if current == generation { activeRequest = nil }
        }
        do {
            let response = try await request.value
            try Task.checkCancellation()
            guard current == generation else { throw AIProviderFailure.cancelled }
            guard !response.isEmpty else { throw AIProviderFailure.malformedResponse }
            return response
        } catch let failure as AIProviderFailure { throw failure }
        catch is CancellationError { throw AIProviderFailure.cancelled }
        catch { throw AIProviderFailure.malformedResponse }
    }
    public func cancel() {
        generation &+= 1
        activeRequest?.cancel()
        activeRequest = nil
    }
}

public protocol AINotificationScheduling: Sendable {
    func scheduleBriefingReady(id: String, day: String, fireDate: Date) async throws
}

/// AIKit owns no notification-center API. It reports a completed briefing to
/// the app's central notification policy through this narrow adapter only.
public struct AIBriefingNotificationBridge: Sendable {
    private let scheduler: any AINotificationScheduling

    public init(scheduler: any AINotificationScheduling) { self.scheduler = scheduler }

    public func briefingReady(id: String, day: String, fireDate: Date) async throws {
        try await scheduler.scheduleBriefingReady(id: id, day: day, fireDate: fireDate)
    }
}

public enum AIProposal: Equatable, Codable, Sendable {
    case journal(text: String, tags: [String])
    case goalAdjustment(goalID: UUID, value: Double)
}
public struct StoredAIProposal: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public let conversationID: UUID
    public let proposal: AIProposal
    public var confirmedAt: Date?
    public var appliedAt: Date?
    public init(id: UUID, conversationID: UUID, proposal: AIProposal) {
        self.id = id; self.conversationID = conversationID; self.proposal = proposal
    }
}
public protocol AIProposalApplier: Sendable { func apply(_ proposal: AIProposal) async throws }
public actor AIProposalLedger {
    private var rows: [UUID: StoredAIProposal] = [:]
    private let persistenceURL: URL?
    public init(persistenceURL: URL? = nil) {
        self.persistenceURL = persistenceURL
        guard let persistenceURL, let data = try? Data(contentsOf: persistenceURL),
              let restored = try? JSONDecoder().decode([UUID: StoredAIProposal].self, from: data) else { return }
        rows = restored
    }
    public func store(_ row: StoredAIProposal) { rows[row.id] = row; persist() }
    public func proposal(id: UUID) -> StoredAIProposal? { rows[id] }
    public func confirmAndApply(id: UUID, at date: Date, using applier: any AIProposalApplier) async throws {
        guard var row = rows[id], row.appliedAt == nil else { return }
        row.confirmedAt = date; rows[id] = row; persist()
        try await applier.apply(row.proposal)
        row.appliedAt = date; rows[id] = row; persist()
    }
    public func delete(conversationID: UUID) {
        rows = rows.filter { $0.value.conversationID != conversationID }; persist()
    }
    private func persist() {
        guard let persistenceURL, let data = try? JSONEncoder().encode(rows) else { return }
        try? FileManager.default.createDirectory(at: persistenceURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: persistenceURL, options: .atomic)
    }
}
public struct AIConversation: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public var messages: [String]
    public init(id: UUID, messages: [String]) { self.id = id; self.messages = messages }
}
public actor AIConversationStore {
    private var rows: [UUID: AIConversation] = [:]
    private let proposals: AIProposalLedger
    private let persistenceURL: URL?
    public init(proposals: AIProposalLedger, persistenceURL: URL? = nil) {
        self.proposals = proposals; self.persistenceURL = persistenceURL
        guard let persistenceURL, let data = try? Data(contentsOf: persistenceURL),
              let restored = try? JSONDecoder().decode([UUID: AIConversation].self, from: data) else { return }
        rows = restored
    }
    public func save(_ conversation: AIConversation) { rows[conversation.id] = conversation; persist() }
    public func conversation(id: UUID) -> AIConversation? { rows[id] }
    public func delete(id: UUID) async {
        rows[id] = nil; persist(); await proposals.delete(conversationID: id)
    }
    private func persist() {
        guard let persistenceURL, let data = try? JSONEncoder().encode(rows) else { return }
        try? FileManager.default.createDirectory(at: persistenceURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: persistenceURL, options: .atomic)
    }
}
public enum AIChartKind: String, CaseIterable, Sendable { case sleepTrend, heartTrend, strainTrend }
public enum AIChartFirewallError: Error { case notAllowlisted }
public enum AIChartContext {
    public static func validate(_ rawValue: String) throws -> AIChartKind {
        guard let kind = AIChartKind(rawValue: rawValue) else { throw AIChartFirewallError.notAllowlisted }
        return kind
    }
}

public enum AIFeature: String, Codable, Sendable { case coachConversation, morningBriefing, eveningBriefing }
public struct AIResponse: Equatable, Sendable {
    public let content: Data
    public let usedLocalFallback: Bool
    public init(content: Data, usedLocalFallback: Bool) {
        self.content = content; self.usedLocalFallback = usedLocalFallback
    }
}
public protocol DeterministicAIFallback: Sendable {
    func response(for feature: AIFeature, context: AIContext) async -> Data
}

/// Coach and briefing flows share the exact AI-01 request builder and always retain a useful,
/// deterministic local result when BYOK is disabled, unavailable, or fails.
public actor AIFeatureCoordinator {
    private let provider: AIProviderClient
    private let fallback: any DeterministicAIFallback
    public init(provider: AIProviderClient, fallback: any DeterministicAIFallback) {
        self.provider = provider; self.fallback = fallback
    }
    public func response(for feature: AIFeature, context: AIContext,
                         excluding: Set<AISensitiveCategory> = []) async -> AIResponse {
        do {
            return .init(content: try await provider.request(context: context, excluding: excluding),
                         usedLocalFallback: false)
        } catch {
            return .init(content: await fallback.response(for: feature, context: context),
                         usedLocalFallback: true)
        }
    }
}
