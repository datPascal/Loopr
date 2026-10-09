import Foundation

public struct NocturnalRHRValue: Codable, Sendable, Equatable {
    public let lowestThirtyMinuteMeanBPM: Double
    public let firstPercentileBPM: Double
    public let validSampleCount: Int
    public let algorithmVersion: String
}

public struct HRDipValue: Codable, Sendable, Equatable {
    public let dipPercent: Double
    public let daytimeMeanBPM: Double
    public let nighttimeMeanBPM: Double
    public let band: String
    public let algorithmVersion: String
}

/// The resolved civil-day interval used by nightly metrics.  `end` is the
/// next local midnight, so DST transition days are intentionally 23 or 25
/// hours rather than being forced into a 24-hour UTC bucket.
public struct AnalyticsLocalDayWindow: Codable, Sendable, Equatable {
    public let localDay: String
    public let timeZoneID: String
    public let startMilliseconds: Int64
    public let endMilliseconds: Int64
    public let durationSeconds: Int

    public init(localDay: String, timeZoneID: String, startMilliseconds: Int64, endMilliseconds: Int64) {
        self.localDay = localDay
        self.timeZoneID = timeZoneID
        self.startMilliseconds = startMilliseconds
        self.endMilliseconds = endMilliseconds
        self.durationSeconds = Int((endMilliseconds - startMilliseconds) / 1_000)
    }

    public static func resolve(localDay: String, timeZoneID: String) -> AnalyticsLocalDayWindow? {
        let parts = localDay.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, parts[0] > 0, (1...12).contains(parts[1]), (1...31).contains(parts[2]),
              let timeZone = TimeZone(identifier: timeZoneID) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = Locale(identifier: "en_US_POSIX")
        let components = DateComponents(year: parts[0], month: parts[1], day: parts[2])
        guard let start = calendar.date(from: components), let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
        let startMilliseconds = Int64((start.timeIntervalSince1970 * 1_000).rounded())
        let endMilliseconds = Int64((end.timeIntervalSince1970 * 1_000).rounded())
        guard endMilliseconds > startMilliseconds else { return nil }
        return AnalyticsLocalDayWindow(localDay: localDay, timeZoneID: timeZoneID, startMilliseconds: startMilliseconds, endMilliseconds: endMilliseconds)
    }
}

public struct DailyNocturnalRHRValue: Codable, Sendable, Equatable {
    public let lowestThirtyMinuteMeanBPM: Double
    public let firstPercentileBPM: Double
    public let validSampleCount: Int
    public let localDay: String
    public let timeZoneID: String
    public let dayStartMilliseconds: Int64
    public let dayEndMilliseconds: Int64
    public let dayDurationSeconds: Int
    public let algorithmVersion: String

    public init(base: NocturnalRHRValue, window: AnalyticsLocalDayWindow, algorithmVersion: String = AnalyticsAlgorithmVersion.nocturnal) {
        self.lowestThirtyMinuteMeanBPM = base.lowestThirtyMinuteMeanBPM
        self.firstPercentileBPM = base.firstPercentileBPM
        self.validSampleCount = base.validSampleCount
        self.localDay = window.localDay
        self.timeZoneID = window.timeZoneID
        self.dayStartMilliseconds = window.startMilliseconds
        self.dayEndMilliseconds = window.endMilliseconds
        self.dayDurationSeconds = window.durationSeconds
        self.algorithmVersion = algorithmVersion
    }
}

public enum NocturnalMetrics {
    public static let minimumDipSamples = 300

    public static func restingHeartRate(_ samples: [Double], windowSamples: Int = 1_800, minimumCoverage: Double = 0.9) -> AnalyticsMetric<NocturnalRHRValue> {
        let inputs = ["hr_1hz"]
        let valid = samples.filter { $0 > 0 }
        guard windowSamples >= 1, samples.count >= windowSamples else {
            return .absent(tier: .high, inputsUsed: inputs, note: "insufficient valid (on-skin) HR for nocturnal RHR", algorithmVersion: AnalyticsAlgorithmVersion.nocturnal)
        }
        let required = Int(ceil(minimumCoverage * Double(windowSamples)))
        var sum = 0.0
        var count = 0
        for index in 0..<windowSamples where samples[index] > 0 { sum += samples[index]; count += 1 }
        var best: Double? = count >= required ? sum / Double(count) : nil
        if samples.count > windowSamples {
            for index in windowSamples..<samples.count {
                if samples[index] > 0 { sum += samples[index]; count += 1 }
                let outgoing = samples[index - windowSamples]
                if outgoing > 0 { sum -= outgoing; count -= 1 }
                if count >= required {
                    let average = sum / Double(count)
                    if best == nil || average < best! { best = average }
                }
            }
        }
        guard let lowest = best, let p1 = AnalyticsMath.percentile(valid, 1) else {
            return .absent(tier: .high, inputsUsed: inputs, note: "no contiguous on-skin window long enough for a nocturnal RHR trough (off-skin gaps are never compacted away)", algorithmVersion: AnalyticsAlgorithmVersion.nocturnal)
        }
        let confidence = AnalyticsMath.clamp(Double(valid.count) / 7_200, 0.4, 0.95)
        let value = NocturnalRHRValue(lowestThirtyMinuteMeanBPM: lowest, firstPercentileBPM: p1, validSampleCount: valid.count, algorithmVersion: AnalyticsAlgorithmVersion.nocturnal)
        return AnalyticsMetric(value: value, confidence: confidence, tier: .high, inputsUsed: inputs, note: "lowest-30-min mean + 1st-percentile; HR=0 excluded as off-skin", algorithmVersion: AnalyticsAlgorithmVersion.nocturnal)
    }

    public static func heartRateDip(daySamples: [Double], nightSamples: [Double], minimumSamples: Int = minimumDipSamples) -> AnalyticsMetric<HRDipValue> {
        let inputs = ["hr_1hz_day", "hr_1hz_night"]
        let day = daySamples.filter { $0 > 0 }
        let night = nightSamples.filter { $0 > 0 }
        guard day.count >= minimumSamples, night.count >= minimumSamples else {
            return .absent(tier: .high, inputsUsed: inputs, note: "HR dip needs ≥\(minimumSamples) valid samples on each of day and night (have day=\(day.count), night=\(night.count))", algorithmVersion: AnalyticsAlgorithmVersion.nocturnal)
        }
        guard let dayMean = AnalyticsMath.mean(day), let nightMean = AnalyticsMath.mean(night), dayMean > 0 else {
            return .absent(tier: .high, inputsUsed: inputs, note: "need both day and night valid HR", algorithmVersion: AnalyticsAlgorithmVersion.nocturnal)
        }
        let dip = (dayMean - nightMean) / dayMean * 100
        let band = dip >= 10 ? "dipper" : (dip >= 0 ? "non_dipper" : "riser")
        let confidence = AnalyticsMath.clamp(Double(day.count + night.count) / 14_400, 0.4, 0.9)
        let value = HRDipValue(dipPercent: dip, daytimeMeanBPM: dayMean, nighttimeMeanBPM: nightMean, band: band, algorithmVersion: AnalyticsAlgorithmVersion.nocturnal)
        return AnalyticsMetric(value: value, confidence: confidence, tier: .high, inputsUsed: inputs, note: "night-day HR ratio; CV-risk + acute-strain signal", algorithmVersion: AnalyticsAlgorithmVersion.nocturnal)
    }

    /// Resolve one local civil day, retain wall-clock gaps as off-skin zeros,
    /// then run the same contiguous-window RHR primitive.  This wrapper is
    /// deliberately separate from `restingHeartRate`, whose array contract is
    /// unchanged and remains the pinned 1 Hz primitive.
    public static func dailyRestingHeartRate(
        samples: [HRSample],
        localDay: String,
        timeZoneID: String,
        windowSamples: Int = 1_800,
        minimumCoverage: Double = 0.9
    ) -> AnalyticsMetric<DailyNocturnalRHRValue> {
        // Match the pinned Dart wrapper: civil-day metadata is carried in the
        // value, while `inputs_used` remains the underlying HR primitive.
        let inputs = ["hr_1hz"]
        guard let window = AnalyticsLocalDayWindow.resolve(localDay: localDay, timeZoneID: timeZoneID) else {
            return .absent(tier: .high, inputsUsed: inputs, note: "invalid local day or time zone", algorithmVersion: AnalyticsAlgorithmVersion.nocturnal)
        }
        guard window.durationSeconds > 0 else {
            return .absent(tier: .high, inputsUsed: inputs, note: "empty local day window", algorithmVersion: AnalyticsAlgorithmVersion.nocturnal)
        }
        var values = Array(repeating: 0.0, count: window.durationSeconds)
        for sample in samples {
            guard sample.timestampMilliseconds.isFinite, sample.bpm.isFinite else { continue }
            let offset = Int(((sample.timestampMilliseconds - Double(window.startMilliseconds)) / 1_000).rounded())
            guard values.indices.contains(offset) else { continue }
            values[offset] = sample.bpm
        }
        let result = restingHeartRate(values, windowSamples: windowSamples, minimumCoverage: minimumCoverage)
        guard let base = result.value else {
            return .absent(tier: result.tier, inputsUsed: inputs, note: result.note, algorithmVersion: AnalyticsAlgorithmVersion.nocturnal)
        }
        let value = DailyNocturnalRHRValue(base: base, window: window)
        return AnalyticsMetric(value: value, confidence: result.confidence, tier: result.tier, inputsUsed: inputs, note: result.note, algorithmVersion: AnalyticsAlgorithmVersion.nocturnal)
    }
}
