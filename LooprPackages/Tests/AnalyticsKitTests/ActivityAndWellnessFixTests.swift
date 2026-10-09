import XCTest
@testable import AnalyticsKit

/// Cover for the activity and wellness repairs: the step heart-rate gate, the
/// daily-summary movement floor, Banister day strain, the readiness saturation
/// cap, the baseline countdown, and the stress score.
final class ActivityAndWellnessFixTests: XCTestCase {
    private func minutes(_ count: Int, amplitude: Double, start: TimeInterval = 0) -> [MotionMinute] {
        (0..<count).map {
            MotionMinute(start: start + Double($0) * 60, sampleCount: 60, enmo: amplitude,
                         mad: 0.01, meanMagnitude: 1, dynamicAmplitude: amplitude)
        }
    }

    func testStepEstimateDropsMinutesThatNeverLiftedHeartRate() {
        let motion = minutes(20, amplitude: 0.2)
        let quiet = ActivityAnalytics.dailyStepEstimate(
            motion, personalDynamicFloor: 0.1,
            hrPerMinute: Array(repeating: 60, count: motion.count), restingHR: 58
        )
        let walking = ActivityAnalytics.dailyStepEstimate(
            motion, personalDynamicFloor: 0.1,
            hrPerMinute: Array(repeating: 90, count: motion.count), restingHR: 58
        )
        XCTAssertEqual(quiet.value?.activeMinutes, 0, "arm movement at resting heart rate is not walking")
        XCTAssertEqual(walking.value?.activeMinutes, motion.count)
    }

    func testDeriveFeedsThePerMinuteHeartRateIntoTheStepGate() async throws {
        let seconds = 30 * 60
        let acceleration = (0..<seconds).map { index in
            ActivityAccelerationSample(timestamp: Double(index), x: index.isMultiple(of: 2) ? 0.3 : 0, y: 0, z: 1)
        }
        let amplitudes = (ActivityAnalytics.enmoSeries(acceleration).value?.minutes ?? []).map(\.dynamicAmplitude)
        let floor = try XCTUnwrap(amplitudes.min()) * 0.95
        XCTAssertLessThanOrEqual(try XCTUnwrap(amplitudes.max()), floor * 3, "fixture must sit inside the ambulatory band")

        func derive(bpm: Double) async throws -> ActivityDerivation {
            try await ActivityAnalytics.derive(ActivityInputSnapshot(
                heartRate: (0..<seconds).map { ActivityHeartRateSample(timestamp: Double($0), bpm: bpm) },
                acceleration: acceleration, restingHR: 56, age: 35,
                personalDynamicFloor: floor, pooledMotionMinutes: 10, personalDynamicFloorRequirement: 5
            ))
        }
        let quiet = try await derive(bpm: 58)
        let moving = try await derive(bpm: 95)
        XCTAssertEqual(quiet.steps.value?.activeMinutes, 0,
                       "a resting heart rate must be able to veto an ambulatory minute")
        XCTAssertGreaterThan(moving.steps.value?.activeMinutes ?? 0, 0)
    }

    func testDailySummaryFloorNeedsFiveDaysNotTwoThousandMinutes() {
        let day = minutes(120, amplitude: 0.05)
        let summary = ActivityAnalytics.dailyDynamicAmplitudeSummary(day)
        XCTAssertNotNil(summary)
        XCTAssertNil(ActivityAnalytics.dailyDynamicAmplitudeSummary(minutes(30, amplitude: 0.05)),
                     "a day too thin to summarise contributes nothing")

        let fourDays = Array(repeating: summary!, count: 4)
        XCTAssertNil(ActivityAnalytics.personalDynamicFloorFromDailySummaries(fourDays))
        let fiveDays = Array(repeating: summary!, count: 5)
        XCTAssertEqual(ActivityAnalytics.personalDynamicFloorFromDailySummaries(fiveDays), summary)
        XCTAssertNil(ActivityAnalytics.personalDynamicFloor(day.map(\.dynamicAmplitude)),
                     "the pooled-minute floor still needs its own much larger history")
    }

    func testStepBaselineNoteReportsTheRequirementItWasGiven() {
        let result = ActivityAnalytics.dailyStepEstimate(
            minutes(10, amplitude: 0.2), personalDynamicFloor: nil,
            pooledMinutesAvailable: 2, baselineRequirement: 5
        )
        XCTAssertNil(result.value)
        XCTAssertEqual(baselineNightsRemaining(result.note), 3)
    }

    func testDayStrainUsesBanisterAgainstTheAgeAnchor() async throws {
        let seconds = 1_200
        let heartRate = (0..<seconds).map { ActivityHeartRateSample(timestamp: Double($0), bpm: 140) }
        let derivation = try await ActivityAnalytics.derive(ActivityInputSnapshot(
            heartRate: heartRate, restingHR: 55, age: 40, sex: .male
        ))
        XCTAssertEqual(derivation.strain.value?.method, "banister")
        let tanaka = 208 - 0.7 * 40.0
        XCTAssertEqual(derivation.strain.value?.hrMax ?? 0, tanaka, accuracy: 0.001)
    }

    func testAnArtifactSpikeNoLongerInflatesTheStrainDenominator() async throws {
        let seconds = 1_200
        var clean = (0..<seconds).map { ActivityHeartRateSample(timestamp: Double($0), bpm: 140) }
        var spiked = clean
        spiked.append(contentsOf: (0..<10).map { ActivityHeartRateSample(timestamp: Double(seconds + $0), bpm: 220) })
        clean.append(contentsOf: (0..<10).map { ActivityHeartRateSample(timestamp: Double(seconds + $0), bpm: 140) })
        let withSpike = try await ActivityAnalytics.derive(ActivityInputSnapshot(heartRate: spiked, restingHR: 55, age: 40, sex: .male))
        let withoutSpike = try await ActivityAnalytics.derive(ActivityInputSnapshot(heartRate: clean, restingHR: 55, age: 40, sex: .male))
        XCTAssertEqual(withSpike.strain.value?.hrMax, withoutSpike.strain.value?.hrMax)
    }

    func testReadinessHeadlineIsWithheldWhenTheCompositeSaturates() {
        // Five nights that barely differ. The baseline spread collapses and
        // every later night lands at one end of the scale.
        let baseline = [50.0, 50.1, 49.9, 50.0, 50.05]
        let composite = WellnessAnalytics.readinessComposite([
            .hrv(400, baseline: baseline), .restingHeartRate(52, baseline: [54, 56, 58])
        ])
        XCTAssertNotNil(composite.value)
        XCTAssertGreaterThan(abs(composite.value?.compositeZ ?? 0), WellnessAnalytics.readinessZCap)
        XCTAssertNil(WellnessAnalytics.headlineReadinessScore(composite))
    }

    func testReadinessHeadlineSurvivesAnOrdinaryNight() {
        let composite = WellnessAnalytics.readinessComposite([
            .hrv(58, baseline: [50.0, 54, 46, 52, 49]), .restingHeartRate(52, baseline: [54, 56, 58])
        ])
        XCTAssertNotNil(WellnessAnalytics.headlineReadinessScore(composite))
    }

    func testBaselineCountdownReadsTheNeedBaselineNote() {
        let composite = WellnessAnalytics.readinessComposite([
            .hrv(58, baseline: [50.0]), .respiration(15, baseline: [14.7])
        ])
        XCTAssertNil(composite.value)
        XCTAssertEqual(baselineNightsRemaining(composite.note), 2)
        XCTAssertNil(baselineNightsRemaining("no readiness inputs present — never imputed"))
    }

    func testStressScoreMapsTheBaevskyRangeOntoZeroToOneHundred() {
        XCTAssertEqual(WellnessAnalytics.stressScore(stressIndex: 20) ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(WellnessAnalytics.stressScore(stressIndex: 600) ?? -1, 100, accuracy: 0.001)
        XCTAssertEqual(WellnessAnalytics.stressScore(stressIndex: 2_000) ?? -1, 100, accuracy: 0.001)
        XCTAssertNil(WellnessAnalytics.stressScore(stressIndex: 0))
        let middle = WellnessAnalytics.stressScore(stressIndex: 110) ?? 0
        XCTAssertGreaterThan(middle, 40)
        XCTAssertLessThan(middle, 60)
    }
}
