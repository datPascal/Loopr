import Foundation
import Testing
@testable import AnalyticsKit

struct SmartWakeDetectorTests {
    private let opened = Date(timeIntervalSince1970: 1_790_000_000)

    private func window(minutes: Int = 30, baseline: Double? = 50) -> SmartWakeWindow {
        SmartWakeWindow(
            earliest: opened,
            latest: opened.addingTimeInterval(TimeInterval(minutes * 60)),
            sleepingBaselineBPM: baseline
        )
    }

    /// One sample a second, ending at `now`.
    private func samples(
        endingAt now: Date,
        seconds: Int,
        bpm: Double,
        motion: Double? = nil
    ) -> [SmartWakeSample] {
        (0..<seconds).map { offset in
            SmartWakeSample(
                at: now.addingTimeInterval(TimeInterval(-offset)),
                heartRateBPM: bpm,
                motion: motion
            )
        }
    }

    @Test
    func nothingFiresBeforeTheWindowOpens() {
        let decision = SmartWakeDetector.decide(
            samples: samples(endingAt: opened.addingTimeInterval(-60), seconds: 120, bpm: 90),
            window: window(),
            now: opened.addingTimeInterval(-60)
        )
        #expect(decision == .wait("The wake window has not opened yet."))
    }

    @Test
    func theWindowEndAlwaysFires() {
        // No samples at all, which is what a dropped link looks like. The end
        // of the window is the promise, so it has to fire anyway.
        let decision = SmartWakeDetector.decide(
            samples: [],
            window: window(),
            now: opened.addingTimeInterval(30 * 60)
        )
        #expect(decision.shouldFire)
    }

    @Test
    func aThinStreamWaitsInsteadOfGuessing() {
        let now = opened.addingTimeInterval(300)
        let decision = SmartWakeDetector.decide(
            samples: samples(endingAt: now, seconds: 3, bpm: 90),
            window: window(),
            now: now
        )
        #expect(decision == .wait("Not enough live data from your strap to read your sleep."))
    }

    @Test
    func aSettledSleeperIsLeftAlone() {
        let now = opened.addingTimeInterval(300)
        let decision = SmartWakeDetector.decide(
            samples: samples(endingAt: now, seconds: 240, bpm: 50),
            window: window(),
            now: now
        )
        #expect(!decision.shouldFire)
    }

    @Test
    func aRiseAboveTheSleepingBaselineWakesEarly() {
        let now = opened.addingTimeInterval(300)
        // Two minutes at 60 bpm over a 50 bpm night. The threshold is
        // 50 + max(4, 4) = 54, so this clears it.
        var stream = samples(endingAt: now.addingTimeInterval(-121), seconds: 120, bpm: 50)
        stream += samples(endingAt: now, seconds: 60, bpm: 60)
        let decision = SmartWakeDetector.decide(samples: stream, window: window(), now: now)
        #expect(decision.shouldFire)
        #expect(decision.reason.contains("60 bpm"))
    }

    @Test
    func aRiseThatDoesNotClearTheThresholdWaits() {
        let now = opened.addingTimeInterval(300)
        var stream = samples(endingAt: now.addingTimeInterval(-121), seconds: 120, bpm: 50)
        // 53 bpm is under the 54 bpm threshold, so it is noise, not a wake.
        stream += samples(endingAt: now, seconds: 60, bpm: 53)
        #expect(!SmartWakeDetector.decide(samples: stream, window: window(), now: now).shouldFire)
    }

    @Test
    func aHighSleeperGetsTheSameSensitivityAsALowOne() {
        let now = opened.addingTimeInterval(300)
        // 70 bpm baseline: the threshold is 70 + max(4, 5.6) = 75.6, so the
        // proportional rule is what binds, not the flat 4 bpm.
        let stream = samples(endingAt: now, seconds: 60, bpm: 75)
        #expect(!SmartWakeDetector.decide(
            samples: stream, window: window(baseline: 70), now: now
        ).shouldFire)
        #expect(SmartWakeDetector.decide(
            samples: samples(endingAt: now, seconds: 60, bpm: 76),
            window: window(baseline: 70),
            now: now
        ).shouldFire)
    }

    @Test
    func movementWakesEvenWithAFlatHeartRate() {
        let now = opened.addingTimeInterval(300)
        var stream = samples(endingAt: now.addingTimeInterval(-121), seconds: 120, bpm: 50)
        stream += samples(endingAt: now, seconds: 60, bpm: 50, motion: 0.9)
        let decision = SmartWakeDetector.decide(samples: stream, window: window(), now: now)
        #expect(decision == .fireNow("You are moving, so you are close to waking anyway."))
    }

    @Test
    func aDerivedBaselineNeedsEnoughHistoryFirst() {
        let now = opened.addingTimeInterval(300)
        // No baseline supplied and only ten older samples.
        var stream = samples(endingAt: now.addingTimeInterval(-121), seconds: 10, bpm: 50)
        stream += samples(endingAt: now, seconds: 60, bpm: 70)
        #expect(SmartWakeDetector.decide(
            samples: stream, window: window(baseline: nil), now: now
        ) == .wait("Loopr has no sleeping heart rate to compare tonight against yet."))

        // With enough history it derives one and fires on the same rise.
        var longer = samples(endingAt: now.addingTimeInterval(-121), seconds: 300, bpm: 50)
        longer += samples(endingAt: now, seconds: 60, bpm: 70)
        #expect(SmartWakeDetector.decide(
            samples: longer, window: window(baseline: nil), now: now
        ).shouldFire)
    }

    @Test
    func theQuietBaselineSitsBelowTheStirs() {
        let now = opened
        var stream = samples(endingAt: now, seconds: 60, bpm: 48)
        stream += samples(endingAt: now.addingTimeInterval(-100), seconds: 40, bpm: 80)
        // Three quarters of the night is 48 bpm, so the quarter point is 48
        // even with forty high samples mixed in.
        #expect(SmartWakeDetector.quietBaseline(stream) == 48)
        #expect(SmartWakeDetector.quietBaseline(Array(stream.prefix(5))) == nil)
    }
}
