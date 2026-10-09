import DesignSystem
import DomainKit
import Foundation
import JournalKit
import Testing
import TodayKit
@testable import Loopr

/// The Today context source: the recovery split, the resting trend, journal
/// factors and tonight's inputs, read the way the Today tab reads them.
struct TodayContextSourceTests {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    private static let day = DayIdentity(year: 2023, month: 11, day: 14)
    private static let dayStart = calendar.date(from: DateComponents(year: 2023, month: 11, day: 14))!

    private func fixtureHistory() -> [TodayTrackedMetric: [LooprChartPoint]] {
        Dictionary(uniqueKeysWithValues: TodayTrackedMetric.allCases.map { metric in
            (metric, LooprFixtureMetrics.history(metric.linkID, days: TodayDayContext.historyDays,
                                                 endingOn: Self.dayStart, calendar: Self.calendar))
        })
    }

    @Test func theFixtureSplitReproducesTheFixtureRecovery() throws {
        let split = try #require(LooprTodayContextSource.recoveryBreakdown(
            summary: TodayFixtures.populated, history: fixtureHistory(), dayStart: Self.dayStart, calendar: Self.calendar))
        let score = try #require(split.score)
        let shown = try #require(TodayFixtures.populated.metric(.readiness)?.numericValue)
        #expect(split.explains(shown), "fixture split scores \(score), the fixture shows \(shown)")
        #expect(split.inputs.map(\.signal) == [.hrv, .restingHeartRate, .respiratoryRate])
        #expect(split.input(.hrv)?.status == .used)
        #expect(split.input(.respiratoryRate)?.status == .used)
        // DEC-05.4 refuses a resting-HR spread below the 1 bpm step.
        let resting = try #require(split.input(.restingHeartRate))
        #expect(resting.status == .flatBaseline)
        #expect(resting.value == LooprFixtureMetrics.today(LooprMetricLinkID.restingHeartRate))
        #expect(resting.baselineNights == 28)
        #expect(resting.contribution == nil)
        #expect(resting.points == nil)
        #expect(shown == LooprFixtureMetrics.today(LooprMetricLinkID.recovery))
        #expect(shown == 79)
        #expect(score.rounded() == shown)
        #expect(split.isMeaningful)
        #expect(!split.isSaturated)
        let points = split.inputs.compactMap(\.points).reduce(0, +)
        #expect(abs(points - (score - 50)) < 1e-6)
    }

    @Test func theBaselineIsTheTwentyEightNightsBefore() throws {
        var history: [TodayTrackedMetric: [LooprChartPoint]] = [:]
        // 40 nights at 50 ms with spread, then the day. Only 28 count.
        history[.hrv] = (1...40).map { offset in
            LooprChartPoint(date: Self.calendar.date(byAdding: .day, value: -offset, to: Self.dayStart)!,
                            value: 50 + Double(offset % 5) - 2)
        } + [LooprChartPoint(date: Self.dayStart, value: 60)]
        let split = try #require(LooprTodayContextSource.recoveryBreakdown(
            summary: nil, history: history, dayStart: Self.dayStart, calendar: Self.calendar))
        #expect(split.input(.hrv)?.baselineNights == 28)
        #expect(split.input(.hrv)?.value == 60)
        #expect(split.input(.restingHeartRate)?.status == .noReading)
    }

    @Test func noReadingsMeansNoSplit() {
        #expect(LooprTodayContextSource.recoveryBreakdown(summary: nil, history: [:], dayStart: Self.dayStart,
                                                          calendar: Self.calendar) == nil)
    }

    @Test func aRestingHeartRateThatStaysUpIsPersistent() {
        func points(tail: [Double]) -> [LooprChartPoint] {
            let base = (0..<30).map { 52 + Double($0 % 3) }
            let values = base + tail
            return values.enumerated().map { index, value in
                LooprChartPoint(date: Self.calendar.date(byAdding: .day, value: index - (values.count - 1), to: Self.dayStart)!,
                                value: value)
            }
        }
        #expect(LooprTodayContextSource.restingTrend(points(tail: [53]), dayStart: Self.dayStart, calendar: Self.calendar) == .usual)
        #expect(LooprTodayContextSource.restingTrend(points(tail: [60, 61, 61]), dayStart: Self.dayStart, calendar: Self.calendar) == .persistent)
    }

    @Test func journalFactorsAreCountedAndCleaned() {
        let entries = [
            JournalEntry(day: "2023-11-13", behaviors: ["alcohol", "late_meal"], tags: ["travel"]),
            JournalEntry(day: "2023-11-14", behaviors: ["alcohol"])
        ]
        #expect(LooprTodayContextSource.factors(entries) == ["alcohol", "late meal", "travel"])
    }

    @Test func clockLabelsBecomeMinutes() {
        #expect(LooprTodayContextSource.minute(of: "07:30") == 450)
        #expect(LooprTodayContextSource.minute(of: "24:10") == nil)
        #expect(LooprTodayContextSource.minute(of: "7") == nil)
    }

    @Test func theSourceReadsHistoryJournalSleepAndTheAlarm() async throws {
        let source = LooprTodayContextSource(
            history: FixtureMetricHistoryProvider(calendar: Self.calendar),
            timeZone: TimeZone(identifier: "UTC")!,
            sleepDay: { _ in nil },
            bodyDay: { _ in nil },
            journalEntries: { days in
                #expect(days == ["2023-11-13", "2023-11-14"])
                return [JournalEntry(day: "2023-11-13", behaviors: ["alcohol"])]
            },
            alarmMinute: { 420 }
        )
        let context = try #require(try await source.context(for: Self.day, summary: TodayFixtures.populated))
        #expect(context.history[.hrv]?.last?.value == LooprFixtureMetrics.today(LooprMetricLinkID.rmssd))
        #expect(context.journalFactors == ["alcohol"])
        #expect(context.tonight?.alarmMinute == 420)
        #expect(context.tonight?.needMinutes == LooprFixtureMetrics.sleepNeedMinutes)
        let recovery = try #require(TodayFixtures.populated.metric(.readiness)?.numericValue)
        #expect(context.suggestedStrainRange == StrainTarget(recovery: recovery)?.range)
        #expect(context.strainTarget?.range == context.suggestedStrainRange)
        #expect(context.suggestedStrainRange == 14...18)
    }

    @Test func historySuppliesRecoveryWhenSummaryIsEmpty() async throws {
        let source = LooprTodayContextSource(
            history: FixtureMetricHistoryProvider(calendar: Self.calendar),
            timeZone: TimeZone(identifier: "UTC")!,
            sleepDay: { _ in nil }, bodyDay: { _ in nil },
            journalEntries: { _ in [] }, alarmMinute: { nil }
        )
        let context = try #require(try await source.context(for: Self.day, summary: TodayFixtures.empty))
        // The fixture history still contains recovery for this day, so the
        // history-backed range agrees with Body when the summary is empty.
        #expect(context.suggestedStrainRange == 14...18)
    }

    @Test func noRecoveryMeansNoSuggestedStrainRange() async throws {
        let source = LooprTodayContextSource(
            history: EmptyMetricHistoryProvider(), timeZone: TimeZone(identifier: "UTC")!,
            sleepDay: { _ in nil }, bodyDay: { _ in nil },
            journalEntries: { _ in [] }, alarmMinute: { nil }
        )
        let context = try #require(try await source.context(for: Self.day, summary: TodayFixtures.empty))
        #expect(context.suggestedStrainRange == nil)
    }
}
