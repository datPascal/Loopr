import XCTest
import DomainKit
@testable import AnalyticsKit

final class SIBodyAnalyticsTests: XCTestCase {
    private func tail(step: Int = 1) -> [WorkoutHRPoint] {
        stride(from: -300, through: 123, by: step).map { offset in
            WorkoutHRPoint(timestamp: 600 + Double(offset), bpm: offset <= 0 ? 165 : 165 - Double(offset) * 0.5)
        }
    }
    func testClockResolvedRecoveryAtBothWindowsAndSparseCadence() throws {
        for step in [1, 3, 15] {
            let result = WorkoutAnalytics.timedHeartRateRecovery(samples: tail(step: step).reversed(), start: 0, end: 600, maximumHR: 190)
            XCTAssertEqual(try XCTUnwrap(result.firstMinute).dropBPM, 30, accuracy: 1e-9)
            XCTAssertEqual(try XCTUnwrap(result.secondMinute).dropBPM, 60, accuracy: 1e-9)
            XCTAssertEqual(result.firstMinute?.algorithmVersion, TimedHeartRateRecovery.algorithmVersion)
        }
    }
    func testGapCannotBecomeOneMinuteByPosition() {
        let gappy = tail().filter { $0.timestamp <= 600 || $0.timestamp >= 640 }
        let result = WorkoutAnalytics.timedHeartRateRecovery(samples: gappy, start: 0, end: 600, maximumHR: 190)
        XCTAssertNil(result.firstMinute)
        XCTAssertNil(result.secondMinute)
        XCTAssertNotNil(result.reason)
    }
    func testMissingTwoMinuteWindowDoesNotEraseFirst() {
        let result = WorkoutAnalytics.timedHeartRateRecovery(samples: tail().filter { $0.timestamp <= 670 }, start: 0, end: 600, maximumHR: 190)
        XCTAssertNotNil(result.firstMinute)
        XCTAssertNil(result.secondMinute)
    }
    func testOffWristAndInsufficientIntensityAreAbsent() {
        var samples = tail()
        samples.append(WorkoutHRPoint(timestamp: 630, bpm: 0, valid: false))
        XCTAssertNil(WorkoutAnalytics.timedHeartRateRecovery(samples: samples, start: 0, end: 600, maximumHR: 190).firstMinute)
        let low = tail().map { WorkoutHRPoint(timestamp: $0.timestamp, bpm: 90) }
        XCTAssertNil(WorkoutAnalytics.timedHeartRateRecovery(samples: low, start: 0, end: 600, maximumHR: 190).firstMinute)
        XCTAssertNil(WorkoutAnalytics.timedHeartRateRecovery(samples: tail(), start: 0, end: 600, maximumHR: nil).firstMinute)
    }
    func testPeakUsesLastThirtyClockSeconds() throws {
        var samples = tail()
        samples.append(WorkoutHRPoint(timestamp: 550, bpm: 200))
        let result = WorkoutAnalytics.timedHeartRateRecovery(samples: samples, start: 0, end: 600, maximumHR: 190)
        XCTAssertEqual(try XCTUnwrap(result.firstMinute).peakBPM, 165)
    }
    func testLoadPrimeWarmupAndRestDays() throws {
        XCTAssertNil(ActivityAnalytics.trainingLoad(dailyStrain: Array(repeating: 10, count: 13)))
        let values: [Double?] = Array(repeating: 10, count: 7) + Array(repeating: 0, count: 7)
        let load = try XCTUnwrap(ActivityAnalytics.trainingLoad(dailyStrain: values))
        XCTAssertEqual(load.fitness, 10 * exp(-7.0 / 42), accuracy: 1e-9)
        XCTAssertEqual(load.fatigue, 10 * exp(-1), accuracy: 1e-9)
        XCTAssertEqual(load.days, 14)
        XCTAssertFalse(load.isEstablished)
        XCTAssertNil(ActivityAnalytics.trainingLoad(dailyStrain: Array(repeating: 10, count: 42) + [nil]))
    }
}
