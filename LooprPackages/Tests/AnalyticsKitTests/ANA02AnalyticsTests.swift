import XCTest
@testable import AnalyticsKit

private actor AnalyticsPersistenceProbe {
    private var persistedCount = 0

    func persist() {
        persistedCount += 1
    }

    func count() -> Int {
        persistedCount
    }
}

final class RRQualityParityTests: XCTestCase {
    func test_cleanIntervalsRemainNormalAndPhysiologicallyPlausible() {
        let intervals = Array(repeating: 800.0, count: 32)
        let result = RRQuality.correct(intervals)
        XCTAssertEqual(result.classes, Array(repeating: .normal, count: intervals.count))
        XCTAssertEqual(result.cleanFraction, 1, accuracy: 1e-12)
        XCTAssertTrue(RRQuality.physiologicallyPlausible(result.normalIntervalsMilliseconds))
    }

    func test_multiBeatArtifactRunIsDroppedWithoutInterpolation() {
        let result = RRQuality.correct([800, 800, 800, 2_500, 2_600, 800, 800])
        XCTAssertGreaterThanOrEqual(result.droppedCount, 2)
        XCTAssertEqual(result.correctedCount, 0)
    }

    func test_packetTimestampGapReanchorsCleanedBeatClock() {
        let result = RRQuality.correct(
            [800, 810, 820, 830],
            beatTimestampsMilliseconds: [1_000, 1_000, 10_000, 10_000]
        )

        XCTAssertEqual(result.normalTimesMilliseconds, [800, 1_610, 9_800, 10_630])
    }

    func test_ppgQualityRejectsOffSkinAndFlatline() {
        XCTAssertFalse(PPGQuality.trust(Array(repeating: 4.0, count: 20), heartRate: 0).trusted)
        let flatline = PPGQuality.trust(Array(repeating: 4.0, count: 20), heartRate: 70)
        XCTAssertFalse(flatline.trusted)
        XCTAssertTrue(flatline.reasons.contains("flatline"))
    }
}

final class HRVTimeParityTests: XCTestCase {
    func test_timeDomainHRVMatchesHandCalculation() throws {
        let metric = HRVTime.derive([800, 800, 820, 820])
        let value = try XCTUnwrap(metric.value)
        XCTAssertEqual(try XCTUnwrap(value.rmssdMilliseconds), sqrt(400.0 / 3.0), accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(value.sdnnMilliseconds), 11.547005383792516, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(value.pNN50Percent), 0, accuracy: 1e-12)
    }

    func test_timeDomainHRVAbstainsOnInsufficientIntervals() {
        XCTAssertFalse(HRVTime.derive([800]).present)
        XCTAssertEqual(HRVTime.derive([800]).confidence, 0)
    }

    func test_timeDomainHRVDoesNotDifferenceAcrossPacketGap() throws {
        let metric = HRVTime.derive(
            [800, 900, 1_200, 1_300],
            beatTimesMilliseconds: [800, 1_700, 12_000, 13_300]
        )
        let value = try XCTUnwrap(metric.value)

        XCTAssertEqual(try XCTUnwrap(value.rmssdMilliseconds), 100, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(value.pNN50Percent), 100, accuracy: 1e-9)
    }
}

final class HRVFreqParityTests: XCTestCase {
    func test_frequencyDomainGatesHighFrequencyWhenArtifactsExceedThreshold() {
        let intervals = (0..<64).map { 800 + 20 * sin(2 * Double.pi * 0.25 * Double($0) / 1.25) }
        let times = intervals.reduce(into: [Double]()) { partial, interval in partial.append((partial.last ?? 0) + interval) }
        let result = HRVFrequency.derive(intervals: intervals, beatTimesMilliseconds: times, artifactFraction: 0.2, gridPoints: 120)
        XCTAssertTrue(result.value?.hfGated ?? false)
        XCTAssertNil(result.value?.hf)
        XCTAssertNil(result.value?.total)
    }
}

final class NocturnalParityTests: XCTestCase {
    func test_nocturnalRHRUsesWallClockWindowsAndExcludesOffSkin() throws {
        let samples = Array(repeating: 70.0, count: 1_800) + Array(repeating: 0.0, count: 10) + Array(repeating: 55.0, count: 1_800)
        let result = NocturnalMetrics.restingHeartRate(samples)
        XCTAssertTrue(result.present)
        let value = try XCTUnwrap(result.value)
        XCTAssertEqual(value.lowestThirtyMinuteMeanBPM, 55, accuracy: 1e-9)
        XCTAssertEqual(value.validSampleCount, 3_600)
    }

    func test_hrDipAbstainsWhenOneSideIsThin() {
        XCTAssertFalse(NocturnalMetrics.heartRateDip(daySamples: [70], nightSamples: [60]).present)
    }
}

final class RespirationParityTests: XCTestCase {
    func test_breathingVariabilityNeedsThreeWindowsAndIsIdempotent() {
        XCTAssertFalse(Respiration.variability([12, 13]).present)
        let first = Respiration.variability([12, 14, 16])
        let second = Respiration.variability([12, 14, 16])
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.value?.windowCount, 3)
    }
}

final class HRVAbstentionTests: XCTestCase {
    func test_allMetricFamiliesPreserveAbsenceInsteadOfZero() {
        XCTAssertNil(RRQuality.gated([]).value)
        XCTAssertNil(HRVTime.derive([]).value)
        XCTAssertNil(HRVFrequency.derive(intervals: [], beatTimesMilliseconds: [], artifactFraction: 0).value)
        XCTAssertNil(NocturnalMetrics.restingHeartRate([]).value)
        XCTAssertNil(Respiration.variability([]).value)
    }

    func test_qualityAndCoverageGatesRemainAbsentForThinOrOffSkinInput() {
        XCTAssertNil(RRQuality.correct([0, 0, 0]).normalIntervalsMilliseconds.first)
        XCTAssertNil(NocturnalMetrics.restingHeartRate(Array(repeating: 0, count: 1_800)).value)
        XCTAssertNil(NocturnalMetrics.heartRateDip(daySamples: Array(repeating: 70, count: 299), nightSamples: Array(repeating: 60, count: 299)).value)
        XCTAssertNil(Respiration.rsaRate(intervals: [800], beatTimesMilliseconds: [800], artifactFraction: 0).value)
        XCTAssertNil(Respiration.riivRate(adc: Array(repeating: 1, count: 29), timestampsSeconds: Array(0..<29).map { Double($0) }).value)
    }
}

final class HRVIdempotenceTests: XCTestCase {
    func test_repeatedPureDerivationIsEqualAndDoesNotMutateBaseline() {
        let before = Baselines.foldHistory([80, 81, 79, 80].map(Optional.some), configuration: Baselines.hrv)
        let first = HRVTime.derive([800, 810, 800, 810])
        let second = HRVTime.derive([800, 810, 800, 810])
        let after = Baselines.foldHistory([80, 81, 79, 80].map(Optional.some), configuration: Baselines.hrv)
        XCTAssertEqual(first, second)
        XCTAssertEqual(before, after)
    }

    func test_repeatedDerivationAcrossMetricFamiliesIsEqual() {
        let rr = (0..<32).map { 800.0 + Double($0 % 3) * 5 }
        let times = rr.reduce(into: [Double]()) { partial, interval in
            partial.append((partial.last ?? 0) + interval)
        }
        XCTAssertEqual(RRQuality.correct(rr), RRQuality.correct(rr))
        XCTAssertEqual(
            HRVFrequency.derive(intervals: rr, beatTimesMilliseconds: times, artifactFraction: 0.05, gridPoints: 120),
            HRVFrequency.derive(intervals: rr, beatTimesMilliseconds: times, artifactFraction: 0.05, gridPoints: 120)
        )
        let hr = [70.0, 70, 60, 60]
        XCTAssertEqual(
            NocturnalMetrics.restingHeartRate(hr, windowSamples: 2, minimumCoverage: 1),
            NocturnalMetrics.restingHeartRate(hr, windowSamples: 2, minimumCoverage: 1)
        )
        XCTAssertEqual(Respiration.variability([12, 14, 16]), Respiration.variability([12, 14, 16]))
    }

    func test_everyPublishedANA02MetricCarriesAnExplicitAlgorithmVersion() {
        let rr = RRQuality.correct([])
        let gated = RRQuality.gated([])
        let hrvTime = HRVTime.derive([])
        let hrvFrequency = HRVFrequency.derive(intervals: [], beatTimesMilliseconds: [], artifactFraction: 1)
        let nocturnal = NocturnalMetrics.restingHeartRate([])
        let dip = NocturnalMetrics.heartRateDip(daySamples: [], nightSamples: [])
        let rsa = Respiration.rsaRate(intervals: [], beatTimesMilliseconds: [], artifactFraction: 1)
        let riiv = Respiration.riivRate(adc: [], timestampsSeconds: [])
        let fused = Respiration.fuse(rsa: rsa, riiv: riiv)
        let brv = Respiration.variability([])

        XCTAssertEqual(rr.algorithmVersion, AnalyticsAlgorithmVersion.rrQuality)
        XCTAssertEqual(gated.algorithmVersion, AnalyticsAlgorithmVersion.rrQuality)
        XCTAssertEqual(hrvTime.algorithmVersion, AnalyticsAlgorithmVersion.hrv)
        XCTAssertEqual(hrvFrequency.algorithmVersion, AnalyticsAlgorithmVersion.hrv)
        XCTAssertEqual(nocturnal.algorithmVersion, AnalyticsAlgorithmVersion.nocturnal)
        XCTAssertEqual(dip.algorithmVersion, AnalyticsAlgorithmVersion.nocturnal)
        XCTAssertEqual(rsa.algorithmVersion, AnalyticsAlgorithmVersion.respiration)
        XCTAssertEqual(riiv.algorithmVersion, AnalyticsAlgorithmVersion.respiration)
        XCTAssertEqual(fused.algorithmVersion, AnalyticsAlgorithmVersion.respiration)
        XCTAssertEqual(brv.algorithmVersion, AnalyticsAlgorithmVersion.respiration)
    }

    func test_repeatedRespirationDerivationsDoNotMutateOrDuplicateState() {
        let rsaInputs = Array(repeating: 800.0, count: 19)
        let rsaTimes = rsaInputs.indices.map { Double($0) * 800 }
        let firstRSA = Respiration.rsaRate(intervals: rsaInputs, beatTimesMilliseconds: rsaTimes, artifactFraction: 0)
        let secondRSA = Respiration.rsaRate(intervals: rsaInputs, beatTimesMilliseconds: rsaTimes, artifactFraction: 0)
        let firstRIIV = Respiration.riivRate(adc: Array(repeating: 1.0, count: 29), timestampsSeconds: (0..<29).map { Double($0) })
        let secondRIIV = Respiration.riivRate(adc: Array(repeating: 1.0, count: 29), timestampsSeconds: (0..<29).map { Double($0) })
        XCTAssertEqual(firstRSA, secondRSA)
        XCTAssertEqual(firstRIIV, secondRIIV)
        XCTAssertEqual(Respiration.fuse(rsa: firstRSA, riiv: firstRIIV), Respiration.fuse(rsa: secondRSA, riiv: secondRIIV))
    }
}

final class HRVCancellationTests: XCTestCase {
    func test_cancellationIsObservedByBackgroundDerivationWithoutMainActorRequirement() async {
        let task = Task { () throws -> AnalyticsMetric<HRVTimeValue> in
            try await CancellableAnalytics.hrvTime(Array(repeating: 800, count: 2_000))
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("cancelled derivation returned a partial result")
        } catch is CancellationError {
            // Expected: no metric has been persisted or surfaced.
        } catch {
            XCTFail("unexpected cancellation error: \(error)")
        }
    }

    func test_scriptedCancellationLeavesNoPartialPersistedState() async {
        let persistence = AnalyticsPersistenceProbe()
        let task = Task { () throws -> Void in
            let metric = try await CancellableAnalytics.hrvFrequency(
                intervals: Array(repeating: 800, count: 2_000),
                beatTimesMilliseconds: Array(0..<2_000).map { Double($0) * 800 },
                artifactFraction: 0
            )
            try Task.checkCancellation()
            guard metric.present else { return }
            await persistence.persist()
        }

        // The wrapper yields before deriving and checks again before returning;
        // cancelling this scripted run must therefore prevent the only write
        // after the derivation from occurring.
        task.cancel()
        do {
            try await task.value
            XCTFail("cancelled derivation returned without cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("unexpected cancellation error: \(error)")
        }
        let persistedCount = await persistence.count()
        XCTAssertEqual(persistedCount, 0)
    }

    func test_rrQualityCancellationIsObservedBeforeAResultCanBePublished() async {
        let task = Task { () throws -> RRCorrectionResult in
            try await CancellableAnalytics.rrQuality(Array(repeating: 800, count: 2_000))
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("cancelled RR derivation returned a result")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("unexpected cancellation error: \(error)")
        }
    }

    func test_respirationCancellationIsObservedBeforeAResultCanBePublished() async {
        let task = Task { () throws -> AnalyticsMetric<RespiratoryEstimate> in
            try await CancellableAnalytics.rsaRespiration(
                intervals: Array(repeating: 800, count: 2_000),
                beatTimesMilliseconds: Array(0..<2_000).map { Double($0) * 800 },
                artifactFraction: 0
            )
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("cancelled respiration derivation returned a result")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("unexpected cancellation error: \(error)")
        }
    }
}
