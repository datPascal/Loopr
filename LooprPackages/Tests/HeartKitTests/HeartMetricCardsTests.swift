import DesignSystem
import DomainKit
import Foundation
import Testing
@testable import HeartKit

struct HeartMetricCardsTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }

    private var today: Date { calendar.date(from: DateComponents(year: 2026, month: 9, day: 23, hour: 8))! }

    private func history(_ values: [Double]) -> [LooprChartPoint] {
        values.enumerated().map { index, value in
            LooprChartPoint(date: calendar.date(byAdding: .day, value: -(index + 1), to: calendar.startOfDay(for: today))!, value: value)
        }
    }

    @Test func everyDerivedHeartMetricLinksToADetailPage() {
        #expect(HeartMetricID.sleepingHeartRate.metricLinkID == LooprMetricLinkID.sleepingHeartRate)
        #expect(HeartMetricID.maxHeartRate.metricLinkID == LooprMetricLinkID.maxHeartRate)
        #expect(HeartMetricID.restingHeartRate.metricLinkID == LooprMetricLinkID.restingHeartRate)
        #expect(HeartMetricID.rmssd.metricLinkID == LooprMetricLinkID.rmssd)
        #expect(HeartMetricID.sdnn.metricLinkID == LooprMetricLinkID.sdnn)
        #expect(HeartMetricID.pNN50.metricLinkID == LooprMetricLinkID.pNN50)
        #expect(HeartMetricID.respiration.metricLinkID == LooprMetricLinkID.respiratoryRate)
        #expect(HeartMetricID.frequencyDomain.metricLinkID == nil)
        #expect(HeartMetricID.quality.metricLinkID == nil)
    }

    @Test func comparisonWithinAboveAndBelow() {
        let days = history(Array(repeating: 50, count: 10) + Array(repeating: 52, count: 10))
        #expect(HeartBaselineComparison.make(value: 51, unit: "bpm", history: days, today: today, calendar: calendar) == .within)
        #expect(HeartBaselineComparison.make(value: 60, unit: "bpm", history: days, today: today, calendar: calendar) == .above("9 bpm"))
        #expect(HeartBaselineComparison.make(value: 40, unit: "ms", history: days, today: today, calendar: calendar) == .below("11 ms"))
        #expect(HeartBaselineComparison.above("9 bpm").label == "+9 bpm vs usual")
        #expect(HeartBaselineComparison.within.label == "Usual")
    }

    @Test func comparisonLearnsUntilFourteenDays() {
        let days = history(Array(repeating: 50, count: 5))
        let result = HeartBaselineComparison.make(value: 51, unit: "bpm", history: days, today: today, calendar: calendar)
        #expect(result == .learning(measuredDays: 6, neededDays: 14))
        #expect(result?.label == "Learning your usual · 6 of 14 nights")
    }

    @Test func selectedNightCountsWithOneEarlierReading() {
        let result = HeartBaselineComparison.make(value: 42, unit: "ms", history: history([46]), today: today, calendar: calendar)
        #expect(result?.label == "Learning your usual · 2 of 14 nights")
    }

    @Test func noValueMeansNoComparison() {
        #expect(HeartBaselineComparison.make(value: nil, unit: "bpm", history: [], today: today, calendar: calendar) == nil)
        #expect(HeartBaselineComparison.make(value: .nan, unit: "bpm", history: [], today: today, calendar: calendar) == nil)
    }

    @Test func trendChartsEndOnTheSelectedDay() throws {
        let selected = DayIdentity(year: 2023, month: 11, day: 14)
        let end = try #require(HeartTrendCharts.endDate(for: selected, calendar: calendar))
        #expect(calendar.component(.year, from: end) == 2023)
        #expect(calendar.component(.month, from: end) == 11)
        #expect(calendar.component(.day, from: end) == 14)
    }
}
