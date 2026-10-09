import XCTest
@testable import AnalyticsKit

final class WorkoutAnalyticsTests: XCTestCase {
    func testRecoveryAbstainsWhenHeartRateDoesNotDescend() {
        let tail = Array(repeating: 150.0, count: 100)
        XCTAssertNil(WorkoutAnalytics.hrRecovery(tail, endIndex: 20).value)
    }

    func testRecoveryReportsPositiveDrop() {
        var tail = Array(repeating: 150.0, count: 20)
        tail += Array(repeating: 110.0, count: 70)
        let result = WorkoutAnalytics.hrRecovery(tail, endIndex: 10)
        XCTAssertEqual(result.value?.dropBPM, 40)
    }

    func testCrossMidnightWorkoutUsesEndDay() {
        let start = DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: TimeZone(identifier: "UTC"), year: 2024, month: 1, day: 1, hour: 23, minute: 55).date!.timeIntervalSince1970
        let end = start + 15 * 60
        let assignment = WorkoutAnalytics.workoutDay(start: start, end: end, timeZoneIdentifier: "UTC")
        XCTAssertEqual(assignment?.day.day, 2)
    }
}

final class WorkoutDetectParityTests: XCTestCase {
    func testRepeatedAutoDetectionIsStable() {
        let samples = (0..<900).map { WorkoutHRPoint(timestamp: Double($0), bpm: 150) }
        XCTAssertEqual(WorkoutAnalytics.autoDetect(samples, restingHR: 60, maxHR: 190), WorkoutAnalytics.autoDetect(samples, restingHR: 60, maxHR: 190))
    }

    func testSuggestionNeedsRealHeartRateAnchors() {
        let samples = (0...15).map { WorkoutHRPoint(timestamp: Double($0 * 60), bpm: 150) }
        XCTAssertTrue(WorkoutAnalytics.autoDetect(samples, restingHR: nil, maxHR: 190).isEmpty)
        XCTAssertTrue(WorkoutAnalytics.autoDetect(samples, restingHR: 60, maxHR: nil).isEmpty)
    }

    func testNoMovementCannotBeBypassedByAbruptHeartRateOnset() {
        let samples = (0...16).map { minute in
            WorkoutHRPoint(timestamp: Double(minute * 60), bpm: minute < 4 ? 60 : 150)
        }
        let motion = (0...16).map { minute in
            WorkoutMotionPoint(timestamp: Double(minute * 60), intensity: 0.02)
        }
        XCTAssertTrue(WorkoutAnalytics.autoDetect(samples, restingHR: 60, maxHR: 190, motion: motion).isEmpty)
    }

    func testSuggestionDoesNotTurnAnUnobservedGapIntoSustainedEffort() {
        let sparse = [0.0, 13 * 60.0].map { WorkoutHRPoint(timestamp: $0, bpm: 150) }
        XCTAssertTrue(WorkoutAnalytics.autoDetect(sparse, restingHR: 60, maxHR: 190).isEmpty)
        let briefGap = (0...20).filter { !(10...12).contains($0) }.map {
            WorkoutHRPoint(timestamp: Double($0 * 60), bpm: 150)
        }
        XCTAssertEqual(WorkoutAnalytics.autoDetect(briefGap, restingHR: 60, maxHR: 190).count, 1)
    }
}

final class WorkoutCrossMidnightTests: XCTestCase {
    func testEndDayAssignmentUsesDSTAwareLocalWindow() {
        let calendar = Calendar(identifier: .gregorian)
        let end = DateComponents(calendar: calendar, timeZone: TimeZone(identifier: "America/New_York"), year: 2024, month: 3, day: 10, hour: 1, minute: 30).date!.timeIntervalSince1970
        let start = end - 20 * 60
        let assignment = WorkoutAnalytics.workoutDay(start: start, end: end, timeZoneIdentifier: "America/New_York")
        XCTAssertEqual(assignment?.day.day, 10)
        XCTAssertEqual((assignment?.dayEnd ?? 0) - (assignment?.dayStart ?? 0), 23 * 3_600, accuracy: 1)
    }
}

final class WorkoutAbstentionTests: XCTestCase {
    func testInsufficientRecoveryTailIsAbsent() {
        XCTAssertNil(WorkoutAnalytics.hrRecovery([150, 149], endIndex: 1).value)
    }

    func testCaloriesRequireNoFabricatedProfileButExposeDefaultAnchors() {
        let profile = WorkoutProfile(weightKG: 70, heightCM: 170, age: 30, sex: .nonbinary)
        let estimate = WorkoutAnalytics.estimateBoutCalories([WorkoutHRPoint(timestamp: 0, bpm: 150)], profile: profile)
        XCTAssertNotNil(estimate.value)
        XCTAssertEqual(estimate.value?.usedDefaultAnchors, true)
    }

    func testNoWorkoutDayIsAbsentWhenRequiredStreamsAreMissing() {
        let result = WorkoutAnalytics.detect([], motion: [], restingHR: 60, maxHR: 190)
        XCTAssertNil(result.value)
    }

    func testSufficientButInactiveDayReturnsAnHonestEmptyDetection() {
        let result = WorkoutAnalytics.detect(
            [WorkoutHRPoint(timestamp: 0, bpm: 60)],
            motion: [WorkoutMotionPoint(timestamp: 0, intensity: 0)],
            restingHR: 60,
            maxHR: 190
        )
        XCTAssertNotNil(result.value)
        XCTAssertEqual(result.value, [])
    }
}

final class WorkoutParityTests: XCTestCase {
    func testElapsedCalorieWeightingUsesCappedSampleGaps() {
        let profile = WorkoutProfile(weightKG: 75, heightCM: 178, age: 35, sex: .male)
        let samples = [
            WorkoutHRPoint(timestamp: 0, bpm: 130),
            WorkoutHRPoint(timestamp: 60, bpm: 140),
            WorkoutHRPoint(timestamp: 360, bpm: 150)
        ]
        let estimate = WorkoutAnalytics.estimateBoutCalories(samples, profile: profile, hrMax: 190, restingHR: 60)
        XCTAssertNotNil(estimate.value)
        XCTAssertFalse(estimate.value?.usedDefaultAnchors ?? true)
        XCTAssertGreaterThan(estimate.value?.kcal ?? 0, 0)
    }

    func testDailyEnergySurfacesDefaultHRmax() {
        let profile = WorkoutProfile(weightKG: 75, heightCM: 178, age: 35, sex: .male)
        let estimate = WorkoutAnalytics.dailyEnergy([60, 120, 130], profile: profile)
        XCTAssertEqual(estimate.value?.usedDefaultHRmax, true)
        XCTAssertGreaterThan(estimate.value?.totalKcal ?? 0, 0)
    }

    func testDayCurveExcludesSameDayRowsFromStrictPriorHistory() {
        let curves = WorkoutAnalytics.dayCurve(
            dates: ["2024-01-01", "2024-01-01", "2024-01-02"],
            values: [10, 20, 30],
            minimumHistory: 1
        )
        XCTAssertEqual(curves.map(\.priorCount), [0, 0, 2])
    }
}

final class HRRecoveryParityTests: XCTestCase {
    func testRecoveryFixtureUsesExplicitDropAndVersion() {
        var tail = Array(repeating: 150.0, count: 20)
        tail += Array(repeating: 110.0, count: 70)
        let result = WorkoutAnalytics.hrRecovery(tail, endIndex: 10)
        XCTAssertEqual(result.value?.dropBPM, 40)
        XCTAssertEqual(result.algorithmVersion, WorkoutAlgorithm.version)
    }
}

final class DayCurvesParityTests: XCTestCase {
    func testTargetDayDoesNotLeakIntoItsOwnBaseline() {
        let result = WorkoutAnalytics.dayCurve(
            dates: ["2024-01-01", "2024-01-01", "2024-01-02"],
            values: [10, 20, 30], minimumHistory: 1
        )
        XCTAssertEqual(result[1].priorCount, 0)
        XCTAssertEqual(result[2].priorCount, 2)
    }
}

final class WorkoutIdempotenceTests: XCTestCase {
    func testRepeatedDayCurveDoesNotChangePriorHistory() {
        let dates = ["2024-01-01", "2024-01-02", "2024-01-03"]
        let values = [10.0, 20.0, 30.0]
        XCTAssertEqual(WorkoutAnalytics.dayCurve(dates: dates, values: values), WorkoutAnalytics.dayCurve(dates: dates, values: values))
    }

    func testRepeatedDetectionDoesNotDuplicateAWorkout() {
        let hr = (0...600).map { WorkoutHRPoint(timestamp: Double($0), bpm: 150) }
        let motion = (0...600).map { WorkoutMotionPoint(timestamp: Double($0), intensity: 0.5) }
        let first = WorkoutAnalytics.detect(hr, motion: motion, restingHR: 60, maxHR: 190)
        let second = WorkoutAnalytics.detect(hr, motion: motion, restingHR: 60, maxHR: 190)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.value?.count, 1)
    }
}

final class WorkoutCancellationTests: XCTestCase {
    func testCancelledDerivationStopsBeforeWork() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            _ = try await WorkoutAnalytics.derive(WorkoutInputSnapshot(heartRate: []))
        }
        do {
            _ = try await task.value
            XCTFail("cancelled workout derivation unexpectedly completed")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("unexpected cancellation error: \(error)")
        }
    }
}
