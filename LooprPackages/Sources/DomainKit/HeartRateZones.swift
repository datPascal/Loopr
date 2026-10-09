import Foundation

public enum HeartRateMaximumSource: String, Codable, Sendable {
    case estimated
    case observed
    case manual
}

public struct ReliableHeartRateSample: Equatable, Sendable {
    public let time: TimeInterval
    public let bpm: Double
    public let goodSignal: Bool

    public init(time: TimeInterval, bpm: Double, goodSignal: Bool) {
        self.time = time
        self.bpm = bpm
        self.goodSignal = goodSignal
    }
}

/// The one persisted definition used by live Heart and Body derivation.
/// Percentages are whole points to make the minimum separation unambiguous.
public struct HeartRateZoneSettings: Codable, Equatable, Sendable {
    public static let defaultBoundaries = [60, 70, 80, 90]
    public var observedMaximum: Double?
    public var manualMaximum: Double?
    public private(set) var innerBoundaries: [Int]

    public init(observedMaximum: Double? = nil, manualMaximum: Double? = nil,
                innerBoundaries: [Int] = defaultBoundaries) {
        self.observedMaximum = Self.validMaximum(observedMaximum)
        self.manualMaximum = Self.validMaximum(manualMaximum)
        self.innerBoundaries = Self.validBoundaries(innerBoundaries) ? innerBoundaries : Self.defaultBoundaries
    }

    private enum CodingKeys: String, CodingKey {
        case observedMaximum, manualMaximum, innerBoundaries
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            observedMaximum: try values.decodeIfPresent(Double.self, forKey: .observedMaximum),
            manualMaximum: try values.decodeIfPresent(Double.self, forKey: .manualMaximum),
            innerBoundaries: try values.decodeIfPresent([Int].self, forKey: .innerBoundaries) ?? Self.defaultBoundaries)
    }

    public static func validMaximum(_ value: Double?) -> Double? {
        guard let value, value.isFinite, (100...240).contains(value) else { return nil }
        return value
    }

    public static func validBoundaries(_ values: [Int]) -> Bool {
        guard values.count == 4 else { return false }
        let edges = [50] + values + [100]
        return zip(edges, edges.dropFirst()).allSatisfy { $1 - $0 >= 5 }
    }

    @discardableResult public mutating func setBoundaries(_ values: [Int]) -> Bool {
        guard Self.validBoundaries(values) else { return false }
        innerBoundaries = values
        return true
    }

    public mutating func resetBoundaries() { innerBoundaries = Self.defaultBoundaries }
    public mutating func resetMaximum() { manualMaximum = nil }

    /// A high value raises the automatic maximum only after at least ten
    /// continuous seconds above the current automatic value with good signal.
    public mutating func observe(_ samples: [ReliableHeartRateSample], age: Int?) {
        guard let age, (13...120).contains(age) else { return }
        let current = max(208 - 0.7 * Double(age), observedMaximum ?? 0)
        let sorted = samples.sorted { $0.time < $1.time }
        var start: TimeInterval?
        var previous: TimeInterval?
        var peak = 0.0
        for sample in sorted + [ReliableHeartRateSample(time: .infinity, bpm: 0, goodSignal: false)] {
            let qualifies = sample.goodSignal && sample.time.isFinite && sample.bpm.isFinite
                && sample.bpm > current && sample.bpm <= 240
                && (previous == nil || sample.time - previous! <= 2)
            if qualifies {
                if start == nil { start = sample.time; peak = sample.bpm }
                peak = max(peak, sample.bpm)
                previous = sample.time
            } else {
                if let start, let previous, previous - start >= 10 {
                    observedMaximum = max(observedMaximum ?? 0, peak)
                }
                start = nil
                previous = nil
                peak = 0
            }
        }
    }

    public func resolved(age: Int?, restingNights: [Double] = []) -> HeartRateZones? {
        // An observed peak alone cannot stand in for a missing age. It is a
        // raise to the age estimate, never a way to guess from sparse data.
        let estimate = age.flatMap { (13...120).contains($0) ? 208 - 0.7 * Double($0) : nil }
        let maximum: Double
        let source: HeartRateMaximumSource
        if let manual = Self.validMaximum(manualMaximum) {
            maximum = manual; source = .manual
        } else if let estimate, let observed = Self.validMaximum(observedMaximum), observed > estimate {
            maximum = observed; source = .observed
        } else if let estimate {
            maximum = estimate; source = .estimated
        } else {
            return nil
        }
        return HeartRateZones(maximum: maximum, source: source,
                              boundaries: Self.validBoundaries(innerBoundaries) ? innerBoundaries : Self.defaultBoundaries,
                              restingHeartRate: HeartRateZones.restingMedian(restingNights, maximum: maximum))
    }
}

public struct HeartRateZones: Equatable, Sendable {
    public let maximum: Double
    public let source: HeartRateMaximumSource
    public let boundaries: [Int]
    public let restingHeartRate: Double?

    public init(maximum: Double, source: HeartRateMaximumSource, boundaries: [Int], restingHeartRate: Double? = nil) {
        self.maximum = maximum
        self.source = source
        self.boundaries = boundaries
        self.restingHeartRate = Self.restingMedian(restingHeartRate.map { [$0] } ?? [], maximum: maximum)
    }

    /// Matches the target's median of the latest 14 valid band resting-HR values.
    public static func restingMedian(_ nights: [Double], maximum: Double) -> Double? {
        let values = Array(nights.filter { $0.isFinite && (30...120).contains($0) && $0 < maximum }.suffix(14)).sorted()
        guard !values.isEmpty else { return nil }
        let middle = values.count / 2
        return values.count.isMultiple(of: 2) ? (values[middle - 1] + values[middle]) / 2 : values[middle]
    }

    public var calculationSource: String {
        restingHeartRate == nil ? "From max heart rate" : "From your resting and max heart rate"
    }

    public func bpmBoundary(percent: Int) -> Double {
        let resting = restingHeartRate ?? 0
        // Multiply first so exact integer edges such as 55% of 180 stay exact.
        return resting + Double(percent) * (maximum - resting) / 100
    }

    public var edges: [Int] { [50] + boundaries + [100] }

    public func number(for bpm: Double) -> Int {
        guard bpm.isFinite, bpm > 0 else { return 0 }
        return edges.dropLast().lastIndex(where: { bpm >= bpmBoundary(percent: $0) }).map { $0 + 1 } ?? 0
    }

    public func bpmRange(for number: Int) -> ClosedRange<Int>? {
        guard (1...5).contains(number) else { return nil }
        let lower = Int(ceil(bpmBoundary(percent: edges[number - 1])))
        let upper = number == 5 ? Int(maximum.rounded()) : Int(ceil(bpmBoundary(percent: edges[number]))) - 1
        return lower...max(lower, upper)
    }
}
