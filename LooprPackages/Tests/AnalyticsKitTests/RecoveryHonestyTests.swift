import Foundation
import Testing
@testable import AnalyticsKit

struct RecoveryHonestyTests {
    @Test func absentRecoveryKeepsTheNewAlgorithmProvenance() async throws {
        let result = try await WellnessAnalytics.derive(.init())
        #expect(result.readiness.value == nil)
        #expect(result.readiness.algorithmVersion == WellnessAlgorithm.readinessVersion)
        #expect(result.stress.algorithmVersion == WellnessAlgorithm.version)
    }
    @Test func countdownRequiresHistoryForTwoInputs() {
        let result = WellnessAnalytics.readinessComposite([
            .hrv(log(60), baseline: [45, 50].map(log)),
            .respiration(15, baseline: [])
        ])
        #expect(result.value == nil)
        #expect(result.note == "need_baseline:have=0,need=3")
    }
    @Test func versionedTypedParityFixtureKeepsItsIndependentReference() throws {
        let input = #"{"metric":"readinessComposite","inputs":[{"label":"HRV","metric":{"value":48.0},"baseline":[45,46,47,48],"good_sign":1,"weight":0.4},{"label":"RHR","metric":{"value":57.0},"baseline":[54,56,58,55],"good_sign":-1,"weight":0.3}]}"#.data(using: .utf8)!
        let output = try AnalyticsParityRunner.run(inputData: input)
        let json = try #require(JSONSerialization.jsonObject(with: output) as? [String: Any])
        let value = try #require(json["value"] as? [String: Any])
        #expect(json["algorithm_version"] as? String == WellnessAlgorithm.readinessVersion)
        // DEC-02.9 compares canonical six-decimal values exactly. JSON
        // decoding must not turn a binary representation into a new tolerance.
        let score = try #require(value["score"] as? Double)
        let composite = try #require(value["composite_z"] as? Double)
        #expect(String(format: "%.6f", score) == "52.409105")
        #expect(String(format: "%.6f", composite) == "0.096439")
        #expect(json["inputs_used"] as? [String] == ["HRV", "RHR"])
    }

    @Test func oneInputCannotBecomeAHeadline() {
        let result = WellnessAnalytics.readinessComposite([.hrv(log(60), baseline: [45, 50, 55].map(log))])
        #expect(!result.present)
        #expect(result.algorithmVersion == WellnessAlgorithm.readinessVersion)
    }
    @Test func duplicateLabelsAndZeroWeightsCannotMeetTheGate() {
        let hrv = ReadinessInput.hrv(log(60), baseline: [45, 50, 55].map(log))
        #expect(!WellnessAnalytics.readinessComposite([hrv, hrv]).present)
        #expect(!WellnessAnalytics.readinessComposite([hrv, .init(label: "RR", value: 14, baseline: [14, 15, 16], goodSign: -1, weight: 0)]).present)
    }
    @Test func subQuantumRhrWithPositiveMadCannotDominate() {
        let input = ReadinessInput.restingHeartRate(52, baseline: [58, 58, 59])
        #expect(WellnessAnalytics.readinessZ(input) == nil)
        let split = WellnessAnalytics.recoveryDecomposition([
            .init(signal: .hrv, value: 60, baseline: [45, 50, 55]),
            .init(signal: .restingHeartRate, value: 52, baseline: [58, 58, 59]),
            .init(signal: .respiratoryRate, value: 14.8, baseline: [14.5, 14.8, 15.1])
        ])
        #expect(split.share(.restingHeartRate)?.status == .flatBaseline)
        #expect(split.score != nil)
        #expect(split.share(.restingHeartRate)?.points == nil)
    }
    @Test func earlyNearFlatHistoriesDoNotRail() throws {
        for (hrv, rr, expected) in [(60.0, 14.0, 68.01662880329852), (40, 16, 29.657993491262364)] {
            let result = WellnessAnalytics.readinessComposite([
                .hrv(log(hrv), baseline: [50, 50.1, 49.9].map(log)),
                .respiration(rr, baseline: [14.95, 15, 15.05])
            ])
            let score = try #require(WellnessAnalytics.headlineReadinessScore(result))
            #expect(score > 5 && score < 95)
            // Independent numerical reference, not a relaxed parity tolerance.
            #expect(abs(score - expected) < 1e-9)
        }
    }
    @Test func extremeChangesAreStillWithheldAndFlatInputsAreAbsent() {
        let extreme = WellnessAnalytics.readinessComposite([
            .hrv(log(250), baseline: [50, 50.1, 49.9].map(log)),
            .respiration(5, baseline: [14.95, 15, 15.05])
        ])
        #expect(extreme.present)
        #expect(WellnessAnalytics.headlineReadinessScore(extreme) == nil)
        #expect(!WellnessAnalytics.readinessComposite([
            .hrv(log(50), baseline: Array(repeating: log(50), count: 14)),
            .respiration(15, baseline: Array(repeating: 15, count: 14))
        ]).present)
    }
}
