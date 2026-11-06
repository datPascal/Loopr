import SwiftUI
import Testing
import UIKit
@testable import DesignSystem

/// LV-01.4: ruler and dial stops with hysteresis and the haptic cap; the scrub's slot stops.
@MainActor struct LooprDetentTests {
    @Test func valuesSnapToTheNearestStop() {
        let detent = LooprDetent(range: 30...250, step: 0.1)
        #expect(detent.count == 2_201)
        #expect(detent.index(for: 78.4) == 484)
        #expect(abs(detent.value(at: 484) - 78.4) < 1e-9)
        #expect(abs(detent.snapped(78.437) - 78.4) < 1e-9)
        #expect(detent.index(for: 10) == 0)
        #expect(detent.index(for: 400) == 2_200)
        #expect(abs(detent.value(at: 99_999) - 250) < 1e-9)
        #expect(detent.index(for: .nan) == 0)
    }

    @Test func hysteresisHoldsAStopPastHalfway() {
        let detent = LooprDetent(range: 0...10, step: 1, hysteresis: 0.25)
        #expect(detent.index(for: 4.6, from: 4) == 4)
        #expect(detent.index(for: 4.74, from: 4) == 4)
        #expect(detent.index(for: 4.76, from: 4) == 5)
        #expect(detent.index(for: 3.3, from: 4) == 4)
        #expect(detent.index(for: 3.2, from: 4) == 3)
        #expect(detent.index(for: 8.9, from: 4) == 9)
        #expect(detent.index(for: 4.6, from: nil) == 5)
        #expect(detent.index(for: 4.6, from: 99) == 5)
    }

    @Test func namedMarksSitOnTheirStops() {
        let detent = LooprDetent(range: 4...10, step: 0.25, marks: [.init("Usual", at: 7.5), .init("Target", at: 8)])
        #expect(detent.mark(at: detent.index(for: 7.5))?.label == "Usual")
        #expect(detent.mark(at: detent.index(for: 8))?.label == "Target")
        #expect(detent.mark(at: detent.index(for: 6)) == nil)
    }

    @Test func eachNewStopPlaysOneHapticAtMost30ASecond() {
        var tracker = LooprDetentTracker(LooprDetent(range: 0...1_000, step: 1))
        #expect(!tracker.update(0, at: 0).plays)
        // A fling across 300 stops in one second.
        var plays = 0, changes = 0
        for index in 1...300 {
            let step = tracker.update(Double(index), at: Double(index) / 300)
            if step.changed { changes += 1 }
            if step.plays { plays += 1 }
        }
        #expect(changes == 300)
        #expect(plays <= 30)
        #expect(plays >= 29)
        // Resting on one stop plays nothing more.
        #expect(!tracker.update(300.2, at: 2).changed)
    }

    @Test func slowTurnsPlayEveryStop() {
        var tracker = LooprDetentTracker(LooprDetent(range: 0...20, step: 1))
        _ = tracker.move(to: 0, at: 0)
        let plays = (1...10).filter { tracker.move(to: $0, at: Double($0) * 0.2).plays }
        #expect(plays.count == 10)
        tracker.reset()
        #expect(tracker.current == nil)
        #expect(!tracker.move(to: 5, at: 5).plays)
    }

    @Test func scrubSlotsUseTheDetent() {
        let detent = LooprScrubGesture.detent(slots: 7)
        #expect(detent.count == 7)
        #expect(LooprScrubGesture.slotPosition(x: 20, width: 280, slots: 7) == 0)
        #expect(abs(LooprScrubGesture.slotPosition(x: 280, width: 280, slots: 7) - 6.5) < 0.0001)
        // The slot under the finger matches LooprScrubMath away from the boundaries.
        for index in 0..<7 {
            let x = LooprScrubMath.center(of: index, count: 7, width: 280)
            #expect(detent.index(for: LooprScrubGesture.slotPosition(x: x, width: 280, slots: 7)) == index)
        }
        _ = Color.clear.looprScrub(slots: 7) { _ in }
        _ = Color.clear.looprScrub { _ in }
    }

    @Test func rulerReadsItsStopsFromTheDetent() {
        let ruler = LooprRulerPicker("Weight", value: .constant(78.4), in: 30...250, unit: "kg", accent: .energy)
        #expect(ruler.detent == LooprDetent(range: 30...250, step: 0.1))
        #expect(LooprHaptic.ruleKept.feedback == .success)
        #expect(LooprHaptic.detent.feedback == .selection)
    }
}

/// LV-01.4: the press tilt follows the finger, rests where asked and stays flat under Reduce Motion.
@MainActor struct LooprPressTiltTests {
    @Test func centreIsFlatAndEdgesReachTheMaximum() {
        let size = CGSize(width: 200, height: 100)
        #expect(LooprPressTiltMath.tilt(at: CGPoint(x: 100, y: 50), in: size, maxDegrees: 4) == .flat)
        let right = LooprPressTiltMath.tilt(at: CGPoint(x: 200, y: 50), in: size, maxDegrees: 4)
        #expect(abs(right.degrees - 4) < 0.0001)
        #expect(right.axis.x == 0 && right.axis.y == 1)
        let top = LooprPressTiltMath.tilt(at: CGPoint(x: 100, y: 0), in: size, maxDegrees: 4)
        #expect(abs(top.degrees - 4) < 0.0001)
        #expect(top.axis.x == 1 && top.axis.y == 0)
        let corner = LooprPressTiltMath.tilt(at: CGPoint(x: 900, y: -400), in: size, maxDegrees: 4)
        #expect(corner.degrees <= 4.0001)
        let halfway = LooprPressTiltMath.tilt(at: CGPoint(x: 150, y: 50), in: size, maxDegrees: 4)
        #expect(abs(halfway.degrees - 2) < 0.0001)
        #expect(LooprPressTiltMath.tilt(at: .zero, in: .zero, maxDegrees: 4) == .flat)
    }

    @Test func pressReplacesTheRestingTiltAndReduceMotionFlattensBoth() {
        let resting = LooprTilt(degrees: 4, axis: (1, -0.4))
        let pressed = LooprTilt(degrees: 2, axis: (0, 1))
        #expect(LooprPressTiltModifier.tilt(pressed: nil, resting: resting, reducesMotion: false) == resting)
        #expect(LooprPressTiltModifier.tilt(pressed: pressed, resting: resting, reducesMotion: false) == pressed)
        #expect(LooprPressTiltModifier.tilt(pressed: pressed, resting: resting, reducesMotion: true) == .flat)
        #expect(LooprPressTiltModifier.tilt(pressed: nil, resting: nil, reducesMotion: false) == .flat)
        #expect(LooprPressTiltModifier.holdDuration < 0.25)
    }

    @Test func tiltedViewStillLaysOut() {
        let host = UIHostingController(rootView: Button("Open") {}.looprPressTilt(maxDegrees: 4, resting: .init(degrees: 4, axis: (1, -0.4))))
        host.view.frame = CGRect(x: 0, y: 0, width: 200, height: 100)
        host.view.layoutIfNeeded()
        #expect(host.sizeThatFits(in: CGSize(width: 200, height: 100)).height > 0)
    }
}

/// LV-01.4: entrances play once per tab per local day and survive relaunch.
struct LooprEntranceStoreTests {
    /// A clock the test moves.
    final class Clock: @unchecked Sendable {
        var date: Date
        init(_ date: Date) { self.date = date }
    }

    private static func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    private static func date(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text)!
    }

    private static func suite() -> UserDefaults {
        let name = "loopr-entrance-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private static func store(_ defaults: UserDefaults, _ clock: Clock, zone: String = "Europe/Berlin",
                              arguments: [String] = []) -> LooprEntranceStore {
        LooprEntranceStore(defaults: defaults, calendar: calendar(zone), now: { clock.date }, arguments: arguments)
    }

    @Test func entrancePlaysOncePerTab() {
        let clock = Clock(Self.date("2026-10-24T09:00:00+02:00"))
        let store = Self.store(Self.suite(), clock)
        #expect(store.shouldAnimate("today", reduceMotion: false))
        store.recordPlayed("today")
        #expect(!store.shouldAnimate("today", reduceMotion: false))
        #expect(store.shouldAnimate("food", reduceMotion: false))
        clock.date = Self.date("2026-10-24T23:59:00+02:00")
        #expect(!store.shouldAnimate("today", reduceMotion: false))
    }

    @Test func localMidnightStartsANewDay() {
        let clock = Clock(Self.date("2026-10-24T23:58:00+02:00"))
        let store = Self.store(Self.suite(), clock)
        store.recordPlayed("protocol")
        clock.date = Self.date("2026-10-24T23:59:59+02:00")
        #expect(store.hasPlayedToday("protocol"))
        clock.date = Self.date("2026-10-25T00:00:01+02:00")
        #expect(!store.hasPlayedToday("protocol"))
        #expect(store.shouldAnimate("protocol", reduceMotion: false))
    }

    @Test func daylightSavingNeitherRepeatsNorSkipsADay() {
        // Berlin leaves summer time at 03:00 on 25 October 2026, so that day has 25 hours.
        let clock = Clock(Self.date("2026-10-25T00:30:00+02:00"))
        let store = Self.store(Self.suite(), clock)
        store.recordPlayed("data")
        #expect(store.dayKey(for: clock.date) == "2026-10-25")
        clock.date = Self.date("2026-10-25T23:30:00+01:00")
        #expect(store.dayKey(for: clock.date) == "2026-10-25")
        #expect(store.hasPlayedToday("data"))
        clock.date = Self.date("2026-10-26T00:10:00+01:00")
        #expect(!store.hasPlayedToday("data"))
        // Spring forward: 29 March 2026 has 23 hours and still one key.
        #expect(store.dayKey(for: Self.date("2026-03-29T01:59:00+01:00")) == "2026-03-29")
        #expect(store.dayKey(for: Self.date("2026-03-29T03:01:00+02:00")) == "2026-03-29")
    }

    @Test func theDayFollowsTheCalendarsTimeZone() {
        let instant = Self.date("2026-10-24T23:30:00+00:00")
        let defaults = Self.suite()
        let clock = Clock(instant)
        #expect(Self.store(defaults, clock, zone: "Europe/Berlin").dayKey(for: instant) == "2026-10-25")
        #expect(Self.store(defaults, clock, zone: "America/New_York").dayKey(for: instant) == "2026-10-24")
    }

    @Test func recordsSurviveRelaunch() {
        let defaults = Self.suite()
        let clock = Clock(Self.date("2026-10-24T12:00:00+02:00"))
        Self.store(defaults, clock).recordPlayed("fitness")
        let relaunched = Self.store(defaults, clock)
        #expect(relaunched.hasPlayedToday("fitness"))
        #expect(!relaunched.shouldAnimate("fitness", reduceMotion: false))
        relaunched.reset(["fitness"])
        #expect(relaunched.shouldAnimate("fitness", reduceMotion: false))
    }

    @Test func reduceMotionAlwaysShowsTheFinalState() {
        let store = Self.store(Self.suite(), Clock(Self.date("2026-10-24T12:00:00+02:00")))
        #expect(!store.shouldAnimate("today", reduceMotion: true))
        #expect(!store.hasPlayedToday("today"))
        #expect(store.shouldAnimate("today", reduceMotion: false))
    }

    @Test func launchArgumentsForceTheFinalState() {
        let clock = Clock(Self.date("2026-10-24T12:00:00+02:00"))
        let forced = Self.store(Self.suite(), clock, arguments: ["Loopr", LooprEntranceStore.finalStateLaunchArgument])
        #expect(forced.forcesFinalState)
        #expect(!forced.shouldAnimate("today", reduceMotion: false))
        let capture = Self.store(Self.suite(), clock, arguments: [LooprEntranceStore.visualCaptureLaunchArgument])
        #expect(!capture.shouldAnimate("today", reduceMotion: false))
        #expect(!Self.store(Self.suite(), clock).forcesFinalState)
        #expect(LooprEntranceStore.finalStateLaunchArgument == "--loopr-entrance-final-state")
    }
}
