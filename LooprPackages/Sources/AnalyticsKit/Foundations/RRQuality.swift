import Foundation

public enum BeatClass: String, Codable, Sendable, Equatable {
    case normal
    case ectopic
    case longShort
    case missed
    case extra
}

public struct RRCorrectionResult: Codable, Sendable, Equatable {
    public let normalIntervalsMilliseconds: [Double]
    public let normalTimesMilliseconds: [Double]
    public let classes: [BeatClass]
    public let cleanFraction: Double
    public let droppedCount: Int
    public let correctedCount: Int
    public let algorithmVersion: String

    public init(
        normalIntervalsMilliseconds: [Double],
        normalTimesMilliseconds: [Double],
        classes: [BeatClass],
        cleanFraction: Double,
        droppedCount: Int,
        correctedCount: Int,
        algorithmVersion: String = AnalyticsAlgorithmVersion.rrQuality
    ) {
        self.normalIntervalsMilliseconds = normalIntervalsMilliseconds
        self.normalTimesMilliseconds = normalTimesMilliseconds
        self.classes = classes
        self.cleanFraction = cleanFraction
        self.droppedCount = droppedCount
        self.correctedCount = correctedCount
        self.algorithmVersion = algorithmVersion
    }

    public var artifactFraction: Double { 1 - cleanFraction }
}

/// A quality-qualified cleaned RR series.  This is intentionally a wrapper
/// around `RRQuality.correct`; the pinned primitive still returns its full
/// diagnostic result even when this publication gate withholds the metric.
public struct RRQualityGateValue: Codable, Sendable, Equatable {
    public let normalIntervalsMilliseconds: [Double]
    public let normalTimesMilliseconds: [Double]
    public let classes: [BeatClass]
    public let cleanFraction: Double
    public let droppedCount: Int
    public let correctedCount: Int
    public let algorithmVersion: String

    public init(correction: RRCorrectionResult, algorithmVersion: String = AnalyticsAlgorithmVersion.rrQuality) {
        self.normalIntervalsMilliseconds = correction.normalIntervalsMilliseconds
        self.normalTimesMilliseconds = correction.normalTimesMilliseconds
        self.classes = correction.classes
        self.cleanFraction = correction.cleanFraction
        self.droppedCount = correction.droppedCount
        self.correctedCount = correction.correctedCount
        self.algorithmVersion = algorithmVersion
    }
}

public enum RRQuality {
    /// Publication gate used by downstream metric consumers.  The 0.5 clean
    /// fraction and 30-beat minimum match the existing stress-index RR gate;
    /// the correction primitive itself remains ungated and fully diagnostic.
    public static let minimumMetricCleanFraction = 0.5
    public static let minimumMetricIntervals = 30

    public static func gated(
        _ intervals: [Double],
        beatTimestampsMilliseconds: [Double]? = nil,
        alpha: Double = 5.2,
        windowBeats: Int = 91,
        minimumThresholdMilliseconds: Double = 100,
        minimumCleanFraction: Double = minimumMetricCleanFraction,
        minimumIntervals: Int = minimumMetricIntervals
    ) -> AnalyticsMetric<RRQualityGateValue> {
        let correction = correct(
            intervals,
            beatTimestampsMilliseconds: beatTimestampsMilliseconds,
            alpha: alpha,
            windowBeats: windowBeats,
            minimumThresholdMilliseconds: minimumThresholdMilliseconds
        )
        let accepted = correction.normalIntervalsMilliseconds.count >= minimumIntervals && correction.cleanFraction >= minimumCleanFraction
        guard accepted else {
            return .absent(
                tier: .high,
                inputsUsed: ["rr_raw", "rr_cleaned", "rr_quality"],
                note: "RR quality below gate; cleaned RR metric withheld (need ≥\(minimumIntervals) clean beats and ≥\(AnalyticsMath.round6(minimumCleanFraction)) clean fraction)",
                algorithmVersion: AnalyticsAlgorithmVersion.rrQuality
            )
        }
        let value = RRQualityGateValue(correction: correction)
        return AnalyticsMetric(
            value: value,
            confidence: AnalyticsMath.clamp(correction.cleanFraction, 0.3, 0.9),
            tier: .high,
            inputsUsed: ["rr_raw", "rr_cleaned", "rr_quality"],
            note: "RR quality gate passed; cleaned NN is safe for downstream metrics",
            algorithmVersion: AnalyticsAlgorithmVersion.rrQuality
        )
    }

    public static func qualityGate(
        _ intervals: [Double],
        beatTimestampsMilliseconds: [Double]? = nil,
        minimumCleanFraction: Double = minimumMetricCleanFraction,
        minimumIntervals: Int = minimumMetricIntervals
    ) -> AnalyticsMetric<RRQualityGateValue> {
        gated(
            intervals,
            beatTimestampsMilliseconds: beatTimestampsMilliseconds,
            minimumCleanFraction: minimumCleanFraction,
            minimumIntervals: minimumIntervals
        )
    }

    /// Lipponen–Tarvainen dRR/mRR/sRR detector with isolated-beat Catmull-Rom
    /// correction. Runs of two or more artifacts are dropped, never bridged.
    public static func correct(
        _ intervals: [Double],
        beatTimestampsMilliseconds: [Double]? = nil,
        alpha: Double = 5.2,
        windowBeats: Int = 91,
        minimumThresholdMilliseconds: Double = 100,
        reanchorGapMilliseconds: Double = 1_000
    ) -> RRCorrectionResult {
        let count = intervals.count
        let beatTimes = beatTimes(
            intervals,
            timestampsMilliseconds: beatTimestampsMilliseconds,
            reanchorGapMilliseconds: reanchorGapMilliseconds
        )
        guard count > 0 else {
            return RRCorrectionResult(normalIntervalsMilliseconds: [], normalTimesMilliseconds: [], classes: [], cleanFraction: 0, droppedCount: 0, correctedCount: 0)
        }
        if count < 3 {
            let classes = intervals.map { $0 >= 300 && $0 <= 2_000 ? BeatClass.normal : .longShort }
            var normal: [Double] = []
            var times: [Double] = []
            for (index, value) in intervals.enumerated() where classes[index] == .normal {
                normal.append(value)
                times.append(beatTimes[index])
            }
            return RRCorrectionResult(
                normalIntervalsMilliseconds: normal,
                normalTimesMilliseconds: times,
                classes: classes,
                cleanFraction: Double(normal.count) / Double(count),
                droppedCount: count - normal.count,
                correctedCount: 0
            )
        }

        var differences = Array(repeating: 0.0, count: count)
        for index in 1..<count { differences[index] = intervals[index] - intervals[index - 1] }
        let thresholdOne = slidingThreshold(differences, window: windowBeats, alpha: alpha, floor: minimumThresholdMilliseconds)
        let medians = slidingMedian(intervals, window: windowBeats)
        let mRR = intervals.enumerated().map { index, value in
            let delta = value - medians[index]
            return delta < 0 ? delta * 2 : delta
        }
        let thresholdTwo = slidingThreshold(mRR, window: windowBeats, alpha: alpha, floor: minimumThresholdMilliseconds)

        var classes = Array(repeating: BeatClass.normal, count: count)
        for index in intervals.indices {
            let value = intervals[index]
            let hardLong = value > 2_000
            let hardShort = value < 300
            let bigJump = abs(differences[index]) > thresholdOne[index]
            let bigDeviation = abs(mRR[index]) > thresholdTwo[index]
            if hardLong || (bigDeviation && mRR[index] > 0) {
                classes[index] = medians[index] > 0 && value > 1.5 * medians[index] ? .missed : .longShort
            } else if hardShort || (bigDeviation && mRR[index] < 0) {
                classes[index] = medians[index] > 0 && value < 0.6 * medians[index] ? .extra : .longShort
            } else if bigJump {
                classes[index] = .ectopic
            }
        }

        // A compensatory pair's second dRR jump is a recovery beat, not a
        // second artifact. Keep the exact upstream demotion rule.
        if count > 1 {
            for index in 1..<count where classes[index] == .ectopic {
                let previous = classes[index - 1]
                let previousBad = previous == .extra || previous == .missed || previous == .ectopic || previous == .longShort
                guard previousBad else { continue }
                let oppositeSign = differences[index] * differences[index - 1] < 0
                let value = intervals[index]
                let valueNormal = medians[index] > 0 && value >= 300 && value <= 2_000 && abs(value - medians[index]) <= 0.2 * medians[index]
                if oppositeSign && valueNormal { classes[index] = .normal }
            }
        }

        let artifacts = classes.map { $0 != .normal }
        var normal: [Double] = []
        var times: [Double] = []
        var dropped = 0
        var corrected = 0
        var index = 0
        while index < count {
            if !artifacts[index] {
                normal.append(intervals[index])
                times.append(beatTimes[index])
                index += 1
                continue
            }
            var end = index
            while end < count && artifacts[end] { end += 1 }
            let length = end - index
            if length == 1 {
                if let value = splineCorrect(intervals, artifacts: artifacts, index: index) {
                    normal.append(value)
                    times.append(beatTimes[index])
                    corrected += 1
                } else {
                    dropped += 1
                }
            } else {
                dropped += length
            }
            index = end
        }
        let normalCount = classes.filter { $0 == .normal }.count
        return RRCorrectionResult(
            normalIntervalsMilliseconds: normal,
            normalTimesMilliseconds: times,
            classes: classes,
            cleanFraction: Double(normalCount) / Double(count),
            droppedCount: dropped,
            correctedCount: corrected
        )
    }

    public static func physiologicallyPlausible(_ intervals: [Double]) -> Bool {
        guard !intervals.isEmpty else { return false }
        for index in intervals.indices {
            let interval = intervals[index]
            guard interval >= 300 && interval <= 2_000 else { return false }
            if index > 0 {
                let previous = intervals[index - 1]
                guard max(interval, previous) / min(interval, previous) <= 3 else { return false }
            }
        }
        return true
    }

    /// The shared monotonic beat clock, in milliseconds from the first beat.
    ///
    /// Every consumer of RR timing must use this. Packet timestamps are whole
    /// seconds, so several beats in one packet carry the same wall-clock value;
    /// feeding those duplicates straight into a spectral estimator collapses
    /// the within-packet spacing and biases every band power.
    public static func monotonicBeatTimesMilliseconds(
        _ intervals: [Double],
        timestampsMilliseconds: [Double]? = nil,
        reanchorGapMilliseconds: Double = 1_000
    ) -> [Double] {
        beatTimes(
            intervals,
            timestampsMilliseconds: timestampsMilliseconds,
            reanchorGapMilliseconds: reanchorGapMilliseconds
        )
    }

    /// Builds a monotonic beat clock. Packet timestamps are whole-second
    /// anchors, while RR values retain the sub-second spacing within a run.
    /// A large timestamp step re-anchors the clock instead of pretending that
    /// the first interval after a sensor dropout followed the previous packet.
    private static func beatTimes(
        _ intervals: [Double],
        timestampsMilliseconds: [Double]?,
        reanchorGapMilliseconds: Double
    ) -> [Double] {
        guard !intervals.isEmpty else { return [] }
        let hasWallClock = timestampsMilliseconds?.count == intervals.count
        let timestamps = hasWallClock ? timestampsMilliseconds : nil
        let origin = timestamps.map { $0[0] - intervals[0] } ?? 0
        var current = 0.0
        var output = Array(repeating: 0.0, count: intervals.count)

        for index in intervals.indices {
            let dropout: Bool
            if let timestamps, index > 0 {
                dropout = (timestamps[index] - timestamps[index - 1]) - intervals[index] > reanchorGapMilliseconds
            } else {
                dropout = false
            }
            let anchored = timestamps.map { $0[index] - origin } ?? 0
            current = dropout && anchored > current ? anchored : current + intervals[index]
            output[index] = current
        }
        return output
    }

    // Both sliding statistics below used to sort a fresh 91-element array at
    // every beat, which is where most of a day's RR cleaning time went. The
    // window is now carried sorted across indices. The multiset each
    // percentile reads is identical, so the numbers are identical.
    private static func slidingThreshold(_ values: [Double], window: Int, alpha: Double, floor: Double) -> [Double] {
        guard !values.isEmpty else { return [] }
        var output = [Double](repeating: 0, count: values.count)
        withSlidingWindow(count: values.count, half: window / 2, value: { values[$0] }) { index, window in
            let first = window.percentile(25) ?? 0
            let third = window.percentile(75) ?? 0
            output[index] = max(alpha * ((third - first) / 2), floor)
        }
        return output
    }

    private static func slidingMedian(_ values: [Double], window: Int) -> [Double] {
        guard !values.isEmpty else { return [] }
        var output = [Double](repeating: 0, count: values.count)
        withSlidingWindow(count: values.count, half: window / 2, value: { values[$0] }) { index, window in
            output[index] = window.median(excluding: values[index]) ?? values[index]
        }
        return output
    }

    private static func splineCorrect(_ values: [Double], artifacts: [Bool], index: Int) -> Double? {
        var left: [Double] = []
        var cursor = index - 1
        while cursor >= 0 && left.count < 2 {
            if !artifacts[cursor] { left.insert(values[cursor], at: 0) }
            cursor -= 1
        }
        var right: [Double] = []
        cursor = index + 1
        while cursor < values.count && right.count < 2 {
            if !artifacts[cursor] { right.append(values[cursor]) }
            cursor += 1
        }
        guard let p1 = left.last, let p2 = right.first else { return nil }
        let p0 = left.count >= 2 ? left[left.count - 2] : p1
        let p3 = right.count >= 2 ? right[1] : p2
        let t = 0.5
        let t2 = t * t
        let t3 = t2 * t
        return 0.5 * ((2 * p1) + (-p0 + p2) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2 + (-p0 + 3 * p1 - 3 * p2 + p3) * t3)
    }
}

public struct PPGQualityResult: Codable, Sendable, Equatable {
    public let trusted: Bool
    public let skewness: Double
    public let reasons: [String]
    public let algorithmVersion: String
}

public enum PPGQuality {
    public static func skewness(_ window: [Double]) -> Double {
        guard window.count >= 3,
              let mean = AnalyticsMath.mean(window),
              let standardDeviation = AnalyticsMath.populationStandardDeviation(window),
              standardDeviation != 0 else { return 0 }
        return window.reduce(0) { partial, value in
            let normalized = (value - mean) / standardDeviation
            return partial + normalized * normalized * normalized
        } / Double(window.count)
    }

    public static func trust(_ window: [Double], heartRate: Double, minimumSkewness: Double = -0.1) -> PPGQualityResult {
        var reasons: [String] = []
        let skew = skewness(window)
        if heartRate <= 0 { reasons.append("off-skin") }
        else if heartRate < 40 || heartRate > 180 { reasons.append("hr-out-of-range") }
        if window.isEmpty { reasons.append("no-ppg") }
        else if skew < minimumSkewness { reasons.append("low-skewness") }
        if !window.isEmpty,
           let standardDeviation = AnalyticsMath.populationStandardDeviation(window),
           let average = AnalyticsMath.mean(window) {
            if standardDeviation == 0 || (average != 0 && standardDeviation / abs(average) < 1e-4) { reasons.append("flatline") }
        }
        return PPGQualityResult(trusted: reasons.isEmpty, skewness: skew, reasons: reasons, algorithmVersion: AnalyticsAlgorithmVersion.rrQuality)
    }
}

public struct FusionInput: Codable, Sendable, Equatable {
    public let value: Double
    public let variance: Double
    public let trusted: Bool
    public let label: String
    public init(value: Double, variance: Double, trusted: Bool = true, label: String = "") {
        self.value = value; self.variance = variance; self.trusted = trusted; self.label = label
    }
}

public struct FusionResult: Codable, Sendable, Equatable {
    public let value: Double?
    public let variance: Double?
    public let standardUncertainty: Double?
    public let used: [String]
    public let dropped: [String]
    public let algorithmVersion: String
}

public enum SignalFusion {
    public static func inverseVariance(_ inputs: [FusionInput]) -> FusionResult {
        var used: [String] = []
        var dropped: [String] = []
        var weightSum = 0.0
        var valueWeightSum = 0.0
        for input in inputs {
            guard input.trusted, input.variance > 0, input.value.isFinite else { dropped.append(input.label); continue }
            let weight = 1 / input.variance
            weightSum += weight
            valueWeightSum += input.value * weight
            used.append(input.label)
        }
        guard weightSum > 0 else {
            return FusionResult(value: nil, variance: nil, standardUncertainty: nil, used: [], dropped: dropped, algorithmVersion: AnalyticsAlgorithmVersion.rrQuality)
        }
        let variance = 1 / weightSum
        return FusionResult(value: valueWeightSum / weightSum, variance: variance, standardUncertainty: sqrt(variance), used: used, dropped: dropped, algorithmVersion: AnalyticsAlgorithmVersion.rrQuality)
    }

    public static func varianceFromQuality(_ quality: Double, baseVariance: Double, floor: Double = 0.05) -> Double {
        let clamped = AnalyticsMath.clamp(quality, floor, 1)
        return baseVariance / clamped
    }

    public static func gumWeightedSumUncertainty(weights: [Double], standardUncertainties: [Double]) -> Double? {
        guard weights.count == standardUncertainties.count, !weights.isEmpty else { return nil }
        let sum = zip(weights, standardUncertainties).reduce(0) { partial, pair in
            let term = pair.0 * pair.1
            return partial + term * term
        }
        return sqrt(sum)
    }
}
