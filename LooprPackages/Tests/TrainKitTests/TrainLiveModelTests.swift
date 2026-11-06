import Foundation
import Testing
import TrainKit

/// The live session model with a fixed clock. Alex trains in Australia/Perth.
struct TrainLiveModelTests {
    private let start = TrainFixture.date
    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    private func history(loads: [Double] = [80, 80, 80, 80], reps: [Int] = [7, 7, 6, 6], daysAgo: Double = 7,
                         exercise: ExerciseRef = TrainFixture.bench) throws -> TrainSession {
        let began = start.addingTimeInterval(-daysAgo * 86_400)
        let sets = zip(loads, reps).enumerated().map { index, pair in
            LoggedSet(loadKg: pair.0, reps: pair.1, loggedAt: began.addingTimeInterval(Double(index) * 200), prefillSource: .template)
        }
        let line = SessionExercise(planned: TrainFixture.line(exercise), exercise: exercise, status: .done, sets: sets)
        return try TrainSession(name: "Upper A", startedAt: began, timeZoneIdentifier: TrainFixture.zone,
                                endedAt: began.addingTimeInterval(3_000), status: .completed, exercises: [line])
    }

    private func library() throws -> [ExerciseDefinition] {
        [ExerciseDefinition(key: TrainFixture.bench.key, name: TrainFixture.bench.name, category: "strength", equipment: "barbell",
                            mechanic: "compound", primaryMuscles: ["chest"]),
         ExerciseDefinition(key: "dumbbell-bench-press", name: "Dumbbell bench press", category: "strength", equipment: "dumbbell",
                            mechanic: "compound", primaryMuscles: ["chest"]),
         ExerciseDefinition(key: "incline-barbell-press", name: "Incline barbell press", category: "strength", equipment: "barbell",
                            mechanic: "compound", primaryMuscles: ["chest", "shoulders"]),
         ExerciseDefinition(key: "push-up", name: "Push-up", category: "strength", equipment: "body only",
                            mechanic: "compound", primaryMuscles: ["chest"]),
         ExerciseDefinition(key: "squat", name: "Squat", category: "strength", equipment: "barbell", primaryMuscles: ["quadriceps"]),
         ExerciseDefinition(key: TrainFixture.row.key, name: TrainFixture.row.name, category: "strength", equipment: "barbell",
                            primaryMuscles: ["middle back"]),
         ExerciseDefinition(key: TrainFixture.pushdown.key, name: TrainFixture.pushdown.name, category: "strength", equipment: "cable",
                            primaryMuscles: ["triceps"])]
    }

    private func model(_ template: WorkoutTemplate = TrainFixture.template(), score: Double? = 79, history: [TrainSession] = [],
                       restOverride: Int? = nil) throws -> TrainLiveModel {
        try TrainLiveModel(setup: TrainLiveSetup(template: template, recoveryScore: score, history: history, swapPool: library(),
                                                 restSecondsOverride: restOverride, timeZoneIdentifier: TrainFixture.zone), now: start)
    }

    private func supersetTemplate() -> WorkoutTemplate {
        let group = UUID()
        return WorkoutTemplate(name: "Push", exercises: [
            TrainFixture.line(TrainFixture.bench, sets: 2),
            TemplateExercise(exercise: TrainFixture.row, sets: 3, repsMin: 8, repsMax: 10, loadKg: 60, restSeconds: 90, supersetGroup: group),
            TemplateExercise(exercise: TrainFixture.pushdown, sets: 3, repsMin: 10, repsMax: 12, loadKg: 25, restSeconds: 60, supersetGroup: group),
            TrainFixture.line(ExerciseRef(key: "lateral-raise", name: "Lateral raise"), sets: 1)
        ], recoveryRule: .init())
    }

    // MARK: Start and prefill

    @Test func startsAtTheFirstSetOfTheFirstExerciseWithTheTemplateValues() throws {
        let live = try model()
        #expect(live.cursor == .init(exerciseIndex: 0, setIndex: 0))
        #expect(live.eyebrow == "1 of 3 · set 1 of 4")
        #expect(live.spokenEyebrow == "Exercise 1 of 3, set 1 of 4")
        #expect(live.currentPrefill == SetPrefill(loadKg: 80, reps: 6, source: .template))
        #expect(live.session.status == .active && live.session.exercises.count == 3 && live.session.recoveryAtStart == 79)
        #expect(live.session.timeZoneIdentifier == TrainFixture.zone && live.session.localDay == TrainFixture.day)
        #expect(live.rest == nil && !live.isComplete && !live.isFinished)
        #expect(live.lastTimeSummary(forExerciseAt: 0) == nil)
    }

    @Test func prefillFollowsThePreviousSetThenLastSessionThenTheTemplate() throws {
        var live = try model(history: [history()])
        // No set yet: the set at the same index last time.
        #expect(live.currentPrefill == SetPrefill(loadKg: 80, reps: 7, source: .lastSession))
        #expect(live.lastTimeSummary(forExerciseAt: 0) == "Last time 80 kg × 7, 7, 6, 6")
        try live.logSet(loadKg: 80, reps: 8, now: at(60))
        // Then the set just logged.
        #expect(live.currentPrefill == SetPrefill(loadKg: 80, reps: 8, source: .thisSession))
        // A different exercise has no history and falls back to the template.
        #expect(live.prefill(for: .init(exerciseIndex: 1, setIndex: 0)) == SetPrefill(loadKg: 80, reps: 6, source: .template))
    }

    @Test func aProgressionEarnedLastTimeRaisesTheLoadAndRestartsReps() throws {
        let earned = try history(reps: [8, 8, 8, 8])
        let live = try model(history: [earned])
        #expect(live.currentPrefill == SetPrefill(loadKg: 82.5, reps: 6, source: .progression))
    }

    @Test func lastTimeSummaryHandlesMixedLoadsAndBodyweight() throws {
        let mixed = try history(loads: [80, 82.5, 82.5], reps: [8, 6, 6])
        #expect(try model(history: [mixed]).lastTimeSummary(forExerciseAt: 0) == "Last time 80 kg × 8, 82.5 kg × 6, 6")
        let bodyweight = try history(loads: [0, 0, 0], reps: [8, 7, 6], exercise: TrainFixture.row)
        #expect(try model(history: [bodyweight]).lastTimeSummary(forExerciseAt: 1) == "Last time 8, 7, 6 reps")
    }

    @Test func lastTopSetAndBestRepsFeedTheSetScreen() throws {
        let mixed = try history(loads: [80, 82.5, 82.5], reps: [8, 6, 5])
        var live = try model(history: [mixed])
        let top = live.lastTopSet(forExerciseAt: 0)
        #expect(top?.loadKg == 82.5 && top?.reps == 6)
        // The best at a weight counts heavier sets too: 82.5 × 6 beats 80 × anything under 6.
        #expect(live.bestReps(forExerciseAt: 0, atLeast: 80) == 8)
        #expect(live.bestReps(forExerciseAt: 0, atLeast: 82.5) == 6)
        #expect(live.bestReps(forExerciseAt: 0, atLeast: 90) == nil)
        // A set logged today counts at once.
        try live.logSet(loadKg: 90, reps: 3, now: at(60))
        #expect(live.bestReps(forExerciseAt: 0, atLeast: 90) == 3)
        #expect(live.lastTopSet(forExerciseAt: 1) == nil)
    }

    @Test func theBarbellShowsForBarbellLiftsOnly() throws {
        let live = try model()
        // Bench and row are barbell lifts in the library; the pushdown is a cable.
        #expect(live.usesBarbell(exerciseAt: 0))
        #expect(live.usesBarbell(exerciseAt: 1))
        #expect(!live.usesBarbell(exerciseAt: 2))
        #expect(!live.usesBarbell(exerciseAt: 9))
    }

    @Test func bodyweightExercisesStartWithNoLoadAndKeepAnAddedOne() throws {
        var template = TrainFixture.template()
        template.exercises[0].loadKind = .bodyweight
        template.exercises[0].loadKg = nil
        var live = try model(template)
        #expect(live.currentPrefill?.loadKg == nil)
        // On a bodyweight line the load is the weight on the belt: a weighted dip.
        let set = try live.logSet(loadKg: 20, reps: 8, now: at(30))
        #expect(set.loadKg == 20 && set.assistKg == nil)
    }

    // MARK: Logging

    @Test func loggingAdvancesTheCursorAndStoresWhereTheValuesCameFrom() throws {
        var live = try model(history: [history()])
        let first = try live.logSet(loadKg: 80, reps: 7, now: at(60))
        #expect(first.prefillSource == .lastSession && !first.edited && first.rpe == nil)
        let second = try live.logSet(loadKg: 82.5, reps: 7, rpe: 8.5, now: at(250))
        #expect(second.edited && second.rpe == 8.5 && second.loggedAt == at(250))
        #expect(live.cursor == .init(exerciseIndex: 0, setIndex: 2))
        #expect(live.eyebrow == "1 of 3 · set 3 of 4")
        #expect(live.session.exercises[0].sets.count == 2)
        #expect(live.tonnageKg == 80 * 7 + 82.5 * 7 && live.countedSetCount == 2)
    }

    @Test func finishingTheLastSetOfAnExerciseMovesToTheNextOne() throws {
        var live = try model()
        for index in 0..<4 { try live.logSet(loadKg: 80, reps: 6, now: at(Double(index) * 100)) }
        #expect(live.session.exercises[0].status == .done)
        #expect(live.cursor == .init(exerciseIndex: 1, setIndex: 0))
        #expect(live.eyebrow == "2 of 3 · set 1 of 4")
    }

    @Test func rejectsValuesTheStoreWouldRefuse() throws {
        var live = try model()
        #expect(throws: TrainLiveError.invalidValue) { try live.logSet(loadKg: 80, reps: 0, now: at(1)) }
        #expect(throws: TrainLiveError.invalidValue) { try live.logSet(loadKg: 80, reps: 101, now: at(1)) }
        #expect(throws: TrainLiveError.invalidValue) { try live.logSet(loadKg: -5, reps: 8, now: at(1)) }
        #expect(throws: TrainLiveError.invalidValue) { try live.logSet(loadKg: .nan, reps: 8, now: at(1)) }
        #expect(throws: TrainLiveError.invalidRPE) { try live.logSet(loadKg: 80, reps: 8, rpe: 5.5, now: at(1)) }
        #expect(throws: TrainLiveError.invalidRPE) { try live.logSet(loadKg: 80, reps: 8, rpe: 8.25, now: at(1)) }
        #expect(live.session.exercises[0].sets.isEmpty)
        // A zero load on a weighted lift is stored as no load, so it never counts toward bests.
        let set = try live.logSet(loadKg: 0, reps: 8, now: at(2))
        #expect(set.loadKg == nil)
    }

    @Test func rpeAcceptsHalfStepsFromSixToTenAndCanBeSetAfterwards() throws {
        var live = try model()
        try live.logSet(loadKg: 80, reps: 8, now: at(10))
        for value in stride(from: 6.0, through: 10.0, by: 0.5) {
            try live.setRPE(value, exerciseIndex: 0, setIndex: 0)
            #expect(live.session.exercises[0].sets[0].rpe == value)
        }
        try live.setRPE(nil, exerciseIndex: 0, setIndex: 0)
        #expect(live.session.exercises[0].sets[0].rpe == nil)
        #expect(throws: TrainLiveError.invalidRPE) { try live.setRPE(10.5, exerciseIndex: 0, setIndex: 0) }
        #expect(throws: TrainLiveError.noSuchSet) { try live.setRPE(8, exerciseIndex: 0, setIndex: 3) }
        #expect(throws: TrainLiveError.noSuchExercise) { try live.setRPE(8, exerciseIndex: 9, setIndex: 0) }
    }

    @Test func editingALoggedSetChangesItInPlaceAndMarksItEdited() throws {
        var live = try model()
        try live.logSet(loadKg: 80, reps: 8, now: at(10))
        try live.logSet(loadKg: 80, reps: 8, now: at(20))
        try live.editSet(exerciseIndex: 0, setIndex: 0, loadKg: 82.5, reps: 6, rpe: 9)
        let edited = live.session.exercises[0].sets[0]
        #expect(edited.loadKg == 82.5 && edited.reps == 6 && edited.rpe == 9 && edited.edited)
        #expect(live.session.exercises[0].sets.count == 2 && live.cursor == .init(exerciseIndex: 0, setIndex: 2))
        #expect(throws: TrainLiveError.noSuchSet) { try live.editSet(exerciseIndex: 0, setIndex: 2, loadKg: 80, reps: 8, rpe: nil) }
    }

    // MARK: Skip

    @Test func skippingASetKeepsItsPlaceAndCountsForNothing() throws {
        var live = try model()
        try live.logSet(loadKg: 80, reps: 8, now: at(10))
        try live.skipSet(now: at(20))
        #expect(live.session.exercises[0].sets.map(\.skipped) == [false, true])
        #expect(live.cursor == .init(exerciseIndex: 0, setIndex: 2))
        #expect(live.tonnageKg == 640 && live.countedSetCount == 1)
        let rows = live.tableRows(forExerciseAt: 0)
        #expect(rows.map(\.state) == [.logged, .skipped, .current, .planned])
        // Editing a skipped set turns it into a logged one.
        try live.editSet(exerciseIndex: 0, setIndex: 1, loadKg: 80, reps: 5, rpe: nil)
        #expect(live.session.exercises[0].sets[1].skipped == false && live.countedSetCount == 2)
    }

    @Test func skippingAnExerciseWithNoSetsMarksItSkippedAndMovesOn() throws {
        var live = try model()
        try live.skipExercise(at: 0)
        #expect(live.session.exercises[0].status == .skipped)
        #expect(live.cursor == .init(exerciseIndex: 1, setIndex: 0))
        #expect(live.eyebrow == "2 of 3 · set 1 of 4")
        try live.skipExercise(at: 0) // already closed: nothing changes
        #expect(live.session.exercises[0].status == .skipped)
        #expect(throws: TrainLiveError.noSuchExercise) { try live.skipExercise(at: 7) }
    }

    @Test func skippingAnExerciseAfterSomeSetsKeepsThemAndFinishesItEarly() throws {
        var live = try model()
        try live.logSet(loadKg: 80, reps: 8, now: at(10))
        try live.logSet(loadKg: 80, reps: 8, now: at(20))
        try live.skipExercise(at: 0)
        #expect(live.session.exercises[0].status == .done && live.session.exercises[0].sets.count == 2)
        #expect(live.cursor == .init(exerciseIndex: 1, setIndex: 0))
        #expect(live.tonnageKg == 1_280)
    }

    @Test func skippingEveryRemainingSetOfAnExerciseSkipsTheExercise() throws {
        var template = TrainFixture.template()
        template.exercises[0].sets = 2
        var live = try model(template)
        try live.skipSet(now: at(1))
        try live.skipSet(now: at(2))
        #expect(live.session.exercises[0].status == .skipped)
        #expect(live.cursor?.exerciseIndex == 1)
    }

    @Test func jumpingToAnotherExerciseWorksOutOfOrderAndComesBack() throws {
        var live = try model()
        try live.focus(exerciseAt: 2)
        #expect(live.cursor == .init(exerciseIndex: 2, setIndex: 0))
        try live.logSet(loadKg: 25, reps: 12, now: at(10))
        #expect(live.cursor == .init(exerciseIndex: 2, setIndex: 1))
        try live.skipExercise(at: 2)
        // The focused exercise is closed, so the cursor falls back to the first open one.
        #expect(live.cursor == .init(exerciseIndex: 0, setIndex: 0))
        #expect(throws: TrainLiveError.noSuchExercise) { try live.focus(exerciseAt: 5) }
    }

    // MARK: Swap

    @Test func swapOptionsShareMuscleAndCategoryAndRankSameEquipmentFirst() throws {
        let live = try model()
        let options = live.swapOptions(forExerciseAt: 0)
        // Squat works other muscles, the row and pushdown are already in the session or other muscles.
        #expect(options.map(\.key) == ["incline-barbell-press", "dumbbell-bench-press", "push-up"])
        #expect(live.swapOptions(forExerciseAt: 9).isEmpty)
        #expect(live.swapOptions(forExerciseAt: 0, limit: 1).count == 1)
    }

    @Test func swappingReplacesTheExerciseKeepsThePlanAndClearsTheLoad() throws {
        var live = try model()
        let choice = try #require(live.swapOptions(forExerciseAt: 0).first)
        try live.swapExercise(at: 0, with: choice)
        let line = live.session.exercises[0]
        #expect(line.exercise.key == "incline-barbell-press" && line.swappedFrom == TrainFixture.bench && line.status == .swapped)
        #expect(line.planned.sets == 4 && line.planned.repsMin == 6 && line.planned.loadKg == nil)
        #expect(live.currentPrefill == SetPrefill(loadKg: nil, reps: 6, source: .template))
        #expect(live.cursor == .init(exerciseIndex: 0, setIndex: 0))
        // Swapping again keeps the original lift as the one it came from.
        let next = try #require(live.swapOptions(forExerciseAt: 0).first { $0.key != "incline-barbell-press" })
        try live.swapExercise(at: 0, with: next)
        #expect(live.session.exercises[0].swappedFrom == TrainFixture.bench)
        // A bodyweight replacement carries no load.
        let pushUp = try #require(library().first { $0.key == "push-up" })
        try live.swapExercise(at: 0, with: pushUp)
        #expect(live.session.exercises[0].planned.loadKind == .bodyweight)
    }

    @Test func aSwappedExerciseCanBeLoggedAndStaysSwappedUntilItEnds() throws {
        var live = try model()
        try live.swapExercise(at: 0, with: #require(live.swapOptions(forExerciseAt: 0).first))
        for _ in 0..<4 { try live.logSet(loadKg: 70, reps: 8, now: at(30)) }
        let line = live.session.exercises[0]
        #expect(line.status == .done && line.swappedFrom == TrainFixture.bench && line.exercise.key == "incline-barbell-press")
    }

    @Test func aSwapAfterTheFirstSetMovesOnlyTheSetsLeft() throws {
        // Swap stays open mid-exercise (R2-LIFT-11): the sets done stay with the first lift, the rest move.
        var live = try model()
        try live.logSet(loadKg: 80, reps: 8, now: at(10))
        let planned = live.session.exercises[0].planned.sets
        #expect(live.canSwapExercise(at: 0) && live.setsMovedBySwap(at: 0) == planned - 1)
        let choice = try #require(live.swapOptions(forExerciseAt: 0).first)
        try live.swapExercise(at: 0, with: choice)
        #expect(live.session.exercises[0].sets.count == 1)
        #expect(live.session.exercises[1].exercise.key == choice.key && live.session.exercises[1].planned.sets == planned - 1)
        #expect(throws: TrainLiveError.noSuchExercise) { try live.swapExercise(at: 9, with: choice) }
    }

    // MARK: Supersets

    @Test func supersetMembersAlternateRoundByRound() throws {
        var live = try model(supersetTemplate())
        var order: [String] = []
        while let position = live.cursor {
            order.append("\(position.exerciseIndex).\(position.setIndex)")
            try live.logSet(loadKg: 50, reps: 8, now: at(Double(order.count)))
        }
        #expect(order == ["0.0", "0.1", "1.0", "2.0", "1.1", "2.1", "1.2", "2.2", "3.0"])
        #expect(live.isComplete && live.cursor == nil && live.eyebrow == "All sets logged")
    }

    @Test func supersetEyebrowNamesTheSuperset() throws {
        var live = try model(supersetTemplate())
        try live.logSet(loadKg: 80, reps: 8, now: at(1))
        try live.logSet(loadKg: 80, reps: 8, now: at(2))
        #expect(live.eyebrow == "2 of 4 · set 1 of 3 · superset")
        #expect(live.spokenEyebrow == "Exercise 2 of 4, set 1 of 3, superset")
    }

    @Test func supersetRestsOnceARoundAfterTheLastMemberUsingTheLongestRest() throws {
        var live = try model(supersetTemplate())
        try live.logSet(loadKg: 80, reps: 8, now: at(0))
        #expect(live.rest?.totalSeconds == 150)
        try live.logSet(loadKg: 80, reps: 8, now: at(200))
        // First member of the pair: straight to the partner, no rest.
        try live.logSet(loadKg: 60, reps: 8, now: at(210))
        #expect(live.rest == nil)
        try live.logSet(loadKg: 25, reps: 10, now: at(240))
        #expect(live.rest?.totalSeconds == 90 && live.rest?.endsAt == at(330))
    }

    @Test func supersetTableShowsTheCurrentExercisesSets() throws {
        var live = try model(supersetTemplate())
        try live.logSet(loadKg: 80, reps: 8, now: at(1))
        try live.logSet(loadKg: 80, reps: 8, now: at(2))
        #expect(live.cursor?.exerciseIndex == 1)
        #expect(live.tableRows(forExerciseAt: 1).map(\.state) == [.current, .planned, .planned])
        #expect(live.tableRows(forExerciseAt: 2).map(\.state) == [.planned, .planned, .planned])
    }

    // MARK: Recovery

    @Test func lowRecoveryRemovesASetPerLiftAndSaysSo() throws {
        let live = try model(score: 31)
        #expect(live.session.exercises.map(\.planned.sets) == [3, 3, 2])
        #expect(live.eyebrow == "1 of 3 · set 1 of 3")
        #expect(live.recoveryAdjustment?.message == "Recovery is 31. The lighter version drops one set per lift.")
        #expect(live.session.appliedAdjustments.map(\.kind) == [.setsRemoved] && live.session.appliedAdjustments.first?.setsRemoved == 3)
        #expect(live.session.appliedAdjustments.first?.recoveryScore == 31)
        #expect(live.session.recoveryAtStart == 31)
    }

    @Test func recoveryAtTheThresholdOrWithoutAReadingChangesNothing() throws {
        #expect(try model(score: 34).session.exercises.map(\.planned.sets) == [4, 4, 3])
        #expect(try model(score: nil).session.exercises.map(\.planned.sets) == [4, 4, 3])
        #expect(try model(score: nil).recoveryAdjustment?.message == "No recovery reading yet. Go as planned or lighten it yourself.")
        var off = TrainFixture.template()
        off.recoveryRule = nil
        #expect(try model(off, score: 10).session.exercises.map(\.planned.sets) == [4, 4, 3])
        #expect(try model(score: 79).session.appliedAdjustments.isEmpty)
    }

    @Test func aTemplateWithNoExercisesCannotStart() {
        #expect(throws: TrainLiveError.emptyTemplate) { try model(WorkoutTemplate(name: "Empty")) }
        #expect(throws: TrainLiveError.emptyTemplate) { try model(TrainFixture.cardio()) }
    }

    // MARK: Rest

    @Test func loggingStartsTheTemplateRestAndTheLastSetStartsNone() throws {
        var live = try model(restOverride: nil)
        try live.logSet(loadKg: 80, reps: 8, now: at(100))
        let rest = try #require(live.rest)
        #expect(rest.endsAt == at(250) && rest.totalSeconds == 150)
        var template = TrainFixture.template()
        template.exercises = [TrainFixture.line(TrainFixture.bench, sets: 1)]
        var single = try model(template)
        try single.logSet(loadKg: 80, reps: 8, now: at(1))
        #expect(single.rest == nil && single.isComplete)
    }

    @Test func aRestOverrideShortensEveryRest() throws {
        var live = try model(restOverride: 2)
        try live.logSet(loadKg: 80, reps: 8, now: at(0))
        #expect(live.rest?.totalSeconds == 2)
    }

    @Test func extendingAndClearingTheRestWorkThroughTheModel() throws {
        var live = try model()
        try live.logSet(loadKg: 80, reps: 8, now: at(0))
        live.extendRest(now: at(10))
        #expect(live.rest?.endsAt == at(180))
        live.clearRest()
        #expect(live.rest == nil)
        live.extendRest(now: at(20)) // nothing to extend
        #expect(live.rest == nil)
    }

    @Test func theRestCueIsClaimedOnceThroughTheModel() throws {
        var live = try model(restOverride: 5)
        try live.logSet(loadKg: 80, reps: 8, now: at(0))
        let early = live.claimRestCue(at: at(4))
        let due = live.claimRestCue(at: at(6))
        let again = live.claimRestCue(at: at(7))
        #expect(!early && due && !again)
    }

    // MARK: Finish and personal bests

    @Test func finishComputesBestsAgainstEarlierSessionsAndClosesTheSession() throws {
        var live = try model(history: [history()])
        for index in 0..<4 { try live.logSet(loadKg: 80, reps: 8, rpe: index == 0 ? 8 : nil, now: at(Double(index) * 200)) }
        try live.skipExercise(at: 1)
        let finished = try live.finish(now: at(2_400))
        #expect(finished.status == .completed && finished.endedAt == at(2_400) && live.isFinished)
        #expect(finished.exercises.map(\.status) == [.done, .skipped, .skipped])
        let bests = finished.bests
        #expect(bests.map(\.metric) == [.estimatedOneRepMax, .bestSetVolume])
        #expect(bests.allSatisfy { $0.isNewBest && $0.exerciseKey == TrainFixture.bench.key && $0.sessionID == finished.id })
        let e1rm = try #require(bests.first)
        #expect(abs(e1rm.value - 80 * (1 + 8.0 / 30)) < 1e-9 && e1rm.metric.isEstimated)
        #expect(abs((e1rm.previousValue ?? 0) - 80 * (1 + 7.0 / 30)) < 1e-9)
        #expect(bests[1].value == 640 && bests[1].previousValue == 560)
        #expect(finished.tonnageKg == 2_560)
        // The same finish again returns the same session.
        #expect(try live.finish(now: at(9_999)) == finished)
    }

    @Test func aFirstPerformanceIsABaselineAndSkippedSetsNeverCount() throws {
        var live = try model()
        try live.logSet(loadKg: 80, reps: 8, now: at(10))
        try live.skipSet(now: at(20))
        try live.skipExercise(at: 0)
        let finished = try live.finish(now: at(100))
        #expect(finished.bests.count == 3 && finished.bests.allSatisfy { $0.isBaseline && !$0.isNewBest })
        #expect(finished.countedSets.count == 1)
    }

    @Test func finishSkipsUntouchedExercisesAndKeepsPartialOnes() throws {
        var live = try model()
        try live.logSet(loadKg: 80, reps: 8, now: at(10))
        #expect(live.openSetCount == 3 + 4 + 3)
        let finished = try live.finish(now: at(100))
        #expect(finished.exercises.map(\.status) == [.done, .skipped, .skipped])
        try finished.validate()
    }

    @Test func aFinishedSessionTakesNoMoreChanges() throws {
        var live = try model()
        try live.logSet(loadKg: 80, reps: 8, now: at(10))
        try live.finish(now: at(100))
        #expect(throws: TrainLiveError.sessionFinished) { try live.logSet(loadKg: 80, reps: 8, now: at(110)) }
        #expect(throws: TrainLiveError.sessionFinished) { try live.skipSet(now: at(110)) }
        #expect(throws: TrainLiveError.sessionFinished) { try live.skipExercise(at: 1) }
        #expect(throws: TrainLiveError.sessionFinished) { try live.setRPE(8, exerciseIndex: 0, setIndex: 0) }
        #expect(throws: TrainLiveError.sessionFinished) { try live.editSet(exerciseIndex: 0, setIndex: 0, loadKg: 80, reps: 8, rpe: nil) }
        #expect(live.session.exercises[0].sets.count == 1)
    }

    @Test func finishBeforeTheStartClampsTheEndToTheStart() throws {
        var live = try model()
        let finished = try live.finish(now: at(-50))
        #expect(finished.endedAt == finished.startedAt)
    }

    @Test func aSwappedExerciseGetsItsOwnBaselineNotTheOldLiftsRecord() throws {
        var live = try model(history: [history()])
        let choice = try #require(live.swapOptions(forExerciseAt: 0).first)
        try live.swapExercise(at: 0, with: choice)
        for _ in 0..<4 { try live.logSet(loadKg: 60, reps: 10, now: at(30)) }
        let finished = try live.finish(now: at(1_000))
        #expect(finished.bests.allSatisfy { $0.exerciseKey == choice.key && $0.isBaseline })
        #expect(finished.exercises[0].status == .done && finished.exercises[0].swappedFrom == TrainFixture.bench)
    }

    @Test func aFinishedSessionRoundTripsThroughTheStore() throws {
        let database = try TrainTestDatabase()
        var live = try model(history: [history()])
        for _ in 0..<4 { try live.logSet(loadKg: 80, reps: 8, now: at(30)) }
        let finished = try live.finish(now: at(900))
        let saved = try database.store.saveSession(finished)
        #expect(saved.revision == 1)
        #expect(try database.store.session(id: finished.id)?.bests == finished.bests)
        live.recordSaved(revision: saved.revision)
        #expect(live.session.revision == 1)
    }

    @Test func aSavedActiveSessionResumesWithTheSameCursor() throws {
        var live = try model(history: [history()])
        try live.logSet(loadKg: 80, reps: 8, now: at(10))
        try live.logSet(loadKg: 80, reps: 8, now: at(20))
        let resumed = try TrainLiveModel(resuming: live.session, template: TrainFixture.template(), history: [history()])
        #expect(resumed.cursor == live.cursor && resumed.rest == nil)
        #expect(resumed.progression == .doubleProgression(incrementKg: 2.5) && resumed.bandRestCue)
        var completed = live.session
        completed.status = .abandoned
        #expect(throws: TrainLiveError.noOpenSet) { try TrainLiveModel(resuming: completed, template: nil, history: []) }
    }

    // MARK: Formatting

    @Test func formattingMatchesTheScreens() {
        #expect(TrainLiveFormat.kilograms(80) == "80" && TrainLiveFormat.kilograms(82.5) == "82.5" && TrainLiveFormat.kilograms(2_560) == "2,560")
        #expect(TrainLiveFormat.rpe(8) == "8" && TrainLiveFormat.rpe(8.5) == "8.5")
        #expect(TrainLiveFormat.clock(seconds: 1_450) == "24:10" && TrainLiveFormat.clock(seconds: 3_725) == "1:02:05")
        #expect(TrainLiveFormat.clock(seconds: -3) == "0:00" && TrainLiveFormat.clock(seconds: .nan) == "0:00")
        #expect(TrainLiveFormat.minutes(seconds: 3_720) == "62 min")
    }
}
