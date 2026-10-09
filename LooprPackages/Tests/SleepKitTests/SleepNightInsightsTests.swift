import Foundation
import Testing
import DomainKit
import DesignSystem
@testable import SleepKit

/// The rules behind the Sleep tab: usual ranges, the target, the debt ledger,
/// bedtime consistency, tonight's bedtime, stage shares and the heart line.
struct SleepNightInsightsTests {
    // MARK: Helpers

    static let utc = TimeZone(secondsFromGMT: 0)!
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return calendar
    }

    /// A date on `label` (yyyy-MM-dd) at hour:minute UTC.
    static func at(_ label: String, _ hour: Int, _ minute: Int = 0) -> Date {
        let day = SleepCivilDay(label: label)!
        return calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: hour, minute: minute))!
    }

    /// `label` moved by `days`.
    static func label(_ label: String, plus days: Int) -> String {
        let day = SleepCivilDay(label: label)!.adding(days: days)!
        return String(format: "%04d-%02d-%02d", day.year, day.month, day.day)
    }

    static func point(_ label: String, hours: Double?, values: [String: Double] = [:], bed: (Int, Int)? = nil, wake: (Int, Int)? = nil) -> SleepTrendPoint {
        let start = bed.map { $0.0 >= 12 ? at(Self.label(label, plus: -1), $0.0, $0.1) : at(label, $0.0, $0.1) }
        let end = wake.map { at(label, $0.0, $0.1) }
        return SleepTrendPoint(id: label, localDay: label, value: hours, state: .partial, unit: "hours",
                               start: start, end: end, values: values)
    }

    static let day = DayIdentity(year: 2026, month: 9, day: 23)   // a Wednesday

    static func snapshot(trend: [SleepTrendPoint], needHours: Double? = nil, metrics: [SleepMetricValue] = [],
                         main: Bool = true) -> SleepDaySnapshot {
        let mainSleep = main ? SleepSessionSummary(id: "n", start: at("2026-09-22", 23, 25), end: at("2026-09-23", 7, 16),
                                                   durationMinutes: 452, isMainSleep: true, isPartial: false,
                                                   confidence: 0.9, state: .partial) : nil
        return SleepDaySnapshot(day: day, state: .partial, mainSleep: mainSleep, metrics: metrics, trend: trend,
                                needHours: needHours, source: "test")
    }

    static func metric(_ id: String, _ value: Double?, state: MetricState = .partial) -> SleepMetricValue {
        SleepMetricValue(id: id, title: id, value: value.map { "\($0)" }, unit: "minutes", state: value == nil ? .absent : state,
                         source: "test", numericValue: value)
    }

    static func close(_ value: Double?, _ expected: Double) -> Bool {
        guard let value else { return false }
        return abs(value - expected) < 0.001
    }

    // MARK: Usual range

    @Test func percentilesInterpolateBetweenRanks() {
        #expect(SleepUsualRange.percentile([1, 2, 3, 4, 5], 25) == 2)
        #expect(SleepUsualRange.percentile([1, 2, 3, 4, 5], 75) == 4)
        #expect(SleepUsualRange.percentile([10, 20], 25) == 12.5)
        #expect(SleepUsualRange.percentile([7], 75) == 7)
        #expect(SleepUsualRange.percentile([], 50) == nil)
        #expect(SleepUsualRange.percentile([.nan, 3], 50) == 3)
    }

    @Test func aUsualRangeNeedsFiveNights() {
        #expect(SleepUsualRange.compute([60, 70, 80, 90]) == nil)
        let range = SleepUsualRange.compute([60, 70, 80, 90, 100])
        #expect(range == SleepUsualRange(lower: 70, median: 80, upper: 90, nights: 5))
        #expect(range?.band.lower == 70)
        #expect(range?.band.upper == 90)
    }

    @Test func usualIsBuiltFromEarlierNightsInsideThirtyDaysOnly() {
        var trend = (1...6).map { Self.point(Self.label("2026-09-23", plus: -$0), hours: 7, values: ["deep": Double(60 + $0)]) }
        // Too old: 31 days back.
        trend.append(Self.point(Self.label("2026-09-23", plus: -31), hours: 7, values: ["deep": 500]))
        // The selected night itself never counts towards its own usual.
        trend.append(Self.point("2026-09-23", hours: 7.5, values: ["deep": 400]))
        let history = SleepNightHistory(trend: trend, day: Self.day)
        #expect(history.current?.value("deep") == 400)
        #expect(history.prior.count == 7)
        let usual = SleepUsual.of("deep", in: history)
        #expect(usual.range?.nights == 6)
        #expect(usual.range?.median == 63.5)
        #expect((usual.range?.upper ?? 0) < 100)
    }

    @Test func usualSaysLearningWithTheCountUntilFiveNights() {
        let trend = (1...2).map { Self.point(Self.label("2026-09-23", plus: -$0), hours: 7, values: ["deep": 70]) }
        let usual = SleepUsual.of("deep", in: SleepNightHistory(trend: trend, day: Self.day))
        #expect(usual == .learning(measured: 2, needed: 5))
        #expect(usual.delta(for: 76, higherIsBetter: true, format: .duration)?.text == "Learning your usual · 2 of 5 nights")
        #expect(usual.delta(for: nil, higherIsBetter: true, format: .duration) == nil)
    }

    @Test func learningProgressIncludesTheSelectedNight() {
        let trend = [
            Self.point(Self.label("2026-09-23", plus: -1), hours: 7, values: ["deep": 70]),
            Self.point("2026-09-23", hours: 7.5, values: ["deep": 76]),
        ]
        let history = SleepNightHistory(trend: trend, day: Self.day)
        #expect(SleepUsual.ofDuration(in: history) == .learning(measured: 2, needed: 5))
        #expect(SleepUsual.of("deep", in: history) == .learning(measured: 2, needed: 5))
        #expect(SleepUsual.ofDuration(in: history).range == nil)
    }

    @Test func historyIgnoresBadLabelsAndDuplicates() {
        let trend = [Self.point("2026-09-22", hours: 7), Self.point("2026-09-22", hours: 9), Self.point("not-a-day", hours: 8),
                     Self.point("2026-02-30", hours: 8)]
        let history = SleepNightHistory(trend: trend, day: Self.day)
        #expect(history.prior.count == 1)
        #expect(history.prior.first?.asleepMinutes == 420)
        #expect(history.current == nil)
    }

    // MARK: Target

    @Test func savedNeedWinsAndEightHoursIsTheDefault() {
        let history = SleepNightHistory(trend: [], day: Self.day)
        let need = SleepTarget.resolve(needHours: 7.8333, goalMinutes: 480, history: history)
        #expect(need.source == .goal)
        #expect(need.provisionalNote == nil)
        #expect(need.line(asleepMinutes: 432) == "7 h 12 m of 8 h needed")

        let goal = SleepTarget.resolve(needHours: nil, goalMinutes: 480, history: history)
        #expect(goal.source == .goal)
        #expect(goal.minutes == 480)
        #expect(goal.line(asleepMinutes: 432) == "7 h 12 m of 8 h needed")

        let recommended = SleepTarget.resolve(needHours: nil, goalMinutes: nil, history: history)
        #expect(recommended.source == .recommended)
        #expect(recommended.minutes == 480)
        #expect(recommended.line(asleepMinutes: 452) == "7 h 32 m of 8 h needed")
        #expect(recommended.ringScale.allowsOverflow == false)
        #expect(SleepTarget.resolve(needHours: .nan, goalMinutes: 0, history: history).source == .recommended)
    }

    @Test func theProvisionalNoteSaysWhatIsStillMissing() {
        // One earlier Tuesday night: two more nights, one on a weekend.
        let one = SleepNightHistory(trend: [Self.point("2026-09-22", hours: 7.9)], day: Self.day)
        let target = SleepTarget.resolve(needHours: nil, goalMinutes: nil, history: one)
        #expect(target.progress == nil)
        #expect(target.provisionalNote == nil)

        #expect(SleepNeedProgress(nights: 2, hasWeekendNight: true).remainingText == "It needs 1 more night first.")
        #expect(SleepNeedProgress(nights: 5, hasWeekendNight: false).remainingText == "It needs one weekend night first.")
        #expect(SleepNeedProgress(nights: 5, hasWeekendNight: true).remainingText == nil)

        // 2026-09-20 is a Sunday.
        let weekend = SleepNeedProgress(history: SleepNightHistory(trend: [Self.point("2026-09-20", hours: 8)], day: Self.day))
        #expect(weekend.hasWeekendNight)
        // Nights with no main sleep do not count.
        let empty = SleepNeedProgress(history: SleepNightHistory(trend: [Self.point("2026-09-20", hours: nil)], day: Self.day))
        #expect(empty.nights == 0)
    }

    @Test func weekendsAreSaturdayAndSunday() {
        #expect(SleepCivilDay(label: "2026-09-19")!.isWeekend)   // Saturday
        #expect(SleepCivilDay(label: "2026-09-20")!.isWeekend)   // Sunday
        #expect(!SleepCivilDay(label: "2026-09-21")!.isWeekend)  // Monday
        #expect(!SleepCivilDay(label: "2026-09-18")!.isWeekend)  // Friday
    }

    // MARK: Debt ledger

    @Test func theLedgerCoversFourteenNightsWithGapsForMissingOnes() {
        let trend = [Self.point("2026-09-23", hours: 7.5), Self.point("2026-09-22", hours: 8),
                     Self.point("2026-09-09", hours: 6), Self.point("2026-09-08", hours: 5)]
        let history = SleepNightHistory(trend: trend, day: Self.day)
        let ledger = SleepDebtLedger(history: history, target: SleepTarget(minutes: 450, source: .need), calendar: Self.calendar)
        #expect(ledger.nights.count == 14)
        #expect(ledger.nights.first?.day == SleepCivilDay(label: "2026-09-10"))
        #expect(ledger.nights.last?.day == SleepCivilDay(label: "2026-09-23"))
        #expect(ledger.nights.last?.balance == 0)
        #expect(ledger.nights[12].balance == 30)
        #expect(ledger.measuredNights == 2)
        #expect(ledger.nights.dropLast(2).allSatisfy { $0.balance == nil })
        #expect(ledger.bars.count == 14)
        #expect(ledger.suggestion == .needsNights(measured: 2, needed: 3))
        #expect(ledger.actionLine == "A total needs 3 nights. 1 more night to go.")
        #expect(ledger.headline == "2 nights so far")
    }

    @Test func theLedgerSuggestsSpreadingAShortfallOverAWeek() {
        let trend = (0..<14).map { Self.point(Self.label("2026-09-23", plus: -$0), hours: 7) }
        let history = SleepNightHistory(trend: trend, day: Self.day)
        let ledger = SleepDebtLedger(history: history, target: SleepTarget(minutes: 450, source: .need), calendar: Self.calendar)
        #expect(ledger.netMinutes == -420)
        #expect(ledger.suggestion == .behind(minutes: 420, extraPerNight: 60))
        #expect(ledger.headline == "7 h behind")
        #expect(ledger.actionLine == "Going to bed about 1 h earlier each night this week would make it up.")

        #expect(SleepDebtLedger.extraPerNight(forShortfall: 190) == 25)
        #expect(SleepDebtLedger.extraPerNight(forShortfall: 20) == 10)
        #expect(SleepDebtLedger.extraPerNight(forShortfall: 2_000) == 60)
        #expect(SleepDebtLedger.extraPerNight(forShortfall: 0) == 0)
    }

    @Test func theLedgerCallsSmallTotalsEvenAndSurplusesAhead() {
        func ledger(_ hours: [Double], target: Double = 450) -> SleepDebtLedger {
            let trend = hours.enumerated().map { Self.point(Self.label("2026-09-23", plus: -$0.offset), hours: $0.element) }
            return SleepDebtLedger(history: SleepNightHistory(trend: trend, day: Self.day),
                                   target: SleepTarget(minutes: target, source: .need), calendar: Self.calendar)
        }
        let even = ledger([7.5, 7.6, 7.4])
        #expect(even.suggestion == .even)
        #expect(even.headline == "Even")
        let ahead = ledger([8.5, 8.5, 8.5])
        #expect(ahead.suggestion == .ahead(minutes: 180))
        #expect(ahead.headline == "3 h ahead")
        #expect(ahead.actionLine == "You slept 3 h more than the target over these nights. No catching up needed.")
    }

    // MARK: Consistency

    @Test func clockTimesRunNoonToNoonSoNightsDoNotWrap() {
        #expect(SleepClock.minutesAfterNoon(Self.at("2026-09-22", 23), timeZone: Self.utc) == 660)
        #expect(SleepClock.minutesAfterNoon(Self.at("2026-09-23", 1), timeZone: Self.utc) == 780)
        #expect(SleepClock.minutesAfterNoon(Self.at("2026-09-23", 7, 15), timeZone: Self.utc) == 1_155)
        #expect(SleepClock.minutesAfterNoon(Self.at("2026-09-23", 12), timeZone: Self.utc) == 0)
        let posix = Locale(identifier: "en_GB")
        #expect(SleepClock.text(minutesAfterNoon: 660, timeZone: Self.utc, locale: posix) == "23:00")
        #expect(SleepClock.text(minutesAfterNoon: 1_155, timeZone: Self.utc, locale: posix).hasSuffix("7:15"))
    }

    @Test func twoNightsGiveTheFullSpreadAndOneLine() {
        let trend = [Self.point("2026-09-22", hours: 7.9, bed: (22, 47), wake: (7, 13)),
                     Self.point("2026-09-23", hours: 7.5, bed: (23, 25), wake: (7, 16))]
        let consistency = SleepConsistency(history: SleepNightHistory(trend: trend, day: Self.day), calendar: Self.calendar)
        #expect(consistency.nights.count == 14)
        #expect(consistency.measured.count == 2)
        #expect(consistency.usesMiddleHalf == false)
        #expect(consistency.bedRange == 647...685)
        #expect(consistency.wakeRange == 1_153...1_156)
        #expect(consistency.lastBedShift == nil, "Too few nights for a usual bedtime")
        #expect(consistency.summary?.hasPrefix("You went to bed between") == true)
        #expect(consistency.chartDomain.map { $0.lowerBound <= 647 && $0.upperBound >= 1_156 } == true)
    }

    @Test func fiveNightsOrMoreUseTheMiddleHalfAndNameALateNight() {
        var trend = (1...6).map { Self.point(Self.label("2026-09-23", plus: -$0), hours: 7.5, bed: (23, 0), wake: (7, 0)) }
        trend.append(Self.point("2026-09-23", hours: 7, bed: (0, 10), wake: (7, 30)))
        let consistency = SleepConsistency(history: SleepNightHistory(trend: trend, day: Self.day), calendar: Self.calendar)
        #expect(consistency.usesMiddleHalf)
        #expect(consistency.bedRange == 660...660)
        #expect(consistency.usualBed == 660)
        #expect(consistency.lastBedShift == 70)
        #expect(consistency.shiftLine == "This night started 1 h 10 m later than your usual bedtime.")
        #expect(consistency.summary?.hasPrefix("Most nights you went to bed at ") == true)
    }

    @Test func aNightWithoutSleepHasNoTimesEvenIfTheTrendCarriesThem() {
        let trend = [Self.point("2026-09-23", hours: nil, bed: (23, 0), wake: (7, 0))]
        let consistency = SleepConsistency(history: SleepNightHistory(trend: trend, day: Self.day), calendar: Self.calendar)
        #expect(consistency.measured.isEmpty)
        #expect(consistency.summary == nil)
    }

    // MARK: Tonight

    @Test func tonightsBedtimeIsTheUsualWakeMinusTheTargetAndAnyCatchUp() {
        let trend = (0..<5).map { Self.point(Self.label("2026-09-23", plus: -$0), hours: 7.5, bed: (23, 0), wake: (6, 50)) }
        let history = SleepNightHistory(trend: trend, day: Self.day)
        let consistency = SleepConsistency(history: history, calendar: Self.calendar)
        let target = SleepTarget(minutes: 450, source: .need)
        let even = SleepDebtLedger(history: history, target: target, calendar: Self.calendar)
        let plan = SleepTonightPlan(consistency: consistency, target: target, ledger: even)
        #expect(Self.close(plan?.bedtime, 1_130 - 450))
        #expect(plan?.extraMinutes == 0)
        #expect(plan?.detail.hasPrefix("That gives 7 h 30 m before your usual ") == true)

        let short = SleepTarget(minutes: 510, source: .need)
        let behind = SleepDebtLedger(history: history, target: short, calendar: Self.calendar)
        let catchUp = SleepTonightPlan(consistency: consistency, target: short, ledger: behind)
        // Five nights 60 min short: 300 min over a week is about 45 min a night.
        #expect(catchUp?.extraMinutes == 45)
        #expect(Self.close(catchUp?.bedtime, 1_130 - 555))
        #expect(catchUp?.detail.hasSuffix("including 45 min to make up.") == true)
    }

    @Test func tonightCountsBackFromTheSuggestedAlarmWhenThereIsOne() {
        let trend = (0..<5).map { Self.point(Self.label("2026-09-23", plus: -$0), hours: 7.5, bed: (23, 0), wake: (6, 50)) }
        let history = SleepNightHistory(trend: trend, day: Self.day)
        let target = SleepTarget(minutes: 450, source: .need)
        let plan = SleepTonightPlan(consistency: SleepConsistency(history: history, calendar: Self.calendar), target: target,
                                    ledger: SleepDebtLedger(history: history, target: target, calendar: Self.calendar),
                                    suggestedWake: "07:30")
        #expect(Self.close(plan?.bedtime, 1_170 - 450))
        #expect(plan?.wakeIsSuggestedAlarm == true)
        #expect(plan?.detail.contains("before the suggested ") == true)
        #expect(SleepTonightPlan.minutesAfterNoon(clock: "25:00") == nil)
        #expect(SleepTonightPlan.minutesAfterNoon(clock: "06:00") == 1_080)
    }

    @Test func tonightNeedsThreeWakeTimes() {
        let trend = (0..<2).map { Self.point(Self.label("2026-09-23", plus: -$0), hours: 7.5, bed: (23, 0), wake: (6, 50)) }
        let history = SleepNightHistory(trend: trend, day: Self.day)
        let target = SleepTarget(minutes: 450, source: .need)
        #expect(SleepTonightPlan(consistency: SleepConsistency(history: history, calendar: Self.calendar), target: target,
                                 ledger: SleepDebtLedger(history: history, target: target, calendar: Self.calendar)) == nil)
    }

    // MARK: Stages and rows

    @Test func stageSharesAddUpToExactlyOneHundred() {
        #expect(SleepNightInsights.largestRemainderPercents([1, 1, 1]) == [34, 33, 33])
        #expect(SleepNightInsights.largestRemainderPercents([76, 104.5, 271.5]).reduce(0, +) == 100)
        #expect(SleepNightInsights.largestRemainderPercents([0, 0]) == [0, 0])
    }

    @Test func stagesComeFromTheNightTotalsWithAUsualRangeEach() {
        let prior = (1...6).map { Self.point(Self.label("2026-09-23", plus: -$0), hours: 7.5,
                                             values: ["deep": 60, "rem": 100, "light": 280, "awake": 20]) }
        let snapshot = Self.snapshot(trend: prior, metrics: [Self.metric("deep", 76), Self.metric("rem", 104.5),
                                                             Self.metric("light", 271.5), Self.metric("awake", 19.4)])
        let insights = SleepNightInsights(snapshot: snapshot, calendar: Self.calendar)
        #expect(insights.stages.map(\.stage) == [.deep, .rem, .light, .awake])
        #expect(insights.stages.first?.minutes == 76)
        #expect(insights.stages.prefix(3).map(\.percent).reduce(0, +) == 100)
        #expect(insights.stages.first?.usual.range?.median == 60)
        #expect(insights.stages.first?.delta?.text == "+16 min vs usual")
        #expect(insights.stages.first?.usualText == "Usual 1 h")
    }

    @Test func rowsHideUnreliableAndSectionedMetricsAndAddBreathingRate() {
        let current = Self.point("2026-09-23", hours: 7.5, values: ["respiration": 14.2])
        let metrics = ["duration", "efficiency", "deep", "latency", "remLatency", "disturbances", "cycles", "need", "debt", "regularity"]
            .map { Self.metric($0, 5) }
        let insights = SleepNightInsights(snapshot: Self.snapshot(trend: [current], metrics: metrics), calendar: Self.calendar)
        #expect(insights.rows.map(\.id) == ["efficiency", "disturbances", "respiration", "cycles"])
        #expect(insights.rows.map(\.title) == ["Efficiency", "Wake-ups", "Breathing rate", "Estimated cycles"])
        #expect(insights.rows.first { $0.id == "respiration" }?.valueText == "14.2")
        #expect(insights.rows.first { $0.id == "efficiency" }?.metricLinkID == LooprMetricLinkID.sleepEfficiency)
    }

    @Test func aDayWithoutMainSleepHasNoStagesOrRows() {
        let insights = SleepNightInsights(snapshot: Self.snapshot(trend: [], metrics: [Self.metric("deep", 70)], main: false))
        #expect(insights.stages.isEmpty)
        #expect(insights.rows.isEmpty)
    }

    @Test func aSectionStillLearningSaysSoOnce() {
        #expect(SleepNightInsights.learningNote([.learning(measured: 1, needed: 5), .learning(measured: 0, needed: 5)])
                == "Usual ranges appear after 5 nights. You have 1 so far.")
        #expect(SleepNightInsights.learningNote([.learning(measured: 0, needed: 5)]) == "Usual ranges appear after 5 nights. None yet.")
        let range = SleepUsual.range(SleepUsualRange(lower: 1, median: 2, upper: 3, nights: 5))
        #expect(SleepNightInsights.learningNote([.learning(measured: 1, needed: 5), range]) == nil)
        #expect(SleepNightInsights.learningNote([]) == nil)
    }

    @Test @MainActor func trendsPreferHistoryAndFillFromTheNightsUpToTheSelectedDay() {
        let calendar = Self.calendar
        let day = { (label: String) in SleepCivilDay(label: label)!.noon(in: calendar)! }
        let trend = [LooprChartPoint(date: day("2026-09-21"), value: 400), LooprChartPoint(date: day("2026-09-22"), value: 410)]
        let history = [LooprChartPoint(date: calendar.startOfDay(for: day("2026-09-22")), value: 999),
                       LooprChartPoint(date: calendar.startOfDay(for: day("2026-09-25")), value: 1)]
        let merged = SleepTrendsScreen.merged(history: history, trend: trend, endingOn: day("2026-09-23"), calendar: calendar)
        #expect(merged.map(\.value) == [400, 999], "History wins on a shared day; days after the night are left out")
        #expect(SleepTrendsScreen.minuteAxisText(90) == "90 min")
        #expect(SleepTrendsScreen.minuteAxisText(420) == "7 h")
        #expect(SleepTrendsScreen.minuteAxisText(0) == "0")
    }

    // MARK: Trend points

    @Test func trendPointsSavedBeforeNightDetailStillDecode() throws {
        let old = #"{"id":"2026-09-22","localDay":"2026-09-22","value":7.9,"state":"partial","unit":"hours"}"#
        let point = try JSONDecoder().decode(SleepTrendPoint.self, from: Data(old.utf8))
        #expect(point.start == nil)
        #expect(point.values.isEmpty)
        let full = Self.point("2026-09-23", hours: 7.5, values: ["deep": 76], bed: (23, 25), wake: (7, 16))
        #expect(try JSONDecoder().decode(SleepTrendPoint.self, from: JSONEncoder().encode(full)) == full)
    }

    @Test func nightValuesSkipAbsentMetricsAndNightsWithoutSleep() {
        let snapshot = Self.snapshot(trend: [], metrics: [Self.metric("deep", 76), Self.metric("rem", nil),
                                                          Self.metric("latency", 1)])
        #expect(SleepTrendPoint.nightValues(snapshot, breathingRate: 14.5) == ["deep": 76, "respiration": 14.5])
        #expect(SleepTrendPoint.nightValues(Self.snapshot(trend: [], metrics: [Self.metric("deep", 76)], main: false),
                                            breathingRate: 14).isEmpty)
    }

    // MARK: Heart rate

    @Test func theHeartLineNeedsARealShareOfTheNight() {
        let start = Self.at("2026-09-22", 23), end = Self.at("2026-09-23", 7)   // 480 minutes
        func minutes(_ count: Int) -> [SleepHeartRateMinute] {
            (0..<count).map { SleepHeartRateMinute(date: start.addingTimeInterval(Double($0) * 60), bpm: 55) }
        }
        #expect(SleepOvernightHeartRate.make(samples: minutes(29), start: start, end: end) == nil)
        #expect(SleepOvernightHeartRate.make(samples: minutes(100), start: start, end: end) == nil, "Under a quarter of the night")
        #expect(SleepOvernightHeartRate.make(samples: minutes(130), start: start, end: end)?.samples.count == 130)
        let outside = minutes(130) + [SleepHeartRateMinute(date: end.addingTimeInterval(600), bpm: 90)]
        #expect(SleepOvernightHeartRate.make(samples: outside, start: start, end: end)?.highest?.bpm == 55)
    }

    @Test func smoothingTakesTheMedianAndStopsAtGaps() {
        let base = Self.at("2026-09-23", 1)
        let samples = [50.0, 80, 52, 51].enumerated().map { SleepHeartRateMinute(date: base.addingTimeInterval(Double($0.offset) * 60), bpm: $0.element) }
        let smoothed = SleepOvernightHeartRate.smooth(samples)
        #expect(smoothed[1].bpm == 52, "A one-minute spike is flattened")
        let gapped = [SleepHeartRateMinute(date: base, bpm: 50), SleepHeartRateMinute(date: base.addingTimeInterval(900), bpm: 70)]
        #expect(SleepOvernightHeartRate.smooth(gapped).map(\.bpm) == [50, 70])
    }

    // MARK: View model

    @Test @MainActor func theViewModelWorksOutInsightsAndHeartRateOncePerNight() async {
        let repository = InMemorySleepRepository(values: [SleepFixtures.day: SleepFixtures.populated])
        let source = CountingDetailSource()
        let viewModel = SleepViewModel(repository: repository, detailSource: source)
        await viewModel.load(day: SleepFixtures.day)
        #expect(viewModel.insights?.target.source == .recommended)
        #expect(viewModel.heartRate != nil)
        #expect(viewModel.insights?.stages.count == 4)
        await viewModel.load(day: SleepFixtures.day)
        #expect(await source.heartRateReads() == 1, "An identical reload does not read the night again")
    }

    @Test @MainActor func withoutADetailSourceThereIsNoHeartLine() async {
        let repository = InMemorySleepRepository(values: [SleepFixtures.day: SleepFixtures.populated])
        let viewModel = SleepViewModel(repository: repository)
        await viewModel.load(day: SleepFixtures.day)
        #expect(viewModel.heartRate == nil)
        #expect(viewModel.insights != nil)
    }

    @Test @MainActor func aGoalIsUsedWhenThereIsNoNeedYet() async {
        let snapshot = Self.snapshot(trend: [])
        let repository = InMemorySleepRepository(values: [Self.day: snapshot])
        let viewModel = SleepViewModel(repository: repository, detailSource: GoalSource(goal: 480))
        await viewModel.load(day: Self.day)
        #expect(viewModel.insights?.target.source == .goal)
        #expect(viewModel.insights?.target.minutes == 480)
    }
}

private actor CountingDetailSource: SleepNightDetailSource {
    private var reads = 0
    func overnightHeartRate(from start: Date, to end: Date) async -> [SleepHeartRateMinute] {
        reads += 1
        return await SleepFixtures.DetailSource().overnightHeartRate(from: start, to: end)
    }
    func sleepGoalMinutes() async -> Double? { nil }
    func heartRateReads() -> Int { reads }
}

private struct GoalSource: SleepNightDetailSource {
    let goal: Double
    func overnightHeartRate(from start: Date, to end: Date) async -> [SleepHeartRateMinute] { [] }
    func sleepGoalMinutes() async -> Double? { goal }
}
