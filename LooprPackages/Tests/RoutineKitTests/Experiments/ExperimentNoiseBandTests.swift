import DomainKit
import Foundation
import Testing
@testable import RoutineKit

struct ExperimentNoiseBandTests {
    private let start = ExpFixtures.startDay

    @Test func theBandIsTheScaledMadOfNightToNightDifferences() {
        let band = NoiseBand.make(baseline: ExpFixtures.baseline(), startDay: start)
        #expect(band.isReady && band.shortfall == nil)
        #expect(band.nights == 14 && band.differences == 13)
        // Differences 4, -5, 6, -5, 3, -5, 6, -3, 1, -5, 8, -5, 3 have median 1 and MAD 5.
        #expect(abs((band.spread ?? 0) - 5.0 * 1.4826 / 2.0.squareRoot()) < 1e-9)
        #expect(band.windowStart == ExpFixtures.night(-28) && band.windowEnd == ExpFixtures.night(-1))
    }

    @Test func tooFewBaselineNightsLeaveNoBand() {
        let nine = ExpFixtures.baseline(values: Array(ExpFixtures.baselineValues.prefix(9)))
        let band = NoiseBand.make(baseline: nine, startDay: start)
        #expect(band.spread == nil && !band.isReady)
        #expect(band.shortfall == .tooFewNights(have: 9, need: 10))
        #expect(NoiseBand.make(baseline: [:], startDay: start).shortfall == .tooFewNights(have: 0, need: 10))
    }

    @Test func nightsOutsideTheWindowDoNotCount() {
        // Fourteen nights, all of them 40 to 27 nights before day 1: the window is the 28 before.
        let early = ExpFixtures.baseline(values: ExpFixtures.baselineValues, before: ExpFixtures.night(-26))
        let band = NoiseBand.make(baseline: early, startDay: start)
        #expect(band.nights == 2)
        #expect(band.shortfall == .tooFewNights(have: 2, need: 10))
        // Nights on or after day 1 are never baseline.
        var leaking = ExpFixtures.baseline(values: Array(ExpFixtures.baselineValues.prefix(9)))
        leaking[start] = 50
        leaking[ExpFixtures.night(1)] = 51
        #expect(NoiseBand.make(baseline: leaking, startDay: start).nights == 9)
    }

    @Test func backToBackPairsAreNeededNotJustNights() {
        // Twelve nights, every other day: enough nights, no pair of neighbours.
        var gappy: [DayIdentity: Double] = [:]
        for index in 0..<12 { gappy[ExpFixtures.night(-1 - 2 * index)] = 50 + Double(index) }
        let band = NoiseBand.make(baseline: gappy, startDay: start)
        #expect(band.nights == 12 && band.differences == 0)
        #expect(band.shortfall == .tooFewConsecutivePairs(have: 0, need: 6))
        #expect(band.spread == nil)
    }

    @Test func zeroIsAMeasurementAndAGapIsNot() {
        let flat = NoiseBand.make(baseline: ExpFixtures.baseline(values: Array(repeating: 0, count: 14)), startDay: start)
        #expect(flat.spread == 0 && flat.nights == 14)
        var holes = ExpFixtures.baseline()
        holes[ExpFixtures.night(-5)] = nil
        holes[ExpFixtures.night(-6)] = nil
        let band = NoiseBand.make(baseline: holes, startDay: start)
        #expect(band.nights == 12)
        // The two missing nights break two pairs and make no zero-valued ones.
        #expect(band.differences == 13 - 3)
    }

    @Test func oneWildNightDoesNotInflateTheBand() {
        var values = ExpFixtures.baselineValues
        values[5] = 200
        let band = NoiseBand.make(baseline: ExpFixtures.baseline(values: values), startDay: start)
        // The two differences around the wild night become 150 and -152. The MAD moves from 5 to 6.
        #expect(abs((band.spread ?? 0) - 6.0 * 1.4826 / 2.0.squareRoot()) < 1e-9)
        #expect((band.spread ?? 99) < 1.5 * ExpFixtures.baselineSpread)
    }

    @Test func manyTiesFallBackToTheStandardDeviationOfTheDifferences() {
        var values = Array(repeating: 60.0, count: 11)
        values.append(61)
        let band = NoiseBand.make(baseline: ExpFixtures.baseline(values: values), startDay: start)
        // Ten zero differences and one 1: MAD 0. The sample SD is sqrt(10/11/10), over the square root of two.
        let expected = (1.0 / 11.0).squareRoot() / 2.0.squareRoot()
        #expect(abs((band.spread ?? 0) - expected) < 1e-9)
    }

    @Test func aPolicyCanChangeTheWindowAndTheMinimums() {
        let policy = ExperimentPolicy(baselineWindowNights: 14, minimumBaselineNights: 14, minimumBaselineDifferences: 13)
        #expect(NoiseBand.make(baseline: ExpFixtures.baseline(), startDay: start, policy: policy).isReady)
        let strict = ExperimentPolicy(minimumBaselineNights: 15)
        #expect(NoiseBand.make(baseline: ExpFixtures.baseline(), startDay: start, policy: strict).shortfall
                == .tooFewNights(have: 14, need: 15))
    }
}
