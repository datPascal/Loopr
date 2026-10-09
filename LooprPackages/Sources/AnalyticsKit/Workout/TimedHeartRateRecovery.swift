import Foundation

public struct TimedHeartRateRecovery: Codable, Equatable, Sendable {
    public static let algorithmVersion = "loopr.workout-hrr.1"
    public let firstMinute: HRRecovery?
    public let secondMinute: HRRecovery?
    public let reason: String?
    public let maximumHR: Double?
    public init(firstMinute: HRRecovery?, secondMinute: HRRecovery?, reason: String?, maximumHR: Double? = nil) {
        self.firstMinute = firstMinute; self.secondMinute = secondMinute; self.reason = reason
        self.maximumHR = maximumHR
    }
}

extension WorkoutAnalytics {
    /// Clean-room timestamp implementation. Clock windows and gap risk are
    /// documented in OpenStrap analytics workout/hr_recovery.dart, MIT.
    /// Intensity eligibility is documented in NOOP pull request #565.
    /// No positional interpolation or clinical categories.
    public static func timedHeartRateRecovery(samples: [WorkoutHRPoint], start: TimeInterval,
                                               end: TimeInterval, maximumHR: Double?) -> TimedHeartRateRecovery {
        func absent(_ reason: String) -> TimedHeartRateRecovery {
            TimedHeartRateRecovery(firstMinute: nil, secondMinute: nil, reason: reason)
        }
        guard start.isFinite, end.isFinite, end > start else { return absent("A recorded workout end is needed.") }
        guard let maximumHR, maximumHR.isFinite, (100...240).contains(maximumHR) else {
            return absent("Set your age or maximum heart rate to check workout intensity.")
        }
        let tail = samples.filter { $0.timestamp.isFinite && $0.timestamp >= max(start, end - 300) && $0.timestamp <= end + 123 }
            .sorted { $0.timestamp < $1.timestamp }
        guard !tail.isEmpty else { return absent("No heart-rate history for this workout. New workouts need the band on after finishing.") }
        func usable(_ point: WorkoutHRPoint) -> Bool { point.valid && point.bpm.isFinite && (30...240).contains(point.bpm) }
        // Sustained intensity is elapsed time, never a count of samples.
        var highStart: TimeInterval?, previous: TimeInterval?, longest: TimeInterval = 0
        for point in tail where point.timestamp <= end {
            if !usable(point) || point.bpm < maximumHR * 0.70 {
                highStart = nil; previous = nil; continue
            }
            if let previous, point.timestamp - previous > 30 { highStart = nil }
            highStart = highStart ?? point.timestamp
            longest = max(longest, point.timestamp - (highStart ?? point.timestamp))
            previous = point.timestamp
        }
        guard longest >= 120 else { return absent("Needs two steady minutes of higher effort near the workout's end.") }
        let peakWindow = tail.filter { $0.timestamp >= end - 30 && $0.timestamp <= end }
        guard peakWindow.allSatisfy(usable), let peak = peakWindow.map(\.bpm).max(),
              let peakFirst = peakWindow.first, peakFirst.timestamp <= end - 27,
              let last = peakWindow.last, end - last.timestamp <= 3 else {
            return absent("Keep your band on through the workout's end to measure the drop.")
        }
        func measure(_ seconds: Double) -> HRRecovery? {
            let windowEnd = end + seconds + 3
            let path = tail.filter { $0.timestamp >= end - 30 && $0.timestamp <= windowEnd }
            guard path.allSatisfy(usable), let last = path.last, last.timestamp >= end + seconds - 3 else { return nil }
            for pair in zip(path, path.dropFirst()) where pair.1.timestamp - pair.0.timestamp > 30 { return nil }
            let values = path.filter { abs($0.timestamp - (end + seconds)) <= 3 }.map(\.bpm)
            guard let recovery = AnalyticsMath.median(values) else { return nil }
            let drop = peak - recovery
            return HRRecovery(peakBPM: peak, heartRateAtRecovery: recovery, dropBPM: drop,
                              dropPercent: 100 * drop / peak, algorithmVersion: TimedHeartRateRecovery.algorithmVersion)
        }
        let first = measure(60), second = measure(120)
        return TimedHeartRateRecovery(firstMinute: first, secondMinute: second,
            reason: first == nil ? "No continuous heart rate through the first minute. Keep your band on after finishing and sync again." : nil, maximumHR: maximumHR)
    }
}
