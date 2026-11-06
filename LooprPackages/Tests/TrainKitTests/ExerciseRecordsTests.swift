import Foundation
import Testing
import TrainKit

struct ExerciseRecordsTests {
    private let start = TrainFixture.date
    private static let squat = ExerciseRef(key: "Barbell_Squat", name: "Back squat")

    private func session(_ daysAgo: Double, _ ref: ExerciseRef = squat, sets: [(Double?, Int)],
                         status: TrainSessionStatus = .completed) throws -> TrainSession {
        let began = start.addingTimeInterval(-daysAgo * 86_400)
        let logged = sets.map { LoggedSet(loadKg: $0.0, reps: $0.1, loggedAt: began) }
        return try TrainSession(name: "Lower A", startedAt: began, timeZoneIdentifier: TrainFixture.zone,
                                endedAt: status == .active ? nil : began.addingTimeInterval(600), status: status,
                                exercises: [SessionExercise(planned: TrainFixture.line(ref), exercise: ref, status: .done, sets: logged)])
    }

    @Test func repBestsListOnlyRepCountsThatWereLifted() throws {
        let history = ExerciseHistory(sessions: [
            try session(14, sets: [(100, 5), (100, 5), (90, 8)]),
            try session(7, sets: [(105, 5), (80, 10), (nil, 3)]),
            try session(1, sets: [(105, 5), (110, 3)])
        ])
        let squat = try #require(history.exercise(key: Self.squat.key))
        let bests = ExerciseRepBest.bests(for: squat)
        #expect(bests.map(\.reps) == [3, 5, 8, 10], "no single was logged, and a set without load is not a best")
        #expect(bests.map(\.loadKg) == [110, 105, 90, 80])
        // 105 × 5 was lifted twice; the first time keeps the date.
        #expect(bests[1].date == start.addingTimeInterval(-7 * 86_400))
        #expect(ExerciseRepBest.bests(for: squat, repCounts: [1]).isEmpty)
    }

    @Test func trendNeedsThreePoints() {
        // One session draws one centred dot with its date, so the caption only says so (R2-DES-14).
        #expect(ExerciseTrend.caption(pointCount: 1) == "One session so far.")
        #expect(ExerciseTrend.caption(pointCount: 2) == "One more session to draw a trend.")
        #expect(ExerciseTrend.caption(pointCount: 3) == nil)
        #expect(ExerciseTrend.caption(pointCount: 0) == nil)
        #expect(!ExerciseTrend.drawsLine(pointCount: 2))
        #expect(ExerciseTrend.drawsLine(pointCount: 3))
    }

    @Test func historyJoinsTwoNamesForOneLift() throws {
        let customID = UUID(uuidString: "00000000-0000-0000-0000-0000000000D1")!
        let customPullUp = ExerciseRef(key: ExerciseDefinition.customKeyPrefix + customID.uuidString, name: "Pull ups")
        let libraryPullUp = ExerciseRef(key: "Pullups", name: "Pull-up")
        let rdl = ExerciseRef(key: ExerciseDefinition.customKeyPrefix + UUID(uuidString: "00000000-0000-0000-0000-0000000000D2")!.uuidString, name: "RDL")
        let romanian = ExerciseRef(key: "Romanian_Deadlift", name: "Romanian deadlift")
        let sessions = [
            try session(10, customPullUp, sets: [(nil, 6)]),
            try session(8, libraryPullUp, sets: [(nil, 8)]),
            try session(6, rdl, sets: [(80, 8)]),
            try session(4, romanian, sets: [(90, 8)]),
            try session(2, Self.squat, sets: [(100, 5)])
        ]
        // Without the merge, each name is its own exercise.
        #expect(ExerciseHistory(sessions: sessions).exercises.count == 5)

        let merged = ExerciseHistory(mergingAliasesIn: sessions)
        #expect(merged.exercises.count == 3)
        let pullUps = try #require(merged.exercise(key: "Pullups"))
        #expect(pullUps.entries.count == 2, "the library key wins over the custom one")
        #expect(pullUps.name == "Pull-up", "the newest name shows")
        #expect(merged.exercise(key: "Romanian_Deadlift")?.entries.count == 2)

        let keys = ExerciseHistoryMerge.canonicalKeys(in: sessions)
        #expect(keys[customPullUp.key] == "Pullups")
        #expect(keys[rdl.key] == "Romanian_Deadlift")
        #expect(keys[Self.squat.key] == Self.squat.key)
    }

    @Test func mergeKeepsTheSameKeyWhicheverOrderSessionsArrive() throws {
        let a = ExerciseRef(key: "pull-up", name: "Pull-up")
        let b = ExerciseRef(key: "Pullups", name: "Pullups")
        let sessions = [try session(3, a, sets: [(nil, 5)]), try session(2, b, sets: [(nil, 6)])]
        #expect(ExerciseHistoryMerge.canonicalKeys(in: sessions)[a.key] == "Pullups")
        #expect(ExerciseHistoryMerge.canonicalKeys(in: sessions.reversed())[a.key] == "Pullups")
    }

    @Test func recentsAreNewestFirstOncePerLift() throws {
        let bench = TrainFixture.bench
        let customPullUp = ExerciseRef(key: ExerciseDefinition.customKeyPrefix + UUID(uuidString: "00000000-0000-0000-0000-0000000000D3")!.uuidString,
                                       name: "Pull-up")
        let sessions = [
            try session(9, bench, sets: [(80, 8)]),
            try session(5, ExerciseRef(key: "Pullups", name: "Pullups"), sets: [(nil, 8)]),
            try session(3, customPullUp, sets: [(nil, 7)]),
            try session(1, Self.squat, sets: [(100, 5)]),
            try session(0, TrainFixture.row, sets: [(60, 8)], status: .active)
        ]
        #expect(ExerciseRecents.keys(from: sessions) == [Self.squat.key, "Pullups", bench.key], "the active session is not history yet")
        #expect(ExerciseRecents.keys(from: sessions, limit: 1) == [Self.squat.key])
        #expect(ExerciseRecents.keys(from: []).isEmpty)
    }
}
