import AnalyticsKit
import XCTest

final class SkinTemperatureAnalyticsTests: XCTestCase {
    private let window = VitalsWindow(start: 0, end: 6 * 3_600)
    private func samples(_ value: (Int) -> Double, hr: (Int) -> Double? = { _ in 58 }) -> [SkinTemperatureSample] {
        (0..<21_600).map { .init(timestamp: Double($0), celsius: value($0), heartRate: hr($0)) }
    }

    func testSettledCoreMedianUsesRealDegreesAndRejectsWarmup() throws {
        let input = samples { second in second < 1_200 ? 28 + Double(second) * 7 / 1_200 : 35 }
        let night = try XCTUnwrap(SkinTemperatureAnalytics.nightly(input, sleepWindows: [window]).value)
        XCTAssertEqual(night.celsius, 35, accuracy: 1e-9)
        XCTAssertLessThan(night.keptSamples, 20_400)
        XCTAssertGreaterThan(night.settledFraction, 0.8)
        XCTAssertGreaterThan(night.sleepCoverage, 0.8)
        XCTAssertEqual(night.algorithmVersion, "vitals.skin-temperature.v2.byte72")
    }

    func testDonAfterGapStartsAnotherSettlingPeriod() throws {
        let steady = samples { _ in 35 }
        let interrupted = steady.filter { !(7_200..<7_800).contains(Int($0.timestamp)) }
        let a = try XCTUnwrap(SkinTemperatureAnalytics.nightly(steady, sleepWindows: [window]).value)
        let b = try XCTUnwrap(SkinTemperatureAnalytics.nightly(interrupted, sleepWindows: [window]).value)
        XCTAssertEqual(a.keptSamples - b.keptSamples, 1_200)
        XCTAssertEqual(b.celsius, 35)
    }

    func testOffWristDecayWithStaleHeartRateCannotBecomeANight() {
        let cold = samples { second in max(22, 35 - Double(second) / 100) }
        XCTAssertNil(SkinTemperatureAnalytics.nightly(cold, sleepWindows: [window]).value)
        XCTAssertNil(SkinTemperatureAnalytics.nightly(samples { _ in 22 }, sleepWindows: [window]).value)
    }

    func testContactGuardRefusesTooMuchColdOrUnsettledSleep() {
        let coldSegment = samples { $0 < 12_000 ? 35 : 31 }
        XCTAssertNil(SkinTemperatureAnalytics.nightly(coldSegment, sleepWindows: [window]).value)
        let unstable = samples { 35 + sin(Double($0) / 120) }
        XCTAssertNil(SkinTemperatureAnalytics.nightly(unstable, sleepWindows: [window]).value)
        XCTAssertNil(SkinTemperatureAnalytics.nightly(samples({ _ in 35 }, hr: { _ in nil }), sleepWindows: [window]).value)
    }

    func testSparseAndDuplicateSecondsCannotInflateCoverage() {
        let sparse = samples { _ in 35 }.filter { Int($0.timestamp) % 3 == 0 }
        XCTAssertNil(SkinTemperatureAnalytics.nightly(sparse + sparse + sparse, sleepWindows: [window]).value)
        XCTAssertNil(SkinTemperatureAnalytics.nightly(Array(samples { _ in 35 }.prefix(299)), sleepWindows: [window]).value)
    }

    func testCalibrationIncludesTonightAndRangeNeedsFourteenNights() throws {
        XCTAssertEqual(SkinTemperatureAnalytics.deviation(tonightCelsius: nil, priorNightsOldestFirst: [35]), .noReading)
        XCTAssertEqual(SkinTemperatureAnalytics.deviation(tonightCelsius: 35, priorNightsOldestFirst: [35]), .calibrating(nightsRemaining: 2))
        let first = try XCTUnwrap(SkinTemperatureAnalytics.deviation(tonightCelsius: 35.2, priorNightsOldestFirst: [35, 35, 35]).value)
        XCTAssertEqual(first.deltaCelsius, 0.2, accuracy: 1e-9)
        XCTAssertFalse(first.trusted)
        XCTAssertNil(first.usualRange)
        let trusted = try XCTUnwrap(SkinTemperatureAnalytics.deviation(tonightCelsius: 35.4, priorNightsOldestFirst: Array(repeating: 35, count: 13)).value)
        XCTAssertTrue(trusted.trusted)
        XCTAssertTrue(trusted.outsideUsualRange)
        XCTAssertEqual(trusted.usualRange, 34.7...35.3)
    }

    func testContactArtifactsDoNotCountTowardThePersonalBaseline() throws {
        let history: [Double?] = [35, 35, 35, 35, 31, 31, 31]
        let value = try XCTUnwrap(SkinTemperatureAnalytics.deviation(tonightCelsius: 35, priorNightsOldestFirst: history).value)
        XCTAssertEqual(value.baselineCelsius, 35)
        XCTAssertEqual(value.baselineNights, 4)
        XCTAssertFalse(value.trusted)
    }

    func testCalendarGapsDoNotPullOldNightsIntoBaselineAndFitJumpIsRefused() throws {
        let stale: [Double?] = Array(repeating: 35, count: 20) + Array(repeating: nil, count: 30)
        XCTAssertEqual(SkinTemperatureAnalytics.deviation(tonightCelsius: 35, priorNightsOldestFirst: stale), .calibrating(nightsRemaining: 3))
        let value = try XCTUnwrap(SkinTemperatureAnalytics.deviation(tonightCelsius: 32, priorNightsOldestFirst: Array(repeating: 35, count: 15)).value)
        XCTAssertTrue(value.likelyFitChange)
        XCTAssertFalse(value.outsideUsualRange)
    }
}

final class OvernightOxygenAnalyticsTests: XCTestCase {
    private let window = VitalsWindow(start: 0, end: 3 * 3_600)
    private func channels(_ value: (Int) -> (Int, Int)) -> [OpticalOxygenSample] {
        (0..<10_800).map { second in
            let pair = value(second)
            return .init(timestamp: Double(second), red: pair.0, infrared: pair.1, heartRate: 60)
        }
    }

    func testStepLikeChannelsAreNotUsable() {
        let input = channels { let step = ($0 / 25) % 3; return (560 + step, 618 + step) }
        let assessment = OvernightOxygenAnalytics.assess(input, sleepWindows: [window])
        XCTAssertFalse(assessment.usable)
        XCTAssertLessThan(assessment.redChangeFraction, 0.1)
    }

    func testEverySecondVariationWithConstantOffsetIsStillUnusable() {
        let input = channels { second in
            let pulse = Int((sin(Double(second) * 2.1) * 40).rounded())
            return (1_000 + pulse, 2_000 + pulse)
        }
        let assessment = OvernightOxygenAnalytics.assess(input, sleepWindows: [window])
        XCTAssertGreaterThan(assessment.redChangeFraction, 0.9)
        XCTAssertGreaterThan(assessment.infraredChangeFraction, 0.9)
        XCTAssertEqual(assessment.independentWindowFraction, 0)
        XCTAssertFalse(assessment.usable)
        XCTAssertNil(OvernightOxygenAnalytics.nightly(input, sleepWindows: [window]).value)
    }

    func testChangingSessionOffsetsAndNearlyIdenticalDeltasAreRefused() {
        let input = channels { second in
            let pulse = Int((sin(Double(second) * 2.1) * 100).rounded())
            return (1_000 + pulse, 2_000 + 2 * pulse + (second / 300) * 100)
        }
        XCTAssertFalse(OvernightOxygenAnalytics.assess(input, sleepWindows: [window]).usable)
    }

    func testIndependentSyntheticChannelsPassResearchGate() throws {
        let input = channels { second in
            let a = Int((sin(Double(second) * 2.1) * 40).rounded())
            let b = Int((sin(Double(second) * 1.7) * 40).rounded())
            return (1_000 + a, 2_000 + b)
        }
        let night = try XCTUnwrap(OvernightOxygenAnalytics.nightly(input, sleepWindows: [window]).value)
        XCTAssertTrue(night.assessment.usable)
        XCTAssertEqual(night.medianRatio, 2, accuracy: 0.02)
    }
}

final class CardioFitnessTests: XCTestCase {
    func testArchivedRatioNeverResolves() {
        let archived = HeartRateRatioEstimate(vo2Max: 51, lower: 42, upper: 61, restingHeartRate: 55,
            maximumHeartRate: 185, maximumHeartRateSource: .agePredicted, restingNights: 4)
        XCTAssertNil(CardioFitnessResolver.resolve(estimate: archived, age: 35, group: .male, now: Date()))
    }

    func testLevelTableMatchesFriendAndAppleRules() throws {
        let table = CardioFitnessLevelTable.friend2015
        // Men 20-29: 10th 32.1, 25th 40.1, median 48.0, 75th 55.2.
        let young = try XCTUnwrap(table.thresholds(age: 25, group: .male))
        XCTAssertEqual(young.low, 32.1 + (40.1 - 32.1) * 10 / 15, accuracy: 1e-9)
        XCTAssertEqual(young.median, 48.0)
        XCTAssertEqual(young.upperQuartile, 55.2)
        XCTAssertEqual(table.level(vo2Max: 37.0, age: 25, group: .male), .low)
        XCTAssertEqual(table.level(vo2Max: young.low, age: 25, group: .male), .belowAverage)
        XCTAssertEqual(table.level(vo2Max: 47.9, age: 25, group: .male), .belowAverage)
        XCTAssertEqual(table.level(vo2Max: 48.0, age: 25, group: .male), .aboveAverage)
        XCTAssertEqual(table.level(vo2Max: 55.2, age: 25, group: .male), .high)
        // Women 30-39: median 30.2.
        XCTAssertEqual(table.level(vo2Max: 30.2, age: 39, group: .female), .aboveAverage)
        // From 60, Low is an absolute 18 (men) and 15 (women).
        XCTAssertEqual(table.level(vo2Max: 17.9, age: 60, group: .male), .low)
        XCTAssertEqual(table.level(vo2Max: 18.0, age: 60, group: .male), .belowAverage)
        XCTAssertEqual(table.level(vo2Max: 14.9, age: 75, group: .female), .low)
        XCTAssertEqual(table.level(vo2Max: 15.0, age: 75, group: .female), .belowAverage)
        XCTAssertEqual(table.level(vo2Max: 20.8, age: 75, group: .female), .high)
        // Ages 59 still use the interpolated quintile.
        XCTAssertEqual(try XCTUnwrap(table.thresholds(age: 59, group: .female)).low, 17.3 + (19.9 - 17.3) * 10 / 15, accuracy: 1e-9)
        // FRIEND has no reference outside 20 to 79.
        XCTAssertNil(table.level(vo2Max: 40, age: 19, group: .male))
        XCTAssertNil(table.level(vo2Max: 40, age: 80, group: .female))
    }

    func testEveryRowIsOrdered() throws {
        for row in CardioFitnessLevelTable.friend2015.rows {
            let thresholds = try XCTUnwrap(CardioFitnessLevelTable.friend2015.thresholds(age: row.ageLower, group: row.group))
            XCTAssertLessThan(thresholds.low, thresholds.median, "\(row)")
            XCTAssertLessThan(thresholds.median, thresholds.upperQuartile, "\(row)")
            XCTAssertLessThan(row.p10, row.interpolatedP20)
            XCTAssertLessThan(row.interpolatedP20, row.p25)
        }
        XCTAssertEqual(CardioFitnessLevelTable.friend2015.rows.count, 12)
    }

    func testAppleHealthWinsAndOnlyItProducesCardioAge() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let day = 86_400.0
        let samples = [0.0, 8, 16].map {
            HealthKitVO2MaxSample(vo2max: 42.4, sampledAt: now.addingTimeInterval(-$0 * day), sourceIdentifier: "com.apple.health", testType: .predictionSubMaxExercise)
        }
        let estimate = HeartRateRatioEstimate(vo2Max: 51, lower: 42, upper: 61, restingHeartRate: 55, maximumHeartRate: 185, maximumHeartRateSource: .agePredicted, restingNights: 4)
        let fromHealth = try XCTUnwrap(CardioFitnessResolver.resolve(estimate: estimate, appleHealth: samples, age: 35,
            group: .male, now: now, timeZone: TimeZone(secondsFromGMT: 0)!))
        XCTAssertEqual(fromHealth.source, .appleHealth)
        XCTAssertEqual(fromHealth.vo2Max, 42.4, accuracy: 1e-9)
        XCTAssertNil(fromHealth.lower)
        XCTAssertEqual(try XCTUnwrap(fromHealth.cardioAge?.ageYears), 35, accuracy: 1e-9)

        XCTAssertNil(CardioFitnessResolver.resolve(estimate: estimate, appleHealth: [], age: 35, group: .male, now: now))
        XCTAssertNil(CardioFitnessResolver.resolve(estimate: nil, appleHealth: [], age: 35, group: .male, now: now))
    }

    func testLowCardioFitnessCheckRespectsSourceLevelAndFourMonths() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 23))!
        let low = CardioFitnessResolution(vo2Max: 30, lower: nil, upper: nil, source: .appleHealth, level: .low, cardioAge: nil)
        XCTAssertTrue(LowCardioFitnessCheck.shouldNotify(resolution: low, lastNotifiedAt: nil, now: now, calendar: calendar))
        let threeMonths = calendar.date(from: DateComponents(year: 2026, month: 6, day: 24))!
        XCTAssertFalse(LowCardioFitnessCheck.shouldNotify(resolution: low, lastNotifiedAt: threeMonths, now: now, calendar: calendar))
        let fourMonths = calendar.date(from: DateComponents(year: 2026, month: 5, day: 23))!
        XCTAssertTrue(LowCardioFitnessCheck.shouldNotify(resolution: low, lastNotifiedAt: fourMonths, now: now, calendar: calendar))
        let estimated = CardioFitnessResolution(vo2Max: 30, lower: 21, upper: 39, source: .heartRateRatio, level: .low, cardioAge: nil)
        XCTAssertFalse(LowCardioFitnessCheck.shouldNotify(resolution: estimated, lastNotifiedAt: nil, now: now, calendar: calendar))
        let fine = CardioFitnessResolution(vo2Max: 45, lower: nil, upper: nil, source: .appleHealth, level: .aboveAverage, cardioAge: nil)
        XCTAssertFalse(LowCardioFitnessCheck.shouldNotify(resolution: fine, lastNotifiedAt: nil, now: now, calendar: calendar))
        XCTAssertFalse(LowCardioFitnessCheck.shouldNotify(resolution: nil, lastNotifiedAt: nil, now: now, calendar: calendar))
    }
}

final class BeatToBeatAnalyticsTests: XCTestCase {
    private func clock(_ intervals: [Double]) -> [Double] {
        var total = 0.0
        return intervals.map { total += $0; return total }
    }

    func testSD1MatchesRMSSDOverRootTwo() throws {
        var intervals: [Double] = []
        for index in 0..<1_000 {
            let swing: Double = index.isMultiple(of: 2) ? 12 : -12
            intervals.append(1_000 + swing + Double(index % 7))
        }
        let summary = try XCTUnwrap(BeatToBeatAnalytics.summarize(intervals, beatTimesMilliseconds: clock(intervals)).value)
        let rmssd = try XCTUnwrap(HRVTime.derive(intervals, beatTimesMilliseconds: clock(intervals)).value?.rmssdMilliseconds)
        XCTAssertEqual(summary.sd1Milliseconds, rmssd / 2.0.squareRoot(), accuracy: rmssd * 0.01)
        XCTAssertEqual(summary.pairCount, 999)
        XCTAssertLessThanOrEqual(summary.points.count, BeatToBeatAnalytics.maximumPlotPoints)
        XCTAssertEqual(summary.meanIntervalMilliseconds, intervals.reduce(0, +) / Double(intervals.count), accuracy: 1e-9)
    }

    func testSD2GrowsWithSlowDriftButSD1DoesNot() throws {
        let flat: [Double] = (0..<1_200).map { (index: Int) -> Double in index.isMultiple(of: 2) ? 905 : 895 }
        let drifting: [Double] = flat.enumerated().map { (pair: (offset: Int, element: Double)) -> Double in
            pair.element + Double(pair.offset) * 0.2
        }
        let a = try XCTUnwrap(BeatToBeatAnalytics.summarize(flat, beatTimesMilliseconds: clock(flat)).value)
        let b = try XCTUnwrap(BeatToBeatAnalytics.summarize(drifting, beatTimesMilliseconds: clock(drifting)).value)
        XCTAssertEqual(a.sd1Milliseconds, b.sd1Milliseconds, accuracy: 0.5)
        XCTAssertGreaterThan(b.sd2Milliseconds, a.sd2Milliseconds * 5)
    }

    func testPairsAcrossAGapAreSkipped() throws {
        let intervals = Array(repeating: 1_000.0, count: 300)
        var times = clock(intervals)
        for index in 150..<times.count { times[index] += 60_000 }
        let summary = try XCTUnwrap(BeatToBeatAnalytics.summarize(intervals, beatTimesMilliseconds: times).value)
        XCTAssertEqual(summary.pairCount, 298)
    }

    func testTachogramBucketsTwoMinutes() throws {
        let intervals = Array(repeating: 1_000.0, count: 600)
        let summary = try XCTUnwrap(BeatToBeatAnalytics.summarize(intervals, beatTimesMilliseconds: clock(intervals)).value)
        XCTAssertEqual(summary.tachogram.count, 5)
        XCTAssertEqual(summary.tachogram.first?.minute, 0)
        XCTAssertEqual(summary.tachogram[1].minute, 2)
        XCTAssertEqual(summary.tachogram[1].meanIntervalMilliseconds, 1_000, accuracy: 1e-9)
    }

    func testTooFewPairsIsAbsent() {
        let intervals = Array(repeating: 1_000.0, count: 50)
        XCTAssertNil(BeatToBeatAnalytics.summarize(intervals, beatTimesMilliseconds: clock(intervals)).value)
        XCTAssertNil(BeatToBeatAnalytics.summarize([1_000], beatTimesMilliseconds: [1_000, 2_000]).value)
    }
}
