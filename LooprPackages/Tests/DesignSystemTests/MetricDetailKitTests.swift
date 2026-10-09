import Foundation
import Testing
import SwiftUI
@testable import DesignSystem

/// The small-data rules, range unlocking, weekday labels and the recovery
/// calendar added for the metric detail pages.
struct MetricDetailKitTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        calendar.firstWeekday = 2
        return calendar
    }

    /// Wed 23 Sep 2026, evening.
    private var end: Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: 23, hour: 21))!
    }

    private func day(_ offset: Int) -> Date {
        calendar.date(byAdding: .day, value: -offset, to: calendar.startOfDay(for: end))!
    }

    @Test @MainActor func nightlyChartUsesNightsForAverageAndCoverage() {
        let ending = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_790_000_000))
        let points = (0..<14).map { offset in
            LooprChartPoint(date: Calendar.current.date(byAdding: .day, value: -offset, to: ending)!, value: 0.1)
        }
        let series = LooprChartSeries.prepare(points, range: .month, endingOn: ending)
        let nightly = LooprMetricTrendCard(title: "Temperature change", points: points, endingOn: ending,
            range: .constant(.month), kind: .line, accent: .heart, unit: "°C", valueFormat: { String(format: "%.1f", $0) },
            options: .init(smallDataNoun: .nights))
        #expect(nightly.headerContent(series).eyebrow == "30-NIGHT AVERAGE")
        #expect(nightly.headerContent(series).trailing == "14 OF 30 NIGHTS")
        let daily = LooprMetricTrendCard(title: "Steps", points: points, endingOn: ending,
            range: .constant(.month), kind: .line, accent: .brand, unit: "steps", valueFormat: { String(format: "%.0f", $0) })
        #expect(daily.headerContent(series).eyebrow == "30-DAY AVERAGE")
        #expect(daily.headerContent(series).trailing == "14 OF 30 DAYS")
    }

    // MARK: Minimum y span

    @Test func twoCloseReadingsDoNotFillTheChartHeight() {
        let points = [LooprChartPoint(date: day(1), value: 46), LooprChartPoint(date: day(0), value: 42)]
        let fitted = LooprChartSeries.prepare(points, range: .week, endingOn: end, calendar: calendar)
        let scaled = LooprChartSeries.prepare(points, range: .week, endingOn: end, scale: LooprChartScaleHint(minimumSpan: 20), calendar: calendar)
        #expect(fitted.yDomain.upperBound - fitted.yDomain.lowerBound < 10)
        #expect(scaled.yDomain.upperBound - scaled.yDomain.lowerBound >= 20)
        #expect(scaled.yDomain.contains(42) && scaled.yDomain.contains(46))
        // Centred on the data.
        let middle = (scaled.yDomain.upperBound + scaled.yDomain.lowerBound) / 2
        #expect(abs(middle - 44) < 0.001)
    }

    @Test func boundsKeepAScoreOnItsScale() {
        let points = [20.0, 55, 90].enumerated().map { LooprChartPoint(date: day($0.offset), value: $0.element) }
        let series = LooprChartSeries.prepare(points, range: .week, endingOn: end, scale: LooprChartScaleHint(minimumSpan: 100, bounds: 0...100), calendar: calendar)
        #expect(series.yDomain == 0...100)
        let high = [LooprChartPoint(date: day(0), value: 96), LooprChartPoint(date: day(1), value: 94)]
        let slid = LooprChartSeries.prepare(high, range: .week, endingOn: end, scale: LooprChartScaleHint(minimumSpan: 40, bounds: 0...100), calendar: calendar)
        #expect(slid.yDomain.upperBound == 100)
        #expect(slid.yDomain.upperBound - slid.yDomain.lowerBound >= 40)
    }

    @Test func aReadingOutsideTheBoundsIsNeverCut() {
        let points = [LooprChartPoint(date: day(0), value: 104), LooprChartPoint(date: day(1), value: 98)]
        let series = LooprChartSeries.prepare(points, range: .week, endingOn: end, scale: LooprChartScaleHint(minimumSpan: 10, bounds: 0...100), calendar: calendar)
        #expect(series.yDomain.contains(104))
    }

    @Test func barsReachAtLeastTheMinimumSpan() {
        let points = [LooprChartPoint(date: day(0), value: 8.6), LooprChartPoint(date: day(1), value: 6)]
        let strain = LooprChartSeries.prepare(points, range: .week, endingOn: end, kind: .bars, scale: LooprChartScaleHint(minimumSpan: 21, bounds: 0...21), calendar: calendar)
        #expect(strain.yDomain == 0...21)
        let plain = LooprChartSeries.prepare(points, range: .week, endingOn: end, kind: .bars, calendar: calendar)
        #expect(plain.yDomain.upperBound < 10)
    }

    @Test func noHintKeepsTheOldDomain() {
        let points = (0..<7).map { LooprChartPoint(date: day($0), value: 50 + Double($0)) }
        let old = LooprChartSeries.yDomain(for: LooprChartSeries.prepare(points, range: .week, endingOn: end, calendar: calendar).points, kind: .line, baseline: nil)
        let new = LooprChartSeries.prepare(points, range: .week, endingOn: end, scale: nil, calendar: calendar).yDomain
        #expect(old == new)
    }

    // MARK: Range unlocking

    @Test func rangesUnlockAsHistoryGrows() {
        #expect(LooprChartRange.unlocked(historyDays: 0) == [.week])
        #expect(LooprChartRange.unlocked(historyDays: 3) == [.week])
        #expect(LooprChartRange.unlocked(historyDays: 7) == [.week])
        #expect(LooprChartRange.unlocked(historyDays: 8) == [.week, .month])
        #expect(LooprChartRange.unlocked(historyDays: 30) == [.week, .month])
        #expect(LooprChartRange.unlocked(historyDays: 31) == [.week, .month, .quarter])
        #expect(LooprChartRange.unlocked(historyDays: 90) == [.week, .month, .quarter])
        #expect(LooprChartRange.unlocked(historyDays: 91) == Set(LooprChartRange.allCases))
    }

    @Test func historyDaysCountFromTheFirstReadingToTheDayShown() {
        let points = [LooprChartPoint(date: day(2), value: 1), LooprChartPoint(date: day(0), value: 1)]
        #expect(LooprChartRange.historyDays(points, endingOn: end, calendar: calendar) == 3)
        #expect(LooprChartRange.historyDays([], endingOn: end, calendar: calendar) == 0)
        // A reading after the day shown does not count.
        let later = [LooprChartPoint(date: calendar.date(byAdding: .day, value: 3, to: end)!, value: 1)]
        #expect(LooprChartRange.historyDays(later, endingOn: end, calendar: calendar) == 0)
    }

    @Test func aLockedChoiceFallsBackWithoutBeingForgotten() {
        #expect(LooprChartRange.resolved(.month, available: [.week]) == .week)
        #expect(LooprChartRange.resolved(.year, available: [.week, .month, .quarter]) == .quarter)
        #expect(LooprChartRange.resolved(.month, available: [.week, .month]) == .month)
        #expect(LooprChartRange.resolved(.quarter, available: nil) == .quarter)
        #expect(LooprChartRange.resolved(.week, available: [.month]) == .month)
    }

    @Test func optionsKnowWhenRangesAreLocked() {
        #expect(!LooprTrendCardOptions.standard.hasLockedRanges)
        #expect(LooprTrendCardOptions(availableRanges: [.week]).hasLockedRanges)
        #expect(!LooprTrendCardOptions(availableRanges: Set(LooprChartRange.allCases)).hasLockedRanges)
    }

    @Test func countNounsReadNaturally() {
        #expect(LooprCountNoun.nights.count(1) == "1 night")
        #expect(LooprCountNoun.nights.count(2) == "2 nights")
        #expect(LooprCountNoun.days.count(7) == "7 days")
    }

    // MARK: Weekday labels

    @Test func everyDayLabelCarriesItsWeekday() {
        let week = LooprChartWindow(dayCount: 7)
        let month = LooprChartWindow(dayCount: 30)
        let quarter = LooprChartWindow(dayCount: 90)
        #expect(LooprTrendAxis.label(for: end, window: week, calendar: calendar) == "WED\n23")
        #expect(LooprTrendAxis.label(for: end, window: month, calendar: calendar) == "WED\n23 SEP")
        #expect(LooprTrendAxis.label(for: end, window: quarter, calendar: calendar) == "SEP")
        #expect(LooprChartDateText.day(end, calendar: calendar) == "WED 23 SEP")
    }

    // MARK: Recovery calendar

    @Test func calendarRowsCoverOnlyTheMonthsWithHistory() {
        let points = (0..<40).map { LooprChartPoint(date: day($0), value: Double(($0 * 7) % 100)) }
        let model = LooprRecoveryCalendarModel(points: points, endingOn: end, calendar: calendar)
        // 40 days back from 23 Sep reaches into August.
        #expect(model.months.map(\.title) == ["AUG", "SEP"])
        #expect(model.months.first?.days.count == 31)
        // September stops at the day shown.
        #expect(model.months.last?.days.count == 23)
        #expect(model.scoredDays == 40)
        #expect(model.isWorthShowing)
    }

    @Test func calendarCountsBandsAndKeepsGaps() {
        let points = [
            LooprChartPoint(date: day(0), value: 80),
            LooprChartPoint(date: day(1), value: 50),
            LooprChartPoint(date: day(3), value: 20),
            LooprChartPoint(date: day(4), value: 66.6)
        ]
        let model = LooprRecoveryCalendarModel(points: points, endingOn: end, calendar: calendar)
        #expect(model.counts[.high] == 2)
        #expect(model.counts[.middle] == 1)
        #expect(model.counts[.low] == 1)
        #expect(model.day(on: day(2))?.score == nil)
        #expect(model.day(on: day(2))?.band == nil)
        #expect(!model.isWorthShowing)
        #expect(model.latestScored?.date == day(0))
        #expect(model.readout(for: model.latestScored!) == "WED 23 SEP · 80% · READY")
        #expect(model.readout(for: model.day(on: day(2))!) == "MON 21 SEP · NO SCORE")
        #expect(model.spokenSummary == "4 days scored: 2 ready, 1 steady, 1 recover")
    }

    @Test func calendarShowsAtMostTwelveMonths() {
        let points = (0..<500).map { LooprChartPoint(date: day($0), value: 60) }
        let model = LooprRecoveryCalendarModel(points: points, endingOn: end, calendar: calendar)
        #expect(model.months.count == 12)
        #expect(model.months.first?.title == "OCT")
        #expect(Set(model.months.map(\.title)).count == 12)
    }

    @Test func calendarTapMapsToADay() {
        #expect(LooprRecoveryCalendarModel.dayIndex(x: 0, width: 310) == 0)
        #expect(LooprRecoveryCalendarModel.dayIndex(x: 309, width: 310) == 30)
        #expect(LooprRecoveryCalendarModel.dayIndex(x: 15, width: 310) == 1)
        #expect(LooprRecoveryCalendarModel.dayIndex(x: -1, width: 310) == nil)
        #expect(LooprRecoveryCalendarModel.dayIndex(x: 5, width: 0) == nil)
    }
}
