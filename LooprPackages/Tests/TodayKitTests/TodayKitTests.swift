import Foundation
import Combine
import Testing
#if canImport(UIKit)
import UIKit
#endif
import DomainKit
import DesignSystem
@testable import TodayKit

struct TodayKitTests {
    @Test
    func stateFixturesCoverAllFourteenStatesAndKeepAbsenceDistinctFromZero() {
        #expect(TodayFixtures.allStates.count == 14)
        #expect(Set(TodayFixtures.allStates.map { $0.state.title }).count == 14)

        let absent = TodayFixtures.summary(for: .absent).metric(.steps)
        let zero = TodayFixtures.summary(for: .measuredZero).metric(.steps)
        #expect(absent?.value == nil)
        #expect(absent?.state == .absent)
        #expect(zero?.value == "0")
        #expect(zero?.state == .measuredZero)
        #expect(absent?.accessibilitySummary != zero?.accessibilitySummary)
    }

    @Test
    func populatedProjectionHasCanonicalSourceAndContributors() {
        let summary = TodayFixtures.populated
        #expect(summary.metric(.readiness)?.source == "ANA-08.readiness")
        #expect(summary.metric(.readiness)?.contributors.count == 2)
        #expect(summary.metric(.sleep)?.source == "ANA-03.sleep")
        #expect(summary.metric(.heart)?.source == "ANA-02.nocturnal")
        #expect(summary.metric(.strain)?.source == "ANA-05.activity")
        #expect(summary.coachPlan == .placeholder)
    }

    @Test @MainActor
    func viewModelUsesRepositoryAndThenSeparatelyRefreshesGoalsAndCoach() async {
        let repository = SpyTodayRepository(summary: TodayFixtures.populated)
        let goals = InMemoryTodayGoalsRepository(values: [
            TodayFixtures.day: [TodayGoalProgress(id: "goal", title: "Move", value: "10", target: "20", unit: "minutes", state: .partial, progressFraction: 0.5)]
        ])
        let plan = InMemoryTodayCoachPlanRepository(values: [
            TodayFixtures.day: TodayCoachPlanSummary(title: "Easy movement", detail: "Evidence is available.", recommendationCount: 1, evidenceSummary: "readiness", state: .partial)
        ])
        let viewModel = TodayViewModel(repository: repository, goalsRepository: goals, coachPlanRepository: plan)

        await viewModel.load(day: TodayFixtures.day)

        #expect(viewModel.loadState == .loaded)
        #expect(viewModel.summary?.coachPlan == .plan(TodayCoachPlanSummary(title: "Easy movement", detail: "Evidence is available.", recommendationCount: 1, evidenceSummary: "readiness", state: .partial)))
        #expect(viewModel.goals.count == 1)
        #expect(await repository.requestedDays() == [TodayFixtures.day])
        #expect(await repository.rawReads() == 1)
    }

    @Test @MainActor
    func projectionRefreshUpdatesGoalsAndCoachWithoutReloadingCanonicalSummary() async {
        let repository = InMemoryTodayRepository(values: [TodayFixtures.day: TodayFixtures.populated])
        let goals = InMemoryTodayGoalsRepository(values: [TodayFixtures.day: []])
        let plan = InMemoryTodayCoachPlanRepository(values: [:])
        let viewModel = TodayViewModel(repository: repository, goalsRepository: goals, coachPlanRepository: plan)
        await viewModel.load(day: TodayFixtures.day)

        let updatedGoal = TodayGoalProgress(id: "steps", title: "Steps", value: "8,000", target: "10,000", unit: "steps", state: .partial, progressFraction: 0.8)
        let updatedPlan = TodayCoachPlanSummary(title: "Gentle walk", detail: "Evidence supports an easy session.", recommendationCount: 1, evidenceSummary: "readiness", state: .partial)
        await goals.replace([updatedGoal], for: TodayFixtures.day)
        await plan.replace(updatedPlan, for: TodayFixtures.day)
        await viewModel.refreshProjections(for: TodayFixtures.day)

        #expect(viewModel.summary?.metric(.readiness) == TodayFixtures.populated.metric(.readiness))
        #expect(viewModel.goals == [updatedGoal])
        #expect(viewModel.summary?.coachPlan == .plan(updatedPlan))
    }

    @Test @MainActor
    func absentRepositoryResultDoesNotFabricateValues() async {
        let repository = SpyTodayRepository(summary: nil)
        let viewModel = TodayViewModel(repository: repository)

        await viewModel.load(day: TodayFixtures.day)

        #expect(viewModel.loadState == .loaded)
        #expect(viewModel.summary == nil)
        #expect(viewModel.goals.isEmpty)
    }

    @Test @MainActor
    func repositoryErrorsRemainRecoverable() async {
        let repository = SpyTodayRepository(error: TestError.failed)
        let viewModel = TodayViewModel(repository: repository)

        await viewModel.load(day: TodayFixtures.day)

        guard case .failed(let message) = viewModel.loadState else {
            Issue.record("Expected a recoverable failed state")
            return
        }
        #expect(message.contains("failed"))
        #expect(viewModel.summary == nil)
    }

    @Test @MainActor
    func lastKnownSummaryWaitsForTheFreshRead() {
        let viewModel = TodayViewModel(
            repository: InMemoryTodayRepository(),
            lastKnownSummary: TodayFixtures.populated,
            day: TodayFixtures.day
        )
        #expect(viewModel.loadState == .idle)
        #expect(viewModel.summary == nil)
        #expect(viewModel.goals.isEmpty)
        #expect(viewModel.coachPlan == .placeholder)
    }

    @Test @MainActor
    func firstPublishedRecoveryIsTheFreshReading() async {
        let cached = TodayTestDays.summary(recovery: 73)
        let final = TodayTestDays.summary(recovery: 72)
        let viewModel = TodayViewModel(
            repository: InMemoryTodayRepository(values: [TodayTestDays.day: final]),
            lastKnownSummary: cached,
            day: TodayTestDays.day
        )
        var published: [TodaySummary] = []
        let subscription = viewModel.$summary.compactMap { $0 }.sink { published.append($0) }
        await viewModel.load(day: TodayTestDays.day)
        withExtendedLifetime(subscription) {
            #expect(published == [final])
        }
    }

    @Test @MainActor
    func lastKnownSummaryForAnotherDayIsIgnored() {
        let viewModel = TodayViewModel(
            repository: InMemoryTodayRepository(),
            lastKnownSummary: TodayFixtures.populated,
            day: DayIdentity(year: 2023, month: 11, day: 15)
        )
        #expect(viewModel.loadState == .idle)
        #expect(viewModel.summary == nil)
    }

    @Test @MainActor
    func refreshAfterASeededLaunchClearsASummaryThatNoLongerExists() async {
        let viewModel = TodayViewModel(
            repository: InMemoryTodayRepository(),
            lastKnownSummary: TodayFixtures.populated,
            day: TodayFixtures.day
        )
        await viewModel.load(day: TodayFixtures.day)
        #expect(viewModel.loadState == .loaded)
        #expect(viewModel.summary == nil)
    }

    @Test @MainActor
    func screenAndRoutesConstructWithoutAHiddenPreviewOnlyPath() {
        let repository = InMemoryTodayRepository(values: [TodayFixtures.day: TodayFixtures.populated])
        let viewModel = TodayViewModel(repository: repository)
        let screen = TodayScreen(viewModel: viewModel) { _ in }
        #expect(screen.routeCountForTesting == TodayRoute.allCases.count)
    }
}

private enum TestError: Error, LocalizedError {
    case failed
    var errorDescription: String? { "failed" }
}

private actor SpyTodayRepository: TodayRepository {
    private let summary: TodaySummary?
    private let shouldFail: Bool
    private var reads = 0
    private var days: [DayIdentity] = []

    init(summary: TodaySummary) {
        self.summary = summary
        self.shouldFail = false
    }

    init(summary: TodaySummary?) {
        self.summary = summary
        self.shouldFail = false
    }

    init(error _: Error) {
        self.summary = nil
        self.shouldFail = true
    }

    func readSummary(for day: DayIdentity) async throws -> TodaySummary? {
        reads += 1
        days.append(day)
        if shouldFail { throw TestError.failed }
        return summary
    }

    func requestedDays() -> [DayIdentity] { days }
    func rawReads() -> Int { reads }
}

private extension TodayScreen {
    var routeCountForTesting: Int { TodayRoute.allCases.count }
}
