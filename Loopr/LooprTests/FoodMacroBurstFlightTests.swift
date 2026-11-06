import DesignSystem
import Foundation
import Testing
import UIKit

@testable import Loopr

/// LV-01.3: the food camera's finish flies its dots through the shared `LooprDotFlightView` and keeps
/// the DEC-11.7 timing, haptics and Reduce Motion hold.
@MainActor struct FoodMacroBurstFlightTests {
    @Test func burstKeepsTheFoodTiming() {
        let timing = FoodMacroBurstView.timing
        #expect(timing.spawnDelay == 0.14)
        #expect(timing.spawnSweep == 0.42)
        #expect(timing.spawnJitter == 0.03)
        #expect(timing.minimumSpawn == 0.1)
        #expect(timing.appear == 0.08)
        #expect(timing.linger == 0.12...0.26)
        #expect(timing.flight == 0.62...0.92)
        // The flight's clock starts 0.04 s after the call, so 0.08 s of settle keeps the success
        // 0.12 s after the last landing measured from the call, as before.
        #expect(timing.settle == 0.08)
    }

    @Test func burstTicksSoftlyAtMostEvery75Milliseconds() {
        let haptics = FoodMacroBurstView.haptics
        #expect(haptics.style == .soft)
        #expect(haptics.intensity == 0.45)
        #expect(haptics.minimumInterval == 0.075)
        #expect(haptics.maximumPerSecond <= 30)
        #expect(haptics.playsSuccess)
        var limiter = LooprHapticLimiter(haptics)
        let fired = (0..<300).map { 0.5 + Double($0) / 300 * 0.8 }.filter { limiter.shouldFire(at: $0) }
        #expect(fired.count <= 11)
        #expect(zip(fired, fired.dropFirst()).allSatisfy { $1 - $0 >= 0.075 - 1e-9 })
    }

    @Test func samplesStillComeFromThePicture() {
        let picture = Self.picture()
        let samples = FoodMacroBurstView.samples(picture, count: 170)
        #expect(samples.count == 170)
        #expect(samples.allSatisfy { $0.unit.x >= 0 && $0.unit.x <= 1 && $0.unit.y >= 0 && $0.unit.y <= 1 })
    }

    @Test func reduceMotionHoldsTheNewDayThenFinishes() {
        let (view, holds) = Self.burstView()
        let request = Self.request()
        var finished = false
        view.play(request, reduceMotion: true) { finished = true }
        #expect(view.played == request.id)
        // No dots fly: the rings already show the new day, then the burst holds 1.4 s.
        #expect(Self.labels(in: view).isSuperset(of: Self.newDay))
        #expect(holds.delays == [1.4])
        #expect(!finished)
        holds.runAll()
        #expect(finished)
    }

    @Test func fullBurstFliesItsDotsAndFinishes() throws {
        let (view, holds) = Self.burstView()
        let request = Self.request()
        var finished = false
        view.play(request, reduceMotion: false) { finished = true }
        #expect(view.played == request.id)
        let flight = try #require(view.subviews.compactMap { $0 as? LooprDotFlightView }.first)
        #expect(flight.playing != nil)
        #expect(!Self.labels(in: view).isSuperset(of: Self.newDay))
        // Frame by frame at 60 Hz on the injected clock until the flight settles and the hold is queued.
        var time = Self.start
        while holds.delays.isEmpty, time < Self.start + 10 {
            time += 1.0 / 60
            view.advance(to: time)
        }
        #expect(holds.delays == [0.9])
        #expect(time > Self.start + 1)
        #expect(Self.labels(in: view).isSuperset(of: Self.newDay))
        #expect(!finished)
        holds.runAll()
        #expect(finished)
    }

    /// The holds the burst queued, run by the test instead of a timer.
    private final class Holds {
        private var pending: [(delay: TimeInterval, work: @MainActor @Sendable () -> Void)] = []
        private(set) var delays: [TimeInterval] = []

        func add(_ delay: TimeInterval, _ work: @escaping @MainActor @Sendable () -> Void) {
            pending.append((delay, work))
            delays.append(delay)
        }

        @MainActor func runAll() {
            while !pending.isEmpty { pending.removeFirst().work() }
        }
    }

    private nonisolated static let start: CFTimeInterval = 1_000

    /// The counters after the meal: 900 + 520 kcal, 50 + 32 g protein, 100 + 48 g carbs, 30 + 18 g fat.
    private static let newDay: Set<String> = ["1,420", "82 g", "148 g", "48 g"]

    private static func labels(in view: UIView) -> Set<String> {
        Set(view.subviews.compactMap { ($0 as? UILabel)?.text })
    }

    private static func burstView() -> (FoodMacroBurstView, Holds) {
        let view = FoodMacroBurstView(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        view.layoutIfNeeded()
        let holds = Holds()
        let start = Self.start
        view.clock = { start }
        view.after = { delay, work in holds.add(delay, work) }
        return (view, holds)
    }

    private static func request() -> FoodBurstRequest {
        FoodBurstRequest(subject: picture(), frame: CGRect(x: 96, y: 200, width: 200, height: 200),
                         day: FoodBurstDay(eaten: .init(energy: 900, protein: 50, carbs: 100, fat: 30), energyTarget: 2_200),
                         added: .init(energy: 520, protein: 32, carbs: 48, fat: 18))
    }

    private static func picture() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 60, height: 60)).image { context in
            UIColor.orange.setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 4, y: 4, width: 52, height: 52))
        }
    }
}
