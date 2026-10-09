import Foundation
import DomainKit
import DesignSystem

public enum CoachFixtures {
    public static let day = DayIdentity(year: 2023, month: 11, day: 14)

    public static func input(for state: MetricState) -> CoachInput {
        let value: Double? = switch state {
        case .measuredZero: 0
        case .partial, .stale, .settling: 72
        default: nil
        }
        let confidence = state == .lowConfidence ? 0.2 : value == nil ? 0 : 0.9
        let evidence = [
            CoachEvidence(id: .readiness, label: "Readiness", value: value, unit: "%", state: state, confidence: confidence, source: "fixture.readiness", detail: state.detail),
            CoachEvidence(id: .sleep, label: "Sleep", value: value == nil ? nil : 7.5, unit: "hours", state: state, confidence: confidence, source: "fixture.sleep", detail: state.detail),
            CoachEvidence(id: .strain, label: "Strain", value: value == nil ? nil : 8, unit: "score", state: state, confidence: confidence, source: "fixture.strain", detail: state.detail),
            CoachEvidence(id: .stress, label: "Stress", value: value == nil ? nil : 20, unit: "index", state: state, confidence: confidence, source: "fixture.stress", detail: state.detail)
        ]
        return CoachInput(day: day, generatedAt: Date(timeIntervalSince1970: 1_700_000_000), evidence: evidence, goals: [CoachGoal(id: "movement", title: "30 minutes of movement", target: 30, unit: "minutes", progress: 0.5, state: state)])
    }

    public static var allStates: [(state: MetricState, input: CoachInput)] {
        MetricState.allCases.map { (state: $0, input: input(for: $0)) }
    }

    public static var completeInput: CoachInput {
        CoachInput(
            day: day,
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            evidence: [
                CoachEvidence(id: .readiness, label: "Readiness", value: 82, unit: "%", state: .partial, confidence: 0.95, source: "ANA-08.readiness", detail: "High confidence"),
                CoachEvidence(id: .sleep, label: "Sleep", value: 7.5, unit: "hours", state: .partial, confidence: 0.92, source: "ANA-03.sleep", detail: "High confidence"),
                CoachEvidence(id: .strain, label: "Strain", value: 8, unit: "score", state: .partial, confidence: 0.9, source: "ANA-05.strain", detail: "High confidence"),
                CoachEvidence(id: .stress, label: "Stress", value: 22, unit: "index", state: .partial, confidence: 0.85, source: "ANA-04.stress", detail: "High confidence")
            ],
            goals: [CoachGoal(id: "movement", title: "30 minutes of movement", target: 30, unit: "minutes", progress: 0.5, state: .partial)]
        )
    }
}
