import SwiftUI
import Testing
import UIKit
@testable import DesignSystem

/// A seeded generator, so a plan is the same on every run.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// LV-01.3: the shared dot flight. Order, positions, the haptic cap and Reduce Motion are checked
/// through the pure types with an injected clock; the view is driven frame by frame.
@MainActor struct LooprDotFlightTests {
    // MARK: Haptic cap

    @Test func aBurstOf300LandingsTicksAtMost30TimesASecond() {
        var limiter = LooprHapticLimiter(maximumPerSecond: 30)
        let times = (0..<300).map { Double($0) / 300 }
        let fired = times.filter { limiter.shouldFire(at: $0) }
        #expect(fired.count <= 30)
        #expect(fired.count >= 29)
        #expect(limiter.fired == fired.count)
        #expect(limiter.coalesced == 300 - fired.count)
        #expect(Self.busiestSecond(fired) <= 30)
    }

    @Test func noSecondEverHoldsMoreThan30Ticks() {
        var limiter = LooprHapticLimiter(maximumPerSecond: 30)
        var random = SeededGenerator(seed: 7)
        let times = (0..<900).map { _ in Double.random(in: 0..<3, using: &random) }.sorted()
        let fired = times.filter { limiter.shouldFire(at: $0) }
        #expect(Self.busiestSecond(fired) <= 30)
        #expect(zip(fired, fired.dropFirst()).allSatisfy { $1 - $0 >= 1.0 / 30 - 1e-9 })
    }

    @Test func landingsInTheSameInstantCoalesceIntoOneTick() {
        var limiter = LooprHapticLimiter(maximumPerSecond: 30)
        let fired = (0..<300).filter { _ in limiter.shouldFire(at: 0.5) }
        #expect(fired.count == 1)
    }

    @Test func aFlightOf300LandingsAtFrameRateTicksAtMost30ASecond() {
        let arrivals = (0..<300).map { 0.2 + Double($0) / 300 }
        var progress = LooprDotLandingProgress(arrivals: arrivals, settle: 0.1)
        var tickTimes: [Double] = []
        var frame = 0.0
        while !progress.isFinished, frame < 5 {
            if progress.advance(to: frame).ticks { tickTimes.append(frame) }
            frame += 1.0 / 120
        }
        #expect(progress.landed == 300)
        #expect(progress.isFinished)
        #expect(Self.busiestSecond(tickTimes) <= 30)
        #expect(tickTimes.count >= 25)
    }

    @Test func standardHapticsAreALightTickAndASuccess() {
        let haptics = LooprDotFlightHaptics.standard
        #expect(haptics.style == .light)
        #expect(haptics.intensity == 0.4)
        #expect(haptics.maximumPerSecond == 30)
        #expect(haptics.playsSuccess)
    }

    // MARK: Order and positions

    @Test func dotsLandInArrivalOrderAndFinishAfterTheSettle() {
        var progress = LooprDotLandingProgress(arrivals: [0.9, 0.3, 0.6], settle: 0.12)
        #expect(progress.arrivals == [0.3, 0.6, 0.9])
        #expect(progress.advance(to: 0.2).landed.isEmpty)
        #expect(progress.advance(to: 0.65).landed == 0..<2)
        let last = progress.advance(to: 0.95)
        #expect(last.landed == 2..<3)
        #expect(!last.finishes)
        #expect(progress.advance(to: 1.03).finishes)
        #expect(progress.isFinished)
        #expect(!progress.advance(to: 2).finishes)
    }

    @Test func groupsLandAlongTheirRingInArrivalOrder() throws {
        var random = SeededGenerator(seed: 3)
        let starts = (0..<40).map { LooprDotStart(unit: CGPoint(x: Double($0 % 8) / 8, y: Double($0 / 8) / 5), color: .red) }
        let dots = LooprDotFlight.schedule(starts, in: CGRect(x: 100, y: 100, width: 200, height: 200), using: &random)
        #expect(dots.count == 40)
        let timing = LooprDotFlightTiming.standard
        for dot in dots {
            #expect(dot.spawn >= timing.minimumSpawn)
            #expect(timing.linger.contains(dot.linger))
            #expect(timing.flight.contains(dot.flight))
            #expect(dot.start.x >= 100 && dot.start.x <= 300 && dot.start.y >= 100 && dot.start.y <= 300)
        }
        let ring = LooprDotTarget.ring(center: CGPoint(x: 200, y: 500), radius: 50, from: 0, to: 0.5)
        let landings = LooprDotFlight.land(dots, on: ring, color: .blue, using: &random)
        #expect(zip(landings, landings.dropFirst()).allSatisfy { $0.dot.arrival <= $1.dot.arrival })
        // The first lands near twelve o'clock and the last near six, so the arc grows end to end.
        let first = try #require(landings.first?.target), last = try #require(landings.last?.target)
        #expect(abs(first.x - 200) < 5 && first.y < 452)
        #expect(abs(last.x - 200) < 5 && last.y > 548)
        #expect(landings.allSatisfy { abs(hypot($0.target.x - 200, $0.target.y - 500) - 50) < 0.001 })
        #expect(landings.allSatisfy { $0.color == .blue })
    }

    @Test func targetsPlaceDotsOnTheirShape() {
        let line = LooprDotTarget.line(from: CGPoint(x: 0, y: 10), to: CGPoint(x: 100, y: 10))
        #expect(line.position(rank: 0, of: 4) == CGPoint(x: 12.5, y: 10))
        #expect(line.position(rank: 3, of: 4) == CGPoint(x: 87.5, y: 10))
        #expect(LooprDotTarget.point(CGPoint(x: 5, y: 6)).position(rank: 2, of: 9) == CGPoint(x: 5, y: 6))
        let slot = LooprDotTarget.slot(CGRect(x: 0, y: 0, width: 30, height: 30))
        let cells = (0..<9).map { slot.position(rank: $0, of: 9) }
        #expect(Set(cells.map { "\($0.x),\($0.y)" }).count == 9)
        #expect(cells.allSatisfy { $0.x > 0 && $0.x < 30 && $0.y > 0 && $0.y < 30 })
        let frame = CGRect(x: 10, y: 20, width: 100, height: 60)
        #expect(LooprDotTargetShape.point.target(in: frame) == .point(CGPoint(x: 60, y: 50)))
        #expect(LooprDotTargetShape.ring(inset: 4).target(in: frame) == .ring(center: CGPoint(x: 60, y: 50), radius: 26, from: 0, to: 1))
        #expect(LooprDotTargetShape.line.target(in: frame) == .line(from: CGPoint(x: 10, y: 50), to: CGPoint(x: 110, y: 50)))
    }

    @Test func requestOrdersLandingsAndKeepsTiesStable() {
        let dot = { (arrival: Double) in
            LooprDotLanding(dot: LooprScheduledDot(start: .zero, color: .red, spawn: arrival, appear: 0, linger: 0, flight: 0),
                            target: .zero, color: .red)
        }
        let request = LooprDotFlightRequest(landings: [dot(0.5), dot(0.2), dot(0.5), dot(0.1)], away: .zero)
        #expect(request.landingOrder == [3, 1, 0, 2])
        #expect(request.lastArrival == 0.5)
    }

    // MARK: The view

    @Test func viewReportsEachLandingInOrderThenCompletes() {
        var random = SeededGenerator(seed: 11)
        let request = LooprDotFlight.request(from: CGRect(x: 0, y: 0, width: 50, height: 50),
                                             to: .point(CGPoint(x: 200, y: 400)), colors: Array(repeating: .red, count: 24),
                                             landingColor: .green, using: &random)
        let view = LooprDotFlightView(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        view.clock = { 100 }
        var ranks: [Int] = [], arrivals: [Double] = [], completed = 0
        view.play(request, startingAt: 100, reduceMotion: false, onLanding: { rank, landing in
            ranks.append(rank)
            arrivals.append(landing.dot.arrival)
        }, completion: { completed += 1 })
        #expect(view.playing == request.id)
        var time = 100.0
        while completed == 0, time < 105 {
            time += 1.0 / 60
            view.advance(to: time)
        }
        #expect(ranks == Array(0..<24))
        #expect(arrivals == arrivals.sorted())
        #expect(completed == 1)
        #expect(time >= 100 + request.lastArrival + request.timing.settle)
        view.advance(to: time + 1)
        #expect(completed == 1)
    }

    @Test func reduceMotionLandsEverythingAtOnceAndCompletes() {
        var random = SeededGenerator(seed: 5)
        let request = LooprDotFlight.request(from: CGRect(x: 0, y: 0, width: 50, height: 50), to: .point(.zero),
                                             colors: Array(repeating: .red, count: 10), using: &random)
        let view = LooprDotFlightView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        var count = LooprCountUp(from: 100, to: 200, total: 10)
        var completed = false
        view.play(request, reduceMotion: true, onLanding: { _, _ in count = count.landing() }, completion: { completed = true })
        #expect(completed)
        #expect(count.isComplete)
        #expect(count.value == 200)
        // No dot layers were added.
        #expect(view.layer.sublayers?.first?.sublayers?.isEmpty ?? true)
    }

    @Test func reduceMotionWithNoDotsStillCompletes() {
        let view = LooprDotFlightView(frame: .zero)
        var completed = false
        view.play(LooprDotFlightRequest(landings: [], away: .zero), reduceMotion: true, completion: { completed = true })
        #expect(completed)
    }

    @Test func cancelStopsWithoutCompleting() {
        var random = SeededGenerator(seed: 9)
        let request = LooprDotFlight.request(from: CGRect(x: 0, y: 0, width: 10, height: 10), to: .point(.zero),
                                             colors: [.red, .blue], using: &random)
        let view = LooprDotFlightView(frame: .zero)
        var completed = false
        view.play(request, startingAt: 0, reduceMotion: false, completion: { completed = true })
        view.cancel()
        view.advance(to: 10)
        #expect(!completed)
    }

    @Test func imageSamplesComeFromOpaquePixels() {
        let size = CGSize(width: 20, height: 10)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        }
        let samples = LooprDotFlight.samples(image, count: 50)
        #expect(samples.count == 50)
        #expect(samples.allSatisfy { $0.unit.x <= 0.52 })
        #expect(LooprDotFlight.samples(UIImage(), count: 10).isEmpty)
    }

    // MARK: Coordinator

    @Test func coordinatorRegistersSourcesAndTargets() throws {
        let coordinator = LooprDotFlightCoordinator()
        #expect(!coordinator.fly(from: "log", to: "ring", colors: [.red]))
        coordinator.registerSource("log", frame: CGRect(x: 10, y: 700, width: 120, height: 48))
        #expect(!coordinator.fly(from: "log", to: "ring", colors: [.red]))
        coordinator.registerTarget("ring", frame: CGRect(x: 100, y: 100, width: 200, height: 200))
        #expect(coordinator.sources["log"] == CGRect(x: 10, y: 700, width: 120, height: 48))
        #expect(coordinator.targets["ring"] == CGRect(x: 100, y: 100, width: 200, height: 200))
        #expect(!coordinator.fly(from: "log", to: "ring", colors: []))
        #expect(coordinator.fly(from: "log", to: "ring", colors: [.red, .blue, .green]))
        let playback = try #require(coordinator.playback)
        #expect(playback.request.landings.count == 3)
        #expect(playback.request.away == CGPoint(x: 70, y: 724))
        coordinator.finished(playback.request.id)
        #expect(coordinator.playback == nil)
    }

    @Test func coordinatorSortsAnchorFramesByRole() {
        let coordinator = LooprDotFlightCoordinator()
        coordinator.update([
            .init(role: .source, name: "button"): CGRect(x: 0, y: 0, width: 10, height: 10),
            .init(role: .target, name: "ring"): CGRect(x: 50, y: 50, width: 20, height: 20),
            .init(role: .target, name: "grid"): CGRect(x: 80, y: 0, width: 5, height: 5)
        ])
        #expect(coordinator.sources.keys.sorted() == ["button"])
        #expect(coordinator.targets.keys.sorted() == ["grid", "ring"])
        coordinator.update([:])
        #expect(coordinator.sources.isEmpty && coordinator.targets.isEmpty)
    }

    @Test func hostResolvesMarkedViewsAndTheGalleryLaysOut() {
        let host = UIHostingController(rootView: VStack {
            Color.red.frame(width: 40, height: 40).looprDotFlightSource("a")
            Color.blue.frame(width: 60, height: 60).looprDotFlightTarget("b")
        }.looprDotFlightHost())
        host.view.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        host.view.layoutIfNeeded()
        let gallery = UIHostingController(rootView: LooprDotFlightGalleryDemo().padding(20))
        gallery.view.frame = CGRect(x: 0, y: 0, width: 393, height: 400)
        gallery.view.layoutIfNeeded()
        #expect(LooprDotFlightGalleryDemo.colors.count == LooprDotFlightGalleryDemo.dotCount)
        #expect(LooprDotFlightGalleryDemo.ringFill(value: 4_000) == 1)
        _ = DesignSystemGallery(initialSection: "craft")
    }

    /// The most timestamps inside any one-second window that starts at a timestamp.
    private static func busiestSecond(_ times: [Double]) -> Int {
        var busiest = 0
        for (index, start) in times.enumerated() {
            busiest = max(busiest, times[index...].prefix { $0 < start + 1 }.count)
        }
        return busiest
    }
}
