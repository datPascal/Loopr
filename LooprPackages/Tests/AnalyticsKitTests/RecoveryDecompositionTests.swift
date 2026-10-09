import Foundation
import Testing
@testable import AnalyticsKit

/// The recovery split must be the formula's own: same score, same terms,
/// points that add up, and honest statuses for signals that did not count.
struct RecoveryDecompositionTests {
    private let hrvNights: [Double] = [44, 48, 51, 53, 50, 47, 55, 49, 52, 46]
    private let rhrNights: [Double] = [55, 54, 56, 53, 55, 54, 57, 55, 54, 56]
    private let rrNights: [Double] = [14.6, 14.8, 14.7, 14.9, 14.5, 14.7, 14.8, 14.6, 14.7, 14.9]

    private func readings(hrv: Double? = 58, rhr: Double? = 51, rr: Double? = 14.6) -> [RecoverySignalReading] {
        [
            RecoverySignalReading(signal: .hrv, value: hrv, baseline: hrvNights),
            RecoverySignalReading(signal: .restingHeartRate, value: rhr, baseline: rhrNights),
            RecoverySignalReading(signal: .respiratoryRate, value: rr, baseline: rrNights)
        ]
    }

    @Test func scoreMatchesTheTodayFormulaExactly() throws {
        let split = WellnessAnalytics.recoveryDecomposition(readings())
        // The Today score, built the way CanonicalDailyAnalytics builds it.
        let composite = WellnessAnalytics.readinessComposite([
            .hrv(log(58), baseline: hrvNights.map { log($0) }),
            .restingHeartRate(51, baseline: rhrNights),
            .respiration(14.6, baseline: rrNights)
        ])
        let expected = try #require(WellnessAnalytics.headlineReadinessScore(composite))
        let score = try #require(split.score)
        #expect(abs(score - expected) < 1e-9)
        #expect(split.agrees(withDisplayedScore: expected.rounded()))
    }

    @Test func termsSumToTheCompositeAndPointsSumToTheDistanceFromFifty() throws {
        let split = WellnessAnalytics.recoveryDecomposition(readings())
        let composite = try #require(split.compositeZ)
        let score = try #require(split.score)
        let terms = split.signals.compactMap(\.contribution)
        let points = split.signals.compactMap(\.points)
        #expect(terms.count == 3)
        #expect(abs(terms.reduce(0, +) - composite) < 1e-9)
        #expect(abs(points.reduce(0, +) - (score - 50)) < 1e-9)
    }

    @Test func aGoodNightPushesUpAndAPoorOnePushesDown() throws {
        let good = WellnessAnalytics.recoveryDecomposition(readings(hrv: 62, rhr: 50, rr: 14.6))
        let poor = WellnessAnalytics.recoveryDecomposition(readings(hrv: 45, rhr: 57, rr: 15.0))
        #expect(try #require(good.score) > 50)
        #expect(try #require(poor.score) < 50)
        #expect(try #require(good.share(.hrv)?.points) > 0)
        #expect(try #require(good.share(.restingHeartRate)?.points) > 0)
        #expect(try #require(poor.share(.hrv)?.points) < 0)
        #expect(try #require(poor.share(.restingHeartRate)?.points) < 0)
        #expect(try #require(poor.share(.respiratoryRate)?.points) < 0)
    }

    @Test func hrvUsualIsTheLogScaleMedianInMilliseconds() throws {
        let split = WellnessAnalytics.recoveryDecomposition(readings())
        let usual = try #require(split.share(.hrv)?.usual)
        // Ten nights: the median of logs is the geometric mean of the two
        // middle nights, 49 and 50 ms.
        #expect(abs(usual - (49.0 * 50).squareRoot()) < 1e-9)
        #expect(split.share(.restingHeartRate)?.usual == 55)
        #expect(split.share(.hrv)?.baselineNights == 10)
    }

    @Test func missingReadingIsNotImputedAndTheRestRenormalise() throws {
        let split = WellnessAnalytics.recoveryDecomposition(readings(rr: nil))
        #expect(split.share(.respiratoryRate)?.status == .noReading)
        #expect(split.share(.respiratoryRate)?.points == nil)
        let used = split.signals.filter { $0.status == .used }
        #expect(used.count == 2)
        let score = try #require(split.score)
        #expect(abs(used.compactMap(\.points).reduce(0, +) - (score - 50)) < 1e-9)
    }

    @Test func tooFewNightsIsLearningWithACount() {
        let short = [
            RecoverySignalReading(signal: .hrv, value: 58, baseline: [50, 52]),
            RecoverySignalReading(signal: .restingHeartRate, value: 51, baseline: [55]),
            RecoverySignalReading(signal: .respiratoryRate, value: nil, baseline: [])
        ]
        let split = WellnessAnalytics.recoveryDecomposition(short)
        #expect(split.score == nil)
        #expect(split.share(.hrv)?.status == .learning(have: 2, need: 3))
        #expect(split.share(.restingHeartRate)?.status == .learning(have: 1, need: 3))
        #expect(split.baselineNightsSoFar == 1)
        #expect(split.nightsNeeded == 3)
        #expect(!split.isSaturated)
    }

    @Test func subQuantumRhrLeavesTooFewContributingInputs() {
        let flat = [
            RecoverySignalReading(signal: .hrv, value: 60, baseline: [50, 50, 50, 50.2]),
            RecoverySignalReading(signal: .restingHeartRate, value: 50, baseline: [55, 55, 55, 55.1])
        ]
        let split = WellnessAnalytics.recoveryDecomposition(flat)
        #expect(!split.isSaturated)
        #expect(split.score == nil)
        #expect(split.signals.allSatisfy { $0.points == nil })
    }

    @Test func aScoreFromADifferentComputationDoesNotAgree() {
        let split = WellnessAnalytics.recoveryDecomposition(readings())
        let score = split.score ?? 0
        #expect(!split.agrees(withDisplayedScore: score + 3))
        #expect(!split.agrees(withDisplayedScore: nil))
    }
}
