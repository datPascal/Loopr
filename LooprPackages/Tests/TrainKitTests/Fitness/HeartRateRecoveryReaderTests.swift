import AnalyticsKit
import Foundation
import Testing
import TrainKit

struct HeartRateRecoveryReaderTests {
    typealias F = FitnessFixture
    let end = 1_700_003_600.0

    /// 165 bpm through the last five minutes, then a fall of 0.5 bpm per second for two minutes.
    func tail(peak: Double = 165) -> [WorkoutHRPoint] {
        stride(from: -300, through: 123, by: 1).map { offset in
            WorkoutHRPoint(timestamp: end + Double(offset), bpm: offset <= 0 ? peak : peak - Double(offset) * 0.5)
        }
    }

    func workout(samples: [WorkoutHRPoint], maximumHR: Double? = 190, id: UUID = UUID()) -> WorkoutRecoveryInput {
        WorkoutRecoveryInput(workoutID: id, startedAt: Date(timeIntervalSince1970: end - 600), endedAt: Date(timeIntervalSince1970: end),
                             samples: samples, maximumHR: maximumHR, timeZoneIdentifier: "Europe/Berlin")
    }

    @Test func theDropIsTheExistingCalculationsOneMinuteDrop() throws {
        let id = UUID()
        let input = workout(samples: tail().reversed(), id: id)
        let reading = try #require(HeartRateRecoveryReader.result(from: input))
        let existing = WorkoutAnalytics.timedHeartRateRecovery(samples: input.samples, start: end - 600, end: end, maximumHR: 190)
        #expect(reading.value == existing.firstMinute?.dropBPM)
        #expect(abs(reading.value - 30) < 1e-9)
        #expect(reading.kind == .heartRateRecovery && reading.unit == "bpm" && reading.source == .workout)
        #expect(reading.id == id && reading.workoutID == id)
        #expect(reading.algorithmVersion == "loopr.workout-hrr.1" && reading.algorithmVersion == TimedHeartRateRecovery.algorithmVersion)
        #expect(reading.recordedAt == input.endedAt && reading.timeZoneIdentifier == "Europe/Berlin")
    }

    @Test func readingTheSameWorkoutTwiceGivesTheSameResult() throws {
        let input = workout(samples: tail())
        #expect(HeartRateRecoveryReader.result(from: input) == HeartRateRecoveryReader.result(from: input))
    }

    @Test func aWorkoutTheCalculationCannotScoreGivesNoResult() {
        #expect(HeartRateRecoveryReader.result(from: workout(samples: tail(), maximumHR: nil)) == nil)
        #expect(HeartRateRecoveryReader.result(from: workout(samples: [])) == nil)
        let gappy = tail().filter { $0.timestamp <= end || $0.timestamp >= end + 40 }
        #expect(HeartRateRecoveryReader.result(from: workout(samples: gappy)) == nil)
        let easy = tail().map { WorkoutHRPoint(timestamp: $0.timestamp, bpm: 90) }
        #expect(HeartRateRecoveryReader.result(from: workout(samples: easy)) == nil)
    }

    @Test func aRiseAfterTheWorkoutIsNotStoredAsARecovery() {
        let rising = stride(from: -300, through: 123, by: 1).map { offset in
            WorkoutHRPoint(timestamp: end + Double(offset), bpm: offset <= 0 ? 165 : 165 + Double(min(offset, 5)))
        }
        #expect(HeartRateRecoveryReader.result(from: workout(samples: rising)) == nil)
    }

    @Test func manyWorkoutsKeepOnlyTheOnesThatScore() {
        let good = workout(samples: tail())
        let bad = workout(samples: tail(), maximumHR: nil)
        #expect(HeartRateRecoveryReader.results(from: [good, bad]).map(\.workoutID) == [good.workoutID])
    }
}
