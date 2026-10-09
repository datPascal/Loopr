import Foundation

/// Candidate window proposed by the HR-led fallback.  It is a candidate only:
/// callers must surface it as low-confidence or ask for confirmation before
/// treating it as a user-authored sleep window.
public struct SleepHRFallbackWindow: Codable, Sendable, Equatable {
    public let onset: TimeInterval
    public let offset: TimeInterval
    public let thresholdBPM: Double

    public init(onset: TimeInterval, offset: TimeInterval, thresholdBPM: Double) {
        self.onset = onset; self.offset = offset; self.thresholdBPM = thresholdBPM
    }

    public var durationSeconds: Int { max(0, Int((offset - onset).rounded())) }
}

public enum SleepHRFallback {
    public static func window(
        _ heartRate: [SleepHeartRateSample],
        daytimeBaseline: [Double] = [],
        minDurationSeconds: Int = 2 * 3_600,
        bridgeGapSeconds: Int = 30 * 60,
        smoothingSeconds: Int = 300
    ) -> AnalyticsMetric<SleepHRFallbackWindow> {
        let sorted = heartRate.filter { $0.valid && $0.bpm > 0 && $0.bpm.isFinite && $0.timestamp.isFinite }.sorted { $0.timestamp < $1.timestamp }
        guard sorted.count >= max(2, minDurationSeconds / 2) else {
            return .absent(tier: .estimate, inputs: ["hr_1hz"], note: "too few HR samples for HR-led sleep fallback", algorithmVersion: SleepAlgorithm.version)
        }
        let values = sorted.map(\.bpm)
        let baseline = daytimeBaseline.filter { $0.isFinite && $0 > 0 }
        let threshold = daytimeBaseline.isEmpty
            ? (AnalyticsMath.percentile(values, 30) ?? 0)
            : (AnalyticsMath.median(baseline).map { $0 * 0.90 } ?? 0)
        guard threshold > 0 else {
            return .absent(tier: .estimate, inputs: ["hr_1hz", "daytime_hr"], note: "no valid HR baseline for HR-led sleep fallback", algorithmVersion: SleepAlgorithm.version)
        }
        let window = min(max(1, smoothingSeconds), sorted.count)
        let half = window / 2
        // A five-minute median at every one of a day's seconds is 24,000 sorts
        // of 300 samples. Carry the window sorted instead; the multiset behind
        // each median is the same, so the smoothed series is the same.
        var smooth = [Double](repeating: 0, count: sorted.count)
        withSlidingWindow(count: sorted.count, half: half, value: { values[$0] }) { index, window in
            smooth[index] = window.median() ?? 0
        }
        func isLow(_ index: Int) -> Bool { smooth[index] > 0 && smooth[index] < threshold }
        var bestStart: Int?
        var bestEnd: Int?
        var bestDuration = 0.0
        var index = 0
        while index < sorted.count {
            guard isLow(index) else { index += 1; continue }
            let start = index
            var end = index
            while end < sorted.count {
                if isLow(end) { end += 1; continue }
                var cursor = end
                while cursor < sorted.count && !isLow(cursor) && sorted[cursor].timestamp - sorted[end].timestamp < Double(bridgeGapSeconds) { cursor += 1 }
                if cursor < sorted.count && isLow(cursor) && sorted[cursor].timestamp - sorted[end].timestamp < Double(bridgeGapSeconds) {
                    end = cursor
                } else {
                    break
                }
            }
            let duration = sorted[max(start, end - 1)].timestamp - sorted[start].timestamp
            if duration > bestDuration { bestDuration = duration; bestStart = start; bestEnd = end }
            index = end + 1
        }
        guard let bestStart, let bestEnd, bestDuration >= Double(minDurationSeconds) else {
            return .absent(tier: .estimate, inputs: ["hr_1hz", "daytime_hr"], note: "no sustained nocturnal HR dip found", algorithmVersion: SleepAlgorithm.version)
        }
        let onset = sorted[bestStart].timestamp
        let offset = sorted[max(bestStart, bestEnd - 1)].timestamp + 1
        guard offset > onset else {
            return .absent(tier: .estimate, inputs: ["hr_1hz", "daytime_hr"], note: "degenerate HR-led candidate window", algorithmVersion: SleepAlgorithm.version)
        }
        let value = SleepHRFallbackWindow(onset: onset, offset: offset, thresholdBPM: threshold)
        return AnalyticsMetric(value: value, confidence: 0.3, tier: .estimate, inputs: ["hr_1hz", "daytime_hr"], note: "HR-led candidate only; user confirmation required before staging", algorithmVersion: SleepAlgorithm.version)
    }
}

public func hrLedSleepWindow(_ heartRate: [SleepHeartRateSample], daytimeBaseline: [Double] = [], minDurationSeconds: Int = 2 * 3_600, bridgeGapSeconds: Int = 30 * 60, smoothingSeconds: Int = 300) -> AnalyticsMetric<SleepHRFallbackWindow> {
    SleepHRFallback.window(heartRate, daytimeBaseline: daytimeBaseline, minDurationSeconds: minDurationSeconds, bridgeGapSeconds: bridgeGapSeconds, smoothingSeconds: smoothingSeconds)
}
