import AIKit
import Foundation

/// Why a read was refused. `message` is what the model sees as the tool result and what the
/// request log records.
nonisolated enum AgentAccessError: Error, Equatable, Sendable, LocalizedError {
    /// The switch in Your data is off.
    case off(AgentDataDomain)
    /// Your data allows it, but this chat did not share it.
    case notShared(AgentDataDomain)

    var domain: AgentDataDomain {
        switch self { case .off(let domain), .notShared(let domain): domain }
    }
    var message: String {
        switch self {
        case .off(let domain): "\(domain.title) is off in Your data, so Ask did not read it."
        case .notShared(let domain): "\(domain.title) is not shared in this chat, so Ask did not read it."
        }
    }
    var errorDescription: String? { message }
}

/// The one rule for what Ask may read: a domain is readable when its switch in Your data is on
/// and the chat shares it. Your data is read from `UserDefaults` on every check, never cached, so
/// turning a switch off stops the next read, even inside a running chat.
/// `UserDefaults` is documented as safe to use from any thread, so the struct is `@unchecked Sendable`.
nonisolated struct AgentAccessGate: @unchecked Sendable {
    /// What the chat shared. Nil applies Your data alone, for callers with no chat.
    let consent: CoachSharing?
    let defaults: UserDefaults?

    init(consent: CoachSharing?, defaults: UserDefaults? = .standard) {
        self.consent = consent; self.defaults = defaults
    }

    func yourDataAllows(_ domain: AgentDataDomain) -> Bool {
        AgentAccessPreferences.isAllowed(domain, defaults: defaults)
    }
    func chatShares(_ domain: AgentDataDomain) -> Bool {
        guard let consent else { return true }
        return Self.shared(domain, in: consent)
    }
    func isAllowed(_ domain: AgentDataDomain) -> Bool { yourDataAllows(domain) && chatShares(domain) }

    func check(_ domain: AgentDataDomain) throws {
        guard yourDataAllows(domain) else { throw AgentAccessError.off(domain) }
        guard chatShares(domain) else { throw AgentAccessError.notShared(domain) }
    }

    var allowedDomains: Set<AgentDataDomain> { Set(AgentDataDomain.allCases.filter(isAllowed)) }
    /// In display order, for the instruction that names what is off.
    var blockedDomains: [AgentDataDomain] { AgentDataDomain.allCases.filter { !isAllowed($0) } }

    /// `sharing` with every domain Your data has switched off turned off too.
    static func effective(_ sharing: CoachSharing, defaults: UserDefaults?) -> CoachSharing {
        var result = sharing
        for domain in AgentDataDomain.allCases where !AgentAccessPreferences.isAllowed(domain, defaults: defaults) {
            set(domain, false, in: &result)
        }
        return result
    }
    func effective(_ sharing: CoachSharing) -> CoachSharing { Self.effective(sharing, defaults: defaults) }

    static func shared(_ domain: AgentDataDomain, in sharing: CoachSharing) -> Bool {
        switch domain {
        case .metrics: sharing.metrics
        case .food: sharing.food
        case .training: sharing.training
        case .journalAnswers: sharing.journalAnswers
        case .journalNotes: sharing.journalNotes
        case .cycle: sharing.cycle
        case .supplements: sharing.supplements
        case .labs: sharing.labs
        }
    }
    static func set(_ domain: AgentDataDomain, _ value: Bool, in sharing: inout CoachSharing) {
        switch domain {
        case .metrics: sharing.metrics = value
        case .food: sharing.food = value
        case .training: sharing.training = value
        case .journalAnswers: sharing.journalAnswers = value
        case .journalNotes: sharing.journalNotes = value
        case .cycle: sharing.cycle = value
        case .supplements: sharing.supplements = value
        case .labs: sharing.labs = value
        }
    }

    /// A short note for the model naming what it cannot read, so it tells the person instead of guessing.
    /// - Parameter selectedDay: The past day the chat was opened from, when it was not opened on today.
    func instructionNote(today: String, timeZone: TimeZone, selectedDay: String? = nil) -> String {
        var lines = ["Today is \(today) in \(timeZone.identifier)."]
        if let selectedDay {
            lines.append("The person opened this chat from the screen for \(selectedDay), a past day. \"This day\", \"that night\" and \"the day before\" mean \(selectedDay) and the days around it. When you leave `to` out of a tool call, the range ends on \(selectedDay), not today.")
        }
        let blocked = blockedDomains
        if blocked.isEmpty {
            lines.append("Every data domain is available to the tools in this chat.")
        } else {
            lines.append("Not available in this chat: " + blocked.map(\.title).joined(separator: ", ")
                + ". These are off in Your data or not shared in this chat. Do not try to read them. If the person asks about them, say they can turn them on in Your data.")
        }
        return lines.joined(separator: "\n")
    }
}

/// The ways the tools reach saved data, one narrow reader per domain. A reader is handed out only
/// through `AgentReaders`, which checks the gate before the read and again after it, so a switch
/// turned off while the read ran still discards the result.
nonisolated protocol AgentMetricsReading: Sendable {
    func metricSeries(_ key: MetricKey, from: String, to: String) async throws -> [AgentMetricPoint]
}
nonisolated protocol AgentFoodReading: Sendable {
    func foodDays(from: String, to: String) async throws -> [AgentFoodDay]
    /// Body weight readings in the range, oldest first.
    func weightReadings(from: String, to: String) async throws -> [AgentWeightReading]
    /// The goal behind the current food targets, when they came from the planner.
    func goalPlan() async throws -> AgentGoalPlan?
}

extension AgentFoodReading {
    func weightReadings(from: String, to: String) async throws -> [AgentWeightReading] { [] }
    func goalPlan() async throws -> AgentGoalPlan? { nil }
}

nonisolated struct AgentWeightReading: Equatable, Sendable {
    let day: String
    let time: String
    let kilograms: Double
}

nonisolated struct AgentGoalPlan: Equatable, Sendable {
    let goal: String
    let startWeightKg: Double
    let goalWeightKg: Double?
    let paceKgPerWeek: Double
    let activity: String
    let savedOn: String
}
nonisolated protocol AgentTrainingReading: Sendable {
    func trainingEntries(from: String, to: String) async throws -> [AgentTrainingEntry]
    func trainingTemplates() async throws -> [AgentTemplateRow]
}
nonisolated protocol AgentJournalAnswersReading: Sendable {
    func journalDays(from: String, to: String) async throws -> [AgentJournalDay]
}
nonisolated protocol AgentJournalNotesReading: Sendable {
    func journalNotes(from: String, to: String) async throws -> [AgentJournalNote]
}
nonisolated protocol AgentCycleReading: Sendable {
    func cycleRows(from: String, to: String) async throws -> [AgentCycleRow]
}
nonisolated protocol AgentPatternReading: Sendable {
    func visiblePatterns() async throws -> [AgentPatternRow]
}
nonisolated protocol AgentDataSource: AgentMetricsReading, AgentFoodReading, AgentTrainingReading, AgentJournalAnswersReading,
                                      AgentJournalNotesReading, AgentCycleReading, AgentPatternReading,
                                      AgentProtocolReading, AgentSupplementsReading, AgentLabsReading, AgentCapacityReading,
                                      AgentAgesReading {}

nonisolated struct AgentReaders: Sendable {
    let gate: AgentAccessGate
    private let source: any AgentDataSource
    init(gate: AgentAccessGate, source: any AgentDataSource) { self.gate = gate; self.source = source }

    private func guarded<T: Sendable>(_ domain: AgentDataDomain, _ read: () async throws -> T) async throws -> T {
        try gate.check(domain)
        let value = try await read()
        try gate.check(domain)
        return value
    }
    func metrics<T: Sendable>(_ body: (any AgentMetricsReading) async throws -> T) async throws -> T {
        try await guarded(.metrics) { try await body(source) }
    }
    func food<T: Sendable>(_ body: (any AgentFoodReading) async throws -> T) async throws -> T {
        try await guarded(.food) { try await body(source) }
    }
    func training<T: Sendable>(_ body: (any AgentTrainingReading) async throws -> T) async throws -> T {
        try await guarded(.training) { try await body(source) }
    }
    func journalAnswers<T: Sendable>(_ body: (any AgentJournalAnswersReading) async throws -> T) async throws -> T {
        try await guarded(.journalAnswers) { try await body(source) }
    }
    func journalNotes<T: Sendable>(_ body: (any AgentJournalNotesReading) async throws -> T) async throws -> T {
        try await guarded(.journalNotes) { try await body(source) }
    }
    func cycle<T: Sendable>(_ body: (any AgentCycleReading) async throws -> T) async throws -> T {
        try await guarded(.cycle) { try await body(source) }
    }
    // MARK: Longevity reads (LV-09)

    /// Protocol, adherence and experiments sit under Journal answers, which protocols replace.
    func protocolRecords<T: Sendable>(_ body: (any AgentProtocolReading) async throws -> T) async throws -> T {
        try await guarded(.journalAnswers) { try await body(source) }
    }
    /// Experiment results are computed from sleep readings. `bandMetrics` tells the reader whether Band metrics and
    /// sleep is on at the start of the read. A result built with it is discarded when that switch goes off mid-read.
    func experimentRecords<T: Sendable>(_ body: (any AgentProtocolReading, _ bandMetrics: Bool) async throws -> T) async throws -> T {
        let used = gate.isAllowed(.metrics)
        return try await guarded(.journalAnswers) {
            let value = try await body(source, used)
            if used { try gate.check(.metrics) }
            return value
        }
    }
    func supplements<T: Sendable>(_ body: (any AgentSupplementsReading) async throws -> T) async throws -> T {
        try await guarded(.supplements) { try await body(source) }
    }
    func labs<T: Sendable>(_ body: (any AgentLabsReading) async throws -> T) async throws -> T {
        try await guarded(.labs) { try await body(source) }
    }
    /// Capacity results are Training. The weekly dose also reads band zone minutes (Band metrics and sleep) and the
    /// weekly targets in the protocol (Journal answers). Each is used only while its switch is on, and a read that used
    /// one is discarded if that switch goes off before it ends.
    func capacity<T: Sendable>(_ body: (any AgentCapacityReading, _ bandMetrics: Bool, _ protocolTargets: Bool) async throws -> T) async throws -> T {
        let band = gate.isAllowed(.metrics), targets = gate.isAllowed(.journalAnswers)
        return try await guarded(.training) {
            let value = try await body(source, band, targets)
            if band { try gate.check(.metrics) }
            if targets { try gate.check(.journalAnswers) }
            return value
        }
    }
    /// The ages tool reads two domains. Each part goes through its own switch, so one off switch leaves the other part.
    func cardioAge<T: Sendable>(_ body: (any AgentAgesReading) async throws -> T) async throws -> T {
        try await guarded(.metrics) { try await body(source) }
    }
    func bloodAge<T: Sendable>(_ body: (any AgentAgesReading) async throws -> T) async throws -> T {
        try await guarded(.labs) { try await body(source) }
    }

    /// Patterns are derived from health measurements, so they need the metrics switch. Each pattern is
    /// then filtered by the domain of the habit behind it, so a pattern built on food is hidden when Food log is off.
    func patterns(_ body: (any AgentPatternReading) async throws -> [AgentPatternRow]) async throws -> (rows: [AgentPatternRow], hidden: Int) {
        let rows = try await guarded(.metrics) { try await body(source) }
        let allowed = rows.filter { gate.isAllowed($0.exposureDomain) }
        return (allowed, rows.count - allowed.count)
    }
}

// MARK: Plain rows the tools format. They hold no storage types, so tests can supply them directly.

nonisolated struct AgentMetricPoint: Equatable, Sendable {
    let day: String
    let value: Double
}

nonisolated struct AgentFoodItemRow: Equatable, Sendable {
    let name: String
    let amount: Double
    let unit: String
    let energy: Double?
    let estimated: Bool
}

nonisolated struct AgentFoodMealRow: Equatable, Sendable {
    let id: String
    let slot: String
    /// Local `HH:mm`.
    let time: String
    let items: [AgentFoodItemRow]
}

nonisolated struct AgentFoodDay: Equatable, Sendable {
    let day: String
    let meals: [AgentFoodMealRow]
    /// Nil when no item reported energy.
    let energy: Double?
    /// False when some items have no energy value, so `energy` undercounts.
    let energyComplete: Bool
    let protein: Double?
    let carbs: Double?
    let fat: Double?
    let waterMillilitres: Double?
    let caffeineMilligrams: Double?
    let alcoholUnits: Double?
    var fibre: Double? = nil
    var sugar: Double? = nil
    var salt: Double? = nil
    /// True when the person marked the day as fully logged, so missing nutrients are zero, not unknown.
    var completed: Bool = false
    /// The targets in effect that day, as the Food screen shows them. Nil when no target was set yet.
    var targets: AgentFoodTargets? = nil
}

nonisolated struct AgentFoodTargets: Equatable, Sendable {
    /// `lose`, `maintain` or `build`.
    let goal: String
    /// Base target plus the day's training allowance.
    let energy: Double?
    let protein: Double?
    let carbs: Double?
    let fat: Double?
    let waterMillilitres: Double?
    /// The sentence the Food screen shows under the target.
    let reason: String
}

nonisolated struct AgentTrainingEntry: Equatable, Sendable {
    let id: String
    let day: String
    /// `strength` for a logged session, `workout` for a recorded or imported one.
    let kind: String
    let name: String
    let minutes: Int?
    let sets: Int?
    let volumeKg: Double?
    /// A logged session's exercises in order. Empty for recorded workouts.
    var exercises: [AgentTrainingExercise] = []
}

nonisolated struct AgentTrainingExercise: Equatable, Sendable {
    struct SetRow: Equatable, Sendable {
        let loadKg: Double?
        let reps: Int
        let rpe: Double?
    }
    let name: String
    let sets: [SetRow]
    /// Epley estimate of the best set. Nil without a loaded set.
    let estimatedOneRepMaxKg: Double?
}

nonisolated struct AgentTemplateRow: Equatable, Sendable {
    struct Exercise: Equatable, Sendable {
        let index: Int
        let name: String
        let sets: Int
        let repsMin: Int
        let repsMax: Int
        let loadKg: Double?
        let restSeconds: Int
    }
    let id: String
    let name: String
    let revision: Int
    let kind: String
    let exercises: [Exercise]
}

nonisolated struct AgentJournalDay: Equatable, Sendable {
    struct Answer: Equatable, Sendable { let name: String; let answer: String }
    let day: String
    let answers: [Answer]
    let behaviors: [String]
    let tags: [String]
}

nonisolated struct AgentJournalNote: Equatable, Sendable {
    let id: String
    let day: String
    let text: String
}

nonisolated struct AgentCycleRow: Equatable, Sendable {
    let id: String
    let day: String
    let kind: String
    let flow: String?
    let symptoms: [String]
    let note: String?
}

nonisolated struct AgentPatternRow: Equatable, Sendable {
    let candidateID: String
    let title: String
    let metric: String
    let strength: String
    /// Difference with the exposure, in `unit`.
    let difference: Double
    let unit: String
    let nightsWith: Int
    let nightsWithout: Int
    let windowEnd: String
    /// The domain of what the pattern is about, besides the outcome metric.
    let exposureDomain: AgentDataDomain
}
