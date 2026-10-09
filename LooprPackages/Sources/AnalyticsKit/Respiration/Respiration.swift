import Foundation

public struct RespiratoryEstimate: Codable, Sendable, Equatable {
    public let breathsPerMinute: Double?
    public let peakHz: Double?
    public let power: Double?
    public let source: String
    public let algorithmVersion: String
}
public struct FusedRespiration: Codable, Sendable, Equatable {
    public let breathsPerMinute: Double?
    public let rsaBreathsPerMinute: Double?
    public let riivBreathsPerMinute: Double?
    public let agreed: Bool
    public let decision: String
    public let algorithmVersion: String
}

public struct BreathingRateVariability: Codable, Sendable, Equatable {
    public let meanBreathsPerMinute: Double
    public let standardDeviationBreathsPerMinute: Double
    public let coefficientOfVariation: Double
    public let trendSlope: Double?
    public let windowCount: Int
    public let algorithmVersion: String
}

public enum Respiration {
    public static let lowerHz = 0.1
    public static let upperHz = 0.5
    public static let rsaLowerHz = 0.15
    public static let rsaUpperHz = 0.4

    public static func rsaRate(intervals: [Double], beatTimesMilliseconds times: [Double], artifactFraction: Double, agreementBPM: Double = 3, maximumArtifactFraction: Double = 0.3) -> AnalyticsMetric<RespiratoryEstimate> {
        let inputs = ["rr_cleaned", "beat_times"]
        guard intervals.count >= 20, intervals.count == times.count else {
            return .absent(tier: .high, inputsUsed: inputs, note: "too few beats for an RSA spectral estimate (need ≥20)", algorithmVersion: AnalyticsAlgorithmVersion.respiration)
        }
        guard artifactFraction <= maximumArtifactFraction else {
            return .absent(tier: .high, inputsUsed: inputs, note: "artifact fraction \(AnalyticsMath.round6(artifactFraction)) > gate — RSA peak unreliable", algorithmVersion: AnalyticsAlgorithmVersion.respiration)
        }
        let seconds = times.map { $0 / 1_000 }
        guard let first = seconds.first, let last = seconds.last, last - first > 0 else {
            return .absent(tier: .high, inputsUsed: inputs, note: "degenerate beat times", algorithmVersion: AnalyticsAlgorithmVersion.respiration)
        }
        var peaks: [Double] = []
        var peakFrequencies: [Double] = []
        var peakPowers: [Double] = []
        for grid in [300, 450, 700] {
            guard let spectrum = SpectralAnalysis.lombScargle(times: seconds, values: intervals, frequencies: SpectralAnalysis.frequencyGrid(lower: rsaLowerHz, upper: rsaUpperHz, count: grid)),
                  let peak = spectrum.peakFrequency(lower: rsaLowerHz, upper: rsaUpperHz), peak < upperHz else { continue }
            peaks.append(peak * 60)
            peakFrequencies.append(peak)
            peakPowers.append(power(at: peak, in: spectrum))
        }
        guard peaks.count >= 2 else {
            return .absent(tier: .high, inputsUsed: inputs, note: "no stable HF respiratory peak resolved", algorithmVersion: AnalyticsAlgorithmVersion.respiration)
        }
        let spread = (peaks.max()! - peaks.min()!)
        guard spread <= agreementBPM else {
            return .absent(tier: .high, inputsUsed: inputs, note: "HF peak unstable across spectral resolutions (spread \(AnalyticsMath.round6(spread)) br/min) — withheld", algorithmVersion: AnalyticsAlgorithmVersion.respiration)
        }
        let median = AnalyticsMath.median(peaks)!
        var best = 0
        for index in 1..<peaks.count where abs(peaks[index] - median) < abs(peaks[best] - median) { best = index }
        let rate = peaks[best]
        let estimate = RespiratoryEstimate(breathsPerMinute: rate, peakHz: peakFrequencies[best], power: peakPowers[best], source: "rsa", algorithmVersion: AnalyticsAlgorithmVersion.respiration)
        let confidence = AnalyticsMath.clamp((1 - artifactFraction) * (1 - spread / (agreementBPM * 2)), 0.2, 0.9)
        return AnalyticsMetric(value: estimate, confidence: confidence, tier: .high, inputsUsed: inputs, note: "RSA HF-peak respiratory rate (Lomb-Scargle on native beat times, medoid of \(peaks.count) spectral resolutions — brpm, peak_hz and power all come from that one grid); PRV-derived; 1 Hz Nyquist caps rate at 30 br/min", algorithmVersion: AnalyticsAlgorithmVersion.respiration)
    }

    public static func riivRate(adc: [Double], timestampsSeconds times: [Double], validFraction: Double = 1) -> AnalyticsMetric<RespiratoryEstimate> {
        let inputs = ["ppg_green", "ts"]
        guard adc.count >= 30, adc.count == times.count else {
            return .absent(tier: .relative, inputsUsed: inputs, note: "too few green-ADC samples for RIIV (need ≥30 s)", algorithmVersion: AnalyticsAlgorithmVersion.respiration)
        }
        guard let first = times.first, let last = times.last, last - first > 0 else {
            return .absent(tier: .relative, inputsUsed: inputs, note: "degenerate timestamps", algorithmVersion: AnalyticsAlgorithmVersion.respiration)
        }
        let fit = linearFit(values: adc, times: times)
        let detrended = adc.indices.map { index in adc[index] - ((fit?.slope ?? 0) * times[index] + (fit?.intercept ?? 0)) }
        guard let spectrum = SpectralAnalysis.lombScargle(times: times, values: detrended, frequencies: SpectralAnalysis.frequencyGrid(lower: lowerHz, upper: upperHz, count: 500)), let peak = spectrum.peakFrequency(lower: lowerHz, upper: upperHz), peak < upperHz else {
            return .absent(tier: .relative, inputsUsed: inputs, note: "no respiratory-band peak (or aliased at Nyquist)", algorithmVersion: AnalyticsAlgorithmVersion.respiration)
        }
        let estimate = RespiratoryEstimate(breathsPerMinute: peak * 60, peakHz: peak, power: power(at: peak, in: spectrum), source: "riiv", algorithmVersion: AnalyticsAlgorithmVersion.respiration)
        return AnalyticsMetric(value: estimate, confidence: AnalyticsMath.clamp(0.6 * validFraction, 0.15, 0.6), tier: .relative, inputsUsed: inputs, note: "RIIV band-pass (0.1–0.5 Hz) on 1 Hz green ADC; coarse intensity proxy (not 419 Hz waveform); 1 Hz Nyquist caps rate at 30 br/min", algorithmVersion: AnalyticsAlgorithmVersion.respiration)
    }

    public static func fuse(rsa: AnalyticsMetric<RespiratoryEstimate>, riiv: AnalyticsMetric<RespiratoryEstimate>, disagreementBPM: Double = 5) -> AnalyticsMetric<FusedRespiration> {
        let inputs = rsa.inputsUsed + riiv.inputsUsed
        let rsaRate = rsa.value?.breathsPerMinute
        let riivRate = riiv.value?.breathsPerMinute
        guard rsaRate != nil || riivRate != nil else {
            return .absent(tier: .high, inputsUsed: inputs, note: "neither RSA nor RIIV resolved a respiratory rate", algorithmVersion: AnalyticsAlgorithmVersion.respiration)
        }
        if let rsaRate, riivRate == nil {
            let value = FusedRespiration(breathsPerMinute: rsaRate, rsaBreathsPerMinute: rsaRate, riivBreathsPerMinute: nil, agreed: false, decision: "rsa_only", algorithmVersion: AnalyticsAlgorithmVersion.respiration)
            return AnalyticsMetric(value: value, confidence: rsa.confidence, tier: .high, inputsUsed: inputs, note: "RSA-only (RIIV absent)", algorithmVersion: AnalyticsAlgorithmVersion.respiration)
        }
        if rsaRate == nil, let riivRate {
            let value = FusedRespiration(breathsPerMinute: riivRate, rsaBreathsPerMinute: nil, riivBreathsPerMinute: riivRate, agreed: false, decision: "riiv_only", algorithmVersion: AnalyticsAlgorithmVersion.respiration)
            return AnalyticsMetric(value: value, confidence: riiv.confidence, tier: .relative, inputsUsed: inputs, note: "RIIV-only (RSA absent) — relative/MED tier", algorithmVersion: AnalyticsAlgorithmVersion.respiration)
        }
        let difference = abs(rsaRate! - riivRate!)
        if difference > disagreementBPM {
            let value = FusedRespiration(breathsPerMinute: rsaRate!, rsaBreathsPerMinute: rsaRate, riivBreathsPerMinute: riivRate, agreed: false, decision: "disagree", algorithmVersion: AnalyticsAlgorithmVersion.respiration)
            return AnalyticsMetric(value: value, confidence: rsa.confidence * 0.6, tier: .high, inputsUsed: inputs, note: "Karlen SD-gate: RSA/RIIV disagree by \(AnalyticsMath.round6(difference)) br/min > \(disagreementBPM); fell back to RSA, lowered confidence", algorithmVersion: AnalyticsAlgorithmVersion.respiration)
        }
        let rsaVariance = 1 / pow(AnalyticsMath.clamp(rsa.confidence, 0.05, 1), 2)
        let riivVariance = 1 / pow(AnalyticsMath.clamp(riiv.confidence, 0.05, 1), 2)
        let weightSum = 1 / rsaVariance + 1 / riivVariance
        let fusedRate = (rsaRate! / rsaVariance + riivRate! / riivVariance) / weightSum
        let confidence = AnalyticsMath.clamp(max(rsa.confidence, riiv.confidence) + 0.1, 0.2, 0.95)
        let value = FusedRespiration(breathsPerMinute: fusedRate, rsaBreathsPerMinute: rsaRate, riivBreathsPerMinute: riivRate, agreed: true, decision: "fused", algorithmVersion: AnalyticsAlgorithmVersion.respiration)
        return AnalyticsMetric(value: value, confidence: confidence, tier: .high, inputsUsed: inputs, note: "Karlen SD-gate passed (Δ \(AnalyticsMath.round6(difference)) br/min); inverse-variance fused RSA+RIIV", algorithmVersion: AnalyticsAlgorithmVersion.respiration)
    }

    public static func variability(_ rates: [Double]) -> AnalyticsMetric<BreathingRateVariability> {
        let inputs = ["resp_rate_series"]
        guard rates.count >= 3, let average = AnalyticsMath.mean(rates), let standardDeviation = AnalyticsMath.sampleStandardDeviation(rates) else {
            return .absent(tier: .estimate, inputsUsed: inputs, note: "need ≥3 respiratory-rate windows for a BRV estimate", algorithmVersion: AnalyticsAlgorithmVersion.respiration)
        }
        let slope = theilSen(rates)
        let value = BreathingRateVariability(meanBreathsPerMinute: average, standardDeviationBreathsPerMinute: standardDeviation, coefficientOfVariation: average == 0 ? 0 : standardDeviation / average, trendSlope: slope, windowCount: rates.count, algorithmVersion: AnalyticsAlgorithmVersion.respiration)
        return AnalyticsMetric(value: value, confidence: AnalyticsMath.clamp(0.3 + 0.05 * Double(rates.count), 0.3, 0.8), tier: .estimate, inputsUsed: inputs, note: "Breathing-rate variability TREND (within-user only); surface a change only beyond the metric MDC", algorithmVersion: AnalyticsAlgorithmVersion.respiration)
    }

    private static func power(at frequency: Double, in spectrum: LombScargleSpectrum) -> Double {
        spectrum.points.min { abs($0.frequencyHz - frequency) < abs($1.frequencyHz - frequency) }?.power ?? 0
    }

    private struct Line { let slope: Double; let intercept: Double }
    private static func linearFit(values: [Double], times: [Double]) -> Line? {
        guard values.count >= 2, values.count == times.count, let meanX = AnalyticsMath.mean(times), let meanY = AnalyticsMath.mean(values) else { return nil }
        var numerator = 0.0; var denominator = 0.0
        for index in values.indices {
            numerator += (times[index] - meanX) * (values[index] - meanY)
            denominator += (times[index] - meanX) * (times[index] - meanX)
        }
        guard denominator != 0 else { return nil }
        let slope = numerator / denominator
        return Line(slope: slope, intercept: meanY - slope * meanX)
    }

    private static func theilSen(_ values: [Double]) -> Double? {
        guard values.count >= 2 else { return nil }
        var slopes: [Double] = []
        for i in values.indices {
            for j in values.indices where j > i { slopes.append((values[j] - values[i]) / Double(j - i)) }
        }
        return AnalyticsMath.median(slopes)
    }
}
