import DomainKit
import Foundation
import Testing

@Suite struct StrainTargetTests {
    @Test func rangeFollowsTheRecoveryBand() {
        #expect(StrainTarget(recovery: 100)?.range == 14...18)
        #expect(StrainTarget(recovery: 74)?.range == 14...18)
        #expect(StrainTarget(recovery: 67)?.range == 14...18)
        #expect(StrainTarget(recovery: 66)?.range == 10...14)
        #expect(StrainTarget(recovery: 50)?.range == 10...14)
        #expect(StrainTarget(recovery: 34)?.range == 10...14)
        #expect(StrainTarget(recovery: 33)?.range == 4...10)
        #expect(StrainTarget(recovery: 0)?.range == 4...10)
    }

    @Test func scoreIsRoundedBeforeTheBandIsChosen() {
        // 66.5 prints as 67 on the ring, so it gets the high range.
        #expect(StrainTarget(recovery: 66.5)?.band == .high)
        #expect(StrainTarget(recovery: 66.4)?.band == .middle)
        #expect(StrainTarget(recovery: 33.5)?.band == .middle)
        #expect(StrainTarget(recovery: 33.4)?.band == .low)
        #expect(StrainTarget(recovery: 66.5)?.recovery == 67)
    }

    @Test func outOfRangeScoresClampAndMissingScoresGiveNoRange() {
        #expect(StrainTarget(recovery: 140)?.band == .high)
        #expect(StrainTarget(recovery: 140)?.recovery == 100)
        #expect(StrainTarget(recovery: -5)?.band == .low)
        #expect(StrainTarget(recovery: nil) == nil)
        #expect(StrainTarget(recovery: .nan) == nil)
        #expect(StrainTarget(recovery: .infinity) == nil)
    }

    @Test func bandsCoverEveryScoreOnceAndNeverSuggestAllOut() {
        for score in 0...100 {
            let matching = StrainTarget.RecoveryBand.allCases.filter { $0.scores.contains(score) }
            #expect(matching.count == 1, "score \(score)")
        }
        for band in StrainTarget.RecoveryBand.allCases {
            #expect(band.strainRange.upperBound <= 18)
            #expect(band.strainRange.lowerBound >= StrainTarget.scale.lowerBound)
        }
        // Higher recovery never suggests less.
        let ordered: [StrainTarget.RecoveryBand] = [.low, .middle, .high]
        for (lower, higher) in zip(ordered, ordered.dropFirst()) {
            #expect(lower.strainRange.lowerBound < higher.strainRange.lowerBound)
            #expect(lower.strainRange.upperBound <= higher.strainRange.lowerBound)
        }
    }

    @Test func positionComparesAtTheDisplayedPrecision() throws {
        let target = try #require(StrainTarget(recovery: 74))
        #expect(target.position(of: 8.6) == .below)
        #expect(target.position(of: 13.94) == .below)
        #expect(target.position(of: 13.96) == .within) // prints as 14.0
        #expect(target.position(of: 14) == .within)
        #expect(target.position(of: 18) == .within)
        #expect(target.position(of: 18.04) == .within) // prints as 18.0
        #expect(target.position(of: 18.1) == .above)
        #expect(target.position(of: nil) == nil)
        #expect(target.position(of: .nan) == nil)
    }

    @Test func distanceIsZeroInsideAndRoundedOutside() throws {
        let target = try #require(StrainTarget(recovery: 74))
        #expect(target.distance(of: 8.6) == 5.4)
        #expect(target.distance(of: 15) == 0)
        #expect(target.distance(of: 19.25) == 1.3)
        #expect(target.distance(of: nil) == nil)
    }

    @Test func textAndFractionsDescribeTheRange() throws {
        let high = try #require(StrainTarget(recovery: 90))
        #expect(high.text == "14 to 18")
        #expect(abs(high.fractions.lowerBound - 14.0 / 21) < 1e-12)
        #expect(abs(high.fractions.upperBound - 18.0 / 21) < 1e-12)
        #expect(StrainTarget(recovery: 20)?.text == "4 to 10")
    }
}
