import Foundation
import Testing
import DomainKit
@testable import TodayKit

/// The sleep need on the summary: where it comes from and how it travels. These cases lived in the ring tests
/// until the rings were removed.
struct TodaySleepNeedTests {
    @Test
    func theNeedIsEightHoursUnlessASleepGoalSaysOtherwise() {
        #expect(TodaySleepNeed.minutes(from: []) == 480)
        #expect(TodaySleepNeed.minutes(from: [sleepGoal(target: "7.5", unit: "hours")]) == 450)
    }

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

    private func sleepGoal(target: String?, unit: String) -> TodayGoalProgress {
        TodayGoalProgress(id: "sleep", title: "Sleep", value: nil, target: target, unit: unit, state: .partial)
    }
}
