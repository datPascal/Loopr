import Foundation
import DomainKit

/// Per-epoch features used by the pinned transparent cardiorespiratory
/// stager.  NaN means that a feature could not be measured for that epoch; it
/// is never converted into a favourable sleep vote.
public struct SleepCardioEpochFeatures: Codable, Sendable, Equatable {
    public let motion: [Double]
    public let heartRate: [Double]
    public let heartRateSD: [Double]
    public let rmssd: [Double]
    public let lfHF: [Double]
    public let rk: [Double]
    public let sdnn: [Double]
    /// Epochs the accelerometer never covered. A recording gap is not
    /// stillness, so these epochs are reported as wake and are kept out of
    /// every night baseline. An empty array means "no gap information".
    public let unstaged: [Bool]

    public init(motion: [Double], heartRate: [Double], heartRateSD: [Double], rmssd: [Double], lfHF: [Double], rk: [Double], sdnn: [Double], unstaged: [Bool] = []) {
        self.motion = motion; self.heartRate = heartRate; self.heartRateSD = heartRateSD
        self.rmssd = rmssd; self.lfHF = lfHF; self.rk = rk; self.sdnn = sdnn
        self.unstaged = unstaged
    }

    private enum CodingKeys: String, CodingKey {
        case motion, heartRate, heartRateSD, rmssd, lfHF, rk, sdnn, unstaged
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        motion = try container.decode([Double].self, forKey: .motion)
        heartRate = try container.decode([Double].self, forKey: .heartRate)
        heartRateSD = try container.decode([Double].self, forKey: .heartRateSD)
        rmssd = try container.decode([Double].self, forKey: .rmssd)
        lfHF = try container.decode([Double].self, forKey: .lfHF)
        rk = try container.decode([Double].self, forKey: .rk)
        sdnn = try container.decode([Double].self, forKey: .sdnn)
        unstaged = try container.decodeIfPresent([Bool].self, forKey: .unstaged) ?? []
    }

    /// `unstaged` is deliberately excluded: it is a diagnostic mask, not a
    /// feature axis, and an older caller that omits it must not shorten the
    /// classified night to zero epochs.
    public var count: Int {
        [motion.count, heartRate.count, heartRateSD.count, rmssd.count, lfHF.count, rk.count, sdnn.count].min() ?? 0
    }
}

public struct SleepCardioStagingResult: Codable, Sendable, Equatable {
    /// Three-class labels (wake/NREM/REM); deep is carried in `stages4`.
    public let stages: [SleepStage]
    /// Four-class labels (wake/light/deep/rem), aligned one-for-one with stages.
    public let stages4: [SleepStage]
    public let epochSeconds: Int
    public let confidence: Double
    public let algorithmVersion: String

    public init(stages: [SleepStage], stages4: [SleepStage], epochSeconds: Int, confidence: Double, algorithmVersion: String = SleepAlgorithm.version) {
        self.stages = stages; self.stages4 = stages4; self.epochSeconds = epochSeconds
        self.confidence = confidence; self.algorithmVersion = algorithmVersion
    }
}

public enum SleepCardioStager {
    public static let epochSeconds = 30
    private static let remCut = 0.5
    private static let deepCut = 0.3

    struct TimedRR {
        let timestamp: TimeInterval
        let milliseconds: Double
    }

    public static func stage(
        acceleration: [SleepAccelerationSample],
        heartRate: [SleepHeartRateSample],
        rr: [SleepRRInterval],
        onset: TimeInterval,
        offset: TimeInterval,
        epochSeconds: Int = SleepCardioStager.epochSeconds
    ) -> AnalyticsMetric<SleepCardioStagingResult> {
        guard offset > onset, epochSeconds > 0 else {
            return .absent(tier: .estimate, inputs: ["accel_1hz", "hr_1hz"], note: "invalid sleep staging window", algorithmVersion: SleepAlgorithm.version)
        }
        let epochCount = Int((offset - onset) / Double(epochSeconds))
        guard epochCount >= 3 else {
            return .absent(tier: .estimate, inputs: ["accel_1hz", "hr_1hz"], note: "too few epochs for cardiorespiratory staging", algorithmVersion: SleepAlgorithm.version)
        }
        // Clip every stream to the staged night before doing any per-epoch
        // work. A 36-hour history scanned once per 30-second epoch is the
        // difference between milliseconds and minutes on a real night, and no
        // sample outside [onset - context, offset + context) can reach any
        // epoch window, so the result is unchanged.
        let context = Double(broadHalfWindow)
        let accel = clipped(acceleration.filter { $0.valid && $0.timestamp.isFinite }.sorted { $0.timestamp < $1.timestamp },
                            times: { $0.timestamp }, from: onset - context, to: offset + context)
        let hr = clipped(heartRate.filter { $0.valid && $0.bpm > 0 && $0.bpm.isFinite && $0.timestamp.isFinite }.sorted { $0.timestamp < $1.timestamp },
                         times: { $0.timestamp }, from: onset - context, to: offset + context)
        let rrSorted = clipped(rr.filter { $0.timestamp.isFinite && $0.milliseconds.isFinite }.sorted { $0.timestamp < $1.timestamp },
                               times: { $0.timestamp }, from: onset - context, to: offset + context)
        let accelTimes = accel.map(\.timestamp)
        let hrTimes = hr.map(\.timestamp)
        let rrTimes = rrSorted.map(\.timestamp)
        let magnitudes = accel.map { magnitude($0) }
        var motion = [Double](repeating: 0, count: epochCount)
        var heart = [Double](repeating: .nan, count: epochCount)
        var heartSD = [Double](repeating: 0, count: epochCount)
        var rmssd = [Double](repeating: .nan, count: epochCount)
        var lfHF = [Double](repeating: .nan, count: epochCount)
        var rk = [Double](repeating: .nan, count: epochCount)
        var sdnn = [Double](repeating: .nan, count: epochCount)
        var unstaged = [Bool](repeating: false, count: epochCount)

        // The gravity reference is the median of a five-minute window that
        // slides one epoch at a time. Re-sorting those three hundred samples
        // once per epoch was the second biggest cost in staging, so the window
        // is carried sorted. Its contents, and therefore the median, are the
        // same.
        var gravityWindow = SortedWindow(capacity: 2 * broadHalfWindow + 2 * epochSeconds + 2)
        var gravityLower = 0
        var gravityUpper = 0

        for epoch in 0..<epochCount {
            let start = onset + Double(epoch * epochSeconds)
            let end = min(offset, start + Double(epochSeconds))
            let localRange = indexRange(accelTimes, from: start - context, to: end + context)
            while gravityUpper < localRange.upperBound { gravityWindow.insert(magnitudes[gravityUpper]); gravityUpper += 1 }
            while gravityLower < localRange.lowerBound { gravityWindow.remove(magnitudes[gravityLower]); gravityLower += 1 }
            let gRef = gravityWindow.median() ?? 1
            let epochRange = indexRange(accelTimes, from: start, to: end)
            if !epochRange.isEmpty {
                motion[epoch] = AnalyticsMath.mean(magnitudes[epochRange].map { max(0, $0 - gRef) }) ?? 0
            } else if accelTimes.isEmpty {
                // No accelerometer at all. There is nothing to carry forward
                // and nothing to contradict, so motion stays unknown and the
                // cardiac axes decide the night on their own.
                motion[epoch] = .nan
            } else if epochRange.lowerBound == 0 || start - accelTimes[epochRange.lowerBound - 1] > maxAccelCarryForwardSeconds {
                // The pinned stager carries the last known gravity vector for
                // at most one minute. Past that there is no accelerometer, and
                // "no accelerometer" is not "perfectly still": report wake and
                // keep the epoch out of every night baseline.
                unstaged[epoch] = true
                motion[epoch] = .nan
            }
            let hrRange = indexRange(hrTimes, from: start, to: end)
            let epochHR = hr[hrRange].map(\.bpm)
            if let mean = AnalyticsMath.mean(epochHR) { heart[epoch] = mean }
            if let deviation = AnalyticsMath.standardDeviation(epochHR), deviation.isFinite { heartSD[epoch] = deviation }
            let center = (start + end) / 2
            let broad = cleanRR(rrSorted, times: rrTimes, center: center, halfWindow: context)
            if broad.count >= 5 {
                let values = broad.map(\.milliseconds)
                rmssd[epoch] = rootMeanSquareSuccessiveDifference(values)
                sdnn[epoch] = AnalyticsMath.sampleStandardDeviation(values) ?? .nan
            }
            let remWindow = cleanRR(rrSorted, times: rrTimes, center: center, halfWindow: Double(remHalfWindow))
            if remWindow.count >= 16 {
                rk[epoch] = meanInstantaneousHRDifference(remWindow.map(\.milliseconds))
                lfHF[epoch] = lfHFRatio(remWindow)
            }
        }
        let features = SleepCardioEpochFeatures(motion: motion, heartRate: heart, heartRateSD: heartSD, rmssd: rmssd, lfHF: lfHF, rk: rk, sdnn: sdnn, unstaged: unstaged)
        return classify(features, epochSeconds: epochSeconds, algorithmVersion: SleepAlgorithm.version)
    }

    /// Half-window of the broad RR/gravity context, in seconds.
    private static let broadHalfWindow = 150
    /// Half-window of the REM-sensitive RR context, in seconds.
    private static let remHalfWindow = 90
    /// Longest accelerometer dropout carried across as "unchanged posture".
    private static let maxAccelCarryForwardSeconds: TimeInterval = 60

    private static func clipped<T>(_ values: [T], times: (T) -> TimeInterval, from lower: TimeInterval, to upper: TimeInterval) -> [T] {
        let sortedTimes = values.map(times)
        return Array(values[indexRange(sortedTimes, from: lower, to: upper)])
    }

    /// Half-open index range of a sorted timestamp array covering `[from, to)`.
    private static func indexRange(_ times: [Double], from lower: Double, to upper: Double) -> Range<Int> {
        let start = lowerBound(times, lower)
        let end = lowerBound(times, upper)
        return start..<max(start, end)
    }

    private static func lowerBound(_ times: [Double], _ value: Double) -> Int {
        var low = 0, high = times.count
        while low < high {
            let mid = (low + high) / 2
            if times[mid] < value { low = mid + 1 } else { high = mid }
        }
        return low
    }

    public static func classify(_ features: SleepCardioEpochFeatures, epochSeconds: Int = 30, algorithmVersion: String = SleepAlgorithm.version) -> AnalyticsMetric<SleepCardioStagingResult> {
        let n = features.count
        guard n >= 3 else {
            return .absent(tier: .estimate, inputs: ["cardio_epoch_features"], note: "too few epochs for cardiorespiratory staging", algorithmVersion: algorithmVersion)
        }
        let motion = Array(features.motion.prefix(n))
        let heart = Array(features.heartRate.prefix(n))
        let heartSD = Array(features.heartRateSD.prefix(n))
        let rmssd = Array(features.rmssd.prefix(n))
        let lfHF = Array(features.lfHF.prefix(n))
        let rk = Array(features.rk.prefix(n))
        let sdnn = Array(features.sdnn.prefix(n))
        let unstaged = features.unstaged.count >= n ? Array(features.unstaged.prefix(n)) : [Bool](repeating: false, count: n)
        let heartAll = heart.filter { $0.isFinite && $0 > 0 }
        guard !heartAll.isEmpty else {
            return .absent(tier: .estimate, inputs: ["cardio_epoch_features", "hr_1hz"], note: "no valid HR anywhere; sleep stages withheld", algorithmVersion: algorithmVersion)
        }
        let measuredMotion = motion.filter(\.isFinite)
        let motionMedian = AnalyticsMath.median(measuredMotion) ?? 0
        let motionMAD = max(1e-9, AnalyticsMath.mad(measuredMotion) ?? 0)
        let stillCut = motionMedian + 1.5 * motionMAD
        let moveCut = motionMedian + 5 * motionMAD
        // A missing motion value never votes for stillness.
        let still = (0..<n).map { motion[$0].isFinite && motion[$0] <= stillCut && !unstaged[$0] }
        let sleepingHR = (0..<n).compactMap { still[$0] && heart[$0].isFinite && heart[$0] > 0 ? heart[$0] : nil }
        let globalMedian = AnalyticsMath.median(sleepingHR.isEmpty ? heartAll : sleepingHR) ?? (AnalyticsMath.mean(heartAll) ?? 60)
        var localMedian = [Double](repeating: globalMedian, count: n)
        var localP25 = localMedian
        var localArousal = localMedian.map { $0 + 6 }
        let halfLocal = 180
        for i in 0..<n {
            let lo = max(0, i - halfLocal), hi = min(n, i + halfLocal + 1)
            let local = (lo..<hi).compactMap { still[$0] && heart[$0].isFinite && heart[$0] > 0 ? heart[$0] : nil }
            if let med = AnalyticsMath.median(local) {
                localMedian[i] = med
                localP25[i] = AnalyticsMath.percentile(local, 25) ?? med
                localArousal[i] = med + max(6, AnalyticsMath.standardDeviation(local) ?? 6)
            }
        }
        let lfHFScale = RobustScale(values: (0..<n).compactMap { still[$0] && lfHF[$0].isFinite ? lfHF[$0] : nil })
        let rkScale = RobustScale(values: (0..<n).compactMap { still[$0] && rk[$0].isFinite ? rk[$0] : nil })
        let sdnnScale = RobustScale(values: (0..<n).compactMap { still[$0] && sdnn[$0].isFinite ? sdnn[$0] : nil })
        let heartSDScale = RobustScale(values: (0..<n).compactMap { still[$0] && heartSD[$0] > 0 ? heartSD[$0] : nil })
        var stages = [SleepStage](repeating: .wake, count: n)
        var deep = [Bool](repeating: false, count: n)
        for i in 0..<n {
            if unstaged[i] { stages[i] = .wake; continue }
            let hrUp = heart[i].isFinite && heart[i] >= localArousal[i]
            let bigPrev = i > 0 && motion[i - 1] > moveCut
            let bigMoveWake = motion[i] > moveCut && ((heart[i].isFinite && heart[i] >= localMedian[i]) || bigPrev)
            if hrUp || bigMoveWake {
                stages[i] = .wake
                continue
            }
            func score(_ terms: [(Double?, Double)]) -> Double? {
                var numerator = 0.0, denominator = 0.0
                for (z, weight) in terms where z?.isFinite == true {
                    numerator += z! * weight
                    denominator += abs(weight)
                }
                return denominator > 0 ? numerator / denominator : nil
            }
            // heartSD is 0 when the epoch had fewer than two HR samples. That
            // is "not measured", not "perfectly steady", and must not score
            // as the quietest epoch of the night (a strong deep vote). The
            // baseline above already excludes it; the pinned stager also
            // drops it here.
            let heartSDZ = heartSD[i] > 0 ? heartSDScale?.z(heartSD[i]) : nil
            let remScore = score([
                (rkScale?.z(rk[i]), 0.43),
                (sdnnScale?.z(sdnn[i]), 0.32),
                (heartSDZ, 0.27),
                (lfHFScale?.z(lfHF[i]), 0.12)
            ])
            let deepScore = score([
                (rkScale?.z(rk[i]).map { -$0 }, 0.53),
                (heartSDZ.map { -$0 }, 0.43),
                (sdnnScale?.z(sdnn[i]).map { -$0 }, 0.41),
                (lfHFScale?.z(lfHF[i]).map { -$0 }, 0.33)
            ])
            let atonia = motion[i] <= moveCut
            let hrTowardWake = heart[i].isFinite && heart[i] >= localP25[i]
            if let remScore, remScore > remCut, atonia, hrTowardWake {
                stages[i] = .rem
            } else {
                stages[i] = .nrem
                deep[i] = deepScore.map { $0 > deepCut } ?? false
            }
        }
        modeFilter(&stages)
        websterRescore(&stages, epochSeconds: epochSeconds)
        consolidate(&stages, epochSeconds: epochSeconds)
        // The continuity passes may bridge across a gap. They must not turn
        // an epoch with no accelerometer into sleep.
        for index in 0..<n where unstaged[index] { stages[index] = .wake }
        for index in deep.indices where deep[index] && stages[index] != .nrem {
            deep[index] = false
        }
        mergeShortDeep(&deep, stages: stages, epochSeconds: epochSeconds)
        let stages4 = stages.enumerated().map { index, stage in
            stage == .nrem && deep[index] ? SleepStage.deep : stage == .nrem ? SleepStage.light : stage
        }
        let rrCoverage = Double((0..<n).filter { still[$0] && rmssd[$0].isFinite }.count) / Double(max(1, n))
        let confidence = AnalyticsMath.clamp(0.35 + 0.25 * rrCoverage, 0.3, 0.6)
        let result = SleepCardioStagingResult(stages: stages, stages4: stages4, epochSeconds: epochSeconds, confidence: confidence, algorithmVersion: algorithmVersion)
        return AnalyticsMetric(value: result, confidence: confidence, tier: .estimate, inputs: ["accel_1hz", "hr_1hz", "rr_cleaned"], note: "transparent cardio stager: motion + HR + robust RR axes; wrist estimate, not PSG", algorithmVersion: algorithmVersion)
    }

    private struct RobustScale {
        let median: Double
        let scale: Double
        init?(values: [Double]) {
            guard values.count >= 4, let median = AnalyticsMath.median(values), let scale = AnalyticsMath.mad(values), scale > 0 else { return nil }
            self.median = median; self.scale = scale
        }
        func z(_ value: Double) -> Double? { value.isFinite ? (value - median) / scale : nil }
    }

    private static func magnitude(_ sample: SleepAccelerationSample) -> Double { sqrt(sample.x * sample.x + sample.y * sample.y + sample.z * sample.z) }

    /// `samples` is already sorted by timestamp and `times` mirrors it, so the
    /// window is an index range rather than a scan of the whole night.
    static func cleanRR(_ samples: [SleepRRInterval], times: [Double], center: TimeInterval, halfWindow: TimeInterval) -> [TimedRR] {
        let start = lowerBound(times, center - halfWindow)
        let end = lowerBound(times, (center + halfWindow).nextUp)
        guard start < end else { return [] }
        var result: [TimedRR] = []
        result.reserveCapacity(end - start)
        // The pinned gate compares each beat with the beat just before it,
        // accepted or not, and an out-of-range beat breaks the chain. The
        // earlier port compared with the last accepted beat instead, so a
        // single outlier early in a window, or a real step in heart rate,
        // rejected every later beat of the window. On two real nights that
        // starved the REM axes and moved about a third of REM to light. Epoch
        // agreement with the pinned stager on those nights went from 88% and
        // 86% to 98% and 95%; the rest is the deliberate LF/HF beat clock in
        // `lfHFRatio`. The stage cutoffs were calibrated on this exact gate,
        // so it has to match.
        var previous: Double?
        for index in start..<end {
            let sample = samples[index]
            guard sample.milliseconds >= 300, sample.milliseconds <= 2_000 else { previous = nil; continue }
            if let last = previous, abs(sample.milliseconds - last) > 200 { previous = sample.milliseconds; continue }
            result.append(TimedRR(timestamp: sample.timestamp, milliseconds: sample.milliseconds)); previous = sample.milliseconds
        }
        return result
    }

    private static func rootMeanSquareSuccessiveDifference(_ values: [Double]) -> Double {
        guard values.count > 1 else { return .nan }
        return sqrt(values.dropFirst().enumerated().reduce(0) { partial, pair in
            let difference = pair.element - values[pair.offset]
            return partial + difference * difference
        } / Double(values.count - 1))
    }

    private static func meanInstantaneousHRDifference(_ values: [Double]) -> Double {
        guard values.count > 1 else { return .nan }
        let ihr = values.map { 60_000 / $0 }
        return AnalyticsMath.mean(zip(ihr.dropFirst(), ihr).map { abs($0.0 - $0.1) }) ?? .nan
    }

    private static func lfHFRatio(_ samples: [TimedRR]) -> Double {
        let values = samples.map(\.milliseconds)
        // Packet timestamps are whole seconds, so several beats share one
        // value. Lomb-Scargle reads those duplicates as simultaneous beats and
        // the LF/HF split stops meaning anything. Use the shared monotonic
        // beat clock instead.
        let times = RRQuality.monotonicBeatTimesMilliseconds(
            values,
            timestampsMilliseconds: samples.map { $0.timestamp * 1_000 }
        ).map { $0 / 1_000 }
        guard let spectrum = SpectralAnalysis.lombScargle(times: times, values: values, frequencies: SpectralAnalysis.frequencyGrid(lower: 0.04, upper: 0.4, count: 120)) else { return .nan }
        let hf = spectrum.bandPower(lower: 0.15, upper: 0.4)
        return hf > 0 ? spectrum.bandPower(lower: 0.04, upper: 0.15) / hf : .nan
    }

    private static func modeFilter(_ stages: inout [SleepStage]) {
        guard stages.count >= 3 else { return }
        let original = stages
        for index in 1..<(stages.count - 1) where original[index - 1] == original[index + 1] && original[index] != original[index - 1] {
            stages[index] = original[index - 1]
        }
    }

    private static func websterRescore(_ stages: inout [SleepStage], epochSeconds: Int) {
        guard epochSeconds > 0, !stages.isEmpty else { return }
        let original = stages
        guard let onset = original.firstIndex(where: { $0 != .wake }), let last = original.lastIndex(where: { $0 != .wake }) else { return }
        func runBefore(_ index: Int) -> Int {
            var count = 0, cursor = index - 1
            while cursor >= onset, original[cursor] != .wake { count += 1; cursor -= 1 }
            return count
        }
        func runAfter(_ index: Int) -> Int {
            var count = 0, cursor = index + 1
            while cursor <= last, original[cursor] != .wake { count += 1; cursor += 1 }
            return count
        }
        var index = onset
        while index <= last {
            guard original[index] == .wake else { index += 1; continue }
            var end = index
            while end <= last, original[end] == .wake { end += 1 }
            let context = max(runBefore(index), runAfter(end - 1))
            let wakeCount = end - index
            let rules = [(15 * 60 / epochSeconds, 10 * 60 / epochSeconds), (10 * 60 / epochSeconds, 5 * 60 / epochSeconds), (4 * 60 / epochSeconds, 2 * 60 / epochSeconds)]
            if rules.contains(where: { context >= $0.0 && wakeCount <= $0.1 }) {
                for cursor in index..<end { stages[cursor] = .nrem }
            }
            index = end
        }
    }

    /// Pinned Dart architecture consolidation: bridge short NREM gaps inside
    /// REM, then merge sub-five-minute asleep bouts into the longer adjacent
    /// asleep bout. Wake is never rewritten by this pass.
    private static func consolidate(_ stages: inout [SleepStage], epochSeconds: Int) {
        guard !stages.isEmpty, epochSeconds > 0 else { return }
        let remGap = Int((5 * 60 / Double(epochSeconds)).rounded())
        let minBout = Int((5 * 60 / Double(epochSeconds)).rounded())
        guard remGap > 1 || minBout > 1 else { return }

        func runs(_ values: [SleepStage]) -> [(start: Int, end: Int)] {
            var result: [(Int, Int)] = []
            var start = 0
            while start < values.count {
                var end = start + 1
                while end < values.count, values[end] == values[start] { end += 1 }
                result.append((start, end))
                start = end
            }
            return result
        }

        let initialRuns = runs(stages)
        for index in initialRuns.indices {
            let run = initialRuns[index]
            guard stages[run.start] == .nrem, run.end - run.start < remGap else { continue }
            let left = index > 0 && stages[initialRuns[index - 1].start] == .rem
                ? initialRuns[index - 1].end - initialRuns[index - 1].start : 0
            let right = index + 1 < initialRuns.count && stages[initialRuns[index + 1].start] == .rem
                ? initialRuns[index + 1].end - initialRuns[index + 1].start : 0
            if left > 0, right > 0, left + right + run.end - run.start >= remGap {
                for cursor in run.start..<run.end { stages[cursor] = .rem }
            }
        }

        var changed = true
        while changed {
            changed = false
            let currentRuns = runs(stages)
            for index in currentRuns.indices {
                let run = currentRuns[index]
                let stage = stages[run.start]
                guard stage != .wake, run.end - run.start < minBout else { continue }
                let leftRun = index > 0 && stages[currentRuns[index - 1].start] != .wake ? currentRuns[index - 1] : nil
                let rightRun = index + 1 < currentRuns.count && stages[currentRuns[index + 1].start] != .wake ? currentRuns[index + 1] : nil
                let target: SleepStage?
                if let leftRun, let rightRun {
                    target = leftRun.end - leftRun.start >= rightRun.end - rightRun.start
                        ? stages[leftRun.start] : stages[rightRun.start]
                } else if let leftRun {
                    target = stages[leftRun.start]
                } else if let rightRun {
                    target = stages[rightRun.start]
                } else {
                    target = nil
                }
                guard let target, target != stage else { continue }
                for cursor in run.start..<run.end { stages[cursor] = target }
                changed = true
                break
            }
        }
    }

    private static func mergeShortDeep(_ deep: inout [Bool], stages: [SleepStage], epochSeconds: Int) {
        guard epochSeconds > 0 else { return }
        let minimum = Int((3 * 60 / Double(epochSeconds)).rounded())
        guard minimum > 1 else { return }
        var start = 0
        while start < deep.count {
            guard deep[start], stages[start] == .nrem else { start += 1; continue }
            var end = start
            while end < deep.count, deep[end], stages[end] == .nrem { end += 1 }
            if end - start < minimum {
                for index in start..<end { deep[index] = false }
            }
            start = end
        }
    }
}
