import AnalyticsKit
import Foundation
import Testing
@testable import TrainKit

/// The dot field's layout, the gauge's band geometry and the bookkeeping that decides which dots fly in.
struct FitnessGeometryTests {
    // MARK: Dots

    @Test func dotsFillRowsLeftToRight() {
        // 12 pt dots with 5 pt gaps: 19 fit in 330 pt (19 × 17 − 5 = 318).
        let layout = FitnessDotLayout(count: 36, width: 330, diameter: 12)
        #expect(layout.columns == 19)
        #expect(layout.rows == 2)
        #expect(layout.height == 29)
        #expect(layout.center(of: 0) == CGPoint(x: 6, y: 6))
        #expect(layout.center(of: 18) == CGPoint(x: 18 * 17 + 6, y: 6))
        #expect(layout.center(of: 19) == CGPoint(x: 6, y: 23))
        #expect(layout.frame(of: 1) == CGRect(x: 17, y: 0, width: 12, height: 12))
    }

    @Test func aNarrowOrMissingWidthStillPlacesOneDotARow() {
        #expect(FitnessDotLayout(count: 3, width: 0, diameter: 24).columns == 1)
        #expect(FitnessDotLayout(count: 3, width: .nan, diameter: 24).rows == 3)
        #expect(FitnessDotLayout(count: 0, width: 300, diameter: 12).height == 0)
    }

    /// A long week stays a block of at most three rows: the dots shrink a point at a time, never under 7 pt.
    @Test func aLongWeekShrinksItsDotsToStayThreeRowsTall() {
        // 63 zone 2 dots (315 min) start at 8 pt, past 60 (R2-DES-08), and fit three rows.
        #expect(FitnessDotLayout.diameter(forCount: 63, standard: 12) == 8)
        #expect(FitnessDotLayout.diameter(forCount: 36, standard: 12) == 10)
        #expect(FitnessDotLayout.diameter(forCount: 30, standard: 12) == 12)
        #expect(FitnessDotLayout.diameter(forCount: 4, standard: 24) == 24)
        let usual = FitnessDotLayout.fitting(count: 63, width: 330, diameter: 8)
        #expect(usual.diameter == 8 && usual.rows == 3)
        // 120 dots (600 min) would need seven rows at 12 pt. They shrink to the smallest dot, and past it the rows
        // grow again rather than the dots vanishing.
        let long = FitnessDotLayout.fitting(count: 120, width: 330, diameter: 12)
        #expect(long.diameter == FitnessDotLayout.minimumDiameter && long.rows > FitnessDotLayout.maximumRows)
        let medium = FitnessDotLayout.fitting(count: 80, width: 330, diameter: 12)
        #expect(medium.rows <= FitnessDotLayout.maximumRows && medium.diameter < 12)
        // 30 hard dots (150 min) at 24 pt would take three rows of 11: still fine.
        #expect(FitnessDotLayout.fitting(count: 30, width: 330, diameter: 24).diameter == 24)
        // 63 hard dots (315 min) shrink.
        let hard = FitnessDotLayout.fitting(count: 63, width: 330, diameter: 24)
        #expect(hard.rows <= FitnessDotLayout.maximumRows && hard.diameter < 24)
        // Past the smallest dot the rows grow again instead of the dots vanishing.
        let huge = FitnessDotLayout.fitting(count: 2_000, width: 330, diameter: 12)
        #expect(huge.diameter == FitnessDotLayout.minimumDiameter && huge.rows > FitnessDotLayout.maximumRows)
    }

    @Test func hardDotsAreLargerSoFewerFitARow() {
        let hard = FitnessDotLayout(count: 4, width: 330, diameter: FitnessDotLayout.hardDiameter)
        #expect(hard.columns == 11)
        #expect(hard.rows == 1)
        #expect(FitnessDotLayout.hardDiameter > FitnessDotLayout.standardDiameter)
    }

    @Test func theFillDrawsMeasuredDotsThenTheOnesStillToGo() {
        let fill = FitnessDotFill(filled: 22, total: 36)
        #expect(fill.count == 36)
        #expect(fill.dot(at: 21) == .filled)
        #expect(fill.dot(at: 22) == .empty)
        // A week past its target keeps every measured dot.
        #expect(FitnessDotFill(filled: 40, total: 36).count == 40)
        // No target: only measured dots.
        #expect(FitnessDotFill(filled: 5, total: nil).count == 5)
    }

    @Test func dotsInFlightAreTheLastMeasuredOnesAndWaitAsEmptySlots() {
        let fill = FitnessDotFill(filled: 22, total: 36, arriving: 3)
        #expect(fill.dot(at: 18) == .filled)
        #expect(fill.dot(at: 19) == .arriving)
        #expect(fill.dot(at: 21) == .arriving)
        #expect(fill.dot(at: 22) == .empty)
        #expect(FitnessDotFill(filled: 2, total: nil, arriving: 9).arriving == 2)
    }

    // MARK: Gauge

    /// FRIEND, men 30 to 39: 30.2, 35.9, 42.4, 49.2.
    var bands: [VO2MaxBand] {
        VO2MaxGauge.bands(for: FriendPercentileRow(ageLower: 30, ageUpper: 39, group: .male, p10: 30.2, p25: 35.9, p50: 42.4, p75: 49.2))
    }

    @Test func theRangeRunsABandPastTheOuterPercentilesInFives() {
        let scale = VO2MaxGaugeScale(bands: bands)
        #expect(scale.lower == 20 && scale.upper == 60)
        // A value past the bands widens the range to keep it inside.
        let wide = VO2MaxGaugeScale(bands: bands, including: [63])
        #expect(wide.upper == 65)
        #expect(VO2MaxGaugeScale(bands: bands, including: [19]).lower == 15)
    }

    @Test func theArcRunsFromMinus112To112Degrees() {
        let scale = VO2MaxGaugeScale(lower: 20, upper: 60)
        #expect(scale.angle(for: 20) == -112)
        #expect(scale.angle(for: 60) == 112)
        #expect(scale.angle(for: 40) == 0)
        #expect(scale.angle(for: 10) == -112)
        #expect(scale.angle(for: 99) == 112)
        #expect(abs(scale.value(atAngle: scale.angle(for: 44.1)) - 44.1) < 0.0001)
        #expect(scale.value(atAngle: -170) == 20)
    }

    @Test func theBandsAreFiveContiguousArcsCutAtThePercentiles() {
        let scale = VO2MaxGaugeScale(bands: bands)
        let arcs = scale.arcs(for: bands)
        #expect(arcs.map(\.band) == [.belowP10, .p10ToP25, .p25ToP50, .p50ToP75, .aboveP75])
        #expect(arcs.first?.startAngle == VO2MaxGaugeScale.startAngle)
        #expect(arcs.last?.endAngle == VO2MaxGaugeScale.endAngle)
        for (earlier, later) in zip(arcs, arcs.dropFirst()) {
            #expect(earlier.endAngle == later.startAngle)
            #expect(earlier.startAngle < earlier.endAngle)
        }
        #expect(arcs[3].startAngle == scale.angle(for: 42.4))
    }

    @Test func ticksAndLabelsCoverTheRange() {
        let scale = VO2MaxGaugeScale(lower: 20, upper: 60)
        #expect(scale.ticks.count == 41)
        #expect(scale.labels == [20, 30, 40, 50, 60])
    }

    @Test func pointsAndAnglesAreInverses() {
        let center = CGPoint(x: 150, y: 150)
        let top = VO2MaxGaugeScale.point(angle: 0, radius: 120, center: center)
        #expect(abs(top.x - 150) < 0.0001 && abs(top.y - 30) < 0.0001)
        let right = VO2MaxGaugeScale.point(angle: 90, radius: 120, center: center)
        #expect(abs(right.x - 270) < 0.0001 && abs(right.y - 150) < 0.0001)
        for angle in [-112.0, -45, 0, 30, 112] {
            let point = VO2MaxGaugeScale.point(angle: angle, radius: 100, center: center)
            #expect(abs(VO2MaxGaugeScale.angle(of: point, around: center) - angle) < 0.0001)
        }
    }

    @Test func scrubbingSnapsToTheNearestPercentile() {
        let boundaries = VO2MaxGaugeBoundary.boundaries(for: bands)
        #expect(boundaries.map(\.percentile) == [10, 25, 50, 75])
        #expect(boundaries.map(\.value) == [30.2, 35.9, 42.4, 49.2])
        #expect(boundaries[1].label == "25th percentile")
        #expect(VO2MaxGaugeBoundary.nearest(to: 44, in: boundaries, reach: 5) == 2)
        #expect(VO2MaxGaugeBoundary.nearest(to: 58, in: boundaries, reach: 5) == nil)
        #expect(VO2MaxGaugeBoundary.nearest(to: 58, in: boundaries, reach: .infinity) == 3)
    }

    // MARK: Flight

    @Test func theFirstLookAtAWeekFliesNothing() {
        #expect(FitnessDoseFlight.newDots(current: 22, lastShown: nil) == 0)
        #expect(FitnessDoseFlight.newDots(current: 22, lastShown: 22) == 0)
        #expect(FitnessDoseFlight.newDots(current: 20, lastShown: 22) == 0)
    }

    @Test func dotsThatArriveAfterASyncFlyOnceUpToTheCap() {
        #expect(FitnessDoseFlight.newDots(current: 25, lastShown: 22) == 3)
        #expect(FitnessDoseFlight.newDots(current: 80, lastShown: 2) == FitnessDoseFlight.maximumDots)
        let plan = FitnessDoseFlight.plan(current: FitnessDoseShown(zone2: 25, hard: 4),
                                          lastShown: FitnessDoseShown(zone2: 22, hard: 3), animates: true)
        #expect(plan == FitnessDoseShown(zone2: 3, hard: 1))
    }

    @Test func nothingFliesUnderReduceMotionOrWithoutBandData() {
        let last = FitnessDoseShown(zone2: 22, hard: 3)
        #expect(FitnessDoseFlight.plan(current: FitnessDoseShown(zone2: 25, hard: 4), lastShown: last, animates: false)
                == FitnessDoseShown(zone2: 0, hard: 0))
        #expect(FitnessDoseFlight.plan(current: nil, lastShown: last, animates: true) == FitnessDoseShown(zone2: 0, hard: 0))
    }

    @Test func theShownCountsArePerWeekAndOldWeeksAreDropped() throws {
        let suite = "FitnessGeometryTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = FitnessDoseShownStore(defaults: defaults)
        #expect(store.lastShown(week: "2023-W45") == nil)
        store.record(FitnessDoseShown(zone2: 10, hard: 1), week: "2023-W44")
        store.record(FitnessDoseShown(zone2: 30, hard: 2), week: "2023-W45")
        store.record(FitnessDoseShown(zone2: 22, hard: 3), week: "2023-W46")
        #expect(store.lastShown(week: "2023-W46") == FitnessDoseShown(zone2: 22, hard: 3))
        #expect(store.lastShown(week: "2023-W45") == FitnessDoseShown(zone2: 30, hard: 2))
        #expect(store.lastShown(week: "2023-W44") == nil)
        store.record(FitnessDoseShown(zone2: 25, hard: 3), week: "2023-W46")
        #expect(store.lastShown(week: "2023-W46")?.zone2 == 25)
    }

    @Test func theWeekKeyIsTheISOYearAndWeek() throws {
        let calendar = FitnessFixture.calendar("Australia/Perth")
        let week = try #require(ISOWeek(containing: FitnessFixture.date(2023, 11, 14, zone: "Australia/Perth"), calendar: calendar))
        #expect(FitnessDoseShownStore.key(for: week) == "2023-W46")
        let newYear = try #require(ISOWeek(containing: FitnessFixture.date(2021, 1, 2), calendar: FitnessFixture.calendar()))
        #expect(FitnessDoseShownStore.key(for: newYear) == "2020-W53")
    }
}
