import CoreGraphics
import Foundation

/// One dot resting by a ring's end.
public struct FoodRingDot: Equatable, Sendable {
    /// Degrees clockwise from twelve o'clock.
    public let angle: Double
    /// Points off the ring's centre line, outwards positive.
    public let radialOffset: Double
    public let diameter: Double
    /// Which colour of the ring's palette the dot wears.
    public let colorIndex: Int
    /// Where the dot comes from while it settles, in points from its resting place.
    public let settleFrom: CGVector
    /// Seconds before its settle starts.
    public let delay: Double
}

/// The dots the camera's finish leaves on the rings (contract p-food: "still settling around their ends"). A small,
/// still set rests by each ring's end, spread over the last 30° of the arc and a little past it, across the ring's
/// width. The set depends only on the day, the ring and its fill, so a dot never jumps between renders, and an empty
/// ring has none.
public enum FoodRingDots {
    /// The most dots on one ring, the contract's count.
    public static let maximum = 16

    /// - Parameters:
    ///   - fraction: the ring's fill, 0 to 1. Zero or less gives no dots.
    ///   - lineWidth: the ring's stroke width in points.
    ///   - weights: the share of each palette colour. The calorie ring passes protein, carbs and fat energy so the dots
    ///     keep the finish's macro colours; a macro ring passes one weight.
    ///   - seed: a stable number for the day and ring.
    public static func dots(fraction: Double, lineWidth: Double, weights: [Double], seed: UInt64) -> [FoodRingDot] {
        guard fraction.isFinite, fraction > 0 else { return [] }
        let filled = min(fraction, 1)
        let count = min(maximum, max(6, Int((filled * 24).rounded())))
        let end = filled * 360
        let span = min(30, end)
        var random = SeededGenerator(seed: seed)
        let colors = colorIndices(count: count, weights: weights)
        return (0..<count).map { index in
            let angle = end - span + random.unit() * (span + 4)
            let offset = (random.unit() - 0.5) * (lineWidth + 14)
            let diameter = 2.4 + random.unit() * 3.6
            let from = CGVector(dx: (random.unit() - 0.5) * 160, dy: -80 - random.unit() * 120)
            return FoodRingDot(angle: angle, radialOffset: offset, diameter: diameter, colorIndex: colors[index],
                               settleFrom: from, delay: 0.2 + Double(index) * 0.05)
        }
    }

    /// Spreads `count` dots over the colours in proportion to `weights`, largest remainders first, then shuffles them
    /// into a fixed order so the colours mix along the arc.
    static func colorIndices(count: Int, weights: [Double]) -> [Int] {
        let clean = weights.map { $0.isFinite && $0 > 0 ? $0 : 0 }
        let total = clean.reduce(0, +)
        guard total > 0, count > 0 else { return Array(repeating: 0, count: max(count, 0)) }
        let exact = clean.map { $0 / total * Double(count) }
        var shares = exact.map { Int($0.rounded(.down)) }
        let order = exact.indices.sorted { (exact[$0] - Double(shares[$0]), -$0) > (exact[$1] - Double(shares[$1]), -$1) }
        for index in order.prefix(count - shares.reduce(0, +)) { shares[index] += 1 }
        let flat = shares.enumerated().flatMap { Array(repeating: $0.offset, count: $0.element) }
        // Interleave: every k-th dot, so no colour bunches at one end.
        let stride = flat.count > 2 ? 5 : 1
        var result: [Int] = []
        var used = Set<Int>()
        var cursor = 0
        while result.count < flat.count {
            while used.contains(cursor % flat.count) { cursor += 1 }
            used.insert(cursor % flat.count); result.append(flat[cursor % flat.count])
            cursor += stride
        }
        return result
    }

    /// A seed from a day key and a ring number, stable across launches.
    public static func seed(localDay: String, ring: Int) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in localDay.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        return hash ^ UInt64(ring + 1) &* 0x9E37_79B9_7F4A_7C15
    }
}

/// SplitMix64: a small generator that gives the same numbers for the same seed on every device.
struct SeededGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    /// 0 up to 1.
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}
