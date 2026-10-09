import XCTest
@testable import AnalyticsKit

/// Cover for the first-day failures found against a real strap database: a
/// waking evening published as a night, and a sedentary hour billed as exercise.
final class PartialDayMetricTests: XCTestCase {
    private static let midnight: TimeInterval = 1_735_689_600 // 2025-01-01T00:00:00Z

    private func heartRate(from start: TimeInterval, seconds: Int, bpm: Double, step: Int = 1) -> [SleepHeartRateSample] {
        stride(from: 0, to: seconds, by: step).map { SleepHeartRateSample(timestamp: start + Double($0), bpm: bpm) }
    }

    /// A day of desk work followed by a walk. There is no gravity stream, so
    /// the heart-rate-led fallback runs, and its candidate window is simply the
    /// lower two thirds of the day's heart rate. Nothing here is sleep.
    func testQuietWakingEveningIsNotPublishedAsANight() {
        let start = Self.midnight + 8 * 3_600
        var heart: [SleepHeartRateSample] = []
        heart += heartRate(from: start, seconds: 6 * 3_600, bpm: 78)
        heart += heartRate(from: start + 6 * 3_600, seconds: 3_600, bpm: 140)
        heart += heartRate(from: start + 7 * 3_600, seconds: 3_600, bpm: 80)
        let result = SleepAnalytics.segment(SleepInputSnapshot(
            acceleration: [], heartRate: heart, timeZoneIdentifier: "UTC"
        ))
        XCTAssertNil(result.window, "a waking day must not become a main sleep")
        XCTAssertNil(result.totalSleepSeconds)
    }

    /// The same fallback still recovers a real night: a long dip well below the
    /// waking baseline stages more than the three-hour main-sleep floor.
    func testRealNightStillSurvivesTheHeartRateLedFloor() {
        let start = Self.midnight
        var heart: [SleepHeartRateSample] = []
        heart += heartRate(from: start, seconds: 6 * 3_600, bpm: 82)
        heart += heartRate(from: start + 6 * 3_600, seconds: 5 * 3_600, bpm: 50)
        heart += heartRate(from: start + 11 * 3_600, seconds: 2 * 3_600, bpm: 82)
        let result = SleepAnalytics.segment(SleepInputSnapshot(
            acceleration: [], heartRate: heart,
            daytimeHeartRate: Array(repeating: 82, count: 600),
            timeZoneIdentifier: "UTC"
        ))
        XCTAssertNotNil(result.window)
        XCTAssertTrue(result.isHeartRateLed)
        XCTAssertGreaterThanOrEqual(Double(result.totalSleepSeconds ?? 0), SleepAdvancedWindowDetector.mainSleepMinimumSeconds)
    }

    /// Someone resting at 75 bpm sits above half of a 185 bpm maximum all day.
    /// Without a resting anchor every sedentary minute is charged as exercise.
    func testDailyEnergyUsesHeartRateReserveWhenRestingIsKnown() {
        let profile = WorkoutProfile(weightKG: 78, heightCM: 180, age: 33, sex: .male)
        let sedentary = [Double](repeating: 95, count: 240)
        let anchored = WorkoutAnalytics.dailyEnergy(sedentary, profile: profile, hrMax: 184.9, restingHR: 75)
        let unanchored = WorkoutAnalytics.dailyEnergy(sedentary, profile: profile, hrMax: 184.9)
        XCTAssertEqual(anchored.value?.activeKcal, 0, "sitting at 95 bpm with a 75 bpm resting rate is not exercise")
        XCTAssertGreaterThan(unanchored.value?.activeKcal ?? 0, 500, "the old flat anchor is what this fix removes")
    }

    /// Real exercise still counts once the anchor moves.
    func testDailyEnergyStillCountsMinutesAboveTheReserveThreshold() {
        let profile = WorkoutProfile(weightKG: 78, heightCM: 180, age: 33, sex: .male)
        let session = [Double](repeating: 155, count: 45)
        let energy = WorkoutAnalytics.dailyEnergy(session, profile: profile, hrMax: 184.9, restingHR: 75)
        let active = try? XCTUnwrap(energy.value?.activeKcal)
        XCTAssertNotNil(active)
        XCTAssertGreaterThan(active ?? 0, 300)
        XCTAssertLessThan(active ?? 0, 900)
    }

    /// A missing or absurd resting rate falls back to the documented default.
    func testDailyEnergyIgnoresAnImpossibleRestingRate() {
        let profile = WorkoutProfile(weightKG: 78, heightCM: 180, age: 33, sex: .male)
        let minutes = [Double](repeating: 120, count: 60)
        let baseline = WorkoutAnalytics.dailyEnergy(minutes, profile: profile, hrMax: 184.9)
        for resting in [Double.nan, -10, 0, 400] {
            let value = WorkoutAnalytics.dailyEnergy(minutes, profile: profile, hrMax: 184.9, restingHR: resting)
            XCTAssertEqual(value.value?.activeKcal, baseline.value?.activeKcal)
        }
    }
}
