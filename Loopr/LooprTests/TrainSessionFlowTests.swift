import DomainKit
import Foundation
import JournalKit
import StorageKit
import Testing
import TrainKit
import WorkoutKit
@testable import Loopr

/// A live strength session from start to summary against real SQLite stores. Alex trains in
/// Australia/Perth on the fixture day, Tuesday 2023-11-14.
@MainActor struct TrainSessionFlowTests {
    /// A clock that moves one minute on every read, so a workout always ends after it starts.
    private final class StepClock: @unchecked Sendable {
        private let lock = NSLock()
        private var current: Date
        init(start: Date) { current = start }
        func tick() -> Date {
            lock.lock(); defer { lock.unlock() }
            current = current.addingTimeInterval(60)
            return current
        }
    }

    @MainActor private struct Rig {
        let root: URL
        let database: StorageDatabase
        let repository: AppTrainRepository
        let workouts: SQLiteWorkoutStore
        let workoutSession: WorkoutSessionController
        let sessionClock: StepClock
        let runtime = TrainLiveRuntime()

        func environment(restSeconds: Int? = 1) -> TrainLiveEnvironment {
            TrainLiveEnvironment(repository: repository, workoutSession: workoutSession, bandRuntime: nil, bandCueAvailable: false,
                                 clock: { @Sendable [sessionClock] in sessionClock.tick() }, restSecondsOverride: restSeconds,
                                 timeZoneIdentifier: AppTrainFixtures.zone.identifier)
        }

        func startWorkout() async throws -> WorkoutRecord {
            var workout = try await workoutSession.start(activity: .strength, source: .live)
            _ = try await workoutSession.transition(to: .preparing)
            workout = try await workoutSession.transition(to: .active)
            return workout
        }

        func setup(workout: WorkoutRecord, score: Double? = 79) async throws -> TrainLiveSetup {
            let history = try await repository.recentSessions(limit: 50)
            let template = try #require(try await repository.template(id: AppTrainFixtures.upperAID))
            var setup = TrainLiveSetup(template: template, recoveryScore: score, programID: AppTrainFixtures.strengthBlockID,
                                       programWeek: 3, history: history, timeZoneIdentifier: AppTrainFixtures.zone.identifier)
            setup.swapPool = await TrainLiveRuntime.loadSwapPool(repository: repository)
            setup.workoutID = workout.id
            return setup
        }
    }

    private static func rig() async throws -> Rig {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("train-session-flow-\(UUID().uuidString)")
        let database = try StorageDatabase(url: root.appendingPathComponent("loopr.sqlite"), applicationVersion: "test")
        let environment = AppEnvironment.make(arguments: ["--loopr-launch-mode=populated"], environment: [:])
        let repository = AppTrainRepository(store: TrainStore(database: database), environment: environment)
        try AppTrainFixtures.seed(TrainStore(database: database))
        let workouts = try SQLiteWorkoutStore(database: database)
        let clock = StepClock(start: AppTrainFixtures.now)
        let controller = WorkoutSessionController(store: workouts, now: { @Sendable in clock.tick() })
        return Rig(root: root, database: database, repository: repository, workouts: workouts, workoutSession: controller,
                   sessionClock: StepClock(start: AppTrainFixtures.now.addingTimeInterval(600)))
    }

    @Test func startToFinishSavesTheSessionItsSetsAndTheLinkedWorkout() async throws {
        let rig = try await Self.rig()
        defer { try? rig.database.databasePool.close(); try? FileManager.default.removeItem(at: rig.root) }
        let workout = try await rig.startWorkout()
        try rig.runtime.begin(setup: try await rig.setup(workout: workout), environment: rig.environment())
        let live = try #require(rig.runtime.session)
        #expect(rig.runtime.hasSession && rig.runtime.workoutID == workout.id)
        #expect(live.model.session.status == .active && live.model.session.workoutID == workout.id)
        #expect(live.model.lastTimeSummary(forExerciseAt: 0) == "Last time 80 kg × 7, 7, 6, 6")

        // Bench: one more rep than last time, four sets, an RPE on the first.
        live.draft.reps = 8
        for _ in 0..<4 { live.logSet() }
        live.setRPE(8, exerciseIndex: 0, setIndex: 0)
        #expect(live.model.session.exercises[0].status == .done)
        live.skipExercise(at: 1)
        // A swap on the third exercise.
        let option = try #require(live.model.swapOptions(forExerciseAt: 2).first)
        live.swapExercise(at: 2, with: option)
        #expect(live.model.session.exercises[2].swappedFrom?.name == "Barbell row")

        // Progress is saved while training, as an active session the overview ignores.
        await rig.runtime.waitForCheckpoint()
        let checkpoint = try #require(try await rig.repository.session(workoutID: workout.id))
        #expect(checkpoint.status == .active && checkpoint.exercises[0].sets.count == 4)
        #expect(try await rig.repository.recentSessions(limit: 50).filter { $0.name == "Upper A" }.count == 1)

        let completed = try await rig.runtime.finish { _ = try await rig.workoutSession.finish(id: workout.id) }
        rig.runtime.end()
        #expect(!rig.runtime.hasSession && rig.runtime.workoutID == nil)

        // The session, its sets and its bests are stored and linked to the workout.
        let saved = try #require(try await rig.repository.session(id: completed.id))
        #expect(saved.status == .completed && saved.workoutID == workout.id && saved.name == "Upper A")
        #expect(saved.localDay == "2023-11-14" && saved.programWeek == 3 && saved.programID == AppTrainFixtures.strengthBlockID)
        // The swapped exercise got no sets, so it closes as skipped and still remembers what it replaced.
        #expect(saved.exercises.map(\.status) == [.done, .skipped, .skipped, .skipped, .skipped, .skipped])
        #expect(saved.exercises[2].swappedFrom?.name == "Barbell row" && saved.exercises[2].exercise.key == option.key)
        #expect(saved.exercises[0].sets.count == 4 && saved.exercises[0].sets[0].rpe == 8)
        #expect(saved.tonnageKg == 80 * 8 * 4)
        let metrics = saved.bests.map(\.metric)
        #expect(metrics == [.estimatedOneRepMax, .bestSetVolume] && saved.bests.allSatisfy(\.isNewBest))
        #expect(try await rig.repository.session(workoutID: workout.id)?.id == completed.id)
        #expect(try await rig.repository.recentSessions(limit: 50).filter { $0.workoutID == workout.id }.count == 1)

        // The workout record is a finished strength workout, the kind Journal and strain read.
        let record = try #require(await rig.workouts.workout(id: workout.id))
        #expect(record.state == .completed && record.activity == .strength && record.source == .live)
        #expect(record.finalizationStage == .activeStateCleared)

        // The overview now shows the session this week and today as done.
        let loader = TrainOverviewLoader(repository: rig.repository, workouts: rig.workouts)
        await loader.load(now: AppTrainFixtures.now.addingTimeInterval(1_800), calendar: AppTrainFixtures.calendar, history: TrainFixtureMetricHistory())
        let overview = try #require(loader.overview)
        #expect(overview.thisWeek.contains { $0.name == "Upper A" && $0.localDay == "2023-11-14" && $0.tonnageKg == 2_560 })
        if case .done(let done) = overview.today { #expect(done.name == "Upper A") } else { Issue.record("Expected today to be done") }
    }

    @Test func theFinishedWorkoutFillsJournalTrainedToday() async throws {
        let rig = try await Self.rig()
        defer { try? rig.database.databasePool.close(); try? FileManager.default.removeItem(at: rig.root) }
        let habits = try SQLiteHabitRepository(database: rig.database)
        let question = HabitDefinition(id: HabitID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000007001")!),
            source: .preset(catalogID: "trained_today"), name: "Trained today", question: "Trained today?", sortOrder: 0,
            createdAt: AppTrainFixtures.now)
        try await habits.saveDefinition(question)
        let day = DayIdentity(year: 2023, month: 11, day: 14)
        let zone = AppTrainFixtures.zone.identifier
        let provider = AppJournalAutoFillProvider(readTraining: { @Sendable [workouts = rig.workouts] in try await workouts.journalAutoFillRecords() })
        let service = JournalAutoFillService(store: habits, clock: FlowClock(value: AppTrainFixtures.now))

        // Before the session nothing is filled for the day.
        try await service.reconcile(provider.snapshot(for: day, timeZoneID: zone))
        #expect(try await habits.dayRecord(for: day)?.response(for: question.id) == nil)

        let workout = try await rig.startWorkout()
        try rig.runtime.begin(setup: try await rig.setup(workout: workout), environment: rig.environment())
        let live = try #require(rig.runtime.session)
        live.logSet()
        _ = try await rig.runtime.finish { _ = try await rig.workoutSession.finish(id: workout.id) }

        try await service.reconcile(provider.snapshot(for: day, timeZoneID: zone))
        let filled = try #require(try await habits.dayRecord(for: day)?.response(for: question.id))
        #expect(filled.answer == .yes)
        #expect(filled.autoFillProvenance?.summary == "Strength training")
    }

    @Test func aFailedWorkoutFinishKeepsTheLogAndARetryDoesNotSaveTwice() async throws {
        let rig = try await Self.rig()
        defer { try? rig.database.databasePool.close(); try? FileManager.default.removeItem(at: rig.root) }
        let workout = try await rig.startWorkout()
        try rig.runtime.begin(setup: try await rig.setup(workout: workout), environment: rig.environment())
        let live = try #require(rig.runtime.session)
        live.logSet()
        live.logSet()

        struct Boom: Error {}
        await #expect(throws: Boom.self) { _ = try await rig.runtime.finish { throw Boom() } }
        #expect(rig.runtime.isFinishing)
        let afterFailure = try #require(try await rig.repository.session(workoutID: workout.id))
        #expect(afterFailure.status == .completed && afterFailure.exercises[0].sets.count == 2)
        // The model is closed, so nothing more can be logged while the workout is still recording.
        live.logSet()
        #expect(live.model.session.exercises[0].sets.count == 2 && live.errorMessage == "This session is already finished.")

        let completed = try await rig.runtime.finish { _ = try await rig.workoutSession.finish(id: workout.id) }
        #expect(completed.id == afterFailure.id && completed.revision == afterFailure.revision)
        #expect(try await rig.repository.recentSessions(limit: 50).filter { $0.workoutID == workout.id }.count == 1)
        #expect(await rig.workouts.workout(id: workout.id)?.state == .completed)
    }

    @Test func aRelaunchResumesTheSavedSessionAtTheSameSet() async throws {
        let rig = try await Self.rig()
        defer { try? rig.database.databasePool.close(); try? FileManager.default.removeItem(at: rig.root) }
        let workout = try await rig.startWorkout()
        try rig.runtime.begin(setup: try await rig.setup(workout: workout), environment: rig.environment())
        let live = try #require(rig.runtime.session)
        live.logSet(); live.logSet()
        await rig.runtime.waitForCheckpoint()
        let before = live.model.cursor

        let relaunched = TrainLiveRuntime()
        let active = try #require(await rig.workoutSession.activeWorkout())
        let resumed = await relaunched.resumeIfNeeded(for: active, environment: rig.environment(), swapPool: { @Sendable [repository = rig.repository] in
            await TrainLiveRuntime.loadSwapPool(repository: repository)
        })
        #expect(resumed && relaunched.hasSession && relaunched.workoutID == workout.id)
        #expect(relaunched.session?.model.cursor == before)
        #expect(relaunched.session?.model.session.exercises[0].sets.count == 2)
        #expect(relaunched.session?.model.lastTimeSummary(forExerciseAt: 0) == "Last time 80 kg × 7, 7, 6, 6")
        // Logging again carries on from the resumed state and saves without a stale revision.
        relaunched.session?.logSet()
        await relaunched.waitForCheckpoint()
        #expect(try await rig.repository.session(workoutID: workout.id)?.exercises[0].sets.count == 3)
        // A recording that was never a template session resumes nothing.
        let plain = TrainLiveRuntime()
        var other = workout
        other.activity = .run
        #expect(await plain.resumeIfNeeded(for: other, environment: rig.environment(), swapPool: { [] }) == false)
    }

    @Test func aDiscardedWorkoutLeavesTheSessionAbandonedNotCompleted() async throws {
        let rig = try await Self.rig()
        defer { try? rig.database.databasePool.close(); try? FileManager.default.removeItem(at: rig.root) }
        let workout = try await rig.startWorkout()
        try rig.runtime.begin(setup: try await rig.setup(workout: workout), environment: rig.environment())
        rig.runtime.session?.logSet()
        await rig.runtime.abandon()
        #expect(!rig.runtime.hasSession)
        let stored = try #require(try await rig.repository.session(workoutID: workout.id))
        #expect(stored.status == .abandoned && stored.endedAt != nil)
        // An abandoned session never counts toward history, bests or the week.
        #expect(try await rig.repository.recentSessions(limit: 50).allSatisfy { $0.id != stored.id })
    }

    @Test func abandonDoesNothingOnceFinishHasStarted() async throws {
        let rig = try await Self.rig()
        defer { try? rig.database.databasePool.close(); try? FileManager.default.removeItem(at: rig.root) }
        let workout = try await rig.startWorkout()
        try rig.runtime.begin(setup: try await rig.setup(workout: workout), environment: rig.environment())
        rig.runtime.session?.logSet()
        _ = try await rig.runtime.finish { _ = try await rig.workoutSession.finish(id: workout.id) }
        await rig.runtime.abandon()
        #expect(rig.runtime.hasSession)
        #expect(try await rig.repository.session(workoutID: workout.id)?.status == .completed)
    }

    @Test func lowRecoveryStartsALighterSessionAndRecordsWhy() async throws {
        let rig = try await Self.rig()
        defer { try? rig.database.databasePool.close(); try? FileManager.default.removeItem(at: rig.root) }
        let workout = try await rig.startWorkout()
        try rig.runtime.begin(setup: try await rig.setup(workout: workout, score: 31), environment: rig.environment())
        let live = try #require(rig.runtime.session)
        #expect(live.model.session.exercises.map(\.planned.sets) == [3, 3, 3, 2, 3, 2])
        #expect(live.model.session.appliedAdjustments.first?.kind == .setsRemoved)
        #expect(live.model.eyebrow == "1 of 6 · set 1 of 3")
    }

    @Test func beginningWithATemplateThatCannotRunThrowsBeforeAnythingIsSaved() async throws {
        let rig = try await Self.rig()
        defer { try? rig.database.databasePool.close(); try? FileManager.default.removeItem(at: rig.root) }
        let setup = TrainLiveSetup(template: WorkoutTemplate(name: "Empty"))
        #expect(throws: TrainLiveError.emptyTemplate) { try rig.runtime.begin(setup: setup, environment: rig.environment()) }
        #expect(!rig.runtime.hasSession)
    }

    @Test func theFixtureClockPinsTheDayAndKeepsRunning() async throws {
        let clock = TrainLiveRuntime.makeClock(fixtureStart: AppTrainFixtures.now)
        let first = clock()
        #expect(abs(first.timeIntervalSince(AppTrainFixtures.now)) < 2)
        try await Task.sleep(for: .milliseconds(30))
        #expect(clock() > first)
        #expect(abs(TrainLiveRuntime.makeClock(fixtureStart: nil)().timeIntervalSinceNow) < 2)
    }

    @Test func theActivityOverlayNamesTheNextSetAndTheRestEnd() async throws {
        let template = AppTrainFixtures.upperA
        var model = try TrainLiveModel(setup: TrainLiveSetup(template: template, restSecondsOverride: 90,
                                                              timeZoneIdentifier: AppTrainFixtures.zone.identifier), now: AppTrainFixtures.now)
        var overlay = TrainLiveRuntime.overlay(for: model, now: AppTrainFixtures.now)
        #expect(overlay.setSummary == "Bench press · set 1 of 4" && overlay.restEndsAt == nil)
        try model.logSet(loadKg: 80, reps: 8, now: AppTrainFixtures.now)
        overlay = TrainLiveRuntime.overlay(for: model, now: AppTrainFixtures.now)
        #expect(overlay.setSummary == "Bench press · set 2 of 4" && overlay.restEndsAt == AppTrainFixtures.now.addingTimeInterval(90))
        // After the end date the rest is gone from the overlay.
        overlay = TrainLiveRuntime.overlay(for: model, now: AppTrainFixtures.now.addingTimeInterval(91))
        #expect(overlay.restEndsAt == nil)
    }
}

private nonisolated struct FlowClock: DateProviding {
    let value: Date
    func now() -> Date { value }
}
