import Foundation
import Dispatch

public struct HRVTimeValue: Codable, Sendable, Equatable {
    public let rmssdMilliseconds: Double?
    public let sdnnMilliseconds: Double?
    public let sdannMilliseconds: Double?
    public let sdnnIndexMilliseconds: Double?
    public let pNN50Percent: Double?
    public let beatCount: Int
    public let algorithmVersion: String
}
public enum HRVTime {
    public static func derive(_ intervals: [Double], beatTimesMilliseconds: [Double]? = nil) -> AnalyticsMetric<HRVTimeValue> {
        let inputs = ["rr_cleaned"]
        guard intervals.count >= 2 else {
            return .absent(tier: .high, inputsUsed: inputs, note: "too few NN intervals", algorithmVersion: AnalyticsAlgorithmVersion.hrv)
        }
        let gapAware = beatTimesMilliseconds?.count == intervals.count
        var sumSquared = 0.0
        var countAbove = 0
        var pairCount = 0
        for index in 1..<intervals.count {
            if gapAware,
               let beatTimesMilliseconds,
               beatTimesMilliseconds[index] - beatTimesMilliseconds[index - 1] > intervals[index] + 0.5 {
                continue
            }
            let difference = intervals[index] - intervals[index - 1]
            sumSquared += difference * difference
            if abs(difference) > 50 { countAbove += 1 }
            pairCount += 1
        }
        let rmssd = pairCount > 0 ? sqrt(sumSquared / Double(pairCount)) : nil
        let pNN50 = pairCount > 0 ? 100 * Double(countAbove) / Double(pairCount) : nil
        let sdnn = AnalyticsMath.sampleStandardDeviation(intervals)
        var sdann: Double?
        var sdnnIndex: Double?
        if let times = beatTimesMilliseconds, times.count == intervals.count {
            let segments = fiveMinuteSegments(intervals, times: times)
            if segments.count >= 2 {
                let means = segments.compactMap(AnalyticsMath.mean)
                sdann = AnalyticsMath.sampleStandardDeviation(means)
                let segmentSDs = segments.compactMap(AnalyticsMath.sampleStandardDeviation)
                sdnnIndex = AnalyticsMath.mean(segmentSDs)
            }
        }
        let confidence = AnalyticsMath.clamp(Double(intervals.count) / 250, 0.3, 0.95)
        return AnalyticsMetric(
            value: HRVTimeValue(rmssdMilliseconds: rmssd, sdnnMilliseconds: sdnn, sdannMilliseconds: sdann, sdnnIndexMilliseconds: sdnnIndex, pNN50Percent: pNN50, beatCount: intervals.count, algorithmVersion: AnalyticsAlgorithmVersion.hrv),
            confidence: confidence,
            tier: .high,
            inputsUsed: inputs,
            note: "PRV not ECG-HRV; RMSSD/pNN50 are quantization-sensitive at 1 Hz — lead with SDNN/SDANN",
            algorithmVersion: AnalyticsAlgorithmVersion.hrv
        )
    }

    public static func nocturnalRMSSD(
        _ intervals: [Double],
        beatTimesMilliseconds times: [Double],
        windowMilliseconds: Double = 300_000,
        minimumBeatsPerWindow: Int = 5,
        stageMaskPerSecond: [Bool]? = nil
    ) -> AnalyticsMetric<Double> {
        let inputs = ["rr_cleaned", "beat_times"]
        guard intervals.count == times.count, intervals.count >= minimumBeatsPerWindow + 1 else {
            return .absent(tier: .high, inputsUsed: inputs, note: "too few NN intervals for windowed nocturnal RMSSD", algorithmVersion: AnalyticsAlgorithmVersion.hrv)
        }
        guard let firstTime = times.first else {
            return .absent(tier: .high, inputsUsed: inputs, note: "too few NN intervals for windowed nocturnal RMSSD", algorithmVersion: AnalyticsAlgorithmVersion.hrv)
        }
        var buckets: [Int: [Double]] = [:]
        for index in intervals.indices {
            let bucket = Int(floor((times[index] - firstTime) / windowMilliseconds))
            buckets[bucket, default: []].append(intervals[index])
        }
        var rmssds: [Double] = []
        for bucket in buckets.keys.sorted() {
            if let mask = stageMaskPerSecond {
                let midpoint = Int(floor((Double(bucket) + 0.5) * windowMilliseconds / 1_000))
                guard midpoint >= 0, midpoint < mask.count, mask[midpoint] else { continue }
            }
            guard let segment = buckets[bucket], segment.count >= minimumBeatsPerWindow + 1 else { continue }
            var sum = 0.0
            for index in 1..<segment.count {
                let difference = segment[index] - segment[index - 1]
                sum += difference * difference
            }
            rmssds.append(sqrt(sum / Double(segment.count - 1)))
        }
        guard let robust = AnalyticsMath.median(rmssds) else {
            return .absent(tier: .high, inputsUsed: inputs, note: "no usable 5-min windows for nocturnal RMSSD", algorithmVersion: AnalyticsAlgorithmVersion.hrv)
        }
        let confidence = AnalyticsMath.clamp(Double(rmssds.count) / 12, 0.3, 0.95)
        return AnalyticsMetric(value: robust, confidence: confidence, tier: .high, inputsUsed: inputs, note: "robust nocturnal RMSSD = MEDIAN of \(rmssds.count) consecutive 5-min-window RMSSDs (REM/arousal-robust). PRV not ECG-HRV; RMSSD is quantization-sensitive at 1 Hz.", algorithmVersion: AnalyticsAlgorithmVersion.hrv)
    }

    public static func sleepSessionWindowedRMSSD(
        rrMilliseconds: [Double],
        rrTimestampsMilliseconds: [Double],
        startSeconds: Int,
        endSeconds: Int,
        windowSeconds: Int = 300
    ) -> AnalyticsMetric<Double> {
        let inputs = ["rr_sleep_window"]
        guard startSeconds > 0, endSeconds > startSeconds, !rrMilliseconds.isEmpty, rrMilliseconds.count == rrTimestampsMilliseconds.count else {
            return .absent(tier: .high, inputsUsed: inputs, note: "invalid or empty RR session window", algorithmVersion: AnalyticsAlgorithmVersion.hrv)
        }
        var buckets: [Int: [Double]] = [:]
        for index in rrMilliseconds.indices {
            let timestamp = Int((rrTimestampsMilliseconds[index] / 1_000).rounded())
            guard timestamp >= startSeconds, timestamp < endSeconds else { continue }
            let bucket = (timestamp - startSeconds) / windowSeconds
            buckets[bucket, default: []].append(rrMilliseconds[index])
        }
        guard !buckets.isEmpty else {
            return .absent(tier: .high, inputsUsed: inputs, note: "no RR beats inside the session window", algorithmVersion: AnalyticsAlgorithmVersion.hrv)
        }
        var rmssds: [Double] = []
        for bucket in buckets.keys.sorted() {
            let cleaned = rejectWindowEctopic(buckets[bucket]!.filter { $0 >= 300 && $0 <= 2_000 })
            guard cleaned.count >= 2 else { continue }
            var sum = 0.0
            for index in 1..<cleaned.count {
                let difference = cleaned[index] - cleaned[index - 1]
                sum += difference * difference
            }
            rmssds.append(sqrt(sum / Double(cleaned.count - 1)))
        }
        guard let average = AnalyticsMath.mean(rmssds) else {
            return .absent(tier: .high, inputsUsed: inputs, note: "no valid 5-min windows for sleep-session RMSSD", algorithmVersion: AnalyticsAlgorithmVersion.hrv)
        }
        let confidence = AnalyticsMath.clamp(Double(rmssds.count) / 12, 0.3, 0.95)
        return AnalyticsMetric(value: average, confidence: confidence, tier: .high, inputsUsed: inputs, note: "sleep-session HRV: mean RMSSD over cleaned 5-min windows.", algorithmVersion: AnalyticsAlgorithmVersion.hrv)
    }

    private static func fiveMinuteSegments(_ intervals: [Double], times: [Double]) -> [[Double]] {
        guard let first = times.first else { return [] }
        var output: [[Double]] = []
        var currentIndex = 0
        var current: [Double] = []
        for index in intervals.indices {
            let segmentIndex = Int(floor((times[index] - first) / 300_000))
            if segmentIndex != currentIndex {
                if current.count >= 2 { output.append(current) }
                current = []
                currentIndex = segmentIndex
            }
            current.append(intervals[index])
        }
        if current.count >= 2 { output.append(current) }
        return output
    }

    private static func rejectWindowEctopic(_ intervals: [Double]) -> [Double] {
        guard intervals.count > 2 else { return intervals }
        let radius = 2
        var kept: [Double] = []
        for index in intervals.indices {
            let lower = max(0, index - radius)
            let upper = min(intervals.count - 1, index + radius)
            let neighbors = intervals.enumerated().compactMap { neighborIndex, value in
                (neighborIndex >= lower && neighborIndex <= upper && neighborIndex != index) ? value : nil
            }
            guard neighbors.count >= 2, let median = AnalyticsMath.median(neighbors), median > 0 else {
                kept.append(intervals[index]); continue
            }
            if abs(intervals[index] - median) / median <= 0.20 { kept.append(intervals[index]) }
        }
        return kept
    }
}

public struct LombScarglePoint: Codable, Sendable, Equatable {
    public let frequencyHz: Double
    public let power: Double
}

public struct LombScargleSpectrum: Codable, Sendable, Equatable {
    public let points: [LombScarglePoint]
    public func bandPower(lower: Double, upper: Double) -> Double {
        guard points.count > 1 else { return 0 }
        var sum = 0.0
        for index in 1..<points.count {
            let frequency = points[index].frequencyHz
            guard frequency >= lower, frequency < upper else { continue }
            sum += points[index].power * (points[index].frequencyHz - points[index - 1].frequencyHz)
        }
        return sum
    }
    public func peakFrequency(lower: Double, upper: Double) -> Double? {
        points.filter { $0.frequencyHz >= lower && $0.frequencyHz <= upper }.max { $0.power < $1.power }?.frequencyHz
    }
}

public enum SpectralAnalysis {
    public static func frequencyGrid(lower: Double, upper: Double, count: Int) -> [Double] {
        guard count > 0 else { return [] }
        guard count > 1 else { return [lower] }
        let step = (upper - lower) / Double(count - 1)
        return (0..<count).map { lower + Double($0) * step }
    }

    /// The periodogram is the single most expensive thing analytics does: the
    /// stager runs one per 30-second epoch and respiration runs three over the
    /// whole series. The two inner loops below are therefore written against
    /// raw buffers, with the same operations in the same order as before, so
    /// the arithmetic is unchanged and only the bounds checks and retain
    /// traffic are gone.
    public static func lombScargle(times: [Double], values: [Double], frequencies: [Double]) -> LombScargleSpectrum? {
        guard times.count >= 4, values.count == times.count, !frequencies.isEmpty, let average = AnalyticsMath.mean(values) else { return nil }
        let centered = values.map { $0 - average }
        let variance = centered.reduce(0) { $0 + $1 * $1 } / Double(times.count - 1)
        guard variance > 0 else { return nil }
        var powers = [Double](repeating: 0, count: frequencies.count)
        // Each frequency reads the whole series and writes one slot, so the
        // frequencies are independent and splitting them across cores cannot
        // change a value. Below the threshold the dispatch costs more than the
        // work it hands out.
        let parallel = frequencies.count > 1 && frequencies.count * times.count >= 20_000
        times.withUnsafeBufferPointer { timeBuffer in
            centered.withUnsafeBufferPointer { weightBuffer in
                frequencies.withUnsafeBufferPointer { frequencyBuffer in
                    powers.withUnsafeMutableBufferPointer { powerBuffer in
                        guard let time = timeBuffer.baseAddress, let weight = weightBuffer.baseAddress,
                              let frequency = frequencyBuffer.baseAddress, let power = powerBuffer.baseAddress else { return }
                        // Every worker reads the same two input buffers and
                        // writes its own slot, so the buffers are safe to share
                        // even though a raw pointer cannot say so for itself.
                        let shared = PeriodogramBuffers(time: time, weight: weight, frequency: frequency, power: power, count: timeBuffer.count)
                        let body: @Sendable (Int) -> Void = { slot in
                            shared.power[slot] = periodogram(shared.frequency[slot], time: shared.time, weight: shared.weight, count: shared.count, variance: variance)
                        }
                        if parallel {
                            DispatchQueue.concurrentPerform(iterations: frequencyBuffer.count, execute: body)
                        } else {
                            for slot in 0..<frequencyBuffer.count { body(slot) }
                        }
                    }
                }
            }
        }
        return LombScargleSpectrum(points: zip(frequencies, powers).map { LombScarglePoint(frequencyHz: $0 == 0 ? 0 : $0, power: $1) })
    }

    /// The input and output buffers one periodogram pass shares between
    /// workers. Disjoint writes, read-only inputs.
    private struct PeriodogramBuffers: @unchecked Sendable {
        let time: UnsafePointer<Double>
        let weight: UnsafePointer<Double>
        let frequency: UnsafePointer<Double>
        let power: UnsafeMutablePointer<Double>
        let count: Int
    }

    /// One frequency of the periodogram. The operations and their order match
    /// the original loop exactly, so the value is bit for bit what it was.
    private static func periodogram(
        _ frequency: Double,
        time: UnsafePointer<Double>,
        weight: UnsafePointer<Double>,
        count: Int,
        variance: Double
    ) -> Double {
        let angular = 2 * Double.pi * frequency
        guard angular != 0 else { return 0 }
        var sineTwice = 0.0
        var cosineTwice = 0.0
        for index in 0..<count {
            sineTwice += sin(2 * angular * time[index])
            cosineTwice += cos(2 * angular * time[index])
        }
        let tau = atan2(sineTwice, cosineTwice) / (2 * angular)
        var cosineNumerator = 0.0
        var cosineDenominator = 0.0
        var sineNumerator = 0.0
        var sineDenominator = 0.0
        for index in 0..<count {
            let argument = angular * (time[index] - tau)
            let cosine = cos(argument)
            let sine = sin(argument)
            cosineNumerator += weight[index] * cosine
            cosineDenominator += cosine * cosine
            sineNumerator += weight[index] * sine
            sineDenominator += sine * sine
        }
        let termOne = cosineDenominator == 0 ? 0 : cosineNumerator * cosineNumerator / cosineDenominator
        let termTwo = sineDenominator == 0 ? 0 : sineNumerator * sineNumerator / sineDenominator
        return 0.5 * (termOne + termTwo) / variance
    }
}

public struct HRVFrequencyValue: Codable, Sendable, Equatable {
    public let ulf: Double?
    public let vlf: Double?
    public let lf: Double?
    public let hf: Double?
    public let total: Double?
    public let lfHF: Double?
    public let normalizedLF: Double?
    public let normalizedHF: Double?
    public let hfGated: Bool
    public let algorithmVersion: String
}

public enum HRVFrequency {
    public static func derive(
        intervals: [Double],
        beatTimesMilliseconds times: [Double],
        artifactFraction: Double,
        hfArtifactGate: Double = 0.15,
        gridPoints: Int = 600
    ) -> AnalyticsMetric<HRVFrequencyValue> {
        let inputs = ["rr_cleaned", "beat_times"]
        guard intervals.count >= 16, intervals.count == times.count else {
            return .absent(tier: .high, inputsUsed: inputs, note: "too few beats for a spectral estimate", algorithmVersion: AnalyticsAlgorithmVersion.hrv)
        }
        let seconds = times.map { $0 / 1_000 }
        guard let first = seconds.first, let last = seconds.last else {
            return .absent(tier: .high, inputsUsed: inputs, note: "degenerate beat times", algorithmVersion: AnalyticsAlgorithmVersion.hrv)
        }
        let span = last - first
        guard span > 0 else {
            return .absent(tier: .high, inputsUsed: inputs, note: "degenerate beat times", algorithmVersion: AnalyticsAlgorithmVersion.hrv)
        }
        let lower = AnalyticsMath.clamp(1 / span, 0.0005, 0.04)
        guard let spectrum = SpectralAnalysis.lombScargle(times: seconds, values: intervals, frequencies: SpectralAnalysis.frequencyGrid(lower: lower, upper: 0.4, count: gridPoints)) else {
            return .absent(tier: .high, inputsUsed: inputs, note: "spectrum undefined", algorithmVersion: AnalyticsAlgorithmVersion.hrv)
        }
        let ulf = span >= 1 / 0.003 ? spectrum.bandPower(lower: 0, upper: 0.003) : nil
        let vlf = span >= 1 / 0.04 ? spectrum.bandPower(lower: 0.003, upper: 0.04) : nil
        let lf = spectrum.bandPower(lower: 0.04, upper: 0.15)
        let hfRaw = spectrum.bandPower(lower: 0.15, upper: 0.4)
        let gated = artifactFraction > hfArtifactGate
        let hf = gated ? nil : hfRaw
        var lfHF: Double?
        var normalizedLF: Double?
        var normalizedHF: Double?
        if let hf, lf + hf > 0 {
            lfHF = hf == 0 ? nil : lf / hf
            normalizedLF = 100 * lf / (lf + hf)
            normalizedHF = 100 * hf / (lf + hf)
        }
        let total = gated ? nil : (ulf ?? 0) + (vlf ?? 0) + lf + hfRaw
        let confidence = AnalyticsMath.clamp((1 - artifactFraction) * (gated ? 0.6 : 0.9), 0.2, 0.9)
        let value = HRVFrequencyValue(ulf: ulf, vlf: vlf, lf: lf, hf: hf, total: total, lfHF: lfHF, normalizedLF: normalizedLF, normalizedHF: normalizedHF, hfGated: gated, algorithmVersion: AnalyticsAlgorithmVersion.hrv)
        let note = gated ? "HF suppressed: artifact fraction \(AnalyticsMath.round6(artifactFraction)) > gate — LF/VLF reported, HF/LF-HF/nu/total withheld" : "PRV spectrum; HF band quantization-limited at 1 Hz"
        return AnalyticsMetric(value: value, confidence: confidence, tier: .high, inputsUsed: inputs, note: note, algorithmVersion: AnalyticsAlgorithmVersion.hrv)
    }
}
