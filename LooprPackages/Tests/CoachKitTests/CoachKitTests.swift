import Foundation
import Testing
import DomainKit
import DesignSystem
import TodayKit
@testable import CoachKit

struct CoachKitTests {
    @Test
    func allFourteenStateFixturesAreSafeAndAbsentEvidenceNeverBecomesRecommendation() {
        #expect(CoachFixtures.allStates.count == 14)
        let engine = CoachRuleEngine()
        for fixture in CoachFixtures.allStates {
            let decision = engine.evaluate(fixture.input)
            switch fixture.state {
            case .absent, .noRecords, .loading, .permissionDenied, .unsupportedHardware, .recoverableError, .destructiveFailure, .bluetoothOff, .disconnected, .lowConfidence:
                guard case .abstain = decision else {
                    Issue.record("Expected abstention for (fixture.state.rawValue)")
                    continue
                }
            default:
                break
            }
        }
    }

    @Test
    func completeEvidenceProducesStablePlanAndEvidenceLinks() {
        let engine = CoachRuleEngine()
        let first = engine.evaluate(CoachFixtures.completeInput)
        let second = engine.evaluate(CoachFixtures.completeInput)
        #expect(first == second)
        guard case .plan(let plan) = first else {
            Issue.record("Expected a plan from complete evidence")
            return
        }
        #expect(plan.algorithmVersion == CoachRuleEngine.algorithmVersion)
        #expect(!plan.recommendations.isEmpty)
        #expect(plan.recommendations.allSatisfy { !$0.evidence.isEmpty })
        #expect(plan.summary.recommendationCount == plan.recommendations.count)
    }

    @Test
    func lowReadinessAndOverreachingGuardSuppressesWorkout() {
        let input = CoachFixtures.completeInput.replacing(readiness: 30, strain: 19)
        let decision = CoachRuleEngine().evaluate(input)
        guard case .plan(let plan) = decision else {
            Issue.record("Expected guarded recovery plan")
            return
        }
        #expect(plan.recommendations.first?.kind == .rest)
        #expect(plan.recommendations.contains { $0.kind != .workout })
        #expect(!plan.recommendations.contains { $0.kind == .workout })
    }

    @Test
    func sleepDebtAddsSleepRecommendationWithoutChangingPrimaryOrder() {
        let input = CoachFixtures.completeInput.replacing(sleep: 5.5)
        guard case .plan(let plan) = CoachRuleEngine().evaluate(input) else {
            Issue.record("Expected sleep-aware plan")
            return
        }
        #expect(plan.recommendations.first?.kind == .workout)
        #expect(plan.recommendations.contains { $0.kind == .sleep })
    }

    @Test
    func servicePersistsPlanAndSupportsDeletion() async throws {
        let inputRepository = InMemoryCoachInputRepository(values: [CoachFixtures.day: CoachFixtures.completeInput])
        let history = InMemoryCoachRecommendationHistoryRepository()
        let service = CoachService(inputs: inputRepository, history: history)

        let decision = try await service.evaluate(for: CoachFixtures.day)
        #expect(try await service.historyForDay(CoachFixtures.day) == decision)
        #expect((try await service.recentHistory(limit: 10)).count == 1)
        try await service.deleteAllData()
        #expect(try await service.historyForDay(CoachFixtures.day) == nil)
    }

    @Test
    func todayAdapterPreservesAbstentionAsAbsent() async throws {
        let adapter = CoachTodayPlanRepository()
        let abstention: CoachDecision = .abstain(CoachAbstention(reason: "Waiting", missingEvidence: [.readiness]))
        await adapter.replace(abstention, for: CoachFixtures.day)
        let plan = try await adapter.readPlan(for: CoachFixtures.day)
        #expect(plan?.state == .absent)
        #expect(plan?.recommendationCount == 0)
        #expect(plan?.detail == "Waiting")
    }

    @Test @MainActor
    func coachScreenConstructsFromViewModel() {
        let inputRepository = InMemoryCoachInputRepository(values: [CoachFixtures.day: CoachFixtures.completeInput])
        let history = InMemoryCoachRecommendationHistoryRepository()
        let service = CoachService(inputs: inputRepository, history: history)
        let viewModel = CoachViewModel(service: service)
        _ = CoachScreen(viewModel: viewModel)
        #expect(viewModel.loadState == .idle)
    }
}

private extension CoachInput {
    func replacing(readiness: Double? = nil, sleep: Double? = nil, strain: Double? = nil) -> CoachInput {
        let replacements: [CoachEvidenceID: Double?] = [
            .readiness: readiness,
            .sleep: sleep,
            .strain: strain
        ]
        let evidence = self.evidence.map { item in
            guard let replacement = replacements[item.id], replacement != nil else { return item }
            return CoachEvidence(id: item.id, label: item.label, value: replacement!, unit: item.unit, state: item.state, confidence: item.confidence, source: item.source, detail: item.detail)
        }
        return CoachInput(day: day, generatedAt: generatedAt, evidence: evidence, goals: goals)
    }
}
