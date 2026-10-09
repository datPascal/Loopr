import Foundation
import DomainKit

public enum SleepAlgorithm {
    public static let version = "loopr.sleep.2"
}

public struct SleepAccelerationSample: Codable, Sendable, Equatable {
    public let timestamp: TimeInterval
    public let x: Double
    public let y: Double
    public let z: Double
    public let valid: Bool

    public init(timestamp: TimeInterval, x: Double, y: Double, z: Double, valid: Bool = true) {
        self.timestamp = timestamp; self.x = x; self.y = y; self.z = z; self.valid = valid
    }
}

public struct SleepHeartRateSample: Codable, Sendable, Equatable {
    public let timestamp: TimeInterval
    public let bpm: Double
    public let valid: Bool

    public init(timestamp: TimeInterval, bpm: Double, valid: Bool = true) {
        self.timestamp = timestamp; self.bpm = bpm; self.valid = valid
    }
}

public struct SleepRRInterval: Codable, Sendable, Equatable {
    public let timestamp: TimeInterval
    public let milliseconds: Double

    public init(timestamp: TimeInterval, milliseconds: Double) {
        self.timestamp = timestamp; self.milliseconds = milliseconds
    }
}

public struct SleepForcedWindow: Codable, Sendable, Equatable {
    public let onset: TimeInterval
    public let offset: TimeInterval

    public init(onset: TimeInterval, offset: TimeInterval) {
        self.onset = onset; self.offset = offset
    }
}

public struct SleepInputSnapshot: Codable, Sendable, Equatable {
    public let acceleration: [SleepAccelerationSample]
    public let heartRate: [SleepHeartRateSample]
    public let rr: [SleepRRInterval]
    public let daytimeHeartRate: [Double]
    public let forcedWindow: SleepForcedWindow?
    public let habitualMidsleepSecond: Int?
    public let timeZoneIdentifier: String?
    public let fixedTimeZoneOffsetSeconds: Int?
    public let mainSleepWakeDay: DayIdentity?

    public init(
        acceleration: [SleepAccelerationSample],
        heartRate: [SleepHeartRateSample] = [],
        rr: [SleepRRInterval] = [],
        daytimeHeartRate: [Double] = [],
        forcedWindow: SleepForcedWindow? = nil,
        habitualMidsleepSecond: Int? = nil,
        timeZoneIdentifier: String? = nil,
        fixedTimeZoneOffsetSeconds: Int? = nil,
        mainSleepWakeDay: DayIdentity? = nil
    ) {
        self.acceleration = acceleration; self.heartRate = heartRate; self.rr = rr
        self.daytimeHeartRate = daytimeHeartRate; self.forcedWindow = forcedWindow
        self.habitualMidsleepSecond = habitualMidsleepSecond
        self.timeZoneIdentifier = timeZoneIdentifier
        self.fixedTimeZoneOffsetSeconds = fixedTimeZoneOffsetSeconds
        self.mainSleepWakeDay = mainSleepWakeDay
    }
}

public struct SleepWindow: Codable, Sendable, Equatable {
    public let onsetIndex: Int
    public let offsetIndex: Int
    public let onset: TimeInterval
    public let offset: TimeInterval
    public let immobile: [Bool]
    public let immobileUnknown: [Bool]
    public let zAngleDegrees: [Double]
    public let sptSeconds: Int

    public init(
        onsetIndex: Int,
        offsetIndex: Int,
        onset: TimeInterval,
        offset: TimeInterval,
        immobile: [Bool],
        immobileUnknown: [Bool] = [],
        zAngleDegrees: [Double] = [],
        sptSeconds: Int
    ) {
        self.onsetIndex = onsetIndex; self.offsetIndex = offsetIndex
        self.onset = onset; self.offset = offset; self.immobile = immobile
        self.immobileUnknown = immobileUnknown; self.zAngleDegrees = zAngleDegrees
        self.sptSeconds = sptSeconds
    }

    public var unresolvedTailSeconds: Int { immobileUnknown.filter { $0 }.count }
}

public enum SleepStage: String, Codable, Sendable, Equatable, CaseIterable {
    case wake
    case light
    case deep
    case rem
    case nrem

    public var isAsleep: Bool { self != .wake }
    public var isNREM: Bool { self == .light || self == .deep || self == .nrem }
}

public struct SleepStageSegment: Codable, Sendable, Equatable {
    public let start: TimeInterval
    public let end: TimeInterval
    public let stage: SleepStage

    public init(start: TimeInterval, end: TimeInterval, stage: SleepStage) {
        self.start = start; self.end = end; self.stage = stage
    }
}

public struct SleepSegmentation: Codable, Sendable, Equatable {
    public let window: SleepWindow?
    public let stages: [SleepStage]
    public let stages4: [SleepStage]
    public let totalSleepSeconds: Int?
    public let wasoSeconds: Int?
    public let inBedSeconds: Int?
    public let efficiencyPercent: Double?
    public let nremSeconds: Int?
    public let lightSeconds: Int?
    public let deepSeconds: Int?
    public let remSeconds: Int?
    public let wakeSeconds: Int?
    public let isPartial: Bool
    public let confidence: Double
    /// Every other qualifying session of the same record, ordered by onset.
    /// The main sleep is never repeated here.
    public let naps: [SleepWindow]
    /// True when the window came from the heart-rate-led fallback rather than
    /// from gravity. Present so callers can badge it honestly.
    public let isHeartRateLed: Bool
    public let algorithmVersion: String

    public init(
        window: SleepWindow?,
        stages: [SleepStage],
        stages4: [SleepStage] = [],
        totalSleepSeconds: Int?,
        wasoSeconds: Int?,
        inBedSeconds: Int?,
        efficiencyPercent: Double?,
        nremSeconds: Int?,
        lightSeconds: Int?,
        deepSeconds: Int?,
        remSeconds: Int?,
        wakeSeconds: Int?,
        isPartial: Bool = false,
        confidence: Double,
        naps: [SleepWindow] = [],
        isHeartRateLed: Bool = false,
        algorithmVersion: String = SleepAlgorithm.version
    ) {
        self.window = window; self.stages = stages; self.stages4 = stages4
        self.totalSleepSeconds = totalSleepSeconds; self.wasoSeconds = wasoSeconds
        self.inBedSeconds = inBedSeconds; self.efficiencyPercent = efficiencyPercent
        self.nremSeconds = nremSeconds; self.lightSeconds = lightSeconds
        self.deepSeconds = deepSeconds; self.remSeconds = remSeconds
        self.wakeSeconds = wakeSeconds; self.isPartial = isPartial
        self.confidence = confidence; self.naps = naps
        self.isHeartRateLed = isHeartRateLed
        self.algorithmVersion = algorithmVersion
    }

    private enum CodingKeys: String, CodingKey {
        case window, stages, stages4, totalSleepSeconds, wasoSeconds, inBedSeconds
        case efficiencyPercent, nremSeconds, lightSeconds, deepSeconds, remSeconds
        case wakeSeconds, isPartial, confidence, naps, isHeartRateLed, algorithmVersion
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        window = try container.decodeIfPresent(SleepWindow.self, forKey: .window)
        stages = try container.decode([SleepStage].self, forKey: .stages)
        stages4 = try container.decodeIfPresent([SleepStage].self, forKey: .stages4) ?? []
        totalSleepSeconds = try container.decodeIfPresent(Int.self, forKey: .totalSleepSeconds)
        wasoSeconds = try container.decodeIfPresent(Int.self, forKey: .wasoSeconds)
        inBedSeconds = try container.decodeIfPresent(Int.self, forKey: .inBedSeconds)
        efficiencyPercent = try container.decodeIfPresent(Double.self, forKey: .efficiencyPercent)
        nremSeconds = try container.decodeIfPresent(Int.self, forKey: .nremSeconds)
        lightSeconds = try container.decodeIfPresent(Int.self, forKey: .lightSeconds)
        deepSeconds = try container.decodeIfPresent(Int.self, forKey: .deepSeconds)
        remSeconds = try container.decodeIfPresent(Int.self, forKey: .remSeconds)
        wakeSeconds = try container.decodeIfPresent(Int.self, forKey: .wakeSeconds)
        isPartial = try container.decodeIfPresent(Bool.self, forKey: .isPartial) ?? false
        confidence = try container.decode(Double.self, forKey: .confidence)
        naps = try container.decodeIfPresent([SleepWindow].self, forKey: .naps) ?? []
        isHeartRateLed = try container.decodeIfPresent(Bool.self, forKey: .isHeartRateLed) ?? false
        algorithmVersion = try container.decodeIfPresent(String.self, forKey: .algorithmVersion) ?? SleepAlgorithm.version
    }

    public static let absent = SleepSegmentation(
        window: nil, stages: [], stages4: [], totalSleepSeconds: nil,
        wasoSeconds: nil, inBedSeconds: nil, efficiencyPercent: nil,
        nremSeconds: nil, lightSeconds: nil, deepSeconds: nil, remSeconds: nil,
        wakeSeconds: nil, isPartial: false, confidence: 0
    )

    public var present: Bool { window != nil }

    public func replacingNaps(_ naps: [SleepWindow]) -> SleepSegmentation {
        SleepSegmentation(
            window: window, stages: stages, stages4: stages4,
            totalSleepSeconds: totalSleepSeconds, wasoSeconds: wasoSeconds,
            inBedSeconds: inBedSeconds, efficiencyPercent: efficiencyPercent,
            nremSeconds: nremSeconds, lightSeconds: lightSeconds,
            deepSeconds: deepSeconds, remSeconds: remSeconds,
            wakeSeconds: wakeSeconds, isPartial: isPartial, confidence: confidence,
            naps: naps, isHeartRateLed: isHeartRateLed, algorithmVersion: algorithmVersion
        )
    }
}

public struct SleepAccounting: Codable, Sendable, Equatable {
    public let onsetIndex: Int
    public let offsetIndex: Int
    public let totalSleepSeconds: Int
    public let wasoSeconds: Int
    public let sleepPeriodSeconds: Int
    public let efficiencyPercent: Double
    public let cycles: Int
    public let algorithmVersion: String

    public init(
        onsetIndex: Int, offsetIndex: Int, totalSleepSeconds: Int,
        wasoSeconds: Int, sleepPeriodSeconds: Int, efficiencyPercent: Double,
        cycles: Int, algorithmVersion: String = SleepAlgorithm.version
    ) {
        self.onsetIndex = onsetIndex; self.offsetIndex = offsetIndex
        self.totalSleepSeconds = totalSleepSeconds; self.wasoSeconds = wasoSeconds
        self.sleepPeriodSeconds = sleepPeriodSeconds; self.efficiencyPercent = efficiencyPercent
        self.cycles = cycles; self.algorithmVersion = algorithmVersion
    }
}

public struct SleepCycle: Codable, Sendable, Equatable {
    public let startMinute: Int
    public let endMinute: Int
    public let lengthMinute: Int
    public init(startMinute: Int, endMinute: Int, lengthMinute: Int) {
        self.startMinute = startMinute; self.endMinute = endMinute; self.lengthMinute = lengthMinute
    }
}

/// A serializable point in the minute-resolution cycle trace.
///
/// This is deliberately a named value rather than a tuple.  Named tuples are
/// not Codable/Sendable values across all Swift 6 toolchains, while cycle
/// traces are part of the persisted analytics contract.
public struct SleepCycleSeriesPoint: Codable, Sendable, Equatable {
    public let timestamp: TimeInterval
    public let z: Double

    public init(timestamp: TimeInterval, z: Double) {
        self.timestamp = timestamp
        self.z = z
    }
}

public struct SleepCyclesResult: Codable, Sendable, Equatable {
    public let cycles: [SleepCycle]
    public let meanDurationMinutes: Double?
    public let series: [SleepCycleSeriesPoint]
    public let algorithmVersion: String

    public init(
        cycles: [SleepCycle], meanDurationMinutes: Double?,
        series: [SleepCycleSeriesPoint] = [],
        algorithmVersion: String = SleepAlgorithm.version
    ) {
        self.cycles = cycles; self.meanDurationMinutes = meanDurationMinutes
        self.series = series; self.algorithmVersion = algorithmVersion
    }
}

public struct HypnogramMetrics: Codable, Sendable, Equatable {
    public let timeInBedSeconds: Int
    public let totalSleepSeconds: Int
    public let sleepPeriodSeconds: Int
    public let sleepOnsetLatencySeconds: Int
    public let remLatencySeconds: Double?
    public let wasoSeconds: Int
    public let efficiency: Double
    public let disturbances: Int
    public let deepMinutes: Double
    public let remMinutes: Double
    public let lightMinutes: Double
    public let deepPercent: Double
    public let remPercent: Double
    public let lightPercent: Double
    public let algorithmVersion: String
}

public struct SleepDebt: Codable, Sendable, Equatable {
    public let optimalSleepHours: Double?
    public let habitualSleepHours: Double
    public let debtHours: Double?
    public let hasFreeNight: Bool
    public let algorithmVersion: String
}

public struct SleepRegularity: Codable, Sendable, Equatable {
    public let score: Double
    public let epochsPerDay: Int
    public let comparedPairs: Int
    public let band: String
    public let algorithmVersion: String
}

public struct SleepUserProfile: Codable, Sendable, Equatable {
    public let nights: Int
    public let hrFloorP5: Double?
    public let hrFloorP25: Double?
    public let hrSleepMedian: Double?
    public let hrArousal: Double?
    public let rmssdMedian: Double?
    public let rmssdMAD: Double?
    public let updatedAt: TimeInterval?

    public init(
        nights: Int = 0, hrFloorP5: Double? = nil, hrFloorP25: Double? = nil,
        hrSleepMedian: Double? = nil, hrArousal: Double? = nil,
        rmssdMedian: Double? = nil, rmssdMAD: Double? = nil,
        updatedAt: TimeInterval? = nil
    ) {
        self.nights = nights; self.hrFloorP5 = hrFloorP5; self.hrFloorP25 = hrFloorP25
        self.hrSleepMedian = hrSleepMedian; self.hrArousal = hrArousal
        self.rmssdMedian = rmssdMedian; self.rmssdMAD = rmssdMAD; self.updatedAt = updatedAt
    }

    public var personalWeight: Double { AnalyticsMath.clamp(Double(nights) / 28, 0, 0.5) }
}

/// A local-calendar day window.  Day identity is computed from the supplied
/// timezone at the instant being assigned; callers must not use a fixed 24h
/// offset, because DST transitions make those windows 23 or 25 hours long.
public struct SleepDayWindow: Codable, Sendable, Equatable {
    public let day: DayIdentity
    public let start: TimeInterval
    public let end: TimeInterval
    public let lengthSeconds: Int

    public init(day: DayIdentity, start: TimeInterval, end: TimeInterval) {
        self.day = day
        self.start = start
        self.end = end
        self.lengthSeconds = max(0, Int((end - start).rounded()))
    }
}

public struct SleepNightObservation: Codable, Sendable, Equatable {
    public let epochs: Int
    public let hrFloorP5: Double?
    public let hrFloorP25: Double?
    public let hrSleepMedian: Double?
    public let hrArousal: Double?
    public let rmssdMedian: Double?
    public let rmssdMAD: Double?
    public init(
        epochs: Int, hrFloorP5: Double? = nil, hrFloorP25: Double? = nil,
        hrSleepMedian: Double? = nil, hrArousal: Double? = nil,
        rmssdMedian: Double? = nil, rmssdMAD: Double? = nil
    ) {
        self.epochs = epochs; self.hrFloorP5 = hrFloorP5; self.hrFloorP25 = hrFloorP25
        self.hrSleepMedian = hrSleepMedian; self.hrArousal = hrArousal
        self.rmssdMedian = rmssdMedian; self.rmssdMAD = rmssdMAD
    }
}

public struct SleepDerivation: Codable, Sendable, Equatable {
    public let segmentation: SleepSegmentation
    public let accounting: SleepAccounting?
    public let cycles: SleepCyclesResult?
    public let hypnogram: HypnogramMetrics?
    public let algorithmVersion: String
}

public protocol SleepAnalyticsRepository: Sendable {
    func sleep(for day: DayIdentity) async throws -> SleepDerivation?
}

public enum SleepAnalytics {
    public static let algorithmVersion = SleepAlgorithm.version

    public static func zAngle(x: Double, y: Double, z: Double) -> Double {
        atan2(z, sqrt(x * x + y * y)) * 180 / .pi
    }

    public static func vanHeesWindow(
        _ samples: [SleepAccelerationSample],
        angleThresholdDegrees: Double = 5,
        sustainedMinutes: Int = 5,
        bridgeMinutes: Int = 30,
        smoothSeconds: Int = 5
    ) -> AnalyticsMetric<SleepWindow> {
        let valid = samples.filter(\.valid).sorted { $0.timestamp < $1.timestamp }
        let win = max(1, sustainedMinutes * 60)
        let inputs = ["accel_1hz"]
        guard valid.count >= win else {
            return .absent(tier: .high, inputs: inputs, note: "too few accel samples for a sustained-inactivity block", algorithmVersion: algorithmVersion)
        }
        let raw = valid.map { zAngle(x: $0.x, y: $0.y, z: $0.z) }
        let half = max(0, smoothSeconds / 2)
        var angle = [Double](repeating: 0, count: raw.count)
        for i in raw.indices {
            let lo = max(0, i - half), hi = min(raw.count - 1, i + half)
            angle[i] = AnalyticsMath.median(Array(raw[lo...hi])) ?? raw[i]
        }
        var delta = [Double](repeating: 0, count: angle.count)
        if angle.count > 1 {
            for i in 1..<angle.count { delta[i] = abs(angle[i] - angle[i - 1]) }
        }
        var immobile = [Bool](repeating: false, count: valid.count)
        var unknown = [Bool](repeating: false, count: valid.count)
        for i in valid.indices {
            let hi = min(valid.count, i + win)
            let maxDelta = delta[(i + 1)..<hi].max() ?? 0
            let still = maxDelta < angleThresholdDegrees
            if hi - i == win { immobile[i] = still } else { unknown[i] = still }
        }
        let bridge = max(0, bridgeMinutes * 60)
        var bestStart = -1, bestEnd = -1, bestLength = 0
        var i = 0
        while i < immobile.count {
            guard immobile[i] else { i += 1; continue }
            let start = i
            var end = i
            while end < immobile.count {
                if immobile[end] { end += 1; continue }
                var k = end
                while k < immobile.count && !immobile[k] && k - end < bridge { k += 1 }
                if k < immobile.count && immobile[k] && k - end < bridge { end = k; continue }
                break
            }
            if end - start > bestLength { bestStart = start; bestEnd = end; bestLength = end - start }
            i = max(end + 1, i + 1)
        }
        guard bestStart >= 0, bestLength >= win else {
            return .absent(tier: .high, inputs: inputs, note: "no sustained-inactivity block ≥\(sustainedMinutes)min found", algorithmVersion: algorithmVersion)
        }
        let cadence = valid.count > 1 ? max(0.1, AnalyticsMath.median(zip(valid.dropFirst(), valid).map { $0.0.timestamp - $0.1.timestamp }) ?? 1) : 1
        let onset = valid[bestStart].timestamp
        let offset = valid[min(bestEnd - 1, valid.count - 1)].timestamp + cadence
        let confidence = AnalyticsMath.clamp(Double(bestLength) / (7 * 3600), 0.3, 0.95)
        let result = SleepWindow(
            onsetIndex: bestStart, offsetIndex: bestEnd, onset: onset, offset: offset,
            immobile: immobile, immobileUnknown: unknown, zAngleDegrees: angle,
            sptSeconds: max(0, Int((offset - onset).rounded()))
        )
        let note = unknown.contains(true) ? "van Hees angle-based rest window; unresolved tail excluded" : "van Hees angle-based rest window"
        return AnalyticsMetric(value: result, confidence: confidence, tier: .high, inputs: inputs, note: note, algorithmVersion: algorithmVersion)
    }

    public static func segment(
        _ input: SleepInputSnapshot,
        forcedWindow: SleepForcedWindow? = nil
    ) -> SleepSegmentation {
        let accel = input.acceleration.filter(\.valid).sorted { $0.timestamp < $1.timestamp }
        let heart = input.heartRate.sorted { $0.timestamp < $1.timestamp }
        let requested = forcedWindow ?? input.forcedWindow
        guard !accel.isEmpty else {
            return requested == nil ? heartRateLedSegmentation(input, heart: heart) : .absent
        }
        // The automatic path is intentionally conservative: the pinned
        // segmenter requires an aligned HR stream before it can claim stages.
        // A caller-supplied window is different; it is useful for showing an
        // explicitly partial night even when HR was unavailable.
        if requested == nil && !heart.contains(where: { $0.valid && $0.bpm > 0 && $0.timestamp.isFinite }) {
            return .absent
        }
        let window: SleepWindow?
        var naps: [SleepWindow] = []
        if let forced = requested, forced.offset > forced.onset {
            let indices = accel.indices.filter { accel[$0].timestamp >= forced.onset && accel[$0].timestamp < forced.offset }
            let immobile = [Bool](repeating: false, count: indices.count)
            window = SleepWindow(onsetIndex: indices.first ?? 0, offsetIndex: indices.last.map { $0 + 1 } ?? 0, onset: forced.onset, offset: forced.offset, immobile: immobile, sptSeconds: max(0, Int((forced.offset - forced.onset).rounded())))
        } else {
            // Automatic detection follows the pinned AdvancedSleepStager
            // guards (15-minute gravity stillness, HR confirmation, daytime,
            // off-wrist, one-hour floor and 16-hour cap).  The lower-level
            // van Hees primitive remains public for explicit primitive parity
            // fixtures, but is not a bypass around production guards.
            let detected = SleepAdvancedWindowDetector.detect(
                acceleration: accel,
                heartRate: heart,
                timeZoneIdentifier: input.timeZoneIdentifier,
                daytimeHeartRate: input.daytimeHeartRate
            )
            let eligible = detected.value?.filter { window in
                guard let wakeDay = input.mainSleepWakeDay else { return true }
                return mainSleepDay(forEnd: window.offset, timeZoneIdentifier: input.timeZoneIdentifier)?.day == wakeDay
            } ?? []
            // The automatic main sleep needs the pinned three-hour floor. A
            // shorter qualifying session is real, it is just a nap.
            let longEnough = eligible.filter { Double($0.sptSeconds) >= SleepAdvancedWindowDetector.mainSleepMinimumSeconds }
            guard let detectedWindow = longEnough.max(by: { $0.sptSeconds < $1.sptSeconds }) else {
                // Gravity found something, but nothing long enough to be a
                // night. Try the heart-rate-led fallback before giving up, and
                // keep the short sessions as naps either way.
                let fallback = heartRateLedSegmentation(input, heart: heart)
                let others = eligible.sorted { $0.onset < $1.onset }
                guard fallback.window != nil else {
                    return others.isEmpty ? .absent : SleepSegmentation(
                        window: nil, stages: [], stages4: [], totalSleepSeconds: nil,
                        wasoSeconds: nil, inBedSeconds: nil, efficiencyPercent: nil,
                        nremSeconds: nil, lightSeconds: nil, deepSeconds: nil,
                        remSeconds: nil, wakeSeconds: nil, isPartial: false,
                        confidence: 0, naps: others
                    )
                }
                return fallback.replacingNaps(others.filter { !overlaps($0, fallback.window!) })
            }
            naps = eligible
                .filter { $0.onset != detectedWindow.onset || $0.offset != detectedWindow.offset }
                .sorted { $0.onset < $1.onset }
            window = detectedWindow
        }
        guard let window, window.offset > window.onset else { return .absent }
        let inBed = max(1, Int((window.offset - window.onset).rounded()))
        let availableHR = heart.filter {
            $0.valid && $0.bpm > 0 && $0.bpm.isFinite && $0.timestamp >= window.onset && $0.timestamp < window.offset
        }
        guard !availableHR.isEmpty else {
            // A user-forced window is still recorded, but no stage is claimed.
            return SleepSegmentation(
                window: window,
                stages: [SleepStage](repeating: .wake, count: inBed),
                stages4: [SleepStage](repeating: .wake, count: inBed),
                totalSleepSeconds: nil,
                wasoSeconds: nil,
                inBedSeconds: inBed,
                efficiencyPercent: nil,
                nremSeconds: nil,
                lightSeconds: nil,
                deepSeconds: nil,
                remSeconds: nil,
                wakeSeconds: nil,
                isPartial: true,
                confidence: 0.2,
                naps: naps
            )
        }
        guard let staged = SleepCardioStager.stage(
            acceleration: accel,
            heartRate: heart,
            rr: input.rr,
            onset: window.onset,
            offset: window.offset
        ).value else {
            return requested == nil ? .absent : SleepSegmentation(
                window: window,
                stages: [SleepStage](repeating: .wake, count: inBed),
                stages4: [SleepStage](repeating: .wake, count: inBed),
                totalSleepSeconds: nil,
                wasoSeconds: nil,
                inBedSeconds: inBed,
                efficiencyPercent: nil,
                nremSeconds: nil,
                lightSeconds: nil,
                deepSeconds: nil,
                remSeconds: nil,
                wakeSeconds: nil,
                isPartial: true,
                confidence: 0.2,
                naps: naps
            )
        }
        var perSecond = [SleepStage](repeating: .wake, count: inBed)
        var perSecond4 = [SleepStage](repeating: .wake, count: inBed)
        for epoch in staged.stages.indices {
            let stage = staged.stages[epoch]
            let stage4 = epoch < staged.stages4.count ? staged.stages4[epoch] : stage
            let lower = epoch * staged.epochSeconds
            let upper = min(inBed, lower + staged.epochSeconds)
            guard lower < upper else { continue }
            for second in lower..<upper { perSecond[second] = stage; perSecond4[second] = stage4 }
        }
        let confidence = requested == nil ? staged.confidence : min(0.35, staged.confidence)
        return Self.makeSegmentation(window: window, labels: perSecond, stages4: perSecond4, confidence: confidence, isPartial: requested != nil && window.unresolvedTailSeconds > 0, naps: naps)
    }

    /// Heart-rate-led sleep window, used only when gravity cannot carry the
    /// night. The pinned pipeline treats it as a candidate, so the result is
    /// always marked partial and never claims the full automatic confidence.
    private static func heartRateLedSegmentation(_ input: SleepInputSnapshot, heart: [SleepHeartRateSample]) -> SleepSegmentation {
        let accel = input.acceleration.filter(\.valid)
        guard accel.isEmpty || SleepAdvancedWindowDetector.gravityIsSparse(acceleration: accel, heartRate: heart) else { return .absent }
        guard let candidate = SleepHRFallback.window(heart, daytimeBaseline: input.daytimeHeartRate).value else { return .absent }
        if let wakeDay = input.mainSleepWakeDay,
           mainSleepDay(forEnd: candidate.offset, timeZoneIdentifier: input.timeZoneIdentifier)?.day != wakeDay {
            return .absent
        }
        let inBed = max(1, Int((candidate.offset - candidate.onset).rounded()))
        let window = SleepWindow(
            onsetIndex: 0, offsetIndex: 0, onset: candidate.onset, offset: candidate.offset,
            immobile: [], sptSeconds: inBed
        )
        guard let staged = SleepCardioStager.stage(
            acceleration: input.acceleration,
            heartRate: heart,
            rr: input.rr,
            onset: candidate.onset,
            offset: candidate.offset
        ).value else {
            return SleepSegmentation(
                window: window,
                stages: [SleepStage](repeating: .wake, count: inBed),
                stages4: [SleepStage](repeating: .wake, count: inBed),
                totalSleepSeconds: nil, wasoSeconds: nil, inBedSeconds: inBed,
                efficiencyPercent: nil, nremSeconds: nil, lightSeconds: nil,
                deepSeconds: nil, remSeconds: nil, wakeSeconds: nil,
                isPartial: true, confidence: 0.2, isHeartRateLed: true
            )
        }
        var perSecond = [SleepStage](repeating: .wake, count: inBed)
        var perSecond4 = [SleepStage](repeating: .wake, count: inBed)
        for epoch in staged.stages.indices {
            let stage = staged.stages[epoch]
            let stage4 = epoch < staged.stages4.count ? staged.stages4[epoch] : stage
            let lower = epoch * staged.epochSeconds
            let upper = min(inBed, lower + staged.epochSeconds)
            guard lower < upper else { continue }
            for second in lower..<upper { perSecond[second] = stage; perSecond4[second] = stage4 }
        }
        // The candidate window is only a sustained dip in heart rate. A quiet
        // evening produces one, and the stager then finds a few scattered
        // minutes of sleep inside eight hours of sitting still. That is not a
        // night, and publishing it hands the Sleep screen a duration of
        // forty-five minutes at nine per cent efficiency instead of the empty
        // state the day deserves. Hold the fallback to the same main-sleep
        // floor the gravity path uses, measured on the sleep it actually
        // staged rather than on the length of the dip.
        let stagedAsleepSeconds = perSecond.filter(\.isAsleep).count
        guard Double(stagedAsleepSeconds) >= SleepAdvancedWindowDetector.mainSleepMinimumSeconds else { return .absent }
        return makeSegmentation(
            window: window, labels: perSecond, stages4: perSecond4,
            confidence: min(0.3, staged.confidence), isPartial: true, isHeartRateLed: true
        )
    }

    private static func overlaps(_ window: SleepWindow, _ other: SleepWindow) -> Bool {
        window.onset < other.offset && other.onset < window.offset
    }

    private static func makeSegmentation(window: SleepWindow, labels: [SleepStage], stages4: [SleepStage]? = nil, confidence: Double, isPartial: Bool, naps: [SleepWindow] = [], isHeartRateLed: Bool = false) -> SleepSegmentation {
        var first = labels.firstIndex(where: { $0.isAsleep })
        var last = labels.lastIndex(where: { $0.isAsleep })
        let wake = labels.filter { $0 == .wake }.count
        let nrem = labels.filter { $0.isNREM }.count
        let rem = labels.filter { $0 == .rem }.count
        let outputStages4 = stages4 ?? labels.map { $0 == .nrem ? .light : $0 }
        // The stager labels sleep in three classes and carries the deep/light
        // split only in `stages4`, so the three-class labels never contain a
        // single deep second. Counting deep from them reported every night as
        // 0 minutes deep and all NREM as light, while the hypnogram (drawn
        // from `stages4`) showed deep blocks. Split NREM the way the pinned
        // segmenter does: an NREM second is deep when `stages4` says deep.
        var light = 0, deep = 0
        for index in labels.indices where labels[index].isNREM {
            let refined = index < outputStages4.count ? outputStages4[index] : labels[index]
            if refined == .deep { deep += 1 } else { light += 1 }
        }
        let tst = nrem + rem
        var waso = 0
        if let f = first, let l = last, f <= l { waso = labels[f...l].filter { $0 == .wake }.count }
        if first == nil { first = 0; last = 0 }
        return SleepSegmentation(
            window: window, stages: labels, stages4: outputStages4, totalSleepSeconds: tst,
            wasoSeconds: waso, inBedSeconds: labels.count,
            efficiencyPercent: labels.isEmpty ? nil : 100 * Double(tst) / Double(labels.count),
            nremSeconds: nrem, lightSeconds: light, deepSeconds: deep, remSeconds: rem,
            wakeSeconds: wake, isPartial: isPartial, confidence: confidence,
            naps: naps, isHeartRateLed: isHeartRateLed
        )
    }

    public static func consolidateSleepStages(_ stages: [SleepStage], epochSeconds: Int = 30) -> [SleepStage] {
        guard stages.count > 1 else { return stages }
        var out = stages
        let minBout = max(1, Int((5 * 60.0 / Double(max(epochSeconds, 1))).rounded()))
        let remGap = max(1, Int((15 * 60.0 / Double(max(epochSeconds, 1))).rounded()))
        func runs() -> [(Int, Int, SleepStage)] {
            guard !out.isEmpty else { return [] }
            var result: [(Int, Int, SleepStage)] = []; var start = 0
            for i in 1...out.count where i == out.count || out[i] != out[start] {
                result.append((start, i, out[start])); start = i
            }
            return result
        }
        // Bridge a short NREM intrusion within a genuine REM episode.
        for r in runs() where r.2.isNREM && r.1 - r.0 < remGap {
            let rs = runs(); guard let idx = rs.firstIndex(where: { $0.0 == r.0 }) else { continue }
            if idx > 0, idx + 1 < rs.count, rs[idx - 1].2 == .rem, rs[idx + 1].2 == .rem {
                for i in r.0..<r.1 { out[i] = .rem }
            }
        }
        var changed = true
        while changed {
            changed = false
            let rs = runs()
            for (idx, r) in rs.enumerated() where r.2.isNREM && r.1 - r.0 < minBout {
                let left = idx > 0 && rs[idx - 1].2.isNREM ? rs[idx - 1] : nil
                let right = idx + 1 < rs.count && rs[idx + 1].2.isNREM ? rs[idx + 1] : nil
                let target = (left != nil && right != nil) ? ((left!.1 - left!.0 >= right!.1 - right!.0) ? left!.2 : right!.2) : (left?.2 ?? right?.2)
                if let target, target != r.2 { for i in r.0..<r.1 { out[i] = target }; changed = true; break }
            }
        }
        return out
    }

    public static func accounting(asleep: [Bool], stages: [SleepStage]? = nil) -> AnalyticsMetric<SleepAccounting> {
        let inputs = ["in_bed_sleep_wake"]
        guard asleep.count >= 60 else { return .absent(tier: .high, inputs: inputs, note: "in-bed window too short for sleep accounting", algorithmVersion: algorithmVersion) }
        guard let onset = asleep.firstIndex(of: true), let offset = asleep.lastIndex(of: true) else {
            return .absent(tier: .high, inputs: inputs, note: "no sleep detected within the in-bed window", algorithmVersion: algorithmVersion)
        }
        let period = max(0, offset - onset)
        let inBed = offset - onset + 1
        let tst = asleep[onset...offset].filter { $0 }.count
        let waso = inBed - tst
        let cycles: Int
        if let stages, stages.count == asleep.count {
            cycles = countEpisodes(stages, stage: .rem, lo: onset, hi: offset, minLength: 180, bridge: 300)
        } else { cycles = Int(AnalyticsMath.clamp(Double(period) / 5400, 0, 6).rounded()) }
        let value = SleepAccounting(onsetIndex: onset, offsetIndex: offset, totalSleepSeconds: tst, wasoSeconds: waso, sleepPeriodSeconds: period, efficiencyPercent: 100 * Double(tst) / Double(inBed), cycles: min(6, max(0, cycles)))
        return AnalyticsMetric(value: value, confidence: AnalyticsMath.clamp(0.4 + Double(period) / (8 * 3600) * 0.5, 0.4, 0.9), tier: .high, inputs: stages == nil ? inputs : inputs + ["stages"], note: "onset/offset/WASO/TST/efficiency", algorithmVersion: algorithmVersion)
    }

    private static func countEpisodes(_ stages: [SleepStage], stage: SleepStage, lo: Int, hi: Int, minLength: Int, bridge: Int) -> Int {
        guard lo <= hi, !stages.isEmpty else { return 0 }
        var count = 0, i = max(0, lo)
        while i <= min(hi, stages.count - 1) {
            guard stages[i] == stage else { i += 1; continue }
            let start = i; var end = i
            while end <= hi && end < stages.count {
                if stages[end] == stage { end += 1; continue }
                var k = end
                while k <= hi && k < stages.count && stages[k] != stage && k - end < bridge { k += 1 }
                if k <= hi && k < stages.count && stages[k] == stage { end = k; continue }
                break
            }
            if end - start >= minLength { count += 1 }
            i = max(end + 1, i + 1)
        }
        return count
    }

    public static func hypnogramMetrics(_ session: SleepSession) -> HypnogramMetrics {
        let stages = session.stages
        let tib = Int(max(0, session.end - session.start).rounded())
        let sleepIndices = stages.indices.filter { stages[$0] != .wake }
        let onset = sleepIndices.first ?? stages.count
        let sptEnd = sleepIndices.last.map { $0 + 1 } ?? onset
        let sleep = sleepIndices.count
        let wasoRange = onset < sptEnd ? stages[onset..<min(sptEnd, stages.count)] : stages[0..<0]
        let waso = wasoRange.filter { $0 == .wake }.count
        let deep = stages.filter { $0 == .deep }.count, rem = stages.filter { $0 == .rem }.count
        let light = stages.filter { $0 == .light || $0 == .nrem }.count
        let sleepDouble = Double(max(1, sleep))
        var disturbances = 0
        var inWakeBout = false
        if onset < sptEnd {
            for stage in stages[onset..<min(sptEnd, stages.count)] {
                if stage == .wake {
                    if !inWakeBout { disturbances += 1 }
                    inWakeBout = true
                } else {
                    inWakeBout = false
                }
            }
        }
        let remIndex = stages.firstIndex(of: .rem)
        return HypnogramMetrics(
            timeInBedSeconds: tib, totalSleepSeconds: sleep, sleepPeriodSeconds: max(0, sptEnd - onset),
            sleepOnsetLatencySeconds: onset == stages.count ? tib : onset, remLatencySeconds: remIndex.map { Double($0 - onset) },
            wasoSeconds: waso, efficiency: tib > 0 ? min(1, Double(sleep) / Double(tib)) : 0,
            disturbances: disturbances, deepMinutes: Double(deep) / 60, remMinutes: Double(rem) / 60,
            lightMinutes: Double(light) / 60, deepPercent: Double(deep) / sleepDouble * 100,
            remPercent: Double(rem) / sleepDouble * 100, lightPercent: Double(light) / sleepDouble * 100,
            algorithmVersion: algorithmVersion
        )
    }

    public static func sleepRegularityIndex(_ asleep: [Bool], epochsPerDay: Int) -> AnalyticsMetric<SleepRegularity> {
        let inputs = ["sleep_wake_binary"]
        guard epochsPerDay > 0, asleep.count > epochsPerDay else { return .absent(tier: .high, inputs: inputs, note: "SRI needs more than one full day", algorithmVersion: algorithmVersion) }
        var agreement = 0
        for i in 0..<(asleep.count - epochsPerDay) where asleep[i] == asleep[i + epochsPerDay] { agreement += 1 }
        let pairs = asleep.count - epochsPerDay
        let score = 200 * Double(agreement) / Double(pairs) - 100
        let band = score >= 80 ? "very regular" : score >= 60 ? "regular" : score >= 40 ? "somewhat irregular" : "irregular"
        let value = SleepRegularity(score: score, epochsPerDay: epochsPerDay, comparedPairs: pairs, band: band, algorithmVersion: algorithmVersion)
        return AnalyticsMetric(value: value, confidence: AnalyticsMath.clamp(Double(pairs) / Double(epochsPerDay) / 7, 0.3, 0.95), tier: .high, inputs: inputs, note: "epoch-by-epoch 24-hour concordance", algorithmVersion: algorithmVersion)
    }

    public static func sleepDebt(recentSleepHours: [Double], freeNightSleepHours: [Double], minimumRecentNights: Int = 3) -> AnalyticsMetric<SleepDebt> {
        guard recentSleepHours.count >= minimumRecentNights, let habitual = AnalyticsMath.median(recentSleepHours) else { return .absent(tier: .high, inputs: ["sleep_duration_recent", "sleep_duration_free"], note: "need more recent nights to estimate habitual sleep", algorithmVersion: algorithmVersion) }
        guard !freeNightSleepHours.isEmpty, let optimal = AnalyticsMath.percentile(freeNightSleepHours, 75) else {
            let value = SleepDebt(optimalSleepHours: nil, habitualSleepHours: habitual, debtHours: nil, hasFreeNight: false, algorithmVersion: algorithmVersion)
            return AnalyticsMetric(value: value, confidence: 0.3, tier: .high, inputs: ["sleep_duration_recent", "sleep_duration_free"], note: "no free night yet; sleep need remains absent", algorithmVersion: algorithmVersion)
        }
        let value = SleepDebt(optimalSleepHours: optimal, habitualSleepHours: habitual, debtHours: optimal - habitual, hasFreeNight: true, algorithmVersion: algorithmVersion)
        return AnalyticsMetric(value: value, confidence: AnalyticsMath.clamp(Double(freeNightSleepHours.count) / 5, 0.3, 0.85), tier: .high, inputs: ["sleep_duration_recent", "sleep_duration_free"], note: "optimal sleep from free-night rebound", algorithmVersion: algorithmVersion)
    }

    public static func foldProfile(_ profile: SleepUserProfile, observation: SleepNightObservation, horizonNights: Int = 14, now: TimeInterval? = nil) -> SleepUserProfile {
        guard horizonNights > 0 else { return profile }
        let nextNights = profile.nights + 1
        let alpha = max(1 / Double(nextNights), 2 / Double(horizonNights + 1))
        func ewma(_ old: Double?, _ new: Double?) -> Double? { guard let new else { return old }; guard let old else { return new }; return old * (1 - alpha) + new * alpha }
        return SleepUserProfile(
            nights: nextNights, hrFloorP5: ewma(profile.hrFloorP5, observation.hrFloorP5),
            hrFloorP25: ewma(profile.hrFloorP25, observation.hrFloorP25),
            hrSleepMedian: ewma(profile.hrSleepMedian, observation.hrSleepMedian),
            hrArousal: ewma(profile.hrArousal, observation.hrArousal),
            rmssdMedian: ewma(profile.rmssdMedian, observation.rmssdMedian),
            rmssdMAD: ewma(profile.rmssdMAD, observation.rmssdMAD), updatedAt: now
        )
    }

    public static func derive(_ input: SleepInputSnapshot) async throws -> SleepDerivation {
        try Task.checkCancellation()
        let segmentation = segment(input)
        try Task.checkCancellation()
        guard let labels = segmentation.window.map({ _ in segmentation.stages }), !labels.isEmpty else {
            return SleepDerivation(segmentation: segmentation, accounting: nil, cycles: nil, hypnogram: nil, algorithmVersion: algorithmVersion)
        }
        // A forced/no-HR window is useful as a visible partial substrate, but
        // it must not authorize downstream accounting or a completed
        // hypnogram made entirely of synthetic wake labels.
        if segmentation.isPartial {
            return SleepDerivation(segmentation: segmentation, accounting: nil, cycles: nil, hypnogram: nil, algorithmVersion: algorithmVersion)
        }
        let account = accounting(asleep: labels.map(\.isAsleep), stages: labels).value
        try Task.checkCancellation()
        // The hypnogram summary needs the four-class labels: the three-class
        // ones have no deep seconds, so deep minutes and percentages were
        // always zero here too. Wake and REM are identical in both arrays.
        let fourClass = segmentation.stages4.count == labels.count ? segmentation.stages4 : labels
        let hypno = SleepSession(start: segmentation.window!.onset, end: segmentation.window!.offset, stages: fourClass)
        let metrics = hypnogramMetrics(hypno)
        // No qualifying peak pair means the cycles could not be read, not
        // that the night had none; the pinned metric reports it as absent.
        let cycles = detectCycles(input.rr, onset: segmentation.window!.onset, offset: segmentation.window!.offset)
            .flatMap { $0.cycles.isEmpty ? nil : $0 }
        return SleepDerivation(segmentation: segmentation, accounting: account, cycles: cycles, hypnogram: metrics, algorithmVersion: algorithmVersion)
    }

    public static func detectCycles(_ rr: [SleepRRInterval], onset: TimeInterval, offset: TimeInterval) -> SleepCyclesResult? {
        let nMinutes = Int((offset - onset) / 60)
        guard nMinutes >= 60 else { return nil }
        var bins = [[Double]](repeating: [], count: nMinutes)
        for sample in rr where sample.milliseconds >= 300 && sample.milliseconds <= 2000 {
            let minute = Int(floor((sample.timestamp - onset) / 60))
            if minute >= 0 && minute < nMinutes { bins[minute].append(sample.milliseconds) }
        }
        let values = bins.map { r -> Double? in
            guard r.count >= 10 else { return nil }
            let diffs = zip(r.dropFirst(), r).map { $0.0 - $0.1 }.filter { abs($0) <= 200 }
            guard !diffs.isEmpty else { return nil }
            return sqrt(diffs.reduce(0) { $0 + $1 * $1 } / Double(diffs.count))
        }
        let smoothed = values.indices.map { i -> Double? in
            let range = max(0, i - 10)...min(nMinutes - 1, i + 10)
            let present = range.compactMap { values[$0] }
            return present.isEmpty ? nil : AnalyticsMath.mean(present)
        }
        let present = smoothed.compactMap { $0 }
        guard present.count >= 60, let mean = AnalyticsMath.mean(present), let sd = AnalyticsMath.standardDeviation(present), sd > 0 else { return nil }
        let z = smoothed.map { $0.map { ($0 - mean) / sd } }
        let peaks = cyclePeaks(z, minimumDistance: 20, minimumProminence: 0.9)
        let cycles = zip(peaks.dropFirst(), peaks).map { SleepCycle(startMinute: $0.1, endMinute: $0.0, lengthMinute: $0.0 - $0.1) }
        let meanDuration = cycles.isEmpty ? nil : Double(cycles.reduce(0) { $0 + $1.lengthMinute }) / Double(cycles.count)
        let series = z.enumerated().compactMap { i, value in
            value.map { SleepCycleSeriesPoint(timestamp: onset + Double(i) * 60, z: (1000 * $0).rounded() / 1000) }
        }
        return SleepCyclesResult(cycles: cycles, meanDurationMinutes: meanDuration, series: series)
    }

    /// Peaks of the smoothed RMSSD wave that count as cycle boundaries: local
    /// maxima that stand at least `minimumProminence` z-units above the lower
    /// of the two troughs around them, kept tallest first and at least
    /// `minimumDistance` minutes apart. This is the pinned Rosenblum-style
    /// peak finder. The earlier port kept every local maximum twenty minutes
    /// after the previous one, with no prominence test, so the ripple in a
    /// real night's RMSSD read as 19 and 20 "cycles" in eight hours instead
    /// of the four to six a night holds.
    static func cyclePeaks(_ values: [Double?], minimumDistance: Int, minimumProminence: Double) -> [Int] {
        let count = values.count
        guard count >= 3 else { return [] }
        func at(_ index: Int) -> Double { values[index] ?? -.infinity }
        var candidates: [(index: Int, value: Double)] = []
        for index in 1..<(count - 1) {
            guard let value = values[index], value >= at(index - 1), value > at(index + 1) else { continue }
            var left = index
            while left > 0, at(left - 1) < value { left -= 1 }
            var right = index
            while right < count - 1, at(right + 1) < value { right += 1 }
            let leftMinimum = values[left...index].compactMap { $0 }.min() ?? value
            let rightMinimum = values[index...right].compactMap { $0 }.min() ?? value
            if value - max(leftMinimum, rightMinimum) >= minimumProminence { candidates.append((index, value)) }
        }
        // Tallest first, earlier index first on an exact tie. Dart's sort is
        // not guaranteed stable, so the pinned finder has no defined tie
        // order; exact ties between smoothed z values do not occur on real
        // nights, and on both real nights this matches it peak for peak.
        let ordered = candidates.enumerated().sorted { lhs, rhs in
            lhs.element.value != rhs.element.value ? lhs.element.value > rhs.element.value : lhs.offset < rhs.offset
        }.map(\.element)
        var kept: [Int] = []
        for candidate in ordered where kept.allSatisfy({ abs(candidate.index - $0) >= minimumDistance }) {
            kept.append(candidate.index)
        }
        return kept.sorted()
    }

    /// Returns the local-calendar day containing `timestamp`.
    public static func dayWindow(containing timestamp: TimeInterval, timeZoneIdentifier: String?) -> SleepDayWindow? {
        let timeZone: TimeZone
        if let identifier = timeZoneIdentifier, let resolved = TimeZone(identifier: identifier) {
            timeZone = resolved
        } else {
            timeZone = .current
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let date = Date(timeIntervalSince1970: timestamp)
        let startDate = calendar.startOfDay(for: date)
        guard let endDate = calendar.date(byAdding: .day, value: 1, to: startDate) else { return nil }
        let components = calendar.dateComponents([.era, .year, .month, .day], from: startDate)
        guard let era = components.era, let year = components.year,
              let month = components.month, let day = components.day else { return nil }
        return SleepDayWindow(
            day: DayIdentity(era: era, year: year, month: month, day: day),
            start: startDate.timeIntervalSince1970,
            end: endDate.timeIntervalSince1970
        )
    }

    /// Main sleep belongs to the day on which it ends, including a sleep
    /// ending just after local midnight.  This is the canonical assignment
    /// used by daily baselines and persistence callers.
    public static func mainSleepDay(forEnd end: TimeInterval, timeZoneIdentifier: String?) -> SleepDayWindow? {
        dayWindow(containing: end, timeZoneIdentifier: timeZoneIdentifier)
    }
}

public struct SleepSession: Codable, Sendable, Equatable {
    public let start: TimeInterval
    public let end: TimeInterval
    public let stages: [SleepStage]
    public init(start: TimeInterval, end: TimeInterval, stages: [SleepStage]) { self.start = start; self.end = end; self.stages = stages }
}
