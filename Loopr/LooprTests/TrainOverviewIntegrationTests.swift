import Foundation
import Testing
import TrainKit
import WorkoutKit
@testable import Loopr

/// The Train overview against the seeded fixture database: Alex, Australia/Perth, Tuesday 2023-11-14.
@MainActor struct TrainOverviewIntegrationTests {
    private static func environment() -> AppEnvironment {
        AppEnvironment.make(arguments: ["--loopr-launch-mode=populated"], environment: [:])
    }

    private static func fixtureRepository(seeded: Bool = true) -> AppTrainRepository {
        AppTrainRepository(environment: environment(), seedsFixture: seeded)
    }

    private static func loader(_ repository: AppTrainRepository) -> TrainOverviewLoader {
        TrainOverviewLoader(repository: repository, workouts: InMemoryWorkoutStore(workouts: AppTrainFixtures.workoutRecords))
    }

    private static func load(_ loader: TrainOverviewLoader) async {
        await loader.load(now: AppTrainFixtures.now, calendar: AppTrainFixtures.calendar, history: TrainFixtureMetricHistory())
    }

    @Test func fixtureRepositoryReadsTheSavedPlans() async throws {
        let repository = Self.fixtureRepository()
        let templates = try await repository.templates()
        #expect(templates.map(\.name) == ["Lower A", "Lower B", "Upper A", "Upper B", "Zone 2"])
        let upper = try #require(templates.first { $0.name == "Upper A" })
        #expect(upper.exercises.count == 6)
        #expect(upper.exercises.last?.exercise.name == "Cable triceps pushdown")
        let programs = try await repository.programs()
        #expect(programs.map(\.name) == ["Half marathon", "Strength block"])
        #expect(programs.first { $0.name == "Strength block" }?.status == .active)
        #expect(programs.first { $0.name == "Half marathon" }?.status == .paused)
        let sessions = try await repository.recentSessions(limit: 10)
        #expect(sessions.map(\.name) == ["Lower A", "Upper A", "Lower A"])
        #expect(sessions.first?.tonnageKg == 8_420)
        #expect(sessions.first?.workoutID == AppTrainFixtures.lowerAWorkoutID)
    }

    @Test func fixtureWithoutTheFlagStartsEmpty() async throws {
        let repository = Self.fixtureRepository(seeded: false)
        #expect(try await repository.templates().isEmpty)
        let loader = Self.loader(repository)
        await Self.load(loader)
        let overview = try #require(loader.overview)
        #expect(overview.isEmpty && overview.today == .none && !overview.showsWeekStrip)
        #expect(loader.failure == nil)
    }

    @Test func overviewReadsTheSavedPlansForTheFixtureDay() async throws {
        let loader = Self.loader(Self.fixtureRepository())
        await Self.load(loader)
        let overview = try #require(loader.overview)
        #expect(loader.failure == nil && !overview.isEmpty)
        #expect(overview.headerMeta == "Week 3 of 8 · Strength block")
        #expect(overview.week.map(\.caption) == ["Done", "Upper A", "Zone 2", "Lower B", "Rest", "Upper B", "Rest"])
        #expect(overview.week.map(\.numeral) == ["13", "14", "15", "16", "17", "18", "19"])
        guard case .plan(let plan) = overview.today else { Issue.record("Expected a plan for today"); return }
        #expect(plan.name == "Upper A" && plan.templateID == AppTrainFixtures.upperAID)
        #expect(plan.recoveryShown == 79 && plan.recoveryMessage == "Recovery is 79, so go as planned.")
        #expect(plan.detail == "6 exercises · about 55 min · expected strain 11")
        #expect(plan.programWeek == 3 && !plan.isLight)
        #expect(overview.programs.map(\.caption) == ["8 weeks · 5 days a week", "Paused"])
        #expect(overview.programs.first?.value == "3" && overview.programs.first?.valueUnit == "of 8")
        #expect(overview.templates.map(\.slug) == ["lower-a", "lower-b", "upper-a", "upper-b", "zone-2"])
        let lower = try #require(overview.thisWeek.first)
        #expect(lower.caption == "Mon 13 Nov · 62 min · 17 sets · 8,420 kg")
        #expect(overview.sessionsByWorkoutID[AppTrainFixtures.lowerAWorkoutID]?.name == "Lower A")
    }

    @Test func overviewReflectsATemplateSavedAfterTheFirstLoad() async throws {
        let repository = Self.fixtureRepository()
        let loader = Self.loader(repository)
        await Self.load(loader)
        #expect(loader.overview?.templates.count == 5)
        #expect(loader.overview?.week[4].caption == "Rest")

        let pull = WorkoutTemplate(name: "Pull day", weekdays: [.friday], exercises: [
            TemplateExercise(exercise: ExerciseRef(key: "Pullups", name: "Pull-up"), sets: 3, repsMin: 6, repsMax: 8, restSeconds: 120)
        ])
        _ = try await repository.saveTemplate(pull, at: AppTrainFixtures.now)
        await Self.load(loader)

        let overview = try #require(loader.overview)
        #expect(overview.templates.count == 6)
        #expect(overview.templates.contains { $0.slug == "pull-day" && $0.caption == "Pull-up" })
        // The program still owns Friday, which it leaves empty. A template's own days only fill gaps without a program.
        #expect(overview.week[4].caption == "Rest")
        #expect(overview.swapChoices.contains { $0.name == "Pull day" })
    }

    @Test func aTemplateWithDaysFillsTheWeekWhenNoProgramRuns() async throws {
        let repository = Self.fixtureRepository(seeded: false)
        let template = WorkoutTemplate(name: "Upper A", weekdays: [.tuesday], exercises: [
            TemplateExercise(exercise: ExerciseRef(key: "Barbell_Bench_Press_-_Medium_Grip", name: "Bench press"), sets: 4,
                             repsMin: 6, repsMax: 8, loadKg: 80, restSeconds: 150)
        ])
        _ = try await repository.saveTemplate(template, at: AppTrainFixtures.now)
        let loader = Self.loader(repository)
        await Self.load(loader)
        let overview = try #require(loader.overview)
        #expect(!overview.isEmpty && overview.showsWeekStrip)
        #expect(overview.week[1].caption == "Upper A" && overview.week[1].isToday)
        #expect(overview.headerMeta == nil)
    }

    @Test func swapShowsAnotherTemplateForTodayOnly() async throws {
        let loader = Self.loader(Self.fixtureRepository())
        await Self.load(loader)
        loader.swap(to: AppTrainFixtures.lowerBID)
        guard case .plan(let swapped) = loader.overview?.today else { Issue.record("Expected a plan"); return }
        #expect(swapped.name == "Lower B" && swapped.isSwapped)
        // A reload on the same day keeps the choice.
        await Self.load(loader)
        guard case .plan(let kept) = loader.overview?.today else { Issue.record("Expected a plan"); return }
        #expect(kept.name == "Lower B")
        loader.swap(to: nil)
        guard case .plan(let planned) = loader.overview?.today else { Issue.record("Expected a plan"); return }
        #expect(planned.name == "Upper A" && !planned.isSwapped)
    }

    @Test func swapFromADifferentDayIsDropped() async throws {
        let loader = Self.loader(Self.fixtureRepository())
        await Self.load(loader)
        loader.swap(to: AppTrainFixtures.lowerBID)
        let tomorrow = AppTrainFixtures.now.addingTimeInterval(86_400)
        await loader.load(now: tomorrow, calendar: AppTrainFixtures.calendar, history: TrainFixtureMetricHistory())
        guard case .plan(let plan) = loader.overview?.today else { Issue.record("Expected a plan"); return }
        #expect(plan.name == "Zone 2" && !plan.isSwapped)
    }

    @Test func aStoreThatCannotOpenShowsAFailureAndStillBuildsTheEmptyState() async throws {
        let loader = Self.loader(AppTrainRepository(environment: .production()))
        await Self.load(loader)
        #expect(loader.failure != nil)
        #expect(loader.overview?.isEmpty == true)
    }

    @Test func recoveryReadingsKeepOnePerLocalDayInThePersonsZone() {
        let calendar = AppTrainFixtures.calendar
        let monday = calendar.date(from: DateComponents(year: 2023, month: 11, day: 13)) ?? .distantPast
        let points = [
            MetricHistoryPoint(day: monday, value: 70, source: .band),
            MetricHistoryPoint(day: monday.addingTimeInterval(86_400), value: 79, source: .band),
            MetricHistoryPoint(day: monday.addingTimeInterval(2 * 86_400), value: .nan, source: .band),
            MetricHistoryPoint(day: monday.addingTimeInterval(3 * 86_400), value: 140, source: .band)
        ]
        let readings = TrainRecoveryProvider.readings(from: points, calendar: calendar)
        #expect(readings == [RecoveryReading(localDay: "2023-11-13", score: 70), RecoveryReading(localDay: "2023-11-14", score: 79)])
    }

    @Test func fixtureRecoveryHasNineDaysEndingOnTheFixtureDay() async throws {
        let readings = await TrainRecoveryProvider(history: TrainFixtureMetricHistory())
            .readings(endingOn: AppTrainFixtures.now, calendar: AppTrainFixtures.calendar)
        #expect(readings.last == RecoveryReading(localDay: "2023-11-14", score: 79))
        #expect(readings.count == 9)
        let window = readings.filter { $0.localDay >= "2023-11-06" && $0.localDay <= "2023-11-12" }
        #expect(window.count == 7 && window.map(\.score).reduce(0, +) / 7 > 50)
    }

    @Test func fixtureFlagMatchesTheBareAndTheValuedForm() {
        #expect(AppTrainFixtures.isRequested(arguments: ["--loopr-train-fixture"]))
        #expect(AppTrainFixtures.isRequested(arguments: ["--loopr-train-fixture=live"]))
        #expect(!AppTrainFixtures.isRequested(arguments: ["--loopr-launch-mode=populated"]))
    }
}
