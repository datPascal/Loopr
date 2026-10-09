import Foundation
import Testing
import DomainKit
import DesignSystem
@testable import TodayKit

struct TodayRingTests {
    // MARK: Sleep

    @Test
    func realNightFillsNinetyFourPercentOfTheDefaultNeed() {
        let day = summary(metrics: [sleep(minutes: 452)])
        let reading = TodayRingReading.reading(for: .sleep, metric: day.metric(.sleep), summary: day)
        #expect(abs((reading.fraction ?? 0) - 452.0 / 480) < 0.0001)
        #expect(reading.percent == 94)
        #expect(TodaySleepNeed.minutes(from: []) == 480)
        #expect(TodaySleepNeed.minutes(from: [sleepGoal(target: "7.5", unit: "hours")]) == 450)
    }

    @Test
    func sleepFillsAgainstTheSleepNeedAndStopsAtAFullRing() {
        let summary = summary(metrics: [sleep(minutes: 528)], goals: [sleepGoal(target: "8", unit: "hours")])
        let reading = TodayRingReading.reading(for: .sleep, metric: summary.metric(.sleep), summary: summary)
        #expect(reading.scale == LooprRingScale(fullValue: 480))
        #expect(reading.fraction == 1)
        #expect(reading.format == .hoursMinutes)
        #expect(reading.accessibilityFill == "100 percent of your sleep need of 8 hours")
    }

    @Test
    func sleepGoalInMinutesAndFractionalHoursBothScale() {
        let minutes = summary(metrics: [sleep(minutes: 225)], goals: [sleepGoal(target: "450", unit: "minutes")])
        #expect(TodayRingReading.reading(for: .sleep, metric: minutes.metric(.sleep), summary: minutes).fraction == 0.5)

        let hours = summary(metrics: [sleep(minutes: 225)], goals: [sleepGoal(target: "7.5", unit: "hours")])
        let reading = TodayRingReading.reading(for: .sleep, metric: hours.metric(.sleep), summary: hours)
        #expect(reading.fraction == 0.5)
        #expect(reading.accessibilityFill == "50 percent of your sleep need of 7.5 hours")
    }

    @Test
    func sleepUsesTheDefaultWhenTheOldSummaryHasADerivedNeed() {
        let summary = summary(metrics: [sleep(minutes: 441)], needMinutes: 490)
        let reading = TodayRingReading.reading(for: .sleep, metric: summary.metric(.sleep), summary: summary)
        #expect(abs((reading.fraction ?? 0) - 441.0 / 480) < 0.0001)
        #expect(reading.accessibilityFill == "92 percent of your sleep need of 8 hours")
    }

    @Test
    func sleepGoalWinsOverTheDerivedNeed() {
        let summary = summary(metrics: [sleep(minutes: 420)], goals: [sleepGoal(target: "7", unit: "hours")], needMinutes: 600)
        #expect(TodayRingReading.reading(for: .sleep, metric: summary.metric(.sleep), summary: summary).fraction == 1)
    }

    @Test
    func sleepWithoutGoalOrNeedUsesEightHours() {
        let summary = summary(metrics: [sleep(minutes: 495)])
        let reading = TodayRingReading.reading(for: .sleep, metric: summary.metric(.sleep), summary: summary)
        #expect(reading.value == 495)
        #expect(reading.scale == LooprRingScale(fullValue: 480))
        #expect(reading.fraction == 1)
        #expect(reading.accessibilityFill == "100 percent of your sleep need of 8 hours")
    }

    @Test
    func unusableSleepGoalIsIgnoredRatherThanGuessed() {
        for goal in [sleepGoal(target: nil, unit: "hours"), sleepGoal(target: "0", unit: "hours"),
                     sleepGoal(target: "eight", unit: "hours"), sleepGoal(target: "8", unit: "nights")] {
            let summary = summary(metrics: [sleep(minutes: 420)], goals: [goal])
            #expect(TodayRingReading.reading(for: .sleep, metric: summary.metric(.sleep), summary: summary).scale == LooprRingScale(fullValue: 480))
        }
    }

    @Test
    func sleepOverflowStopsAtAFullRing() {
        let summary = summary(metrics: [sleep(minutes: 1_200)], goals: [sleepGoal(target: "5", unit: "hours")])
        #expect(TodayRingReading.reading(for: .sleep, metric: summary.metric(.sleep), summary: summary).fraction == 1)
    }

    // MARK: Recovery, strain, stress

    @Test
    func recoveryFillsItsOwnPercentAndClamps() {
        let base = summary(metrics: [])
        let reading = TodayRingReading.reading(for: .recovery, metric: score(.recovery, 64), summary: base)
        #expect(reading.fraction == 0.64)
        #expect(reading.format == .integer)
        // The value already is a percentage; VoiceOver does not say it twice.
        #expect(reading.accessibilityFill == nil)
        #expect(TodayRingReading.reading(for: .recovery, metric: score(.recovery, 104), summary: base).fraction == 1)
        #expect(TodayRingReading.reading(for: .readiness, metric: score(.readiness, 82), summary: base).fraction == 0.82)
    }

    @Test
    func strainFillsTheTwentyOnePointScaleAndClamps() {
        let base = summary(metrics: [])
        let strain = metric(.strain, value: 3.6, unit: .strainScore)
        let reading = TodayRingReading.reading(for: .strain, metric: strain, summary: base)
        #expect(abs((reading.fraction ?? -1) - 3.6 / 21) < 1e-12)
        #expect(reading.format == .oneDecimal)
        #expect(reading.accessibilityFill == "17 percent of the 21 point strain scale")
        #expect(TodayRingReading.reading(for: .strain, metric: metric(.strain, value: 23, unit: .strainScore), summary: base).fraction == 1)
        #expect(TodayRingReading.reading(for: .strain, metric: metric(.strain, value: 0, unit: .strainScore), summary: base).fraction == 0)
    }

    @Test
    func stressFillsItsHundredPointScore() {
        let base = summary(metrics: [])
        let reading = TodayRingReading.reading(for: .stress, metric: score(.stress, 21), summary: base)
        #expect(reading.fraction == 0.21)
        #expect(reading.accessibilityFill == "21 percent of the 100 point stress scale")
    }

    // MARK: Unavailable

    @Test
    func unavailableReadingsLeaveTheTrackEmpty() {
        let base = summary(metrics: [])
        for id in [TodayMetricID.sleep, .recovery, .strain, .stress] {
            #expect(TodayRingReading.reading(for: id, metric: nil, summary: base) == .empty)
            let noNumber = TodayMetricValue(id: id, title: "Metric", value: nil, unit: "", state: .settling, source: "test")
            #expect(TodayRingReading.reading(for: id, metric: noNumber, summary: base).fraction == nil)
        }
        let absent = TodayMetricValue(id: .strain, title: "Strain", value: "0", unit: "/21", state: .absent,
                                      source: "test", numericValue: 0, numericUnit: .strainScore)
        #expect(TodayRingReading.reading(for: .strain, metric: absent, summary: base) == .empty)
        let nonFinite = TodayMetricValue(id: .stress, title: "Stress", value: "?", unit: "/100", state: .partial,
                                         source: "test", numericValue: .nan, numericUnit: .scorePoints)
        #expect(TodayRingReading.reading(for: .stress, metric: nonFinite, summary: base) == .empty)
    }

    @Test
    func aNumberInAnUnexpectedUnitIsNotScaled() {
        let base = summary(metrics: [])
        #expect(TodayRingReading.reading(for: .stress, metric: metric(.stress, value: 3, unit: .index), summary: base) == .empty)
        #expect(TodayRingReading.reading(for: .strain, metric: metric(.strain, value: 60, unit: .scorePoints), summary: base) == .empty)
        #expect(TodayRingReading.reading(for: .sleep, metric: metric(.sleep, value: 7.5, unit: .scorePoints), summary: base) == .empty)
    }

    // MARK: Summary plumbing

    @Test
    func sleepNeedTravelsInHoursAndDecodesFromOlderPayloads() throws {
        let attached = TodayFixtures.populated.withSleepNeed(hours: 8.2)
        #expect(abs((attached.sleepNeedMinutes ?? 0) - 492) < 1e-9)
        #expect(TodayFixtures.populated.withSleepNeed(hours: nil).sleepNeedMinutes == nil)
        #expect(TodayFixtures.populated.withSleepNeed(hours: .infinity).sleepNeedMinutes == nil)

        let encoded = try JSONEncoder().encode(attached)
        #expect(try JSONDecoder().decode(TodaySummary.self, from: encoded) == attached)

        var legacy = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "sleepNeedMinutes")
        let legacyData = try JSONSerialization.data(withJSONObject: legacy)
        #expect(try JSONDecoder().decode(TodaySummary.self, from: legacyData).sleepNeedMinutes == nil)
    }

    @Test @MainActor
    func goalAndCoachRefreshesResolveTheSavedSleepNeed() async {
        let summary = TodayFixtures.populated.withSleepNeed(hours: 7.5)
        let repository = InMemoryTodayRepository(values: [TodayFixtures.day: summary])
        let goals = InMemoryTodayGoalsRepository(values: [TodayFixtures.day: []])
        let plan = InMemoryTodayCoachPlanRepository(values: [:])
        let viewModel = TodayViewModel(repository: repository, goalsRepository: goals, coachPlanRepository: plan)
        await viewModel.load(day: TodayFixtures.day)
        #expect(viewModel.summary?.sleepNeedMinutes == 480)

        await goals.replace([sleepGoal(target: "8", unit: "hours")], for: TodayFixtures.day)
        await plan.replace(TodayCoachPlanSummary(title: "Rest", detail: "Evidence supports rest.", recommendationCount: 1,
                                                 evidenceSummary: "sleep", state: .partial), for: TodayFixtures.day)
        await viewModel.refreshProjections(for: TodayFixtures.day)
        #expect(viewModel.summary?.sleepNeedMinutes == 480)
        #expect(viewModel.summary?.goals.first?.id == "sleep")
    }

    @Test
    func populatedFixtureFillsEveryRing() {
        let summary = TodayFixtures.populated
        let recovery = summary.metric(.recovery) ?? summary.metric(.readiness)
        #expect(TodayRingReading.reading(for: .sleep, metric: summary.metric(.sleep), summary: summary).fraction != nil)
        #expect(TodayRingReading.reading(for: .recovery, metric: recovery, summary: summary).fraction != nil)
        #expect(TodayRingReading.reading(for: .strain, metric: summary.metric(.strain), summary: summary).fraction != nil)
        #expect(TodayRingReading.reading(for: .stress, metric: summary.metric(.stress), summary: summary).fraction != nil)
    }

    // MARK: Settling on too little wear

    @Test
    func settlingStrainAndStressShowNoNumberAndTheWearProgress() {
        let strain = TodayMetricValue(id: .strain, title: "Strain", value: nil, unit: "/21", confidence: "23 of 60 min worn",
                                      state: .settling, source: "test", numericValue: nil, numericUnit: .strainScore)
        let stress = TodayMetricValue(id: .stress, title: "Stress", value: nil, unit: "/100", confidence: "23 of 60 min worn",
                                      state: .settling, source: "test", numericValue: nil, numericUnit: .scorePoints)
        let day = summary(metrics: [sleep(minutes: 420), strain, stress])
        #expect(TodayRingReading.reading(for: .strain, metric: strain, summary: day) == .empty)
        #expect(TodayRingReading.reading(for: .stress, metric: stress, summary: day) == .empty)
        let rings = TodayDashboard.rings(
            summary: day, values: TodayValues(summary: day, context: nil, calendar: Calendar(identifier: .gregorian)), context: nil)
        let strainRing = rings.first { $0.id == .strain }
        let stressRing = rings.first { $0.id == .stress }
        #expect(strainRing?.text == "—")
        #expect(strainRing?.settlingCaption == "23 of 60 min worn")
        #expect(stressRing?.settlingCaption == "23 of 60 min worn")
        #expect(rings.first { $0.id == .sleep }?.settlingCaption == nil)
        #expect(TodayDashboard.spokenSettling("23 of 60 min worn") == "23 of 60 minutes worn")
    }

    @Test
    func aMeasuredRingHasNoSettlingCaption() {
        let day = summary(metrics: [sleep(minutes: 420), metric(.strain, value: 8, unit: .strainScore), score(.stress, 40)])
        let rings = TodayDashboard.rings(
            summary: day, values: TodayValues(summary: day, context: nil, calendar: Calendar(identifier: .gregorian)), context: nil)
        #expect(rings.allSatisfy { $0.settlingCaption == nil })
    }

    // MARK: Helpers

    private func summary(metrics: [TodayMetricValue], goals: [TodayGoalProgress] = [], needMinutes: Double? = nil) -> TodaySummary {
        TodaySummary(
            day: TodayFixtures.day,
            overallState: .partial,
            freshness: TodayFreshness(state: .partial, updatedAt: nil, ageMinutes: nil, detail: "test"),
            device: TodayDeviceSnapshot(connection: .unknown, status: .partial),
            metrics: metrics,
            goals: goals,
            sleepNeedMinutes: needMinutes
        )
    }

    private func sleep(minutes: Double) -> TodayMetricValue {
        metric(.sleep, value: minutes, unit: .minutes)
    }

    private func score(_ id: TodayMetricID, _ value: Double) -> TodayMetricValue {
        metric(id, value: value, unit: .scorePoints)
    }

    private func metric(_ id: TodayMetricID, value: Double, unit: TodayMetricUnitID) -> TodayMetricValue {
        TodayMetricValue(id: id, title: "Metric", value: String(value), unit: "", state: .partial,
                         source: "test", numericValue: value, numericUnit: unit)
    }

    private func sleepGoal(target: String?, unit: String) -> TodayGoalProgress {
        TodayGoalProgress(id: "sleep", title: "Sleep", value: nil, target: target, unit: unit, state: .partial)
    }
}
