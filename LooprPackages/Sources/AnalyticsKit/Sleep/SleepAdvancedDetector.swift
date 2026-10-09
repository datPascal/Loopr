import Foundation
import DomainKit

/// Stage-0 session detection ported from the pinned AdvancedSleepStager.
/// Cardiorespiratory staging remains in `SleepCardioStager`; this type owns
/// only the gravity/HR window and its guards.  Keeping detection separate
/// makes a forced window explicit instead of silently weakening auto gates.
public enum SleepAdvancedWindowDetector {
    private static let gravityStillThresholdG = 0.01
    private static let stillWindowSeconds: TimeInterval = 15 * 60
    private static let stillFraction = 0.70
    private static let maxGapSeconds: TimeInterval = 20 * 60
    private static let mergeSeconds: TimeInterval = 15 * 60
    /// Floor for a single qualifying session, including a daytime nap.
    private static let minSleepSeconds: TimeInterval = 60 * 60
    /// Floor for the night the app calls your main sleep on the automatic
    /// path. The pinned segmenter uses three hours; a shorter window is still
    /// returned, but only as a nap. A window the user asserts keeps the
    /// one-hour session floor instead.
    public static let mainSleepMinimumSeconds: TimeInterval = 3 * 60 * 60
    /// Minimum daytime samples before a daytime heart-rate baseline is
    /// trusted over the median of the whole record.
    public static let daytimeBaselineMinimumSamples = 60
    private static let maxMainSleepSeconds: TimeInterval = 16 * 60 * 60
    private static let maxOffWristSleepFraction = 0.5
    private static let offWristGapSeconds: TimeInterval = 20 * 60
    private static let sparseGravitySpanFraction = 0.5
    private static let sparseBridgeGapSeconds: TimeInterval = 90 * 60
    private static let hrSleepBaselineMultiplier = 1.05
    private static let daytimeRestingMultiplier = 0.95
    private static let daytimeMinimumSeconds: TimeInterval = 90 * 60

    private struct Period {
        let asleep: Bool
        let start: TimeInterval
        let end: TimeInterval
    }

    /// Detect qualifying sessions from gravity and HR streams.  The returned
    /// windows are ordered by onset and retain their local immobility mask.
    public static func detect(
        acceleration: [SleepAccelerationSample],
        heartRate: [SleepHeartRateSample],
        timeZoneIdentifier: String? = nil,
        daytimeHeartRate: [Double] = []
    ) -> AnalyticsMetric<[SleepWindow]> {
        let inputs = daytimeHeartRate.isEmpty
            ? ["accel_1hz", "hr_1hz", "local_time"]
            : ["accel_1hz", "hr_1hz", "local_time", "daytime_hr"]
        let gravity = acceleration.filter {
            $0.valid && $0.timestamp.isFinite && [$0.x, $0.y, $0.z].allSatisfy(\.isFinite)
        }.sorted { $0.timestamp < $1.timestamp }
        let hr = heartRate.filter {
            $0.valid && $0.timestamp.isFinite && $0.bpm.isFinite && $0.bpm > 0
        }.sorted { $0.timestamp < $1.timestamp }
        guard gravity.count >= 2 else {
            return .absent(tier: .estimate, inputs: inputs, note: "need at least two valid gravity samples", algorithmVersion: SleepAlgorithm.version)
        }

        let times = gravity.map(\.timestamp)
        let cadence = medianInterval(times)
        let deltas = gravityDeltas(gravity)
        let still = stillFlags(deltas: deltas, times: times, cadence: cadence)
        let sparse = isSparse(gravity: gravity, heartRate: hr)
        // The median of the whole record already contains the night it is
        // meant to judge, so a long night drags the baseline down towards
        // sleeping heart rate and the confirmation gate stops discriminating.
        // Prefer the waking hours before the window, as the pinned pipeline
        // does, and fall back only when there are too few of them.
        let daytime = daytimeHeartRate.filter { $0.isFinite && $0 > 0 }
        let baseline = daytime.count >= daytimeBaselineMinimumSamples
            ? AnalyticsMath.median(daytime)
            : AnalyticsMath.median(hr.map(\.bpm))
        var periods = buildPeriods(
            gravity: gravity,
            still: still,
            sparse: sparse,
            heartRate: hr,
            baseline: baseline,
            cadence: cadence
        )
        periods = mergeShortPeriods(periods)
        periods = bridgeSparseSleep(periods, sparse: sparse, heartRate: hr, baseline: baseline)

        var windows: [SleepWindow] = []
        for period in periods where period.asleep {
            let duration = period.end - period.start
            guard duration > minSleepSeconds, duration <= maxMainSleepSeconds else { continue }
            guard confirmsSleep(period, heartRate: hr, baseline: baseline) else { continue }
            guard offWristFraction(period, heartRate: hr) < maxOffWristSleepFraction else { continue }
            if isDaytimeCenter(period, timeZoneIdentifier: timeZoneIdentifier) {
                guard duration >= daytimeMinimumSeconds,
                      let baseline,
                      let resting = restingHeartRate(period, heartRate: hr),
                      resting <= baseline * daytimeRestingMultiplier else { continue }
            }

            let first = nearestIndex(times, to: period.start)
            let last = nearestIndex(times, to: max(period.start, period.end - cadence))
            guard first <= last else { continue }
            let mask = Array(still[first...last])
            let angles = Array(gravity[first...last]).map { SleepAnalytics.zAngle(x: $0.x, y: $0.y, z: $0.z) }
            windows.append(SleepWindow(
                onsetIndex: first,
                offsetIndex: last + 1,
                onset: period.start,
                offset: period.end,
                immobile: mask,
                zAngleDegrees: angles,
                sptSeconds: max(0, Int((period.end - period.start).rounded()))
            ))
        }
        guard !windows.isEmpty else {
            return .absent(tier: .estimate, inputs: inputs, note: "no qualifying advanced sleep session", algorithmVersion: SleepAlgorithm.version)
        }
        let confidence = AnalyticsMath.clamp(0.45 + 0.1 * Double(min(windows.count, 4)), 0.45, 0.8)
        return AnalyticsMetric(value: windows, confidence: confidence, tier: .estimate, inputs: inputs, note: "AdvancedSleepStager gravity stillness with HR/day/off-wrist guards", algorithmVersion: SleepAlgorithm.version)
    }

    private static func medianInterval(_ times: [TimeInterval]) -> TimeInterval {
        let gaps = zip(times.dropFirst(), times).map { $0.0 - $0.1 }.filter { $0 > 0 && $0 < 300 }
        return max(1, AnalyticsMath.median(gaps) ?? 60)
    }

    private static func gravityDeltas(_ samples: [SleepAccelerationSample]) -> [Double] {
        guard samples.count > 1 else { return [0] }
        var result = [Double](repeating: 0, count: samples.count)
        for index in 1..<samples.count {
            let dx = samples[index].x - samples[index - 1].x
            let dy = samples[index].y - samples[index - 1].y
            let dz = samples[index].z - samples[index - 1].z
            result[index] = sqrt(dx * dx + dy * dy + dz * dz)
        }
        return result
    }

    private static func stillFlags(deltas: [Double], times: [TimeInterval], cadence: TimeInterval) -> [Bool] {
        let half = max(1, Int((stillWindowSeconds / cadence / 2).rounded()))
        var prefix = [Int](repeating: 0, count: deltas.count + 1)
        for index in deltas.indices {
            prefix[index + 1] = prefix[index] + (deltas[index] < gravityStillThresholdG ? 1 : 0)
        }
        return deltas.indices.map { index in
            let lower = max(0, index - half)
            let upper = min(deltas.count, index + half + 1)
            return Double(prefix[upper] - prefix[lower]) / Double(max(1, upper - lower)) >= stillFraction
        }
    }

    /// True when the gravity stream is too thin to carry the night on its own,
    /// which is the condition the heart-rate-led fallback exists for.
    public static func gravityIsSparse(acceleration: [SleepAccelerationSample], heartRate: [SleepHeartRateSample]) -> Bool {
        let gravity = acceleration.filter {
            $0.valid && $0.timestamp.isFinite && [$0.x, $0.y, $0.z].allSatisfy(\.isFinite)
        }.sorted { $0.timestamp < $1.timestamp }
        let hr = heartRate.filter {
            $0.valid && $0.timestamp.isFinite && $0.bpm.isFinite && $0.bpm > 0
        }.sorted { $0.timestamp < $1.timestamp }
        guard gravity.count >= 2 else { return true }
        return isSparse(gravity: gravity, heartRate: hr)
    }

    private static func isSparse(gravity: [SleepAccelerationSample], heartRate: [SleepHeartRateSample]) -> Bool {
        guard gravity.count >= 2, heartRate.count >= 2 else { return false }
        let hrSpan = (heartRate.last?.timestamp ?? 0) - (heartRate.first?.timestamp ?? 0)
        guard hrSpan > 0 else { return false }
        let gravitySpan = (gravity.last?.timestamp ?? 0) - (gravity.first?.timestamp ?? 0)
        if gravitySpan < sparseGravitySpanFraction * hrSpan { return true }
        return zip(gravity.dropFirst(), gravity).contains { $0.0.timestamp - $0.1.timestamp > maxGapSeconds }
    }

    private static func hrSleepBand(_ start: TimeInterval, _ end: TimeInterval, heartRate: [SleepHeartRateSample], baseline: Double?) -> Bool {
        guard let baseline else { return false }
        let values = heartRate.filter { $0.timestamp > start && $0.timestamp <= end }.map(\.bpm)
        guard !values.isEmpty else { return false }
        return (AnalyticsMath.mean(values) ?? .infinity) <= baseline * hrSleepBaselineMultiplier
    }

    private static func buildPeriods(
        gravity: [SleepAccelerationSample],
        still: [Bool],
        sparse: Bool,
        heartRate: [SleepHeartRateSample],
        baseline: Double?,
        cadence: TimeInterval
    ) -> [Period] {
        guard !gravity.isEmpty else { return [] }
        let times = gravity.map(\.timestamp)
        var result: [Period] = []
        var start = 0
        for index in 1...gravity.count {
            let endOfStream = index == gravity.count
            var close = endOfStream
            if !endOfStream {
                let changed = still[index] != still[start]
                var gapExceeded = times[index] - times[index - 1] > maxGapSeconds
                if sparse && gapExceeded && !changed && still[start] && hrSleepBand(times[index - 1], times[index], heartRate: heartRate, baseline: baseline) {
                    gapExceeded = false
                }
                close = changed || gapExceeded
            }
            if close {
                let last = index - 1
                result.append(Period(asleep: still[start], start: times[start], end: times[last] + cadence))
                start = index
            }
        }
        return result
    }

    private static func mergeShortPeriods(_ periods: [Period]) -> [Period] {
        guard !periods.isEmpty else { return [] }
        var pending = periods
        var merged: [Period] = []
        var index = 0
        while index < pending.count {
            let current = pending[index]
            guard current.end - current.start < mergeSeconds else {
                merged.append(current)
                index += 1
                continue
            }
            let hasPrevious = !merged.isEmpty
            let hasNext = index + 1 < pending.count
            let bridges = hasPrevious && hasNext && merged[merged.count - 1].asleep == pending[index + 1].asleep
            if bridges {
                let previous = merged.removeLast()
                merged.append(Period(asleep: previous.asleep, start: previous.start, end: pending[index + 1].end))
                index += 2
            } else if hasNext {
                pending[index + 1] = Period(asleep: pending[index + 1].asleep, start: current.start, end: pending[index + 1].end)
                index += 1
            } else if hasPrevious {
                let previous = merged.removeLast()
                merged.append(Period(asleep: previous.asleep, start: previous.start, end: current.end))
                index += 1
            } else {
                index += 1
            }
        }
        return merged
    }

    private static func bridgeSparseSleep(_ periods: [Period], sparse: Bool, heartRate: [SleepHeartRateSample], baseline: Double?) -> [Period] {
        guard sparse, !periods.isEmpty else { return periods }
        var result: [Period] = []
        for period in periods {
            if let previous = result.last, previous.asleep, period.asleep,
               period.start >= previous.end,
               period.start - previous.end <= sparseBridgeGapSeconds,
               hrSleepBand(previous.end, period.start, heartRate: heartRate, baseline: baseline) {
                result[result.count - 1] = Period(asleep: true, start: previous.start, end: period.end)
            } else {
                result.append(period)
            }
        }
        return result
    }

    private static func confirmsSleep(_ period: Period, heartRate: [SleepHeartRateSample], baseline: Double?) -> Bool {
        guard let baseline else { return true }
        let values = heartRate.filter { $0.timestamp >= period.start && $0.timestamp <= period.end }.map(\.bpm)
        guard values.count >= 30 else { return true }
        return (AnalyticsMath.mean(values) ?? .infinity) <= baseline * hrSleepBaselineMultiplier
    }

    private static func restingHeartRate(_ period: Period, heartRate: [SleepHeartRateSample]) -> Double? {
        let values = heartRate.filter { $0.timestamp >= period.start && $0.timestamp <= period.end }
        guard !values.isEmpty else { return nil }
        var means: [Double] = []
        var start = period.start
        while start < period.end {
            let window = values.filter { $0.timestamp >= start && $0.timestamp < start + 300 }.map(\.bpm)
            if let mean = AnalyticsMath.mean(window) { means.append(mean) }
            start += 300
        }
        return means.min() ?? AnalyticsMath.mean(values.map(\.bpm))
    }

    private static func offWristFraction(_ period: Period, heartRate: [SleepHeartRateSample]) -> Double {
        let duration = period.end - period.start
        guard duration > 0 else { return 1 }
        let samples = heartRate.filter { $0.timestamp >= period.start && $0.timestamp <= period.end }
        // A globally sparse HR stream is not evidence of off-wrist time; the
        // pinned detector only applies the 20-minute gap guard to a dense
        // stream.  Otherwise a low-rate but intentional sensor feed would be
        // rejected as if the band had been removed.
        if let first = heartRate.first, let last = heartRate.last {
            let streamSpan = last.timestamp - first.timestamp
            if streamSpan >= 600, Double(heartRate.count) < streamSpan / 600 { return 0 }
        }
        guard !samples.isEmpty else { return duration >= offWristGapSeconds ? 1 : 0 }
        var missing: [(TimeInterval, TimeInterval)] = []
        if samples[0].timestamp - period.start >= offWristGapSeconds { missing.append((period.start, samples[0].timestamp)) }
        for pair in zip(samples.dropFirst(), samples) {
            if pair.0.timestamp - pair.1.timestamp >= offWristGapSeconds { missing.append((pair.1.timestamp, pair.0.timestamp)) }
        }
        if period.end - (samples.last?.timestamp ?? period.end) >= offWristGapSeconds {
            missing.append((samples.last?.timestamp ?? period.end, period.end))
        }
        guard !missing.isEmpty else { return 0 }
        let sorted = missing.sorted { $0.0 < $1.0 }
        var covered = 0.0
        var start = sorted[0].0
        var end = sorted[0].1
        for span in sorted.dropFirst() {
            if span.0 <= end { end = max(end, span.1) }
            else { covered += end - start; start = span.0; end = span.1 }
        }
        covered += end - start
        return AnalyticsMath.clamp(covered / duration, 0, 1)
    }

    private static func isDaytimeCenter(_ period: Period, timeZoneIdentifier: String?) -> Bool {
        let timeZone = timeZoneIdentifier.flatMap(TimeZone.init(identifier:)) ?? .current
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let date = Date(timeIntervalSince1970: period.start + (period.end - period.start) / 2)
        let hour = calendar.component(.hour, from: date)
        return hour >= 11 && hour < 20
    }

    private static func nearestIndex(_ values: [TimeInterval], to target: TimeInterval) -> Int {
        values.enumerated().min { lhs, rhs in
            abs(lhs.element - target) < abs(rhs.element - target)
        }?.offset ?? 0
    }
}

public func detectAdvancedSleepWindows(
    acceleration: [SleepAccelerationSample],
    heartRate: [SleepHeartRateSample],
    timeZoneIdentifier: String? = nil,
    daytimeHeartRate: [Double] = []
) -> AnalyticsMetric<[SleepWindow]> {
    SleepAdvancedWindowDetector.detect(acceleration: acceleration, heartRate: heartRate, timeZoneIdentifier: timeZoneIdentifier, daytimeHeartRate: daytimeHeartRate)
}
