import Foundation
import DomainKit
import DesignSystem
import TodayKit

public enum CoachEvidenceID: String, Codable, CaseIterable, Hashable, Sendable {
    case readiness
    case sleep
    case strain
    case stress
    case goal

    public var displayName: String {
        switch self {
        case .readiness: "readiness"
        case .sleep: "sleep"
        case .strain: "strain"
        case .stress: "stress"
        case .goal: "goal progress"
        }
    }
}

public struct CoachEvidence: Codable, Equatable, Sendable, Identifiable {
    public let id: CoachEvidenceID
    public let label: String
    public let value: Double?
    public let unit: String
    public let state: MetricState
    public let confidence: Double
    public let source: String
    public let detail: String

    public init(
        id: CoachEvidenceID,
        label: String,
        value: Double?,
        unit: String,
        state: MetricState,
        confidence: Double,
        source: String,
        detail: String
    ) {
        self.id = id
        self.label = label
        self.value = value
        self.unit = unit
        self.state = state
        self.confidence = confidence
        self.source = source
        self.detail = detail
    }

    public var isUsable: Bool {
        guard value != nil else { return false }
        guard confidence >= 0.5 else { return false }
        switch state {
        case .absent, .noRecords, .loading, .permissionDenied, .unsupportedHardware, .recoverableError, .destructiveFailure, .bluetoothOff, .disconnected:
            return false
        case .measuredZero, .partial, .lowConfidence, .settling, .stale:
            return state != .lowConfidence
        }
    }

    public var accessibilitySummary: String {
        guard let value else { return "\(label). \(state.title). \(state.detail)" }
        return "\(label), \(value.formatted()) \(unit), \(Int(confidence * 100)) percent confidence. \(detail)"
    }
}

public struct CoachGoal: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let target: Double?
    public let unit: String
    public let progress: Double?
    public let state: MetricState

    public init(id: String, title: String, target: Double?, unit: String, progress: Double?, state: MetricState) {
        self.id = id
        self.title = title
        self.target = target
        self.unit = unit
        self.progress = progress
        self.state = state
    }
}

public struct CoachInput: Codable, Equatable, Sendable {
    public let day: DayIdentity
    public let generatedAt: Date
    public let evidence: [CoachEvidence]
    public let goals: [CoachGoal]

    public init(day: DayIdentity, generatedAt: Date, evidence: [CoachEvidence], goals: [CoachGoal] = []) {
        self.day = day
        self.generatedAt = generatedAt
        self.evidence = evidence
        self.goals = goals
    }

    public func evidence(_ id: CoachEvidenceID) -> CoachEvidence? { evidence.first { $0.id == id } }
}

public enum CoachRecommendationKind: String, CaseIterable, Codable, Sendable {
    case rest
    case sleep
    case recovery
    case load
    case workout

    public var displayName: String {
        switch self {
        case .rest: "Rest"
        case .sleep: "Sleep"
        case .recovery: "Recovery"
        case .load: "Training load"
        case .workout: "Workout"
        }
    }
}

public struct CoachRecommendation: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let kind: CoachRecommendationKind
    public let title: String
    public let detail: String
    public let evidence: [CoachEvidenceID]
    public let confidence: Double
    public let downgraded: Bool

    public init(id: String, kind: CoachRecommendationKind, title: String, detail: String, evidence: [CoachEvidenceID], confidence: Double, downgraded: Bool = false) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.evidence = evidence
        self.confidence = confidence
        self.downgraded = downgraded
    }
}

public struct CoachPlan: Codable, Equatable, Sendable {
    public let day: DayIdentity
    public let generatedAt: Date
    public let recommendations: [CoachRecommendation]
    public let evidence: [CoachEvidence]
    public let algorithmVersion: String

    public init(day: DayIdentity, generatedAt: Date, recommendations: [CoachRecommendation], evidence: [CoachEvidence], algorithmVersion: String = CoachRuleEngine.algorithmVersion) {
        self.day = day
        self.generatedAt = generatedAt
        self.recommendations = recommendations
        self.evidence = evidence
        self.algorithmVersion = algorithmVersion
    }

    public var summary: TodayCoachPlanSummary {
        TodayCoachPlanSummary(
            title: recommendations.first?.title ?? "No recommendation today",
            detail: recommendations.first?.detail ?? "The local coach is abstaining until required evidence is available.",
            recommendationCount: recommendations.count,
            evidenceSummary: evidence.filter(\.isUsable).map(\.label).joined(separator: ", "),
            state: recommendations.isEmpty ? .absent : .partial
        )
    }
}

public struct CoachAbstention: Codable, Equatable, Sendable {
    public let reason: String
    public let missingEvidence: [CoachEvidenceID]

    public init(reason: String, missingEvidence: [CoachEvidenceID]) {
        self.reason = reason
        self.missingEvidence = missingEvidence
    }
}

public enum CoachDecision: Codable, Equatable, Sendable {
    case plan(CoachPlan)
    case abstain(CoachAbstention)

    private enum CodingKeys: String, CodingKey { case kind, plan, abstention }
    private enum Kind: String, Codable { case plan, abstain }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .plan: self = .plan(try container.decode(CoachPlan.self, forKey: .plan))
        case .abstain: self = .abstain(try container.decode(CoachAbstention.self, forKey: .abstention))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .plan(let plan):
            try container.encode(Kind.plan, forKey: .kind)
            try container.encode(plan, forKey: .plan)
        case .abstain(let abstention):
            try container.encode(Kind.abstain, forKey: .kind)
            try container.encode(abstention, forKey: .abstention)
        }
    }

    public var plan: CoachPlan? {
        if case .plan(let plan) = self { return plan }
        return nil
    }
}

public protocol CoachInputRepository: Sendable {
    func readInput(for day: DayIdentity) async throws -> CoachInput?
}

public protocol CoachRecommendationHistoryRepository: Sendable {
    func save(_ decision: CoachDecision, for day: DayIdentity) async throws
    func read(for day: DayIdentity) async throws -> CoachDecision?
    func readRecent(limit: Int) async throws -> [CoachDecision]
    func deleteAll() async throws
}

public actor InMemoryCoachRecommendationHistoryRepository: CoachRecommendationHistoryRepository {
    private var values: [DayIdentity: CoachDecision] = [:]

    public init(values: [DayIdentity: CoachDecision] = [:]) { self.values = values }

    public func save(_ decision: CoachDecision, for day: DayIdentity) async throws { values[day] = decision }
    public func read(for day: DayIdentity) async throws -> CoachDecision? { values[day] }
    public func readRecent(limit: Int) async throws -> [CoachDecision] {
        guard limit > 0 else { return [] }
        return values.keys.sorted { lhs, rhs in
            let left = lhs.year * 10_000 + lhs.month * 100 + lhs.day
            let right = rhs.year * 10_000 + rhs.month * 100 + rhs.day
            return left > right
        }.prefix(limit).compactMap { values[$0] }
    }
    public func deleteAll() async throws { values.removeAll(keepingCapacity: true) }
}

public actor InMemoryCoachInputRepository: CoachInputRepository {
    private var values: [DayIdentity: CoachInput]

    public init(values: [DayIdentity: CoachInput] = [:]) { self.values = values }
    public func readInput(for day: DayIdentity) async throws -> CoachInput? { values[day] }
    public func replace(_ input: CoachInput, for day: DayIdentity) { values[day] = input }
}

/// Adapter consumed by TodayKit's APP-03B plan-refresh seam.  The adapter is
/// deliberately read-only from Today: mutations happen only in CoachService.
public actor CoachTodayPlanRepository: TodayCoachPlanRepository {
    private var plans: [DayIdentity: TodayCoachPlanSummary] = [:]

    public init(plans: [DayIdentity: TodayCoachPlanSummary] = [:]) { self.plans = plans }
    public func readPlan(for day: DayIdentity) async throws -> TodayCoachPlanSummary? { plans[day] }
    public func replace(_ plan: TodayCoachPlanSummary, for day: DayIdentity) { plans[day] = plan }
    public func replace(_ decision: CoachDecision, for day: DayIdentity) {
        switch decision {
        case .plan(let plan): plans[day] = plan.summary
        case .abstain(let abstention):
            plans[day] = TodayCoachPlanSummary(title: "No plan yet", detail: abstention.reason, recommendationCount: 0, evidenceSummary: abstention.missingEvidence.map(\.displayName).joined(separator: ", "), state: .absent)
        }
    }
}
