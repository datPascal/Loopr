import AnalyticsKit
import Foundation
import Testing
@testable import TrainKit

/// The past gym session logger's draft (R2-LIFT-05) and the capacity norms (R2-VET-06).
struct TrainPastSessionTests {
    private static let bench = ExerciseDefinition(key: "barbell-bench-press", name: "Barbell bench press", category: "strength",
                                                  equipment: "barbell", primaryMuscles: ["chest"])
    private static let squat = ExerciseDefinition(key: "barbell-squat", name: "Back squat", category: "strength",
                                                  equipment: "barbell", primaryMuscles: ["quadriceps"])

    @Test func aNewExerciseStartsFromLastTime() throws {
        let earlier = try TrainFixture.session(startedAt: TrainFixture.date.addingTimeInterval(-7 * 86_400))
        var draft = TrainPastSessionDraft(startedAt: TrainFixture.date, history: [earlier], timeZoneIdentifier: TrainFixture.zone)
        try draft.addExercise(Self.bench)
        try draft.addExercise(Self.squat)
        // Bench was done before: its two working sets, 80 kg × 8 and × 7. Squat was not: three sets of 8.
        #expect(draft.lines[0].fromLastTime && draft.lines[0].rows.map(\.values.reps) == [8, 7])
        #expect(draft.lines[0].rows.map(\.values.loadKg) == [80, 80])
        #expect(!draft.lines[1].fromLastTime && draft.lines[1].rows.count == TrainPastSessionDraft.defaultSetCount)
    }

    @Test func savingNeedsASetAndAnEndBeforeNow() throws {
        let now = TrainFixture.date
        var draft = TrainPastSessionDraft(startedAt: now.addingTimeInterval(-30 * 60), durationMinutes: 60,
                                          timeZoneIdentifier: TrainFixture.zone)
        #expect(draft.problem(now: now) == .noExercise)
        try draft.addExercise(Self.squat)
        #expect(draft.problem(now: now) == .inFuture)
        draft.startedAt = now.addingTimeInterval(-2 * 3_600)
        #expect(draft.problem(now: now) == nil)
        draft.removeSet(lineIndex: 0, rowIndex: 0); draft.removeSet(lineIndex: 0, rowIndex: 0); draft.removeSet(lineIndex: 0, rowIndex: 0)
        #expect(draft.problem(now: now) == .noSet)
    }

    @Test func theSessionIsCompletedAtTheChosenTime() throws {
        let now = TrainFixture.date
        let start = now.addingTimeInterval(-26 * 3_600)
        var draft = TrainPastSessionDraft(startedAt: start, durationMinutes: 45, timeZoneIdentifier: TrainFixture.zone, name: " Legs ")
        try draft.addExercise(Self.squat)
        draft.updateSet(lineIndex: 0, rowIndex: 0, values: TrainSetValues(loadKg: 100, reps: 5), tag: nil)
        let workoutID = UUID()
        let session = try draft.session(workoutID: workoutID, now: now)
        #expect(session.status == .completed && session.workoutID == workoutID && session.name == "Legs")
        #expect(session.startedAt == start && session.endedAt == start.addingTimeInterval(45 * 60))
        #expect(session.exercises[0].sets.count == 3 && session.exercises[0].sets[0].loadKg == 100)
        #expect(session.exercises[0].sets.allSatisfy { $0.loggedAt >= start && $0.loggedAt < start.addingTimeInterval(45 * 60) })
    }

    // MARK: Starter routine

    @Test func theBeginnersWorkoutIsValidAndOfferedOnlyToFewWorkouts() throws {
        let template = TrainStarterRoutine.template(now: TrainFixture.date)
        try template.validate()
        #expect(template.exercises.map(\.measure) == [.weight, .weight, .bodyweight, .time])
        #expect(template.exercises.allSatisfy { $0.loadKg == nil })
        #expect(TrainStarterRoutine.isOffered(templateNames: ["Lower A", "Upper A"]))
        #expect(!TrainStarterRoutine.isOffered(templateNames: [TrainStarterRoutine.name]))
        #expect(!TrainStarterRoutine.isOffered(templateNames: ["A", "B", "C"]))
    }

    // MARK: Norms

    @Test func gripNamesTheMedianAndWhereTheBestSits() throws {
        let norm = try #require(CapacityNorm.make(kind: .grip, best: 52, age: 46, group: .male))
        #expect(norm.line == "Men aged 45 in the table (you are 46): median 49 kg, middle half 42 to 56 kg. Yours is above the median.")
        #expect(norm.source?.hasPrefix("Dodds 2014") == true)
        #expect(CapacityNorm.make(kind: .grip, best: 52, age: 46, group: nil)?.line == CapacityNorm.needsSex)
        #expect(CapacityNorm.make(kind: .grip, best: 52, age: nil, group: .male)?.line == CapacityNorm.needsAge)
    }

    @Test func sitToStandFollowsTheChartsGaps() throws {
        // No top quarter up to 45: a perfect 10 at 30 is at or above the median, not the top quarter.
        let young = try #require(CapacityNorm.make(kind: .sitToStand, best: 10, age: 30, group: .male))
        #expect(young.line == "Men aged 26 to 30: 9.5 or more is at or above the median. Yours is at or above the median.")
        // Men 51 to 55 have no second quarter: 7.5 is the bottom quarter.
        #expect(CapacityNorm.make(kind: .sitToStand, best: 7.5, age: 53, group: .male)?.line.hasSuffix("Yours is in the bottom quarter.") == true)
        // From 76 women have no bottom quarter: 0 is the second quarter.
        #expect(CapacityNorm.make(kind: .sitToStand, best: 0, age: 78, group: .female)?.line
            .hasSuffix("Yours is in the second quarter, below the median.") == true)
        #expect(CapacityNorm.make(kind: .sitToStand, best: 9, age: 90, group: .female)?.line.hasPrefix("Women over 85") == true)
    }

    @Test func balanceGivesTheAverageOnlyAndDeadHangHasNone() throws {
        let balance = try #require(CapacityNorm.make(kind: .oneLegBalance, best: 30, age: 44, group: nil))
        #expect(balance.line == "Ages 40 to 49, eyes closed: average 12.7 s, spread about 12.9 s either way. Yours is well above the average.")
        #expect(CapacityNorm.make(kind: .deadHang, best: 60, age: 44, group: .male)?.line == CapacityNorm.noNorm)
        #expect(CapacityNorm.make(kind: .heartRateRecovery, best: 30, age: 44, group: .male) == nil)
    }
}
