import Foundation
import DomainKit

public enum WorkoutAlgorithm {
    public static let version = "loopr.workout.2"
}

public struct WorkoutHRPoint: Codable, Sendable, Equatable {
    public let timestamp: TimeInterval
    public let bpm: Double
    public let valid: Bool

    public init(timestamp: TimeInterval, bpm: Double, valid: Bool = true) {
        self.timestamp = timestamp; self.bpm = bpm; self.valid = valid
    }
}

public struct WorkoutMotionPoint: Codable, Sendable, Equatable {
    public let timestamp: TimeInterval
    public let intensity: Double
    public init(timestamp: TimeInterval, intensity: Double) { self.timestamp = timestamp; self.intensity = intensity }
}

public struct SavedWorkoutSpan: Codable, Sendable, Equatable {
    public let start: TimeInterval
    public let end: TimeInterval
    public init(start: TimeInterval, end: TimeInterval) { self.start = start; self.end = end }
}

public struct WorkoutBout: Codable, Sendable, Equatable {
    public let start: TimeInterval
    public let end: TimeInterval
    public let averageBPM: Double
    public let peakBPM: Double
    public let durationSeconds: Double
    public init(start: TimeInterval, end: TimeInterval, averageBPM: Double, peakBPM: Double, durationSeconds: Double) {
        self.start = start; self.end = end; self.averageBPM = averageBPM; self.peakBPM = peakBPM; self.durationSeconds = durationSeconds
    }
}

public struct MotionFeatures: Codable, Sendable, Equatable {
    public let meanIntensity: Double
    public let cadenceHz: Double?
    public let enmo: Double?
    public init(meanIntensity: Double, cadenceHz: Double? = nil, enmo: Double? = nil) { self.meanIntensity = meanIntensity; self.cadenceHz = cadenceHz; self.enmo = enmo }
}

public typealias SportClassifier = @Sendable (WorkoutBout, MotionFeatures?) -> String

public struct DetectedWorkout: Codable, Sendable, Equatable {
    public let start: TimeInterval
    public let end: TimeInterval
    public let averageBPM: Double
    public let peakBPM: Double
    public let durationMinutes: Int
    public let sport: String
    public init(start: TimeInterval, end: TimeInterval, averageBPM: Double, peakBPM: Double, durationMinutes: Int, sport: String = "detected") {
        self.start = start; self.end = end; self.averageBPM = averageBPM; self.peakBPM = peakBPM; self.durationMinutes = durationMinutes; self.sport = sport
    }
}

public struct WorkoutHRZoneSummary: Codable, Sendable, Equatable {
    public let zoneTimePercent: [Int: Double]
    public let averageHRReservePercent: Double?
    public init(zoneTimePercent: [Int: Double], averageHRReservePercent: Double?) { self.zoneTimePercent = zoneTimePercent; self.averageHRReservePercent = averageHRReservePercent }
}

public struct ExerciseSession: Codable, Sendable, Equatable {
    public let start: TimeInterval
    public let end: TimeInterval
    public let averageBPM: Double
    public let peakBPM: Double
    public let strain: Double?
    public let durationSeconds: Double
    public let zones: WorkoutHRZoneSummary?
    public let hrMax: Double?
    public let hrMaxSource: String
    public let caloriesKcal: Double?
    public let sport: String
    public let algorithmVersion: String

    public init(start: TimeInterval, end: TimeInterval, averageBPM: Double, peakBPM: Double, strain: Double?, durationSeconds: Double, zones: WorkoutHRZoneSummary?, hrMax: Double?, hrMaxSource: String, caloriesKcal: Double?, sport: String, algorithmVersion: String = WorkoutAlgorithm.version) {
        self.start = start; self.end = end; self.averageBPM = averageBPM; self.peakBPM = peakBPM; self.strain = strain; self.durationSeconds = durationSeconds
        self.zones = zones; self.hrMax = hrMax; self.hrMaxSource = hrMaxSource; self.caloriesKcal = caloriesKcal; self.sport = sport; self.algorithmVersion = algorithmVersion
    }
}

public struct HRRecovery: Codable, Sendable, Equatable {
    public let peakBPM: Double
    public let heartRateAtRecovery: Double
    public let dropBPM: Double
    public let dropPercent: Double
    public let algorithmVersion: String
    public init(peakBPM: Double, heartRateAtRecovery: Double, dropBPM: Double, dropPercent: Double, algorithmVersion: String = WorkoutAlgorithm.version) {
        self.peakBPM = peakBPM; self.heartRateAtRecovery = heartRateAtRecovery; self.dropBPM = dropBPM; self.dropPercent = dropPercent; self.algorithmVersion = algorithmVersion
    }
}

public struct WorkoutDayCurve: Codable, Sendable, Equatable {
    public let date: String
    public let value: Double
    public let percentileOfYou: Double?
    public let priorCount: Int
    public let algorithmVersion: String
    public init(date: String, value: Double, percentileOfYou: Double?, priorCount: Int, algorithmVersion: String = WorkoutAlgorithm.version) {
        self.date = date; self.value = value; self.percentileOfYou = percentileOfYou; self.priorCount = priorCount; self.algorithmVersion = algorithmVersion
    }
}

public struct WorkoutDayAssignment: Codable, Sendable, Equatable {
    public let day: DayIdentity
    public let dayStart: TimeInterval
    public let dayEnd: TimeInterval
    public init(day: DayIdentity, dayStart: TimeInterval, dayEnd: TimeInterval) { self.day = day; self.dayStart = dayStart; self.dayEnd = dayEnd }
}

public struct WorkoutProfile: Codable, Sendable, Equatable {
    public let weightKG: Double
    public let heightCM: Double
    public let age: Double
    public let sex: ActivitySex
    public init(weightKG: Double, heightCM: Double, age: Double, sex: ActivitySex) { self.weightKG = weightKG; self.heightCM = heightCM; self.age = age; self.sex = sex }
}

public typealias WorkoutUserProfile = WorkoutProfile

public struct WorkoutEnergyEstimate: Codable, Sendable, Equatable {
    public let kcal: Double
    public let kilojoules: Double
    public let usedDefaultAnchors: Bool
    public let algorithmVersion: String

    public init(kcal: Double, kilojoules: Double, usedDefaultAnchors: Bool, algorithmVersion: String = WorkoutAlgorithm.version) {
        self.kcal = kcal; self.kilojoules = kilojoules; self.usedDefaultAnchors = usedDefaultAnchors
        self.algorithmVersion = algorithmVersion
    }
}

public struct WorkoutDailyEnergy: Codable, Sendable, Equatable {
    public let totalKcal: Double
    public let activeKcal: Double
    public let basalKcal: Double
    public let usedDefaultHRmax: Bool
    public let algorithmVersion: String

    public init(totalKcal: Double, activeKcal: Double, basalKcal: Double, usedDefaultHRmax: Bool, algorithmVersion: String = WorkoutAlgorithm.version) {
        self.totalKcal = totalKcal; self.activeKcal = activeKcal; self.basalKcal = basalKcal
        self.usedDefaultHRmax = usedDefaultHRmax; self.algorithmVersion = algorithmVersion
    }
}

public struct WorkoutInputSnapshot: Codable, Sendable, Equatable {
    public let heartRate: [WorkoutHRPoint]
    public let motion: [WorkoutMotionPoint]
    public let restingHR: Double?
    public let hrMax: Double?
    public let age: Double?
    public let savedSpans: [SavedWorkoutSpan]
    public let sport: String
    public let timeZoneIdentifier: String?
    public let profile: WorkoutProfile?

    public init(heartRate: [WorkoutHRPoint], motion: [WorkoutMotionPoint] = [], restingHR: Double? = nil, hrMax: Double? = nil, age: Double? = nil, savedSpans: [SavedWorkoutSpan] = [], sport: String = "detected", timeZoneIdentifier: String? = nil, profile: WorkoutProfile? = nil) {
        self.heartRate = heartRate; self.motion = motion; self.restingHR = restingHR; self.hrMax = hrMax; self.age = age; self.savedSpans = savedSpans; self.sport = sport; self.timeZoneIdentifier = timeZoneIdentifier
        self.profile = profile
    }
}

public struct WorkoutDerivation: Codable, Sendable, Equatable {
    public let suggestions: [DetectedWorkout]
    public let sessions: [ExerciseSession]
    public let recovery: AnalyticsMetric<HRRecovery>
    public let algorithmVersion: String
    public init(suggestions: [DetectedWorkout], sessions: [ExerciseSession], recovery: AnalyticsMetric<HRRecovery>, algorithmVersion: String = WorkoutAlgorithm.version) { self.suggestions = suggestions; self.sessions = sessions; self.recovery = recovery; self.algorithmVersion = algorithmVersion }
}

public protocol WorkoutAnalyticsRepository: Sendable {
    func workout(for day: DayIdentity) async throws -> WorkoutDerivation?
}

public enum WorkoutAnalytics {
    public static let algorithmVersion = WorkoutAlgorithm.version
    public static let defaultSport = "detected"

    public static func autoDetect(
        _ hr: [WorkoutHRPoint], restingHR: Double?, maxHR: Double? = nil,
        motion: [WorkoutMotionPoint]? = nil, savedSpans: [SavedWorkoutSpan] = [],
        classifier: SportClassifier? = nil
    ) -> [DetectedWorkout] {
        let sorted = hr.filter { $0.valid && $0.bpm.isFinite && $0.bpm > 0 && $0.timestamp.isFinite }.sorted { $0.timestamp < $1.timestamp }
        guard !sorted.isEmpty else { return [] }
        guard let rhr = restingHR, rhr.isFinite, rhr > 0,
              let effectiveMax = maxHR, effectiveMax.isFinite, effectiveMax > rhr else { return [] }
        let floor = max(rhr + 40, rhr + 0.45 * (effectiveMax - rhr))
        var spans: [(TimeInterval, TimeInterval)] = []
        var start: TimeInterval?, end: TimeInterval = 0, dipStart: TimeInterval?
        var previousTimestamp: TimeInterval?
        func close() {
            if let start, end - start >= 12 * 60 { spans.append((start, end)) }
            start = nil; dipStart = nil
        }
        for sample in sorted {
            if let previousTimestamp, sample.timestamp - previousTimestamp > 300 { close() }
            previousTimestamp = sample.timestamp
            if sample.bpm >= floor { start = start ?? sample.timestamp; end = sample.timestamp; dipStart = nil }
            else if start != nil {
                dipStart = dipStart ?? sample.timestamp
                if sample.timestamp - dipStart! > 90 { close() }
            }
        }
        close()
        guard !spans.isEmpty else { return [] }
        var merged: [(TimeInterval, TimeInterval)] = []
        for span in spans {
            if let last = merged.last, span.0 - last.1 < 300 { merged[merged.count - 1] = (last.0, max(last.1, span.1)) } else { merged.append(span) }
        }
        var results: [DetectedWorkout] = []
        for span in merged where span.1 - span.0 <= 120 * 60 {
            guard !savedSpans.contains(where: { overlaps(span.0, span.1, $0.start, $0.end) }) else { continue }
            let window = sorted.filter { $0.timestamp >= span.0 && $0.timestamp <= span.1 }
            guard !window.isEmpty, (window.map(\.bpm).reduce(0, +) / Double(window.count)) >= floor else { continue }
            let observedElevatedMinutes = Set(window.filter { $0.bpm >= floor }.map { Int(($0.timestamp / 60).rounded(.down)) }).count
            guard observedElevatedMinutes >= 12 else { continue }
            var features: MotionFeatures?
            if let motion, !motion.isEmpty {
                let inside = motion.filter { $0.timestamp.isFinite && $0.intensity.isFinite && $0.intensity >= 0 && $0.timestamp >= span.0 && $0.timestamp <= span.1 }
                guard !inside.isEmpty else { continue }
                let meanMotion = inside.map(\.intensity).reduce(0, +) / Double(inside.count)
                guard meanMotion >= 0.15 else { continue }
                features = MotionFeatures(meanIntensity: meanMotion)
            }
            let bout = WorkoutBout(start: span.0, end: span.1, averageBPM: window.map(\.bpm).reduce(0, +) / Double(window.count), peakBPM: window.map(\.bpm).max() ?? 0, durationSeconds: span.1 - span.0)
            let sport = classifier?(bout, features) ?? defaultSport
            results.append(DetectedWorkout(start: span.0, end: span.1, averageBPM: bout.averageBPM.rounded(), peakBPM: bout.peakBPM.rounded(), durationMinutes: Int((span.1 - span.0) / 60), sport: sport))
        }
        return results
    }

    /// Estimate calories for one detected bout using the pinned Keytel active
    /// equation plus a revised Harris–Benedict resting floor.  Sparse samples
    /// are weighted by elapsed time (capped at the detector merge gap), and
    /// default HR anchors are surfaced on the value instead of being hidden.
    public static func estimateBoutCalories(
        _ samples: [WorkoutHRPoint],
        profile: WorkoutProfile,
        hrMax: Double? = nil,
        restingHR: Double? = nil,
        mergeGapSeconds: Double = 150
    ) -> AnalyticsMetric<WorkoutEnergyEstimate> {
        let sorted = samples.filter { $0.valid && $0.bpm > 0 && $0.bpm.isFinite && $0.timestamp.isFinite }.sorted { $0.timestamp < $1.timestamp }
        guard !sorted.isEmpty else {
            return .absent(tier: .estimate, inputs: ["hr_bout", "workout_profile"], note: "no valid HR samples for calorie estimation", algorithmVersion: algorithmVersion)
        }
        let weight = profile.weightKG > 0 && profile.weightKG.isFinite ? profile.weightKG : 70
        let height = profile.heightCM > 0 && profile.heightCM.isFinite ? profile.heightCM : 170
        let age = profile.age > 0 && profile.age.isFinite ? profile.age : 30
        let coefficients = calorieCoefficients(for: profile.sex)
        let usedDefaultAnchors = !(hrMax?.isFinite == true && hrMax! > 0) || !(restingHR?.isFinite == true && restingHR! > 0)
        let effectiveMax = hrMax.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 220
        let effectiveResting = restingHR.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 60
        let activeThreshold = effectiveResting + 0.30 * (effectiveMax - effectiveResting)
        let restingRate = max(0, coefficients.restingAlpha + coefficients.restingWeight * weight + coefficients.restingHeight * (height / 100) - coefficients.restingAge * age) / 86_400
        var total = 0.0
        for index in sorted.indices {
            let duration: Double
            if index + 1 < sorted.count {
                let gap = sorted[index + 1].timestamp - sorted[index].timestamp
                duration = gap > 0 ? min(gap, max(1, mergeGapSeconds)) : 1
            } else {
                duration = 1
            }
            if sorted[index].bpm < activeThreshold {
                total += restingRate * duration
            } else {
                let activePerSecond = max(0, coefficients.workoutHR * min(sorted[index].bpm, effectiveMax) + coefficients.workoutWeight * weight + coefficients.workoutAge * age + coefficients.workoutAlpha) / 251.04
                total += activePerSecond * duration
            }
        }
        let value = WorkoutEnergyEstimate(kcal: total, kilojoules: total * 4.184, usedDefaultAnchors: usedDefaultAnchors)
        return AnalyticsMetric(value: value, confidence: usedDefaultAnchors ? 0.35 : 0.65, tier: .estimate, inputs: ["hr_bout", "workout_profile", "hrmax?", "resting_hr?"], note: usedDefaultAnchors ? "Keytel/Harris–Benedict estimate using default HR anchor(s); caveat required" : "Keytel/Harris–Benedict HR calorie estimate", algorithmVersion: algorithmVersion)
    }

    /// Daily HR-flex energy estimate.  Basal energy uses Mifflin–St Jeor;
    /// active surplus is accumulated only above the HR-flex point.
    ///
    /// The flex point follows heart-rate reserve whenever a resting heart rate
    /// is known, matching `estimateBoutCalories`. A flat fraction of HRmax is
    /// the wrong anchor for anyone whose resting rate is not average: a person
    /// resting at 75 bpm sits above half of a 185 bpm maximum while doing
    /// nothing, and every sedentary minute is then billed as exercise.
    public static func dailyEnergy(
        _ heartRatePerMinute: [Double],
        profile: WorkoutProfile,
        hrMax: Double? = nil,
        restingHR: Double? = nil,
        activeFraction: Double = 0.50,
        reserveFraction: Double = 0.30,
        dayMinutes: Int = 1_440
    ) -> AnalyticsMetric<WorkoutDailyEnergy> {
        let weight = profile.weightKG > 0 && profile.weightKG.isFinite ? profile.weightKG : 70
        let height = profile.heightCM > 0 && profile.heightCM.isFinite ? profile.heightCM : 170
        let age = profile.age > 0 && profile.age.isFinite ? profile.age : 30
        let coefficients = calorieCoefficients(for: profile.sex)
        let usedDefaultHRmax = !(hrMax?.isFinite == true && hrMax! > 0)
        let effectiveMax = hrMax.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? (220 - age)
        let bmrConstant: Double = profile.sex == .male ? 5 : profile.sex == .female ? -161 : -78
        let bmr = max(0, 10 * weight + 6.25 * height - 5 * age + bmrConstant)
        let basalPerMinute = bmr / 1_440
        let resting = restingHR.flatMap { $0.isFinite && $0 > 0 && $0 < effectiveMax ? $0 : nil }
        let flexHR = resting.map { $0 + AnalyticsMath.clamp(reserveFraction, 0, 1) * (effectiveMax - $0) }
            ?? AnalyticsMath.clamp(activeFraction, 0, 1) * effectiveMax
        var active = 0.0
        for hr in heartRatePerMinute where hr.isFinite && hr >= flexHR {
            let activePerMinute = max(0, coefficients.workoutHR * min(hr, effectiveMax) + coefficients.workoutWeight * weight + coefficients.workoutAge * age + coefficients.workoutAlpha) / 251.04 * 60
            active += max(0, activePerMinute - basalPerMinute)
        }
        let basal = basalPerMinute * Double(max(0, dayMinutes))
        let value = WorkoutDailyEnergy(totalKcal: basal + active, activeKcal: active, basalKcal: basal, usedDefaultHRmax: usedDefaultHRmax)
        return AnalyticsMetric(value: value, confidence: usedDefaultHRmax ? 0.35 : 0.6, tier: .estimate, inputs: ["hr_per_min", "workout_profile", "hrmax?"], note: usedDefaultHRmax ? "Mifflin + HR-flex estimate using default HRmax" : "Mifflin + HR-flex daily energy estimate", algorithmVersion: algorithmVersion)
    }

    public static func detect(
        _ hr: [WorkoutHRPoint], motion: [WorkoutMotionPoint], restingHR: Double?, maxHR: Double?, age: Double? = nil,
        savedSpans: [SavedWorkoutSpan] = [], classifier: SportClassifier? = nil, profile: WorkoutProfile? = nil,
        includeSustainedModerate: Bool = false
    ) -> AnalyticsMetric<[ExerciseSession]> {
        let sortedHR = hr.filter { $0.valid && $0.bpm.isFinite && $0.bpm > 0 && $0.timestamp.isFinite }.sorted { $0.timestamp < $1.timestamp }
        let sortedMotion = motion.filter { $0.timestamp.isFinite && $0.intensity.isFinite && $0.intensity >= 0 }.sorted { $0.timestamp < $1.timestamp }
        guard !sortedHR.isEmpty, !sortedMotion.isEmpty else { return .absent(tier: .estimate, inputs: ["hr_1hz", "motion_1hz"], note: "no HR or motion stream for workout detection", algorithmVersion: algorithmVersion) }
        let rhr = restingHR ?? AnalyticsMath.percentile(sortedHR.map(\.bpm), 10)
        guard let rhr, rhr.isFinite, rhr > 0 else { return .absent(tier: .estimate, inputs: ["resting_hr"], note: "no resting HR baseline", algorithmVersion: algorithmVersion) }
        let resolvedMax: Double
        let source: String
        if let maxHR { resolvedMax = maxHR; source = "caller" }
        else {
            let estimate = ActivityAnalytics.estimateHRmax(history: sortedHR.map(\.bpm), age: age ?? profile?.age)
            guard let value = estimate.value else {
                return .absent(tier: .estimate, inputs: ["max_hr", "age", "hr_history"], note: "no HRmax anchor for zone qualification", algorithmVersion: algorithmVersion)
            }
            resolvedMax = value.maxHR
            source = value.source == .measured ? "observed" : "tanaka"
        }
        guard resolvedMax.isFinite, resolvedMax > rhr else { return .absent(tier: .estimate, inputs: ["max_hr", "resting_hr"], note: "invalid HR reserve", algorithmVersion: algorithmVersion) }
        let smoothed = trailingMean(sortedMotion, windowSeconds: 10)
        let hrFloor = rhr + 15
        let active = zip(sortedMotion, smoothed).compactMap { pair -> TimeInterval? in
            guard pair.1 > 0.2, let nearest = nearestHR(sortedHR, at: pair.0.timestamp), nearest > hrFloor else { return nil }
            return pair.0.timestamp
        }
        guard !active.isEmpty else { return AnalyticsMetric(value: [], confidence: 0, tier: .estimate, inputs: ["hr_1hz", "motion_1hz"], note: "no sustained elevated HR + motion bout", algorithmVersion: algorithmVersion) }
        let runs = bridgeRuns(makeRuns(active, mergeGap: 150), heartRate: sortedHR, floor: hrFloor)
        var sessions: [ExerciseSession] = []
        for run in runs where run.1 - run.0 >= 5 * 60 - 10 {
            let window = sortedHR.filter { $0.timestamp >= run.0 && $0.timestamp <= run.1 }
            guard !window.isEmpty else { continue }
            let zone = zoneSummary(window.map(\.bpm), restingHR: rhr, maxHR: resolvedMax)
            let z2plus = (2...5).reduce(0) { $0 + (zone.zoneTimePercent[$1] ?? 0) } / 100
            // OpenStrap's suggestion gate uses 45% HR reserve. A long,
            // movement-confirmed moderate bout can qualify there even when
            // fewer than half its samples reach the persistent zone-2 gate.
            let moderateShare = Double(window.filter { ($0.bpm - rhr) / (resolvedMax - rhr) >= 0.45 }.count) / Double(window.count)
            let sustainedModerate = includeSustainedModerate && run.1 - run.0 >= 30 * 60 && moderateShare >= 0.8
            guard z2plus >= 0.5 || sustainedModerate else { continue }
            guard !savedSpans.contains(where: { overlaps(run.0, run.1, $0.start, $0.end) }) else { continue }
            let trimp = window.map { AnalyticsMath.clamp(($0.bpm - rhr) / (resolvedMax - rhr), 0, 1) }.reduce(0, +)
            let strain = min(100, 100 * log(trimp + 1) / log(7201))
            let bout = WorkoutBout(start: run.0, end: run.1, averageBPM: window.map(\.bpm).reduce(0, +) / Double(window.count), peakBPM: window.map(\.bpm).max() ?? 0, durationSeconds: run.1 - run.0)
            let boutMotion = sortedMotion.filter { $0.timestamp >= run.0 && $0.timestamp <= run.1 }
            let boutFeatures = MotionFeatures(meanIntensity: boutMotion.map(\.intensity).reduce(0, +) / Double(max(1, boutMotion.count)))
            let sport = classifier?(bout, boutFeatures) ?? defaultSport
            let calories = profile.flatMap { estimateBoutCalories(window, profile: $0, hrMax: resolvedMax, restingHR: rhr).value?.kcal }
            sessions.append(ExerciseSession(start: run.0, end: run.1, averageBPM: bout.averageBPM, peakBPM: bout.peakBPM, strain: strain, durationSeconds: run.1 - run.0, zones: zone, hrMax: resolvedMax, hrMaxSource: source, caloriesKcal: calories, sport: sport))
        }
        let note = includeSustainedModerate
            ? "detected workouts: HR + motion gated, with sustained moderate-effort qualification"
            : "detected workouts: HR + motion gated, ≥5min and ≥50% zone 2+"
        return AnalyticsMetric(value: sessions, confidence: sessions.isEmpty ? 0 : 0.6, tier: .estimate, inputs: ["hr_1hz", "motion_1hz", "resting_hr", "max_hr"], note: note, algorithmVersion: algorithmVersion)
    }

    public static func hrRecovery(_ tail: [Double], endIndex: Int? = nil, recoverySeconds: Int = 60, peakWindowSeconds: Int = 30) -> AnalyticsMetric<HRRecovery> {
        let end = endIndex ?? 0
        guard !tail.isEmpty, end >= 0, end < tail.count else { return .absent(tier: .estimate, inputs: ["hr_1hz"], note: "no HR tail for HR recovery", algorithmVersion: algorithmVersion) }
        let peakWindow = tail[max(0, end - peakWindowSeconds)...end].filter { $0 > 0 && $0.isFinite }
        let target = end + recoverySeconds
        guard target < tail.count, target + 3 < tail.count else { return .absent(tier: .estimate, inputs: ["hr_1hz"], note: "HR tail too short to reach recovery point", algorithmVersion: algorithmVersion) }
        let recovery = tail[(target - 3)...(target + 3)].filter { $0 > 0 && $0.isFinite }
        guard let peak = peakWindow.max(), let atRecovery = AnalyticsMath.median(recovery), peak > 0, !recovery.isEmpty else { return .absent(tier: .estimate, inputs: ["hr_1hz"], note: "off-skin or missing HR around recovery point", algorithmVersion: algorithmVersion) }
        let drop = peak - atRecovery
        guard drop > 0 else { return .absent(tier: .estimate, inputs: ["hr_1hz"], note: "HR did not descend after exercise", algorithmVersion: algorithmVersion) }
        return AnalyticsMetric(value: HRRecovery(peakBPM: peak, heartRateAtRecovery: atRecovery, dropBPM: drop, dropPercent: 100 * drop / peak), confidence: AnalyticsMath.clamp(drop / 30, 0.3, 0.9), tier: .estimate, inputs: ["hr_1hz"], note: "HRR-\(recoverySeconds)s = peak − recovery HR", algorithmVersion: algorithmVersion)
    }

    public static func workoutDay(start: TimeInterval, end: TimeInterval, timeZoneIdentifier: String?) -> WorkoutDayAssignment? {
        // A cross-midnight workout is attributed to the local day on which it
        // ends, matching the explicit main-sleep day rule and preventing one
        // workout from being counted twice in daily baselines.
        guard let window = SleepAnalytics.dayWindow(containing: end, timeZoneIdentifier: timeZoneIdentifier) else { return nil }
        return WorkoutDayAssignment(day: window.day, dayStart: window.start, dayEnd: window.end)
    }

    public static func dayCurve(dates: [String], values: [Double], minimumHistory: Int = 14) -> [WorkoutDayCurve] {
        guard dates.count == values.count else { return [] }
        var curves: [WorkoutDayCurve] = []
        for i in values.indices {
            // Baselines are date-scoped, not merely index-scoped: a target
            // day may never consume another sample from the same day, even if
            // the caller presents duplicate or reordered rows.
            let prior = dates.indices.filter { dates[$0] < dates[i] }.map { values[$0] }.filter(\.isFinite)
            let percentile: Double?
            if prior.count < minimumHistory { percentile = nil }
            else {
                let below = prior.filter { $0 < values[i] }.count, equal = prior.filter { $0 == values[i] }.count
                percentile = 100 * (Double(below) + 0.5 * Double(equal)) / Double(prior.count)
            }
            curves.append(WorkoutDayCurve(date: dates[i], value: values[i], percentileOfYou: percentile, priorCount: prior.count))
        }
        return curves
    }

    public static func derive(_ input: WorkoutInputSnapshot) async throws -> WorkoutDerivation {
        try Task.checkCancellation()
        let suggestions = autoDetect(input.heartRate, restingHR: input.restingHR, maxHR: input.hrMax, motion: input.motion, savedSpans: input.savedSpans, classifier: { bout, _ in input.sport.isEmpty ? defaultSport : input.sport })
        try Task.checkCancellation()
        let sessions = detect(input.heartRate, motion: input.motion, restingHR: input.restingHR, maxHR: input.hrMax, age: input.age, savedSpans: input.savedSpans, classifier: { bout, features in input.sport.isEmpty ? defaultSport : input.sport }, profile: input.profile).value ?? []
        let recovery = hrRecovery(input.heartRate.sorted { $0.timestamp < $1.timestamp }.map(\.bpm), endIndex: input.heartRate.isEmpty ? nil : input.heartRate.count - 1)
        return WorkoutDerivation(suggestions: suggestions, sessions: sessions, recovery: recovery)
    }

    private struct CalorieCoefficients {
        let restingAlpha: Double
        let restingWeight: Double
        let restingHeight: Double
        let restingAge: Double
        let workoutHR: Double
        let workoutWeight: Double
        let workoutAge: Double
        let workoutAlpha: Double
    }

    private static func calorieCoefficients(for sex: ActivitySex) -> CalorieCoefficients {
        switch sex {
        case .male:
            return CalorieCoefficients(restingAlpha: 88.362, restingWeight: 13.397, restingHeight: 479.9, restingAge: 5.677, workoutHR: 0.6309, workoutWeight: 0.1988, workoutAge: 0.2017, workoutAlpha: -55.0969)
        case .female:
            return CalorieCoefficients(restingAlpha: 447.593, restingWeight: 9.247, restingHeight: 309.8, restingAge: 4.33, workoutHR: 0.4472, workoutWeight: -0.1263, workoutAge: 0.0740, workoutAlpha: -20.4022)
        case .nonbinary:
            return CalorieCoefficients(restingAlpha: 267.9775, restingWeight: 11.322, restingHeight: 394.85, restingAge: 5.0035, workoutHR: 0.53905, workoutWeight: 0.03625, workoutAge: 0.13785, workoutAlpha: -37.74955)
        }
    }

    private static func overlaps(_ aStart: TimeInterval, _ aEnd: TimeInterval, _ bStart: TimeInterval, _ bEnd: TimeInterval) -> Bool { aStart <= bEnd && bStart <= aEnd }

    private static func nearestHR(_ sorted: [WorkoutHRPoint], at timestamp: TimeInterval, tolerance: TimeInterval = 5) -> Double? {
        var lower = 0, upper = sorted.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if sorted[middle].timestamp < timestamp { lower = middle + 1 } else { upper = middle }
        }
        var best: (distance: TimeInterval, bpm: Double)?
        for index in [lower - 1, lower] where sorted.indices.contains(index) {
            let distance = abs(sorted[index].timestamp - timestamp)
            if distance <= tolerance && (best == nil || distance <= best!.distance) {
                best = (distance, sorted[index].bpm)
            }
        }
        return best?.bpm
    }

    private static func trailingMean(_ motion: [WorkoutMotionPoint], windowSeconds: TimeInterval) -> [Double] {
        var result: [Double] = [], lower = 0, sum = 0.0
        for i in motion.indices {
            sum += motion[i].intensity
            while lower < i && motion[i].timestamp - motion[lower].timestamp > windowSeconds { sum -= motion[lower].intensity; lower += 1 }
            result.append(sum / Double(i - lower + 1))
        }
        return result
    }

    private static func makeRuns(_ timestamps: [TimeInterval], mergeGap: TimeInterval) -> [(TimeInterval, TimeInterval)] {
        guard let first = timestamps.first else { return [] }
        var result: [(TimeInterval, TimeInterval)] = [], start = first, previous = first
        for timestamp in timestamps.dropFirst() {
            if timestamp - previous > mergeGap { result.append((start, previous)); start = timestamp }
            previous = timestamp
        }
        result.append((start, previous)); return result
    }

    private static func bridgeRuns(_ runs: [(TimeInterval, TimeInterval)], heartRate: [WorkoutHRPoint], floor: Double) -> [(TimeInterval, TimeInterval)] {
        guard let first = runs.first else { return [] }
        var result: [(TimeInterval, TimeInterval)] = []
        var current = first
        for next in runs.dropFirst() {
            let gap = next.0 - current.1
            var shouldBridge = false
            if gap <= 300 {
                var lower = 0, upper = heartRate.count
                while lower < upper {
                    let middle = (lower + upper) / 2
                    if heartRate[middle].timestamp <= current.1 { lower = middle + 1 } else { upper = middle }
                }
                var sum = 0.0, count = 0, index = lower
                while index < heartRate.count && heartRate[index].timestamp < next.0 {
                    sum += heartRate[index].bpm
                    count += 1
                    index += 1
                }
                // No HR in the gap means signal loss, not observed rest.
                shouldBridge = count == 0 || sum / Double(count) > floor
            }
            if shouldBridge { current.1 = max(current.1, next.1) }
            else { result.append(current); current = next }
        }
        result.append(current)
        return result
    }

    private static func zoneSummary(_ bpm: [Double], restingHR: Double, maxHR: Double) -> WorkoutHRZoneSummary {
        var counts = [Int: Int](); var hrr: [Double] = []
        for value in bpm {
            let x = AnalyticsMath.clamp((value - restingHR) / (maxHR - restingHR), 0, 1)
            let zone = x >= 0.9 ? 5 : x >= 0.8 ? 4 : x >= 0.7 ? 3 : x >= 0.6 ? 2 : x >= 0.5 ? 1 : 0
            counts[zone, default: 0] += 1; hrr.append(x * 100)
        }
        let total = Double(max(1, bpm.count))
        return WorkoutHRZoneSummary(zoneTimePercent: counts.mapValues { 100 * Double($0) / total }, averageHRReservePercent: AnalyticsMath.mean(hrr))
    }
}

public func hrRecovery(_ tail: [Double], endIndex: Int? = nil, recoverySeconds: Int = 60) -> AnalyticsMetric<HRRecovery> {
    WorkoutAnalytics.hrRecovery(tail, endIndex: endIndex, recoverySeconds: recoverySeconds)
}

public func autoDetectWorkouts(_ heartRate: [WorkoutHRPoint], restingHR: Double?, maxHR: Double? = nil, motion: [WorkoutMotionPoint]? = nil) -> [DetectedWorkout] {
    WorkoutAnalytics.autoDetect(heartRate, restingHR: restingHR, maxHR: maxHR, motion: motion)
}

public func estimateBoutCalories(_ samples: [WorkoutHRPoint], profile: WorkoutProfile, hrMax: Double? = nil, restingHR: Double? = nil, mergeGapSeconds: Double = 150) -> AnalyticsMetric<WorkoutEnergyEstimate> {
    WorkoutAnalytics.estimateBoutCalories(samples, profile: profile, hrMax: hrMax, restingHR: restingHR, mergeGapSeconds: mergeGapSeconds)
}

public func dailyEnergy(_ heartRatePerMinute: [Double], profile: WorkoutProfile, hrMax: Double? = nil, restingHR: Double? = nil, activeFraction: Double = 0.50, dayMinutes: Int = 1_440) -> AnalyticsMetric<WorkoutDailyEnergy> {
    WorkoutAnalytics.dailyEnergy(heartRatePerMinute, profile: profile, hrMax: hrMax, restingHR: restingHR, activeFraction: activeFraction, dayMinutes: dayMinutes)
}
