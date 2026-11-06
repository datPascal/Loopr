import DomainKit
import Foundation

/// Every number an experiment result depends on, in one place. A stored result names `version`, so a result from an
/// older engine can be told apart.
public struct ExperimentPolicy: Equatable, Sendable {
    public static let standard = ExperimentPolicy()
    public let version: String
    /// The noise band reads this many nights before day 1.
    public let baselineWindowNights: Int
    /// With fewer baseline nights that have an outcome, there is no band and no result.
    public let minimumBaselineNights: Int
    /// With fewer pairs of back-to-back baseline nights, there is no band and no result.
    public let minimumBaselineDifferences: Int
    /// Width of the likely range.
    public let confidence: Double
    public let bootstrapResamples: Int
    /// Strong needs the cautious end of the range to sit at least this many spreads from zero.
    public let strongSpreadMultiple: Double
    /// Strong needs this many times the minimum nights in each arm.
    public let strongNightsMultiple: Int

    public init(version: String = "experiment.v1", baselineWindowNights: Int = 28, minimumBaselineNights: Int = 10,
                minimumBaselineDifferences: Int = 6, confidence: Double = 0.95, bootstrapResamples: Int = 2_000,
                strongSpreadMultiple: Double = 2, strongNightsMultiple: Int = 2) {
        self.version = version
        self.baselineWindowNights = baselineWindowNights
        self.minimumBaselineNights = minimumBaselineNights
        self.minimumBaselineDifferences = minimumBaselineDifferences
        self.confidence = confidence
        self.bootstrapResamples = bootstrapResamples
        self.strongSpreadMultiple = strongSpreadMultiple
        self.strongNightsMultiple = strongNightsMultiple
    }
}

/// The person's own night-to-night spread of the outcome, read from the nights before day 1.
///
/// The spread is a scaled median absolute deviation of night-to-night differences. A difference between two
/// back-to-back nights cancels the person's slow drift (a bad week, a season), so what is left is the noise a single
/// night adds. The median and the MAD ignore a few wild nights (a late party, an illness) that would inflate a
/// standard deviation and make every result look inside the noise. Two independent nights differ by a spread of
/// sigma times the square root of two, so the MAD is divided by that root, and multiplied by 1.4826 so it reads as a
/// standard deviation for bell-shaped noise. When the MAD is zero (many repeated values) the standard deviation of the
/// differences stands in, so a flat run of ties does not claim a perfectly quiet sleeper.
public struct NoiseBand: Equatable, Sendable {
    public enum Shortfall: Equatable, Sendable {
        case tooFewNights(have: Int, need: Int)
        case tooFewConsecutivePairs(have: Int, need: Int)
    }

    /// Half the width of the band: a difference between arm means inside plus or minus this is inside the noise.
    /// Nil when the baseline was too short.
    public let spread: Double?
    public let shortfall: Shortfall?
    /// Baseline nights with an outcome inside the window.
    public let nights: Int
    /// Back-to-back pairs of those nights.
    public let differences: Int
    public let windowStart: DayIdentity?
    public let windowEnd: DayIdentity?

    public var isReady: Bool { spread != nil }

    /// `baseline` maps a local day to the outcome of the night that starts on it. A night that has no value is
    /// absent from the map; zero counts as a measurement.
    public static func make(baseline: [DayIdentity: Double], startDay: DayIdentity,
                            policy: ExperimentPolicy = .standard) -> NoiseBand {
        let windowStart = startDay.adding(days: -policy.baselineWindowNights)
        let windowEnd = startDay.adding(days: -1)
        var series: [Int: Double] = [:]
        for (day, value) in baseline where value.isFinite {
            guard let offset = windowStart?.days(until: day), (0..<policy.baselineWindowNights).contains(offset) else { continue }
            series[offset] = value
        }
        var differences: [Double] = []
        for offset in series.keys.sorted() {
            if let previous = series[offset - 1], let current = series[offset] { differences.append(current - previous) }
        }
        func band(_ spread: Double?, _ shortfall: Shortfall?) -> NoiseBand {
            NoiseBand(spread: spread, shortfall: shortfall, nights: series.count, differences: differences.count,
                      windowStart: windowStart, windowEnd: windowEnd)
        }
        guard series.count >= policy.minimumBaselineNights else {
            return band(nil, .tooFewNights(have: series.count, need: policy.minimumBaselineNights))
        }
        guard differences.count >= policy.minimumBaselineDifferences else {
            return band(nil, .tooFewConsecutivePairs(have: differences.count, need: policy.minimumBaselineDifferences))
        }
        return band(ExperimentStatistics.nightToNightSpread(differences: differences), nil)
    }
}

public enum ExperimentStatistics {
    public static func mean(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    public static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }

    /// The scaled MAD of night-to-night differences, divided by the square root of two. See `NoiseBand`.
    public static func nightToNightSpread(differences: [Double]) -> Double? {
        guard let center = median(differences), let mad = median(differences.map { abs($0 - center) }) else { return nil }
        let normal = 1.4826 / 2.0.squareRoot()
        if mad > 0 { return mad * normal }
        guard differences.count > 1, let average = mean(differences) else { return 0 }
        let variance = differences.map { ($0 - average) * ($0 - average) }.reduce(0, +) / Double(differences.count - 1)
        return variance.squareRoot() / 2.0.squareRoot()
    }

    /// SplitMix64. It is written out here instead of using the system generator so a seed gives the same interval on
    /// every device and OS version.
    public struct SeededGenerator: RandomNumberGenerator, Sendable {
        private var state: UInt64
        public init(seed: UInt64) { state = seed }
        public mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// A stable seed for one experiment, so its result does not change from one launch to the next. FNV-1a over the
    /// id's text; Swift's own hashing is randomised per process.
    public static func seed(for id: ExperimentID) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in id.rawValue.uuidString.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }

    /// A percentile bootstrap interval for the difference of means (`on` minus `off`). Each arm is resampled with
    /// replacement on its own, `resamples` times, with the seeded generator. With few nights a percentile interval is
    /// a little narrow, which is one reason Strong asks for twice the minimum nights.
    public static func bootstrapInterval(on: [Double], off: [Double], seed: UInt64, resamples: Int,
                                         confidence: Double) -> ClosedRange<Double>? {
        guard !on.isEmpty, !off.isEmpty, resamples > 0 else { return nil }
        var generator = SeededGenerator(seed: seed)
        func resampledMean(_ values: [Double]) -> Double {
            var total = 0.0
            for _ in values { total += values[Int(generator.next() % UInt64(values.count))] }
            return total / Double(values.count)
        }
        var differences: [Double] = []
        differences.reserveCapacity(resamples)
        for _ in 0..<resamples {
            let onMean = resampledMean(on)
            let offMean = resampledMean(off)
            differences.append(onMean - offMean)
        }
        differences.sort()
        let tail = (1 - min(max(confidence, 0), 1)) / 2
        let lower = min(max(Int((tail * Double(resamples)).rounded(.down)), 0), resamples - 1)
        let upper = min(max(Int(((1 - tail) * Double(resamples)).rounded(.up)) - 1, 0), resamples - 1)
        return differences[lower]...differences[max(upper, lower)]
    }
}
