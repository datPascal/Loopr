import Foundation

public enum VitalsAlgorithmVersion {
    public static let skinTemperature = "vitals.skin-temperature.v2.byte72"
    public static let oxygen = "vitals.relative-oxygen.v2.independence"
    public static let cardioFitness = "vitals.cardio-fitness.v1"
    public static let beatToBeat = "vitals.beat-to-beat.v1"
}

/// A sleep interval in absolute seconds, half-open `[start, end)`.
public struct VitalsWindow: Codable, Sendable, Equatable {
    public let start: Double
    public let end: Double
    public init(start: Double, end: Double) { self.start = start; self.end = end }
    public func contains(_ timestamp: Double) -> Bool { timestamp >= start && timestamp < end }
}

public struct SkinTemperatureSample: Sendable, Equatable {
    public let timestamp: Double
    public let celsius: Double
    public let heartRate: Double?
    public init(timestamp: Double, celsius: Double, heartRate: Double?) {
        self.timestamp = timestamp; self.celsius = celsius; self.heartRate = heartRate
    }
}

public struct SkinTemperatureNight: Codable, Sendable, Equatable {
    /// Median of settled, worn seconds in the main sleep, approximate °C.
    public let celsius: Double
    public let keptSamples: Int
    public let settledFraction: Double
    public let sleepCoverage: Double
    public let algorithmVersion: String
}

public struct SkinTemperatureDeviationValue: Codable, Sendable, Equatable {
    public let deltaCelsius: Double
    public let baselineCelsius: Double
    public let z: Double
    public let baselineNights: Int
    public let trusted: Bool
    /// Absolute nightly range. Nil until 14 scorable nights, including tonight.
    public let usualRange: ClosedRange<Double>?
    public let outsideUsualRange: Bool
    public let likelyFitChange: Bool

    public init(deltaCelsius: Double, baselineCelsius: Double, z: Double, baselineNights: Int,
                trusted: Bool, usualRange: ClosedRange<Double>? = nil,
                outsideUsualRange: Bool, likelyFitChange: Bool) {
        self.deltaCelsius = deltaCelsius; self.baselineCelsius = baselineCelsius
        self.z = z; self.baselineNights = baselineNights; self.trusted = trusted
        self.usualRange = usualRange; self.outsideUsualRange = outsideUsualRange
        self.likelyFitChange = likelyFitChange
    }
}

public enum SkinTemperatureDeviation: Codable, Sendable, Equatable {
    case noReading
    case calibrating(nightsRemaining: Int)
    case available(SkinTemperatureDeviationValue)
    public var value: SkinTemperatureDeviationValue? {
        if case .available(let value) = self { return value }; return nil
    }
}

public enum SkinTemperatureAnalytics {
    public static let minimumSamples = 300
    public static let calibrationNights = 4
    public static let rangeNights = 14
    public static let fitArtifactCelsius = 2.0
    public static let minimumSettledFraction = 0.8
    public static let minimumSleepCoverage = 0.5
    public static let settlingSeconds = 600.0

    /// The byte-72 channel warms over minutes after donning and decays toward
    /// room temperature off wrist, as recorded band nights show.
    ///
    /// Conservatively restart after missing HR or a gap >2 seconds. Wait at
    /// least ten minutes, then require five full minute medians spanning no
    /// more than 0.3°C with <=0.1°C end-to-end drift. Once settled, ordinary
    /// sleep variation is retained; a cold drop restarts settling. The 30°C
    /// floor rejects room-temperature decay even if HR remains stale. The
    /// night's own median minus 0.7°C rejects cold contact segments without
    /// excluding a whole warmer or cooler night relative to its baseline.
    public static func nightly(_ samples: [SkinTemperatureSample], sleepWindows: [VitalsWindow],
                               minimumSamples: Int = minimumSamples) -> AnalyticsMetric<SkinTemperatureNight> {
        let inputs = ["skin_temperature_celsius", "heart_rate", "main_sleep_window"]
        let duration = sleepWindows.reduce(0) { $0 + max(0, $1.end - $1.start) }
        guard duration > 0 else {
            return .absent(tier: .relative, inputsUsed: inputs, note: "no main sleep window", algorithmVersion: VitalsAlgorithmVersion.skinTemperature)
        }
        // Deduplicate seconds, so a redelivered record cannot inflate coverage.
        var bySecond: [Int64: SkinTemperatureSample] = [:]
        for sample in samples where sample.timestamp.isFinite && sample.celsius.isFinite {
            bySecond[Int64(sample.timestamp)] = sample
        }
        let ordered = bySecond.keys.sorted().compactMap { bySecond[$0] }
        var run: [SkinTemperatureSample] = []
        var donAt: Double?
        var settled = false
        var candidates: [Double] = []
        var wornSeconds = 0
        var lastTimestamp: Double?
        for sample in ordered {
            guard sleepWindows.contains(where: { $0.contains(sample.timestamp) }),
                  let bpm = sample.heartRate, (30...220).contains(bpm), (30...45).contains(sample.celsius) else {
                run.removeAll(keepingCapacity: true); settled = false; lastTimestamp = nil; donAt = nil
                continue
            }
            wornSeconds += 1
            if let lastTimestamp, sample.timestamp - lastTimestamp > 2 {
                run.removeAll(keepingCapacity: true); settled = false; donAt = nil
            }
            if settled, let last = run.last, sample.celsius < last.celsius - 0.5 {
                run.removeAll(keepingCapacity: true); settled = false; donAt = nil
            }
            lastTimestamp = sample.timestamp
            if donAt == nil { donAt = sample.timestamp }
            run.append(sample)
            if !settled, let donAt, sample.timestamp - donAt >= settlingSeconds {
                let tail = run.filter { $0.timestamp > sample.timestamp - 300 }
                var buckets: [Int: [Double]] = [:]
                for value in tail {
                    let bucket = Int((sample.timestamp - value.timestamp) / 60)
                    buckets[bucket, default: []].append(value.celsius)
                }
                let medians = (0..<5).compactMap { index -> Double? in
                    guard let values = buckets[index], values.count >= 45 else { return nil }
                    return AnalyticsMath.median(values)
                }
                if medians.count == 5, let lo = medians.min(), let hi = medians.max(),
                   hi - lo <= 0.300001, abs(medians[0] - medians[4]) <= 0.100001 { settled = true }
            }
            if settled { candidates.append(sample.celsius) }
            // Keep the don time while bounding steady-state memory.
            if settled && run.count > 2 { run.removeFirst(run.count - 2) }
            else if run.count > 301 { run.removeFirst(run.count - 301) }
        }
        let median = AnalyticsMath.median(candidates)
        let core = median.map { center in candidates.filter { $0 >= center - 0.7 } } ?? []
        let fraction = wornSeconds > 0 ? Double(core.count) / Double(wornSeconds) : 0
        let coverage = Double(core.count) / duration
        guard core.count >= minimumSamples, fraction >= minimumSettledFraction,
              coverage >= minimumSleepCoverage, let value = AnalyticsMath.median(core) else {
            return .absent(tier: .relative, inputsUsed: inputs,
                note: "too little settled sleep temperature; check overnight band fit", algorithmVersion: VitalsAlgorithmVersion.skinTemperature)
        }
        let night = SkinTemperatureNight(celsius: value, keptSamples: core.count, settledFraction: fraction,
            sleepCoverage: coverage, algorithmVersion: VitalsAlgorithmVersion.skinTemperature)
        return AnalyticsMetric(value: night, confidence: min(0.8, coverage), tier: .relative,
            inputsUsed: inputs, note: "median settled wrist temperature; absolute value approximate",
            algorithmVersion: VitalsAlgorithmVersion.skinTemperature)
    }

    /// Caller supplies one entry per calendar day, oldest first, including gaps.
    /// A baseline uses the last 30 calendar days and never includes tonight.
    public static func deviation(tonightCelsius: Double?, priorNightsOldestFirst: [Double?]) -> SkinTemperatureDeviation {
        guard let tonightCelsius, tonightCelsius.isFinite, (30...45).contains(tonightCelsius) else { return .noReading }
        var prior = Array(priorNightsOldestFirst.suffix(30)).compactMap { $0 }.filter { $0.isFinite && (30...45).contains($0) }
        if let center = AnalyticsMath.median(prior) {
            prior = prior.filter { abs($0 - center) <= fitArtifactCelsius }
        }
        let count = prior.count + 1
        guard count >= calibrationNights, let center = AnalyticsMath.median(prior) else {
            return .calibrating(nightsRemaining: calibrationNights - count)
        }
        let mad = AnalyticsMath.median(prior.map { abs($0 - center) }) ?? 0
        // One tenth is the sensor step. This is an engineering noise floor.
        let spread = max(0.1, 1.4826 * mad)
        let halfWidth = max(0.3, 2.5 * spread)
        let delta = tonightCelsius - center
        let trusted = count >= rangeNights
        let fit = abs(delta) > fitArtifactCelsius
        return .available(SkinTemperatureDeviationValue(deltaCelsius: delta, baselineCelsius: center,
            z: delta / spread, baselineNights: prior.count, trusted: trusted,
            usualRange: trusted ? (center - halfWidth)...(center + halfWidth) : nil,
            outsideUsualRange: trusted && !fit && abs(delta) > halfWidth, likelyFitChange: fit))
    }
}
