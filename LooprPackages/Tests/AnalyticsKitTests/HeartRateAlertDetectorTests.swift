import Foundation
import Testing
@testable import AnalyticsKit

/// Synthetic band history for the heart rate alert rules.
private struct Tape {
    enum Motion { case still, walking, fidget }

    /// 2026-09-22 10:00:00 UTC, on a minute boundary.
    static let origin: Int64 = 1_790_071_200
    var seconds: [HeartRateMonitorSecond] = []
    var cursor: Int64 = Tape.origin

    /// Appends `minutes` of seconds with the given band rate, motion and RR.
    /// `rrBPM` nil means no RR at all; otherwise beats matching that rate.
    mutating func add(
        minutes: Int,
        bpm: Double?,
        motion: Motion = .still,
        rrBPM: Double? = .nan,
        dropEvery: Int? = nil
    ) {
        let rr = rrBPM.map { $0.isNaN ? (bpm ?? 60) : $0 }
        var beatClock = 0.0
        for index in 0..<(minutes * 60) {
            let t = cursor
            cursor += 1
            let dropped = dropEvery.map { index % $0 == 0 } ?? false
            let (x, y, z) = gravity(t, motion: motion)
            var beats: [Int] = []
            if let rr, !dropped {
                let interval = 60_000 / rr
                beatClock += 1000
                while beatClock >= interval {
                    beatClock -= interval
                    // A few ms of natural variation so no interval repeats.
                    beats.append(Int(interval.rounded()) + [0, 3, -2, 5, -4, 1, -3][(beats.count + Int(t % 7)) % 7])
                }
            }
            seconds.append(HeartRateMonitorSecond(
                timestamp: t,
                heartRate: dropped ? nil : bpm,
                gravityX: x, gravityY: y, gravityZ: z,
                rrIntervalsMilliseconds: beats
            ))
        }
    }

    mutating func gap(minutes: Int) { cursor += Int64(minutes * 60) }

    private func gravity(_ t: Int64, motion: Motion) -> (Double, Double, Double) {
        switch motion {
        case .still:
            // Sub-milligram jitter, like the snapshot's sleeping minutes.
            let jitter = Double(t % 5) * 0.0002
            return (0.002 + jitter, 0.2, -0.98)
        case .fidget:
            // About 0.08 g a second: more than still, less than walking.
            let jitter = t % 2 == 0 ? 0.04 : -0.04
            return (0.002 + jitter, 0.2, -0.98)
        case .walking:
            // Arm swing: the vector swings by about 0.3 g second to second.
            let swing = t % 2 == 0 ? 0.15 : -0.15
            return (0.3 + swing, 0.2 - swing, -0.9)
        }
    }
}

private func utcCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
}

private let highOn = HeartRateAlertSettings(highEnabled: true, highThresholdBPM: 120, lowEnabled: true, lowThresholdBPM: 40)

private func run(
    _ tape: Tape,
    settings: HeartRateAlertSettings = highOn,
    state: HeartRateAlertState = .initial,
    now: Int64? = nil,
    workouts: [Range<Int64>] = [],
    sleep: [Range<Int64>] = [],
    openEpisodes: [HeartRateAlertEpisode] = [],
    parameters: HeartRateAlertParameters = .standard
) -> HeartRateAlertEvaluation {
    HeartRateAlertDetector.evaluate(
        seconds: tape.seconds,
        settings: settings,
        state: state,
        context: HeartRateAlertContext(now: now ?? tape.cursor, calendar: utcCalendar(),
                                       workouts: workouts, sleep: sleep),
        openEpisodes: openEpisodes,
        parameters: parameters
    )
}

struct HeartRateAlertDetectorTests {
    @Test func stillAndHighForTenMinutesAlertsAtTheTenMinuteMark() {
        var tape = Tape()
        tape.add(minutes: 12, bpm: 132)
        let result = run(tape)
        #expect(result.alerts.count == 1)
        let alert = try! #require(result.alerts.first)
        #expect(alert.kind == .high)
        #expect(alert.detectedAt == Tape.origin + 600)
        #expect(alert.start == Tape.origin)
        #expect(alert.thresholdBPM == 120)
        #expect(abs((alert.confirmationBPM ?? 0) - 132) < 3)
        // The episode keeps running while the windows keep qualifying.
        #expect(alert.end == Tape.origin + 720)
        #expect(result.nextState.high.armed == false)
    }

    @Test func sevenMinutesIsNotEnough() {
        // Eight of ten minutes past the threshold is the least a window takes.
        var tape = Tape()
        tape.add(minutes: 7, bpm: 135)
        tape.add(minutes: 7, bpm: 70)
        #expect(run(tape).alerts.isEmpty)
    }

    @Test func walkingWithAHighHeartRateDoesNotAlert() {
        var tape = Tape()
        tape.add(minutes: 20, bpm: 128, motion: .walking)
        let result = run(tape)
        #expect(result.alerts.isEmpty)
        #expect(result.candidates.isEmpty)
    }

    @Test func oneFidgetMinuteIsStillRestButTwoAreNot() {
        var oneFidget = Tape()
        oneFidget.add(minutes: 5, bpm: 130)
        oneFidget.add(minutes: 1, bpm: 130, motion: .fidget)
        oneFidget.add(minutes: 4, bpm: 130)
        #expect(run(oneFidget).alerts.count == 1)

        var twoFidgets = Tape()
        twoFidgets.add(minutes: 3, bpm: 130)
        twoFidgets.add(minutes: 1, bpm: 130, motion: .fidget)
        twoFidgets.add(minutes: 3, bpm: 130)
        twoFidgets.add(minutes: 1, bpm: 130, motion: .fidget)
        twoFidgets.add(minutes: 2, bpm: 130)
        #expect(run(twoFidgets).alerts.isEmpty)
    }

    @Test func heartRateCoverageBelowEightyPercentDoesNotAlert() {
        var sparse = Tape()
        // Every third second missing: 67% coverage.
        sparse.add(minutes: 15, bpm: 130, dropEvery: 3)
        #expect(run(sparse).alerts.isEmpty)

        var mostlyCovered = Tape()
        // Every tenth second missing: 90% coverage.
        mostlyCovered.add(minutes: 12, bpm: 130, dropEvery: 10)
        #expect(run(mostlyCovered).alerts.count == 1)
    }

    @Test func aGapInTheMiddleBreaksTheWindow() {
        var tape = Tape()
        tape.add(minutes: 6, bpm: 130)
        tape.gap(minutes: 5)
        tape.add(minutes: 6, bpm: 130)
        #expect(run(tape).alerts.isEmpty)
    }

    @Test func beatToBeatDisagreementRejectsCadenceLockAndHalving() {
        // The optical rate says 130 while the beats say 74: cadence lock or
        // an artifact like the one in the device snapshot.
        var locked = Tape()
        locked.add(minutes: 12, bpm: 130, rrBPM: 74)
        let lockedResult = run(locked)
        #expect(lockedResult.alerts.isEmpty)
        #expect(lockedResult.candidates.allSatisfy { $0.skip == .beatToBeatDisagrees })
        #expect(!lockedResult.candidates.isEmpty)

        // Low rate from missed beats: the band halves 88 to 38.
        var halved = Tape()
        halved.add(minutes: 12, bpm: 38, rrBPM: 88)
        #expect(run(halved).alerts.isEmpty)
    }

    @Test func missingRRNeverAlertsWhileConfirmationIsRequired() {
        var tape = Tape()
        tape.add(minutes: 12, bpm: 130, rrBPM: nil)
        let result = run(tape)
        #expect(result.alerts.isEmpty)
        #expect(result.candidates.first?.skip == .unconfirmed)

        var relaxed = HeartRateAlertParameters.standard
        relaxed.requiresBeatToBeatConfirmation = false
        #expect(run(tape, parameters: relaxed).alerts.count == 1)
    }

    @Test func placeholderRRRunsAreNotConfirmation() {
        // Runs of 500 ms, the band's lost-beat placeholder, look like 120 bpm.
        let placeholder = Array(repeating: 500, count: 400)
        #expect(HeartRateAlertDetector.confirm(rr: placeholder, bandMedian: 121) == .inconsistent)
        let mixed = (0..<400).map { $0 % 2 == 0 ? 333 : 500 }
        #expect(!HeartRateAlertDetector.confirm(rr: mixed, bandMedian: 121).confirms)
    }

    @Test func rearmsOnlyAfterThirtyNormalMinutes() {
        var tape = Tape()
        tape.add(minutes: 12, bpm: 130)   // alert 1
        tape.add(minutes: 20, bpm: 70)    // normal, but only 20 minutes
        tape.add(minutes: 12, bpm: 130)   // disarmed
        tape.add(minutes: 31, bpm: 70)    // re-arms
        tape.add(minutes: 12, bpm: 130)   // alert 2
        let result = run(tape)
        #expect(result.alerts.count == 2)
        #expect(result.candidates.contains { $0.skip == .disarmed })
    }

    @Test func atMostTwoAlertsPerKindPerDay() {
        var tape = Tape()
        for _ in 0..<3 {
            tape.add(minutes: 12, bpm: 130)
            tape.add(minutes: 35, bpm: 70)
        }
        // The whole tape is one offload here, so widen freshness past its
        // 141 minutes; the daily limit is what is under test.
        var parameters = HeartRateAlertParameters.standard
        parameters.freshnessSeconds = 86_400
        let result = run(tape, parameters: parameters)
        #expect(result.alerts.count == 2)
        #expect(result.candidates.contains { $0.skip == .dailyLimit })

        // The next day starts a new allowance.
        var nextDay = Tape()
        nextDay.cursor = Tape.origin + 86_400
        nextDay.add(minutes: 12, bpm: 130)
        let tomorrow = run(nextDay, state: result.nextState)
        #expect(tomorrow.alerts.count == 1)
    }

    @Test func staleBacklogNeverAlerts() {
        var tape = Tape()
        tape.add(minutes: 12, bpm: 130)
        let threeHoursLater = tape.cursor + 3 * 3600
        let result = run(tape, now: threeHoursLater)
        #expect(result.alerts.isEmpty)
        #expect(result.candidates.contains { $0.skip == .stale })
        // A stale episode does not disarm the kind either.
        #expect(result.nextState.high.armed)
    }

    @Test func lowHeartRateDuringSleepIsIgnoredUnlessIncluded() {
        var tape = Tape()
        tape.add(minutes: 15, bpm: 38)
        let sleep = [Tape.origin - 3600 ..< tape.cursor + 3600]
        let excluded = run(tape, sleep: sleep)
        #expect(excluded.alerts.isEmpty)
        #expect(excluded.candidates.contains { $0.skip == .sleep })

        var included = highOn
        included.lowIncludesSleep = true
        let alerted = run(tape, settings: included, sleep: sleep)
        #expect(alerted.alerts.count == 1)
        #expect(alerted.alerts.first?.kind == .low)
        #expect(alerted.alerts.first?.duringSleep == true)
    }

    @Test func longStillStretchCountsAsSleepWithoutDerivedSleep() {
        var tape = Tape()
        tape.add(minutes: 60, bpm: 52)
        tape.add(minutes: 15, bpm: 38)
        let result = run(tape)
        #expect(result.alerts.isEmpty)
        #expect(result.candidates.contains { $0.skip == .sleep })

        // Awake and resting, not an hour of stillness: the low alert fires.
        var awake = Tape()
        awake.add(minutes: 15, bpm: 38)
        #expect(run(awake).alerts.first?.kind == .low)
    }

    @Test func highHeartRateDuringSleepStillAlerts() {
        var tape = Tape()
        tape.add(minutes: 12, bpm: 125)
        let sleep = [Tape.origin - 3600 ..< tape.cursor + 3600]
        #expect(run(tape, sleep: sleep).alerts.count == 1)
    }

    @Test func workoutsAndTheTenMinutesAfterAreExcluded() {
        var tape = Tape()
        tape.add(minutes: 25, bpm: 135)
        // Workout ended five minutes into the tape: the cooldown runs to
        // minute 15, so the first clean window ends at minute 25.
        let workout = [Tape.origin - 1800 ..< Tape.origin + 300]
        let result = run(tape, workouts: workout)
        #expect(result.alerts.count == 1)
        #expect(result.alerts.first?.detectedAt == Tape.origin + 25 * 60)

        let during = run(tape, workouts: [Tape.origin ..< tape.cursor])
        #expect(during.alerts.isEmpty)
        #expect(during.candidates.allSatisfy { $0.skip == .workout })
    }

    @Test func unrecordedExerciseStartsTheSameCooldown() {
        var tape = Tape()
        tape.add(minutes: 15, bpm: 140, motion: .walking)
        tape.add(minutes: 12, bpm: 128)
        // Sitting down straight after a brisk walk: no alert inside the
        // ten-minute cooldown, even though the first still window qualifies.
        let result = run(tape)
        #expect(result.alerts.isEmpty)
        #expect(result.candidates.contains { $0.skip == .workout })

        var longer = tape
        longer.add(minutes: 10, bpm: 128)
        #expect(run(longer).alerts.count == 1)
    }

    @Test func disabledKindsNeverAlert() {
        var tape = Tape()
        tape.add(minutes: 12, bpm: 130)
        let result = run(tape, settings: .off)
        #expect(result.alerts.isEmpty)
        #expect(result.candidates.contains { $0.skip == .disabled })
        #expect(HeartRateAlertSettings().highEnabled == false)
        #expect(HeartRateAlertSettings().lowEnabled == false)
        #expect(HeartRateAlertSettings().lowIncludesSleep == false)
    }

    @Test func incrementalOffloadsAlertOnceAndExtendTheEpisode() {
        var tape = Tape()
        tape.add(minutes: 11, bpm: 130)
        let first = run(tape)
        #expect(first.alerts.count == 1)
        let episode = try! #require(first.alerts.first)

        // The next offload continues the same stretch.
        var more = tape
        more.add(minutes: 6, bpm: 131)
        let second = run(more, state: first.nextState, openEpisodes: [episode])
        #expect(second.alerts.isEmpty)
        let updated = try! #require(second.updatedEpisodes.first)
        #expect(updated.id == episode.id)
        #expect(updated.end == Tape.origin + 17 * 60)
        #expect(updated.minutes.count > episode.minutes.count)

        // Re-running the same data changes nothing.
        let replay = run(more, state: second.nextState, openEpisodes: [updated])
        #expect(replay.alerts.isEmpty)
    }

    @Test func thresholdsSnapToOfferedChoices() {
        #expect(HeartRateAlertSettings(highThresholdBPM: 300).highThresholdBPM == 150)
        #expect(HeartRateAlertSettings(highThresholdBPM: 0).highThresholdBPM == 100)
        #expect(HeartRateAlertSettings(lowThresholdBPM: 47).lowThresholdBPM == 45)
    }

    @Test func settingsRoundTripThroughJSON() throws {
        let settings = HeartRateAlertSettings(highEnabled: true, highThresholdBPM: 140, lowEnabled: false,
                                              lowThresholdBPM: 50, lowIncludesSleep: true)
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(HeartRateAlertSettings.self, from: data) == settings)
        var state = HeartRateAlertState.initial
        state.high.armed = false
        state.watermark = 42
        let stateData = try JSONEncoder().encode(state)
        #expect(try JSONDecoder().decode(HeartRateAlertState.self, from: stateData) == state)
    }
}
