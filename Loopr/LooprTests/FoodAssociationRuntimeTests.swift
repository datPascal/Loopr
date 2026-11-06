import DesignSystem
import DomainKit
import FoodKit
import Foundation
import HeartKit
import JournalKit
import SleepKit
import StorageKit
import Testing
import TodayKit
import WorkoutKit
@testable import Loopr

@MainActor struct FoodAssociationRuntimeTests {
    @Test func priorDayStrainComesFromTheBehaviorDayAndKeepsItsVersion() async throws {
        let behavior = DayIdentity(year: 2026, month: 9, day: 29)
        let outcome = DayIdentity(year: 2026, month: 9, day: 30)
        let start = Date(timeIntervalSince1970: 1_790_700_000), end = start.addingTimeInterval(8 * 3600)
        func summary(_ day: DayIdentity, strain: Double, version: String) -> TodaySummary {
            .init(day: day, overallState: .measuredZero,
                freshness: .init(state: .measuredZero, updatedAt: end, ageMinutes: 0, detail: "Test"),
                device: .init(connection: .connected, status: .measuredZero),
                metrics: [.init(id: .strain, title: "Strain", value: String(strain), unit: "", state: .measuredZero,
                    source: "test", algorithmVersion: version, numericValue: strain, numericUnit: .strainScore)])
        }
        let today = InMemoryTodayRepository(values: [behavior: summary(behavior, strain: 12, version: "behavior.v1"),
                                                     outcome: summary(outcome, strain: 3, version: "outcome.v1")])
        let sleep = InMemorySleepRepository(values: [outcome: .init(day: outcome, state: .measuredZero,
            mainSleep: .init(id: "test", start: start, end: end, durationMinutes: 480, isMainSleep: true,
                            isPartial: false, confidence: 1, state: .measuredZero),
            metrics: [.init(id: "deep", title: "Deep sleep", value: "60", unit: "min", state: .measuredZero,
                source: "test", algorithmVersion: "sleep.v1", numericValue: 60, numericUnit: .minutes)], source: "test")])
        let resolver = AppHabitOutcomeResolver(today: today, sleep: sleep, heart: InMemoryHeartRepository())
        let record = HabitDayRecord(behaviorDay: behavior, behaviorTimeZoneID: "Australia/Perth", createdAt: start)
        guard case .outcome(let value) = await resolver.resolve(record: record) else { Issue.record("Missing valid sleep outcome"); return }
        #expect(value.priorDayStrain == 12)
        #expect(value.sourceVersions["priorDayStrain"] == "behavior.v1")
        await today.removeAll()
        await today.replace(summary(outcome, strain: 3, version: "outcome.v1"), for: outcome)
        guard case .outcome(let missing) = await resolver.resolve(record: record) else { Issue.record("Missing sleep-only outcome"); return }
        #expect(missing.priorDayStrain == nil)
    }

    @Test func populatedSourceHistoryBuildsFoodComparisonsAndWorkoutAverages() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FoodAssociationRuntime-" + UUID().uuidString)
        let database = try StorageDatabase(url: root.appendingPathComponent("food.sqlite"))
        defer { try? database.databasePool.close(); try? FileManager.default.removeItem(at: root) }
        let store = FoodStore(database: database)
        let environment = AppEnvironment.make(arguments: ["--loopr-launch-mode=populated"], environment: [:])
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Australia/Perth")!
        let day = calendar.date(from: .init(year: 2023, month: 11, day: 14))!
        try FoodAssociationFixtures.seedHistory(store, today: day, calendar: calendar)
        try AppFoodFixtures.seed(store, endingOn: environment.dateProvider.now())
        let repository = AppFoodRepository(store: store, environment: environment)
        let repositories = ProductRepositoryContainer(environment: environment)
        let workouts = try #require(repositories.workoutStore)
        for workout in FoodAssociationFixtures.workouts(endingOn: environment.dateProvider.now()) { try await workouts.save(workout) }
        let model = FoodAssociationModel()
        await model.load(repository: repository, repositories: repositories, date: day, calendar: calendar)
        let report = try #require(model.report)
        #expect(model.error == nil && !model.loading)
        #expect(report.recentDays.count == 29 && report.points.count == 29)
        #expect(report.protein(training: true) != nil && report.protein(training: false) != nil)
        #expect(report.row(.lateMeal).difference != nil && report.row(.proteinTarget).difference != nil)
        #expect(model.detailStore != nil)
    }
}
