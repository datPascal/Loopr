import Foundation
import DomainKit

public enum ActivityAlgorithm {
    public static let version = "loopr.activity.1"
}

public enum ActivitySex: String, Codable, Sendable, Equatable {
    case male
    case female
    case nonbinary
}

public enum HRMaxSource: String, Codable, Sendable, Equatable {
    case measured
    case agePredicted
    case manual
}

public struct ActivityAccelerationSample: Codable, Sendable, Equatable {
    public let timestamp: TimeInterval
    public let x: Double
    public let y: Double
    public let z: Double
    public let valid: Bool

    public init(timestamp: TimeInterval, x: Double, y: Double, z: Double, valid: Bool = true) {
        self.timestamp = timestamp; self.x = x; self.y = y; self.z = z; self.valid = valid
    }
}

public struct ActivityHeartRateSample: Codable, Sendable, Equatable {
    public let timestamp: TimeInterval
    public let bpm: Double
    public let valid: Bool
    public let goodSignal: Bool

    public init(timestamp: TimeInterval, bpm: Double, valid: Bool = true, goodSignal: Bool = false) {
        self.timestamp = timestamp; self.bpm = bpm; self.valid = valid; self.goodSignal = goodSignal
    }
}

/// Coarse wrist-orientation proxy derived only from a low-motion gravity
/// vector.  This is deliberately not a torso-position claim and does not
/// attempt dynamic/quaternion orientation.
public enum ActivityPosition: String, Codable, Sendable, Equatable {
    case supine
    case prone
    case lateralLeft = "lateral_left"
    case lateralRight = "lateral_right"
    case upright
    case unknown
}

public struct Tilt: Codable, Sendable, Equatable {
    public let pitchDeg: Double
    public let rollDeg: Double
    public let position: ActivityPosition
    public let nSamples: Int
    public let stillness: Double
    public let algorithmVersion: String

    public init(
        pitchDeg: Double,
        rollDeg: Double,
        position: ActivityPosition,
        nSamples: Int,
        stillness: Double,
        algorithmVersion: String = ActivityAlgorithm.version
    ) {
        self.pitchDeg = pitchDeg; self.rollDeg = rollDeg; self.position = position
        self.nSamples = nSamples; self.stillness = stillness
        self.algorithmVersion = algorithmVersion
    }
}

public struct MotionMinute: Codable, Sendable, Equatable {
    public let start: TimeInterval
    public let sampleCount: Int
    public let enmo: Double
    public let mad: Double
    public let meanMagnitude: Double
    public let dynamicAmplitude: Double

    public init(start: TimeInterval, sampleCount: Int, enmo: Double, mad: Double, meanMagnitude: Double, dynamicAmplitude: Double) {
        self.start = start; self.sampleCount = sampleCount; self.enmo = enmo; self.mad = mad
        self.meanMagnitude = meanMagnitude; self.dynamicAmplitude = dynamicAmplitude
    }
}

public struct EnmoResult: Codable, Sendable, Equatable {
    public let gravityReference: Double
    public let minutes: [MotionMinute]
    public let coverage: Double

    public init(gravityReference: Double, minutes: [MotionMinute], coverage: Double) {
        self.gravityReference = gravityReference; self.minutes = minutes; self.coverage = coverage
    }
}

public struct IntensityBands: Codable, Sendable, Equatable {
    public let lightCut: Double
    public let moderateCut: Double
    public let vigorousCut: Double
    public let labels: [String]
    public let minutesInBand: [String: Int]

    public init(lightCut: Double, moderateCut: Double, vigorousCut: Double, labels: [String], minutesInBand: [String: Int]) {
        self.lightCut = lightCut; self.moderateCut = moderateCut; self.vigorousCut = vigorousCut
        self.labels = labels; self.minutesInBand = minutesInBand
    }
}

public struct HeartRateZone: Codable, Sendable, Equatable {
    public let number: Int
    public let lowerBPM: Double
    public let upperBPM: Double
    public let lowerPercent: Double
    public let upperPercent: Double

    public init(number: Int, lowerBPM: Double, upperBPM: Double, lowerPercent: Double, upperPercent: Double) {
        self.number = number; self.lowerBPM = lowerBPM; self.upperBPM = upperBPM
        self.lowerPercent = lowerPercent; self.upperPercent = upperPercent
    }
}

public struct HeartRateZoneSet: Codable, Sendable, Equatable {
    public let zones: [HeartRateZone]
    public let maxHR: Double
    public let source: HRMaxSource
    public let restingHR: Double?

    public init(zones: [HeartRateZone], maxHR: Double, source: HRMaxSource, restingHR: Double? = nil) {
        self.zones = zones; self.maxHR = maxHR; self.source = source; self.restingHR = restingHR
    }

    public func zoneNumber(for bpm: Double) -> Int {
        for zone in zones {
            if zone.number == 5 {
                if bpm >= zone.lowerBPM { return 5 }
            } else if bpm >= zone.lowerBPM && bpm < zone.upperBPM {
                return zone.number
            }
        }
        return 0
    }
}

public struct TimeInHeartRateZones: Codable, Sendable, Equatable {
    public let seconds: [Double]
    public let belowZone1Seconds: Double

    public init(seconds: [Double], belowZone1Seconds: Double) {
        self.seconds = seconds; self.belowZone1Seconds = belowZone1Seconds
    }

    public var totalSeconds: Double { seconds.reduce(belowZone1Seconds, +) }
    public func secondsInZone(_ number: Int) -> Double { number >= 1 && number <= seconds.count ? seconds[number - 1] : 0 }
}

public struct HRMaxEstimate: Codable, Sendable, Equatable {
    public let maxHR: Double
    public let source: HRMaxSource?
    public let age: Double?
    public let algorithmVersion: String

    public init(maxHR: Double, source: HRMaxSource?, age: Double?, algorithmVersion: String = ActivityAlgorithm.version) {
        self.maxHR = maxHR; self.source = source; self.age = age; self.algorithmVersion = algorithmVersion
    }
}

public struct StrainValue: Codable, Sendable, Equatable {
    public let trimp: Double
    public let strain: Double
    public let method: String
    public let hrMax: Double
    public let hrMaxSource: HRMaxSource
    public let algorithmVersion: String

    public init(trimp: Double, strain: Double, method: String, hrMax: Double, hrMaxSource: HRMaxSource, algorithmVersion: String = ActivityAlgorithm.version) {
        self.trimp = trimp; self.strain = strain; self.method = method; self.hrMax = hrMax; self.hrMaxSource = hrMaxSource; self.algorithmVersion = algorithmVersion
    }
}

public struct LoadState: Codable, Sendable, Equatable {
    public let ctl: Double
    public let atl: Double
    public let tsb: Double
    public let algorithmVersion: String

    public init(ctl: Double, atl: Double, tsb: Double, algorithmVersion: String = ActivityAlgorithm.version) {
        self.ctl = ctl; self.atl = atl; self.tsb = tsb; self.algorithmVersion = algorithmVersion
    }
}

public struct PedometerResult: Codable, Sendable, Equatable {
    public let steps: Int
    public let durationSeconds: Double
    public let cadenceSPM: Double
    public let peakToPeakG: Double
    public let confidence: Double

    public init(steps: Int, durationSeconds: Double, cadenceSPM: Double, peakToPeakG: Double, confidence: Double) {
        self.steps = steps; self.durationSeconds = durationSeconds; self.cadenceSPM = cadenceSPM; self.peakToPeakG = peakToPeakG; self.confidence = confidence
    }
}

public struct StepCalibration: Codable, Sendable, Equatable {
    public let cadenceSPM: Double
    public let referenceENMO: Double
    public let count: Int

    public init(cadenceSPM: Double, referenceENMO: Double, count: Int) {
        self.cadenceSPM = cadenceSPM; self.referenceENMO = referenceENMO; self.count = count
    }

    /// Source-compatible spelling used by the pinned Dart model.
    public var refEnmo: Double { referenceENMO }
}

/// A cumulative device counter sample. Counter reconciliation is separate
/// from foreground pedometer inference because a device counter can reset,
/// resume after a gap, or report a backlog independently of raw motion.
public struct StepCounterSample: Codable, Sendable, Equatable {
    public let timestamp: TimeInterval
    public let cumulativeSteps: Int
    public let valid: Bool

    public init(timestamp: TimeInterval, cumulativeSteps: Int, valid: Bool = true) {
        self.timestamp = timestamp
        self.cumulativeSteps = cumulativeSteps
        self.valid = valid
    }
}

public struct StepCounterDaySummary: Codable, Sendable, Equatable {
    public let day: DayIdentity
    public let steps: Int
    public let resetDetected: Bool
    public let backlogSteps: Int

    public init(day: DayIdentity, steps: Int, resetDetected: Bool, backlogSteps: Int) {
        self.day = day
        self.steps = steps
        self.resetDetected = resetDetected
        self.backlogSteps = backlogSteps
    }
}

public struct StepCounterResult: Codable, Sendable, Equatable {
    public let days: [StepCounterDaySummary]
    public let totalSteps: Int
    public let resetCount: Int
    public let backlogSteps: Int
    public let algorithmVersion: String

    public init(
        days: [StepCounterDaySummary], totalSteps: Int, resetCount: Int,
        backlogSteps: Int, algorithmVersion: String = ActivityAlgorithm.version
    ) {
        self.days = days
        self.totalSteps = totalSteps
        self.resetCount = resetCount
        self.backlogSteps = backlogSteps
        self.algorithmVersion = algorithmVersion
    }
}

public struct DailyStepEstimate: Codable, Sendable, Equatable {
    public let activeMinutes: Int
    public let stepsLow: Int
    public let stepsHigh: Int
    public let stepsMidpoint: Int
    public let cadenceLowSPM: Double
    public let cadenceHighSPM: Double
    public let dynamicFloorG: Double
    public let coverage: Double
    public let calibrated: Bool

    public init(activeMinutes: Int, stepsLow: Int, stepsHigh: Int, stepsMidpoint: Int, cadenceLowSPM: Double, cadenceHighSPM: Double, dynamicFloorG: Double, coverage: Double, calibrated: Bool) {
        self.activeMinutes = activeMinutes; self.stepsLow = stepsLow; self.stepsHigh = stepsHigh; self.stepsMidpoint = stepsMidpoint
        self.cadenceLowSPM = cadenceLowSPM; self.cadenceHighSPM = cadenceHighSPM; self.dynamicFloorG = dynamicFloorG; self.coverage = coverage; self.calibrated = calibrated
    }
}

public struct EnergyPoint: Codable, Sendable, Equatable {
    public let timestamp: TimeInterval
    public let index: Double
    public let accelComponent: Double
    public let heartRateComponent: Double
    public let accelerationWeight: Double
    public let branch: String

    public init(timestamp: TimeInterval, index: Double, accelComponent: Double, heartRateComponent: Double, accelerationWeight: Double, branch: String) {
        self.timestamp = timestamp; self.index = index; self.accelComponent = accelComponent; self.heartRateComponent = heartRateComponent; self.accelerationWeight = accelerationWeight; self.branch = branch
    }
}

public struct EnergyFusion: Codable, Sendable, Equatable {
    public let points: [EnergyPoint]
    public let relativeLoad: Double
    public let calibrated: Bool
    public let algorithmVersion: String

    public init(points: [EnergyPoint], relativeLoad: Double, calibrated: Bool, algorithmVersion: String = ActivityAlgorithm.version) {
        self.points = points; self.relativeLoad = relativeLoad; self.calibrated = calibrated; self.algorithmVersion = algorithmVersion
    }
}

public struct ActivityUserProfile: Codable, Sendable, Equatable {
    public let weightKG: Double
    public let heightCM: Double
    public let age: Double
    public let sex: ActivitySex

    public init(weightKG: Double, heightCM: Double, age: Double, sex: ActivitySex) {
        self.weightKG = weightKG; self.heightCM = heightCM; self.age = age; self.sex = sex
    }
}

public struct ActivityInputSnapshot: Codable, Sendable, Equatable {
    public let heartRate: [ActivityHeartRateSample]
    public let acceleration: [ActivityAccelerationSample]
    public let restingHR: Double?
    public let measuredHRMax: Double?
    public let zoneSettings: HeartRateZoneSettings?
    public let age: Double?
    public let sex: ActivitySex
    public let dailyTrimpHistory: [Double]
    public let personalDynamicFloor: Double?
    public let pooledMotionMinutes: Int
    public let stepCalibration: StepCalibration?
    public let stepCounterReadings: [StepCounterSample]
    public let timeZoneIdentifier: String?
    /// How much history the personal movement floor needs before it exists.
    /// It is a day count when the floor comes from daily summaries and a
    /// minute count when it comes from pooled minutes, so the cold-start note
    /// can report honest progress either way.
    public let personalDynamicFloorRequirement: Int

    public init(
        heartRate: [ActivityHeartRateSample] = [], acceleration: [ActivityAccelerationSample] = [], restingHR: Double? = nil,
        measuredHRMax: Double? = nil, zoneSettings: HeartRateZoneSettings? = nil, age: Double? = nil, sex: ActivitySex = .nonbinary,
        dailyTrimpHistory: [Double] = [], personalDynamicFloor: Double? = nil, pooledMotionMinutes: Int = 0,
        stepCalibration: StepCalibration? = nil, stepCounterReadings: [StepCounterSample] = [], timeZoneIdentifier: String? = nil,
        personalDynamicFloorRequirement: Int = ActivityAnalytics.personalDynamicFloorMinimumMinutes
    ) {
        self.heartRate = heartRate; self.acceleration = acceleration; self.restingHR = restingHR; self.measuredHRMax = measuredHRMax
        self.zoneSettings = zoneSettings
        self.age = age; self.sex = sex; self.dailyTrimpHistory = dailyTrimpHistory; self.personalDynamicFloor = personalDynamicFloor
        self.pooledMotionMinutes = pooledMotionMinutes; self.stepCalibration = stepCalibration
        self.stepCounterReadings = stepCounterReadings
        self.timeZoneIdentifier = timeZoneIdentifier
        self.personalDynamicFloorRequirement = personalDynamicFloorRequirement
    }

    private enum CodingKeys: String, CodingKey {
        case heartRate, acceleration, restingHR, measuredHRMax, zoneSettings, age, sex, dailyTrimpHistory
        case personalDynamicFloor, pooledMotionMinutes, stepCalibration, stepCounterReadings
        case timeZoneIdentifier, personalDynamicFloorRequirement
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        heartRate = try container.decodeIfPresent([ActivityHeartRateSample].self, forKey: .heartRate) ?? []
        acceleration = try container.decodeIfPresent([ActivityAccelerationSample].self, forKey: .acceleration) ?? []
        restingHR = try container.decodeIfPresent(Double.self, forKey: .restingHR)
        measuredHRMax = try container.decodeIfPresent(Double.self, forKey: .measuredHRMax)
        zoneSettings = try container.decodeIfPresent(HeartRateZoneSettings.self, forKey: .zoneSettings)
        age = try container.decodeIfPresent(Double.self, forKey: .age)
        sex = try container.decodeIfPresent(ActivitySex.self, forKey: .sex) ?? .nonbinary
        dailyTrimpHistory = try container.decodeIfPresent([Double].self, forKey: .dailyTrimpHistory) ?? []
        personalDynamicFloor = try container.decodeIfPresent(Double.self, forKey: .personalDynamicFloor)
        pooledMotionMinutes = try container.decodeIfPresent(Int.self, forKey: .pooledMotionMinutes) ?? 0
        stepCalibration = try container.decodeIfPresent(StepCalibration.self, forKey: .stepCalibration)
        stepCounterReadings = try container.decodeIfPresent([StepCounterSample].self, forKey: .stepCounterReadings) ?? []
        timeZoneIdentifier = try container.decodeIfPresent(String.self, forKey: .timeZoneIdentifier)
        personalDynamicFloorRequirement = try container.decodeIfPresent(Int.self, forKey: .personalDynamicFloorRequirement)
            ?? ActivityAnalytics.personalDynamicFloorMinimumMinutes
    }
}

public struct ActivityDerivation: Codable, Sendable, Equatable {
    public let zones: AnalyticsMetric<TimeInHeartRateZones>
    public let strain: AnalyticsMetric<StrainValue>
    public let motion: AnalyticsMetric<EnmoResult>
    public let steps: AnalyticsMetric<DailyStepEstimate>
    public let energy: AnalyticsMetric<EnergyFusion>
    public let load: AnalyticsMetric<LoadState>
    public let stepCounter: AnalyticsMetric<StepCounterResult>?
    public let algorithmVersion: String

    public init(zones: AnalyticsMetric<TimeInHeartRateZones>, strain: AnalyticsMetric<StrainValue>, motion: AnalyticsMetric<EnmoResult>, steps: AnalyticsMetric<DailyStepEstimate>, energy: AnalyticsMetric<EnergyFusion>, load: AnalyticsMetric<LoadState>, algorithmVersion: String = ActivityAlgorithm.version, stepCounter: AnalyticsMetric<StepCounterResult>? = nil) {
        self.zones = zones; self.strain = strain; self.motion = motion; self.steps = steps; self.energy = energy; self.load = load; self.stepCounter = stepCounter; self.algorithmVersion = algorithmVersion
    }
}

public protocol ActivityAnalyticsRepository: Sendable {
    func activity(for day: DayIdentity) async throws -> ActivityDerivation?
}

public enum ActivityAnalytics {
    public static let algorithmVersion = ActivityAlgorithm.version
    public static let personalDynamicFloorQuantile = 0.90
    public static let personalDynamicFloorMinimumMinutes = 2_000

    public static func calibrateGRef(_ magnitudes: [Double]) -> Double {
        guard !magnitudes.isEmpty else { return 1 }
        guard magnitudes.count > 1 else { return magnitudes[0] > 0 ? magnitudes[0] : 1 }
        let steps = zip(magnitudes.dropFirst(), magnitudes).map { abs($0.0 - $0.1) }
        let threshold = AnalyticsMath.median(steps) ?? 0
        let still = zip(magnitudes.dropFirst(), magnitudes).compactMap { pair in abs(pair.0 - pair.1) <= threshold ? pair.0 : nil }
        let reference = AnalyticsMath.median(still.count >= 2 ? still : magnitudes) ?? 1
        return reference > 0 ? reference : 1
    }

    public static func classifyPosition(pitchDeg: Double, rollDeg: Double) -> ActivityPosition {
        guard pitchDeg.isFinite, rollDeg.isFinite else { return .unknown }
        if abs(pitchDeg) > 60 { return .upright }
        let absoluteRoll = abs(rollDeg)
        if absoluteRoll < 45 { return .supine }
        if absoluteRoll > 135 { return .prone }
        return rollDeg > 0 ? .lateralRight : .lateralLeft
    }

    /// Estimate static gravity tilt over a low-motion epoch.  Dynamic epochs
    /// return an explicit absence because their vector direction is not a
    /// reliable posture proxy.
    public static func staticTilt(
        _ epoch: [ActivityAccelerationSample],
        maxJitterG: Double = 0.05,
        minSamples: Int = 3
    ) -> AnalyticsMetric<Tilt> {
        let inputs = ["accel_1hz"]
        let valid = epoch.filter { sample in
            sample.valid && [sample.x, sample.y, sample.z].allSatisfy { $0.isFinite }
        }
        guard maxJitterG > 0, valid.count >= minSamples else {
            return .absent(tier: .high, inputs: inputs, note: "epoch too short for a static-tilt estimate", algorithmVersion: algorithmVersion)
        }
        let magnitudes = valid.map { sqrt($0.x * $0.x + $0.y * $0.y + $0.z * $0.z) }
        var jitter = 0.0
        if magnitudes.count > 1 {
            jitter = zip(magnitudes.dropFirst(), magnitudes).reduce(0) { partial, pair in partial + abs(pair.0 - pair.1) } / Double(magnitudes.count - 1)
        }
        let stillness = AnalyticsMath.clamp(1 - jitter / maxJitterG, 0, 1)
        guard jitter <= maxJitterG else {
            return .absent(tier: .high, inputs: inputs, note: "epoch too dynamic for static posture", algorithmVersion: algorithmVersion)
        }
        let meanX = AnalyticsMath.mean(valid.map(\.x)) ?? 0
        let meanY = AnalyticsMath.mean(valid.map(\.y)) ?? 0
        let meanZ = AnalyticsMath.mean(valid.map(\.z)) ?? 0
        let radiansToDegrees = 180 / Double.pi
        let pitch = atan2(-meanX, sqrt(meanY * meanY + meanZ * meanZ)) * radiansToDegrees
        let roll = atan2(meanY, meanZ) * radiansToDegrees
        let confidence = AnalyticsMath.clamp(stillness * AnalyticsMath.clamp(Double(valid.count) / 30, 0.3, 1), 0, 0.9)
        let value = Tilt(
            pitchDeg: pitch,
            rollDeg: roll,
            position: classifyPosition(pitchDeg: pitch, rollDeg: roll),
            nSamples: valid.count,
            stillness: stillness
        )
        return AnalyticsMetric(value: value, confidence: confidence, tier: .high, inputs: inputs, note: "wrist gravity tilt; body-position proxy (static, low-motion only)", algorithmVersion: algorithmVersion)
    }

    public static func positionSeries(
        _ samples: [ActivityAccelerationSample],
        epochSeconds: Int = 30,
        maxJitterG: Double = 0.05
    ) -> [Tilt] {
        guard epochSeconds > 0 else { return [] }
        var buckets: [Int: [ActivityAccelerationSample]] = [:]
        for sample in samples where sample.valid && sample.timestamp.isFinite {
            buckets[Int(floor(sample.timestamp / Double(epochSeconds))), default: []].append(sample)
        }
        return buckets.keys.sorted().compactMap { key in
            staticTilt(buckets[key]!, maxJitterG: maxJitterG).value
        }
    }

    public static func enmoSeries(_ samples: [ActivityAccelerationSample], gravityReference: Double? = nil, minimumSamplesPerMinute: Int = 30, gravityWindowSeconds: Double = 15) -> AnalyticsMetric<EnmoResult> {
        let valid = samples.filter { $0.valid && [$0.x, $0.y, $0.z].allSatisfy(\.isFinite) }.sorted { $0.timestamp < $1.timestamp }
        guard !valid.isEmpty else { return .absent(tier: .relative, inputs: ["accel_1hz"], note: "no valid acceleration samples", algorithmVersion: algorithmVersion) }
        let magnitudes = valid.map { sqrt($0.x * $0.x + $0.y * $0.y + $0.z * $0.z) }
        let reference = gravityReference ?? calibrateGRef(magnitudes)
        var dynamic = [Double](repeating: 0, count: valid.count)
        var lower = 0, sumX = 0.0, sumY = 0.0, sumZ = 0.0
        for i in valid.indices {
            sumX += valid[i].x; sumY += valid[i].y; sumZ += valid[i].z
            while lower < i && valid[i].timestamp - valid[lower].timestamp >= gravityWindowSeconds {
                sumX -= valid[lower].x; sumY -= valid[lower].y; sumZ -= valid[lower].z; lower += 1
            }
            let count = Double(i - lower + 1)
            let dx = valid[i].x - sumX / count, dy = valid[i].y - sumY / count, dz = valid[i].z - sumZ / count
            dynamic[i] = sqrt(dx * dx + dy * dy + dz * dz)
        }
        var buckets: [Int: [Int]] = [:]
        for i in valid.indices { buckets[Int(floor(valid[i].timestamp / 60)) , default: []].append(i) }
        var minutes: [MotionMinute] = []
        var covered = 0
        for key in buckets.keys.sorted() {
            let indexes = buckets[key]!
            let mags = indexes.map { magnitudes[$0] }
            let meanMagnitude = AnalyticsMath.mean(mags) ?? 0
            let enmo = AnalyticsMath.mean(mags.map { max(0, $0 - reference) }) ?? 0
            let mad = AnalyticsMath.mean(mags.map { abs($0 - meanMagnitude) }) ?? 0
            let dyn = AnalyticsMath.mean(indexes.map { dynamic[$0] }) ?? 0
            if indexes.count >= minimumSamplesPerMinute { covered += 1 }
            minutes.append(MotionMinute(start: Double(key) * 60, sampleCount: indexes.count, enmo: enmo, mad: mad, meanMagnitude: meanMagnitude, dynamicAmplitude: dyn))
        }
        let result = EnmoResult(gravityReference: reference, minutes: minutes, coverage: minutes.isEmpty ? 0 : Double(covered) / Double(minutes.count))
        return AnalyticsMetric(value: result, confidence: AnalyticsMath.clamp(Double(covered) / 60, 0.3, 0.8), tier: .relative, inputs: ["accel_1hz"], note: "ENMO/MAD plus gravity-removed dynamic amplitude; 1 Hz amplitude only", algorithmVersion: algorithmVersion)
    }

    public static func relativeIntensityBands(_ enmoPerMinute: [Double], sedentaryENMO: Double = 0.01) -> AnalyticsMetric<IntensityBands> {
        let inputs = ["enmo_per_min"]
        guard !enmoPerMinute.isEmpty else { return .absent(tier: .relative, inputs: inputs, note: "no ENMO minutes", algorithmVersion: algorithmVersion) }
        let moving = enmoPerMinute.filter { $0 > sedentaryENMO }
        if moving.count < 4 {
            let labels = enmoPerMinute.map { $0 > sedentaryENMO ? "light" : "sedentary" }
            let counts = labels.reduce(into: ["sedentary": 0, "light": 0, "moderate": 0, "vigorous": 0]) { $0[$1, default: 0] += 1 }
            let value = IntensityBands(lightCut: sedentaryENMO, moderateCut: sedentaryENMO, vigorousCut: sedentaryENMO, labels: labels, minutesInBand: counts)
            return AnalyticsMetric(value: value, confidence: 0.3, tier: .relative, inputs: inputs, note: "too few moving minutes for personal cut-points", algorithmVersion: algorithmVersion)
        }
        let light = AnalyticsMath.percentile(moving, 50)!, moderate = AnalyticsMath.percentile(moving, 75)!, vigorous = AnalyticsMath.percentile(moving, 90)!
        var labels: [String] = [], counts = ["sedentary": 0, "light": 0, "moderate": 0, "vigorous": 0]
        for value in enmoPerMinute {
            let label = value <= sedentaryENMO ? "sedentary" : value >= vigorous ? "vigorous" : value >= moderate ? "moderate" : "light"
            labels.append(label); counts[label, default: 0] += 1
        }
        return AnalyticsMetric(value: IntensityBands(lightCut: light, moderateCut: moderate, vigorousCut: vigorous, labels: labels, minutesInBand: counts), confidence: AnalyticsMath.clamp(Double(moving.count) / 60, 0.3, 0.8), tier: .relative, inputs: inputs, note: "relative within-user 50/75/90th moving percentiles; not METs", algorithmVersion: algorithmVersion)
    }

    public static func estimateHRmax(history: [Double], age: Double?, minimumMeasuredSamples: Int = 600) -> AnalyticsMetric<HRMaxEstimate> {
        _ = history
        _ = minimumMeasuredSamples
        guard let zones = HeartRateZoneSettings().resolved(age: age.map(Int.init)) else {
            return .absent(tier: .estimate, inputs: ["age"], note: "need age for HR zones", algorithmVersion: algorithmVersion)
        }
        return AnalyticsMetric(value: HRMaxEstimate(maxHR: zones.maximum, source: .agePredicted, age: age), confidence: 0.45, tier: .estimate, inputs: ["age"], note: "Tanaka age-predicted HRmax", algorithmVersion: algorithmVersion)
    }

    public static func zones(maxHR: Double, source: HRMaxSource) -> AnalyticsMetric<HeartRateZoneSet> {
        guard maxHR.isFinite, maxHR > 0 else { return .absent(tier: .estimate, inputs: ["max_hr"], note: "invalid HRmax", algorithmVersion: algorithmVersion) }
        let shared = HeartRateZones(maximum: maxHR,
                                    source: source == .measured ? .observed : source == .manual ? .manual : .estimated,
                                    boundaries: HeartRateZoneSettings.defaultBoundaries)
        return zones(shared, source: source)
    }

    public static func zones(_ shared: HeartRateZones, source: HRMaxSource) -> AnalyticsMetric<HeartRateZoneSet> {
        let maxHR = shared.maximum
        let edges = shared.edges.map { Double($0) / 100 }
        let zones = (0..<5).map { HeartRateZone(number: $0 + 1, lowerBPM: shared.bpmBoundary(percent: shared.edges[$0]), upperBPM: shared.bpmBoundary(percent: shared.edges[$0 + 1]), lowerPercent: edges[$0], upperPercent: edges[$0 + 1]) }
        let maximumNote: String = switch source {
        case .measured: "zones use observed HRmax"
        case .agePredicted: "zones use age-predicted HRmax"
        case .manual: "zones use a manually set HRmax"
        }
        let confidence: Double = switch source {
        case .measured: 0.8
        case .agePredicted: 0.5
        case .manual: 0.65
        }
        let note = shared.restingHeartRate == nil ? maximumNote : "\(maximumNote) and resting HR reserve"
        return AnalyticsMetric(value: HeartRateZoneSet(zones: zones, maxHR: maxHR, source: source, restingHR: shared.restingHeartRate),
            confidence: confidence, tier: .estimate,
            inputs: shared.restingHeartRate == nil ? ["max_hr", "max_hr_source"] : ["max_hr", "max_hr_source", "resting_hr"], note: note, algorithmVersion: algorithmVersion)
    }

    public static func timeInZone(_ samples: [ActivityHeartRateSample], zoneSet: HeartRateZoneSet) -> AnalyticsMetric<TimeInHeartRateZones> {
        let sorted = samples.filter { $0.valid && $0.bpm > 0 }.sorted { $0.timestamp < $1.timestamp }
        guard !sorted.isEmpty else { return .absent(tier: .estimate, inputs: ["hr_1hz", "zones"], note: "no valid HR samples for zone time", algorithmVersion: algorithmVersion) }
        let gaps = zip(sorted.dropFirst(), sorted).map { $0.0.timestamp - $0.1.timestamp }.filter { $0 > 0 && $0 <= 300 }
        let cadence = max(1, AnalyticsMath.median(gaps) ?? 1)
        var seconds = [Double](repeating: 0, count: 5), below = 0.0
        for i in sorted.indices {
            let duration = i + 1 < sorted.count ? min(max(0, sorted[i + 1].timestamp - sorted[i].timestamp), cadence) : cadence
            let zone = zoneSet.zoneNumber(for: sorted[i].bpm)
            if zone == 0 { below += duration } else { seconds[zone - 1] += duration }
        }
        return AnalyticsMetric(value: TimeInHeartRateZones(seconds: seconds, belowZone1Seconds: below), confidence: AnalyticsMath.clamp(Double(sorted.count) / 600, 0.3, 0.9), tier: .estimate, inputs: ["hr_1hz", "zones"], note: "duration-aware zone time with gap cap", algorithmVersion: algorithmVersion)
    }

    public static func edwardsTRIMP(zoneMinutes: [Double]) -> AnalyticsMetric<Double> {
        guard zoneMinutes.count == 5 else { return .absent(tier: .estimate, inputs: ["zone_minutes"], note: "Edwards TRIMP needs five zone minutes", algorithmVersion: algorithmVersion) }
        return AnalyticsMetric(value: zip(zoneMinutes, 1...5).reduce(0) { $0 + $1.0 * Double($1.1) }, confidence: 0.6, tier: .estimate, inputs: ["zone_minutes"], note: "Edwards zone-sum TRIMP", algorithmVersion: algorithmVersion)
    }

    public static func banisterTRIMP(hrPerMinute: [Double], restingHR: Double?, maxHR: Double?, sex: ActivitySex = .male) -> AnalyticsMetric<Double> {
        guard let restingHR, let maxHR, maxHR > restingHR, !hrPerMinute.isEmpty else { return .absent(tier: .estimate, inputs: ["hr_per_min", "resting_hr", "max_hr"], note: "Banister TRIMP needs RHR and HRmax", algorithmVersion: algorithmVersion) }
        let reserve = maxHR - restingHR
        var trimp = 0.0
        for bpm in hrPerMinute where bpm > 0 {
            let x = AnalyticsMath.clamp((bpm - restingHR) / reserve, 0, 1)
            let coefficient = sex == .female ? 0.86 : 0.64
            let exponent = sex == .female ? 1.67 : 1.92
            trimp += x * coefficient * exp(exponent * x)
        }
        return AnalyticsMetric(value: trimp, confidence: 0.6, tier: .estimate, inputs: ["hr_per_min", "resting_hr", "max_hr"], note: "Banister exponential TRIMP", algorithmVersion: algorithmVersion)
    }

    public static func strainScore(_ trimp: Double) -> Double {
        guard trimp > 0 else { return 0 }
        return min(21, log(trimp + 1) / log(1.5))
    }

    public static func trimpToStrain(_ trimp: Double, denominator: Double = 7201) -> Double {
        guard trimp > 0 else { return 0 }
        return min(100, max(0, 100 * log(trimp + 1) / log(denominator))).rounded(toPlaces: 2)
    }

    public static func strain(hr: [Double], timestamps: [TimeInterval], restingHR: Double?, maxHR: Double?, source: HRMaxSource, method: String = "edwards", sex: ActivitySex = .male) -> AnalyticsMetric<StrainValue> {
        guard let restingHR, let maxHR, maxHR > restingHR, hr.count == timestamps.count else { return .absent(tier: .estimate, inputs: ["hr_series", "resting_hr", "max_hr"], note: "strain needs HR anchors and aligned timestamps", algorithmVersion: algorithmVersion) }
        let valid = zip(hr, timestamps).filter { $0.0 > 0 && $0.0.isFinite && $0.1.isFinite }
        guard valid.count >= 20 else { return .absent(tier: .estimate, inputs: ["hr_series", "resting_hr", "max_hr"], note: "strain needs at least 20 valid HR samples spanning 10 minutes or 600 valid samples", algorithmVersion: algorithmVersion) }
        let sorted = valid.sorted { $0.1 < $1.1 }
        let wallSpan = (sorted.last?.1 ?? 0) - (sorted.first?.1 ?? 0)
        guard valid.count >= 600 || wallSpan >= 600 else {
            return .absent(tier: .estimate, inputs: ["hr_series", "resting_hr", "max_hr"], note: "sparse strain stream must span at least 10 minutes", algorithmVersion: algorithmVersion)
        }
        let gaps = zip(sorted.dropFirst(), sorted).map { $0.0.1 - $0.1.1 }.filter { $0 > 0 && $0 <= 300 }
        let cadence = max(1, AnalyticsMath.median(gaps) ?? 1)
        var durations = [Double](repeating: cadence / 60, count: sorted.count)
        for i in 0..<(sorted.count - 1) { durations[i] = min(max(0, sorted[i + 1].1 - sorted[i].1), cadence) / 60 }
        let reserve = maxHR - restingHR
        var trimp = 0.0
        for i in sorted.indices {
            let x = AnalyticsMath.clamp((sorted[i].0 - restingHR) / reserve, 0, 1)
            if method.lowercased() == "banister" {
                let coefficient = sex == .female ? 0.86 : 0.64, exponent = sex == .female ? 1.67 : 1.92
                trimp += durations[i] * x * coefficient * exp(exponent * x)
            } else {
                let weight = x >= 0.9 ? 5 : x >= 0.8 ? 4 : x >= 0.7 ? 3 : x >= 0.6 ? 2 : x >= 0.5 ? 1 : 0
                trimp += durations[i] * Double(weight)
            }
        }
        let value = StrainValue(trimp: trimp, strain: trimpToStrain(trimp), method: method, hrMax: maxHR, hrMaxSource: source)
        return AnalyticsMetric(value: value, confidence: AnalyticsMath.clamp(Double(sorted.count) / 600, 0.3, 0.8), tier: .estimate, inputs: ["hr_series", "resting_hr", "max_hr", "max_hr_source"], note: "\(method) TRIMP → 0–100 strain; wrist-HR estimate", algorithmVersion: algorithmVersion)
    }

    public static func trainingLoad(dailyStrain: [Double?]) -> TrainingLoad? {
        TrainingLoad.compute(dailyStrain: dailyStrain)
    }

    public static func personalDynamicFloor(_ values: [Double], quantile: Double = personalDynamicFloorQuantile, minimumMinutes: Int = personalDynamicFloorMinimumMinutes) -> Double? {
        let valid = values.filter { $0.isFinite && $0 >= 0 }
        guard valid.count >= minimumMinutes, let q = AnalyticsMath.percentile(valid, AnalyticsMath.clamp(quantile, 0, 1) * 100), q.isFinite, q > 0 else { return nil }
        return q
    }

    public static func personalDynamicFloorFromDailySummaries(_ values: [Double], minimumDays: Int = 5) -> Double? {
        let valid = values.filter { $0.isFinite && $0 > 0 }
        guard valid.count >= minimumDays, let median = AnalyticsMath.median(valid), median.isFinite, median > 0 else { return nil }
        return median
    }

    /// Reconcile a cumulative device step counter into local calendar days.
    ///
    /// A decrease is a counter reset: the post-reset value is attributed to
    /// the current day and the reset is retained as diagnostic state.  A
    /// positive delta after a gap longer than one day is retained as a
    /// backlog delta and attributed to the day of the reading that delivered
    /// it.  This is deliberately a pure fold; persistence can insert or
    /// replace the resulting day rows idempotently.
    public static func reconcileStepCounter(
        _ readings: [StepCounterSample],
        timeZoneIdentifier: String? = nil,
        backlogGapSeconds: TimeInterval = 24 * 3_600
    ) -> AnalyticsMetric<StepCounterResult> {
        let inputs = ["step_counter", "local_day", "counter_reset", "backlog"]
        let valid = readings.enumerated().filter { _, sample in
            sample.valid && sample.timestamp.isFinite && sample.timestamp >= 0 && sample.cumulativeSteps >= 0
        }.sorted { lhs, rhs in
            if lhs.element.timestamp != rhs.element.timestamp { return lhs.element.timestamp < rhs.element.timestamp }
            return lhs.offset < rhs.offset
        }
        guard !valid.isEmpty else {
            return .absent(tier: .estimate, inputs: inputs, note: "no valid cumulative step-counter readings", algorithmVersion: algorithmVersion)
        }

        var aggregate: [DayIdentity: (steps: Int, reset: Bool, backlog: Int)] = [:]
        var previous: StepCounterSample?
        var resetCount = 0
        var backlogTotal = 0

        for (_, sample) in valid {
            guard let day = SleepAnalytics.dayWindow(containing: sample.timestamp, timeZoneIdentifier: timeZoneIdentifier)?.day else { continue }
            var delta = 0
            var reset = false
            var backlog = 0
            if let previous {
                if sample.timestamp > previous.timestamp {
                    if sample.cumulativeSteps >= previous.cumulativeSteps {
                        delta = sample.cumulativeSteps - previous.cumulativeSteps
                        if sample.timestamp - previous.timestamp > backlogGapSeconds {
                            backlog = delta
                            backlogTotal += delta
                        }
                    } else {
                        // The device has restarted or rolled its counter.
                        // The first post-reset value is the only defensible
                        // count for this interval.
                        delta = sample.cumulativeSteps
                        reset = true
                        resetCount += 1
                    }
                }
            }
            var current = aggregate[day] ?? (steps: 0, reset: false, backlog: 0)
            current.steps += delta
            current.reset = current.reset || reset
            current.backlog += backlog
            aggregate[day] = current
            previous = sample
        }

        let days = aggregate.map { day, values in
            StepCounterDaySummary(day: day, steps: values.steps, resetDetected: values.reset, backlogSteps: values.backlog)
        }.sorted {
            if $0.day.era != $1.day.era { return $0.day.era < $1.day.era }
            if $0.day.year != $1.day.year { return $0.day.year < $1.day.year }
            if $0.day.month != $1.day.month { return $0.day.month < $1.day.month }
            return $0.day.day < $1.day.day
        }
        guard !days.isEmpty else {
            return .absent(tier: .estimate, inputs: inputs, note: "valid counter readings do not resolve to local days", algorithmVersion: algorithmVersion)
        }
        let total = days.reduce(0) { $0 + $1.steps }
        let result = StepCounterResult(days: days, totalSteps: total, resetCount: resetCount, backlogSteps: backlogTotal)
        let confidence = AnalyticsMath.clamp(Double(valid.count) / 8, 0.35, 0.9)
        return AnalyticsMetric(value: result, confidence: confidence, tier: .estimate, inputs: inputs, note: "cumulative step counter reconciled with reset and multi-day backlog diagnostics", algorithmVersion: algorithmVersion)
    }

    /// The day's own contribution to the personal movement floor: the p90 of
    /// its covered minutes. Nil for a day too thin to summarise, so a sparse
    /// day never lowers the floor.
    public static func dailyDynamicAmplitudeSummary(
        _ motion: [MotionMinute],
        quantile: Double = personalDynamicFloorQuantile,
        minimumSamplesPerMinute: Int = 30,
        minimumCoveredMinutes: Int = 60
    ) -> Double? {
        let values = motion
            .filter { $0.sampleCount >= minimumSamplesPerMinute && $0.dynamicAmplitude.isFinite && $0.dynamicAmplitude >= 0 }
            .map(\.dynamicAmplitude)
        guard values.count >= minimumCoveredMinutes,
              let q = AnalyticsMath.percentile(values, AnalyticsMath.clamp(quantile, 0, 1) * 100),
              q.isFinite, q > 0 else { return nil }
        return q
    }

    public static func dailyStepEstimate(_ motion: [MotionMinute], personalDynamicFloor floor: Double?, hrPerMinute: [Double]? = nil, restingHR: Double? = nil, calibration: StepCalibration? = nil, hrMarginBPM: Double = 8, minimumSamplesPerMinute: Int = 30, minimumBoutMinutes: Int = 3, vigorousCeilingRatio: Double = 3, pooledMinutesAvailable: Int = 0, baselineRequirement: Int = personalDynamicFloorMinimumMinutes) -> AnalyticsMetric<DailyStepEstimate> {
        let inputs = ["dyn_amp_per_min", "hr_per_min", "personal_dyn_floor"]
        guard !motion.isEmpty else { return .absent(tier: .estimate, inputs: inputs, note: "no motion minutes", algorithmVersion: algorithmVersion) }
        guard let floor, floor.isFinite, floor > 0 else { return .absent(tier: .estimate, inputs: inputs, note: "need_baseline:have=\(pooledMinutesAvailable),need=\(baselineRequirement)", algorithmVersion: algorithmVersion) }
        let covered = motion.indices.filter { motion[$0].sampleCount >= minimumSamplesPerMinute }
        guard covered.count >= 4 else { return .absent(tier: .estimate, inputs: inputs, note: "too few covered minutes to estimate activity", algorithmVersion: algorithmVersion) }
        let useHR = hrPerMinute?.count == motion.count
        var rest = restingHR ?? 0
        if useHR, rest == 0 { rest = AnalyticsMath.percentile(hrPerMinute!.filter { $0 > 0 }, 10) ?? 0 }
        let ceiling = floor * max(1, vigorousCeilingRatio)
        var gate = [Bool](repeating: false, count: motion.count)
        for index in covered {
            let value = motion[index].dynamicAmplitude
            guard value > floor && value <= ceiling else { continue }
            if useHR, rest > 0, hrPerMinute![index] > 0, hrPerMinute![index] < rest + hrMarginBPM { continue }
            gate[index] = true
        }
        var active = 0, index = 0
        while index < motion.count {
            guard gate[index] else { index += 1; continue }
            let start = index
            while index < motion.count && gate[index] {
                if index > start, motion[index].start - motion[index - 1].start > 90 { break }
                index += 1
            }
            if index - start >= minimumBoutMinutes { active += index - start }
        }
        let measured = calibration.flatMap { $0.count >= 3 && $0.cadenceSPM >= 60 && $0.cadenceSPM <= 180 ? $0.cadenceSPM : nil }
        let calibrated = measured != nil
        let low = calibrated ? AnalyticsMath.clamp(measured! * 0.9, 60, 180) : 100
        let high = calibrated ? AnalyticsMath.clamp(measured! * 1.1, 60, 180) : 130
        let value = DailyStepEstimate(activeMinutes: active, stepsLow: Int((Double(active) * low).rounded()), stepsHigh: Int((Double(active) * high).rounded()), stepsMidpoint: Int((Double(active) * (low + high) / 2).rounded()), cadenceLowSPM: low, cadenceHighSPM: high, dynamicFloorG: floor, coverage: Double(covered.count) / Double(motion.count), calibrated: calibrated)
        let coverage = Double(covered.count) / Double(motion.count)
        let confidence = AnalyticsMath.clamp(
            (calibrated ? 0.45 : 0.30) * AnalyticsMath.clamp(coverage / 0.6, 0.3, 1),
            0.1,
            0.7
        )
        return AnalyticsMetric(value: value, confidence: confidence, tier: .estimate, inputs: inputs, note: calibrated ? "ESTIMATE: active minutes from gravity-removed 1 Hz amplitude vs personal movement floor; measured cadence narrows the step range" : "ESTIMATE: active minutes from gravity-removed 1 Hz amplitude vs personal movement floor; free-living cadence band is not exact at 1 Hz", algorithmVersion: algorithmVersion)
    }

    public static func pedometer(_ signal: [Double]) -> Int {
        guard signal.count >= 33 else { return 0 }
        let filter = 8, half = 16, sensitivity = 0.10, timeout = 120, confirmation = 8
        var lowPass = [Double](repeating: 0, count: signal.count), accumulator = 0.0
        for i in signal.indices { accumulator += signal[i]; if i >= filter { accumulator -= signal[i - filter] }; lowPass[i] = accumulator / Double(min(i + 1, filter)) }
        var candidateIndices: [Int] = [], candidateMax: [Bool] = [], candidateValues: [Double] = []
        for i in half..<(signal.count - half) {
            var isMax = true, isMin = true
            for j in (i - half)...(i + half) { if lowPass[j] > lowPass[i] { isMax = false }; if lowPass[j] < lowPass[i] { isMin = false }; if !isMax && !isMin { break } }
            if isMax { candidateIndices.append(i); candidateMax.append(true); candidateValues.append(lowPass[i]) } else if isMin { candidateIndices.append(i); candidateMax.append(false); candidateValues.append(lowPass[i]) }
        }
        var dynamic = signal.reduce(0, +) / Double(signal.count)
        var thresholdHistory: [Double] = []
        var steps = 0, possible = 0, regulation = false, stateMax = true, currentMax = 0.0, currentMaxIndex = -1
        for k in candidateIndices.indices {
            let index = candidateIndices[k], isMax = candidateMax[k], value = candidateValues[k]
            if stateMax { if isMax { currentMax = value; currentMaxIndex = index; stateMax = false }; continue }
            if isMax { if value > currentMax { currentMax = value; currentMaxIndex = index }; continue }
            if index - currentMaxIndex > timeout { stateMax = true; possible = 0; regulation = false; continue }
            if currentMax > dynamic + sensitivity / 2 && value < dynamic - sensitivity / 2 {
                if currentMax - value > sensitivity {
                    thresholdHistory.append((currentMax + value) / 2)
                    if thresholdHistory.count > 4 { thresholdHistory.removeFirst() }
                    dynamic = AnalyticsMath.mean(thresholdHistory) ?? dynamic
                }
                possible += 1
                if regulation { steps += 1 } else if possible >= confirmation { steps += possible; regulation = true }
            } else { possible = 0; regulation = false }
            stateMax = true
        }
        return steps
    }

    /// Apply the pinned 1.11 gain to independent foreground minute buffers.
    /// The gain belongs only at this aggregate boundary; a single 1 Hz
    /// minute cannot resolve individual gait cycles honestly.
    public static func calcSteps(_ minuteSignals: [[Double]]) -> Int {
        let raw = minuteSignals.reduce(0) { $0 + pedometer($1) }
        return Int((Double(raw) * 1.11).rounded())
    }

    public static func livePedometer(x: [Double], y: [Double], z: [Double], sampleRateHz: Double = 100) -> PedometerResult {
        let n = min(x.count, min(y.count, z.count))
        guard n >= 33, sampleRateHz > 0 else { return PedometerResult(steps: 0, durationSeconds: 0, cadenceSPM: 0, peakToPeakG: 0, confidence: 0) }
        let magnitude = (0..<n).map { index -> Double in
            let xSquared = x[index] * x[index]
            let ySquared = y[index] * y[index]
            let zSquared = z[index] * z[index]
            return sqrt(xSquared + ySquared + zSquared)
        }
        let steps = pedometer(magnitude), duration = Double(n) / sampleRateHz
        guard steps > 0 else { return PedometerResult(steps: 0, durationSeconds: duration, cadenceSPM: 0, peakToPeakG: 0, confidence: 0) }
        let range = (magnitude.max() ?? 0) - (magnitude.min() ?? 0)
        let cadence = duration > 0 ? Double(steps) / duration * 60 : 0
        return PedometerResult(steps: steps, durationSeconds: duration, cadenceSPM: cadence, peakToPeakG: range, confidence: cadence >= 60 && cadence <= 200 ? 0.85 : 0.5)
    }

    /// Fold one credible foreground walking bout into the running cadence
    /// calibration.  Invalid/fidgeting observations return the prior exactly.
    public static func calibrateCadence(
        prior: StepCalibration?,
        live: PedometerResult,
        concurrentENMOG: Double,
        minimumConfidence: Double = 0.5,
        minimumDurationSeconds: Double = 20
    ) -> StepCalibration? {
        let cadence = live.cadenceSPM
        guard live.confidence >= minimumConfidence,
              live.durationSeconds >= minimumDurationSeconds,
              cadence >= 70, cadence <= 140,
              concurrentENMOG > 0, concurrentENMOG.isFinite else { return prior }
        guard let prior else {
            return StepCalibration(cadenceSPM: cadence, referenceENMO: concurrentENMOG, count: 1)
        }
        let weight = min(max(prior.count, 0), 50)
        let count = weight + 1
        return StepCalibration(
            cadenceSPM: (prior.cadenceSPM * Double(weight) + cadence) / Double(count),
            referenceENMO: (prior.referenceENMO * Double(weight) + concurrentENMOG) / Double(count),
            count: min(prior.count + 1, 200)
        )
    }

    public static func branchedEnergyFusion(timestamps: [TimeInterval], enmo: [Double], heartRate: [Double], restingHR: Double? = nil, maxHR: Double? = nil, accelSaturationG: Double = 0.5, accelHigh: Double = 0.15, hrHigh: Double = 0.4) -> AnalyticsMetric<EnergyFusion> {
        guard !timestamps.isEmpty, timestamps.count == enmo.count, enmo.count == heartRate.count else { return .absent(tier: .relative, inputs: ["enmo_1hz", "hr_1hz"], note: "HR/ENMO/timestamps must be equal length", algorithmVersion: algorithmVersion) }
        let calibrated = restingHR != nil && maxHR != nil && maxHR! > restingHR!
        var points: [EnergyPoint] = [], load = 0.0, validHR = 0
        for i in timestamps.indices {
            let accel = AnalyticsMath.clamp(enmo[i] / max(accelSaturationG, 0.001), 0, 1)
            let hasHR = heartRate[i] > 0
            if hasHR { validHR += 1 }
            let hr = hasHR ? (calibrated ? AnalyticsMath.clamp((heartRate[i] - restingHR!) / (maxHR! - restingHR!), 0, 1) : AnalyticsMath.clamp((heartRate[i] - 50) / 130, 0, 1)) : 0
            let highA = accel >= accelHigh, highH = hasHR && hr >= hrHigh
            let branch: String, weight: Double
            if !hasHR { branch = "accel_only"; weight = 1 } else if !highA && !highH { branch = "rest"; weight = 0.85 } else if !highA && highH { branch = "nonlocomotor"; weight = 0.15 } else if highA && !highH { branch = "transient"; weight = 0.7 } else { branch = "locomotor"; weight = 0.4 }
            var value = weight * accel + (1 - weight) * hr
            if branch == "transient" { value *= 0.7 }
            value = AnalyticsMath.clamp(value, 0, 1); load += value
            points.append(EnergyPoint(timestamp: timestamps[i], index: value, accelComponent: accel, heartRateComponent: hr, accelerationWeight: weight, branch: branch))
        }
        let confidence = AnalyticsMath.clamp(Double(validHR) / Double(timestamps.count) * (calibrated ? 0.7 : 0.5), 0, 0.7)
        return AnalyticsMetric(value: EnergyFusion(points: points, relativeLoad: load, calibrated: calibrated), confidence: confidence, tier: calibrated ? .estimate : .relative, inputs: ["enmo_1hz", "hr_1hz", "resting_hr?", "max_hr?"], note: calibrated ? "Brage fusion with %HR reserve; estimate, not kcal" : "Brage fusion; relative energy index", algorithmVersion: algorithmVersion)
    }

    public static func derive(_ input: ActivityInputSnapshot) async throws -> ActivityDerivation {
        try Task.checkCancellation()
        let motion = enmoSeries(input.acceleration)
        try Task.checkCancellation()
        let settings = input.zoneSettings ?? HeartRateZoneSettings(manualMaximum: input.measuredHRMax)
        let resolvedZones = settings.resolved(age: input.age.map(Int.init), restingNights: input.restingHR.map { [$0] } ?? [])
        let hrMax: AnalyticsMetric<HRMaxEstimate> = resolvedZones.map { resolved in
            let source: HRMaxSource = if input.zoneSettings == nil, input.measuredHRMax != nil {
                .measured
            } else {
                switch resolved.source {
                case .estimated: .agePredicted
                case .observed: .measured
                case .manual: .manual
                }
            }
            let confidence: Double = switch source {
            case .measured: 0.85
            case .agePredicted: 0.45
            case .manual: 0.65
            }
            return AnalyticsMetric(value: HRMaxEstimate(maxHR: resolved.maximum,
                source: source, age: input.age),
                confidence: confidence, tier: .estimate,
                inputs: ["zone_settings", "age"], note: "shared heart-rate zone settings", algorithmVersion: algorithmVersion)
        } ?? .absent(tier: .estimate, inputs: ["age", "zone_settings"], note: "no maximum heart rate", algorithmVersion: algorithmVersion)
        let zoneMetric: AnalyticsMetric<TimeInHeartRateZones>
        if let max = hrMax.value {
            let zoneSetMetric = ActivityAnalytics.zones(resolvedZones!, source: max.source ?? .agePredicted)
            zoneMetric = zoneSetMetric.value.map { ActivityAnalytics.timeInZone(input.heartRate, zoneSet: $0) } ?? .absent(tier: .estimate, inputs: ["hr_1hz", "zones"], note: "invalid HR zones", algorithmVersion: algorithmVersion)
        } else {
            zoneMetric = .absent(tier: .estimate, inputs: ["hr_1hz", "zones"], note: "no HRmax/zones", algorithmVersion: algorithmVersion)
        }
        let strainMetric: AnalyticsMetric<StrainValue>
        let strainAnchor = hrMax.value.map { (value: $0.maxHR, source: $0.source ?? .agePredicted) }
        if let strainAnchor {
            strainMetric = strain(hr: input.heartRate.map(\.bpm), timestamps: input.heartRate.map(\.timestamp), restingHR: input.restingHR, maxHR: strainAnchor.value, source: strainAnchor.source, method: "banister", sex: input.sex)
        } else {
            strainMetric = .absent(tier: .estimate, inputs: ["hr_series", "max_hr"], note: "no HRmax", algorithmVersion: algorithmVersion)
        }
        try Task.checkCancellation()
        let motionValue = motion.value
        // The restingHR + 8 bpm gate is the only thing separating an
        // ambulatory minute from a minute of arm movement in a chair. It
        // cannot run without a per-minute HR array aligned to the motion
        // minutes, so build one on the canonical minute key.
        let stepHRPerMinute = motionValue.map { result -> [Double] in
            var buckets: [Int: [Double]] = [:]
            for sample in input.heartRate where sample.valid && sample.bpm > 0 && sample.bpm.isFinite && sample.timestamp.isFinite {
                buckets[Int(floor(sample.timestamp / 60)), default: []].append(sample.bpm)
            }
            return result.minutes.map { AnalyticsMath.mean(buckets[Int(floor($0.start / 60))] ?? []) ?? 0 }
        }
        let stepMetric = motionValue.map { dailyStepEstimate($0.minutes, personalDynamicFloor: input.personalDynamicFloor, hrPerMinute: stepHRPerMinute, restingHR: input.restingHR, calibration: input.stepCalibration, pooledMinutesAvailable: input.pooledMotionMinutes, baselineRequirement: input.personalDynamicFloorRequirement) } ?? .absent(tier: .estimate, inputs: ["dyn_amp_per_min"], note: "no motion", algorithmVersion: algorithmVersion)
        // The fusion API remains for Dart parity, but its relative index has
        // no calorie calibration. Production uses WorkoutAnalytics.dailyEnergy.
        let energy: AnalyticsMetric<EnergyFusion> = .absent(tier: .relative, inputs: [],
            note: "Relative energy fusion is not used for calorie estimates", algorithmVersion: algorithmVersion)
        let load: AnalyticsMetric<LoadState> = .absent(tier: .estimate, inputs: ["daily_strain"], note: "Training load is derived from stored daily strain history", algorithmVersion: TrainingLoad.algorithmVersion)
        let counter = input.stepCounterReadings.isEmpty ? nil : reconcileStepCounter(input.stepCounterReadings, timeZoneIdentifier: input.timeZoneIdentifier)
        return ActivityDerivation(zones: zoneMetric, strain: strainMetric, motion: motion, steps: stepMetric, energy: energy, load: load, algorithmVersion: "loopr.activity-derived.2", stepCounter: counter)
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let factor = pow(10, Double(places)); return (self * factor).rounded() / factor
    }
}

public func enmoSeries(_ samples: [ActivityAccelerationSample], gravityReference: Double? = nil, minimumSamplesPerMinute: Int = 30, gravityWindowSeconds: Double = 15) -> AnalyticsMetric<EnmoResult> {
    ActivityAnalytics.enmoSeries(samples, gravityReference: gravityReference, minimumSamplesPerMinute: minimumSamplesPerMinute, gravityWindowSeconds: gravityWindowSeconds)
}

public func dailyStepEstimate(_ motion: [MotionMinute], personalDynamicFloor: Double?, hrPerMinute: [Double]? = nil, restingHR: Double? = nil, calibration: StepCalibration? = nil, pooledMinutesAvailable: Int = 0) -> AnalyticsMetric<DailyStepEstimate> {
    ActivityAnalytics.dailyStepEstimate(motion, personalDynamicFloor: personalDynamicFloor, hrPerMinute: hrPerMinute, restingHR: restingHR, calibration: calibration, pooledMinutesAvailable: pooledMinutesAvailable)
}

public func classifyPosition(pitchDeg: Double, rollDeg: Double) -> ActivityPosition {
    ActivityAnalytics.classifyPosition(pitchDeg: pitchDeg, rollDeg: rollDeg)
}

public func staticTilt(_ epoch: [ActivityAccelerationSample], maxJitterG: Double = 0.05, minSamples: Int = 3) -> AnalyticsMetric<Tilt> {
    ActivityAnalytics.staticTilt(epoch, maxJitterG: maxJitterG, minSamples: minSamples)
}

public func positionSeries(_ samples: [ActivityAccelerationSample], epochSeconds: Int = 30, maxJitterG: Double = 0.05) -> [Tilt] {
    ActivityAnalytics.positionSeries(samples, epochSeconds: epochSeconds, maxJitterG: maxJitterG)
}

public func calibrateCadence(prior: StepCalibration?, live: PedometerResult, concurrentENMOG: Double, minimumConfidence: Double = 0.5, minimumDurationSeconds: Double = 20) -> StepCalibration? {
    ActivityAnalytics.calibrateCadence(prior: prior, live: live, concurrentENMOG: concurrentENMOG, minimumConfidence: minimumConfidence, minimumDurationSeconds: minimumDurationSeconds)
}

public func reconcileStepCounter(_ readings: [StepCounterSample], timeZoneIdentifier: String? = nil, backlogGapSeconds: TimeInterval = 24 * 3_600) -> AnalyticsMetric<StepCounterResult> {
    ActivityAnalytics.reconcileStepCounter(readings, timeZoneIdentifier: timeZoneIdentifier, backlogGapSeconds: backlogGapSeconds)
}
