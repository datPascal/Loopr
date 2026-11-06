import AnalyticsKit
@testable import DataKit
import DesignSystem
import Foundation
import XCTest

/// Improving, steady, watch and changed; this year against last with its coverage rule; and the star map.
final class DataTrendTests: XCTestCase {
    private typealias S = DataOverviewTestSupport
    private let now = DataOverviewTestSupport.date(2026, 10, 25)

    // MARK: Classification

    func testAChangeInsideTheBandIsSteadyAndOutsideFollowsTheBetterDirection() {
        XCTAssertEqual(DataTrendRule.classify(earlier: 50, later: 51, band: 2, higherIsBetter: true), .steady)
        XCTAssertEqual(DataTrendRule.classify(earlier: 50, later: 52, band: 2, higherIsBetter: true), .steady)
        XCTAssertEqual(DataTrendRule.classify(earlier: 50, later: 53, band: 2, higherIsBetter: true), .improving)
        XCTAssertEqual(DataTrendRule.classify(earlier: 50, later: 47, band: 2, higherIsBetter: true), .watch)
        XCTAssertEqual(DataTrendRule.classify(earlier: 54, later: 51, band: 1, higherIsBetter: false), .improving)
        XCTAssertEqual(DataTrendRule.classify(earlier: 54, later: 57, band: 1, higherIsBetter: false), .watch)
        // No better direction: a move outside the band is changed either way, never watch (DEC-12.6).
        XCTAssertEqual(DataTrendRule.classify(earlier: 50, later: 60, band: 2, higherIsBetter: nil), .changed)
        XCTAssertEqual(DataTrendRule.classify(earlier: 50, later: 40, band: 2, higherIsBetter: nil), .changed)
    }

    func testTheBandIsHalfTheEarlierSpreadWithAFloorShareOfTheMedian() {
        XCTAssertEqual(DataTrendRule.interquartileRange([1, 2, 3, 4, 5, 6, 7, 8, 9]), 4, accuracy: 1e-12)
        XCTAssertEqual(DataTrendRule.band(earlier: [1, 2, 3, 4, 5, 6, 7, 8, 9], floorShare: 0.02), 2, accuracy: 1e-12)
        // No spread: the floor holds.
        XCTAssertEqual(DataTrendRule.band(earlier: [50, 50, 50, 50], floorShare: 0.02), 1, accuracy: 1e-12)
        XCTAssertEqual(DataTrendRule.band(earlier: [100], floorShare: DataTrendRule.labFloorShare), 5, accuracy: 1e-12)
        XCTAssertEqual(DataTrendRule.median([3, 1, 2, 10]), 2.5)
        XCTAssertNil(DataTrendRule.median([]))
    }

    // MARK: This year against last

    func testWithLessThanAYearOfDataTheComparisonSaysWhenItOpens() {
        let young = S.series("rmssd", points: S.daily(now: now, from: 200, to: 0) { _ in 60 })
        XCTAssertEqual(DataYearComparisonRule.compare([young], now: now, calendar: S.calendar), .learning(daysUntilOpen: 165))
        XCTAssertEqual(DataYearComparisonRule.compare([S.series("rmssd", points: [])], now: now, calendar: S.calendar), .noData)
    }

    func testADailyMetricNeedsThirtyDaysInBothNinetyDayWindows() throws {
        let calendar = S.calendar
        let today = calendar.startOfDay(for: now)
        let windows = try XCTUnwrap(DataYearComparisonRule.windows(today: today, calendar: calendar))
        XCTAssertEqual(calendar.dateComponents([.day], from: windows.this.lowerBound, to: today).day, 89)
        XCTAssertEqual(windows.last.lowerBound, calendar.date(byAdding: .year, value: -1, to: windows.this.lowerBound))

        // Every day this year; last year's window has 29 values for one metric and 30 for the other.
        let thisYear = S.daily(now: now, from: 89, to: 0) { _ in 64 }
        let lastYearStart = calendar.dateComponents([.day], from: windows.last.lowerBound, to: today).day!
        let thin = S.daily(now: now, from: lastYearStart, to: lastYearStart - 28) { _ in 57 }
        let enough = S.daily(now: now, from: lastYearStart, to: lastYearStart - 29) { _ in 57 }
        let anchor = [DataPoint(date: calendar.date(byAdding: .day, value: -500, to: today)!, value: 57)]
        let rows = DataYearComparisonRule.compare([
            S.series("thin", points: anchor + thin + thisYear),
            S.series("enough", points: anchor + enough + thisYear)
        ], now: now, calendar: calendar).rows
        XCTAssertEqual(rows.map(\.id), ["enough"])
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.lastYear, 57)
        XCTAssertEqual(row.thisYear, 64)
        XCTAssertEqual(row.trend, .improving)
        XCTAssertEqual(row.deltaText, "+7.0")
        XCTAssertEqual(row.valueText, "64.0")
    }

    func testWithAYearOfDataButNoCoverageTheCardSaysSo() {
        let calendar = S.calendar
        let old = [DataPoint(date: calendar.date(byAdding: .day, value: -500, to: now)!, value: 50)]
        XCTAssertEqual(DataYearComparisonRule.compare([S.series("rhr", points: old)], now: now, calendar: calendar), .notEnoughCoverage)
    }

    func testRowsListTheMostMovedFirstAndEveryRuleAppliesTheSameWay() {
        func metric(_ id: String, last: Double, this: Double, higherIsBetter: Bool?) -> DataSeries {
            S.series(id, higherIsBetter: higherIsBetter,
                     points: S.daily(now: now, from: 460, to: 0) { $0 > 300 ? last : this })
        }
        let rows = DataYearComparisonRule.compare([
            metric("flat", last: 60, this: 60.5, higherIsBetter: true),
            metric("rhr", last: 57, this: 51, higherIsBetter: false),
            metric("strain", last: 10, this: 12, higherIsBetter: nil)
        ], now: now, calendar: S.calendar).rows
        // Strain moved 10 bands (2 against a 2 % floor of 0.2), resting heart rate about 5, the flat one less than 1.
        XCTAssertEqual(rows.map(\.id), ["strain", "rhr", "flat"])
        XCTAssertEqual(rows.map(\.trend), [.changed, .improving, .steady])
        // The glyph follows the sign: resting heart rate fell, so it slopes down even though it improved.
        XCTAssertEqual(rows.map(\.direction), [1, -1, 0])
    }

    func testLabValuesCompareTheLatestOfEachYearAgainstEachOtherNeverARange() {
        let calendar = S.calendar
        let lastYear = calendar.date(byAdding: .day, value: -400, to: now)!
        let thisYear = calendar.date(byAdding: .day, value: -40, to: now)!
        let apoB = S.series("apob", cadence: .lab, points: [DataPoint(date: lastYear, value: 92), DataPoint(date: thisYear, value: 78)])
        let row = DataYearComparisonRule.compare([apoB], now: now, calendar: calendar).rows.first
        XCTAssertEqual(row?.lastYear, 92)
        XCTAssertEqual(row?.thisYear, 78)
        // Lab markers carry no better direction, so a move outside 5 % of last year's value is changed, in its own
        // neutral colour (ICP R2-OPT-28).
        XCTAssertEqual(row?.trend, .changed)
        XCTAssertEqual(row?.direction, -1)
        XCTAssertEqual(row?.trend.accent, .sleep)
        // A lab row names its values as draws, not as a 90-day median, and gives last year's value with its unit
        // (Data ICP R4-VET-01, R4-VET-02).
        XCTAssertEqual(row?.basis, "Latest draw")
        XCTAssertEqual(row?.caption.hasPrefix("Latest draw "), true)
        XCTAssertEqual(row?.caption.contains(", last year "), true)
        let close = S.series("hba1c", cadence: .lab, points: [DataPoint(date: lastYear, value: 5.3), DataPoint(date: thisYear, value: 5.4)])
        XCTAssertEqual(DataYearComparisonRule.compare([close], now: now, calendar: calendar).rows.first?.trend, .steady)
        XCTAssertNil(S.series("apob", cadence: .lab, higherIsBetter: true, points: []).higherIsBetter)
    }

    func testALabMarkerThatRoseSlopesUpInNeutralInkAndOneThatFellSlopesDown() throws {
        let calendar = S.calendar
        let lastYear = calendar.date(byAdding: .day, value: -400, to: now)!
        let thisYear = calendar.date(byAdding: .day, value: -40, to: now)!
        let vitaminD = S.series("vitd", cadence: .lab, points: [DataPoint(date: lastYear, value: 30), DataPoint(date: thisYear, value: 42)])
        let crp = S.series("crp", cadence: .lab, points: [DataPoint(date: lastYear, value: 1.4), DataPoint(date: thisYear, value: 0.9)])
        let rows = DataYearComparisonRule.compare([vitaminD, crp], now: now, calendar: calendar).rows
        let up = try XCTUnwrap(rows.first { $0.id == "vitd" })
        XCTAssertEqual(up.trend, .changed)
        XCTAssertEqual(up.direction, 1)
        let down = try XCTUnwrap(rows.first { $0.id == "crp" })
        XCTAssertEqual(down.trend, .changed)
        XCTAssertEqual(down.direction, -1)
        // No lab row is ever drawn in the warning colour.
        XCTAssertFalse(rows.contains { $0.trend.accent == .warning })
    }

    // MARK: Star map

    func testEveryMarkerIsAStarAndAnUnmeasuredOneIsADimOutline() {
        let draws = [S.completeDraw()]
        let series = DataLabSeries.series(draws) + [S.series("rmssd", system: .cardiovascular, points: S.daily(now: now, from: 120, to: 0) { _ in 60 }),
                                                   S.series("steps", system: .fitness, points: [])]
        let map = DataStarMapRule.make(series, now: now, calendar: S.calendar)
        XCTAssertEqual(map.count, LabMarkerCatalog.markers.count + 2)
        XCTAssertEqual(map.measuredCount, 9 + 1)
        XCTAssertEqual(map.clusters.map(\.system), DataBodySystem.allCases.filter { system in series.contains { $0.system == system } })
        let steps = map.clusters.flatMap(\.stars).first { $0.id == "steps" }
        XCTAssertEqual(steps?.isAbsent, true)
        XCTAssertEqual(steps?.brightness, 0)
        XCTAssertNil(steps?.trend)
        for cluster in map.clusters {
            // Measured stars come first, brightest first.
            let measured = cluster.stars.prefix { !$0.isAbsent }
            XCTAssertEqual(measured.count, cluster.measuredCount)
            XCTAssertEqual(measured.map(\.brightness), measured.map(\.brightness).sorted(by: >))
        }
    }

    func testALabStarComparesWithTheOwnEarlierValuesAndIgnoresTheLabsRange() {
        let calendar = S.calendar
        func draw(_ daysAgo: Int, _ text: String, range: LabReferenceRange) -> DataLabDraw {
            let report = S.report(at: calendar.date(byAdding: .day, value: -daysAgo, to: now)!)
            return DataLabDraw(report: report, values: [S.value(report, .apoB, text, "mg/dL", range: range)])
        }
        let range = LabReferenceRange(low: 40, high: 130)
        // Inside the lab's range every time, but well above the person's own earlier values.
        let moved = [draw(700, "80", range: range), draw(400, "82", range: range), draw(30, "120", range: range)]
        let star = DataStarMapRule.make(DataLabSeries.series(moved), now: now, calendar: calendar)
            .clusters.flatMap(\.stars).first { $0.id == "lab-apob" }
        XCTAssertEqual(star?.trend, .changed)
        XCTAssertTrue(star?.note.contains(DataStarMap.labNote) == true)
        XCTAssertEqual(star?.latestText, "120 mg/dL")

        // Above the lab's range every time, but the same as before: steady.
        let high = LabReferenceRange(low: 40, high: 100)
        let same = [draw(400, "140", range: high), draw(30, "141", range: high)]
        let steady = DataStarMapRule.make(DataLabSeries.series(same), now: now, calendar: calendar)
            .clusters.flatMap(\.stars).first { $0.id == "lab-apob" }
        XCTAssertEqual(steady?.trend, .steady)

        // One value: no comparison yet.
        let single = DataStarMapRule.make(DataLabSeries.series([draw(30, "80", range: range)]), now: now, calendar: calendar)
            .clusters.flatMap(\.stars).first { $0.id == "lab-apob" }
        XCTAssertNil(single?.trend)
        XCTAssertEqual(single?.isAbsent, false)
    }

    func testLabValuesInAnotherUnitAreConvertedToTheNewestUnitBeforeComparing() throws {
        let calendar = S.calendar
        let older = S.report(at: calendar.date(byAdding: .day, value: -400, to: now)!)
        let newer = S.report(at: calendar.date(byAdding: .day, value: -30, to: now)!)
        let series = DataLabSeries.series([
            DataLabDraw(report: older, values: [S.value(older, .glucose, "90", "mg/dL")]),
            DataLabDraw(report: newer, values: [S.value(newer, .glucose, "5.0", "mmol/L")])
        ]).first { $0.id == "lab-glucose" }
        let points = try XCTUnwrap(series?.points)
        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(points[0].value, 90 / 18.016, accuracy: 0.05)
        XCTAssertEqual(points[1].value, 5.0, accuracy: 1e-9)
    }

    func testADailyStarNeedsTenRecentDaysAndThirtyBeforeThem() {
        let sparse = S.series("rhr", higherIsBetter: false, points: S.daily(now: now, from: 120, to: 0) { $0 % 4 == 0 ? 50 : .nan })
        let star = DataStarMapRule.make([sparse], now: now, calendar: S.calendar).clusters.first?.stars.first
        XCTAssertNil(star?.trend)
        XCTAssertFalse(star?.isAbsent ?? true)

        let full = S.series("rhr", higherIsBetter: false, points: S.daily(now: now, from: 119, to: 0) { $0 < 30 ? 50 : 54 })
        XCTAssertEqual(DataStarMapRule.make([full], now: now, calendar: S.calendar).clusters.first?.stars.first?.trend, .improving)
    }

    func testBrightnessFallsWithAgeToAFloorAndStarsSitInsideTheirDisc() {
        XCTAssertEqual(DataStarMapRule.brightness(daysSince: 0), 1)
        XCTAssertEqual(DataStarMapRule.brightness(daysSince: 365), DataStarMapRule.dimmest)
        XCTAssertEqual(DataStarMapRule.brightness(daysSince: 2_000), DataStarMapRule.dimmest)
        XCTAssertEqual(DataStarMapRule.brightness(daysSince: 73), 0.8, accuracy: 1e-12)

        for count in [1, 2, 9, 16] {
            let points = DataStarMapRule.positions(count: count)
            XCTAssertEqual(points.count, count)
            XCTAssertEqual(points[0], .zero)
            XCTAssertTrue(points.allSatisfy { ($0.x * $0.x + $0.y * $0.y).squareRoot() <= 1 + 1e-9 })
            XCTAssertEqual(Set(points.map { "\(($0.x * 1000).rounded()),\(($0.y * 1000).rounded())" }).count, count)
        }
        XCTAssertTrue(DataStarMapRule.positions(count: 0).isEmpty)
    }
}
