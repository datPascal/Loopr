import Foundation

/// The version of the analytics equations used by this package.  Persisted
/// rows carry this value so a later equation change cannot silently reinterpret
/// old results.
public enum AnalyticsAlgorithmVersion {
    public static let rrQuality = "ana02.rr-quality.v1"
    public static let baseline = "ana02.baseline.v1"
    public static let hrv = "ana02.hrv.v1"
    public static let nocturnal = "ana02.nocturnal.v1"
    public static let respiration = "ana02.respiration.v1"
}

public enum AnalyticsTier: String, Codable, Sendable, Equatable, CaseIterable {
    case auth = "AUTH"
    case high = "HIGH"
    case estimate = "ESTIMATE"
    case relative = "RELATIVE"
}

/// A metric deliberately preserves absence.  `value == nil` is not a zero or
/// a neutral default; callers must render it as unavailable.
public struct AnalyticsMetric<Value: Codable & Sendable & Equatable>: Codable, Sendable, Equatable {
    public let value: Value?
    public let confidence: Double
    public let tier: AnalyticsTier
    public let inputsUsed: [String]
    public let drivers: [AnalyticsDriver]?
    public let note: String?
    public let algorithmVersion: String

    public init(
        value: Value?,
        confidence: Double,
        tier: AnalyticsTier,
        inputsUsed: [String],
        drivers: [AnalyticsDriver]? = nil,
        note: String? = nil,
        algorithmVersion: String
    ) {
        self.value = value
        self.confidence = value == nil ? 0 : confidence
        self.tier = tier
        self.inputsUsed = inputsUsed
        self.drivers = drivers
        self.note = note
        self.algorithmVersion = algorithmVersion
    }

    public static func absent(
        tier: AnalyticsTier,
        inputsUsed: [String],
        note: String?,
        algorithmVersion: String
    ) -> Self {
        Self(value: nil, confidence: 0, tier: tier, inputsUsed: inputsUsed, note: note, algorithmVersion: algorithmVersion)
    }

    public var present: Bool { value != nil }
}

public struct AnalyticsDriver: Codable, Sendable, Equatable {
    public let label: String
    public let contribution: Double
    public let detail: String?

    public init(label: String, contribution: Double, detail: String? = nil) {
        self.label = label
        self.contribution = contribution
        self.detail = detail
    }
}

public struct RRSeries: Codable, Sendable, Equatable {
    public let timestampsMilliseconds: [Double]
    public let intervalsMilliseconds: [Double]

    public init(timestampsMilliseconds: [Double], intervalsMilliseconds: [Double]) {
        precondition(timestampsMilliseconds.count == intervalsMilliseconds.count, "RR timestamps and intervals must have equal lengths")
        self.timestampsMilliseconds = timestampsMilliseconds
        self.intervalsMilliseconds = intervalsMilliseconds
    }

    public init(intervalsMilliseconds: [Double]) {
        self.timestampsMilliseconds = []
        self.intervalsMilliseconds = intervalsMilliseconds
    }

    public var count: Int { intervalsMilliseconds.count }
    public var isEmpty: Bool { intervalsMilliseconds.isEmpty }

    public func beatTimesMilliseconds(startingAt start: Double = 0) -> [Double] {
        var result: [Double] = []
        result.reserveCapacity(intervalsMilliseconds.count)
        var t = start
        for interval in intervalsMilliseconds {
            t += interval
            result.append(t)
        }
        return result
    }
}

public struct HRSample: Codable, Sendable, Equatable {
    public let timestampMilliseconds: Double
    public let bpm: Double
    public init(timestampMilliseconds: Double, bpm: Double) {
        self.timestampMilliseconds = timestampMilliseconds
        self.bpm = bpm
    }
    public var valid: Bool { bpm > 0 }
}

public struct PPGSample: Codable, Sendable, Equatable {
    public let timestampMilliseconds: Double
    public let adc: Double
    public let valid: Bool
    public init(timestampMilliseconds: Double, adc: Double, valid: Bool = true) {
        self.timestampMilliseconds = timestampMilliseconds
        self.adc = adc
        self.valid = valid
    }
}

/// A relative-ADC channel.  It intentionally carries raw counts only: the
/// stable product never treats this shape as calibrated oxygen or temperature.
public struct ADCSample: Codable, Sendable, Equatable {
    public let timestampMilliseconds: Double
    public let adc: Double
    public let valid: Bool
    public init(timestampMilliseconds: Double, adc: Double, valid: Bool = true) {
        self.timestampMilliseconds = timestampMilliseconds
        self.adc = adc
        self.valid = valid
    }
}

public typealias AdcSample = ADCSample

public struct AccelSample: Codable, Sendable, Equatable {
    public let timestampMilliseconds: Double
    public let x: Double
    public let y: Double
    public let z: Double
    public let valid: Bool
    public init(timestampMilliseconds: Double, x: Double, y: Double, z: Double, valid: Bool = true) {
        self.timestampMilliseconds = timestampMilliseconds
        self.x = x
        self.y = y
        self.z = z
        self.valid = valid
    }
}

public struct NightlyRecord: Codable, Sendable, Equatable {
    public let date: String
    public let rhr: Double?
    public let lnRmssd: Double?
    public let rmssd: Double?
    public let sdnn: Double?
    public let respiratoryRate: Double?
    public let skinTemperatureZ: Double?
    public let coverage: Double?

    public init(
        date: String,
        rhr: Double? = nil,
        lnRmssd: Double? = nil,
        rmssd: Double? = nil,
        sdnn: Double? = nil,
        respiratoryRate: Double? = nil,
        skinTemperatureZ: Double? = nil,
        coverage: Double? = nil
    ) {
        self.date = date
        self.rhr = rhr
        self.lnRmssd = lnRmssd
        self.rmssd = rmssd
        self.sdnn = sdnn
        self.respiratoryRate = respiratoryRate
        self.skinTemperatureZ = skinTemperatureZ
        self.coverage = coverage
    }
}

public enum AnalyticsMath {
    public static func mean(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    public static func sampleStandardDeviation(_ values: [Double]) -> Double? {
        guard values.count >= 2, let average = mean(values) else { return nil }
        let sum = values.reduce(0) { partial, value in
            let delta = value - average
            return partial + delta * delta
        }
        return sqrt(sum / Double(values.count - 1))
    }

    public static func populationStandardDeviation(_ values: [Double]) -> Double? {
        guard !values.isEmpty, let average = mean(values) else { return nil }
        let sum = values.reduce(0) { partial, value in
            let delta = value - average
            return partial + delta * delta
        }
        return sqrt(sum / Double(values.count))
    }

    public static func percentile(_ values: [Double], _ percentile: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        guard sorted.count > 1 else { return sorted[0] }
        let rank = (percentile / 100) * Double(sorted.count - 1)
        let lower = Int(floor(rank))
        let upper = Int(ceil(rank))
        guard lower != upper else { return sorted[lower] }
        return sorted[lower] + (sorted[upper] - sorted[lower]) * (rank - Double(lower))
    }

    public static func median(_ values: [Double]) -> Double? { percentile(values, 50) }

    public static func mad(_ values: [Double], scaled: Bool = true) -> Double? {
        guard let center = median(values) else { return nil }
        let raw = median(values.map { abs($0 - center) })
        return raw.map { scaled ? $0 * 1.4826 : $0 }
    }

    public static func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        max(lower, min(upper, value))
    }

    public static func round6(_ value: Double) -> Double {
        guard value.isFinite else { return value }
        return (value * 1_000_000).rounded() / 1_000_000
    }

    public static func lambda(halfLife: Double) -> Double {
        guard halfLife > 0 else { return 1 }
        return 1 - pow(0.5, 1 / halfLife)
    }

    public static func safeLog(_ value: Double) -> Double? { value > 0 ? log(value) : nil }
}
