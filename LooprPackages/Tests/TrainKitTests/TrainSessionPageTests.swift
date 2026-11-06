import Foundation
import Testing
@testable import TrainKit

@Suite("Gym session page")
struct TrainSessionPageTests {
    private static let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func session(id: UUID = UUID(), daysAgo: Double = 0, sets: [(Double?, Int)], rpe: Double? = nil, skippedLast: Bool = false,
                         plannedSets: Int = 4, key: String = "bench", bests: [PersonalBest] = []) throws -> TrainSession {
        let begin = Self.start.addingTimeInterval(-daysAgo * 86_400)
        let ref = ExerciseRef(key: key, name: "Bench press")
        var logged = sets.enumerated().map { index, set in
            LoggedSet(loadKg: set.0, reps: set.1, rpe: rpe, loggedAt: begin.addingTimeInterval(Double(index) * 130))
        }
        if skippedLast { logged.append(LoggedSet(loadKg: nil, reps: 0, loggedAt: begin.addingTimeInterval(600), skipped: true)) }
        let planned = TemplateExercise(exercise: ref, sets: plannedSets, repsMin: 8, repsMax: 10)
        return try TrainSession(id: id, name: "Upper A", startedAt: begin, timeZoneIdentifier: "UTC", endedAt: begin.addingTimeInterval(3_600), status: .completed,
                                exercises: [SessionExercise(planned: planned, status: .done, sets: logged)], bests: bests)
    }

    @Test func lastTimeAndTheChangeComeFromEarlierSessions() throws {
        let earlier = try session(daysAgo: 7, sets: [(80, 7), (80, 7), (80, 6), (80, 6)])
        let now = try session(sets: [(80, 8), (80, 7), (80, 7), (80, 6)])
        let exercise = try #require(TrainSessionComparison(session: now, history: [earlier, now]).exercises[0])
        #expect(exercise.lastTimeLine?.contains("80 kg × 7, 7, 6, 6") == true)
        #expect(exercise.changeLine == "+2 reps")
    }

    @Test func aHeavierTopSetIsReportedAsLoad() {
        func set(_ kg: Double, _ reps: Int) -> LoggedSet { LoggedSet(loadKg: kg, reps: reps, loggedAt: Self.start) }
        #expect(TrainSessionComparison.changeLine(now: [set(82.5, 8)], last: [set(80, 8)]) == "+2.5 kg on the top set")
        #expect(TrainSessionComparison.changeLine(now: [set(80, 8)], last: [set(80, 8)]) == "Same as last time")
    }

    @Test func theOneRepMaxShowsEveryTimeLabelledAndSaysWhatItWas() throws {
        let earlier = try session(daysAgo: 7, sets: [(80, 6)])
        let now = try session(sets: [(80, 8)])
        let exercise = try #require(TrainSessionComparison(session: now, history: [earlier, now]).exercises[0])
        #expect(exercise.oneRepMaxLine == "Estimated 1RM 101 kg, was 96 kg")
        let first = try #require(TrainSessionComparison(session: now, history: []).exercises[0])
        #expect(first.oneRepMaxLine == "Estimated 1RM 101 kg")
    }

    @Test func anAssistedSetIsNotComparedAsALoad() throws {
        var earlier = try session(daysAgo: 7, sets: [(nil, 8)], key: "pull")
        earlier.exercises[0].sets[0].assistKg = 20
        var now = try session(sets: [(nil, 8)], key: "pull")
        now.exercises[0].sets[0].assistKg = 15
        let exercise = try #require(TrainSessionComparison(session: now, history: [earlier, now]).exercises[0])
        #expect(exercise.changeLine == nil && exercise.lastTimeLine == nil && exercise.oneRepMaxLine == nil)
    }

    @Test func aForgottenSetCanBeAddedAndCountsTowardBests() throws {
        let now = try session(sets: [(80, 8)])
        let added = try TrainSessionCorrection.adding(now, exerciseIndex: 0, values: TrainSetValues(loadKg: 82.5, reps: 8), tag: nil, rpe: 8, history: [])
        #expect(added.exercises[0].sets.count == 2)
        #expect(added.exercises[0].sets[1].rpe == 8 && added.exercises[0].sets[1].edited)
        #expect(added.exercises[0].sets[1].loggedAt > now.exercises[0].sets[0].loggedAt)
        #expect(!added.bests.isEmpty)
        #expect(throws: (any Error).self) {
            try TrainSessionCorrection.adding(now, exerciseIndex: 0, values: TrainSetValues(loadKg: 80, reps: 0), tag: nil, rpe: nil, history: [])
        }
    }

    @Test func anEditCanChangeTheRPE() throws {
        let now = try session(sets: [(80, 8)], rpe: 9)
        let fixed = try TrainSessionCorrection.editing(now, exerciseIndex: 0, setIndex: 0, values: TrainSetValues(loadKg: 80, reps: 8), tag: nil, rpe: 7, history: [])
        #expect(fixed.exercises[0].sets[0].rpe == 7)
        #expect(throws: (any Error).self) {
            try TrainSessionCorrection.editing(now, exerciseIndex: 0, setIndex: 0, values: TrainSetValues(loadKg: 80, reps: 8), tag: nil, rpe: 3, history: [])
        }
    }

    @Test func aFirstSessionHasNoLastTime() throws {
        let now = try session(sets: [(80, 8)])
        let exercise = try #require(TrainSessionComparison(session: now, history: [now]).exercises[0])
        #expect(exercise.lastTimeLine == nil && exercise.changeLine == nil)
    }

    @Test func restComesFromTheLogTimes() {
        let sets = [0.0, 130, 260].map { LoggedSet(loadKg: 80, reps: 8, loggedAt: Self.start.addingTimeInterval($0)) }
        #expect(TrainSessionComparison.restLine(sets) == "Rest about 2:10, longest 2:10")
        #expect(TrainSessionComparison.restLine(Array(sets.prefix(1))) == nil)
        let walkedOff = [LoggedSet(loadKg: 80, reps: 8, loggedAt: Self.start), LoggedSet(loadKg: 80, reps: 8, loggedAt: Self.start.addingTimeInterval(2_000))]
        #expect(TrainSessionComparison.restLine(walkedOff) == nil)
    }

    @Test func fixingATypoRecomputesTheBests() throws {
        let earlier = try session(daysAgo: 7, sets: [(80, 8)])
        let typo = try session(sets: [(800, 8)])
        var withBests = typo
        withBests.bests = PersonalBestEvaluator.evaluate(session: typo, history: [earlier])
        #expect(withBests.bests.contains { $0.isNewBest })
        let fixed = try TrainSessionCorrection.editing(withBests, exerciseIndex: 0, setIndex: 0, values: TrainSetValues(loadKg: 80, reps: 8), tag: nil, history: [earlier])
        #expect(fixed.exercises[0].sets[0].loadKg == 80)
        #expect(fixed.exercises[0].sets[0].edited)
        #expect(!fixed.bests.contains { $0.isNewBest })
    }

    @Test func aBadEditIsRefusedAndDeletingTheLastSetSkipsTheExercise() throws {
        let now = try session(sets: [(80, 8)])
        #expect(throws: (any Error).self) {
            try TrainSessionCorrection.editing(now, exerciseIndex: 0, setIndex: 0, values: TrainSetValues(loadKg: 80, reps: 0), tag: nil, history: [])
        }
        #expect(throws: (any Error).self) {
            try TrainSessionCorrection.editing(now, exerciseIndex: 3, setIndex: 0, values: TrainSetValues(loadKg: 80, reps: 8), tag: nil, history: [])
        }
        let deleted = try TrainSessionCorrection.deleting(now, exerciseIndex: 0, setIndex: 0, history: [])
        #expect(deleted.exercises[0].sets.isEmpty && deleted.exercises[0].status == .skipped)
        #expect(deleted.bests.isEmpty)
    }
}
