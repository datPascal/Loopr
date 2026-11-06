import Foundation
import ProtocolKit
import Testing
import TrainKit
@testable import Loopr

/// The end of a rest buzzes the band once. Time is a clock the test moves by hand, and the band is a
/// recording fake, so nothing here sleeps or touches hardware.
@MainActor struct TrainRestCueTests {
    private final class HandClock: @unchecked Sendable {
        private let lock = NSLock()
        private var current: Date
        init(_ start: Date = AppTrainFixtures.now) { current = start }
        func now() -> Date { lock.lock(); defer { lock.unlock() }; return current }
        func advance(_ seconds: TimeInterval) { lock.lock(); current = current.addingTimeInterval(seconds); lock.unlock() }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
        func increment() { lock.lock(); value += 1; lock.unlock() }
    }

    @MainActor private struct Rig {
        let clock = HandClock()
        let band = CueRuntimeFixture()
        let haptics = Counter()
        let session: TrainLiveSession
        let scheduler: TrainRestCueScheduler

        /// - Parameter honoursSleep: True makes the fake sleep move the clock to the end date, as a real
        ///   sleep would. False never wakes, as when the app is suspended.
        init(bandCue: Bool = true, restSeconds: Int = 2, honoursSleep: Bool = true) throws {
            var template = AppTrainFixtures.upperA
            template.bandRestCue = bandCue
            let clock = clock
            let model = try TrainLiveModel(setup: TrainLiveSetup(
                template: template, restSecondsOverride: restSeconds, timeZoneIdentifier: AppTrainFixtures.zone.identifier),
                now: clock.now())
            let session = TrainLiveSession(model: model, clock: { @Sendable in clock.now() })
            let cue = TrainRestCue(delivery: BandCueDelivery(runtime: band), sessionID: session.model.session.id,
                                   queue: BandCueCommandQueue(wait: {}), haptic: { @MainActor @Sendable [haptics] in haptics.increment() })
            let sleep: TrainRestCueScheduler.Sleep = honoursSleep
                ? { @Sendable seconds in
                    guard !Task.isCancelled else { return }
                    clock.advance(seconds)
                }
                : { @Sendable _ in try? await Task.sleep(for: .seconds(3_600)) }
            let scheduler = TrainRestCueScheduler(session: session, sleep: sleep) { @MainActor @Sendable band in
                await cue.deliver(band: band)
            }
            session.onChange = { @MainActor @Sendable _ in scheduler.update() }
            self.session = session
            self.scheduler = scheduler
        }
    }

    @Test func theRestEndBuzzesTheBandOnceAndPlaysOneHaptic() async throws {
        let rig = try Rig()
        rig.session.logSet()
        #expect(rig.session.model.rest?.totalSeconds == 2)
        await rig.scheduler.waitUntilIdle()
        #expect(await rig.band.effects == [BandCuePattern.restEnd])
        #expect(rig.haptics.count == 1)
        // A foreground check, a second look from the timeline and a repeat all find the cue used up.
        await rig.scheduler.fireIfDue()
        await rig.scheduler.fireIfDue()
        rig.scheduler.update()
        await rig.scheduler.waitUntilIdle()
        #expect(await rig.band.effects == [0] && rig.haptics.count == 1)
    }

    @Test func theRestEndCueIsOneShortBuzzThatTheBandAccepts() throws {
        #expect(BandCuePattern.restEnd == BandCuePattern.single)
        #expect(BandCuePattern.restEnd != BandCuePattern.double)
        let bytes = try ProductionCommandWriter(capabilities: .confirmed(.haptic))
            .encode(.haptic(.run(sequence: 7, pattern: BandCuePattern.restEnd)))
        #expect(try FrameDecoder().decode(bytes).paddedInner == Data([0x23, 7, 0x4F, BandCuePattern.restEnd, 0, 0, 0, 0]))
    }

    @Test func addingThirtySecondsMovesTheCueToTheNewEndDate() async throws {
        let rig = try Rig()
        rig.session.logSet()
        rig.session.extendRest()
        #expect(rig.session.model.rest?.totalSeconds == 32)
        await rig.scheduler.waitUntilIdle()
        // One buzz for the one rest, at the later end date, not at the first one.
        #expect(await rig.band.effects == [0] && rig.haptics.count == 1)
        #expect(rig.clock.now() >= (rig.session.model.rest?.endsAt ?? .distantFuture))
    }

    @Test func aRestThatEndedWhileTheAppSleptBuzzesWhenItComesBackSoon() async throws {
        let rig = try Rig(honoursSleep: false)
        rig.session.logSet()
        // The app is suspended: the wait never returns. Five seconds after the end date it is active again.
        rig.clock.advance(2 + 5)
        await rig.scheduler.fireIfDue()
        #expect(await rig.band.effects == [0] && rig.haptics.count == 1)
        await rig.scheduler.fireIfDue()
        #expect(await rig.band.effects == [0])
        rig.scheduler.cancel()
    }

    @Test func aRestThatEndedLongAgoStaysQuietAndDoesNotFireLater() async throws {
        let rig = try Rig(honoursSleep: false)
        rig.session.logSet()
        rig.clock.advance(2 + RestTimer.cueGraceSeconds + 30)
        await rig.scheduler.fireIfDue()
        #expect(await rig.band.effects.isEmpty && rig.haptics.count == 0)
        rig.clock.advance(1)
        await rig.scheduler.fireIfDue()
        #expect(await rig.band.effects.isEmpty && rig.haptics.count == 0)
        rig.scheduler.cancel()
    }

    @Test func aTemplateWithTheBandCueOffStillGetsThePhoneHapticButNoBuzz() async throws {
        let rig = try Rig(bandCue: false)
        rig.session.logSet()
        await rig.scheduler.waitUntilIdle()
        #expect(await rig.band.effects.isEmpty)
        #expect(rig.haptics.count == 1)
    }

    @Test func skippingTheRestCancelsTheCue() async throws {
        let rig = try Rig(honoursSleep: false)
        rig.session.logSet()
        rig.session.endRest()
        #expect(rig.session.model.rest == nil)
        rig.clock.advance(5)
        await rig.scheduler.fireIfDue()
        #expect(await rig.band.effects.isEmpty && rig.haptics.count == 0)
    }

    @Test func addingTimeAfterTheRestEndedArmsOneMoreCue() async throws {
        let rig = try Rig()
        rig.session.logSet()
        await rig.scheduler.waitUntilIdle()
        #expect(await rig.band.effects == [0])
        // The card is still on screen at 0:00. The person adds thirty seconds and gets a second cue at its end.
        rig.session.extendRest()
        await rig.scheduler.waitUntilIdle()
        #expect(await rig.band.effects == [0, 0] && rig.haptics.count == 2)
    }

    @Test func eachSetLoggedStartsItsOwnRestAndCue() async throws {
        let rig = try Rig()
        rig.session.logSet()
        await rig.scheduler.waitUntilIdle()
        rig.session.logSet()
        await rig.scheduler.waitUntilIdle()
        #expect(await rig.band.effects == [0, 0] && rig.haptics.count == 2)
    }

    @Test func noRestAfterTheLastSetMeansNoCue() async throws {
        var template = AppTrainFixtures.upperA
        template.exercises = [template.exercises[0]]
        template.exercises[0].sets = 1
        let clock = HandClock()
        let model = try TrainLiveModel(setup: TrainLiveSetup(template: template, restSecondsOverride: 2,
                                                              timeZoneIdentifier: AppTrainFixtures.zone.identifier), now: clock.now())
        let session = TrainLiveSession(model: model, clock: { @Sendable in clock.now() })
        let fakeBand = CueRuntimeFixture()
        let scheduler = TrainRestCueScheduler(session: session, sleep: { @Sendable seconds in clock.advance(seconds) }) { @MainActor @Sendable _ in
            Issue.record("A cue fired with no rest running")
        }
        session.onChange = { @MainActor @Sendable _ in scheduler.update() }
        session.logSet()
        #expect(session.model.rest == nil && session.model.isComplete)
        await scheduler.waitUntilIdle()
        #expect(await fakeBand.effects.isEmpty)
    }

    @Test func theFixtureRestOverrideAndStoreNameAreReadFromLaunchArguments() {
        #expect(AppTrainFixtures.restSecondsOverride(arguments: ["--loopr-train-fixture-rest-seconds=2"]) == 2)
        #expect(AppTrainFixtures.restSecondsOverride(arguments: ["--loopr-train-fixture-rest-seconds=999999"]) == 3_600)
        #expect(AppTrainFixtures.restSecondsOverride(arguments: ["--loopr-train-fixture-rest-seconds=abc"]) == nil)
        #expect(AppTrainFixtures.restSecondsOverride(arguments: ["--loopr-train-fixture"]) == nil)
    }
}
