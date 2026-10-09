import XCTest
@testable import AnalyticsKit

private actor SleepPersistenceProbe {
    private var writes = 0

    func persist() { writes += 1 }
    func count() -> Int { writes }
}

final class SleepAnalyticsTests: XCTestCase {
    func testAccountingUsesExplicitOnsetOffsetAndWASO() {
        let stages = Array(repeating: SleepStage.nrem, count: 60) + Array(repeating: SleepStage.wake, count: 5) + Array(repeating: SleepStage.nrem, count: 60)
        let result = SleepAnalytics.accounting(asleep: stages.map(\.isAsleep), stages: stages)
        XCTAssertEqual(result.value?.totalSleepSeconds, 120)
        XCTAssertEqual(result.value?.wasoSeconds, 5)
        XCTAssertEqual(result.value?.sleepPeriodSeconds, 124)
    }

    func testForcedWindowWithoutHeartRateRemainsPartialAndPresent() {
        let input = SleepInputSnapshot(
            acceleration: [SleepAccelerationSample(timestamp: 0, x: 0, y: 0, z: 1)],
            heartRate: [],
            forcedWindow: SleepForcedWindow(onset: 0, offset: 3_600)
        )
        let result = SleepAnalytics.segment(input)
        XCTAssertTrue(result.present)
        XCTAssertTrue(result.isPartial)
        XCTAssertNil(result.totalSleepSeconds)
    }

    func testDayWindowsFollowLocalMidnightAndDSTLength() {
        let timestamp = DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: TimeZone(identifier: "America/New_York"), year: 2024, month: 3, day: 10, hour: 12).date!.timeIntervalSince1970
        let window = SleepAnalytics.dayWindow(containing: timestamp, timeZoneIdentifier: "America/New_York")
        XCTAssertEqual(window?.lengthSeconds, 23 * 3_600)
    }

    func testAdvancedDetectorUsesOvernightStillnessAndHRGuards() {
        let acceleration = (0...3_600).map { SleepAccelerationSample(timestamp: Double($0), x: 0, y: 0, z: 1) }
        let heartRate = stride(from: 0, through: 3_600, by: 5).map { SleepHeartRateSample(timestamp: Double($0), bpm: 55) }
        let result = SleepAdvancedWindowDetector.detect(acceleration: acceleration, heartRate: heartRate, timeZoneIdentifier: "UTC")
        XCTAssertTrue(result.present)
        XCTAssertGreaterThanOrEqual(result.value?.first?.sptSeconds ?? 0, 3_600)
    }

    func testCardioStagerWithNoValidHRAbstains() {
        let features = SleepCardioEpochFeatures(
            motion: [0, 0, 0], heartRate: [.nan, .nan, .nan],
            heartRateSD: [0, 0, 0], rmssd: [.nan, .nan, .nan],
            lfHF: [.nan, .nan, .nan], rk: [.nan, .nan, .nan], sdnn: [.nan, .nan, .nan]
        )
        XCTAssertNil(SleepCardioStager.classify(features).value)
    }

    func testEveryPublishedSleepOutputCarriesThePinnedAlgorithmVersion() async throws {
        let stages = Array(repeating: SleepStage.light, count: 60)
        let accounting = SleepAnalytics.accounting(asleep: stages.map(\.isAsleep), stages: stages).value
        let hypnogram = SleepAnalytics.hypnogramMetrics(SleepSession(start: 0, end: 60, stages: stages))
        let regularity = SleepAnalytics.sleepRegularityIndex([true, false, true], epochsPerDay: 2).value
        let derivation = try await SleepAnalytics.derive(SleepInputSnapshot(acceleration: []))

        XCTAssertEqual(SleepSegmentation.absent.algorithmVersion, SleepAlgorithm.version)
        XCTAssertEqual(accounting?.algorithmVersion, SleepAlgorithm.version)
        XCTAssertEqual(hypnogram.algorithmVersion, SleepAlgorithm.version)
        XCTAssertEqual(regularity?.algorithmVersion, SleepAlgorithm.version)
        XCTAssertEqual(derivation.algorithmVersion, SleepAlgorithm.version)
    }
}

final class SleepAbstentionTests: XCTestCase {
    func testAutomaticNoHeartRateIsAbsent() {
        let input = SleepInputSnapshot(acceleration: [SleepAccelerationSample(timestamp: 0, x: 0, y: 0, z: 1)])
        XCTAssertFalse(SleepAnalytics.segment(input).present)
    }

    func testForcedNoHeartRateDoesNotCreateDerivedAccounting() async throws {
        let input = SleepInputSnapshot(
            acceleration: [SleepAccelerationSample(timestamp: 0, x: 0, y: 0, z: 1)],
            forcedWindow: SleepForcedWindow(onset: 0, offset: 3_600)
        )
        let derivation = try await SleepAnalytics.derive(input)
        XCTAssertTrue(derivation.segmentation.isPartial)
        XCTAssertNil(derivation.accounting)
        XCTAssertNil(derivation.hypnogram)
    }

    func testThinAutomaticCoverageRemainsAbsent() {
        let input = SleepInputSnapshot(
            acceleration: [SleepAccelerationSample(timestamp: 0, x: 0, y: 0, z: 1)],
            heartRate: [SleepHeartRateSample(timestamp: 0, bpm: 55)]
        )
        let result = SleepAnalytics.segment(input)
        XCTAssertFalse(result.present)
        XCTAssertNil(result.totalSleepSeconds)
    }
}

final class SleepDayAssignmentTests: XCTestCase {
    func testMainSleepUsesLocalEndDayAcrossFallBack() {
        let calendar = Calendar(identifier: .gregorian)
        let start = DateComponents(calendar: calendar, timeZone: TimeZone(identifier: "America/New_York"), year: 2024, month: 11, day: 2, hour: 23).date!.timeIntervalSince1970
        let end = DateComponents(calendar: calendar, timeZone: TimeZone(identifier: "America/New_York"), year: 2024, month: 11, day: 3, hour: 7).date!.timeIntervalSince1970
        let window = SleepAnalytics.mainSleepDay(forEnd: end, timeZoneIdentifier: "America/New_York")
        XCTAssertEqual(window?.day.day, 3)
        XCTAssertEqual(window?.lengthSeconds, 25 * 3_600)
        XCTAssertGreaterThan(end, start)
    }

    func testMainSleepUsesLocalEndDayAfterTimezoneTravel() {
        let calendar = Calendar(identifier: .gregorian)
        let end = DateComponents(calendar: calendar, timeZone: TimeZone(identifier: "Asia/Tokyo"), year: 2024, month: 7, day: 16, hour: 1).date!.timeIntervalSince1970
        let window = SleepAnalytics.mainSleepDay(forEnd: end, timeZoneIdentifier: "Asia/Tokyo")
        XCTAssertEqual(window?.day.year, 2024)
        XCTAssertEqual(window?.day.month, 7)
        XCTAssertEqual(window?.day.day, 16)
        XCTAssertEqual(window?.lengthSeconds, 24 * 3_600)
    }
}

final class SleepIdempotenceTests: XCTestCase {
    func testRepeatedSegmentationIsEqual() {
        let input = SleepInputSnapshot(
            acceleration: [SleepAccelerationSample(timestamp: 0, x: 0, y: 0, z: 1)],
            forcedWindow: SleepForcedWindow(onset: 0, offset: 3_600)
        )
        XCTAssertEqual(SleepAnalytics.segment(input), SleepAnalytics.segment(input))
    }

    func testRepeatedDerivationAndHypnogramAreByteStable() async throws {
        let input = SleepInputSnapshot(
            acceleration: [SleepAccelerationSample(timestamp: 0, x: 0, y: 0, z: 1)],
            forcedWindow: SleepForcedWindow(onset: 0, offset: 3_600)
        )
        let first = try await SleepAnalytics.derive(input)
        let second = try await SleepAnalytics.derive(input)
        XCTAssertEqual(first, second)

        let stages = Array(repeating: SleepStage.light, count: 600)
        let firstHypnogram = SleepAnalytics.hypnogramMetrics(SleepSession(start: 0, end: 600, stages: stages))
        let secondHypnogram = SleepAnalytics.hypnogramMetrics(SleepSession(start: 0, end: 600, stages: stages))
        XCTAssertEqual(firstHypnogram, secondHypnogram)
    }
}

final class SleepCancellationTests: XCTestCase {
    func testCancelledDerivationStopsBeforeWork() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            _ = try await SleepAnalytics.derive(SleepInputSnapshot(acceleration: []))
        }
        do {
            _ = try await task.value
            XCTFail("cancelled sleep derivation unexpectedly completed")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("unexpected cancellation error: \(error)")
        }
    }

    func testScriptedCancellationLeavesNoPartialPersistedState() async {
        let persistence = SleepPersistenceProbe()
        let task = Task { () throws -> Void in
            withUnsafeCurrentTask { $0?.cancel() }
            let derivation = try await SleepAnalytics.derive(SleepInputSnapshot(acceleration: []))
            try Task.checkCancellation()
            if derivation.segmentation.present { await persistence.persist() }
        }
        do {
            try await task.value
            XCTFail("cancelled sleep derivation unexpectedly completed")
        } catch is CancellationError {
            // Expected: the only write follows the final cancellation check.
        } catch {
            XCTFail("unexpected cancellation error: \(error)")
        }
        let writes = await persistence.count()
        XCTAssertEqual(writes, 0)
    }
}

final class SleepParityTests: XCTestCase {
    func testHRFallbackReturnsCandidateOnlyForSustainedDip() {
        let samples = [
            SleepHeartRateSample(timestamp: 0, bpm: 72),
            SleepHeartRateSample(timestamp: 1, bpm: 55),
            SleepHeartRateSample(timestamp: 2, bpm: 54),
            SleepHeartRateSample(timestamp: 3, bpm: 55),
            SleepHeartRateSample(timestamp: 4, bpm: 54),
            SleepHeartRateSample(timestamp: 5, bpm: 55),
            SleepHeartRateSample(timestamp: 6, bpm: 56)
        ]
        let result = SleepHRFallback.window(samples, daytimeBaseline: [70, 72, 71], minDurationSeconds: 5, bridgeGapSeconds: 2, smoothingSeconds: 1)
        XCTAssertEqual(result.value?.durationSeconds, 6)
        XCTAssertEqual(result.confidence, 0.3)
    }

    func testRegularityRequiresMoreThanOneFullDay() {
        XCTAssertNil(SleepAnalytics.sleepRegularityIndex([true, false], epochsPerDay: 2).value)
        XCTAssertNotNil(SleepAnalytics.sleepRegularityIndex([true, false, true], epochsPerDay: 2).value)
        XCTAssertNotNil(SleepAnalytics.sleepRegularityIndex([true, false, true, false, true, false], epochsPerDay: 2).value)
    }
}

final class SleepSegmentParityTests: XCTestCase {
    func testThinAutomaticInputRemainsAbsent() {
        let input = SleepInputSnapshot(
            acceleration: [SleepAccelerationSample(timestamp: 0, x: 0, y: 0, z: 1)],
            heartRate: [SleepHeartRateSample(timestamp: 0, bpm: 55)]
        )
        XCTAssertFalse(SleepAnalytics.segment(input).present)
    }
}

final class SleepStagingParityTests: XCTestCase {
    func testCardioFeatureLabelsRemainFourClassAligned() {
        let features = SleepCardioEpochFeatures(
            motion: [0, 0, 0, 0], heartRate: [55, 54, 53, 52],
            heartRateSD: [1, 1, 1, 1], rmssd: [50, 51, 52, 53],
            lfHF: [0.8, 0.8, 0.8, 0.8], rk: [0.5, 0.5, 0.5, 0.5], sdnn: [40, 41, 42, 43]
        )
        let result = SleepCardioStager.classify(features)
        XCTAssertEqual(result.value?.stages.count, result.value?.stages4.count)
    }
}

final class SleepAccountingParityTests: XCTestCase {
    func testAccountingFixtureCountsExplicitWASO() {
        let asleep = Array(repeating: true, count: 60) + Array(repeating: false, count: 5) + Array(repeating: true, count: 60)
        let result = SleepAnalytics.accounting(asleep: asleep)
        XCTAssertEqual(result.value?.totalSleepSeconds, 120)
        XCTAssertEqual(result.value?.wasoSeconds, 5)
    }
}

final class HypnogramParityTests: XCTestCase {
    func testRegularityUsesEpochOffsetPairs() {
        let result = SleepAnalytics.sleepRegularityIndex([true, false, true, false, true, false], epochsPerDay: 2)
        XCTAssertEqual(result.value?.comparedPairs, 4)
    }

    func testAASMMappingCountsSleepMetricsAndWakeBouts() {
        let stages = Array(repeating: SleepStage.wake, count: 100)
            + Array(repeating: SleepStage.light, count: 300)
            + Array(repeating: SleepStage.deep, count: 200)
            + Array(repeating: SleepStage.rem, count: 200)
            + Array(repeating: SleepStage.wake, count: 50)
            + Array(repeating: SleepStage.light, count: 150)
        let result = SleepAnalytics.hypnogramMetrics(SleepSession(start: 0, end: 1_000, stages: stages))
        XCTAssertEqual(result.timeInBedSeconds, 1_000)
        XCTAssertEqual(result.totalSleepSeconds, 850)
        XCTAssertEqual(result.sleepPeriodSeconds, 900)
        XCTAssertEqual(result.sleepOnsetLatencySeconds, 100)
        XCTAssertEqual(result.remLatencySeconds ?? -1, 500, accuracy: 1e-12)
        XCTAssertEqual(result.wasoSeconds, 50)
        XCTAssertEqual(result.disturbances, 1)
        XCTAssertEqual(result.efficiency, 0.85, accuracy: 1e-12)
    }
}
