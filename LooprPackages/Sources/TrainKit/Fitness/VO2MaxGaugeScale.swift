import Foundation

/// The geometry of the VO2 max gauge: a semicircle a little wider than half a turn (the contract's
/// -112° to 112°), with a value range that holds the FRIEND bands for the person's age and group, the
/// current value and last year's. Angles are degrees clockwise from twelve o'clock, so the lowest value
/// sits lower left and the highest lower right. Pure arithmetic, so the band boundaries and the needle
/// positions can be tested without drawing.
public struct VO2MaxGaugeScale: Equatable, Sendable {
    public static let startAngle = -112.0
    public static let endAngle = 112.0
    /// Ticks every unit, labelled every ten.
    public static let labelStep = 10.0

    /// ml/kg/min at the start of the arc.
    public let lower: Double
    /// ml/kg/min at the end of the arc.
    public let upper: Double

    /// The range runs one band width past the 10th and 75th percentiles on each side, rounded out to
    /// multiples of five, and widens to keep every value in `including` at least two units inside.
    public init(bands: [VO2MaxBand], including values: [Double] = []) {
        let cuts = bands.compactMap(\.lowerBound).sorted()
        let finite = values.filter(\.isFinite)
        guard let first = cuts.first, let last = cuts.last, cuts.count >= 2 else {
            let low = finite.min() ?? 20, high = finite.max() ?? 60
            self.init(lower: Self.floor5(low - 10), upper: Self.ceil5(high + 10))
            return
        }
        var low = first - (cuts[1] - first)
        var high = last + (last - cuts[cuts.count - 2])
        if let minimum = finite.min() { low = min(low, minimum - 2) }
        if let maximum = finite.max() { high = max(high, maximum + 2) }
        self.init(lower: Self.floor5(low), upper: Self.ceil5(high))
    }

    public init(lower: Double, upper: Double) {
        let lower = max(lower, 0)
        self.lower = lower
        self.upper = upper > lower ? upper : lower + 5
    }

    /// Where `value` sits along the arc, 0 at the start and 1 at the end, held at the ends.
    public func fraction(for value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max((value - lower) / (upper - lower), 0), 1)
    }

    /// The needle's angle for `value`.
    public func angle(for value: Double) -> Double {
        Self.startAngle + fraction(for: value) * (Self.endAngle - Self.startAngle)
    }

    /// The value under an angle, for a finger scrubbing the gauge. Held at the ends.
    public func value(atAngle angle: Double) -> Double {
        let fraction = min(max((angle - Self.startAngle) / (Self.endAngle - Self.startAngle), 0), 1)
        return lower + fraction * (upper - lower)
    }

    /// One coloured stretch of the arc.
    public struct Arc: Equatable, Sendable {
        public let band: VO2MaxBandID
        public let startAngle: Double
        public let endAngle: Double
    }

    /// The five bands as arcs, lowest first. An open band runs to the end of the arc.
    public func arcs(for bands: [VO2MaxBand]) -> [Arc] {
        bands.map { band in
            Arc(band: band.id, startAngle: angle(for: band.lowerBound ?? lower), endAngle: angle(for: band.upperBound ?? upper))
        }
    }

    /// Whole values from `lower` to `upper`, for the tick marks.
    public var ticks: [Double] {
        stride(from: lower.rounded(.up), through: upper, by: 1).map { $0 }
    }

    /// The labelled ticks: multiples of ten inside the range.
    public var labels: [Double] {
        stride(from: (lower / Self.labelStep).rounded(.up) * Self.labelStep, through: upper, by: Self.labelStep).map { $0 }
    }

    /// The point on a circle of `radius` around `center` at `angle`, in screen coordinates (y down).
    public static func point(angle: Double, radius: Double, center: CGPoint) -> CGPoint {
        let radians = angle * .pi / 180
        return CGPoint(x: center.x + radius * sin(radians), y: center.y - radius * cos(radians))
    }

    /// The angle of a point around `center`, the inverse of `point(angle:radius:center:)`.
    public static func angle(of point: CGPoint, around center: CGPoint) -> Double {
        atan2(point.x - center.x, center.y - point.y) * 180 / .pi
    }

    static func floor5(_ value: Double) -> Double { (value / 5).rounded(.down) * 5 }
    static func ceil5(_ value: Double) -> Double { (value / 5).rounded(.up) * 5 }
}

/// The band boundaries the gauge snaps to while the person scrubs it: the FRIEND 10th, 25th, 50th
/// and 75th percentiles.
public struct VO2MaxGaugeBoundary: Equatable, Sendable {
    public let percentile: Int
    public let value: Double

    /// "25th percentile"
    public var label: String { "\(percentile)th percentile" }

    public static func boundaries(for bands: [VO2MaxBand]) -> [VO2MaxGaugeBoundary] {
        let percentiles: [VO2MaxBandID: Int] = [.p10ToP25: 10, .p25ToP50: 25, .p50ToP75: 50, .aboveP75: 75]
        return bands.compactMap { band in
            guard let value = band.lowerBound, let percentile = percentiles[band.id] else { return nil }
            return VO2MaxGaugeBoundary(percentile: percentile, value: value)
        }
    }

    /// The boundary nearest `value`, or nil when none is within `reach` ml/kg/min.
    public static func nearest(to value: Double, in boundaries: [VO2MaxGaugeBoundary], reach: Double) -> Int? {
        let ranked = boundaries.enumerated().map { ($0.offset, abs($0.element.value - value)) }.min { $0.1 < $1.1 }
        guard let ranked, ranked.1 <= reach else { return nil }
        return ranked.0
    }
}
