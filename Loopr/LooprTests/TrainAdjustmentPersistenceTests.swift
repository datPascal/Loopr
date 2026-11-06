import Foundation
import Testing
import TrainKit
import WorkoutKit
@testable import Loopr

/// The scheduler's light-week decisions and moved sessions are saved, so a rule never decides the same
/// week twice. Alex trains in Australia/Perth on the fixture day, Tuesday 2023-11-14, week 3 of the
/// Strength block.
@MainActor struct TrainAdjustmentPersistenceTests {
    /// Recovery that is the same on every day the fixture covers.
    private struct SteadyRecovery: MetricHistoryProviding {
        let score: Double
        func series(for key: MetricKey, days: Int, endingOn: Date) async throws -> [MetricHistoryPoint] {
            guard key == .recovery else { return [] }
            let calendar = AppTrainFixtures.calendar
            return (6...14).compactMap { day in
                calendar.date(from: DateComponents(year: 2023, month: 11, day: day)).map { MetricHistoryPoint(day: $0, value: score, source: .band) }
            }
        }
    }

    private static func environment() -> AppEnvironment { AppEnvironment.make(arguments: ["--loopr-launch-mode=populated"], environment: [:]) }

    private static func loader(_ repository: AppTrainRepository) -> TrainOverviewLoader {
        TrainOverviewLoader(repository: repository, workouts: InMemoryWorkoutStore(workouts: AppTrainFixtures.workoutRecords))
    }

    private static func block(_ repository: AppTrainRepository) async throws -> Program {
        try #require(try await repository.programs().first { $0.id == AppTrainFixtures.strengthBlockID })
    }

    @Test func aLowRecoveryAverageMakesTheWeekLightAndTheDecisionSticks() async throws {
        let repository = AppTrainRepository(environment: Self.environment(), seedsFixture: true)
        #expect(try await Self.block(repository).adjustments.isEmpty)

        let first = Self.loader(repository)
        await first.load(now: AppTrainFixtures.now, calendar: AppTrainFixtures.calendar, history: SteadyRecovery(score: 46))
        guard case .plan(let light) = first.overview?.today else { Issue.record("Expected a plan"); return }
        #expect(light.isLight && light.scheduleNote == "Week 3 is lighter. Recovery averaged 46 over the last 7 days.")
        let saved = try await Self.block(repository).adjustments
        #expect(saved.count == 1 && saved[0].kind == .earlyLightWeek && saved[0].week == 3 && saved[0].recoveryScore == 46)
        #expect(saved[0].daysWithReadings == 7)

        // A later launch with healthy recovery does not undo it: the week was decided once.
        let second = Self.loader(repository)
        await second.load(now: AppTrainFixtures.now.addingTimeInterval(3 * 3_600), calendar: AppTrainFixtures.calendar,
                          history: SteadyRecovery(score: 90))
        guard case .plan(let still) = second.overview?.today else { Issue.record("Expected a plan"); return }
        #expect(still.isLight)
        #expect(try await Self.block(repository).adjustments.count == 1)
    }

    @Test func aHighAverageSavesADeclinedDecisionSoTheWeekIsNotDecidedAgain() async throws {
        let repository = AppTrainRepository(environment: Self.environment(), seedsFixture: true)
        let loader = Self.loader(repository)
        await loader.load(now: AppTrainFixtures.now, calendar: AppTrainFixtures.calendar, history: TrainFixtureMetricHistory())
        let saved = try await Self.block(repository).adjustments
        #expect(saved.map(\.kind) == [.earlyLightDeclined] && saved.first?.week == 3)
        // Loading again, and a new loader, add nothing.
        await loader.load(now: AppTrainFixtures.now, calendar: AppTrainFixtures.calendar, history: TrainFixtureMetricHistory())
        await Self.loader(repository).load(now: AppTrainFixtures.now, calendar: AppTrainFixtures.calendar, history: SteadyRecovery(score: 20))
        #expect(try await Self.block(repository).adjustments == saved)
        guard case .plan(let plan) = loader.overview?.today else { Issue.record("Expected a plan"); return }
        #expect(!plan.isLight)
    }

    @Test func startingASessionRecordsWhatTheOverviewHasNotYet() async throws {
        let repository = AppTrainRepository(environment: Self.environment(), seedsFixture: true)
        let loader = Self.loader(repository)
        await loader.load(now: AppTrainFixtures.now, calendar: AppTrainFixtures.calendar, history: TrainFixtureMetricHistory())
        let revision = try await Self.block(repository).revision
        // Nothing new: the start-time pass changes nothing and does not bump the revision.
        await loader.recordProgramAdjustments()
        #expect(try await Self.block(repository).revision == revision)
        // A decision that was never saved is saved at the start.
        let program = try await Self.block(repository)
        let pending = [PendingProgramAdjustments(programID: program.id, adjustments: [
            ProgramAdjustment(kind: .movedSession, week: 3, weekday: .thursday, movedToWeekday: .friday,
                              reason: "Moved from Thursday so no day has two sessions.", createdAt: AppTrainFixtures.now)])]
        #expect(try await repository.recordAdjustments(pending, at: AppTrainFixtures.now))
        let after = try await Self.block(repository)
        #expect(after.revision == revision + 1 && after.adjustments.contains { $0.kind == .movedSession })
        // The same decision again is already held.
        #expect(try await repository.recordAdjustments(pending, at: AppTrainFixtures.now) == false)
        #expect(try await Self.block(repository).revision == after.revision)
    }

    @Test func aMissedSessionIsSavedAsAMoveOnTheFirstLoad() async throws {
        // Skip the Monday session by clearing the finished Lower A, so it counts as missed on Tuesday.
        let repository = AppTrainRepository(environment: Self.environment(), seedsFixture: true)
        let lowerA = try #require(try await repository.session(id: AppTrainFixtures.lowerASessionID))
        try await repository.deleteSession(id: lowerA.id, expectedRevision: lowerA.revision)
        let loader = Self.loader(repository)
        await loader.load(now: AppTrainFixtures.now, calendar: AppTrainFixtures.calendar, history: TrainFixtureMetricHistory())
        let moves = try await Self.block(repository).adjustments.filter { $0.kind == .movedSession }
        #expect(moves.count == 1 && moves[0].week == 3 && moves[0].weekday == .monday)
        // The move is on record, so the overview plans from it and the next load saves nothing more.
        await loader.load(now: AppTrainFixtures.now, calendar: AppTrainFixtures.calendar, history: TrainFixtureMetricHistory())
        #expect(try await Self.block(repository).adjustments.filter { $0.kind == .movedSession }.count == 1)
    }

    @Test func aNamedFixtureStoreSurvivesAReleaseOfTheRepositoryAndSeedsOnlyOnce() async throws {
        let name = "unit-\(UUID().uuidString.prefix(8))"
        defer { try? FileManager.default.removeItem(at: AppTrainFixtures.stableRoot(named: name)) }
        do {
            let first = AppTrainRepository(environment: Self.environment(), seedsFixture: true, fixtureStoreName: name)
            var upper = try #require(try await first.template(id: AppTrainFixtures.upperAID))
            upper.exercises[0].sets = 5
            _ = try await first.saveTemplate(upper, at: AppTrainFixtures.now)
        }
        let second = AppTrainRepository(environment: Self.environment(), seedsFixture: true, fixtureStoreName: name)
        let reopened = try #require(try await second.template(id: AppTrainFixtures.upperAID))
        #expect(reopened.exercises[0].sets == 5 && reopened.revision == 2)
        let templateCount = try await second.templates().count
        let sessionCount = try await second.sessions().count
        #expect(templateCount == 5 && sessionCount == 3)
        // A launch without a name starts from a fresh seed.
        let throwaway = AppTrainRepository(environment: Self.environment(), seedsFixture: true)
        #expect(try await throwaway.template(id: AppTrainFixtures.upperAID)?.exercises[0].sets == 4)
    }

    @Test func storeNamesAreCleanedAndNeverPointOutsideTheirFolder() {
        #expect(AppTrainFixtures.storeName(arguments: ["--loopr-train-fixture-store=template-relaunch-1"]) == "template-relaunch-1")
        #expect(AppTrainFixtures.storeName(arguments: ["--loopr-train-fixture-store=a/b c"]) == "abc")
        #expect(AppTrainFixtures.storeName(arguments: ["--loopr-train-fixture-store=.."]) == nil)
        #expect(AppTrainFixtures.storeName(arguments: ["--loopr-train-fixture-store=///"]) == nil)
        #expect(AppTrainFixtures.storeName(arguments: ["--loopr-train-fixture-store="]) == nil)
        #expect(AppTrainFixtures.storeName(arguments: ["--loopr-train-fixture"]) == nil)
        #expect(AppTrainFixtures.storeName(arguments: ["--loopr-train-fixture-store=\(String(repeating: "x", count: 200))"])?.count == 64)
        #expect(!AppTrainFixtures.isRequested(arguments: ["--loopr-train-fixture-store=x"]))
        #expect(AppTrainFixtures.stableRoot(named: "x").lastPathComponent == "x")
    }
}
