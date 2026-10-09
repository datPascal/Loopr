import Foundation
import DomainKit

/// ANA-04 recovery/readiness, stress and confidence primitives.
///
/// The wellness layer consumes immutable ANA-02/ANA-03 outputs.  It has no
/// sensor or persistence dependency and deliberately omits temperature and
/// irregular-rhythm interpretation from its public surface.
public enum WellnessAlgorithm {
    public static let version = "loopr.wellness.1"
    public static let readinessVersion = "loopr.readiness.2.honest"
}

public struct ReadinessInput: Codable, Sendable, Equatable {
    public let label: String
    public let value: Double?
    public let baseline: [Double]
    public let goodSign: Int
    public let weight: Double

    public init(label: String, value: Double?, baseline: [Double], goodSign: Int, weight: Double) {
        self.label = label
        self.value = value
        self.baseline = baseline
        self.goodSign = goodSign >= 0 ? 1 : -1
        self.weight = max(0, weight)
    }

    public static func hrv(_ value: Double?, baseline: [Double]) -> Self {
        Self(label: "HRV", value: value, baseline: baseline, goodSign: 1, weight: 0.40)
    }

    public static func restingHeartRate(_ value: Double?, baseline: [Double]) -> Self {
        Self(label: "RHR", value: value, baseline: baseline, goodSign: -1, weight: 0.30)
    }

    public static func respiration(_ value: Double?, baseline: [Double]) -> Self {
        Self(label: "RR", value: value, baseline: baseline, goodSign: -1, weight: 0.20)
    }
}

/// Typed bridge from canonical ANA-02 outputs into ANA-04.  The metric keeps
/// presence, confidence, tier, inputs, and algorithm provenance intact; the
/// Wellness layer never receives raw sensor samples through this path.
public struct CanonicalReadinessInput: Codable, Sendable, Equatable {
    public let label: String
    public let metric: AnalyticsMetric<Double>
    public let baseline: [Double]
    public let goodSign: Int
    public let weight: Double

    public init(label: String, metric: AnalyticsMetric<Double>, baseline: [Double], goodSign: Int, weight: Double) {
        self.label = label; self.metric = metric; self.baseline = baseline
        self.goodSign = goodSign >= 0 ? 1 : -1; self.weight = max(0, weight)
    }

    fileprivate var readinessInput: ReadinessInput {
        ReadinessInput(label: label, value: metric.value, baseline: baseline, goodSign: goodSign, weight: weight)
    }

    public static func hrv(_ metric: AnalyticsMetric<Double>, baseline: [Double]) -> Self {
        Self(label: "HRV", metric: metric, baseline: baseline, goodSign: 1, weight: 0.40)
    }

    public static func restingHeartRate(_ metric: AnalyticsMetric<Double>, baseline: [Double]) -> Self {
        Self(label: "RHR", metric: metric, baseline: baseline, goodSign: -1, weight: 0.30)
    }

    public static func respiration(_ metric: AnalyticsMetric<Double>, baseline: [Double]) -> Self {
        Self(label: "RR", metric: metric, baseline: baseline, goodSign: -1, weight: 0.20)
    }
}

public struct ReadinessValue: Codable, Sendable, Equatable {
    public let score: Double
    public let compositeZ: Double
    public let meaningful: Bool
    public let algorithmVersion: String

    public init(score: Double, compositeZ: Double, meaningful: Bool, algorithmVersion: String = WellnessAlgorithm.readinessVersion) {
        self.score = score
        self.compositeZ = compositeZ
        self.meaningful = meaningful
        self.algorithmVersion = algorithmVersion
    }
}

public typealias Readiness = ReadinessValue

public struct ReadinessLnRmssd: Codable, Sendable, Equatable {
    public let lnRmssdToday: Double
    public let rolling7Mean: Double
    public let cvPercent: Double
    public let z: Double?
    public let swc: Double?
    public let band: String
    public let saturationFlag: Bool
    public let algorithmVersion: String

    public init(
        lnRmssdToday: Double, rolling7Mean: Double, cvPercent: Double,
        z: Double?, swc: Double?, band: String, saturationFlag: Bool,
        algorithmVersion: String = WellnessAlgorithm.version
    ) {
        self.lnRmssdToday = lnRmssdToday
        self.rolling7Mean = rolling7Mean
        self.cvPercent = cvPercent
        self.z = z
        self.swc = swc
        self.band = band
        self.saturationFlag = saturationFlag
        self.algorithmVersion = algorithmVersion
    }
}

public struct StressIndex: Codable, Sendable, Equatable {
    public let si: Double
    public let level: String
    public let modeSeconds: Double
    public let amoPercent: Double
    public let variationRangeSeconds: Double
    public let algorithmVersion: String

    public init(
        si: Double, level: String, modeSeconds: Double, amoPercent: Double,
        variationRangeSeconds: Double, algorithmVersion: String = WellnessAlgorithm.version
    ) {
        self.si = si
        self.level = level
        self.modeSeconds = modeSeconds
        self.amoPercent = amoPercent
        self.variationRangeSeconds = variationRangeSeconds
        self.algorithmVersion = algorithmVersion
    }
}

public struct AnomalyFeatures: Codable, Sendable, Equatable {
    public let restingHeartRate: Double?
    public let hrv: Double?
    public let respiration: Double?

    public init(restingHeartRate: Double? = nil, hrv: Double? = nil, respiration: Double? = nil) {
        self.restingHeartRate = restingHeartRate
        self.hrv = hrv
        self.respiration = respiration
    }
}

public struct AnomalyDay: Codable, Sendable, Equatable {
    public let date: String
    public let mahalanobis: Double?
    public let flagged: Bool
    public let candidate: Bool
    public let drivers: [AnalyticsDriver]
    public let note: String?

    public init(date: String, mahalanobis: Double?, flagged: Bool, candidate: Bool, drivers: [AnalyticsDriver] = [], note: String? = nil) {
        self.date = date
        self.mahalanobis = mahalanobis
        self.flagged = flagged
        self.candidate = candidate
        self.drivers = drivers
        self.note = note
    }
}

public struct ChangePoint: Codable, Sendable, Equatable {
    public let index: Int
    public let direction: Int
    public let statistic: Double

    public init(index: Int, direction: Int, statistic: Double) {
        self.index = index; self.direction = direction; self.statistic = statistic
    }
}

public struct ChangePointSegmentation: Codable, Sendable, Equatable {
    public let changePoints: [Int]
    public let segmentMeans: [Double]
    public let segments: [[Int]]
    public let penalty: Double
    public let algorithmVersion: String

    public init(changePoints: [Int], segmentMeans: [Double], segments: [[Int]], penalty: Double, algorithmVersion: String = WellnessAlgorithm.version) {
        self.changePoints = changePoints; self.segmentMeans = segmentMeans
        self.segments = segments; self.penalty = penalty; self.algorithmVersion = algorithmVersion
    }
}

public enum IllnessState: String, Codable, Sendable, Equatable {
    case green
    case yellow
    case red
}

public struct IllnessDay: Codable, Sendable, Equatable {
    public let date: String
    public let state: IllnessState
    public let cusum: Double?
    public let z: Double?
    public let note: String?

    public init(date: String, state: IllnessState, cusum: Double?, z: Double?, note: String? = nil) {
        self.date = date; self.state = state; self.cusum = cusum; self.z = z; self.note = note
    }
}

public struct WellnessInputSnapshot: Codable, Sendable, Equatable {
    public let readinessInputs: [ReadinessInput]
    /// The canonical ANA-03 result for this day.  Readiness is not allowed to
    /// manufacture a value when the shared sleep segmentation is absent.
    public let sleep: SleepSegmentation?
    public let cleanedRR: RRCorrectionResult?
    public let anomalyDates: [String]
    public let anomalyFeatures: [AnomalyFeatures]
    public let illnessDates: [String]
    public let nightlyRestingHeartRate: [Double?]
    public let canonicalReadinessInputs: [CanonicalReadinessInput]

    public init(
        readinessInputs: [ReadinessInput] = [],
        cleanedRR: RRCorrectionResult? = nil,
        anomalyDates: [String] = [],
        anomalyFeatures: [AnomalyFeatures] = [],
        illnessDates: [String] = [],
        nightlyRestingHeartRate: [Double?] = [],
        sleep: SleepSegmentation? = nil,
        canonicalReadinessInputs: [CanonicalReadinessInput] = []
    ) {
        self.readinessInputs = readinessInputs
        self.sleep = sleep
        self.cleanedRR = cleanedRR
        self.anomalyDates = anomalyDates
        self.anomalyFeatures = anomalyFeatures
        self.illnessDates = illnessDates
        self.nightlyRestingHeartRate = nightlyRestingHeartRate
        self.canonicalReadinessInputs = canonicalReadinessInputs
    }
}

public struct WellnessDerivation: Codable, Sendable, Equatable {
    public let readiness: AnalyticsMetric<ReadinessValue>
    public let stress: AnalyticsMetric<StressIndex>
    public let anomalies: [AnomalyDay]
    public let illness: [IllnessDay]
    public let algorithmVersion: String

    public init(
        readiness: AnalyticsMetric<ReadinessValue>, stress: AnalyticsMetric<StressIndex>,
        anomalies: [AnomalyDay] = [], illness: [IllnessDay] = [],
        algorithmVersion: String = WellnessAlgorithm.version
    ) {
        self.readiness = readiness; self.stress = stress; self.anomalies = anomalies
        self.illness = illness; self.algorithmVersion = algorithmVersion
    }
}

public protocol WellnessAnalyticsRepository: Sendable {
    func wellness(for day: DayIdentity) async throws -> WellnessDerivation?
}

public enum WellnessAnalytics {
    public static let algorithmVersion = WellnessAlgorithm.version
    public static let readinessCompositeMinBaseline = 3
    public static let illnessCusumMinBaseline = 7
    /// Beyond this composite z the logistic has railed and the score carries
    /// no information. A handful of near-identical nights drives the baseline
    /// dispersion to zero and every later night lands at 0 or 100, so the
    /// headline is withheld instead.
    public static let readinessZCap = 5.0

    /// The readiness score fit to show a person, or nil when the composite has
    /// saturated.
    public static func headlineReadinessScore(_ composite: AnalyticsMetric<ReadinessValue>) -> Double? {
        guard let value = composite.value, value.compositeZ.isFinite else { return nil }
        return abs(value.compositeZ) > readinessZCap ? nil : value.score
    }

    /// Baevsky Stress Index on a 0 to 100 scale, log-mapped over the plausible
    /// resting range. This is autonomic tension, not a mood reading.
    public static func stressScore(stressIndex: Double) -> Double? {
        guard stressIndex.isFinite, stressIndex > 0 else { return nil }
        let lower = log(20.0), upper = log(600.0)
        return AnalyticsMath.clamp(100 * (log(stressIndex) - lower) / (upper - lower), 0, 100)
    }

    public static func readinessComposite(
        _ inputs: [ReadinessInput], swcMultiplier: Double = 0.2,
        minBaseline: Int = readinessCompositeMinBaseline
    ) -> AnalyticsMetric<ReadinessValue> {
        var used: [String] = []
        var drivers: [AnalyticsDriver] = []
        var weightSum = 0.0
        var weightedZ = 0.0
        var potentialCounts: [Int] = []
        var seen: Set<String> = []
        for input in inputs {
            guard seen.insert(input.label).inserted, input.weight > 0, let value = input.value, value.isFinite else { continue }
            let baseline = input.baseline.filter(\.isFinite)
            guard baseline.count >= minBaseline else {
                potentialCounts.append(baseline.count)
                continue
            }
            guard let rawZ = readinessZ(input) else { continue }
            potentialCounts.append(baseline.count)
            let oriented = Double(input.goodSign) * rawZ
            used.append(input.label)
            weightSum += input.weight
            weightedZ += input.weight * oriented
            let method = "median with guarded dispersion and early-history caution"
            // Keep the narrative deterministic with the pinned Dart runner:
            // displayed driver z values are canonical-rounded, just like the
            // numeric contribution field.  The raw value remains in the
            // calculation above and is never used for a decision boundary.
            drivers.append(AnalyticsDriver(label: input.label, contribution: input.weight * oriented, detail: "oriented \(method)=\(AnalyticsMath.round6(oriented))"))
        }
        guard used.count >= 2, weightSum >= 0.5 else {
            let counts = potentialCounts.sorted(by: >)
            let have = counts.count >= 2 ? counts[1] : nil
            let note = have.map { $0 < minBaseline ? needBaselineNote(have: $0, need: minBaseline) : "need_inputs: at least two usable overnight readings; no readiness from one input" }
                ?? "need_inputs: at least two usable overnight readings; no readiness from one input"
            return .absent(tier: .estimate, inputs: [], note: note, algorithmVersion: WellnessAlgorithm.readinessVersion)
        }
        let composite = weightedZ / weightSum
        let normalizedDrivers = drivers
            .map { AnalyticsDriver(label: $0.label, contribution: ($0.contribution / weightSum), detail: $0.detail) }
            .sorted { abs($0.contribution) > abs($1.contribution) }
        let meaningful = abs(composite) > swcMultiplier
        let score = 100 / (1 + exp(-composite))
        let value = ReadinessValue(score: score, compositeZ: composite, meaningful: meaningful)
        return AnalyticsMetric(
            value: value,
            confidence: AnalyticsMath.clamp(0.3 + 0.15 * Double(used.count), 0.3, 0.9),
            tier: .estimate,
            inputs: used,
            drivers: normalizedDrivers,
            note: "recovery: at least two inputs; guarded dispersion; early estimate before 14 nights",
            algorithmVersion: WellnessAlgorithm.readinessVersion
        )
    }

    public static func readinessLnRmssd(
        _ history: [Double], meanNnTodayMilliseconds: Double? = nil,
        windowDays: Int = 7, minNights: Int = 4
    ) -> AnalyticsMetric<ReadinessLnRmssd> {
        let inputs = ["ln_rmssd_history"]
        guard history.count >= minNights else {
            return .absent(tier: .high, inputs: inputs, note: needBaselineNote(have: history.count, need: minNights), algorithmVersion: algorithmVersion)
        }
        let today = history[history.count - 1]
        let start = max(0, history.count - 1 - windowDays)
        let prior = Array(history[start..<(history.count - 1)])
        guard prior.count >= 2, let mean = AnalyticsMath.mean(prior), let sd = AnalyticsMath.sampleStandardDeviation(prior), sd.isFinite else {
            return .absent(tier: .high, inputs: inputs, note: "lnRMSSD baseline dispersion undefined", algorithmVersion: algorithmVersion)
        }
        let cv = mean == 0 ? 0 : abs(sd / mean) * 100
        let z = sd > 0 ? (today - mean) / sd : nil
        let swc = 0.5 * sd
        let band = today < mean - swc ? "suppressed" : today > mean + swc ? "elevated" : "normal"
        let saturation = meanNnTodayMilliseconds.map { $0 > 1100 && (z ?? 0) > 1 } ?? false
        let value = ReadinessLnRmssd(
            lnRmssdToday: today, rolling7Mean: mean, cvPercent: cv, z: z,
            swc: swc, band: band, saturationFlag: saturation
        )
        return AnalyticsMetric(value: value, confidence: AnalyticsMath.clamp(Double(prior.count) / Double(max(1, windowDays)), 0.3, 0.9), tier: .high, inputs: inputs, note: saturation ? "lnRMSSD:RR saturation — high-HRV interpretation caution" : "whole-night lnRMSSD readiness", algorithmVersion: algorithmVersion)
    }

    public static func baevskyStressIndex(_ nnMilliseconds: [Double], minRangeMilliseconds: Double = 20) -> AnalyticsMetric<StressIndex> {
        let inputs = ["rr_cleaned"]
        let nn = nnMilliseconds.filter { $0 >= 300 && $0 <= 2000 && $0.isFinite }
        guard nn.count >= 30 else {
            return .absent(tier: .estimate, inputs: inputs, note: "need ≥30 clean beats for a Stress Index histogram", algorithmVersion: algorithmVersion)
        }
        let window = 256, step = 128
        var values: [(Double, Double, Double, Double)] = []
        var start = 0
        while start + 30 <= nn.count {
            let end = min(start + window, nn.count)
            let segment = Array(nn[start..<end])
            if let result = stressWindow(segment, minRangeMilliseconds: minRangeMilliseconds) { values.append(result) }
            if end >= nn.count { break }
            start += step
        }
        guard let si = AnalyticsMath.median(values.map(\.0)) else {
            return .absent(tier: .estimate, inputs: inputs, note: "no valid Stress Index window", algorithmVersion: algorithmVersion)
        }
        let level = si < 50 ? "low" : si < 150 ? "normal" : si < 500 ? "elevated" : "high"
        let value = StressIndex(
            si: si,
            level: level,
            modeSeconds: AnalyticsMath.median(values.map(\.1)) ?? 0,
            amoPercent: AnalyticsMath.median(values.map(\.2)) ?? 0,
            variationRangeSeconds: AnalyticsMath.median(values.map(\.3)) ?? 0
        )
        return AnalyticsMetric(value: value, confidence: AnalyticsMath.clamp(0.4 + Double(values.count) / 60, 0.4, 0.7), tier: .estimate, inputs: inputs, note: "Baevsky Stress Index: median of short RR windows; PRV, not psychological stress", algorithmVersion: algorithmVersion)
    }

    public static func multivariateAnomaly(
        dates: [String], features: [AnomalyFeatures], baselineDays: Int = 28,
        minBaseline: Int = 10, chiSquareGate: Double? = nil,
        persistDays: Int = 2, ridge: Double = 0.1
    ) -> [AnomalyDay] {
        let count = min(dates.count, features.count)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        func day(_ key: String) -> Date? {
            let parts = key.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3 else { return nil }
            return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
        }
        var result: [AnomalyDay] = []
        var run = 0
        for index in 0..<count {
            let current = orient(features[index])
            guard let currentDay = day(dates[index]),
                  let earliest = calendar.date(byAdding: .day, value: -baselineDays, to: currentDay) else {
                result.append(AnomalyDay(date: dates[index], mahalanobis: nil, flagged: false, candidate: false, note: "invalid_calendar_day"))
                run = 0; continue
            }
            if index > 0, let previous = day(dates[index - 1]), calendar.dateComponents([.day], from: previous, to: currentDay).day != 1 { run = 0 }
            var columns = Array(repeating: [Double](), count: 3)
            var rows: [[Double?]] = []
            if index > 0 {
                for j in 0..<index {
                    guard let priorDay = day(dates[j]), priorDay >= earliest, priorDay < currentDay else { continue }
                    let row = orient(features[j])
                    for f in 0..<3 { if let value = row[f] { columns[f].append(value) } }
                    rows.append(row)
                }
            }
            let available = (0..<3).filter { current[$0] != nil && columns[$0].count >= minBaseline }
            guard available.count >= 2 else {
                let have = available.map { columns[$0].count }.max() ?? (current.compactMap { $0 }.isEmpty ? -1 : columns.enumerated().filter { current[$0.offset] != nil }.map { $0.element.count }.max() ?? 0)
                let note = have >= 0 ? needBaselineNote(have: have, need: minBaseline) : nil
                result.append(AnomalyDay(date: dates[index], mahalanobis: nil, flagged: false, candidate: false, note: note))
                run = 0
                continue
            }
            var keep: [Int] = [], center: [Double] = [], scale: [Double] = []
            for feature in available {
                let median = AnalyticsMath.median(columns[feature]) ?? 0
                let robustScale = AnalyticsMath.mad(columns[feature]) ?? 0
                let fallback = AnalyticsMath.sampleStandardDeviation(columns[feature]) ?? 0
                let chosen = robustScale > 0 ? robustScale : fallback
                guard chosen.isFinite, chosen > 0, feature != 0 || chosen >= 1 else { continue }
                keep.append(feature); center.append(median); scale.append(chosen)
            }
            guard keep.count >= 2 else {
                result.append(AnomalyDay(date: dates[index], mahalanobis: nil, flagged: false, candidate: false, note: "degenerate_baseline:no_dispersion"))
                run = 0
                continue
            }
            let z = keep.indices.map { (current[keep[$0]]! - center[$0]) / scale[$0] }
            let correlation = robustCorrelation(rows: rows, keep: keep, center: center, scale: scale, ridge: ridge)
            let inverse = invert(correlation)
            let distanceSquared: Double
            if let inverse {
                distanceSquared = max(0, z.indices.reduce(0) { outer, a in
                    outer + z.indices.reduce(0) { inner, b in inner + z[a] * inverse[a][b] * z[b] }
                })
            } else {
                distanceSquared = z.reduce(0) { $0 + $1 * $1 }
            }
            let distance = sqrt(distanceSquared)
            var drivers = keep.indices.map { AnalyticsDriver(label: anomalyLabel(keep[$0]), contribution: z[$0], detail: "standardized deviation") }
            drivers.sort { abs($0.contribution) > abs($1.contribution) }
            // MIT OpenStrap analytics anomaly.dart, 27b0ba486234: empirical
            // median/MAD small-sample inflation. Exact Hotelling F correction
            // assumes mean/sample covariance and cannot calibrate MAD + ridge.
            let baselineCount = keep.map { columns[$0].count }.min() ?? 0
            let inflation = anomalySmallSampleInflation(baselineCount)
            let gate = chiSquareGate ?? chiSquare999(keep.count) * inflation
            let candidate = distanceSquared > gate
            run = candidate ? run + 1 : 0
            result.append(AnomalyDay(date: dates[index], mahalanobis: distance, flagged: candidate && run >= persistDays, candidate: candidate, drivers: drivers))
        }
        return result
    }

    public static let anomalyAlgorithmVersion = "ana04.anomaly.v2.calendar-small-sample"

    private static func anomalySmallSampleInflation(_ n: Int) -> Double {
        let anchors: [(Int, Double)] = [(10, 13.23), (14, 5.65), (20, 3.17), (28, 2.24), (45, 1.65), (90, 1.25), (200, 1)]
        guard n >= anchors[0].0 else { return anchors[0].1 }
        for index in 1..<anchors.count where n < anchors[index].0 {
            let a = anchors[index - 1], b = anchors[index]
            let fraction = (log(Double(n)) - log(Double(a.0))) / (log(Double(b.0)) - log(Double(a.0)))
            return exp(log(a.1) + fraction * (log(b.1) - log(a.1)))
        }
        return 1
    }

    public static func cusumChangePoints(_ values: [Double], k: Double = 0.5, h: Double = 5, center: Double? = nil, scale: Double? = nil) -> [ChangePoint] {
        guard values.count >= 2 else { return [] }
        let c = center ?? AnalyticsMath.median(values)!
        var s = scale ?? (AnalyticsMath.mad(values) ?? 0)
        if s <= 0 { s = AnalyticsMath.sampleStandardDeviation(values) ?? 1 }
        if s <= 0 { s = 1 }
        var up = 0.0, down = 0.0
        var result: [ChangePoint] = []
        for index in values.indices {
            let z = (values[index] - c) / s
            up = max(0, up + z - k)
            down = max(0, down - z - k)
            if up > h {
                result.append(ChangePoint(index: index, direction: 1, statistic: up)); up = 0; down = 0
            } else if down > h {
                result.append(ChangePoint(index: index, direction: -1, statistic: down)); up = 0; down = 0
            }
        }
        return result
    }

    public static func segmentChangePoints(_ values: [Double], minSegment: Int = 7, penaltyMultiplier: Double = 1, penaltyOverride: Double? = nil) -> AnalyticsMetric<ChangePointSegmentation> {
        let inputs = ["daily_aggregate"]
        let n = values.count
        guard n >= 2 * minSegment else { return .absent(tier: .estimate, inputs: inputs, note: "series shorter than 2× minimum segment", algorithmVersion: algorithmVersion) }
        var prefix = [Double](repeating: 0, count: n + 1), prefixSquared = [Double](repeating: 0, count: n + 1)
        for i in 0..<n { prefix[i + 1] = prefix[i] + values[i]; prefixSquared[i + 1] = prefixSquared[i] + values[i] * values[i] }
        let variance = AnalyticsMath.sampleStandardDeviation(values) ?? 1
        let penalty = penaltyOverride ?? penaltyMultiplier * max(variance * variance, 1) * log(Double(n))
        var points: [Int] = []
        binarySegment(values, prefix: prefix, prefixSquared: prefixSquared, lower: 0, upper: n, minimum: minSegment, penalty: penalty, output: &points)
        points.sort()
        let bounds = [0] + points + [n]
        var segments: [[Int]] = [], means: [Double] = []
        for i in 0..<(bounds.count - 1) {
            let lo = bounds[i], hi = bounds[i + 1]
            segments.append([lo, hi]); means.append(AnalyticsMath.mean(Array(values[lo..<hi])) ?? 0)
        }
        return AnalyticsMetric(value: ChangePointSegmentation(changePoints: points, segmentMeans: means, segments: segments, penalty: penalty), confidence: 0.6, tier: .estimate, inputs: inputs, note: "binary segmentation with BIC-penalized change in mean; minimum segment \(minSegment)", algorithmVersion: algorithmVersion)
    }

    public static func illnessCusum(
        dates: [String], restingHeartRate: [Double?], baselineDays: Int = 28,
        k: Double = 0.5, threshold: Double = 4, persistDays: Int = 2,
        minBaseline: Int = illnessCusumMinBaseline, returnZ: Double = 0.5,
        recoverDays: Int = 2
    ) -> [IllnessDay] {
        let count = min(dates.count, restingHeartRate.count)
        var result: [IllnessDay] = []
        var cusum = 0.0, yellowRun = 0, normalRun = 0
        for index in 0..<count {
            guard let current = restingHeartRate[index] else {
                result.append(IllnessDay(date: dates[index], state: .green, cusum: nil, z: nil)); continue
            }
            let lower = max(0, index - baselineDays)
            let baseline = restingHeartRate[lower..<index].compactMap { $0 }
            guard baseline.count >= minBaseline else {
                result.append(IllnessDay(date: dates[index], state: .green, cusum: nil, z: nil, note: needBaselineNote(have: baseline.count, need: minBaseline)))
                continue
            }
            let median = AnalyticsMath.median(baseline)!
            let robust = AnalyticsMath.mad(baseline) ?? 0
            let scale = robust > 0 ? robust : (AnalyticsMath.sampleStandardDeviation(baseline) ?? 0)
            guard scale.isFinite, scale > 0 else {
                result.append(IllnessDay(date: dates[index], state: .green, cusum: nil, z: nil, note: "degenerate_baseline:scale=0")); continue
            }
            let z = (current - median) / scale
            cusum = max(0, cusum + z - k)
            if z < returnZ { normalRun += 1; if normalRun >= recoverDays { cusum = 0 } } else { normalRun = 0 }
            let state: IllnessState
            if cusum > threshold { yellowRun += 1; state = yellowRun >= persistDays ? .red : .yellow } else { yellowRun = 0; state = .green }
            result.append(IllnessDay(date: dates[index], state: state, cusum: cusum, z: z))
        }
        return result
    }

    public static func derive(_ input: WellnessInputSnapshot) async throws -> WellnessDerivation {
        try Task.checkCancellation()
        let readinessInputs = input.canonicalReadinessInputs.map(\.readinessInput)
        let effectiveReadinessInputs = readinessInputs.isEmpty ? input.readinessInputs : readinessInputs
        let readiness: AnalyticsMetric<ReadinessValue>
        if let sleep = input.sleep, sleep.present, sleep.totalSleepSeconds != nil {
            readiness = readinessComposite(effectiveReadinessInputs)
        } else {
            readiness = .absent(
                tier: .estimate,
                inputs: ["sleep_segmentation", "readiness_inputs"],
                note: "no completed sleep segmentation; readiness remains absent",
                algorithmVersion: WellnessAlgorithm.readinessVersion
            )
        }
        try Task.checkCancellation()
        let stress: AnalyticsMetric<StressIndex>
        if let rr = input.cleanedRR {
            // The RR quality result is an upstream gate, not just metadata.
            // In particular, a short or artifact-heavy stream must not turn
            // into a neutral-looking stress score.
            guard rr.cleanFraction >= 0.5, rr.normalIntervalsMilliseconds.count >= 30 else {
                stress = .absent(
                    tier: .estimate,
                    inputs: ["rr_cleaned", "rr_quality"],
                    note: "RR quality below gate; stress index absent",
                    algorithmVersion: algorithmVersion
                )
                let anomalies = input.anomalyDates.count == input.anomalyFeatures.count ? multivariateAnomaly(dates: input.anomalyDates, features: input.anomalyFeatures) : []
                let illness = input.illnessDates.count == input.nightlyRestingHeartRate.count ? illnessCusum(dates: input.illnessDates, restingHeartRate: input.nightlyRestingHeartRate) : []
                return WellnessDerivation(readiness: readiness, stress: stress, anomalies: anomalies, illness: illness)
            }
            stress = baevskyStressIndex(rr.normalIntervalsMilliseconds)
        } else {
            stress = .absent(tier: .estimate, inputs: ["rr_cleaned"], note: "no cleaned RR output", algorithmVersion: algorithmVersion)
        }
        try Task.checkCancellation()
        let anomalies = input.anomalyDates.count == input.anomalyFeatures.count ? multivariateAnomaly(dates: input.anomalyDates, features: input.anomalyFeatures) : []
        let illness = input.illnessDates.count == input.nightlyRestingHeartRate.count ? illnessCusum(dates: input.illnessDates, restingHeartRate: input.nightlyRestingHeartRate) : []
        return WellnessDerivation(readiness: readiness, stress: stress, anomalies: anomalies, illness: illness)
    }

    /// DEC-05.4. The two-input/weight and RHR quantum gates follow the MIT
    /// OpenStrap readiness contract, independently implemented here:
    /// github.com/OpenStrap/analytics, readiness_composite.dart at 27b0ba486234.
    /// Floors reuse Loopr's 5 ms at 50 ms HRV and 0.5 br/min conventions.
    /// Prediction inflation and early-history shrink are engineering caution,
    /// not clinical confidence. See 2026-10-07-si-morning-recovery.md.
    static func readinessZ(_ input: ReadinessInput) -> Double? {
        let prior = input.baseline.filter(\.isFinite)
        guard let value = input.value, value.isFinite, Set(prior).count > 1,
              let center = AnalyticsMath.median(prior),
              let sd = AnalyticsMath.sampleStandardDeviation(prior), sd > 0 else { return nil }
        if input.label == "RHR", sd < 1 { return nil }
        let floor: Double = switch input.label { case "HRV": 0.10; case "RR": 0.5; default: 0 }
        let dispersion = max(AnalyticsMath.mad(prior) ?? 0, sd, floor)
        guard dispersion > 0 else { return nil }
        let n = Double(prior.count)
        let prediction = sqrt(1 + 1 / n)
        let earlyCaution = sqrt(min(n, 14) / 14)
        return (value - center) / (dispersion * prediction) * earlyCaution
    }

    private static func sampleZ(_ value: Double, _ baseline: [Double]) -> Double? {
        guard let mean = AnalyticsMath.mean(baseline), let sd = AnalyticsMath.sampleStandardDeviation(baseline), sd > 0 else { return nil }
        return (value - mean) / sd
    }

    private static func robustZ(_ value: Double, _ baseline: [Double]) -> Double? {
        guard baseline.count >= 2, let median = AnalyticsMath.median(baseline), let scale = AnalyticsMath.mad(baseline), scale > 0 else { return nil }
        return (value - median) / scale
    }

    private static func stressWindow(_ segment: [Double], minRangeMilliseconds: Double) -> (Double, Double, Double, Double)? {
        var counts: [Int: Int] = [:]
        for value in segment { counts[Int(floor(value / 50)) , default: 0] += 1 }
        // Dictionary iteration order is not a contract.  Resolve equal-count
        // bins by the lower RR bin so repeated derivations are byte-stable.
        var modeBin: Int?
        var modeCount = 0
        for (bin, count) in counts.sorted(by: { $0.key < $1.key }) where count > modeCount {
            modeBin = bin
            modeCount = count
        }
        guard let modeBin else { return nil }
        let modeSeconds = (Double(modeBin) + 0.5) * 50 / 1000
        let amo = 100 * Double(modeCount) / Double(segment.count)
        guard let min = segment.min(), let max = segment.max() else { return nil }
        let rangeMilliseconds = max - min
        guard modeSeconds > 0, rangeMilliseconds >= minRangeMilliseconds else { return nil }
        return (amo / (2 * modeSeconds * rangeMilliseconds / 1000), modeSeconds, amo, rangeMilliseconds / 1000)
    }

    private static func orient(_ features: AnomalyFeatures) -> [Double?] {
        [features.restingHeartRate, features.hrv.map { -$0 }, features.respiration]
    }

    private static func anomalyLabel(_ index: Int) -> String { ["RHR", "HRV(↓)", "resp"][index] }

    private static func chiSquare999(_ dimensions: Int) -> Double {
        switch dimensions { case 1: return 10.83; case 2: return 13.82; default: return 16.27 }
    }

    private static func robustCorrelation(rows: [[Double?]], keep: [Int], center: [Double], scale: [Double], ridge: Double) -> [[Double]] {
        let count = keep.count
        var matrix = Array(repeating: Array(repeating: 0.0, count: count), count: count)
        for i in 0..<count { matrix[i][i] = 1 }
        let complete = rows.compactMap { row -> [Double]? in
            let selected = keep.compactMap { row[$0] }
            return selected.count == keep.count ? selected : nil
        }
        guard complete.count >= 4 else { return matrix }
        let standardized = complete.map { row in keep.indices.map { (row[$0] - center[$0]) / scale[$0] } }
        for i in 0..<count {
            for j in (i + 1)..<count {
                let a = standardized.map { $0[i] }, b = standardized.map { $0[j] }
                let meanA = AnalyticsMath.mean(a) ?? 0, meanB = AnalyticsMath.mean(b) ?? 0
                let numerator = zip(a, b).reduce(0) { $0 + ($1.0 - meanA) * ($1.1 - meanB) }
                let da = sqrt(a.reduce(0) { $0 + ($1 - meanA) * ($1 - meanA) }), db = sqrt(b.reduce(0) { $0 + ($1 - meanB) * ($1 - meanB) })
                let correlation = da > 0 && db > 0 ? numerator / (da * db) : 0
                let bounded = AnalyticsMath.clamp(correlation, -0.95, 0.95)
                matrix[i][j] = bounded; matrix[j][i] = bounded
            }
        }
        let weight = AnalyticsMath.clamp(ridge, 0, 1)
        for i in 0..<count { for j in 0..<count { matrix[i][j] = (1 - weight) * matrix[i][j] + (i == j ? weight : 0) } }
        return matrix
    }

    private static func invert(_ matrix: [[Double]]) -> [[Double]]? {
        let n = matrix.count
        guard n > 0, matrix.allSatisfy({ $0.count == n }) else { return nil }
        var a = matrix
        var identity = Array(repeating: Array(repeating: 0.0, count: n), count: n)
        for i in 0..<n { identity[i][i] = 1 }
        for column in 0..<n {
            guard let pivot = (column..<n).max(by: { abs(a[$0][column]) < abs(a[$1][column]) }), abs(a[pivot][column]) > 1e-12 else { return nil }
            if pivot != column { a.swapAt(pivot, column); identity.swapAt(pivot, column) }
            let divisor = a[column][column]
            for j in 0..<n { a[column][j] /= divisor; identity[column][j] /= divisor }
            for row in 0..<n where row != column {
                let factor = a[row][column]
                for j in 0..<n { a[row][j] -= factor * a[column][j]; identity[row][j] -= factor * identity[column][j] }
            }
        }
        return identity
    }

    private static func segmentSSE(_ prefix: [Double], _ prefixSquared: [Double], lower: Int, upper: Int) -> Double {
        let count = upper - lower
        guard count > 0 else { return 0 }
        let sum = prefix[upper] - prefix[lower], sumSquared = prefixSquared[upper] - prefixSquared[lower]
        return sumSquared - sum * sum / Double(count)
    }

    private static func binarySegment(_ values: [Double], prefix: [Double], prefixSquared: [Double], lower: Int, upper: Int, minimum: Int, penalty: Double, output: inout [Int]) {
        guard upper - lower >= 2 * minimum else { return }
        let base = segmentSSE(prefix, prefixSquared, lower: lower, upper: upper)
        var best = -1, bestGain = 0.0
        for split in (lower + minimum)...(upper - minimum) {
            let gain = base - segmentSSE(prefix, prefixSquared, lower: lower, upper: split) - segmentSSE(prefix, prefixSquared, lower: split, upper: upper)
            if gain > bestGain { bestGain = gain; best = split }
        }
        guard best >= 0, bestGain > penalty else { return }
        output.append(best)
        binarySegment(values, prefix: prefix, prefixSquared: prefixSquared, lower: lower, upper: best, minimum: minimum, penalty: penalty, output: &output)
        binarySegment(values, prefix: prefix, prefixSquared: prefixSquared, lower: best, upper: upper, minimum: minimum, penalty: penalty, output: &output)
    }
}

/// Stable machine-readable abstention text shared by baseline-gated wellness
/// primitives.  A short baseline is not a zero-valued baseline.
public func needBaselineNote(have: Int, need: Int) -> String {
    "need_baseline:have=\(max(0, have)),need=\(max(0, need))"
}

/// Reads a `need_baseline:have=H,need=N` note back into the number of further
/// nights required, so a screen can count down instead of saying "building"
/// forever. Returns nil for any other note.
public func baselineNightsRemaining(_ note: String?) -> Int? {
    guard let note, note.hasPrefix("need_baseline:") else { return nil }
    let body = note.dropFirst("need_baseline:".count)
    var have: Int?
    var need: Int?
    for part in body.split(separator: ",") {
        let pair = part.split(separator: "=", maxSplits: 1)
        guard pair.count == 2, let value = Int(pair[1]) else { continue }
        if pair[0] == "have" { have = value }
        if pair[0] == "need" { need = value }
    }
    guard let have, let need else { return nil }
    return max(0, need - have)
}

// Source-shaped free functions make parity fixtures easy to port while the
// namespaced API remains the single implementation path.
public func readinessComposite(_ inputs: [ReadinessInput], swcMultiplier: Double = 0.2, minBaseline: Int = WellnessAnalytics.readinessCompositeMinBaseline) -> AnalyticsMetric<ReadinessValue> {
    WellnessAnalytics.readinessComposite(inputs, swcMultiplier: swcMultiplier, minBaseline: minBaseline)
}

public func baevskyStressIndex(_ nnMilliseconds: [Double], minRangeMilliseconds: Double = 20) -> AnalyticsMetric<StressIndex> {
    WellnessAnalytics.baevskyStressIndex(nnMilliseconds, minRangeMilliseconds: minRangeMilliseconds)
}

public func multivariateAnomaly(_ dates: [String], _ features: [AnomalyFeatures], baselineDays: Int = 28, minBaseline: Int = 10, chiSquareGate: Double? = nil, persistDays: Int = 2, ridge: Double = 0.1) -> [AnomalyDay] {
    WellnessAnalytics.multivariateAnomaly(dates: dates, features: features, baselineDays: baselineDays, minBaseline: minBaseline, chiSquareGate: chiSquareGate, persistDays: persistDays, ridge: ridge)
}

public func cusumChangePoints(_ values: [Double], k: Double = 0.5, h: Double = 5, center: Double? = nil, scale: Double? = nil) -> [ChangePoint] {
    WellnessAnalytics.cusumChangePoints(values, k: k, h: h, center: center, scale: scale)
}

public func segmentChangePoints(_ values: [Double], minSegment: Int = 7, penaltyMultiplier: Double = 1, penaltyOverride: Double? = nil) -> AnalyticsMetric<ChangePointSegmentation> {
    WellnessAnalytics.segmentChangePoints(values, minSegment: minSegment, penaltyMultiplier: penaltyMultiplier, penaltyOverride: penaltyOverride)
}

public func illnessCusum(_ dates: [String], _ restingHeartRate: [Double?], baselineDays: Int = 28, k: Double = 0.5, threshold: Double = 4, persistDays: Int = 2, minBaseline: Int = WellnessAnalytics.illnessCusumMinBaseline, returnZ: Double = 0.5, recoverDays: Int = 2) -> [IllnessDay] {
    WellnessAnalytics.illnessCusum(dates: dates, restingHeartRate: restingHeartRate, baselineDays: baselineDays, k: k, threshold: threshold, persistDays: persistDays, minBaseline: minBaseline, returnZ: returnZ, recoverDays: recoverDays)
}
