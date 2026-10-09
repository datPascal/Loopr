import Foundation
import AnalyticsKit
import Testing
import DomainKit
import DesignSystem
@testable import TodayKit

/// Builders for synthetic days: a UTC calendar, a summary with chosen values
/// and history that gives every metric a usual range.
enum TodayTestDays {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    static let day = DayIdentity(year: 2026, month: 9, day: 23)
    static let dayStart = calendar.date(from: DateComponents(year: 2026, month: 9, day: 23))!

    static func metric(_ id: TodayMetricID, _ value: Double?, _ unit: TodayMetricUnitID,
                       state: MetricState = .partial, confidence: String? = nil, source: String = "test") -> TodayMetricValue {
        TodayMetricValue(id: id, title: id.rawValue, value: value.map { String(format: "%.0f", $0) }, unit: "",
                         confidence: confidence, state: value == nil ? .absent : state, source: source,
                         numericValue: value, numericUnit: unit)
    }

    static func summary(recovery: Double? = 74, hrv: Double? = 58, rhr: Double? = 51, sleep: Double? = 462,
                        strain: Double? = 8.6, stress: Double? = 21, steps: Double? = 8_240,
                        strainConfidence: String? = nil,
                        recoveryConfidence: String? = "Based on your recent nights",
                        recoveryState: MetricState = .partial, need: Double? = 450,
                        recoverySource: String = "test",
                        coach: TodayCoachPlanSlot = .placeholder) -> TodaySummary {
        TodaySummary(
            day: day, overallState: .partial,
            freshness: TodayFreshness(state: .partial, updatedAt: nil, ageMinutes: nil, detail: ""),
            device: TodayDeviceSnapshot(connection: .connected, status: .partial),
            metrics: [
                metric(.recovery, recovery, .scorePoints, state: recoveryState, confidence: recoveryConfidence, source: recoverySource),
                metric(.hrv, hrv, .milliseconds),
                metric(.restingHeartRate, rhr, .beatsPerMinute),
                metric(.sleep, sleep, .minutes),
                metric(.strain, strain, .strainScore, confidence: strainConfidence),
                metric(.stress, stress, .scorePoints),
                metric(.steps, steps, .count)
            ],
            coachPlan: coach,
            sleepNeedMinutes: need
        )
    }

    /// `days` nights before the day at `usual` with a little spread, and the
    /// day itself at `today` when given.
    static func series(usual: Double, spread: Double, days: Int = 40, today: Double? = nil, skipping: Set<Int> = []) -> [LooprChartPoint] {
        var points: [LooprChartPoint] = []
        for offset in stride(from: days, through: 1, by: -1) where !skipping.contains(offset) {
            let wobble = [-1.0, -0.5, 0, 0.5, 1][offset % 5] * spread
            points.append(LooprChartPoint(date: calendar.date(byAdding: .day, value: -offset, to: dayStart)!, value: usual + wobble))
        }
        if let today { points.append(LooprChartPoint(date: dayStart, value: today)) }
        return points
    }

    static func context(history: [TodayTrackedMetric: [LooprChartPoint]] = standardHistory(),
                        recovery: TodayRecoveryBreakdown? = nil,
                        restingTrend: TodayRestingTrend = .usual,
                        journal: [String] = [],
                        tonight: TodayTonightInputs? = nil) -> TodayDayContext {
        TodayDayContext(day: day, dayStart: dayStart, history: history, recovery: recovery, restingTrend: restingTrend,
                        journalFactors: journal, tonight: tonight)
    }

    static func standardHistory(respiratoryToday: Double? = 14.6, recoveryToday: Double? = 74,
                                sleepToday: Double? = 462) -> [TodayTrackedMetric: [LooprChartPoint]] {
        [
            .hrv: series(usual: 51, spread: 4, today: 58),
            .restingHeartRate: series(usual: 54, spread: 1.4, today: 51),
            .respiratoryRate: series(usual: 14.7, spread: 0.3, today: respiratoryToday),
            .sleep: series(usual: 450, spread: 28, today: sleepToday),
            .recovery: series(usual: 62, spread: 10, today: recoveryToday),
            .strain: series(usual: 11.5, spread: 2.5, today: 8.6),
            .stress: series(usual: 30, spread: 6, today: 21),
            .steps: series(usual: 8_400, spread: 1_800, today: 8_240),
            .activeEnergy: series(usual: 640, spread: 140, today: 612)
        ]
    }

    static func breakdown(score: Double?, hrvPoints: Double = 14, rhrPoints: Double = 8, rrPoints: Double = 2,
                          meaningful: Bool = true) -> TodayRecoveryBreakdown {
        let total = hrvPoints + rhrPoints + rrPoints
        func input(_ signal: TodayRecoveryBreakdown.Signal, _ value: Double, _ usual: Double, _ points: Double) -> TodayRecoveryBreakdown.Input {
            .init(signal: signal, status: .used, value: value, usual: usual, baselineNights: 28, weight: 0.4,
                  contribution: total == 0 ? 0 : points / 50, points: points)
        }
        return TodayRecoveryBreakdown(
            score: score, isSaturated: false, isMeaningful: meaningful,
            inputs: [input(.hrv, 58, 51, hrvPoints), input(.restingHeartRate, 51, 54, rhrPoints), input(.respiratoryRate, 14.6, 14.7, rrPoints)],
            nightsNeeded: 3
        )
    }

    static func dashboard(_ summary: TodaySummary, _ context: TodayDayContext?, isToday: Bool = true,
                          pinned: [TodayTrackedMetric] = TodayPreferences.defaultPinned, dismissed: Bool = false) -> TodayDashboard {
        TodayDashboard(summary: summary, context: context, pinned: pinned, isToday: isToday, headsUpDismissed: dismissed,
                       dayLabel: TodayDashboard.shortDayLabel, calendar: calendar)
    }
}

struct TodayHeroTests {
    @Test func aHighScoreIsColouredReadyAndNamesTheBiggestPositiveDriver() throws {
        let context = TodayTestDays.context(recovery: TodayTestDays.breakdown(score: 74))
        let hero = TodayTestDays.dashboard(TodayTestDays.summary(), context).hero
        guard case .scored(let reading) = hero else { Issue.record("expected scored, got \(hero)"); return }
        #expect(reading.band == .high)
        #expect(reading.band.verdict == "Ready")
        #expect(reading.sentence == "Higher HRV and a lower resting heart rate supported this score. Keep strain between 14 and 18 today.")
    }

    @Test func theSentenceFollowsTheSplitNotTheRowOrder() {
        let split = TodayTestDays.breakdown(score: 74, hrvPoints: 4, rhrPoints: 18, rrPoints: 2)
        let hero = TodayTestDays.dashboard(TodayTestDays.summary(), TodayTestDays.context(recovery: split)).hero
        #expect(hero.reading?.sentence == "A lower resting heart rate and higher HRV supported this score. Keep strain between 14 and 18 today.")
    }

    @Test func aHighScoreNeverNamesADriverThatPulledDown() {
        // Breathing pulled down hardest, but the score is high: name the
        // largest push that agrees with the verdict.
        let split = TodayTestDays.breakdown(score: 74, hrvPoints: 16, rhrPoints: 10, rrPoints: -2)
        let hero = TodayTestDays.dashboard(TodayTestDays.summary(), TodayTestDays.context(recovery: split)).hero
        #expect(hero.reading?.sentence.hasPrefix("Higher HRV") == true)
    }

    @Test func aLowScoreNamesTheBiggestNegativeDriverAndSuggestsRest() {
        var history = TodayTestDays.standardHistory()
        history[.hrv] = TodayTestDays.series(usual: 51, spread: 4, today: 38)
        let split = TodayRecoveryBreakdown(
            score: 22, isSaturated: false, isMeaningful: true,
            inputs: [
                .init(signal: .hrv, status: .used, value: 38, usual: 51, baselineNights: 28, weight: 0.4, contribution: -0.9, points: -20),
                .init(signal: .restingHeartRate, status: .used, value: 58, usual: 54, baselineNights: 28, weight: 0.3, contribution: -0.3, points: -7),
                .init(signal: .respiratoryRate, status: .used, value: 14.7, usual: 14.7, baselineNights: 28, weight: 0.2, contribution: -0.05, points: -1)
            ],
            nightsNeeded: 3
        )
        let summary = TodayTestDays.summary(recovery: 22, hrv: 38, rhr: 58)
        let hero = TodayTestDays.dashboard(summary, TodayTestDays.context(history: history, recovery: split)).hero
        #expect(hero.reading?.band == .low)
        #expect(hero.reading?.sentence == "Lower HRV and a higher resting heart rate lowered this score. Keep strain between 4 and 10 today.")
    }

    @Test func aScoreTheSplitDoesNotReproduceDoesNotInventContributions() {
        // The split says 60, the screen says 74: its points are not used.
        let split = TodayTestDays.breakdown(score: 60, hrvPoints: 1, rhrPoints: 20, rrPoints: 1)
        let hero = TodayTestDays.dashboard(TodayTestDays.summary(), TodayTestDays.context(recovery: split)).hero
        // Resting heart rate 51 against a tight 53 to 55 range is the
        // furthest outside its usual range, so it is named.
        #expect(hero.reading?.sentence == "This score reflects the available overnight heart readings. Keep strain between 14 and 18 today.")
    }

    @Test func aDayCloseToUsualSaysSo() {
        let split = TodayTestDays.breakdown(score: 52, meaningful: false)
        let summary = TodayTestDays.summary(recovery: 52)
        let hero = TodayTestDays.dashboard(summary, TodayTestDays.context(recovery: split)).hero
        #expect(hero.reading?.band == .middle)
        #expect(hero.reading?.sentence == "This score reflects the available overnight heart readings. Keep strain between 10 and 14 today.")
    }

    @Test func aPastDaySpeaksInThePastWithoutAdvice() {
        let context = TodayTestDays.context(recovery: TodayTestDays.breakdown(score: 74))
        let hero = TodayTestDays.dashboard(TodayTestDays.summary(), context, isToday: false).hero
        #expect(hero.reading?.sentence == "Higher HRV and a lower resting heart rate supported this score.")
    }

    @Test func todayWithoutLastNightCarriesYesterdayStamped() {
        let summary = TodayTestDays.summary(recovery: nil, hrv: nil, rhr: nil, sleep: nil)
        var history = TodayTestDays.standardHistory(recoveryToday: nil, sleepToday: nil)
        history[.recovery] = TodayTestDays.series(usual: 62, spread: 0, days: 3)
        let hero = TodayTestDays.dashboard(summary, TodayTestDays.context(history: history)).hero
        guard case .carried(let reading, let label, let reason) = hero else { Issue.record("expected carried, got \(hero)"); return }
        #expect(reading.score == 62)
        #expect(label == "Yesterday")
        #expect(reason == "Last night hasn't synced yet, so this is yesterday's score.")
    }

    @Test func todayWithoutLastNightOrAnyEarlierScoreIsCalculating() {
        let summary = TodayTestDays.summary(recovery: nil, hrv: nil, rhr: nil, sleep: nil)
        var history = TodayTestDays.standardHistory(sleepToday: nil)
        history[.recovery] = []
        let hero = TodayTestDays.dashboard(summary, TodayTestDays.context(history: history)).hero
        #expect(hero == .calculating(title: "Waiting for last night",
                                     detail: "Recovery appears once your band syncs last night's sleep."))
    }

    @Test func aPastDayNeverCarriesAnotherDaysScore() {
        let summary = TodayTestDays.summary(recovery: nil, hrv: nil, rhr: nil, sleep: nil)
        let history = TodayTestDays.standardHistory(recoveryToday: nil, sleepToday: nil)
        let hero = TodayTestDays.dashboard(summary, TodayTestDays.context(history: history), isToday: false).hero
        guard case .unavailable(let title, _) = hero else { Issue.record("expected unavailable, got \(hero)"); return }
        #expect(title == "No sleep recorded")
    }

    @Test func learningUsesTheSummarysOwnCountdown() {
        let summary = TodayTestDays.summary(recovery: nil, recoveryConfidence: "2 more nights and this is ready", recoveryState: .settling)
        let hero = TodayTestDays.dashboard(summary, TodayTestDays.context(history: TodayTestDays.standardHistory(recoveryToday: nil))).hero
        guard case .learning(let have, let need, let detail) = hero else { Issue.record("expected learning, got \(hero)"); return }
        #expect(have == 1)
        #expect(need == 3)
        #expect(detail == "2 more nights before recovery can start. It needs at least two usable heart readings and compares them with your own nights.")
    }

    @Test func learningNamesWhyTheCountIsStuck() {
        var history = TodayTestDays.standardHistory(recoveryToday: nil)
        // Sleep on every night, HRV missing on three of the last seven.
        history[.hrv] = TodayTestDays.series(usual: 51, spread: 4, today: 58, skipping: [1, 2, 3])
        let summary = TodayTestDays.summary(recovery: nil, recoveryConfidence: "One more night and this is ready", recoveryState: .settling)
        let hero = TodayTestDays.dashboard(summary, TodayTestDays.context(history: history)).hero
        guard case .learning(let have, _, let detail) = hero else { Issue.record("expected learning, got \(hero)"); return }
        #expect(have == 2)
        #expect(detail.hasPrefix("3 of your last 8 nights had sleep but no HRV reading."))
    }

    @Test func aSaturatedScoreSaysWhy() {
        let summary = TodayTestDays.summary(recovery: nil, recoveryConfidence: "Your last few nights are too alike to compare today against",
                                            recoveryState: .settling)
        let hero = TodayTestDays.dashboard(summary, TodayTestDays.context(history: TodayTestDays.standardHistory(recoveryToday: nil))).hero
        guard case .unavailable(let title, _) = hero else { Issue.record("expected unavailable, got \(hero)"); return }
        #expect(title == "Waiting for more history")
    }

    @Test func aNightWithoutHRVSaysSo() {
        let summary = TodayTestDays.summary(recovery: nil, hrv: nil, recoveryConfidence: nil)
        var history = TodayTestDays.standardHistory(recoveryToday: nil)
        history[.hrv] = TodayTestDays.series(usual: 51, spread: 4)
        let hero = TodayTestDays.dashboard(summary, TodayTestDays.context(history: history), isToday: false).hero
        guard case .unavailable(let title, _) = hero else { Issue.record("expected unavailable, got \(hero)"); return }
        #expect(title == "No HRV last night")
    }

    @Test func remainingNightsParsesBothWordings() {
        #expect(TodayHeroRules.remainingNights(in: "One more night and this is ready") == 1)
        #expect(TodayHeroRules.remainingNights(in: "2 more nights and this is ready") == 2)
        #expect(TodayHeroRules.remainingNights(in: "Based on your recent nights") == nil)
    }
}

struct TodayContributorAndRingTests {
    @Test func theHeroSplitsDriverAndGuidance() {
        let context = TodayTestDays.context(recovery: TodayTestDays.breakdown(score: 74))
        let reading = TodayTestDays.dashboard(TodayTestDays.summary(), context).hero.reading
        #expect(reading?.driver == "Higher HRV and a lower resting heart rate supported this score.")
        #expect(reading?.guidance == "Keep strain between 14 and 18 today.")
        #expect(TodayTestDays.dashboard(TodayTestDays.summary(), context, isToday: false).hero.reading?.guidance == nil)
    }

    @Test func threeSecondaryRingsWithSleepAgainstNeed() {
        let dashboard = TodayTestDays.dashboard(TodayTestDays.summary(), TodayTestDays.context())
        #expect(dashboard.rings.map(\.id) == [.sleep, .strain, .stress])
        #expect(dashboard.rings.map(\.text) == ["7:42", "8.6", "21"])
        #expect(dashboard.rings[0].reading.scale == LooprRingScale(fullValue: 480))
        #expect(dashboard.rings[0].delta?.text == "\u{2212}18 min vs need")
        #expect(dashboard.rings[1].delta?.compactText != nil)
        // Strain has no good direction: never coloured.
        #expect(dashboard.rings[1].delta?.tone == .neutral)
    }

    @Test func theStrainRingDrawsTheSuggestedRangeOnlyWhenOneIsGiven() {
        let without = TodayTestDays.dashboard(TodayTestDays.summary(), TodayTestDays.context())
        #expect(without.rings[1].suggestedRange == nil)
        let context = TodayDayContext(day: TodayTestDays.day, dayStart: TodayTestDays.dayStart,
                                      history: TodayTestDays.standardHistory(), suggestedStrainRange: 10...14)
        let with = TodayTestDays.dashboard(TodayTestDays.summary(), context)
        #expect(with.rings[1].suggestedRange == 10...14)
        #expect(with.rings[0].suggestedRange == nil)
    }

    @Test func missingRingsShowADashNotAZero() {
        let dashboard = TodayTestDays.dashboard(TodayTestDays.summary(stress: nil), TodayTestDays.context())
        #expect(dashboard.rings[2].text == "—")
        #expect(dashboard.rings[2].delta == nil)
    }

    @Test func absentStrainNamesTheMissingProfileField() {
        let summary = TodayTestDays.summary(strain: nil,
                                            strainConfidence: "Add your age or set a maximum heart rate to see strain")
        let dashboard = TodayTestDays.dashboard(summary, TodayTestDays.context())
        #expect(dashboard.rings[1].needsAge)
        #expect(dashboard.rings[1].reading.value == nil)
        #expect(!dashboard.rings[0].needsAge)
    }
}

struct TodayHeadsUpTests {
    private func context(values: [OvernightVitalMetric: Double], journal: [String] = [], baseline: Int = 20) -> TodayDayContext {
        let calendar = TodayTestDays.calendar
        let day = TodayTestDays.dayStart
        var nights: [OvernightVitalsNight] = []
        for offset in stride(from: baseline, through: 0, by: -1) {
            let date = calendar.date(byAdding: .day, value: -offset, to: day)!
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            nights.append(.init(night: String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!),
                values: offset == 0 ? values : [.restingHeartRate: 54, .heartRateVariability: 51, .respiratoryRate: 14.7, .skinTemperatureDeviation: 35]))
        }
        return TodayDayContext(day: TodayTestDays.day, dayStart: day, history: TodayTestDays.standardHistory(),
            journalFactors: journal, overnightAssessment: OvernightVitalsCheck.assessment(nights: nights, calendar: calendar))
    }

    @Test func noCardWithoutCachedAssessmentOrWithOnlyOneOutlier() {
        let summary = TodayTestDays.summary(hrv: 40, rhr: 60)
        #expect(TodayTestDays.dashboard(summary, TodayTestDays.context()).headsUp == nil)
        #expect(TodayTestDays.dashboard(summary, context(values: [.restingHeartRate: 60, .heartRateVariability: 51])).headsUp == nil)
    }

    @Test func firstFlaggedNightUsesSharedSignalValuesAndDirection() throws {
        let summary = TodayTestDays.summary(recovery: 30)
        let card = try #require(TodayTestDays.dashboard(summary, context(values: [.restingHeartRate: 60, .heartRateVariability: 40])).headsUp)
        #expect(card.title == "Two signals outside your usual range")
        #expect(card.signals.map(\.metric) == [.restingHeartRate, .heartRateVariability])
        #expect(card.signals.map(\.text) == ["Resting heart rate +6 bpm", "HRV \u{2212}11 ms"])
    }

    @Test func bothDirectionsCountAndTemperatureCanTriggerCard() throws {
        let summary = TodayTestDays.summary()
        let card = try #require(TodayTestDays.dashboard(summary, context(values: [.restingHeartRate: 44, .skinTemperatureDeviation: 35.6])).headsUp)
        #expect(card.signals.map(\.metric) == [.restingHeartRate, .skinTemperatureDeviation])
        #expect(card.signals.last?.text == "Skin temperature +0.6 °C")
    }

    @Test func missingBaselinesStayQuietAndJournalRemainsOptional() throws {
        let summary = TodayTestDays.summary()
        #expect(TodayTestDays.dashboard(summary, context(values: [.restingHeartRate: 60, .heartRateVariability: 40], baseline: 5)).headsUp == nil)
        let card = try #require(TodayTestDays.dashboard(summary, context(values: [.restingHeartRate: 60, .heartRateVariability: 40, .respiratoryRate: 16], journal: ["alcohol", "late meal"])).headsUp)
        #expect(card.title == "Three signals outside your usual range")
        #expect(card.factors == ["Alcohol", "Late meal"])
    }

    @Test func dismissingHidesItForTheDay() {
        let summary = TodayTestDays.summary()
        #expect(TodayTestDays.dashboard(summary, context(values: [.restingHeartRate: 60, .heartRateVariability: 40]), dismissed: true).headsUp == nil)
    }

    @Test func copyNamesOrdinaryCausesBeforeIllnessWithoutDiagnosis() throws {
        let card = try #require(TodayTestDays.dashboard(TodayTestDays.summary(), context(values: [.restingHeartRate: 60, .heartRateVariability: 40])).headsUp)
        #expect(card.detail.hasPrefix("Alcohol, late meals, a hot room, hard training or travel"))
        for banned in ["diagnos", "infection", "abnormal", "dangerous", "disease", "sick", "—"] {
            #expect(!card.detail.lowercased().contains(banned))
        }
    }
}

struct TodayTilesTonightCoachTests {
    @Test func pinnedTilesFollowTheChosenOrderWithDeltas() {
        let dashboard = TodayTestDays.dashboard(TodayTestDays.summary(), TodayTestDays.context(),
                                                pinned: [.steps, .hrv, .activeEnergy, .respiratoryRate])
        #expect(dashboard.tiles.map(\.metric) == [.steps, .hrv, .activeEnergy, .respiratoryRate])
        #expect(dashboard.tiles.map(\.value) == ["8,240", "58", "612", "14.6"])
        #expect(dashboard.tiles[1].delta?.compactText == "+7 ms")
    }

    @Test func aTileWithoutAReadingStaysEmptyNotZero() {
        var history = TodayTestDays.standardHistory()
        history[.activeEnergy] = TodayTestDays.series(usual: 640, spread: 140)
        let dashboard = TodayTestDays.dashboard(TodayTestDays.summary(), TodayTestDays.context(history: history), pinned: [.activeEnergy])
        #expect(dashboard.tiles[0].value == nil)
        #expect(dashboard.tiles[0].delta == nil)
    }

    @Test func tonightCountsBackFromTheAlarm() {
        let plan = TodayTonightRules.plan(TodayTonightInputs(needMinutes: 470, alarmMinute: 7 * 60, suggestedWakeMinute: 7 * 60 + 30))
        #expect(plan?.title == "Asleep by 23:10")
        #expect(plan?.detail == "That gives you the 7 h 50 m you need before your 07:00 alarm.")
    }

    @Test func tonightFallsBackToTheUsualWakeTimeAndRoundsToFiveMinutes() {
        let plan = TodayTonightRules.plan(TodayTonightInputs(needMinutes: 452, alarmMinute: nil, suggestedWakeMinute: 6 * 60 + 45))
        #expect(plan?.title == "Asleep by 23:15")
        #expect(plan?.detail.hasSuffix("before 06:45, when you usually wake.") == true)
    }

    @Test func noBedtimeWithoutANeedOrAWakeTime() {
        #expect(TodayTonightRules.plan(TodayTonightInputs(needMinutes: nil, alarmMinute: 420, suggestedWakeMinute: nil)) == nil)
        #expect(TodayTonightRules.plan(TodayTonightInputs(needMinutes: 450, alarmMinute: nil, suggestedWakeMinute: nil)) == nil)
    }

    @Test func tonightIsOnlyForToday() {
        let context = TodayTestDays.context(tonight: TodayTonightInputs(needMinutes: 450, alarmMinute: 420, suggestedWakeMinute: nil))
        #expect(TodayTestDays.dashboard(TodayTestDays.summary(), context).tonight != nil)
        #expect(TodayTestDays.dashboard(TodayTestDays.summary(), context, isToday: false).tonight == nil)
    }

    @Test func theBriefingPlanReplacesTheBottomCoachLine() {
        let none = TodayTestDays.dashboard(TodayTestDays.summary(), nil)
        #expect(none.coach == nil)
        let empty = TodayCoachPlanSummary(title: "No plan yet", detail: "Waiting", recommendationCount: 0, evidenceSummary: "", state: .absent)
        #expect(TodayTestDays.dashboard(TodayTestDays.summary(coach: .plan(empty)), nil).coach == nil)
        let real = TodayCoachPlanSummary(title: "An easy walk suits today", detail: "Recovery is steady.", recommendationCount: 1,
                                         evidenceSummary: "readiness", state: .partial)
        #expect(TodayTestDays.dashboard(TodayTestDays.summary(coach: .plan(real)), nil).coach
                == nil)
    }
}
