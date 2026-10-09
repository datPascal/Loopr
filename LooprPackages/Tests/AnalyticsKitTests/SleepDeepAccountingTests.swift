import XCTest
@testable import AnalyticsKit

/// Regression cover for the "0 minutes of deep sleep every night" defect.
///
/// The stager always produced deep epochs, but the segmentation counted deep
/// and light from the three-class labels, which never contain deep. Every
/// night therefore reported 0 minutes deep and all of NREM as light, while the
/// hypnogram, drawn from the four-class labels, showed deep blocks. Two real
/// nights read 0 minutes deep; the pinned OpenStrap segmenter gives 66 and 67.
final class SleepDeepAccountingTests: XCTestCase {
    private static let midnight: TimeInterval = 1_735_689_600 // 2025-01-01T00:00:00Z

    /// Six hours in bed, perfectly still, in 30-minute cycles: ten quiet
    /// minutes (slow, very regular heart) and twenty livelier minutes. The
    /// quiet stretches are the cardiac trough the stager calls deep.
    private func cyclingNight() -> SleepInputSnapshot {
        let start = Self.midnight
        let seconds = 6 * 3_600
        let gravity = (0..<seconds).map { SleepAccelerationSample(timestamp: start + Double($0), x: 0, y: 0, z: 1) }
        func isQuiet(_ offset: Double) -> Bool { Int(offset / 60) % 30 < 10 }
        let heart = (0..<seconds).map { second -> SleepHeartRateSample in
            let offset = Double(second)
            let bpm = isQuiet(offset) ? 52 + Double(second % 2) : 57 + 3 * sin(offset * 0.5)
            return SleepHeartRateSample(timestamp: start + offset, bpm: bpm)
        }
        var rr: [SleepRRInterval] = []
        var clock = 0.0
        var beat = 0.0
        while clock < Double(seconds) {
            let interval = isQuiet(clock)
                ? 1_150 + 4 * sin(beat * 1.8)
                : 1_000 + 80 * sin(beat * 1.3) + 40 * sin(beat * 0.37)
            // Packet timestamps are whole seconds, as on the strap.
            rr.append(SleepRRInterval(timestamp: start + floor(clock), milliseconds: interval))
            clock += interval / 1_000
            beat += 1
        }
        return SleepInputSnapshot(acceleration: gravity, heartRate: heart, rr: rr, timeZoneIdentifier: "UTC")
    }

    func testSegmentationCountsDeepFromTheFourClassLabels() {
        let segmentation = SleepAnalytics.segment(cyclingNight())
        XCTAssertNotNil(segmentation.window)
        let deepInLabels = segmentation.stages4.filter { $0 == .deep }.count
        XCTAssertGreaterThan(deepInLabels, 0, "the synthetic night must contain a cardiac trough the stager calls deep")
        XCTAssertEqual(segmentation.deepSeconds, deepInLabels)
        XCTAssertEqual(segmentation.lightSeconds, segmentation.stages4.filter { $0 == .light }.count)
        XCTAssertEqual((segmentation.lightSeconds ?? 0) + (segmentation.deepSeconds ?? 0), segmentation.nremSeconds)
        XCTAssertEqual((segmentation.nremSeconds ?? 0) + (segmentation.remSeconds ?? 0), segmentation.totalSleepSeconds)
    }

    func testHypnogramSummaryCarriesTheDeepMinutes() async throws {
        let derivation = try await SleepAnalytics.derive(cyclingNight())
        let deepSeconds = try XCTUnwrap(derivation.segmentation.deepSeconds)
        XCTAssertGreaterThan(deepSeconds, 0)
        let hypnogram = try XCTUnwrap(derivation.hypnogram)
        XCTAssertEqual(hypnogram.deepMinutes, Double(deepSeconds) / 60, accuracy: 1e-9)
        XCTAssertEqual(hypnogram.lightMinutes, Double(derivation.segmentation.lightSeconds ?? 0) / 60, accuracy: 1e-9)
        XCTAssertEqual(hypnogram.remMinutes, Double(derivation.segmentation.remSeconds ?? 0) / 60, accuracy: 1e-9)
    }

    /// A three-class caller (no `stages4`) keeps its old meaning: NREM is light.
    func testThreeClassOnlySegmentationStillSplitsNREMAsLight() {
        let segmentation = SleepAnalytics.segment(cyclingNight())
        let threeClass = segmentation.stages
        XCTAssertFalse(threeClass.contains(.deep), "the stager's three-class labels never carry deep")
        XCTAssertFalse(threeClass.contains(.light))
    }

    /// An epoch with fewer than two heart-rate samples has a within-epoch SD
    /// of 0. That is a gap, not the steadiest heart of the night, and it must
    /// not vote for deep sleep. A measured quiet epoch still does.
    func testUnmeasuredHeartRateSpreadIsNotADeepVote() throws {
        let count = 60
        let spread: [Double] = (0..<count).map { index in
            switch index {
            case 20..<30: 0 // fewer than two HR samples: not measured
            case 30..<40: 0.1 // measured, very steady
            default: [0.95, 1.0, 1.05][index % 3]
            }
        }
        let nan = [Double](repeating: .nan, count: count)
        let features = SleepCardioEpochFeatures(
            motion: [Double](repeating: 0, count: count),
            heartRate: [Double](repeating: 55, count: count),
            heartRateSD: spread, rmssd: nan, lfHF: nan, rk: nan, sdnn: nan
        )
        let result = try XCTUnwrap(SleepCardioStager.classify(features).value)
        XCTAssertFalse(result.stages4[20..<30].contains(.deep), "a data gap scored as deep sleep")
        XCTAssertTrue(result.stages4[30..<40].allSatisfy { $0 == .deep }, "a measured cardiac trough must still read as deep")
    }

    /// The RR gate compares each beat with the one before it. Comparing with
    /// the last accepted beat instead let one early outlier reject every
    /// later beat of the window.
    func testRRGateRecoversAfterAnOutlierOpensTheWindow() {
        var values: [Double] = [1_600]
        values += (0..<40).map { 1_000 + 5 * sin(Double($0)) }
        let samples = values.enumerated().map { SleepRRInterval(timestamp: Double($0.offset), milliseconds: $0.element) }
        let clean = SleepCardioStager.cleanRR(samples, times: samples.map(\.timestamp), center: 20, halfWindow: 100)
        // The outlier opens the window and the first normal beat after it is
        // dropped with it, exactly as in the pinned gate. Everything after
        // that is kept.
        XCTAssertEqual(clean.count, values.count - 1)
        XCTAssertEqual(clean.dropFirst().filter { abs($0.milliseconds - 1_000) > 10 }.count, 0)
    }

    /// A beat outside 300-2000 ms breaks the successive-difference chain, so
    /// the next beat is judged on its own, as in the pinned gate.
    func testRRGateRestartsAfterAnOutOfRangeBeat() {
        let values: [Double] = [1_000, 1_010, 2_500, 1_300, 1_305, 1_310, 1_300]
        let samples = values.enumerated().map { SleepRRInterval(timestamp: Double($0.offset), milliseconds: $0.element) }
        let clean = SleepCardioStager.cleanRR(samples, times: samples.map(\.timestamp), center: 3, halfWindow: 10)
        XCTAssertEqual(clean.map(\.milliseconds), [1_000, 1_010, 1_300, 1_305, 1_310, 1_300])
    }

    // MARK: - Sleep cycles

    /// Eight hours whose beat-to-beat variability rises and falls on a
    /// 90-minute rhythm, with a small 24-minute ripple on top.
    private func ultradianNight(ripple: Double) -> [SleepRRInterval] {
        var beats: [SleepRRInterval] = []
        var clock = 0.0, sign = 1.0
        while clock < 8 * 3_600 {
            let minute = clock / 60
            let amplitude = 15 + 10 * sin(2 * .pi * minute / 90) + ripple * sin(2 * .pi * minute / 24)
            let interval = 1_000 + sign * amplitude
            beats.append(SleepRRInterval(timestamp: Self.midnight + clock, milliseconds: interval))
            clock += interval / 1_000
            sign = -sign
        }
        return beats
    }

    func testCyclesFollowTheNinetyMinuteRhythmNotItsRipple() throws {
        for ripple in [0.0, 3.0] {
            let result = try XCTUnwrap(SleepAnalytics.detectCycles(ultradianNight(ripple: ripple), onset: Self.midnight, offset: Self.midnight + 8 * 3_600))
            XCTAssertTrue((2...5).contains(result.cycles.count), "ripple \(ripple): \(result.cycles.count) cycles in eight hours")
            for cycle in result.cycles {
                XCTAssertTrue((80...100).contains(cycle.lengthMinute), "ripple \(ripple): a \(cycle.lengthMinute)-minute cycle")
            }
        }
    }

    /// Two real nights read 20 and 19 cycles because every local maximum
    /// twenty minutes after the last one counted. A peak has to stand out
    /// from the troughs around it.
    func testCyclePeaksNeedProminence() {
        let wave: [Double?] = (0..<480).map { minute in
            let t = Double(minute)
            return 1.5 * sin(2 * .pi * t / 90) + 0.2 * sin(2 * .pi * t / 24)
        }
        let peaks = SleepAnalytics.cyclePeaks(wave, minimumDistance: 20, minimumProminence: 0.9)
        XCTAssertTrue((4...6).contains(peaks.count), "\(peaks.count) peaks in eight hours of a 90-minute wave")
        // The ripple nudges each crest by up to about a tenth of the period
        // (the first pair lands 79 minutes apart), but never splits a cycle
        // into ripple-sized pieces.
        for pair in zip(peaks.dropFirst(), peaks) {
            XCTAssertTrue((75...105).contains(pair.0 - pair.1), "peaks \(pair.1) and \(pair.0)")
        }
        // A missing minute is not a trough and not a peak.
        var gapped = wave
        for index in 100..<110 { gapped[index] = nil }
        XCTAssertFalse(SleepAnalytics.cyclePeaks(gapped, minimumDistance: 20, minimumProminence: 0.9).contains { (100..<110).contains($0) })
    }

    /// A night whose variability never rises and falls back has no readable
    /// cycles. That is absent, not "0 cycles".
    func testFlatNightReportsNoCyclesRatherThanZero() async throws {
        var input = cyclingNight()
        var clock = 0.0, sign = 1.0, beats: [SleepRRInterval] = []
        while clock < 6 * 3_600 {
            // Variability climbs steadily all night: no peak, so no cycle.
            let amplitude = 10 + 20 * clock / (6 * 3_600)
            beats.append(SleepRRInterval(timestamp: Self.midnight + floor(clock), milliseconds: 1_000 + amplitude * sign))
            clock += 1; sign = -sign
        }
        input = SleepInputSnapshot(acceleration: input.acceleration, heartRate: input.heartRate, rr: beats, timeZoneIdentifier: "UTC")
        let derivation = try await SleepAnalytics.derive(input)
        XCTAssertNotNil(derivation.segmentation.window)
        XCTAssertNil(derivation.cycles)
    }
}
