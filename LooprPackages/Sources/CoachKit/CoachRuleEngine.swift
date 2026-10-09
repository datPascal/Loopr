import Foundation
import DomainKit

/// Pure, deterministic local-coach rules.  It never reads a clock, database,
/// random source, or network.  All values are supplied as canonical evidence.
public struct CoachRuleEngine: Sendable {
    public static let algorithmVersion = "coach.local.v1"

    public init() {}

    public func evaluate(_ input: CoachInput) -> CoachDecision {
        let required: [CoachEvidenceID] = [.readiness, .sleep, .strain]
        let missing = required.filter { input.evidence($0)?.isUsable != true }
        guard missing.isEmpty else {
            return .abstain(CoachAbstention(
                reason: "The local coach is waiting for reliable \(missing.map(\.displayName).joined(separator: ", ").lowercased()) data.",
                missingEvidence: missing
            ))
        }

        guard let readiness = input.evidence(.readiness)?.value,
              let sleep = input.evidence(.sleep)?.value,
              let strain = input.evidence(.strain)?.value else {
            return .abstain(CoachAbstention(reason: "Required evidence is absent.", missingEvidence: required))
        }

        let stress = input.evidence(.stress)
        let stressValue = stress?.isUsable == true ? stress?.value : nil
        var recommendations: [CoachRecommendation] = []

        // Rest and overreaching guards run before activity suggestions.  They
        // never fabricate a score; they only suppress or downgrade a plan.
        if readiness < 40 || strain >= 18 || (stressValue ?? 0) >= 80 {
            let evidence = evidenceIDs(readiness: input, stress: stressValue != nil, strain: true)
            recommendations.append(CoachRecommendation(
                id: "\(input.day.year)-\(input.day.month)-\(input.day.day)-rest",
                kind: .rest,
                title: "Prioritize recovery",
                detail: "Take a restorative day. The plan is guarded by low readiness or high recent load.",
                evidence: evidence,
                confidence: confidence(for: input, ids: evidence)
            ))
        } else if readiness < 60 {
            recommendations.append(CoachRecommendation(
                id: "\(input.day.year)-\(input.day.month)-\(input.day.day)-reduced",
                kind: .recovery,
                title: "Choose an easy session",
                detail: "Keep intensity conversational and stop if recovery feels worse.",
                evidence: [.readiness, .sleep, .strain],
                confidence: confidence(for: input, ids: [.readiness, .sleep, .strain]),
                downgraded: true
            ))
        } else {
            recommendations.append(CoachRecommendation(
                id: "\(input.day.year)-\(input.day.month)-\(input.day.day)-workout",
                kind: .workout,
                title: workoutTitle(for: input.goals),
                detail: "Evidence supports your planned movement. Keep the session aligned with your goal.",
                evidence: [.readiness, .sleep, .strain],
                confidence: confidence(for: input, ids: [.readiness, .sleep, .strain])
            ))
        }

        if sleep < 7 {
            recommendations.append(CoachRecommendation(
                id: "\(input.day.year)-\(input.day.month)-\(input.day.day)-sleep",
                kind: .sleep,
                title: "Protect tonight's sleep",
                detail: "Your sleep evidence is below seven hours; an earlier wind-down supports recovery.",
                evidence: [.sleep, .readiness],
                confidence: confidence(for: input, ids: [.sleep, .readiness]),
                downgraded: true
            ))
        }

        return .plan(CoachPlan(day: input.day, generatedAt: input.generatedAt, recommendations: recommendations, evidence: input.evidence))
    }

    private func evidenceIDs(readiness input: CoachInput, stress: Bool, strain: Bool) -> [CoachEvidenceID] {
        var ids: [CoachEvidenceID] = [.readiness]
        if input.evidence(.sleep)?.isUsable == true { ids.append(.sleep) }
        if strain { ids.append(.strain) }
        if stress { ids.append(.stress) }
        return ids
    }

    private func confidence(for input: CoachInput, ids: [CoachEvidenceID]) -> Double {
        let values = ids.compactMap { input.evidence($0)?.confidence }
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    private func workoutTitle(for goals: [CoachGoal]) -> String {
        guard let goal = goals.first(where: { $0.state != .absent && $0.state != .noRecords }) else { return "Follow your movement plan" }
        return "Work toward \(goal.title)"
    }
}

public actor CoachService {
    private let engine: CoachRuleEngine
    private let inputs: any CoachInputRepository
    private let history: any CoachRecommendationHistoryRepository

    public init(
        engine: CoachRuleEngine = CoachRuleEngine(),
        inputs: any CoachInputRepository,
        history: any CoachRecommendationHistoryRepository
    ) {
        self.engine = engine
        self.inputs = inputs
        self.history = history
    }

    public func evaluate(for day: DayIdentity) async throws -> CoachDecision {
        guard let input = try await inputs.readInput(for: day) else {
            let decision: CoachDecision = .abstain(CoachAbstention(reason: "There is not enough reliable data yet.", missingEvidence: [.readiness, .sleep, .strain]))
            try await history.save(decision, for: day)
            return decision
        }
        let decision = engine.evaluate(input)
        try await history.save(decision, for: day)
        return decision
    }

    public func historyForDay(_ day: DayIdentity) async throws -> CoachDecision? { try await history.read(for: day) }
    public func recentHistory(limit: Int = 30) async throws -> [CoachDecision] { try await history.readRecent(limit: limit) }
    public func deleteAllData() async throws { try await history.deleteAll() }
}
