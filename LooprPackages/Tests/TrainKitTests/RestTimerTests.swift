import Foundation
import Testing
import TrainKit

/// The rest timer is an end date. Every answer comes from the `now` the test passes.
struct RestTimerTests {
    private let start = TrainFixture.date
    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    @Test func countsDownFromTheEndDateAndRoundsUp() {
        let timer = RestTimer(startingAt: start, seconds: 150)
        #expect(timer.endsAt == at(150) && timer.totalSeconds == 150)
        #expect(timer.remainingSeconds(at: start) == 150)
        #expect(timer.remainingSeconds(at: at(45)) == 105)
        #expect(timer.remainingSeconds(at: at(149.2)) == 1)
        #expect(timer.remainingSeconds(at: at(150)) == 0)
        #expect(timer.remainingSeconds(at: at(500)) == 0)
        #expect(!timer.isExpired(at: at(149.9)) && timer.isExpired(at: at(150)))
        #expect(timer.fractionRemaining(at: at(75)) == 0.5)
        #expect(timer.fractionRemaining(at: at(500)) == 0)
    }

    @Test func aTimerEarlierThanItsStartReadsFullAndAZeroRestIsAlreadyOver() {
        let timer = RestTimer(startingAt: start, seconds: 60)
        #expect(timer.remainingSeconds(at: at(-30)) == 90)
        #expect(timer.fractionRemaining(at: at(-30)) == 1)
        let none = RestTimer(startingAt: start, seconds: 0)
        #expect(none.isExpired(at: start) && none.fractionRemaining(at: start) == 0)
        #expect(RestTimer(startingAt: start, seconds: -4).totalSeconds == 0)
        #expect(RestTimer(startingAt: start, seconds: 99_999).totalSeconds == Double(RestTimer.maximumSeconds))
    }

    @Test func thirtySecondsExtendTheEndDateAndTheRing() {
        var timer = RestTimer(startingAt: start, seconds: 150)
        timer.extend(now: at(100))
        #expect(timer.endsAt == at(180) && timer.totalSeconds == 180)
        #expect(timer.remainingSeconds(at: at(100)) == 80)
        #expect(RestTimer.extensionSeconds == 30)
        timer.extend(bySeconds: 15, now: at(100))
        #expect(timer.endsAt == at(195))
    }

    @Test func extendingAfterTheRestEndedStartsAFreshCountdownAndRearmsTheCue() {
        var timer = RestTimer(startingAt: start, seconds: 2)
        let claim1 = timer.claimCue(at: at(3))
        #expect(claim1)
        timer.extend(now: at(10))
        #expect(timer.startedAt == at(10) && timer.endsAt == at(40) && timer.totalSeconds == 30)
        #expect(timer.remainingSeconds(at: at(10)) == 30)
        #expect(!timer.cueClaimed)
        let claim2 = timer.claimCue(at: at(41))
        #expect(claim2)
    }

    @Test func theCueIsClaimedOnceAndOnlyAfterTheEnd() {
        var timer = RestTimer(startingAt: start, seconds: 10)
        let claim3 = timer.claimCue(at: at(9.9))
        #expect(!claim3)
        let claim4 = timer.claimCue(at: at(10))
        #expect(claim4)
        let claim5 = timer.claimCue(at: at(11))
        #expect(!claim5)
        let claim6 = timer.claimCue(at: at(12))
        #expect(!claim6)
    }

    @Test func aTimerRightAfterBackgroundingStillBuzzesButALateOneStaysQuiet() {
        // The app was suspended and the end date passed while it slept. The anchor answers on return.
        var soon = RestTimer(startingAt: start, seconds: 60)
        #expect(soon.remainingSeconds(at: at(75)) == 0)
        let claim7 = soon.claimCue(at: at(75))
        #expect(claim7)
        var late = RestTimer(startingAt: start, seconds: 60)
        let claim8 = late.claimCue(at: at(60 + RestTimer.cueGraceSeconds + 1))
        #expect(!claim8)
        // The stale cue is used up, so it cannot fire on a later look.
        let claim9 = late.claimCue(at: at(70))
        #expect(!claim9 && late.cueClaimed)
    }

    @Test func extendingWhileRunningNeverPassesTheMaximum() {
        var timer = RestTimer(startingAt: start, seconds: RestTimer.maximumSeconds)
        timer.extend(now: at(10))
        #expect(timer.endsAt == at(10 + Double(RestTimer.maximumSeconds)))
    }

    @Test func roundTripsThroughJSONSoARestSurvivesARelaunch() throws {
        var timer = RestTimer(startingAt: start, seconds: 90)
        timer.extend(now: at(5))
        let decoded = try JSONDecoder().decode(RestTimer.self, from: JSONEncoder().encode(timer))
        // 90 s plus 30 s from the extension ends at 120 s, so 90 s are left at 30 s.
        #expect(decoded == timer && decoded.remainingSeconds(at: at(30)) == 90)
    }
}
