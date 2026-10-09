import Foundation

/// One Poincaré pair: an interval and the one after it, in whole ms.
public struct PoincarePoint: Codable, Sendable, Equatable {
    public let current: Int
    public let next: Int
    public init(current: Int, next: Int) {
        self.current = current
        self.next = next
    }
}

/// The mean interval over one slice of the night.
public struct TachogramPoint: Codable, Sendable, Equatable {
    /// Minutes from the first clean beat.
    public let minute: Double
    public let meanIntervalMilliseconds: Double
    public init(minute: Double, meanIntervalMilliseconds: Double) {
        self.minute = minute
        self.meanIntervalMilliseconds = meanIntervalMilliseconds
    }
}

/// A descriptive picture of the night's beat intervals. It classifies nothing.
public struct BeatToBeatSummary: Codable, Sendable, Equatable {
    /// Spread across the identity line: short-term, beat-to-beat change.
    /// Equals RMSSD / √2 when every pair is used.
    public let sd1Milliseconds: Double
    /// Spread along the identity line: longer-term change.
    public let sd2Milliseconds: Double
    public let meanIntervalMilliseconds: Double
    public let beatCount: Int
    public let pairCount: Int
    /// At most `BeatToBeatAnalytics.maximumPlotPoints`, evenly thinned.
    public let points: [PoincarePoint]
    public let tachogram: [TachogramPoint]
    public let algorithmVersion: String

    public init(sd1Milliseconds: Double, sd2Milliseconds: Double, meanIntervalMilliseconds: Double, beatCount: Int,
                pairCount: Int, points: [PoincarePoint], tachogram: [TachogramPoint],
                algorithmVersion: String = VitalsAlgorithmVersion.beatToBeat) {
        self.sd1Milliseconds = sd1Milliseconds
        self.sd2Milliseconds = sd2Milliseconds
        self.meanIntervalMilliseconds = meanIntervalMilliseconds
        self.beatCount = beatCount
        self.pairCount = pairCount
        self.points = points
        self.tachogram = tachogram
        self.algorithmVersion = algorithmVersion
    }

    public var sd1ToSd2Ratio: Double? { sd2Milliseconds > 0 ? sd1Milliseconds / sd2Milliseconds : nil }
}

public enum BeatToBeatAnalytics {
    public static let maximumPlotPoints = 400
    public static let tachogramBucketSeconds = 120.0
    public static let minimumPairs = 100

    /// - Parameters:
    ///   - intervals: cleaned normal intervals (`RRQuality` output), ms.
    ///   - beatTimesMilliseconds: their monotonic beat clock, same length.
    ///     A pair is used only when the second beat directly follows the
    ///     first, the same gap rule `HRVTime.derive` applies.
    public static func summarize(_ intervals: [Double], beatTimesMilliseconds: [Double]) -> AnalyticsMetric<BeatToBeatSummary> {
        let inputs = ["rr_cleaned"]
        guard intervals.count == beatTimesMilliseconds.count, intervals.count >= 2 else {
            return .absent(tier: .high, inputsUsed: inputs, note: "too few clean beats",
                algorithmVersion: VitalsAlgorithmVersion.beatToBeat)
        }
        var across: [Double] = []
        var along: [Double] = []
        var pairs: [PoincarePoint] = []
        across.reserveCapacity(intervals.count)
        along.reserveCapacity(intervals.count)
        pairs.reserveCapacity(intervals.count)
        for index in 1..<intervals.count {
            if beatTimesMilliseconds[index] - beatTimesMilliseconds[index - 1] > intervals[index] + 0.5 { continue }
            let x = intervals[index - 1], y = intervals[index]
            across.append((y - x) / 2.0.squareRoot())
            along.append((y + x) / 2.0.squareRoot())
            pairs.append(PoincarePoint(current: Int(x.rounded()), next: Int(y.rounded())))
        }
        guard pairs.count >= minimumPairs,
              let sd1 = AnalyticsMath.sampleStandardDeviation(across),
              let sd2 = AnalyticsMath.sampleStandardDeviation(along),
              let mean = AnalyticsMath.mean(intervals) else {
            return .absent(tier: .high, inputsUsed: inputs, note: "fewer than \(minimumPairs) consecutive clean pairs",
                algorithmVersion: VitalsAlgorithmVersion.beatToBeat)
        }
        let step = max(1, Int((Double(pairs.count) / Double(maximumPlotPoints)).rounded(.up)))
        let thinned = stride(from: 0, to: pairs.count, by: step).map { pairs[$0] }

        let origin = beatTimesMilliseconds[0]
        var buckets: [Int: (sum: Double, count: Int)] = [:]
        for (interval, time) in zip(intervals, beatTimesMilliseconds) {
            let key = Int((time - origin) / 1_000 / tachogramBucketSeconds)
            let current = buckets[key] ?? (0, 0)
            buckets[key] = (current.sum + interval, current.count + 1)
        }
        let tachogram = buckets.keys.sorted().compactMap { key -> TachogramPoint? in
            guard let bucket = buckets[key], bucket.count >= 10 else { return nil }
            return TachogramPoint(minute: Double(key) * tachogramBucketSeconds / 60,
                meanIntervalMilliseconds: bucket.sum / Double(bucket.count))
        }
        let summary = BeatToBeatSummary(sd1Milliseconds: sd1, sd2Milliseconds: sd2, meanIntervalMilliseconds: mean,
            beatCount: intervals.count, pairCount: pairs.count, points: thinned, tachogram: tachogram)
        return AnalyticsMetric(value: summary, confidence: AnalyticsMath.clamp(Double(pairs.count) / 2_000, 0.3, 0.9),
            tier: .high, inputsUsed: inputs, note: "descriptive Poincaré and tachogram; no classification",
            algorithmVersion: VitalsAlgorithmVersion.beatToBeat)
    }
}
