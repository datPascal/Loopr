import Foundation
import Testing
@testable import TrainKit

/// The capacity test flows on an injected clock: the timers, grip's best of three per hand, the
/// sit to stand half points, the goals for 85 and what a save hands back to the tile.
struct CapacityTestFlowTests {
    typealias F = FitnessFixture
    static let zone = "Australia/Perth"
    let t0 = F.date(2023, 11, 14, 10, zone: "Australia/Perth")

    func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

    // MARK: Timer

    @Test func startCountsDownThreeTwoOneThenRuns() {
        var timer = CapacityTimer()
        #expect(timer.phase == .ready)
        timer.start(at: t0)
        #expect(timer.phase == .leadIn(startsAt: at(3)))
        #expect(timer.countdown(at: t0) == 3)
        #expect(timer.countdown(at: at(1.2)) == 2)
        #expect(timer.countdown(at: at(2.9)) == 1)
        #expect(timer.elapsed(at: at(2.9)) == 0)
        #expect(timer.resolved(at: at(3)) == .running(startedAt: at(3)))
        #expect(timer.countdown(at: at(3)) == nil)
        #expect(timer.elapsed(at: at(13)) == 10)
    }

    @Test func stopEndsTheRunWithItsTime() throws {
        var timer = CapacityTimer()
        timer.start(at: t0)
        timer.stop(at: at(3 + 84.24))
        #expect(timer.isStopped)
        #expect(abs((timer.result ?? 0) - 84.24) < 0.0001)
        let result = try #require(try timer.capacityResult(kind: .deadHang, side: .left, at: at(90), timeZoneIdentifier: Self.zone))
        #expect(result.value == 84.2)
        #expect(result.source == .timed && result.side == nil && result.kind == .deadHang)
        // A stopped timer ignores another stop.
        timer.stop(at: at(200))
        #expect(abs((timer.result ?? 0) - 84.24) < 0.0001)
    }

    @Test func aStopInsideTheFirstSecondIsAMisTap() {
        var timer = CapacityTimer()
        timer.start(at: t0)
        timer.stop(at: at(3.6))
        #expect(timer.phase == .ready)
        #expect(timer.rejectedMisTap)
        #expect(timer.result == nil)
        timer.start(at: at(10))
        #expect(!timer.rejectedMisTap)
        timer.stop(at: at(14))
        #expect(timer.result == 1)
    }

    @Test func stoppingDuringTheCountdownCancelsWithoutAMisTap() {
        var timer = CapacityTimer()
        timer.start(at: t0)
        timer.stop(at: at(1))
        #expect(timer.phase == .ready && !timer.rejectedMisTap)
    }

    @Test func theBackgroundNeitherPausesNorLosesARun() {
        var timer = CapacityTimer()
        timer.start(at: t0)
        timer.enterBackground(at: at(10))
        #expect(timer.wasBackgrounded)
        timer.enterForeground(at: at(70))
        #expect(timer.phase == .running(startedAt: at(3)))
        #expect(timer.elapsed(at: at(70)) == 67)
        timer.stop(at: at(70))
        #expect(timer.result == 67)
        #expect(timer.wasBackgrounded)
    }

    @Test func goingToTheBackgroundDuringTheCountdownStartsTheRunOnTime() {
        var timer = CapacityTimer()
        timer.start(at: t0)
        timer.enterBackground(at: at(1))
        timer.enterForeground(at: at(5))
        #expect(timer.phase == .running(startedAt: at(3)))
        #expect(timer.elapsed(at: at(5)) == 2)
    }

    @Test func theBackgroundBeforeAStartChangesNothing() {
        var timer = CapacityTimer()
        timer.enterBackground(at: t0)
        timer.enterForeground(at: at(30))
        #expect(timer.phase == .ready && !timer.wasBackgrounded)
    }

    @Test func balanceTicksEveryTenSecondsAndNeedsASide() throws {
        var timer = CapacityTimer()
        timer.start(at: t0)
        #expect(timer.ticks(at: at(2)) == 0)
        #expect(timer.ticks(at: at(3 + 9.9)) == 0)
        #expect(timer.ticks(at: at(3 + 10)) == 1)
        #expect(timer.ticks(at: at(3 + 25)) == 2)
        timer.stop(at: at(3 + 18))
        let result = try #require(try timer.capacityResult(kind: .oneLegBalance, side: .right, at: at(30), timeZoneIdentifier: Self.zone))
        #expect(result.side == .right && result.value == 18)
        #expect(throws: CapacityError.sideRequired(.oneLegBalance)) {
            try timer.capacityResult(kind: .oneLegBalance, side: nil, at: at(30), timeZoneIdentifier: Self.zone)
        }
    }

    @Test func resetDropsAStoppedRunAndNoLeadInStartsAtOnce() {
        var timer = CapacityTimer()
        timer.start(at: t0)
        timer.stop(at: at(10))
        timer.reset()
        #expect(timer.phase == .ready && timer.result == nil)
        var quick = CapacityTimer(leadIn: 0)
        quick.start(at: t0)
        #expect(quick.phase == .running(startedAt: t0))
    }

    @Test func aStoppedTimerCanStartAgain() {
        var timer = CapacityTimer()
        timer.start(at: t0)
        timer.stop(at: at(10))
        timer.start(at: at(20))
        #expect(timer.phase == .leadIn(startsAt: at(23)))
    }

    // MARK: Grip

    @Test func gripKeepsTheBestOfUpToThreeTrialsPerHand() throws {
        var grip = GripTrials()
        #expect(!grip.hasTrials)
        let added = [grip.add(50, side: .right), grip.add(52.3, side: .right), grip.add(51, side: .right),
                     grip.add(60, side: .right)]
        #expect(added == [true, true, true, false])
        #expect(!grip.canAdd(.right) && grip.canAdd(.left))
        #expect(grip.trials(.right) == [50, 52.5, 51])
        #expect(grip.best(.right) == 52.5)
        grip.add(48, side: .left)
        grip.add(49.5, side: .left)
        #expect(grip.best(.left) == 49.5)
        #expect(grip.best == 52.5)
        let results = try grip.results(at: t0, timeZoneIdentifier: Self.zone)
        #expect(results.map(\.side) == [.left, .right])
        #expect(results.map(\.value) == [49.5, 52.5])
        #expect(results.allSatisfy { $0.source == .typed && $0.kind == .grip })
    }

    @Test func removingATrialFreesItsPlace() {
        var grip = GripTrials(trials: [.right: [50, 52, 51, 70]])
        #expect(grip.trials(.right) == [50, 52, 51])
        grip.remove(at: 1, side: .right)
        #expect(grip.trials(.right) == [50, 51])
        #expect(grip.canAdd(.right))
        grip.remove(at: 9, side: .right)
        #expect(grip.trials(.right).count == 2)
    }

    @Test func gripReadingsSnapToHalfKilograms() {
        #expect(GripTrials.snapped(52.3) == 52.5)
        #expect(GripTrials.snapped(52.2) == 52)
        #expect(GripTrials.snapped(0) == 1)
        #expect(GripTrials.snapped(400) == 150)
        #expect(GripTrials.snapped(.nan) == 1)
    }

    // MARK: Sit to stand

    @Test func sitToStandScoresHalfPointsOutOfTen() throws {
        var score = SitToStandScore()
        // Nothing is scored yet: an untested score is not a 10, and there is nothing to save.
        #expect(score.total == nil && !score.isComplete && score.sitting == nil && score.rising == nil)
        #expect(throws: CapacityError.missingResult) { try score.result(at: t0, timeZoneIdentifier: Self.zone) }
        score.setSitting(4.3)
        #expect(score.sitting == 4.5)
        #expect(score.total == nil, "One half is not a score")
        #expect(throws: CapacityError.missingResult) { try score.result(at: t0, timeZoneIdentifier: Self.zone) }
        score.setRising(6)
        #expect(score.rising == 5)
        #expect(score.total == 9.5)
        score.setRising(-1)
        #expect(score.total == 4.5)
        let result = try score.result(at: t0, timeZoneIdentifier: Self.zone)
        #expect(result.value == 4.5 && result.source == .typed && result.side == nil)
        #expect(SitToStandScore.rules.count == 4)
        #expect(SitToStandScore(sitting: 5, rising: 5).total == 10)
    }

    // MARK: Goals at 85

    @Test func theGoalRulerStartsAtTheGoalThenTheBestThenADefault() throws {
        let grip = try #require(CapacityGoalScale.scale(for: .grip))
        #expect(grip.initialValue(goal: 31.2, best: 52) == 31)
        #expect(grip.initialValue(goal: nil, best: 52.3) == 52.5)
        #expect(grip.initialValue(goal: nil, best: nil) == 30)
        #expect(grip.snapped(400) == 100)
        let goal = try grip.goal(kind: .grip, value: 41.3, at: t0)
        #expect(goal.targetValue == 41.5 && goal.kind == .grip && goal.setAt == t0)
        let hang = try #require(CapacityGoalScale.scale(for: .deadHang))
        #expect(hang.snapped(62) == 60)
        let sit = try #require(CapacityGoalScale.scale(for: .sitToStand))
        #expect(sit.snapped(0) == 0.5)
        #expect(CapacityGoalScale.scale(for: .heartRateRecovery) == nil)
    }

    // MARK: Saving

    @Test func aSaveReportsTheNewBestAndWhetherItMeetsTheGoal() throws {
        var grip = GripTrials()
        grip.add(52, side: .right)
        grip.add(47, side: .left)
        let results = try grip.results(at: t0, timeZoneIdentifier: Self.zone)
        let meets = try CapacityFlowOutcome(kind: .grip, previousBest: 50, results: results, goal: 30)
        #expect(meets.newBest == 52 && meets.previousBest == 50 && meets.meetsGoal)
        let under = try CapacityFlowOutcome(kind: .grip, previousBest: 50, results: results, goal: 60)
        #expect(!under.meetsGoal)
        let noGoal = try CapacityFlowOutcome(kind: .grip, previousBest: nil, results: results, goal: nil)
        #expect(!noGoal.meetsGoal)
        #expect((8...20).contains(meets.dotCount))
        #expect(throws: CapacityError.missingResult) {
            try CapacityFlowOutcome(kind: .deadHang, previousBest: nil, results: results, goal: nil)
        }
    }

    @Test func aBiggerResultFliesMoreDotsWithinTheBounds() throws {
        func outcome(_ seconds: Double) throws -> CapacityFlowOutcome {
            let result = try CapacityResult(kind: .deadHang, value: seconds, recordedAt: t0, timeZoneIdentifier: Self.zone, source: .timed)
            return try CapacityFlowOutcome(kind: .deadHang, previousBest: nil, results: [result], goal: nil)
        }
        #expect(try outcome(2).dotCount == 8)
        #expect(try outcome(120).dotCount == 20)
        #expect(try outcome(60).dotCount == 10)
    }

    // MARK: The overview's tiles

    @Test func heartRateRecoveryIsItsOwnReadOnlyTileWithItsDate() throws {
        let workout = UUID()
        let recovery = try CapacityResult(id: workout, kind: .heartRateRecovery, value: 28,
                                          recordedAt: F.date(2023, 11, 13, 18, zone: Self.zone), timeZoneIdentifier: Self.zone,
                                          source: .workout, workoutID: workout, algorithmVersion: "loopr.workout-hrr.1")
        let input = FitnessOverviewInput(now: t0, calendar: F.calendar(Self.zone), birthYear: 1985, capacityResults: [recovery])
        let overview = try #require(FitnessOverview.make(input))
        let tile = overview.heartRateRecovery
        #expect(tile.valueText == "28" && tile.unitText == "bpm")
        #expect(tile.sourceLine == "From a workout on 13 Nov")
        #expect(tile.retestLine == nil)
        #expect(tile.spokenLabel == "Heart rate recovery, 28 beats a minute, From a workout on 13 Nov")
        #expect(overview.tile(.heartRateRecovery) == tile)
        #expect(overview.tile(.grip)?.kind == .grip)
        #expect(!overview.capacity.contains { $0.kind == .heartRateRecovery })
    }

    @Test func aTileCarriesItsBestItsGoalAndTheLineTo85() throws {
        let result = try CapacityResult(kind: .grip, value: 52, side: .right, recordedAt: at(-86_400), timeZoneIdentifier: Self.zone)
        let goal = try CapacityGoal(kind: .grip, targetValue: 30, setAt: t0)
        let input = FitnessOverviewInput(now: t0, calendar: F.calendar(Self.zone), birthYear: 1985, capacityResults: [result],
                                         capacityGoals: [.grip: goal])
        let tile = try #require(FitnessOverview.make(input)?.tile(.grip))
        #expect(tile.bestValue == 52 && tile.goalValue == 30 && tile.knowsBirthYear)
        let line = try #require(tile.trajectory)
        #expect(line.start.value == 52 && line.end.value == 30 && line.goalAlreadyMet)
        let unknown = FitnessOverviewInput(now: t0, calendar: F.calendar(Self.zone), capacityResults: [result],
                                           capacityGoals: [.grip: goal])
        let noBirthYear = try #require(FitnessOverview.make(unknown)?.tile(.grip))
        #expect(noBirthYear.trajectory == nil && !noBirthYear.knowsBirthYear)
    }
}
