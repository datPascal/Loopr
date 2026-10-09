import Foundation

/// The unit every stored `MetricHistoryPoint.value` of a key is in.
///
/// Band values and Apple Health values are converted to this unit before they
/// are stored, so a chart never has to know where a point came from.
/// Additive to the contract in `MetricHistoryContract.swift`.
nonisolated enum MetricHistoryUnit: String, Sendable {
    case beatsPerMinute = "bpm"
    case milliseconds = "ms"
    /// 0...100.
    case percent = "%"
    case breathsPerMinute = "br/min"
    case minutes = "min"
    /// A 0...100 Loopr score.
    case score = "score"
    /// The 0...21 strain scale.
    case strainScale = "/21"
    /// Degrees Celsius relative to the person's own baseline.
    case celsiusDeviation = "°C"
    case millilitresPerKilogramMinute = "mL/kg/min"
    case kilocalories = "kcal"
    case count = "count"
}

nonisolated extension MetricKey {
    /// The unit of this key's stored history values.
    var historyUnit: MetricHistoryUnit {
        switch self {
        case .restingHeartRate, .sleepingHeartRate, .maxHeartRate: .beatsPerMinute
        case .rmssd, .sdnn: .milliseconds
        case .pNN50, .heartRateDip, .oxygenSaturation, .sleepEfficiency: .percent
        case .respiratoryRate: .breathsPerMinute
        case .skinTemperatureDeviation: .celsiusDeviation
        case .recovery, .stress, .sleepConsistency: .score
        case .strain: .strainScale
        case .sleepDuration, .deepSleep, .remSleep: .minutes
        case .vo2Max: .millilitresPerKilogramMinute
        case .activeEnergy: .kilocalories
        case .steps: .count
        }
    }
}
