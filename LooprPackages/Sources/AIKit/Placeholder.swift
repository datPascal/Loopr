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

/// What the agent asked to change. A proposal is inert data until the person confirms it.
/// The payloads carry the model's request as JSON text. The app validates that JSON when the
/// proposal is created and again when it is applied.
public enum AIProposal: Equatable, Codable, Sendable {
    case journal(text: String, tags: [String])
    case goalAdjustment(goalID: UUID, value: Double)
    /// A food draft in the `FoodEstimate` JSON shape, with when and where it happened.
    case meal(estimateJSON: String, slot: String, occurredAt: Date, timeZoneID: String, provider: String, model: String)
    case journalQuestion(name: String, question: String)
    case templateEdit(templateID: UUID, expectedRevision: Int, editJSON: String)
    case programDraft(json: String)
    /// A reminder at a local time of day. `repeatsDaily` false means the next time it comes round, once.
    case reminder(title: String, body: String, minuteOfDay: Int, repeatsDaily: Bool)
    case test(candidateID: String, metric: String?, reminderMinuteOfDay: Int?)
}

/// What the confirmation card says. Written by the app when the proposal is created.
public struct AIProposalCard: Equatable, Codable, Sendable {
    public var title: String
    public var lines: [String]
    public var confirmTitle: String
    public var dismissTitle: String
    /// Shown after the change is saved.
    public var doneText: String
    public init(title: String, lines: [String] = [], confirmTitle: String, dismissTitle: String = "Not now", doneText: String) {
        self.title = title; self.lines = lines; self.confirmTitle = confirmTitle
        self.dismissTitle = dismissTitle; self.doneText = doneText
    }
}

public enum AIProposalState: String, Codable, Sendable {
    case pending, applied, dismissed
    /// Confirmed, but saving failed. The person can try again.
    case failed
}

public struct StoredAIProposal: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public let conversationID: UUID
    /// The assistant message the card sits under.
    public var messageID: UUID?
    public let proposal: AIProposal
    public var card: AIProposalCard?
    public var createdAt: Date
    public var confirmedAt: Date?
    public var appliedAt: Date?
    public var dismissedAt: Date?
    public var failure: String?

    public var state: AIProposalState {
        if appliedAt != nil { return .applied }
        if dismissedAt != nil { return .dismissed }
        if failure != nil { return .failed }
        return .pending
    }

    public init(id: UUID, conversationID: UUID, proposal: AIProposal, messageID: UUID? = nil, card: AIProposalCard? = nil,
                createdAt: Date = Date()) {
        self.id = id; self.conversationID = conversationID; self.proposal = proposal
        self.messageID = messageID; self.card = card; self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, conversationID, messageID, proposal, card, createdAt, confirmedAt, appliedAt, dismissedAt, failure
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        conversationID = try c.decode(UUID.self, forKey: .conversationID)
        proposal = try c.decode(AIProposal.self, forKey: .proposal)
        messageID = try c.decodeIfPresent(UUID.self, forKey: .messageID)
        card = try c.decodeIfPresent(AIProposalCard.self, forKey: .card)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? .distantPast
        confirmedAt = try c.decodeIfPresent(Date.self, forKey: .confirmedAt)
        appliedAt = try c.decodeIfPresent(Date.self, forKey: .appliedAt)
        dismissedAt = try c.decodeIfPresent(Date.self, forKey: .dismissedAt)
        failure = try c.decodeIfPresent(String.self, forKey: .failure)
    }
}
public protocol AIProposalApplier: Sendable {
    func apply(_ proposal: AIProposal) async throws
    /// The ledger calls this one. `id` is the proposal's id, a stable key for applying once.
    func apply(_ proposal: AIProposal, id: UUID) async throws
}
public extension AIProposalApplier {
    func apply(_ proposal: AIProposal, id: UUID) async throws { try await apply(proposal) }
}

/// Where proposals live between launches. The app backs it with its document store.
public protocol AIProposalPersistence: Sendable {
    /// Rows that cannot be decoded are skipped, not fatal.
    func load() throws -> [StoredAIProposal]
    func save(_ row: StoredAIProposal) throws
    func remove(ids: [UUID]) throws
    func removeAll() throws
}

/// Proposals and the one place they turn into changes. `confirmAndApply` is the only path to
/// the applier, so nothing is saved until the person confirms. A second confirm, a double tap
/// or a tap that arrives while the first is still saving does nothing.
public actor AIProposalLedger {
    private var rows: [UUID: StoredAIProposal] = [:]
    private var applying: Set<UUID> = []
    private let persistence: (any AIProposalPersistence)?

    public init(persistenceURL: URL? = nil) {
        persistence = persistenceURL.map { FileAIProposalPersistence(url: $0) }
        rows = Dictionary(((try? persistence?.load()) ?? []).map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
    }
    public init(persistence: any AIProposalPersistence) {
        self.persistence = persistence
        rows = Dictionary(((try? persistence.load()) ?? []).map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
    }

    /// Stores a new proposal. Throws when it could not be saved, so the caller does not offer a card
    /// that would vanish on relaunch. An id that exists is left alone.
    public func create(_ row: StoredAIProposal) throws {
        guard rows[row.id] == nil else { return }
        try persistence?.save(row)
        rows[row.id] = row
    }
    public func store(_ row: StoredAIProposal) { rows[row.id] = row; try? persistence?.save(row) }
    public func proposal(id: UUID) -> StoredAIProposal? { rows[id] }
    public func proposals(conversationID: UUID) -> [StoredAIProposal] {
        rows.values.filter { $0.conversationID == conversationID }.sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
    }

    /// Applies a pending or failed proposal once. Returns true only when this call applied it.
    /// A failed apply keeps the proposal confirmable and records the reason on the row.
    @discardableResult
    public func confirmAndApply(id: UUID, at date: Date, using applier: any AIProposalApplier) async throws -> Bool {
        guard var row = rows[id], row.appliedAt == nil, row.dismissedAt == nil, !applying.contains(id) else { return false }
        applying.insert(id); defer { applying.remove(id) }
        row.confirmedAt = row.confirmedAt ?? date; row.failure = nil
        try persistence?.save(row)
        rows[id] = row
        do { try await applier.apply(row.proposal, id: row.id) }
        catch {
            row.failure = error.localizedDescription.isEmpty ? "Could not save this." : error.localizedDescription
            rows[id] = row; try? persistence?.save(row)
            throw error
        }
        row.appliedAt = date
        rows[id] = row; try? persistence?.save(row)
        return true
    }

    /// Records "Not now". Nothing was applied, so nothing else changes.
    @discardableResult
    public func dismiss(id: UUID, at date: Date) -> Bool {
        guard var row = rows[id], row.appliedAt == nil, row.dismissedAt == nil, !applying.contains(id) else { return false }
        row.dismissedAt = date; row.failure = nil
        rows[id] = row; try? persistence?.save(row)
        return true
    }

    public func delete(conversationID: UUID) {
        let ids = rows.values.filter { $0.conversationID == conversationID }.map(\.id)
        guard !ids.isEmpty else { return }
        for id in ids { rows[id] = nil }
        try? persistence?.remove(ids: ids)
    }
    public func deleteAll() {
        rows = [:]; try? persistence?.removeAll()
    }
}

/// The original single-file store. Kept so existing callers and tests keep working.
struct FileAIProposalPersistence: AIProposalPersistence {
    let url: URL
    func load() throws -> [StoredAIProposal] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return Array(try JSONDecoder().decode([UUID: StoredAIProposal].self, from: data).values)
    }
    private func write(_ rows: [UUID: StoredAIProposal]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(rows).write(to: url, options: .atomic)
    }
    private func current() -> [UUID: StoredAIProposal] {
        Dictionary(((try? load()) ?? []).map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
    }
    func save(_ row: StoredAIProposal) throws { var rows = current(); rows[row.id] = row; try write(rows) }
    func remove(ids: [UUID]) throws { var rows = current(); for id in ids { rows[id] = nil }; try write(rows) }
    func removeAll() throws { try write([:]) }
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
