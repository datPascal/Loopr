import DomainKit
import Foundation

public enum PatternCandidateKind: String, Codable, CaseIterable, Sendable {
    case journalHabit, food, trainingDay, legDay, steps
}

/// What makes a day an exposed day. Descriptive only; the app evaluates it and
/// passes the resulting yes/no answers through `PatternExposureProvider`.
public enum PatternPredicate: Codable, Equatable, Hashable, Sendable {
    /// The person answered Yes to a journal question.
    case journalAnswer(name: String)
    /// A food-derived exposure. `label` finishes "after ...", for example "a late dinner". A label that starts with
    /// "when " stands on its own, for example "when you eat after 21:00".
    case food(label: String)
    case trainingDay
    case legDay
    case stepsOver(Int)

    private enum CodingKeys: String, CodingKey { case kind, text, threshold }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? "journalAnswer"
        let text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        switch kind {
        case "food": self = .food(label: text)
        case "trainingDay": self = .trainingDay
        case "legDay": self = .legDay
        case "stepsOver": self = .stepsOver(try container.decodeIfPresent(Int.self, forKey: .threshold) ?? 10_000)
        default: self = .journalAnswer(name: text)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .journalAnswer(let name):
            try container.encode("journalAnswer", forKey: .kind); try container.encode(name, forKey: .text)
        case .food(let label):
            try container.encode("food", forKey: .kind); try container.encode(label, forKey: .text)
        case .trainingDay: try container.encode("trainingDay", forKey: .kind)
        case .legDay: try container.encode("legDay", forKey: .kind)
        case .stepsOver(let threshold):
            try container.encode("stepsOver", forKey: .kind); try container.encode(threshold, forKey: .threshold)
        }
    }

    /// Finishes "... on nights after X". Observational wording only.
    public var nightPhrase: String {
        switch self {
        case .journalAnswer(let name): "you logged \(name.lowercased())"
        case .food(let label): label
        case .trainingDay: "a training day"
        case .legDay: "a leg day"
        case .stepsOver(let threshold): "a day over \(Self.grouped(threshold)) steps"
        }
    }

    /// The phrase that follows "nights" or a metric: "after a leg day", "when you eat after 21:00".
    public var clause: String {
        if case .food(let label) = self, label.hasPrefix("when ") { return label }
        return "after \(nightPhrase)"
    }

    /// The clause for counts that already happened: "when you ate after 21:00". Other clauses are already past tense.
    public var pastClause: String {
        let now = clause
        for (present, past) in [("when you eat ", "when you ate "), ("when you drink ", "when you drank "), ("when you have ", "when you had ")]
            where now.hasPrefix(present) {
            return past + now.dropFirst(present.count)
        }
        return now
    }

    /// The question a test asks for each day.
    public var question: String {
        switch self {
        case .journalAnswer(let name): "Did you log \(name.lowercased())?"
        case .food(let label): label.hasPrefix("when you ") ? "Did you \(label.dropFirst("when you ".count))?" : "Was there \(label)?"
        case .trainingDay: "Did you train?"
        case .legDay: "Was it a leg day?"
        case .stepsOver(let threshold): "Did you pass \(Self.grouped(threshold)) steps?"
        }
    }

    static func grouped(_ value: Int) -> String {
        let digits = String(abs(value))
        var output = ""
        for (offset, character) in digits.reversed().enumerated() {
            if offset > 0, offset.isMultiple(of: 3) { output.append(",") }
            output.append(character)
        }
        return (value < 0 ? "-" : "") + String(output.reversed())
    }
}

/// A fixed exposure that Loopr can look for. `habitID` is stable across runs so
/// stored results keep pointing at the same candidate.
public struct PatternCandidate: Codable, Equatable, Hashable, Identifiable, Sendable {
    /// Stable string key used in stored document keys, for example
    /// `journal.<uuid>`, `food.lateMeal`, `training`, `legDay`, `steps10k`.
    public let id: String
    public let habitID: HabitID
    public let kind: PatternCandidateKind
    public let predicate: PatternPredicate
    public let title: String
    /// Outcome metrics Loopr looks at for this exposure, first is the default.
    public let targetMetrics: [HabitOutcomeMetricID]
    public var targetMetric: HabitOutcomeMetricID { targetMetrics.first ?? .sleepScore }

    public init(id: String, habitID: HabitID, kind: PatternCandidateKind, predicate: PatternPredicate,
                title: String, targetMetrics: [HabitOutcomeMetricID]) {
        self.id = id
        self.habitID = habitID
        self.kind = kind
        self.predicate = predicate
        self.title = title
        self.targetMetrics = targetMetrics.isEmpty ? [.sleepScore] : targetMetrics
    }

    public init(id: String, habitID: HabitID, kind: PatternCandidateKind, predicate: PatternPredicate,
                title: String, targetMetric: HabitOutcomeMetricID) {
        self.init(id: id, habitID: habitID, kind: kind, predicate: predicate, title: title, targetMetrics: [targetMetric])
    }

    private enum CodingKeys: String, CodingKey { case id, habitID, kind, predicate, title, targetMetrics, targetMetric }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(String.self, forKey: .id)
        let metrics = try container.decodeIfPresent([HabitOutcomeMetricID].self, forKey: .targetMetrics)
            ?? (try container.decodeIfPresent(HabitOutcomeMetricID.self, forKey: .targetMetric)).map { [$0] } ?? []
        self.init(
            id: id,
            habitID: try container.decode(HabitID.self, forKey: .habitID),
            kind: try container.decodeIfPresent(PatternCandidateKind.self, forKey: .kind) ?? .journalHabit,
            predicate: try container.decodeIfPresent(PatternPredicate.self, forKey: .predicate) ?? .journalAnswer(name: ""),
            title: try container.decodeIfPresent(String.self, forKey: .title) ?? id,
            targetMetrics: metrics
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(habitID, forKey: .habitID)
        try container.encode(kind, forKey: .kind)
        try container.encode(predicate, forKey: .predicate)
        try container.encode(title, forKey: .title)
        try container.encode(targetMetrics, forKey: .targetMetrics)
    }

    func definition(sortOrder: Int, at date: Date) -> HabitDefinition {
        HabitDefinition(id: habitID, source: .custom, name: title, question: predicate.question,
                        sortOrder: sortOrder, createdAt: date)
    }
}

public extension PatternCandidate {
    // Fixed identifiers. FoodKit's own exposures use the FC10... range; these
    // built-ins use FC20... so they never collide.
    static let trainingDay = PatternCandidate(
        id: "training", habitID: .init(rawValue: UUID(uuidString: "FC200000-0000-4000-8000-000000000001")!),
        kind: .trainingDay, predicate: .trainingDay, title: "Training day",
        targetMetrics: [.sleepScore, .deepSleepMinutes, .hrvRMSSD, .restingHeartRate])
    static let legDay = PatternCandidate(
        id: "legDay", habitID: .init(rawValue: UUID(uuidString: "FC200000-0000-4000-8000-000000000002")!),
        kind: .legDay, predicate: .legDay, title: "Leg day",
        targetMetrics: [.deepSleepMinutes, .restingHeartRate, .sleepScore])
    static func steps(over threshold: Int = PatternPolicy.default.stepsThreshold) -> PatternCandidate {
        PatternCandidate(
            id: "steps\(threshold / 1000)k",
            habitID: .init(rawValue: UUID(uuidString: "FC200000-0000-4000-8000-000000000003")!),
            kind: .steps, predicate: .stepsOver(threshold), title: "Over \(PatternPredicate.grouped(threshold)) steps",
            targetMetrics: [.sleepScore, .sleepDuration, .recoveryScore])
    }

    static func journalHabit(_ definition: HabitDefinition,
                             metrics: [HabitOutcomeMetricID] = [.sleepScore, .hrvRMSSD, .recoveryScore, .deepSleepMinutes]) -> PatternCandidate {
        PatternCandidate(id: "journal.\(definition.id.rawValue.uuidString)", habitID: definition.id, kind: .journalHabit,
                         predicate: .journalAnswer(name: definition.name), title: definition.name, targetMetrics: metrics)
    }

    /// An exposure derived from food records. The app supplies the answers, so
    /// JournalKit never imports FoodKit. Pass FoodKit's own habit identifier.
    static func food(id: String, habitID: HabitID, title: String, label: String,
                     metrics: [HabitOutcomeMetricID]) -> PatternCandidate {
        PatternCandidate(id: "food.\(id)", habitID: habitID, kind: .food, predicate: .food(label: label),
                         title: title, targetMetrics: metrics)
    }

    /// Journal habits that are active and answer Yes or No, then food exposures,
    /// then training day, leg day and steps. Duplicate habit identifiers keep the first.
    static func catalog(journalHabits: [HabitDefinition], food: [PatternCandidate] = [],
                        policy: PatternPolicy = .default) -> [PatternCandidate] {
        let habits = journalHabits.filter { !$0.isArchived && $0.responseKind == .binary }
            .sorted { ($0.sortOrder, $0.id) < ($1.sortOrder, $1.id) }
            .map { journalHabit($0) }
        var seen = Set<HabitID>()
        return (habits + food + [.trainingDay, .legDay, .steps(over: policy.stepsThreshold)])
            .filter { seen.insert($0.habitID).inserted }
    }
}
