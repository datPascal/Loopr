import XCTest
@testable import AnalyticsKit

final class WellnessAnalyticsTests: XCTestCase {
    func testReadinessAbstainsWithoutAUsableBaseline() {
        let result = WellnessAnalytics.readinessComposite([.hrv(50, baseline: [50, 50, 50])])
        XCTAssertNil(result.value)
        XCTAssertEqual(result.confidence, 0)
        XCTAssertTrue(result.note?.contains("no dispersion") == true || result.note?.contains("no readiness") == true || result.note?.contains("need_baseline") == true || result.note?.contains("need_inputs") == true)
    }

    func testReadinessRenormalizesPresentInputsAndRanksDrivers() {
        let result = WellnessAnalytics.readinessComposite([
            .hrv(60, baseline: [40, 45, 50, 55]),
            .restingHeartRate(60, baseline: [58, 60, 62, 61])
        ])
        XCTAssertNotNil(result.value)
        XCTAssertEqual(result.algorithmVersion, WellnessAlgorithm.readinessVersion)
        XCTAssertFalse(result.inputsUsed.isEmpty)
    }

    func testStressAbstainsForTooFewBeats() {
        XCTAssertNil(WellnessAnalytics.baevskyStressIndex(Array(repeating: 800, count: 29)).value)
    }
}

final class ReadinessAbstentionTests: XCTestCase {
    func testDerivationRequiresCompletedCanonicalSleep() async throws {
        let input = WellnessInputSnapshot(
            readinessInputs: [.hrv(60, baseline: [40, 45, 50, 55]), .restingHeartRate(60, baseline: [58, 60, 62, 61])],
            cleanedRR: RRCorrectionResult(normalIntervalsMilliseconds: Array(repeating: 780, count: 20) + Array(repeating: 820, count: 20), normalTimesMilliseconds: [], classes: [], cleanFraction: 1, droppedCount: 0, correctedCount: 0)
        )
        let result = try await WellnessAnalytics.derive(input)
        XCTAssertNil(result.readiness.value)
        XCTAssertNotNil(result.stress.value)
    }

    func testLowRRQualityAbstainsStress() async throws {
        let input = WellnessInputSnapshot(
            cleanedRR: RRCorrectionResult(normalIntervalsMilliseconds: Array(repeating: 800, count: 40), normalTimesMilliseconds: [], classes: [], cleanFraction: 0.25, droppedCount: 30, correctedCount: 0),
            sleep: SleepSegmentation(window: SleepWindow(onsetIndex: 0, offsetIndex: 60, onset: 0, offset: 60, immobile: [], sptSeconds: 60), stages: Array(repeating: .nrem, count: 60), totalSleepSeconds: 60, wasoSeconds: 0, inBedSeconds: 60, efficiencyPercent: 100, nremSeconds: 60, lightSeconds: 60, deepSeconds: 0, remSeconds: 0, wakeSeconds: 0, confidence: 0.5)
        )
        let result = try await WellnessAnalytics.derive(input)
        XCTAssertNil(result.stress.value)
    }
}

final class ReadinessIdempotenceTests: XCTestCase {
    func testRepeatedCompositeIsEqual() {
        let inputs = [ReadinessInput.hrv(60, baseline: [40, 45, 50, 55])]
        XCTAssertEqual(WellnessAnalytics.readinessComposite(inputs), WellnessAnalytics.readinessComposite(inputs))
    }

    func testRepeatedDerivationKeepsReadinessStressAndSignalsStable() async throws {
        let sleep = SleepSegmentation(
            window: SleepWindow(onsetIndex: 0, offsetIndex: 60, onset: 0, offset: 60, immobile: [], sptSeconds: 60),
            stages: Array(repeating: .nrem, count: 60), totalSleepSeconds: 60, wasoSeconds: 0,
            inBedSeconds: 60, efficiencyPercent: 100, nremSeconds: 60, lightSeconds: 60,
            deepSeconds: 0, remSeconds: 0, wakeSeconds: 0, confidence: 0.8
        )
        let rr = RRCorrectionResult(
            normalIntervalsMilliseconds: (0..<30).map { 790 + Double($0) },
            normalTimesMilliseconds: [], classes: [], cleanFraction: 1,
            droppedCount: 0, correctedCount: 0
        )
        let dates = ["2024-01-01", "2024-01-02", "2024-01-03"]
        let features = dates.map { _ in AnomalyFeatures(restingHeartRate: 60, hrv: 50, respiration: 14) }
        let input = WellnessInputSnapshot(
            readinessInputs: [.hrv(60, baseline: [40, 45, 50, 55]), .restingHeartRate(60, baseline: [58, 60, 62, 61])],
            cleanedRR: rr,
            anomalyDates: dates,
            anomalyFeatures: features,
            sleep: sleep
        )
        let first = try await WellnessAnalytics.derive(input)
        let second = try await WellnessAnalytics.derive(input)
        XCTAssertEqual(first, second)
        XCTAssertNotNil(first.readiness.value)
        XCTAssertNotNil(first.stress.value)
        XCTAssertEqual(first.anomalies.count, dates.count)
    }
}

final class WellnessParityTests: XCTestCase {
    func testCanonicalReadinessInputsPreserveMetricPresenceAndSleepGate() async throws {
        let sleep = SleepSegmentation(
            window: SleepWindow(onsetIndex: 0, offsetIndex: 60, onset: 0, offset: 60, immobile: [], sptSeconds: 60),
            stages: Array(repeating: .nrem, count: 60),
            totalSleepSeconds: 60,
            wasoSeconds: 0,
            inBedSeconds: 60,
            efficiencyPercent: 100,
            nremSeconds: 60,
            lightSeconds: 60,
            deepSeconds: 0,
            remSeconds: 0,
            wakeSeconds: 0,
            confidence: 0.8
        )
        let hrv = AnalyticsMetric<Double>(value: 60, confidence: 0.8, tier: .high, inputsUsed: ["rr_cleaned"], algorithmVersion: "ana02.hrv.v1")
        let input = WellnessInputSnapshot(
            sleep: sleep,
            canonicalReadinessInputs: [CanonicalReadinessInput.hrv(hrv, baseline: [40, 45, 50, 55])]
        )
        let result = try await WellnessAnalytics.derive(input)
        XCTAssertNil(result.readiness.value)
        XCTAssertTrue(result.readiness.note?.contains("need_inputs") == true)
    }

    func testStressQualityGateNeedsBothCleanFractionAndThirtyIntervals() async throws {
        let good = WellnessAnalytics.baevskyStressIndex((0..<30).map { 790.0 + Double($0) })
        XCTAssertNotNil(good.value)
        let degraded = WellnessInputSnapshot(
            cleanedRR: RRCorrectionResult(normalIntervalsMilliseconds: Array(repeating: 800, count: 30), normalTimesMilliseconds: [], classes: [], cleanFraction: 0.49, droppedCount: 1, correctedCount: 0)
        )
        let result = try await WellnessAnalytics.derive(degraded)
        XCTAssertNil(result.stress.value)
    }
}

final class ReadinessParityTests: XCTestCase {
    func testTypedMetricInputsAreAcceptedOnlyWithCompletedSleep() async throws {
        let sleep = SleepSegmentation(
            window: SleepWindow(onsetIndex: 0, offsetIndex: 60, onset: 0, offset: 60, immobile: [], sptSeconds: 60),
            stages: Array(repeating: .nrem, count: 60), totalSleepSeconds: 60, wasoSeconds: 0,
            inBedSeconds: 60, efficiencyPercent: 100, nremSeconds: 60, lightSeconds: 60,
            deepSeconds: 0, remSeconds: 0, wakeSeconds: 0, confidence: 0.8
        )
        let metric = AnalyticsMetric<Double>(value: 60, confidence: 0.8, tier: .high, inputsUsed: ["rr_cleaned"], algorithmVersion: "ana02.hrv.v1")
        let result = try await WellnessAnalytics.derive(WellnessInputSnapshot(sleep: sleep, canonicalReadinessInputs: [CanonicalReadinessInput.hrv(metric, baseline: [40, 45, 50, 55])]))
        XCTAssertFalse(result.readiness.present)
    }
}

final class WellnessSignalParityTests: XCTestCase {
    private let dates = [
        "2024-01-01", "2024-01-02", "2024-01-03", "2024-01-04",
        "2024-01-05", "2024-01-06", "2024-01-07", "2024-01-08",
        "2024-01-09", "2024-01-10", "2024-01-11", "2024-01-12"
    ]

    func testAnomalyUsesOnlyStrictlyPriorBaselineRows() {
        let baseline = (0..<10).map { index in
            AnomalyFeatures(
                restingHeartRate: 60 + Double(index % 3),
                hrv: 48 + Double(index % 4),
                respiration: 13 + Double(index % 2)
            )
        }
        let features = baseline + [
            AnomalyFeatures(restingHeartRate: 110, hrv: 8, respiration: 30),
            AnomalyFeatures(restingHeartRate: 111, hrv: 7, respiration: 31)
        ]
        let result = WellnessAnalytics.multivariateAnomaly(
            dates: dates,
            features: features,
            baselineDays: 28,
            minBaseline: 10,
            persistDays: 2,
            ridge: 0.1
        )
        XCTAssertEqual(result.count, dates.count)
        XCTAssertNil(result[9].mahalanobis)
        XCTAssertTrue(result[10].candidate)
        XCTAssertEqual(result[10].date, "2024-01-11")
        XCTAssertTrue(result[11].flagged)
    }

    func testAnomalyUsesCalendarDaysAndGapResetsPersistence() {
        let baseline = (0..<10).map { index in AnomalyFeatures(restingHeartRate: 60 + Double(index % 3), hrv: 48 + Double(index % 4), respiration: 13 + Double(index % 2)) }
        let input = baseline + [AnomalyFeatures(restingHeartRate: 110, hrv: 8, respiration: 30), AnomalyFeatures(restingHeartRate: 111, hrv: 7, respiration: 31)]
        var gapped = dates; gapped[11] = "2024-01-13"
        let result = WellnessAnalytics.multivariateAnomaly(dates: gapped, features: input)
        XCTAssertTrue(result[10].candidate)
        XCTAssertTrue(result[11].candidate)
        XCTAssertFalse(result[11].flagged)
        gapped[11] = "2024-03-01"
        let stale = WellnessAnalytics.multivariateAnomaly(dates: gapped, features: input)
        XCTAssertNil(stale[11].mahalanobis)
        XCTAssertFalse(stale[11].flagged)
    }

    func testAnomalySmallSampleCorrectionDoesNotFlagModerateNoise() {
        let baseline = (0..<10).map { index in AnomalyFeatures(restingHeartRate: 60 + Double(index % 3), hrv: 48 + Double(index % 4), respiration: 13 + Double(index % 2)) }
        let result = WellnessAnalytics.multivariateAnomaly(dates: Array(dates.prefix(11)), features: baseline + [AnomalyFeatures(restingHeartRate: 65, hrv: 44, respiration: 15)])
        XCTAssertNotNil(result[10].mahalanobis)
        XCTAssertFalse(result[10].candidate)
        XCTAssertEqual(WellnessAnalytics.anomalyAlgorithmVersion, "ana04.anomaly.v2.calendar-small-sample")
    }

    func testChangePointAndIllnessPrimitivesRetainExplicitVersions() {
        let values = Array(repeating: 1.0, count: 7) + Array(repeating: 5.0, count: 7)
        let changePoints = WellnessAnalytics.segmentChangePoints(
            values,
            minSegment: 3,
            penaltyOverride: 0.1
        )
        XCTAssertNotNil(changePoints.value)
        XCTAssertEqual(changePoints.algorithmVersion, WellnessAlgorithm.version)
        XCTAssertEqual(changePoints.value?.segmentMeans.count, 2)

        let illness = WellnessAnalytics.illnessCusum(
            dates: Array(dates.prefix(9)),
            restingHeartRate: [60, 61, 60, 61, 60, 61, 60, 80, 80],
            baselineDays: 28,
            k: 0.5,
            threshold: 4,
            persistDays: 1,
            minBaseline: 7,
            returnZ: 0.5,
            recoverDays: 2
        )
        XCTAssertEqual(illness.count, 9)
        XCTAssertEqual(illness[7].state, .red)
        XCTAssertNotNil(illness[7].z)
    }

    func testDerivationCarriesSignalArraysWithoutInventingReadiness() async throws {
        let dates = Array(self.dates.prefix(9))
        let features = Array(repeating: AnomalyFeatures(restingHeartRate: 60, hrv: 50, respiration: 14), count: dates.count)
        let result = try await WellnessAnalytics.derive(
            WellnessInputSnapshot(
                anomalyDates: dates,
                anomalyFeatures: features,
                illnessDates: dates,
                nightlyRestingHeartRate: [60, 61, 60, 61, 60, 61, 60, 80, 80]
            )
        )
        XCTAssertNil(result.readiness.value)
        XCTAssertEqual(result.anomalies.count, dates.count)
        XCTAssertEqual(result.illness.count, dates.count)
        XCTAssertEqual(result.algorithmVersion, WellnessAlgorithm.version)
    }
}

final class StressParityTests: XCTestCase {
    func testStressFixtureRetainsExplicitAlgorithmVersion() {
        let result = WellnessAnalytics.baevskyStressIndex(Array(repeating: 800, count: 30))
        XCTAssertEqual(result.algorithmVersion, WellnessAlgorithm.version)
    }
}

final class ReadinessCancellationTests: XCTestCase {
    func testCancelledDerivationStopsBeforeWork() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            _ = try await WellnessAnalytics.derive(WellnessInputSnapshot())
        }
        do {
            _ = try await task.value
            XCTFail("cancelled wellness derivation unexpectedly completed")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("unexpected cancellation error: \(error)")
        }
    }
}
