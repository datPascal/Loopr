import Foundation

/// Async, cancellation-aware entry points for long-running derivations.  The
/// calculators remain pure synchronous functions; these wrappers provide the
/// scheduler boundary with a single cancellation check before and after the
/// calculation, and never persist partial output.
public enum CancellableAnalytics {
    public static func rrQuality(_ intervals: [Double]) async throws -> RRCorrectionResult {
        try Task.checkCancellation()
        await Task.yield()
        try Task.checkCancellation()
        let result = RRQuality.correct(intervals)
        try Task.checkCancellation()
        return result
    }

    public static func rrQualityGate(_ intervals: [Double], minimumCleanFraction: Double = RRQuality.minimumMetricCleanFraction, minimumIntervals: Int = RRQuality.minimumMetricIntervals) async throws -> AnalyticsMetric<RRQualityGateValue> {
        try Task.checkCancellation()
        await Task.yield()
        try Task.checkCancellation()
        let result = RRQuality.gated(intervals, minimumCleanFraction: minimumCleanFraction, minimumIntervals: minimumIntervals)
        try Task.checkCancellation()
        return result
    }

    public static func hrvTime(_ intervals: [Double], beatTimesMilliseconds: [Double]? = nil) async throws -> AnalyticsMetric<HRVTimeValue> {
        try Task.checkCancellation()
        await Task.yield()
        try Task.checkCancellation()
        let result = HRVTime.derive(intervals, beatTimesMilliseconds: beatTimesMilliseconds)
        try Task.checkCancellation()
        return result
    }

    public static func hrvFrequency(intervals: [Double], beatTimesMilliseconds: [Double], artifactFraction: Double) async throws -> AnalyticsMetric<HRVFrequencyValue> {
        try Task.checkCancellation()
        await Task.yield()
        try Task.checkCancellation()
        let result = HRVFrequency.derive(intervals: intervals, beatTimesMilliseconds: beatTimesMilliseconds, artifactFraction: artifactFraction)
        try Task.checkCancellation()
        return result
    }

    public static func nocturnalRMSSD(
        _ intervals: [Double],
        beatTimesMilliseconds: [Double],
        windowMilliseconds: Double = 300_000,
        minimumBeatsPerWindow: Int = 5,
        stageMaskPerSecond: [Bool]? = nil
    ) async throws -> AnalyticsMetric<Double> {
        try Task.checkCancellation()
        await Task.yield()
        try Task.checkCancellation()
        let result = HRVTime.nocturnalRMSSD(
            intervals,
            beatTimesMilliseconds: beatTimesMilliseconds,
            windowMilliseconds: windowMilliseconds,
            minimumBeatsPerWindow: minimumBeatsPerWindow,
            stageMaskPerSecond: stageMaskPerSecond
        )
        try Task.checkCancellation()
        return result
    }

    public static func sleepSessionWindowedRMSSD(
        rrMilliseconds: [Double],
        rrTimestampsMilliseconds: [Double],
        startSeconds: Int,
        endSeconds: Int,
        windowSeconds: Int = 300
    ) async throws -> AnalyticsMetric<Double> {
        try Task.checkCancellation()
        await Task.yield()
        try Task.checkCancellation()
        let result = HRVTime.sleepSessionWindowedRMSSD(
            rrMilliseconds: rrMilliseconds,
            rrTimestampsMilliseconds: rrTimestampsMilliseconds,
            startSeconds: startSeconds,
            endSeconds: endSeconds,
            windowSeconds: windowSeconds
        )
        try Task.checkCancellation()
        return result
    }

    public static func nocturnalRestingHeartRate(_ samples: [Double], windowSamples: Int = 1_800, minimumCoverage: Double = 0.9) async throws -> AnalyticsMetric<NocturnalRHRValue> {
        try Task.checkCancellation()
        await Task.yield()
        try Task.checkCancellation()
        let result = NocturnalMetrics.restingHeartRate(samples, windowSamples: windowSamples, minimumCoverage: minimumCoverage)
        try Task.checkCancellation()
        return result
    }

    public static func dailyNocturnalRestingHeartRate(samples: [HRSample], localDay: String, timeZoneID: String, windowSamples: Int = 1_800, minimumCoverage: Double = 0.9) async throws -> AnalyticsMetric<DailyNocturnalRHRValue> {
        try Task.checkCancellation()
        await Task.yield()
        try Task.checkCancellation()
        let result = NocturnalMetrics.dailyRestingHeartRate(samples: samples, localDay: localDay, timeZoneID: timeZoneID, windowSamples: windowSamples, minimumCoverage: minimumCoverage)
        try Task.checkCancellation()
        return result
    }

    public static func heartRateDip(daySamples: [Double], nightSamples: [Double], minimumSamples: Int = NocturnalMetrics.minimumDipSamples) async throws -> AnalyticsMetric<HRDipValue> {
        try Task.checkCancellation()
        await Task.yield()
        try Task.checkCancellation()
        let result = NocturnalMetrics.heartRateDip(daySamples: daySamples, nightSamples: nightSamples, minimumSamples: minimumSamples)
        try Task.checkCancellation()
        return result
    }

    public static func rsaRespiration(
        intervals: [Double],
        beatTimesMilliseconds: [Double],
        artifactFraction: Double,
        agreementBPM: Double = 3,
        maximumArtifactFraction: Double = 0.3
    ) async throws -> AnalyticsMetric<RespiratoryEstimate> {
        try Task.checkCancellation()
        await Task.yield()
        try Task.checkCancellation()
        let result = Respiration.rsaRate(
            intervals: intervals,
            beatTimesMilliseconds: beatTimesMilliseconds,
            artifactFraction: artifactFraction,
            agreementBPM: agreementBPM,
            maximumArtifactFraction: maximumArtifactFraction
        )
        try Task.checkCancellation()
        return result
    }

    public static func riivRespiration(adc: [Double], timestampsSeconds: [Double], validFraction: Double = 1) async throws -> AnalyticsMetric<RespiratoryEstimate> {
        try Task.checkCancellation()
        await Task.yield()
        try Task.checkCancellation()
        let result = Respiration.riivRate(adc: adc, timestampsSeconds: timestampsSeconds, validFraction: validFraction)
        try Task.checkCancellation()
        return result
    }

    public static func respiration(_ rates: [Double]) async throws -> AnalyticsMetric<BreathingRateVariability> {
        try Task.checkCancellation()
        await Task.yield()
        try Task.checkCancellation()
        let result = Respiration.variability(rates)
        try Task.checkCancellation()
        return result
    }

    public static func breathingRateVariability(_ rates: [Double]) async throws -> AnalyticsMetric<BreathingRateVariability> {
        try await respiration(rates)
    }
}
