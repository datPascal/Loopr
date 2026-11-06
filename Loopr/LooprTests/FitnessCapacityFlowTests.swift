import AnalyticsKit
import Foundation
import ProfileKit
import Testing
import TrainKit
import WorkoutKit
@testable import Loopr

/// Where the capacity tests save in fixture launches, and heart rate recovery read from workouts.
struct FitnessCapacityFlowTests {
    private static let perth = "Australia/Perth"

    @Test func savedResultsAndGoalsShowOnTheNextRead() async throws {
        let recorder = FitnessFixtureCapacityRecorder(FitnessCapacityRecords())
        let hang = try CapacityResult(kind: .deadHang, value: 95, recordedAt: AppTrainFixtures.now,
                                      timeZoneIdentifier: Self.perth, source: .timed)
        try await recorder.save([hang])
        try await recorder.save(try CapacityGoal(kind: .deadHang, targetValue: 60, setAt: AppTrainFixtures.now))
        let sources = FitnessSources(profile: { FitnessProfile(birthYear: 1985, biologicalSex: .male) }, recorder: recorder)
        let input = await FitnessInputMapping.input(sources: sources, now: AppTrainFixtures.now,
                                                    calendar: AppTrainFixtures.calendar, train: [], workouts: [])
        let tile = try #require(FitnessOverview.make(input)?.tile(.deadHang))
        #expect(tile.valueText == "1:35")
        #expect(tile.goalValue == 60 && tile.trajectory != nil)
    }

    @Test func savingTheSameResultTwiceKeepsOneRow() async throws {
        let recorder = FitnessFixtureCapacityRecorder(FitnessCapacityRecords())
        let result = try CapacityResult(kind: .sitToStand, value: 9.5, recordedAt: AppTrainFixtures.now, timeZoneIdentifier: Self.perth)
        try await recorder.save([result])
        try await recorder.save([result])
        #expect(await recorder.records().results.count == 1)
    }

    @Test func theFixtureSavesInMemoryAndTimesOnARunningClock() async {
        let first = FitnessFixtures.clock()
        #expect(first >= AppTrainFixtures.now)
        #expect(FitnessFixtures.clock() >= first)
        let records = await FitnessFixtures.recorder.records()
        #expect(records.results.contains { $0.kind == .heartRateRecovery && $0.value == 28 })
        #expect(FitnessFixtures.sources.recorder != nil)
    }

    @Test func heartRateRecoveryIsReadFromScoredCompletedWorkouts() throws {
        let start = AppTrainFixtures.lowerAStart
        let minute = HRRecovery(peakBPM: 160, heartRateAtRecovery: 128, dropBPM: 32, dropPercent: 20,
                                algorithmVersion: "loopr.workout-hrr.1")
        var scored = WorkoutRecord(id: UUID(), identity: WorkoutIdentity(canonicalKey: "scored"), activity: .run, source: .manual,
                                   state: .completed, createdAt: start, startedAt: start, endedAt: start.addingTimeInterval(1_800))
        scored.heartRateRecovery = TimedHeartRateRecovery(firstMinute: minute, secondMinute: nil, reason: nil, maximumHR: 190)
        let unscored = WorkoutRecord(id: UUID(), identity: WorkoutIdentity(canonicalKey: "plain"), activity: .run, source: .manual,
                                     state: .completed, createdAt: start, startedAt: start, endedAt: start.addingTimeInterval(900))
        var running = scored
        running.state = .active
        let results = FitnessInputMapping.heartRateRecoveries([scored, unscored, running], timeZoneIdentifier: Self.perth)
        #expect(results.count == 1)
        #expect(results.first?.value == 32 && results.first?.id == scored.id && results.first?.workoutID == scored.id)
        #expect(results.first?.source == .workout && results.first?.algorithmVersion == "loopr.workout-hrr.1")
    }

    @Test func aWorkoutsOwnRecoveryReplacesAStoredCopy() async throws {
        let start = AppTrainFixtures.lowerAStart
        let id = UUID()
        let stored = try CapacityResult(id: id, kind: .heartRateRecovery, value: 20, recordedAt: start, timeZoneIdentifier: Self.perth,
                                        source: .workout, workoutID: id, algorithmVersion: "loopr.workout-hrr.1")
        var workout = WorkoutRecord(id: id, identity: WorkoutIdentity(canonicalKey: "w"), activity: .run, source: .manual,
                                    state: .completed, createdAt: start, startedAt: start, endedAt: start.addingTimeInterval(600))
        workout.heartRateRecovery = TimedHeartRateRecovery(
            firstMinute: HRRecovery(peakBPM: 150, heartRateAtRecovery: 120, dropBPM: 30, dropPercent: 20, algorithmVersion: "loopr.workout-hrr.1"),
            secondMinute: nil, reason: nil, maximumHR: 190)
        let sources = FitnessSources(recorder: FitnessFixtureCapacityRecorder(FitnessCapacityRecords(results: [stored])))
        let input = await FitnessInputMapping.input(sources: sources, now: AppTrainFixtures.now, calendar: AppTrainFixtures.calendar,
                                                    train: [], workouts: [workout])
        #expect(input.capacityResults.filter { $0.kind == .heartRateRecovery }.map(\.value) == [30])
    }
}
