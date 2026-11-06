#if canImport(UIKit)
import QuartzCore
import SwiftUI
import UIKit

// The shared dot flight (DESIGN_LANGUAGE premium check 2, DEC-11.7). Dots break off a source, linger,
// fly in a loose arc and land in sequence on a target, one light haptic tick per landing, at most 30
// a second, and a success haptic at the end. Every dot is a Core Animation layer, so the motion runs
// on the render server and stays smooth while the main thread saves and reloads.
//
// The planning types here are pure and take their randomness and time from the caller, so tests can
// check the order, the landing positions, the haptic cap and the Reduce Motion path.

/// Where one dot starts: a point inside the source as fractions of its size, and its colour there.
public struct LooprDotStart: Equatable {
    public var unit: CGPoint
    public var color: UIColor

    public init(unit: CGPoint, color: UIColor) {
        self.unit = unit
        self.color = color
    }
}

/// The timing of a flight. The defaults are the food camera's finish (DEC-11.7).
public struct LooprDotFlightTiming: Equatable, Sendable {
    /// Seconds before the first dot breaks off.
    public var spawnDelay: Double = 0.14
    /// Extra seconds the last part of the source waits: dots break off top first, slightly left first.
    public var spawnSweep: Double = 0.42
    /// Random spread on each dot's break-off time.
    public var spawnJitter: Double = 0.03
    /// No dot breaks off earlier than this.
    public var minimumSpawn: Double = 0.1
    /// Seconds a dot takes to appear.
    public var appear: Double = 0.08
    /// Seconds a dot drifts out before it flies.
    public var linger: ClosedRange<Double> = 0.12...0.26
    /// Seconds of flight.
    public var flight: ClosedRange<Double> = 0.62...0.92
    /// Seconds after the last landing before completion and the success haptic.
    public var settle: Double = 0.12

    public init() {}

    public static let standard = LooprDotFlightTiming()
}

/// The haptics of a flight: one impact per landing, rate limited, and a success at the end.
public struct LooprDotFlightHaptics: Equatable, Sendable {
    public enum Style: Equatable, Sendable { case light, soft, medium, rigid }

    public var style: Style
    public var intensity: Double
    /// No more than this many ticks in any second.
    public var maximumPerSecond: Int
    /// The shortest gap between two ticks. Landings inside the gap are coalesced into the last tick.
    public var minimumInterval: TimeInterval
    public var playsSuccess: Bool

    public init(style: Style = .light, intensity: Double = 0.4, maximumPerSecond: Int = 30,
                minimumInterval: TimeInterval = 1.0 / 30, playsSuccess: Bool = true) {
        self.style = style
        self.intensity = intensity
        self.maximumPerSecond = maximumPerSecond
        self.minimumInterval = minimumInterval
        self.playsSuccess = playsSuccess
    }

    /// `.impact(weight: .light, intensity: 0.4)` per landing, at most 30 a second.
    public static let standard = LooprDotFlightHaptics()
}

public extension LooprHapticLimiter {
    /// The limiter a flight's haptics ask for.
    init(_ haptics: LooprDotFlightHaptics) {
        self.init(maximumPerSecond: haptics.maximumPerSecond, minimumInterval: haptics.minimumInterval)
    }
}

/// One dot with its times, in seconds after the flight starts.
public struct LooprScheduledDot: Equatable {
    /// Where it breaks off, in the flight's coordinates.
    public var start: CGPoint
    /// Its colour as it breaks off. It takes on the landing colour in flight.
    public var color: UIColor
    public var spawn: Double
    public var appear: Double
    public var linger: Double
    public var flight: Double

    public init(start: CGPoint, color: UIColor, spawn: Double, appear: Double = LooprDotFlightTiming.standard.appear,
                linger: Double, flight: Double) {
        self.start = start
        self.color = color
        self.spawn = spawn
        self.appear = appear
        self.linger = linger
        self.flight = flight
    }

    /// When it lands.
    public var arrival: Double { spawn + appear + linger + flight }
}

/// Where a group of dots lands. Dots land along it in arrival order, so a ring or line grows end to end.
public enum LooprDotTarget: Equatable {
    /// An arc of a ring, as fractions of a turn from twelve o'clock clockwise. `jitter` spreads each
    /// dot by up to that many points across the ring.
    case ring(center: CGPoint, radius: CGFloat, from: Double, to: Double, jitter: CGFloat = 0)
    case line(from: CGPoint, to: CGPoint)
    case point(CGPoint)
    /// A cell of a grid: dots fill it row by row.
    case slot(CGRect)

    /// The landing point of the dot that lands `rank`th of `count`.
    public func position(rank: Int, of count: Int, jitter: CGFloat = 0) -> CGPoint {
        let fraction = (Double(rank) + 0.5) / Double(max(count, 1))
        switch self {
        case let .ring(center, radius, from, to, _):
            let angle = -Double.pi / 2 + (from + (to - from) * fraction) * 2 * .pi
            let radius = radius + jitter
            return CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
        case let .line(start, end):
            return CGPoint(x: start.x + (end.x - start.x) * fraction, y: start.y + (end.y - start.y) * fraction)
        case let .point(point):
            return point
        case let .slot(rect):
            let columns = max(Int(Double(count).squareRoot().rounded(.up)), 1)
            let rows = max(Int((Double(count) / Double(columns)).rounded(.up)), 1)
            let column = rank % columns, row = rank / columns
            return CGPoint(x: rect.minX + rect.width * (CGFloat(column) + 0.5) / CGFloat(columns),
                           y: rect.minY + rect.height * (CGFloat(row) + 0.5) / CGFloat(rows))
        }
    }

    var jitter: CGFloat {
        if case let .ring(_, _, _, _, jitter) = self { return jitter }
        return 0
    }
}

/// One dot and the place it lands.
public struct LooprDotLanding: Equatable {
    public var dot: LooprScheduledDot
    public var target: CGPoint
    /// The colour it lands in.
    public var color: UIColor

    public init(dot: LooprScheduledDot, target: CGPoint, color: UIColor) {
        self.dot = dot
        self.target = target
        self.color = color
    }
}

/// Everything one flight needs.
public struct LooprDotFlightRequest: Identifiable {
    public let id: UUID
    public var landings: [LooprDotLanding]
    /// The point dots push away from as they break off: the source's centre.
    public var away: CGPoint
    public var timing: LooprDotFlightTiming
    public var haptics: LooprDotFlightHaptics

    public init(id: UUID = UUID(), landings: [LooprDotLanding], away: CGPoint,
                timing: LooprDotFlightTiming = .standard, haptics: LooprDotFlightHaptics = .standard) {
        self.id = id
        self.landings = landings
        self.away = away
        self.timing = timing
        self.haptics = haptics
    }

    /// Landing indices in the order the dots land. Ties keep their order in `landings`.
    public var landingOrder: [Int] {
        landings.indices.sorted { lhs, rhs in
            let left = landings[lhs].dot.arrival, right = landings[rhs].dot.arrival
            return left == right ? lhs < rhs : left < right
        }
    }

    /// Seconds from the start to the last landing.
    public var lastArrival: Double { landings.map(\.dot.arrival).max() ?? 0 }
}

/// Planning helpers for a flight.
public enum LooprDotFlight {
    /// Times for dots that break off `source`, top first, in the order given.
    public static func schedule<G: RandomNumberGenerator>(_ starts: [LooprDotStart], in source: CGRect,
                                                          timing: LooprDotFlightTiming = .standard,
                                                          using random: inout G) -> [LooprScheduledDot] {
        starts.map { start in
            let sweep = min(max(start.unit.x * 0.3 + start.unit.y * 0.7, 0), 1)
            let spawn = timing.spawnDelay + Double(sweep) * timing.spawnSweep
                + Double.random(in: -timing.spawnJitter...timing.spawnJitter, using: &random)
            return LooprScheduledDot(
                start: CGPoint(x: source.minX + start.unit.x * source.width, y: source.minY + start.unit.y * source.height),
                color: start.color, spawn: max(spawn, timing.minimumSpawn), appear: timing.appear,
                linger: .random(in: timing.linger, using: &random), flight: .random(in: timing.flight, using: &random))
        }
    }

    /// Lands `dots` on `target` in arrival order, each in `color`.
    public static func land<G: RandomNumberGenerator>(_ dots: [LooprScheduledDot], on target: LooprDotTarget, color: UIColor,
                                                      using random: inout G) -> [LooprDotLanding] {
        let ordered = dots.sorted { $0.arrival < $1.arrival }
        let spread = target.jitter
        return ordered.enumerated().map { rank, dot in
            let jitter = spread > 0 ? CGFloat.random(in: -spread...spread, using: &random) : 0
            return LooprDotLanding(dot: dot, target: target.position(rank: rank, of: ordered.count, jitter: jitter), color: color)
        }
    }

    /// A whole flight from `source` onto `target`: one dot per colour, spread over the source.
    public static func request<G: RandomNumberGenerator>(from source: CGRect, to target: LooprDotTarget, colors: [UIColor],
                                                         landingColor: UIColor? = nil, timing: LooprDotFlightTiming = .standard,
                                                         haptics: LooprDotFlightHaptics = .standard,
                                                         using random: inout G) -> LooprDotFlightRequest {
        let starts = colors.map { color in
            LooprDotStart(unit: CGPoint(x: .random(in: 0...1, using: &random), y: .random(in: 0...1, using: &random)), color: color)
        }
        let dots = schedule(starts, in: source, timing: timing, using: &random)
        let landings: [LooprDotLanding]
        if let landingColor {
            landings = land(dots, on: target, color: landingColor, using: &random)
        } else {
            // Each dot keeps its own colour.
            let ordered = dots.sorted { $0.arrival < $1.arrival }
            landings = ordered.enumerated().map { rank, dot in
                LooprDotLanding(dot: dot, target: target.position(rank: rank, of: ordered.count), color: dot.color)
            }
        }
        return LooprDotFlightRequest(landings: landings, away: CGPoint(x: source.midX, y: source.midY), timing: timing, haptics: haptics)
    }

    /// Points spread over an image's opaque pixels, as fractions of its size, each with that pixel's colour.
    public static func samples(_ image: UIImage, count: Int) -> [LooprDotStart] {
        guard count > 0, let cgImage = image.cgImage, cgImage.width > 0, cgImage.height > 0 else { return [] }
        let width = 72, height = max(Int((CGFloat(cgImage.height) / CGFloat(cgImage.width) * 72).rounded()), 1)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return [] }
        var candidates: [LooprDotStart] = []
        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 4
                let alpha = pixels[index + 3]
                guard alpha > 150 else { continue }
                let unpremultiply = 255 / CGFloat(alpha)
                let color = UIColor(red: CGFloat(pixels[index]) * unpremultiply / 255, green: CGFloat(pixels[index + 1]) * unpremultiply / 255,
                                    blue: CGFloat(pixels[index + 2]) * unpremultiply / 255, alpha: 1)
                // A bitmap context keeps its top row first in memory.
                candidates.append(LooprDotStart(unit: CGPoint(x: (CGFloat(x) + .random(in: 0...1)) / CGFloat(width),
                                                              y: (CGFloat(y) + .random(in: 0...1)) / CGFloat(height)), color: color))
            }
        }
        guard !candidates.isEmpty else { return [] }
        candidates.shuffle()
        return (0..<count).map { candidates[$0 % candidates.count] }
    }
}

/// Which landings have happened and when to tick, for a flight started at time zero. Pure: the
/// view feeds it the elapsed time on every frame.
public struct LooprDotLandingProgress: Equatable, Sendable {
    /// Arrival times, in landing order.
    public let arrivals: [Double]
    public let settle: Double
    public private(set) var landed = 0
    public private(set) var isFinished = false
    public private(set) var limiter: LooprHapticLimiter

    public struct Step: Equatable, Sendable {
        /// Landing ranks that happened in this step, in order.
        public var landed: Range<Int>
        /// Whether a landing tick plays in this step.
        public var ticks: Bool
        /// True once, in the step that finishes the flight.
        public var finishes: Bool
    }

    public init(arrivals: [Double], settle: Double, haptics: LooprDotFlightHaptics = .standard) {
        self.arrivals = arrivals.sorted()
        self.settle = settle
        limiter = LooprHapticLimiter(haptics)
    }

    public init(_ request: LooprDotFlightRequest) {
        self.init(arrivals: request.landingOrder.map { request.landings[$0].dot.arrival }, settle: request.timing.settle,
                  haptics: request.haptics)
    }

    public mutating func advance(to elapsed: Double) -> Step {
        guard !isFinished else { return Step(landed: landed..<landed, ticks: false, finishes: false) }
        let first = landed
        while landed < arrivals.count, arrivals[landed] <= elapsed { landed += 1 }
        var ticks = false
        for _ in first..<landed where limiter.shouldFire(at: elapsed) { ticks = true }
        let finishes = landed == arrivals.count && elapsed >= (arrivals.last ?? 0) + settle
        if finishes { isFinished = true }
        return Step(landed: first..<landed, ticks: ticks, finishes: finishes)
    }

    /// Lands everything at once, as under Reduce Motion: no ticks.
    public mutating func finishNow() -> Step {
        let first = landed
        landed = arrivals.count
        isFinished = true
        return Step(landed: first..<landed, ticks: false, finishes: true)
    }
}

/// Plays dot flights. Add it over the source and the targets; it never takes touches.
public final class LooprDotFlightView: UIView {
    public typealias Landing = (_ rank: Int, _ landing: LooprDotLanding) -> Void

    public private(set) var playing: UUID?
    /// The flight `queue` last took, played or not.
    public private(set) var queuedID: UUID?
    private var queued: (request: LooprDotFlightRequest, reduceMotion: Bool, onLanding: Landing?, completion: (() -> Void)?)?
    private let stage = CALayer()
    private var link: CADisplayLink?
    private var request: LooprDotFlightRequest?
    private var order: [Int] = []
    private var progress: LooprDotLandingProgress?
    private var start: CFTimeInterval = 0
    private var onFrame: ((CFTimeInterval) -> Void)?
    private var onLanding: Landing?
    private var completion: (() -> Void)?
    private var impact = UIImpactFeedbackGenerator(style: .light)
    private let notice = UINotificationFeedbackGenerator()
    /// The media clock. A test replaces it and drives the flight with `advance(to:)`.
    public var clock: () -> CFTimeInterval = CACurrentMediaTime

    override public init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        layer.addSublayer(stage)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override public func layoutSubviews() {
        super.layoutSubviews()
        stage.frame = bounds
    }

    /// Plays `request`. `start` is when its time zero falls on the media clock, so a caller can line up
    /// its own animations. `onFrame` runs on every frame of the flight with the media time.
    public func play(_ request: LooprDotFlightRequest, startingAt start: CFTimeInterval? = nil, reduceMotion: Bool,
                     onFrame: ((CFTimeInterval) -> Void)? = nil, onLanding: Landing? = nil,
                     completion: (() -> Void)? = nil) {
        cancel()
        playing = request.id
        self.request = request
        order = request.landingOrder
        progress = LooprDotLandingProgress(request)
        self.start = start ?? clock()
        self.onFrame = onFrame
        self.onLanding = onLanding
        self.completion = completion
        impact = UIImpactFeedbackGenerator(style: Self.feedbackStyle(request.haptics.style))
        impact.prepare()
        notice.prepare()

        guard !reduceMotion else {
            // No flight: every landing reports at once, so the targets can show their final state.
            if let step = progress?.finishNow() { deliver(step) }
            return
        }
        var random = SystemRandomNumberGenerator()
        for landing in request.landings {
            launch(landing, away: request.away, at: self.start, timing: request.timing, random: &random)
        }
        startLink()
    }

    /// Plays `request` on the next turn of the main run loop, for callers inside a view update.
    public func queue(_ request: LooprDotFlightRequest, reduceMotion: Bool, onLanding: Landing? = nil,
                      completion: (() -> Void)? = nil) {
        queuedID = request.id
        queued = (request, reduceMotion, onLanding, completion)
        DispatchQueue.main.async { [weak self] in self?.playQueued() }
    }

    private func playQueued() {
        guard let queued else { return }
        self.queued = nil
        play(queued.request, reduceMotion: queued.reduceMotion, onLanding: queued.onLanding, completion: queued.completion)
    }

    /// Stops a flight without calling its completion.
    public func cancel() {
        link?.invalidate()
        link = nil
        stage.sublayers?.forEach { $0.removeFromSuperlayer() }
        progress = nil
        onFrame = nil
        onLanding = nil
        completion = nil
    }

    /// Moves the flight to media time `now`. The display link calls it on every frame; a test calls it
    /// directly to run a flight frame by frame.
    public func advance(to now: CFTimeInterval) {
        guard var progress else { return }
        onFrame?(now)
        let step = progress.advance(to: now - start)
        self.progress = progress
        deliver(step)
    }

    private func deliver(_ step: LooprDotLandingProgress.Step) {
        if let request, let onLanding {
            for rank in step.landed { onLanding(rank, request.landings[order[rank]]) }
        }
        if step.ticks { impact.impactOccurred(intensity: request?.haptics.intensity ?? 0.4) }
        guard step.finishes else { return }
        link?.invalidate()
        link = nil
        if request?.haptics.playsSuccess == true { notice.notificationOccurred(.success) }
        let completion = completion
        self.completion = nil
        onFrame = nil
        onLanding = nil
        completion?()
    }

    private func startLink() {
        let link = CADisplayLink(target: self, selector: #selector(step))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func step(_ link: CADisplayLink) {
        advance(to: clock())
    }

    private static func feedbackStyle(_ style: LooprDotFlightHaptics.Style) -> UIImpactFeedbackGenerator.FeedbackStyle {
        switch style {
        case .light: .light
        case .soft: .soft
        case .medium: .medium
        case .rigid: .rigid
        }
    }

    /// One dot: it breaks off, drifts out a little, then curves into its place, taking on its landing
    /// colour on the way.
    private func launch(_ landing: LooprDotLanding, away middle: CGPoint, at time: CFTimeInterval,
                        timing: LooprDotFlightTiming, random: inout SystemRandomNumberGenerator) {
        let start = landing.dot.start, target = landing.target
        let linger = landing.dot.linger, flight = landing.dot.flight, appear = landing.dot.appear
        let size = CGFloat.random(in: 3.2...5.4, using: &random)
        let dot = CALayer()
        dot.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        dot.cornerRadius = size / 2
        dot.position = target
        dot.backgroundColor = landing.color.cgColor
        dot.opacity = 0

        let outward = CGVector(dx: start.x - middle.x, dy: start.y - middle.y)
        let length = max(hypot(outward.dx, outward.dy), 1)
        let push = CGFloat.random(in: 8...24, using: &random)
        let drifted = CGPoint(x: start.x + outward.dx / length * push + .random(in: -6...6, using: &random),
                              y: start.y + outward.dy / length * push - .random(in: 2...14, using: &random))
        let total = appear + linger + flight

        let drift = CABasicAnimation(keyPath: "position")
        drift.fromValue = start; drift.toValue = drifted
        drift.duration = appear + linger; drift.fillMode = .both
        drift.timingFunction = CAMediaTimingFunction(name: .easeOut)

        // Out and over in a loose arc, then down into the target from above.
        let path = UIBezierPath()
        path.move(to: drifted)
        let sideways = CGFloat.random(in: -90...90, using: &random)
        path.addCurve(to: target,
                      controlPoint1: CGPoint(x: drifted.x + sideways, y: drifted.y - .random(in: 30...110, using: &random)),
                      controlPoint2: CGPoint(x: target.x - sideways * 0.4, y: target.y - .random(in: 60...150, using: &random)))
        let fly = CAKeyframeAnimation(keyPath: "position")
        fly.path = path.cgPath
        fly.beginTime = appear + linger; fly.duration = flight; fly.fillMode = .forwards
        fly.timingFunction = CAMediaTimingFunction(controlPoints: 0.45, 0, 0.2, 1)

        let tint = CABasicAnimation(keyPath: "backgroundColor")
        tint.fromValue = landing.dot.color.cgColor; tint.toValue = landing.color.cgColor
        tint.beginTime = appear + linger; tint.duration = flight * 0.55; tint.fillMode = .both

        let opacity = CAKeyframeAnimation(keyPath: "opacity")
        opacity.values = [0, 1, 1, 0]
        opacity.keyTimes = [0, NSNumber(value: appear / total), NSNumber(value: (total - 0.07) / total), 1]

        let scale = CAKeyframeAnimation(keyPath: "transform.scale")
        scale.values = [0.3, 1.15, 1, 0.55]
        scale.keyTimes = [0, NSNumber(value: appear / total), NSNumber(value: (appear + linger) / total), 1]

        let group = CAAnimationGroup()
        group.animations = [drift, fly, tint, opacity, scale]
        group.beginTime = time + landing.dot.spawn; group.duration = total
        group.fillMode = .both; group.isRemovedOnCompletion = false
        dot.add(group, forKey: "burst")
        stage.addSublayer(dot)
    }
}
#endif
