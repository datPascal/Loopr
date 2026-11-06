import DomainKit
import Foundation
import Testing
import TrainKit

/// A workout built while training: a blank start, exercises and sets added and removed on the way.
struct TrainBuildAsYouGoTests {
    private let start = TrainFixture.date
    private let bench = ExerciseDefinition(key: TrainFixture.bench.key, name: TrainFixture.bench.name, category: "strength",
                                           equipment: "barbell", primaryMuscles: ["chest"])
    private let pullUp = ExerciseDefinition(key: "pull-up", name: "Pull-up", category: "strength", equipment: "body only",
                                            primaryMuscles: ["lats"])

    private func benchHistory(daysAgo: Double = 7) throws -> TrainSession {
        let began = start.addingTimeInterval(-daysAgo * 86_400)
        let sets = [(80.0, 8), (80, 8), (80, 7), (80, 6), (80, 6)].enumerated().map { index, pair in
            LoggedSet(loadKg: pair.0, reps: pair.1, loggedAt: began.addingTimeInterval(Double(index) * 180))
        }
        let line = SessionExercise(planned: TrainFixture.line(TrainFixture.bench), status: .done, sets: sets)
        return try TrainSession(name: "Workout", startedAt: began, timeZoneIdentifier: TrainFixture.zone,
                                endedAt: began.addingTimeInterval(2_400), status: .completed, exercises: [line])
    }

    private func blank(history: [TrainSession] = []) throws -> TrainLiveModel {
        try TrainLiveModel(setup: .freeform(history: history, timeZoneIdentifier: TrainFixture.zone), now: start)
    }

    @Test func aBlankWorkoutStartsWithNothingAndBelongsToNoTemplate() throws {
        let live = try blank()
        #expect(live.exerciseCount == 0)
        #expect(live.cursor == nil)
        #expect(live.session.templateID == nil)
        #expect(live.session.name == "Workout")
        #expect(throws: TrainLiveError.emptyTemplate) {
            try TrainLiveModel(setup: TrainLiveSetup(template: WorkoutTemplate(name: "Empty")), now: start)
        }
    }

    @Test func anAddedExerciseCopiesLastTimeAndBecomesCurrent() throws {
        var live = try blank(history: [benchHistory()])
        try live.addExercise(pullUp)
        let index = try live.addExercise(bench)
        #expect(index == 1)
        #expect(live.cursor == .init(exerciseIndex: 1, setIndex: 0), "the new exercise is current")
        #expect(live.session.exercises[1].planned.sets == 5, "as many sets as last time")
        #expect(live.currentPrefill?.loadKg == 80 && live.currentPrefill?.reps == 8)
        #expect(live.session.exercises[0].planned.loadKind == .bodyweight)
        #expect(live.session.exercises[0].planned.sets == 3)
    }

    @Test func addingASetReopensAFinishedExercise() throws {
        var live = try blank()
        try live.addExercise(bench)
        for _ in 0..<3 { try live.logSet(loadKg: 60, reps: 10, now: start) }
        #expect(live.session.exercises[0].status == .done)
        #expect(live.cursor == nil)
        try live.addSet(toExerciseAt: 0)
        #expect(live.session.exercises[0].status == .pending)
        #expect(live.cursor == .init(exerciseIndex: 0, setIndex: 3))
        try live.logSet(loadKg: 60, reps: 9, now: start)
        #expect(live.session.exercises[0].sets.count == 4)
    }

    @Test func deletingSetsMovesRowsUpAndTheLastOneRemovesTheExercise() throws {
        var live = try blank()
        try live.addExercise(bench)
        try live.logSet(loadKg: 60, reps: 10, now: start)
        try live.logSet(loadKg: 62.5, reps: 8, now: start)
        try live.removeSet(exerciseIndex: 0, setIndex: 0)
        #expect(live.session.exercises[0].sets.map(\.loadKg) == [62.5])
        #expect(live.session.exercises[0].planned.sets == 2)
        try live.removeSet(exerciseIndex: 0, setIndex: 1)
        #expect(live.session.exercises[0].planned.sets == 1)
        #expect(live.session.exercises[0].status == .done, "the only set left is logged")
        try live.removeSet(exerciseIndex: 0, setIndex: 0)
        #expect(live.exerciseCount == 0)
        #expect(throws: TrainLiveError.noSuchExercise) { try live.removeSet(exerciseIndex: 0, setIndex: 0) }
    }

    @Test func removingAnExerciseKeepsTheRestAndTheFocus() throws {
        var live = try blank()
        try live.addExercise(bench)
        try live.addExercise(pullUp)
        try live.focus(exerciseAt: 1)
        try live.removeExercise(at: 0)
        #expect(live.session.exercises.map(\.exercise.key) == ["pull-up"])
        #expect(live.cursor?.exerciseIndex == 0)
    }

    @Test func limitsMatchTheStore() throws {
        var live = try blank()
        try live.addExercise(bench)
        for _ in 3..<20 { try live.addSet(toExerciseAt: 0) }
        #expect(throws: TrainLiveError.tooManySets) { try live.addSet(toExerciseAt: 0) }
        var finished = try blank()
        try finished.addExercise(bench)
        try finished.logSet(loadKg: 60, reps: 5, now: start)
        let session = try finished.finish(now: start.addingTimeInterval(600))
        try session.validate()
        #expect(throws: TrainLiveError.sessionFinished) { try finished.addExercise(pullUp) }
    }

    @Test func aFinishedBlankWorkoutSavesAndValidates() throws {
        var live = try blank()
        try live.addExercise(bench)
        try live.logSet(loadKg: 70, reps: 5, now: start)
        let session = try live.finish(now: start.addingTimeInterval(900))
        #expect(session.status == .completed)
        #expect(session.countedSets.count == 1)
        #expect(session.exercises[0].status == .done, "open sets close as done when some were logged")
    }
}

struct ExerciseHistoryTests {
    private let start = TrainFixture.date

    private func session(_ daysAgo: Double, _ name: String = "Upper A", bench: [(Double?, Int)], skipped: Bool = false) throws -> TrainSession {
        let began = start.addingTimeInterval(-daysAgo * 86_400)
        var sets = bench.map { LoggedSet(loadKg: $0.0, reps: $0.1, loggedAt: began) }
        if skipped { sets.append(LoggedSet(loadKg: nil, reps: 0, loggedAt: began, skipped: true)) }
        return try TrainSession(name: name, startedAt: began, timeZoneIdentifier: TrainFixture.zone, endedAt: began.addingTimeInterval(600),
                                status: .completed, exercises: [SessionExercise(planned: TrainFixture.line(TrainFixture.bench), status: .done, sets: sets)])
    }

    @Test func groupsByExerciseNewestFirstWithBests() throws {
        let history = ExerciseHistory(sessions: [try session(14, bench: [(80, 8), (80, 6)]), try session(7, bench: [(85, 5)], skipped: true)])
        let bench = try #require(history.exercise(key: TrainFixture.bench.key))
        #expect(bench.entries.count == 2)
        #expect(bench.entries[0].date > bench.entries[1].date)
        #expect(bench.entries[0].sets.count == 1, "the skipped set is left out")
        #expect(bench.heaviestLoad == 85)
        #expect(abs((bench.bestEstimatedOneRepMax ?? 0) - 101.33) < 0.01, "80 × (1 + 8/30) = 101.3 beats 85 × (1 + 5/30) = 99.2")
        #expect(bench.bestSetVolume == 640)
        #expect(bench.setCount == 3)
    }

    @Test func setsTextGroupsEqualLoads() {
        let at = Date(timeIntervalSince1970: 0)
        #expect(ExerciseHistory.setsText([LoggedSet(loadKg: 80, reps: 8, loggedAt: at), LoggedSet(loadKg: 80, reps: 7, loggedAt: at),
                                          LoggedSet(loadKg: 82.5, reps: 5, loggedAt: at)]) == "80 kg × 8, 7, 82.5 kg × 5")
        #expect(ExerciseHistory.setsText([LoggedSet(loadKg: nil, reps: 12, loggedAt: at), LoggedSet(loadKg: nil, reps: 10, loggedAt: at)]) == "12, 10 reps")
    }

    @Test func csvHasOneRowPerSetWithTheEstimate() throws {
        let csv = TrainCSV.sets([try session(1, "Push, heavy", bench: [(100, 5)], skipped: true)])
        let lines = csv.split(separator: "\r\n").map(String.init)
        #expect(lines.count == 3)
        #expect(lines[0] == "date,time,workout,exercise,set,weight_kg,reps,rpe,estimated_1rm_kg,skipped,session_id,exercise_key,measure,seconds,metres,assist_kg,tag")
        #expect(lines[1].contains("\"Push, heavy\",Barbell bench press,1,100,5,,116.7,no,"))
        #expect(lines[2].contains(",2,,,,,yes,"))
    }

    @Test func csvFieldsAreQuotedAndFormulaSafe() {
        #expect(CSV.text([["a,b", "say \"hi\"", "=SUM(A1)", "-5"]]) == "\"a,b\",\"say \"\"hi\"\"\",'=SUM(A1),-5\r\n")
        #expect(CSV.number(82.5) == "82.5" && CSV.number(80) == "80" && CSV.number(nil) == "")
    }
}
