import Foundation

/// One second of the WHOOP 4.0 red and infrared optical registers
/// (`spo2_red_raw` at byte 64, `spo2_ir_raw` at byte 66 of the v24 record).
public struct OpticalOxygenSample: Sendable, Equatable {
    public let timestamp: Double
    public let red: Int
    public let infrared: Int
    public let heartRate: Double?

    public init(timestamp: Double, red: Int, infrared: Int, heartRate: Double?) {
        self.timestamp = timestamp
        self.red = red
        self.infrared = infrared
        self.heartRate = heartRate
    }
}

/// Whether the red and infrared channels carry anything a ratio can be built
/// from. Pulse oximetry needs the pulsatile (AC) part of each channel; at one
/// sample per second OpenStrap estimates it as the short-window variation. A
/// channel that holds the same count for most seconds has no such part.
public struct OxygenSignalAssessment: Codable, Sendable, Equatable {
    public let analysedSeconds: Int
    /// Share of consecutive worn seconds in which the channel changed at all.
    public let redChangeFraction: Double
    public let infraredChangeFraction: Double
    /// Share of 30-second windows in which both channels varied on at least
    /// half of their seconds.
    public let variableWindowFraction: Double
    /// Fraction of windows that contain two independently varying channels.
    public let independentWindowFraction: Double?
    public let usable: Bool

    public init(analysedSeconds: Int, redChangeFraction: Double, infraredChangeFraction: Double,
                variableWindowFraction: Double, usable: Bool, independentWindowFraction: Double? = nil) {
        self.analysedSeconds = analysedSeconds
        self.redChangeFraction = redChangeFraction
        self.infraredChangeFraction = infraredChangeFraction
        self.variableWindowFraction = variableWindowFraction
        self.independentWindowFraction = independentWindowFraction
        self.usable = usable
    }
}

/// A night's relative red/infrared ratio. Unitless and never a saturation
/// percentage: without a per-device calibration curve the ratio can only be
/// compared with the same wearer's other nights.
public struct RelativeOxygenNight: Codable, Sendable, Equatable {
    public let medianRatio: Double
    public let windows: Int
    public let assessment: OxygenSignalAssessment
    public let algorithmVersion: String

    public init(medianRatio: Double, windows: Int, assessment: OxygenSignalAssessment,
                algorithmVersion: String = VitalsAlgorithmVersion.oxygen) {
        self.medianRatio = medianRatio
        self.windows = windows
        self.assessment = assessment
        self.algorithmVersion = algorithmVersion
    }
}

public enum RelativeOxygenDeviation: Codable, Sendable, Equatable {
    case noReading
    case calibrating(nightsRemaining: Int)
    /// Percent change of tonight's ratio against the median of earlier
    /// nights. The ratio rises as oxygenation falls (TI SLAA655), so a positive
    /// change reads as lower relative oxygen.
    case available(percentChange: Double, baselineNights: Int)
}

public enum OvernightOxygenAnalytics {
    public static let windowSeconds = 30
    /// A channel must change on at least half of its seconds. A sampled
    /// pulse wave changes almost every second.
    public static let minimumChangeFraction = 0.5
    /// At least half of the night's windows must carry variation on both
    /// channels before a nightly ratio is published.
    public static let minimumVariableWindowFraction = 0.5
    public static let minimumWindows = 20
    public static let minimumBaselineNights = 4

    private static func wornInWindow(_ samples: [OpticalOxygenSample], sleepWindows: [VitalsWindow]) -> [OpticalOxygenSample] {
        samples.filter { sample in
            guard let bpm = sample.heartRate, (30...220).contains(bpm) else { return false }
            return sleepWindows.contains { $0.contains(sample.timestamp) }
        }.sorted { $0.timestamp < $1.timestamp }
    }

    private static func windows(_ worn: [OpticalOxygenSample]) -> [[OpticalOxygenSample]] {
        guard let first = worn.first?.timestamp else { return [] }
        var buckets: [Int: [OpticalOxygenSample]] = [:]
        for sample in worn { buckets[Int((sample.timestamp - first) / Double(windowSeconds)), default: []].append(sample) }
        return buckets.keys.sorted().compactMap { key in
            let bucket = buckets[key] ?? []
            return bucket.count >= windowSeconds / 2 ? bucket : nil
        }
    }

    private static func changeFraction(_ values: [Int]) -> Double {
        guard values.count >= 2 else { return 0 }
        var changes = 0
        for index in 1..<values.count where values[index] != values[index - 1] { changes += 1 }
        return Double(changes) / Double(values.count - 1)
    }

    /// The offset between v24 red/IR is nearly constant even when both change
    /// every second. Evidence: recorded band nights and MIT OpenStrap protocol records.dart at ecb512b710fb, offsets 64/66.
    /// Refuse each lockstep window before forming a ratio. A one-count noise
    /// band or delta correlation >=0.995 is insufficient independent information.
    private static func independent(_ bucket: [OpticalOxygenSample]) -> Bool {
        let differences = bucket.map { Double($0.red - $0.infrared) }
        guard let sd = AnalyticsMath.sampleStandardDeviation(differences), sd > 1 else { return false }
        var red: [Double] = [], infrared: [Double] = []
        for index in 1..<bucket.count where bucket[index].timestamp - bucket[index - 1].timestamp <= 2 {
            red.append(Double(bucket[index].red - bucket[index - 1].red))
            infrared.append(Double(bucket[index].infrared - bucket[index - 1].infrared))
        }
        guard red.count >= 10, let rMean = AnalyticsMath.mean(red), let iMean = AnalyticsMath.mean(infrared) else { return false }
        var covariance = 0.0, rSquared = 0.0, iSquared = 0.0
        for index in red.indices {
            let r = red[index] - rMean, i = infrared[index] - iMean
            covariance += r * i; rSquared += r * r; iSquared += i * i
        }
        guard rSquared > 0, iSquared > 0 else { return false }
        return covariance / sqrt(rSquared * iSquared) < 0.995
    }

    /// Measures whether the channels are usable before anything is computed.
    public static func assess(_ samples: [OpticalOxygenSample], sleepWindows: [VitalsWindow]) -> OxygenSignalAssessment {
        let worn = wornInWindow(samples, sleepWindows: sleepWindows)
        let buckets = windows(worn)
        let variable = buckets.filter {
            changeFraction($0.map(\.red)) >= minimumChangeFraction
                && changeFraction($0.map(\.infrared)) >= minimumChangeFraction
        }.count
        let independentBuckets = buckets.filter(independent).count
        let independentFraction = buckets.isEmpty ? 0 : Double(independentBuckets) / Double(buckets.count)
        let variableFraction = buckets.isEmpty ? 0 : Double(variable) / Double(buckets.count)
        let red = changeFraction(worn.map(\.red))
        let infrared = changeFraction(worn.map(\.infrared))
        let usable = buckets.count >= minimumWindows
            && red >= minimumChangeFraction && infrared >= minimumChangeFraction
            && variableFraction >= minimumVariableWindowFraction
            && independentFraction >= minimumVariableWindowFraction
        return OxygenSignalAssessment(analysedSeconds: worn.count, redChangeFraction: red,
            infraredChangeFraction: infrared, variableWindowFraction: variableFraction, usable: usable,
            independentWindowFraction: independentFraction)
    }

    /// The night's median ratio of ratios, (SD_red / mean_red) / (SD_ir / mean_ir),
    /// over 30-second windows (OpenStrap `relative_odi.dart`). Absent whenever
    /// the channels fail `assess`.
    public static func nightly(_ samples: [OpticalOxygenSample], sleepWindows: [VitalsWindow]) -> AnalyticsMetric<RelativeOxygenNight> {
        let inputs = ["spo2_red_raw", "spo2_ir_raw", "heart_rate", "sleep_window"]
        let assessment = assess(samples, sleepWindows: sleepWindows)
        guard assessment.usable else {
            return .absent(tier: .relative, inputsUsed: inputs,
                note: String(format: "optical channels not pulsatile at 1 Hz (red changes %.0f%%, IR %.0f%% of seconds)",
                             assessment.redChangeFraction * 100, assessment.infraredChangeFraction * 100),
                algorithmVersion: VitalsAlgorithmVersion.oxygen)
        }
        let ratios = windows(wornInWindow(samples, sleepWindows: sleepWindows)).filter(independent).compactMap { bucket -> Double? in
            let red = bucket.map { Double($0.red) }, infrared = bucket.map { Double($0.infrared) }
            guard let redMean = AnalyticsMath.mean(red), let irMean = AnalyticsMath.mean(infrared),
                  let redSD = AnalyticsMath.sampleStandardDeviation(red),
                  let irSD = AnalyticsMath.sampleStandardDeviation(infrared),
                  redMean > 0, irMean > 0, redSD > 0, irSD > 0 else { return nil }
            return (redSD / redMean) / (irSD / irMean)
        }
        guard ratios.count >= minimumWindows, let median = AnalyticsMath.median(ratios) else {
            return .absent(tier: .relative, inputsUsed: inputs, note: "too few windows with a ratio",
                algorithmVersion: VitalsAlgorithmVersion.oxygen)
        }
        return AnalyticsMetric(value: RelativeOxygenNight(medianRatio: median, windows: ratios.count, assessment: assessment),
            confidence: AnalyticsMath.clamp(assessment.variableWindowFraction, 0.3, 0.6), tier: .relative,
            inputsUsed: inputs, note: "relative ratio of ratios; never a saturation percentage",
            algorithmVersion: VitalsAlgorithmVersion.oxygen)
    }

    public static func deviation(tonightRatio: Double?, priorRatios: [Double]) -> RelativeOxygenDeviation {
        guard let tonightRatio, tonightRatio.isFinite, tonightRatio > 0 else { return .noReading }
        let prior = priorRatios.filter { $0.isFinite && $0 > 0 }
        guard prior.count >= minimumBaselineNights, let baseline = AnalyticsMath.median(prior) else {
            return .calibrating(nightsRemaining: max(1, minimumBaselineNights - prior.count))
        }
        return .available(percentChange: (tonightRatio / baseline - 1) * 100, baselineNights: prior.count)
    }
}
