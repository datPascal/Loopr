import XCTest
@testable import AnalyticsKit

/// Regression cover for the sleep pipeline repairs: the staging hot loop, the
/// accelerometer-gap rule, the RR beat clock, the daytime heart-rate baseline,
/// the three-hour main-sleep floor, naps, and the heart-rate-led fallback.
final class SleepPipelineFixTests: XCTestCase {
    private static let midnight: TimeInterval = 1_735_689_600 // 2025-01-01T00:00:00Z

    private func stillNight(from start: TimeInterval, seconds: Int) -> [SleepAccelerationSample] {
        (0..<seconds).map { SleepAccelerationSample(timestamp: start + Double($0), x: 0, y: 0, z: 1) }
    }

    private func steadyHeartRate(from start: TimeInterval, seconds: Int, bpm: Double, step: Int = 1) -> [SleepHeartRateSample] {
        stride(from: 0, to: seconds, by: step).map { SleepHeartRateSample(timestamp: start + Double($0), bpm: bpm) }
    }

    // MARK: - Performance

    func testStagingIgnoresSamplesOutsideTheStagedWindow() {
        let onset = Self.midnight + 3_600
        let offset = onset + 4 * 3_600
        let full = stillNight(from: Self.midnight, seconds: 12 * 3_600)
        let clipped = full.filter { $0.timestamp >= onset - 150 && $0.timestamp < offset + 150 }
        let heart = steadyHeartRate(from: Self.midnight, seconds: 12 * 3_600, bpm: 54, step: 5)

        let wide = SleepCardioStager.stage(acceleration: full, heartRate: heart, rr: [], onset: onset, offset: offset)
        let narrow = SleepCardioStager.stage(acceleration: clipped, heartRate: heart, rr: [], onset: onset, offset: offset)
        XCTAssertNotNil(wide.value)
        XCTAssertEqual(wide.value?.stages, narrow.value?.stages)
        XCTAssertEqual(wide.value?.stages4, narrow.value?.stages4)
        XCTAssertEqual(wide.value?.confidence, narrow.value?.confidence)
    }

    func testStagingARealisticNightFinishesQuickly() {
        // 36 hours of 1 Hz accelerometer, the span a day derivation actually
        // hands the stager, with an eight-hour night inside it.
        let accel = stillNight(from: Self.midnight, seconds: 36 * 3_600)
        XCTAssertEqual(accel.count, 129_600)
        let heart = steadyHeartRate(from: Self.midnight, seconds: 36 * 3_600, bpm: 52, step: 5)
        let rr = stride(from: 0, to: 36 * 3_600, by: 1).map {
            SleepRRInterval(timestamp: Self.midnight + Double($0), milliseconds: 1_150)
        }
        let onset = Self.midnight + 22 * 3_600
        let offset = onset + 8 * 3_600

        let started = Date()
        let result = SleepCardioStager.stage(acceleration: accel, heartRate: heart, rr: rr, onset: onset, offset: offset)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertNotNil(result.value)
        XCTAssertEqual(result.value?.stages.count, 8 * 3_600 / 30)
        XCTAssertLessThan(elapsed, 20, "staging one night must not scan the whole record once per epoch")
    }

    // MARK: - Accelerometer gaps

    func testAccelerometerGapLongerThanAMinuteIsReportedAsWake() {
        let onset = Self.midnight
        let offset = onset + 2 * 3_600
        let heart = steadyHeartRate(from: onset, seconds: 2 * 3_600, bpm: 50, step: 5)
        let continuous = stillNight(from: onset, seconds: 2 * 3_600)
        let holeStart = onset + 3_600
        let holeEnd = holeStart + 600
        let gapped = continuous.filter { $0.timestamp < holeStart || $0.timestamp >= holeEnd }

        let dense = SleepCardioStager.stage(acceleration: continuous, heartRate: heart, rr: [], onset: onset, offset: offset)
        let sparse = SleepCardioStager.stage(acceleration: gapped, heartRate: heart, rr: [], onset: onset, offset: offset)
        let denseStages = try? XCTUnwrap(dense.value?.stages)
        let sparseStages = try? XCTUnwrap(sparse.value?.stages)
        let gapEpochs = Array(Int(holeStart - onset) / 30 + 2 ..< Int(holeEnd - onset) / 30)
        XCTAssertFalse(gapEpochs.isEmpty)
        for epoch in gapEpochs {
            XCTAssertNotEqual(denseStages?[epoch], SleepStage.wake, "a still epoch with data is not wake")
            XCTAssertEqual(sparseStages?[epoch], SleepStage.wake, "an epoch with no accelerometer is not stillness")
        }
    }

    func testBeatClockSeparatesBeatsThatShareAPacketTimestamp() {
        let intervals = [800.0, 810, 790, 805]
        let timestamps = [1_000.0, 1_000, 2_000, 2_000]
        let clock = RRQuality.monotonicBeatTimesMilliseconds(intervals, timestampsMilliseconds: timestamps)
        XCTAssertEqual(clock.count, intervals.count)
        for index in 1..<clock.count {
            XCTAssertGreaterThan(clock[index], clock[index - 1], "the beat clock must be strictly increasing")
        }
    }

    // MARK: - Detector gates

    func testDaytimeBaselineAdmitsANapTheWholeRecordMedianRejects() {
        // A nap centred at 13:00 local. Judged against its own median the
        // sleeping heart rate never looks low enough; judged against the
        // waking hours around it, it does.
        let start = Self.midnight + 12 * 3_600
        let accel = stillNight(from: start, seconds: 2 * 3_600)
        let heart = steadyHeartRate(from: start, seconds: 2 * 3_600, bpm: 60)

        let withoutBaseline = SleepAdvancedWindowDetector.detect(acceleration: accel, heartRate: heart, timeZoneIdentifier: "UTC")
        let withBaseline = SleepAdvancedWindowDetector.detect(
            acceleration: accel, heartRate: heart, timeZoneIdentifier: "UTC",
            daytimeHeartRate: Array(repeating: 82, count: 120)
        )
        XCTAssertNil(withoutBaseline.value)
        XCTAssertEqual(withBaseline.value?.count, 1)
    }

    func testDaytimeBaselineIsIgnoredBelowSixtySamples() {
        let start = Self.midnight + 12 * 3_600
        let accel = stillNight(from: start, seconds: 2 * 3_600)
        let heart = steadyHeartRate(from: start, seconds: 2 * 3_600, bpm: 60)
        let result = SleepAdvancedWindowDetector.detect(
            acceleration: accel, heartRate: heart, timeZoneIdentifier: "UTC",
            daytimeHeartRate: Array(repeating: 82, count: 59)
        )
        XCTAssertNil(result.value)
    }

    func testAutomaticMainSleepNeedsThreeHoursAndShorterSessionsBecomeNaps() {
        let onset = Self.midnight + 2 * 3_600
        let accel = stillNight(from: onset, seconds: 2 * 3_600)
        let heart = steadyHeartRate(from: onset, seconds: 2 * 3_600, bpm: 50)
        let short = SleepAnalytics.segment(SleepInputSnapshot(
            acceleration: accel, heartRate: heart, timeZoneIdentifier: "UTC"
        ))
        XCTAssertFalse(short.present, "two hours is a nap, not the night")
        XCTAssertEqual(short.naps.count, 1)

        let longAccel = stillNight(from: onset, seconds: 5 * 3_600)
        let longHeart = steadyHeartRate(from: onset, seconds: 5 * 3_600, bpm: 50)
        let night = SleepAnalytics.segment(SleepInputSnapshot(
            acceleration: longAccel, heartRate: longHeart, timeZoneIdentifier: "UTC"
        ))
        XCTAssertTrue(night.present)
        XCTAssertTrue(night.naps.isEmpty)
    }

    func testForcedWindowKeepsTheOneHourFloor() {
        let onset = Self.midnight + 2 * 3_600
        let accel = stillNight(from: onset, seconds: 2 * 3_600)
        let heart = steadyHeartRate(from: onset, seconds: 2 * 3_600, bpm: 50)
        let result = SleepAnalytics.segment(
            SleepInputSnapshot(acceleration: accel, heartRate: heart, timeZoneIdentifier: "UTC"),
            forcedWindow: SleepForcedWindow(onset: onset, offset: onset + 2 * 3_600)
        )
        XCTAssertTrue(result.present)
    }

    // MARK: - Heart-rate-led fallback

    func testHeartRateLedFallbackRecoversANightWithNoGravity() {
        let start = Self.midnight
        var heart: [SleepHeartRateSample] = []
        heart += steadyHeartRate(from: start, seconds: 6 * 3_600, bpm: 82)
        heart += steadyHeartRate(from: start + 6 * 3_600, seconds: 5 * 3_600, bpm: 50)
        heart += steadyHeartRate(from: start + 11 * 3_600, seconds: 2 * 3_600, bpm: 82)
        let result = SleepAnalytics.segment(SleepInputSnapshot(
            acceleration: [], heartRate: heart,
            daytimeHeartRate: Array(repeating: 82, count: 600),
            timeZoneIdentifier: "UTC"
        ))
        XCTAssertTrue(result.present, "a night with no gravity must not vanish")
        XCTAssertTrue(result.isHeartRateLed)
        XCTAssertTrue(result.isPartial, "the fallback is a candidate, never a confident night")
        XCTAssertLessThanOrEqual(result.confidence, 0.3)
    }

    func testDenseGravityNeverTriggersTheHeartRateLedFallback() {
        let start = Self.midnight
        let accel = stillNight(from: start, seconds: 13 * 3_600)
        var heart: [SleepHeartRateSample] = []
        heart += steadyHeartRate(from: start, seconds: 6 * 3_600, bpm: 82)
        heart += steadyHeartRate(from: start + 6 * 3_600, seconds: 5 * 3_600, bpm: 50)
        heart += steadyHeartRate(from: start + 11 * 3_600, seconds: 2 * 3_600, bpm: 82)
        let result = SleepAnalytics.segment(SleepInputSnapshot(
            acceleration: accel, heartRate: heart,
            daytimeHeartRate: Array(repeating: 82, count: 600),
            timeZoneIdentifier: "UTC"
        ))
        XCTAssertFalse(result.isHeartRateLed)
    }
}
