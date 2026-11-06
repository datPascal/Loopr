import Foundation
import SwiftUI

/// The stops of a ruler or a dial (DESIGN_LANGUAGE premium check 5): a range cut into equal steps,
/// with optional named marks. It maps a continuous value to the nearest stop, and with hysteresis a
/// value has to pass a little beyond halfway before the stop changes, so a finger resting on a
/// boundary does not flicker between two stops.
public struct LooprDetent: Equatable, Sendable {
    /// A named stop, such as "Usual" or "Target".
    public struct Mark: Equatable, Sendable {
        public let value: Double
        public let label: String

        public init(_ label: String, at value: Double) {
            self.label = label
            self.value = value
        }
    }

    public let range: ClosedRange<Double>
    public let step: Double
    public let marks: [Mark]
    /// How far past halfway, as a fraction of a step, a value must go to leave its current stop.
    public let hysteresis: Double

    public init(range: ClosedRange<Double>, step: Double, marks: [Mark] = [], hysteresis: Double = 0.25) {
        self.range = range
        self.step = step > 0 ? step : 1
        self.marks = marks
        self.hysteresis = min(max(hysteresis, 0), 0.49)
    }

    /// The number of stops, both ends included.
    public var count: Int { Int(((range.upperBound - range.lowerBound) / step).rounded()) + 1 }

    /// The nearest stop to `value`, clamped to the range.
    public func index(for value: Double) -> Int {
        guard value.isFinite else { return 0 }
        let clamped = min(max(value, range.lowerBound), range.upperBound)
        return min(max(Int(((clamped - range.lowerBound) / step).rounded()), 0), count - 1)
    }

    /// The stop for `value` when the control sits on `current`: it stays there until `value` passes
    /// halfway to the next stop by `hysteresis` of a step.
    public func index(for value: Double, from current: Int?) -> Int {
        guard let current, (0..<count).contains(current), value.isFinite else { return index(for: value) }
        let position = (min(max(value, range.lowerBound), range.upperBound) - range.lowerBound) / step
        let distance = position - Double(current)
        guard abs(distance) > 0.5 + hysteresis else { return current }
        return index(for: value)
    }

    /// The value of stop `index`, rounded to the step so 0.1 steps never read 78.39999.
    public func value(at index: Int) -> Double {
        let clamped = min(max(index, 0), count - 1)
        let raw = range.lowerBound + Double(clamped) * step
        return (raw / step).rounded() * step
    }

    /// `value` moved to its nearest stop.
    public func snapped(_ value: Double) -> Double { self.value(at: index(for: value)) }

    /// The named mark on stop `index`, if any.
    public func mark(at index: Int) -> Mark? {
        marks.first { self.index(for: $0.value) == index }
    }
}

/// Follows a control across its stops and decides which stop changes play a haptic: one per new
/// stop, at most 30 a second, so a fast fling does not buzz. Time comes from the caller.
public struct LooprDetentTracker: Equatable, Sendable {
    public let detent: LooprDetent
    public private(set) var current: Int?
    public private(set) var limiter: LooprHapticLimiter

    public struct Step: Equatable, Sendable {
        public let index: Int
        public let changed: Bool
        /// Whether this change plays its haptic.
        public let plays: Bool
    }

    public init(_ detent: LooprDetent, maximumPerSecond: Int = 30) {
        self.detent = detent
        limiter = LooprHapticLimiter(maximumPerSecond: maximumPerSecond)
    }

    /// Moves to the stop for `value` at `time`, with hysteresis.
    public mutating func update(_ value: Double, at time: TimeInterval) -> Step {
        move(to: detent.index(for: value, from: current), at: time)
    }

    /// Moves to stop `index` at `time`, for controls such as a scroll view that already land on stops.
    public mutating func move(to index: Int, at time: TimeInterval) -> Step {
        let index = min(max(index, 0), detent.count - 1)
        guard index != current else { return Step(index: index, changed: false, plays: false) }
        let first = current == nil
        current = index
        // The first stop is where the control starts, not a change the finger made.
        let plays = !first && limiter.shouldFire(at: time)
        return Step(index: index, changed: !first, plays: plays)
    }

    /// Forgets the current stop, as when a finger lifts.
    public mutating func reset() { current = nil }
}

public extension LooprHaptic {
    /// A rule is kept: a soft success.
    static var ruleKept: LooprHaptic { LooprHaptic(.success) }
    /// A ruler or dial reached a new stop.
    static var detent: LooprHaptic { LooprHaptic(.selection) }
    /// A ruler reached a labelled stop, such as a whole kilogram.
    static var majorDetent: LooprHaptic { LooprHaptic(.impact(weight: .medium, intensity: 0.8)) }
}

/// The haptic clock used by the detent modifier.
enum LooprHapticClock {
    static func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
}

public extension View {
    /// Plays `.selection` each time `index` moves to a new stop while `isActive`, at most 30 a second.
    /// Give it the stop a ruler or dial shows; nil means no stop.
    func looprDetentFeedback(_ index: Int?, isActive: Bool = true, major: @escaping @Sendable (Int) -> Bool = { _ in false }) -> some View {
        modifier(LooprDetentFeedback(index: index, isActive: isActive, major: major))
    }
}

struct LooprDetentFeedback: ViewModifier {
    let index: Int?
    let isActive: Bool
    let major: @Sendable (Int) -> Bool
    @State private var limiter = LooprHapticLimiter()
    @State private var haptic: LooprHaptic?

    func body(content: Content) -> some View {
        content
            .onChange(of: index) { old, new in
                guard isActive, let new, old != nil, new != old else { return }
                guard limiter.shouldFire(at: LooprHapticClock.now()) else { return }
                haptic = major(new) ? .majorDetent : .detent
            }
            .looprHaptic(haptic)
    }
}
