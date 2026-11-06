import Foundation
import Testing
import TrainKit

struct TrainSummaryModelTests {
    private let start = TrainFixture.date
    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    private func session(sets: [LoggedSet], exercise: ExerciseRef = TrainFixture.bench, endsAfter: TimeInterval = 3_720,
                         swappedFrom: ExerciseRef? = nil, status: SessionExerciseStatus = .done, more: [SessionExercise] = [],
                         bests: [PersonalBest] = []) throws -> TrainSession {
        let line = SessionExercise(planned: TrainFixture.line(exercise), exercise: exercise, status: status, swappedFrom: swappedFrom, sets: sets)
        return try TrainSession(name: "Upper A", startedAt: start, timeZoneIdentifier: TrainFixture.zone, endedAt: at(endsAfter),
                                status: .completed, exercises: [line] + more, bests: bests)
    }

    @Test func totalsMatchTheSession() throws {
        let sets = (0..<4).map { LoggedSet(loadKg: 80, reps: 8, loggedAt: at(Double($0) * 100)) }
            + [LoggedSet(loadKg: nil, reps: 0, loggedAt: at(500), skipped: true)]
        let skippedLine = SessionExercise(planned: TrainFixture.line(TrainFixture.row), status: .skipped)
        let summary = TrainSummaryModel(session: try session(sets: sets, more: [skippedLine]))
        #expect(summary.name == "Upper A" && summary.durationSeconds == 3_720)
        #expect(summary.tonnageKg == 2_560 && summary.volumeText == "2,560")
        #expect(summary.setCount == 4 && summary.exerciseCount == 2)
        #expect(summary.exercisesDone == 1 && summary.exercisesSkipped == 1 && summary.exercisesSwapped == 0)
        #expect(summary.exercisesText == "1 done, 1 skipped")
        #expect(summary.bests.isEmpty && summary.newBestCount == 0)
    }

    @Test func swappedExercisesAreCounted() throws {
        let summary = TrainSummaryModel(session: try session(sets: [LoggedSet(loadKg: 70, reps: 8, loggedAt: at(10))],
                                                              swappedFrom: TrainFixture.row))
        #expect(summary.exercisesSwapped == 1 && summary.exercisesText == "1 done, 1 swapped")
    }

    @Test func bestsListNewBestsFirstAndLabelEstimates() throws {
        // 80 kg for 8 beats a history of 80 kg for 7. Heaviest load ties, so it is not a best.
        var live = try TrainLiveModel(setup: TrainLiveSetup(
            template: TrainFixture.template(),
            history: [try historySession()], timeZoneIdentifier: TrainFixture.zone), now: start)
        for index in 0..<4 { try live.logSet(loadKg: 80, reps: 8, now: at(Double(index) * 100)) }
        try live.skipExercise(at: 1)
        // A first-time exercise logged next gives baselines, which list after the real bests.
        try live.logSet(loadKg: 25, reps: 12, now: at(900))
        try live.skipExercise(at: 2)
        let finished = try live.finish(now: at(1_500))
        let summary = TrainSummaryModel(session: finished)
        #expect(summary.bests.map { $0.index } == Array(0..<summary.bests.count))
        #expect(summary.bests.prefix(2).allSatisfy { $0.isNewBest })
        let first = try #require(summary.bests.first)
        #expect(first.identifier == "train-summary-pb-0" && first.metricTitle == "Estimated 1RM" && first.isEstimated)
        #expect(first.valueText == "101 kg" && first.previousText == "Was 99 kg")
        #expect(first.spokenLabel.contains("estimated") && first.spokenLabel.contains("new best"))
        let volume = try #require(summary.bests.first { $0.metricTitle == "Best set" && $0.isNewBest })
        #expect(volume.valueText == "640 kg" && volume.setText == "80 kg × 8" && volume.previousText == "Was 560 kg" && !volume.isEstimated)
        let baselines = summary.bests.filter { !$0.isNewBest }
        #expect(baselines.count == 3 && baselines.allSatisfy { $0.exerciseName == TrainFixture.row.name || $0.exerciseName == TrainFixture.pushdown.name })
        #expect(baselines.allSatisfy { $0.previousText == nil && $0.spokenLabel.contains("first time") })
        #expect(summary.bests.suffix(3).allSatisfy { !$0.isNewBest })
        #expect(summary.newBestCount == 2)
    }

    private func historySession() throws -> TrainSession {
        let began = start.addingTimeInterval(-7 * 86_400)
        let sets = [7, 7, 6, 6].enumerated().map { index, reps in
            LoggedSet(loadKg: 80, reps: reps, loggedAt: began.addingTimeInterval(Double(index) * 200))
        }
        let line = SessionExercise(planned: TrainFixture.line(TrainFixture.bench), status: .done, sets: sets)
        return try TrainSession(name: "Upper A", startedAt: began, timeZoneIdentifier: TrainFixture.zone,
                                endedAt: began.addingTimeInterval(3_000), status: .completed, exercises: [line])
    }
}

struct ProgramAdjustmentPlannerTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Australia/Perth") ?? .gmt
        return calendar
    }()
    private let upper = UUID()
    /// Tuesday 2023-11-14, 10:00 in Perth. Week 3 of a program that started on Monday 30 October.
    private let now = Date(timeIntervalSince1970: 1_699_927_200)

    private func program(rules: ProgramRules = .init(), adjustments: [ProgramAdjustment] = [], status: ProgramStatus = .active) -> Program {
        let slots = [ProgramSlot(weekday: .monday, templateID: upper, tag: "LA"), ProgramSlot(weekday: .tuesday, templateID: upper, tag: "UA")]
        return Program(name: "Strength block", status: status, startDay: "2023-10-30", weeks: Array(repeating: slots, count: 8),
                       rules: rules, adjustments: adjustments)
    }

    private func readings(score: Double) -> [RecoveryReading] {
        (1...9).map { RecoveryReading(localDay: String(format: "2023-11-%02d", 5 + $0), score: score) }
    }

    private func input(_ programs: [Program], recovery: [RecoveryReading], sessions: [TrainSession] = []) -> TrainOverviewInput {
        TrainOverviewInput(now: now, calendar: calendar,
                           templates: [WorkoutTemplate(id: upper, name: "Upper A")], programs: programs, sessions: sessions, recovery: recovery)
    }

    @Test func aLowRecoveryAverageRecordsTheLightWeekDecision() throws {
        let pending = ProgramAdjustmentPlanner.pending(input: input([program()], recovery: readings(score: 46)))
        let entry = try #require(pending.first)
        let adjustment = try #require(entry.adjustments.first { $0.kind == .earlyLightWeek })
        #expect(pending.count == 1 && adjustment.week == 3 && adjustment.recoveryScore == 46)
        #expect(adjustment.reason == "Week 3 is lighter. Recovery averaged 46 over the last 7 days.")
    }

    @Test func aHighAverageRecordsADeclinedDecisionSoTheWeekIsNotDecidedTwice() throws {
        let pending = ProgramAdjustmentPlanner.pending(input: input([program()], recovery: readings(score: 70)))
        #expect(pending.first?.adjustments.map(\.kind).contains(.earlyLightDeclined) == true)
    }

    @Test func missedSessionsAreRecordedAsMoves() throws {
        // The Monday session was missed, so it moves to the next free day.
        var rules = ProgramRules(); rules.earlyLightWeek = false
        let pending = ProgramAdjustmentPlanner.pending(input: input([program(rules: rules)], recovery: []))
        let move = try #require(pending.first?.adjustments.first { $0.kind == .movedSession })
        #expect(move.week == 3 && move.weekday == .monday && move.movedToWeekday == .wednesday)
    }

    @Test func nothingIsPendingOnceTheProgramHoldsTheDecisions() throws {
        let first = ProgramAdjustmentPlanner.pending(input: input([program()], recovery: readings(score: 70)))
        let decisions = try #require(first.first).adjustments
        let held = try #require(ProgramAdjustmentPlanner.merge(decisions, into: program()))
        let again = ProgramAdjustmentPlanner.pending(input: input([held], recovery: readings(score: 70)))
        #expect(again.isEmpty)
        #expect(ProgramAdjustmentPlanner.merge(decisions, into: held) == nil)
    }

    @Test func pausedAndDraftProgramsAreLeftAlone() {
        #expect(ProgramAdjustmentPlanner.pending(input: input([program(status: .paused), program(status: .draft)], recovery: readings(score: 46))).isEmpty)
    }

    @Test func mergeAddsOnlyDecisionsTheProgramLacks() throws {
        let existing = ProgramAdjustment(kind: .earlyLightDeclined, week: 3, reason: "Week 3 stays as planned.", createdAt: now)
        let duplicate = ProgramAdjustment(kind: .earlyLightDeclined, week: 3, reason: "Same decision again.", createdAt: now)
        let other = ProgramAdjustment(kind: .earlyLightDeclined, week: 4, reason: "Week 4 stays as planned.", createdAt: now)
        let merged = try #require(ProgramAdjustmentPlanner.merge([duplicate, other], into: program(adjustments: [existing])))
        #expect(merged.adjustments.map(\.week) == [3, 4])
        try merged.validate()
    }
}
