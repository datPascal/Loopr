import Foundation

/// What one chat may read, chosen in the consent sheet. Your data holds a second, device-wide
/// switch for each domain, and a tool reads a domain only when both are on.
///
/// `journal` is the older single switch. It reads true only when answers and notes are both shared,
/// and setting it sets both. Chats saved before the split decode with `journal` copied to both.
///
/// `supplements` and `labs` came with the longevity tools. Both start off in every chat, and a chat saved before they
/// existed reads them as not shared.
public struct CoachSharing: Codable, Equatable, Sendable {
    public var metrics = true
    public var food = true
    public var training = true
    public var journalAnswers = false
    public var journalNotes = false
    public var cycle = false
    public var supplements = false
    public var labs = false

    public var journal: Bool {
        get { journalAnswers && journalNotes }
        set { journalAnswers = newValue; journalNotes = newValue }
    }

    public init(metrics: Bool = true, journal: Bool = false, cycle: Bool = false, food: Bool = true, training: Bool = true,
                journalAnswers: Bool? = nil, journalNotes: Bool? = nil, supplements: Bool = false, labs: Bool = false) {
        self.metrics = metrics; self.cycle = cycle; self.food = food; self.training = training
        self.supplements = supplements; self.labs = labs
        self.journalAnswers = journalAnswers ?? journal; self.journalNotes = journalNotes ?? journal
    }

    private enum CodingKeys: String, CodingKey { case metrics, journal, cycle, food, training, journalAnswers, journalNotes, supplements, labs }

    /// Old chats never shared food, so a missing key means off. Workouts used to travel with health
    /// measurements, so a missing `training` follows `metrics`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let metrics = try c.decodeIfPresent(Bool.self, forKey: .metrics) ?? true
        let legacyJournal = try c.decodeIfPresent(Bool.self, forKey: .journal) ?? false
        self.init(metrics: metrics, journal: legacyJournal, cycle: try c.decodeIfPresent(Bool.self, forKey: .cycle) ?? false,
                  food: try c.decodeIfPresent(Bool.self, forKey: .food) ?? false,
                  training: try c.decodeIfPresent(Bool.self, forKey: .training) ?? metrics,
                  journalAnswers: try c.decodeIfPresent(Bool.self, forKey: .journalAnswers) ?? legacyJournal,
                  journalNotes: try c.decodeIfPresent(Bool.self, forKey: .journalNotes) ?? legacyJournal,
                  supplements: try c.decodeIfPresent(Bool.self, forKey: .supplements) ?? false,
                  labs: try c.decodeIfPresent(Bool.self, forKey: .labs) ?? false)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(metrics, forKey: .metrics)
        try c.encode(journalAnswers || journalNotes, forKey: .journal)
        try c.encode(cycle, forKey: .cycle)
        try c.encode(food, forKey: .food)
        try c.encode(training, forKey: .training)
        try c.encode(journalAnswers, forKey: .journalAnswers)
        try c.encode(journalNotes, forKey: .journalNotes)
        try c.encode(supplements, forKey: .supplements)
        try c.encode(labs, forKey: .labs)
    }
}

/// What started a conversation. A person's own chat is `.chat`. Loopr starts the other two:
/// the morning briefing and the weekly review.
public enum CoachConversationKind: String, Codable, Sendable {
    case chat, morningBriefing, weeklyReview
}

public struct CoachConversation: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var title: String
    public let createdAt: Date
    public var updatedAt: Date
    public var configuration: CoachProviderConfiguration
    public var sharing: CoachSharing
    public var context: String
    public var instructions: String
    public var consentedAt: Date?
    public var messages: [CoachChatMessage]
    public var draft: String
    public var kind: CoachConversationKind
    /// True for every conversation Loopr started, the morning briefing and the weekly review.
    public var isBriefing: Bool {
        get { kind != .chat }
        set { kind = newValue ? (kind == .chat ? .morningBriefing : kind) : .chat }
    }
    public init(id: UUID = UUID(), configuration: CoachProviderConfiguration, instructions: String = "", now: Date = Date()) {
        self.id = id; title = "New chat"; createdAt = now; updatedAt = now
        self.configuration = configuration; sharing = .init(); context = ""; self.instructions = instructions
        consentedAt = nil; messages = []; draft = ""; kind = .chat
    }
    public var request: CoachChatRequest {
        .init(configuration: configuration, instructions: instructions, context: context, messages: messages)
    }
    private enum CodingKeys: String, CodingKey {
        case id, title, createdAt, updatedAt, configuration, sharing, context, instructions, consentedAt, messages, draft, isBriefing, kind
    }

    /// Chats saved before `kind` existed carry only `isBriefing`, which meant the morning briefing.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        configuration = try c.decode(CoachProviderConfiguration.self, forKey: .configuration)
        sharing = try c.decode(CoachSharing.self, forKey: .sharing)
        context = try c.decode(String.self, forKey: .context)
        instructions = try c.decode(String.self, forKey: .instructions)
        consentedAt = try c.decodeIfPresent(Date.self, forKey: .consentedAt)
        messages = try c.decode([CoachChatMessage].self, forKey: .messages)
        draft = try c.decode(String.self, forKey: .draft)
        let legacyBriefing = try c.decodeIfPresent(Bool.self, forKey: .isBriefing) ?? false
        kind = try c.decodeIfPresent(CoachConversationKind.self, forKey: .kind) ?? (legacyBriefing ? .morningBriefing : .chat)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(title, forKey: .title)
        try c.encode(createdAt, forKey: .createdAt); try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(configuration, forKey: .configuration); try c.encode(sharing, forKey: .sharing)
        try c.encode(context, forKey: .context); try c.encode(instructions, forKey: .instructions)
        try c.encodeIfPresent(consentedAt, forKey: .consentedAt)
        try c.encode(messages, forKey: .messages); try c.encode(draft, forKey: .draft)
        try c.encode(isBriefing, forKey: .isBriefing); try c.encode(kind, forKey: .kind)
    }

    /// Unfinished replies remain visible, but are never represented as completed advice to a provider.
    public mutating func recoverInterruptedReply() {
        for index in messages.indices where messages[index].status == .streaming {
            messages[index].status = .interrupted
        }
    }
}

public struct CoachPreferences: Codable, Equatable, Sendable {
    public var instructions = ""
    public var morningEnabled = false
    public var morningHour = 7
    public var morningConfiguration: CoachProviderConfiguration?
    public var morningSharing = CoachSharing()
    public var morningConsentAt: Date?
    public var lastAttemptDay: String?
    public var lastBriefingDay: String?
    public var lastBriefingError: String?
    /// The `yyyy-MM-dd` Monday of the last week the weekly review was written for. Nil until the first one.
    public var lastWeeklyReviewWeek: String?
    public init() {}
}

public protocol CoachConversationRepository: Sendable {
    func conversations() async throws -> [CoachConversation]
    func save(_ conversation: CoachConversation) async throws
    func delete(id: UUID) async throws
    func preferences() async throws -> CoachPreferences
    func savePreferences(_ preferences: CoachPreferences) async throws
}
