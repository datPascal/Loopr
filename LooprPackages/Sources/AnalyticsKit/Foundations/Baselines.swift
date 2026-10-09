import Foundation

public struct RobustBaseline: Codable, Sendable, Equatable {
    public let center: Double?
    public let scale: Double?
    public let validCount: Int
    public let windowCount: Int
    public let sufficient: Bool
    public let algorithmVersion: String

    public init(center: Double?, scale: Double?, validCount: Int, windowCount: Int, sufficient: Bool, algorithmVersion: String = AnalyticsAlgorithmVersion.baseline) {
        self.center = center; self.scale = scale; self.validCount = validCount; self.windowCount = windowCount; self.sufficient = sufficient; self.algorithmVersion = algorithmVersion
    }

    public func modifiedZ(_ value: Double) -> Double? {
        guard let center, let scale, scale != 0 else { return nil }
        return (value - center) / scale
    }

    public func isOutlier(_ value: Double) -> Bool? { modifiedZ(value).map { abs($0) > 3.5 } }
}

public struct EWMAPoint: Codable, Sendable, Equatable {
    public let value: Double
    public let isGap: Bool
    public let algorithmVersion: String
    public init(value: Double, isGap: Bool, algorithmVersion: String = AnalyticsAlgorithmVersion.baseline) { self.value = value; self.isGap = isGap; self.algorithmVersion = algorithmVersion }
}

public struct MetricBaselineConfiguration: Codable, Sendable, Equatable {
    public let minimumValue: Double
    public let maximumValue: Double
    public let floorSpread: Double
    public let centerHalfLife: Double
    public let spreadHalfLife: Double
    public init(minimumValue: Double, maximumValue: Double, floorSpread: Double, centerHalfLife: Double, spreadHalfLife: Double) {
        self.minimumValue = minimumValue; self.maximumValue = maximumValue; self.floorSpread = floorSpread; self.centerHalfLife = centerHalfLife; self.spreadHalfLife = spreadHalfLife
    }
}

/// A dated nightly value used when constructing a target-day baseline.  The
/// date is an already-resolved local-day boundary supplied by the caller; the
/// baseline engine never reads a calendar or database.
public struct DatedBaselineSample: Codable, Sendable, Equatable {
    public let day: Date
    public let value: Double?
    public init(day: Date, value: Double?) {
        self.day = day
        self.value = value
    }
}

public enum BaselineStatus: String, Codable, Sendable, Equatable {
    case calibrating
    case provisional
    case trusted
    case stale
}

public struct BaselineState: Codable, Sendable, Equatable {
    public let baseline: Double
    public let spread: Double
    public let validCount: Int
    public let nightsSinceUpdate: Int
    public let status: BaselineStatus
    public let algorithmVersion: String
    public init(baseline: Double, spread: Double, validCount: Int, nightsSinceUpdate: Int, status: BaselineStatus, algorithmVersion: String = AnalyticsAlgorithmVersion.baseline) {
        self.baseline = baseline; self.spread = spread; self.validCount = validCount; self.nightsSinceUpdate = nightsSinceUpdate; self.status = status; self.algorithmVersion = algorithmVersion
    }
    public var trusted: Bool { status == .trusted }
    public var usable: Bool { status == .provisional || status == .trusted }
}

public struct BaselineDeviation: Codable, Sendable, Equatable {
    public let z: Double
    public let delta: Double
    public let ratio: Double
    public let inNormalRange: Bool
    public let algorithmVersion: String
    public init(z: Double, delta: Double, ratio: Double, inNormalRange: Bool, algorithmVersion: String = AnalyticsAlgorithmVersion.baseline) {
        self.z = z; self.delta = delta; self.ratio = ratio; self.inNormalRange = inNormalRange; self.algorithmVersion = algorithmVersion
    }
}

public enum Baselines {
    public static let winsorizationK = 3.0
    public static let hardOutlierK = 5.0
    public static let minimumNightsSeed = 4
    public static let minimumNightsTrust = 14
    public static let staleDays = 14
    public static let earlyAdaptNights = 8
    public static let earlyCenterHalfLife = 3.0
    public static let earlySpreadInflation = 2.5

    public static let hrv = MetricBaselineConfiguration(minimumValue: 5, maximumValue: 250, floorSpread: 5, centerHalfLife: 14, spreadHalfLife: 21)
    public static let restingHeartRate = MetricBaselineConfiguration(minimumValue: 30, maximumValue: 120, floorSpread: 2, centerHalfLife: 14, spreadHalfLife: 21)
    public static let respiration = MetricBaselineConfiguration(minimumValue: 4, maximumValue: 40, floorSpread: 0.5, centerHalfLife: 14, spreadHalfLife: 21)
    public static let skinTemperature = MetricBaselineConfiguration(minimumValue: 20, maximumValue: 42, floorSpread: 0.3, centerHalfLife: 14, spreadHalfLife: 21)

    public static func computeStatus(validCount: Int, nightsSinceUpdate: Int) -> BaselineStatus {
        if nightsSinceUpdate > staleDays && validCount >= minimumNightsSeed { return .stale }
        if validCount < minimumNightsSeed { return .calibrating }
        if validCount < minimumNightsTrust { return .provisional }
        return .trusted
    }

    public static func update(_ state: BaselineState?, value: Double?, configuration: MetricBaselineConfiguration) -> BaselineState {
        let centerLambda = AnalyticsMath.lambda(halfLife: configuration.centerHalfLife)
        let spreadLambda = AnalyticsMath.lambda(halfLife: configuration.spreadHalfLife)
        guard let state else {
            guard let value, value >= configuration.minimumValue, value <= configuration.maximumValue else {
                return BaselineState(baseline: (configuration.minimumValue + configuration.maximumValue) / 2, spread: configuration.floorSpread, validCount: 0, nightsSinceUpdate: 1, status: .calibrating)
            }
            return BaselineState(baseline: value, spread: configuration.floorSpread, validCount: 1, nightsSinceUpdate: 0, status: .calibrating)
        }
        guard let value else {
            let nights = state.nightsSinceUpdate + 1
            return BaselineState(baseline: state.baseline, spread: state.spread, validCount: state.validCount, nightsSinceUpdate: nights, status: computeStatus(validCount: state.validCount, nightsSinceUpdate: nights))
        }
        guard value >= configuration.minimumValue && value <= configuration.maximumValue else {
            let nights = state.nightsSinceUpdate + 1
            return BaselineState(baseline: state.baseline, spread: state.spread, validCount: state.validCount, nightsSinceUpdate: nights, status: computeStatus(validCount: state.validCount, nightsSinceUpdate: nights))
        }
        let young = state.validCount < earlyAdaptNights
        if state.validCount >= minimumNightsSeed && !young && abs(value - state.baseline) > hardOutlierK * state.spread {
            return BaselineState(baseline: state.baseline, spread: state.spread, validCount: state.validCount, nightsSinceUpdate: 0, status: computeStatus(validCount: state.validCount, nightsSinceUpdate: 0))
        }
        if state.validCount == 0 {
            return BaselineState(baseline: value, spread: configuration.floorSpread, validCount: 1, nightsSinceUpdate: 0, status: .calibrating)
        }
        let effectiveSpread = young ? state.spread * earlySpreadInflation : state.spread
        let effectiveLambda = young ? AnalyticsMath.lambda(halfLife: earlyCenterHalfLife) : centerLambda
        let lower = state.baseline - winsorizationK * effectiveSpread
        let upper = state.baseline + winsorizationK * effectiveSpread
        let clamped = AnalyticsMath.clamp(value, lower, upper)
        let newBaseline = effectiveLambda * clamped + (1 - effectiveLambda) * state.baseline
        let absoluteDeviation = abs(value - newBaseline)
        let newSpread = max(configuration.floorSpread, spreadLambda * absoluteDeviation + (1 - spreadLambda) * state.spread)
        let newCount = state.validCount + 1
        return BaselineState(baseline: newBaseline, spread: newSpread, validCount: newCount, nightsSinceUpdate: 0, status: computeStatus(validCount: newCount, nightsSinceUpdate: 0))
    }

    public static func foldHistory(_ values: [Double?], configuration: MetricBaselineConfiguration) -> BaselineState {
        var state: BaselineState?
        for value in values { state = update(state, value: value, configuration: configuration) }
        return state ?? BaselineState(baseline: (configuration.minimumValue + configuration.maximumValue) / 2, spread: configuration.floorSpread, validCount: 0, nightsSinceUpdate: 0, status: .calibrating)
    }

    /// Build the baseline for `targetDay` from strictly earlier local days.
    /// A sample on the target day is intentionally excluded, even when the
    /// input collection is unsorted; this prevents same-day leakage.
    public static func foldHistoryBefore(
        _ samples: [DatedBaselineSample],
        targetDay: Date,
        configuration: MetricBaselineConfiguration
    ) -> BaselineState {
        let prior = samples
            .filter { $0.day < targetDay }
            .sorted { $0.day < $1.day }
            .map(\.value)
        return foldHistory(prior, configuration: configuration)
    }

    public static func deviation(value: Double, state: BaselineState) -> BaselineDeviation {
        let sigma = max(1.253 * state.spread, 1e-9)
        let z = (value - state.baseline) / sigma
        return BaselineDeviation(z: z, delta: value - state.baseline, ratio: state.baseline == 0 ? 0 : value / state.baseline - 1, inNormalRange: abs(z) <= 1)
    }

    public static func rollingMeanSD(_ values: [Double?], configuration: MetricBaselineConfiguration, window: Int = 30) -> BaselineState {
        let valid = values.compactMap { value -> Double? in
            guard let value, value >= configuration.minimumValue, value <= configuration.maximumValue else { return nil }
            return value
        }
        guard !valid.isEmpty else {
            return BaselineState(baseline: (configuration.minimumValue + configuration.maximumValue) / 2, spread: configuration.floorSpread, validCount: 0, nightsSinceUpdate: 0, status: .calibrating)
        }
        let trailing = valid.count > window ? Array(valid.suffix(window)) : valid
        let average = AnalyticsMath.mean(trailing)!
        let standardDeviation = AnalyticsMath.sampleStandardDeviation(trailing) ?? configuration.floorSpread * 1.253
        let sigmaFloored = max(configuration.floorSpread, standardDeviation)
        let spread = sigmaFloored / 1.253
        return BaselineState(baseline: average, spread: spread, validCount: trailing.count, nightsSinceUpdate: 0, status: computeStatus(validCount: trailing.count, nightsSinceUpdate: 0))
    }

    public static func gapAwareEWMA(timesMilliseconds: [Double], values: [Double], halfLifeMilliseconds: Double, maximumGapMilliseconds: Double = 0) -> [EWMAPoint] {
        guard !values.isEmpty, values.count == timesMilliseconds.count else { return [] }
        var output: [EWMAPoint] = []
        output.reserveCapacity(values.count)
        var estimate: Double?
        var lastTime: Double?
        for index in values.indices {
            guard let existing = estimate else {
                estimate = values[index]
                lastTime = timesMilliseconds[index]
                output.append(EWMAPoint(value: values[index], isGap: false))
                continue
            }
            let delta = timesMilliseconds[index] - (lastTime ?? timesMilliseconds[index])
            guard delta > 0, halfLifeMilliseconds > 0, delta.isFinite else {
                output.append(EWMAPoint(value: existing, isGap: false))
                continue
            }
            var smoothing = 1 - pow(2, -delta / halfLifeMilliseconds)
            let gap = maximumGapMilliseconds > 0 && delta > maximumGapMilliseconds
            if gap { smoothing = min(smoothing, 0.5) }
            let next = smoothing * values[index] + (1 - smoothing) * existing
            estimate = next
            lastTime = timesMilliseconds[index]
            output.append(EWMAPoint(value: next, isGap: gap))
        }
        return output
    }

    public static func smallestWorthwhileChange(_ baseline: RobustBaseline, multiplier: Double = 0.2) -> Double? { baseline.scale.map { multiplier * $0 } }

    public static func minimalDetectableChange(_ baseline: RobustBaseline, typicalError: Double? = nil) -> Double? {
        let error = typicalError ?? baseline.scale
        guard let error, error > 0 else { return nil }
        return 1.96 * sqrt(2) * error
    }

    public static func changeExceedsMDC(delta: Double, baseline: RobustBaseline, typicalError: Double? = nil) -> Bool {
        guard let mdc = minimalDetectableChange(baseline, typicalError: typicalError) else { return false }
        return abs(delta) > mdc
    }
}
