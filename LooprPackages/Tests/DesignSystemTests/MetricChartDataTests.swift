import Foundation
import Testing
@testable import DesignSystem

struct MetricChartDataTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        calendar.firstWeekday = 2
        return calendar
    }

    private func day(_ offset: Int, from end: Date) -> Date {
        calendar.date(byAdding: .day, value: -offset, to: calendar.startOfDay(for: end))!
    }

    private var end: Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: 23, hour: 21))!
    }

    @Test func deviationChartKeepsZeroAndTheUsualBandVisible() {
        let points = [0, 1, 2].map { LooprChartPoint(date: day($0, from: end), value: 1.5) }
        let band = LooprBaselineBand(center: 0, lower: -0.3, upper: 0.3, measuredDays: 14)
        let series = LooprChartSeries.prepare(points, range: .week, endingOn: end, baseline: band,
            scale: .init(minimumSpan: 1, includeZero: true), calendar: calendar)
        #expect(series.yDomain.contains(0))
        #expect(series.yDomain.contains(-0.3))
        #expect(series.yDomain.contains(1.5))
    }

    @Test func zeroReferenceWithoutABaselineNeverClipsReadings() {
        for value in [1.5, -1.5] {
            let points = [LooprChartPoint(date: end, value: value)]
            let series = LooprChartSeries.prepare(points, range: .week, endingOn: end,
                scale: .init(minimumSpan: 1, includeZero: true), calendar: calendar)
            #expect(series.yDomain.contains(0))
            #expect(series.yDomain.contains(value))
        }
    }

    // MARK: Gaps

    @Test func missingDaysSplitTheLineIntoSegments() {
        let points = [0, 1, 2, 5, 6, 9].map { LooprChartPoint(date: day($0, from: end), value: Double(50 + $0)) }
        let series = LooprChartSeries.prepare(points, range: .month, endingOn: end, calendar: calendar)
        let segments = series.points.map(\.segment)
        // Ascending by day: 9 | 6 5 | 2 1 0
        #expect(segments == [0, 1, 1, 2, 2, 2])
    }

    @Test func absentDaysAreNeverZeroFilled() {
        let points = [0, 3].map { LooprChartPoint(date: day($0, from: end), value: 60) }
        let series = LooprChartSeries.prepare(points, range: .week, endingOn: end, calendar: calendar)
        #expect(series.points.count == 2)
        #expect(series.points.allSatisfy { $0.value == 60 })
        #expect(series.point(at: day(1, from: end), calendar: calendar) == nil)
        #expect(series.measuredDays == 2)
    }

    @Test func nonFiniteValuesAndOutOfWindowDaysAreDropped() {
        let points = [
            LooprChartPoint(date: day(0, from: end), value: .nan),
            LooprChartPoint(date: day(1, from: end), value: 42),
            LooprChartPoint(date: day(10, from: end), value: 99)
        ]
        let series = LooprChartSeries.prepare(points, range: .week, endingOn: end, calendar: calendar)
        #expect(series.points.map(\.value) == [42])
    }

    @Test func duplicateDaysKeepOneValue() {
        let morning = calendar.date(byAdding: .hour, value: 7, to: day(0, from: end))!
        let evening = calendar.date(byAdding: .hour, value: 20, to: day(0, from: end))!
        let series = LooprChartSeries.prepare(
            [LooprChartPoint(date: morning, value: 1), LooprChartPoint(date: evening, value: 2)],
            range: .week, endingOn: end, calendar: calendar
        )
        #expect(series.points.count == 1)
    }

    // MARK: Range bucketing

    @Test func rangesCoverTheRightNumberOfDays() {
        let points = (0..<400).map { LooprChartPoint(date: day($0, from: end), value: 50) }
        for range in [LooprChartRange.week, .month, .quarter] {
            let series = LooprChartSeries.prepare(points, range: range, endingOn: end, calendar: calendar)
            #expect(series.points.count == range.dayCount)
            #expect(series.start == day(range.dayCount - 1, from: end))
            #expect(series.lastDay == day(0, from: end))
        }
    }

    @Test func yearRangeAveragesEachWeek() {
        let points = (0..<365).map { LooprChartPoint(date: day($0, from: end), value: Double($0 % 7)) }
        let series = LooprChartSeries.prepare(points, range: .year, endingOn: end, calendar: calendar)
        #expect(series.window.bucket == .week)
        #expect(series.points.count >= 52 && series.points.count <= 54)
        let full = series.points.filter { $0.measuredDays == 7 }
        #expect(!full.isEmpty)
        for point in full {
            #expect(abs(point.value - 3) < 0.0001)
            #expect(point.low == 0)
            #expect(point.high == 6)
        }
        #expect(Set(series.points.map(\.segment)) == [0])
    }

    @Test func yearRangeBreaksAtAMissingWeek() {
        let points = (0..<365).filter { !(100...113).contains($0) }
            .map { LooprChartPoint(date: day($0, from: end), value: 50) }
        let series = LooprChartSeries.prepare(points, range: .year, endingOn: end, calendar: calendar)
        #expect(Set(series.points.map(\.segment)).count == 2)
    }

    @Test func barsStartAtZeroAndLinesFitTheData() {
        let points = (0..<7).map { LooprChartPoint(date: day($0, from: end), value: 7000 + Double($0) * 100) }
        let bars = LooprChartSeries.prepare(points, range: .week, endingOn: end, kind: .bars, calendar: calendar)
        #expect(bars.yDomain.lowerBound == 0)
        #expect(bars.yDomain.upperBound > 7600)
        let line = LooprChartSeries.prepare(points, range: .week, endingOn: end, kind: .line, calendar: calendar)
        #expect(line.yDomain.lowerBound > 6000)
        #expect(line.yDomain.upperBound > 7600)
    }

    @Test func flatSeriesStillGetsAVisibleDomain() {
        let points = (0..<7).map { LooprChartPoint(date: day($0, from: end), value: 50) }
        let series = LooprChartSeries.prepare(points, range: .week, endingOn: end, calendar: calendar)
        #expect(series.yDomain.upperBound - series.yDomain.lowerBound >= 1)
        #expect(series.yDomain.contains(50))
    }

    // MARK: Baseline band

    @Test func baselineNeedsFourteenDays() {
        #expect(LooprBaselineBand.compute(values: Array(repeating: 50, count: 13)) == nil)
        #expect(LooprBaselineBand.compute(values: Array(repeating: 50, count: 14)) != nil)
    }

    @Test func baselineIsMedianPlusMinusScaledMAD() throws {
        // Median 50, absolute deviations 0,1,1,2,2,... -> MAD 2
        let values: [Double] = [46, 47, 48, 48, 49, 49, 50, 50, 51, 51, 52, 52, 53, 54, 50]
        let band = try #require(LooprBaselineBand.compute(values: values))
        #expect(band.center == 50)
        let spread = 2 * 1.4826
        #expect(abs(band.lower - (50 - spread)) < 0.0001)
        #expect(abs(band.upper - (50 + spread)) < 0.0001)
        #expect(band.position(of: 50) == .within)
        #expect(band.position(of: 54) == .above)
        #expect(band.position(of: 46) == .below)
    }

    @Test func baselineIgnoresOneOutlier() throws {
        var values = Array(repeating: 50.0, count: 20)
        values[3] = 500
        let band = try #require(LooprBaselineBand.compute(values: values))
        #expect(band.center == 50)
        #expect(band.upper < 51)
    }

    @Test func flatBaselineKeepsAOnePercentFloor() throws {
        let band = try #require(LooprBaselineBand.compute(values: Array(repeating: 60, count: 20)))
        #expect(abs(band.halfWidth - 0.6) < 0.0001)
        #expect(band.position(of: 60.4) == .within)
    }

    @Test func trailingBaselineExcludesTheDayItself() throws {
        var points = (1...30).map { LooprChartPoint(date: day($0, from: end), value: 50) }
        points.append(LooprChartPoint(date: day(0, from: end), value: 90))
        let band = try #require(LooprBaselineBand.trailing(points, before: end, calendar: calendar))
        #expect(band.center == 50)
        #expect(band.measuredDays == 30)
    }

    // MARK: Statistics and axis

    @Test func statisticsReportExtremesAndConsecutiveChange() throws {
        let values: [Int: Double] = [0: 10, 1: 14, 2: 12, 5: 30]
        let points = values.map { LooprChartPoint(date: day($0.key, from: end), value: $0.value) }
        let stats = try #require(LooprSeriesStatistics.compute(points, window: LooprChartRange.week.window, endingOn: end, calendar: calendar))
        #expect(stats.measuredDays == 4)
        #expect(stats.highest.value == 30)
        #expect(stats.lowest.value == 10)
        // Only day2->day1 (2) and day1->day0 (4) are adjacent; day5->day2 is a gap.
        #expect(stats.typicalDailyChange == 3)
    }

    @Test func weekAxisLabelsEveryDayAndMonthAxisEveryWeek() {
        let points = (0..<120).map { LooprChartPoint(date: day($0, from: end), value: 50) }
        let week = LooprChartSeries.prepare(points, range: .week, endingOn: end, calendar: calendar)
        #expect(LooprTrendAxis.dates(for: week, dense: false, calendar: calendar).count == 7)
        #expect(LooprTrendAxis.dates(for: week, dense: true, calendar: calendar).count == 4)
        let month = LooprChartSeries.prepare(points, range: .month, endingOn: end, calendar: calendar)
        #expect(LooprTrendAxis.dates(for: month, dense: false, calendar: calendar).count == 4)
        let quarter = LooprChartSeries.prepare(points, range: .quarter, endingOn: end, calendar: calendar)
        #expect((3...4).contains(LooprTrendAxis.dates(for: quarter, dense: false, calendar: calendar).count))
    }

    @Test func typicalRangeBarFractionsClamp() {
        #expect(LooprTypicalRangeBar.fraction(5, in: 0...10) == 0.5)
        #expect(LooprTypicalRangeBar.fraction(-5, in: 0...10) == 0)
        #expect(LooprTypicalRangeBar.fraction(50, in: 0...10) == 1)
        let domain = LooprTypicalRangeBar.defaultDomain(value: 70, typical: 50...56)
        #expect(domain.contains(70))
        #expect(domain.lowerBound < 50)
    }

    @Test func metricLinkIDsAreUnique() {
        #expect(Set(LooprMetricLinkID.all).count == LooprMetricLinkID.all.count)
        #expect(LooprMetricLinkID.all.count == 21)
    }
}
