import XCTest
@testable import AnalyticsKit
import DomainKit

final class ActivityAnalyticsTests: XCTestCase {
    func testAnalyticsUsesSharedReserveEdges() async throws {
        let shared = HeartRateZoneSettings(manualMaximum: 184).resolved(age: nil, restingNights: [51])!
        let zones = ActivityAnalytics.zones(shared, source: .manual).value!
        XCTAssertEqual(zones.restingHR, 51)
        XCTAssertEqual(zones.zoneNumber(for: 138), 2)
        for number in 1...5 {
            let zone = zones.zones[number - 1]
            let range = shared.bpmRange(for: number)!
            XCTAssertEqual(zones.zoneNumber(for: Double(range.lowerBound)), number)
            XCTAssertEqual(zones.zoneNumber(for: Double(range.upperBound)), number)
            XCTAssertEqual(zone.lowerBPM, shared.bpmBoundary(percent: shared.edges[number - 1]))
        }
        let result = try await ActivityAnalytics.derive(.init(heartRate: [.init(timestamp: 0, bpm: 138)],
            restingHR: 51, measuredHRMax: 184))
        XCTAssertEqual(result.zones.value?.secondsInZone(2), 1)
        XCTAssertEqual(result.zones.value?.secondsInZone(3), 0)
    }

    func testRecordingGapsDoNotJoinShortWalkingBouts() {
        func minutes(_ timestamps: [Double]) -> [MotionMinute] {
            timestamps.map { MotionMinute(start: $0, sampleCount: 60, enmo: 0.2, mad: 0.01, meanMagnitude: 1, dynamicAmplitude: 0.2) }
        }
        let separate = ActivityAnalytics.dailyStepEstimate(minutes([0, 60, 3_600, 3_660]), personalDynamicFloor: 0.1)
        let continuous = ActivityAnalytics.dailyStepEstimate(minutes([0, 60, 120, 180]), personalDynamicFloor: 0.1)
        XCTAssertEqual(separate.value?.activeMinutes, 0)
        XCTAssertEqual(continuous.value?.activeMinutes, 4)
    }

    func testUngatedHistoryCannotRaiseTheMaximum() {
        let history = Array(repeating: 150.0, count: 590) + Array(repeating: 190.0, count: 10)
        let result = ActivityAnalytics.estimateHRmax(history: history, age: 40)
        XCTAssertEqual(result.value?.source, .agePredicted)
        XCTAssertEqual(result.value?.algorithmVersion, ActivityAlgorithm.version)
    }

    func testStepEstimateAbstainsWithoutPersonalDynamicFloor() {
        let minutes = (0..<10).map { MotionMinute(start: Double($0) * 60, sampleCount: 60, enmo: 0.1, mad: 0.01, meanMagnitude: 1, dynamicAmplitude: 0.1) }
        XCTAssertNil(ActivityAnalytics.dailyStepEstimate(minutes, personalDynamicFloor: nil, pooledMinutesAvailable: 100).value)
    }

    func testEnergyFusionDoesNotClaimCalibrationWithoutAnchors() {
        let result = ActivityAnalytics.branchedEnergyFusion(timestamps: [0], enmo: [0.1], heartRate: [0])
        XCTAssertEqual(result.value?.calibrated, false)
        XCTAssertEqual(result.tier, .relative)
    }
}

final class StrainAbstentionTests: XCTestCase {
    func testSparseShortStreamAbstainsEvenWithAnchors() {
        let hr = Array(repeating: 120.0, count: 20)
        let timestamps = (0..<20).map { Double($0 * 5) }
        XCTAssertNil(ActivityAnalytics.strain(hr: hr, timestamps: timestamps, restingHR: 60, maxHR: 190, source: .measured).value)
    }

    func testMeasuredInputHRmaxWinsInDerivation() async throws {
        let input = ActivityInputSnapshot(heartRate: [ActivityHeartRateSample(timestamp: 0, bpm: 100)], measuredHRMax: 200)
        let result = try await ActivityAnalytics.derive(input)
        XCTAssertEqual(result.zones.inputsUsed.contains("zones"), true)
    }

    func testMissingHeartRateAbstainsStrainAndZoneTime() async throws {
        let result = try await ActivityAnalytics.derive(
            ActivityInputSnapshot(restingHR: 60, measuredHRMax: 190)
        )
        XCTAssertNil(result.strain.value)
        XCTAssertNil(result.zones.value)
    }

    func testMissingMotionAbstainsStepsAndEnergy() async throws {
        let result = try await ActivityAnalytics.derive(
            ActivityInputSnapshot(
                heartRate: [ActivityHeartRateSample(timestamp: 0, bpm: 120)],
                restingHR: 60,
                measuredHRMax: 190
            )
        )
        XCTAssertNil(result.steps.value)
        XCTAssertNil(result.energy.value)
        XCTAssertNil(result.motion.value)
    }
}

final class StrainParityTests: XCTestCase {
    func testBodyZoneTimeAndStrainUseSharedManualMaximumAndBoundaries() async throws {
        let samples = (0..<601).map { ActivityHeartRateSample(timestamp: Double($0), bpm: 130) }
        let settings = HeartRateZoneSettings(manualMaximum: 160, innerBoundaries: [55, 65, 75, 85])
        let result = try await ActivityAnalytics.derive(ActivityInputSnapshot(
            heartRate: samples, restingHR: 60, zoneSettings: settings, age: 40))
        XCTAssertEqual(result.strain.value?.hrMax, 160)
        XCTAssertEqual(result.strain.value?.hrMaxSource, .manual)
        // Reserve edges are 125 and 135 for zone 3; score anchors stay 60/160.
        XCTAssertEqual(result.zones.value?.seconds[2], 601)
        XCTAssertEqual(result.zones.value?.seconds[3], 0)
        let fallback = try await ActivityAnalytics.derive(ActivityInputSnapshot(
            heartRate: samples, zoneSettings: settings, age: 40))
        XCTAssertEqual(fallback.zones.value?.seconds[3], 601)
        XCTAssertEqual(fallback.zones.value?.seconds[2], 0)
    }

    func testMeasuredAndAgePredictedHRmaxRetainSourceInZones() {
        let measured = ActivityAnalytics.zones(maxHR: 200, source: .measured)
        let predicted = ActivityAnalytics.zones(maxHR: 180, source: .agePredicted)
        XCTAssertEqual(measured.value?.source, .measured)
        XCTAssertEqual(predicted.value?.source, .agePredicted)
        XCTAssertGreaterThan(measured.value?.zones.last?.lowerBPM ?? 0, predicted.value?.zones.last?.lowerBPM ?? 0)
    }

    func testEnergyAlignmentUsesWallClockMinuteKeys() {
        let result = ActivityAnalytics.branchedEnergyFusion(
            timestamps: [60, 180], enmo: [0, 0], heartRate: [100, 100], restingHR: 60, maxHR: 190
        )
        XCTAssertEqual(result.value?.points.map(\.timestamp), [60, 180])
    }
}

final class StrainIdempotenceTests: XCTestCase {
    func testRepeatedDerivationIsByteStableAcrossLoadMovementAndEnergy() async throws {
        let heartRate = (0...20).map {
            ActivityHeartRateSample(timestamp: Double($0 * 30), bpm: 120 + Double($0 % 3))
        }
        let acceleration = (0..<120).map {
            ActivityAccelerationSample(
                timestamp: Double($0),
                x: $0.isMultiple(of: 2) ? 0.08 : -0.08,
                y: 0,
                z: 1
            )
        }
        let input = ActivityInputSnapshot(
            heartRate: heartRate,
            acceleration: acceleration,
            restingHR: 60,
            measuredHRMax: 190,
            dailyTrimpHistory: Array(repeating: 10, count: 14),
            personalDynamicFloor: 0.01,
            pooledMotionMinutes: 2_000
        )
        let first = try await ActivityAnalytics.derive(input)
        let second = try await ActivityAnalytics.derive(input)
        XCTAssertEqual(first, second)
    }
}

final class MovementParityTests: XCTestCase {
    func testStaticTiltClassifiesSupineAndDynamicEpochAbstains() {
        let still = (0..<30).map { ActivityAccelerationSample(timestamp: Double($0), x: 0, y: 0, z: 1) }
        let tilt = ActivityAnalytics.staticTilt(still)
        XCTAssertEqual(tilt.value?.position, .supine)
        let dynamic = (0..<30).map { ActivityAccelerationSample(timestamp: Double($0), x: Double($0) / 10, y: 0, z: 1) }
        XCTAssertNil(ActivityAnalytics.staticTilt(dynamic).value)
    }

    func testCadenceCalibrationRejectsImplausibleObservation() {
        let prior = StepCalibration(cadenceSPM: 100, referenceENMO: 0.1, count: 2)
        let live = PedometerResult(steps: 2, durationSeconds: 30, cadenceSPM: 200, peakToPeakG: 0.2, confidence: 0.9)
        XCTAssertEqual(ActivityAnalytics.calibrateCadence(prior: prior, live: live, concurrentENMOG: 0.2), prior)
    }

    func testCounterResetAndMultiDayBacklogAreAttributedToReadingDay() {
        let jan1 = 1_704_067_200.0 // 2024-01-01T00:00:00Z
        let readings = [
            StepCounterSample(timestamp: jan1, cumulativeSteps: 100),
            StepCounterSample(timestamp: jan1 + 3_600, cumulativeSteps: 150),
            StepCounterSample(timestamp: jan1 + 2 * 86_400, cumulativeSteps: 180),
            StepCounterSample(timestamp: jan1 + 2 * 86_400 + 3_600, cumulativeSteps: 20),
            StepCounterSample(timestamp: jan1 + 2 * 86_400 + 7_200, cumulativeSteps: 30)
        ]
        let result = ActivityAnalytics.reconcileStepCounter(readings, timeZoneIdentifier: "UTC")
        XCTAssertEqual(result.value?.resetCount, 1)
        XCTAssertEqual(result.value?.backlogSteps, 30)
        XCTAssertEqual(result.value?.totalSteps, 110)
        XCTAssertEqual(result.value?.days.map(\.steps), [50, 60])
        XCTAssertEqual(result.value?.days.last?.backlogSteps, 30)
        XCTAssertEqual(result.value, ActivityAnalytics.reconcileStepCounter(readings, timeZoneIdentifier: "UTC").value)
    }
}

final class StrainCancellationTests: XCTestCase {
    func testCancelledDerivationStopsBeforeWork() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            _ = try await ActivityAnalytics.derive(ActivityInputSnapshot())
        }
        do {
            _ = try await task.value
            XCTFail("cancelled activity derivation unexpectedly completed")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("unexpected cancellation error: \(error)")
        }
    }
}
