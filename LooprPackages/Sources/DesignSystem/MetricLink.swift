import Foundation
import SwiftUI

/// Lets any screen in any feature package open a metric's detail page and
/// read a short history for its sparkline, without knowing the app's routes
/// or history store. The app installs one at each navigation root; screens
/// check for it and fall back to their previous behaviour when it is absent.
///
/// Metric ids are the app's `MetricKey` raw values. Use `LooprMetricLinkID`
/// rather than string literals.
public struct LooprMetricLink: Sendable {
    public let open: @MainActor @Sendable (String) -> Void
    public let history: @Sendable (String, Int) async -> [LooprChartPoint]
    public let historyEndingOn: (@Sendable (String, Int, Date) async -> [LooprChartPoint])?
    public let supports: @Sendable (String) -> Bool

    public init(
        open: @escaping @MainActor @Sendable (String) -> Void,
        history: @escaping @Sendable (String, Int) async -> [LooprChartPoint],
        supports: @escaping @Sendable (String) -> Bool,
        historyEndingOn: (@Sendable (String, Int, Date) async -> [LooprChartPoint])? = nil
    ) {
        self.open = open
        self.history = history
        self.historyEndingOn = historyEndingOn
        self.supports = supports
    }
}

public extension EnvironmentValues {
    @Entry var looprMetricLink: LooprMetricLink? = nil
}

/// The metric ids feature packages link to. They match the app's `MetricKey`
/// raw values; an app test keeps the two lists in step.
public enum LooprMetricLinkID {
    public static let restingHeartRate = "resting_heart_rate"
    public static let rmssd = "rmssd"
    public static let sdnn = "sdnn"
    public static let pNN50 = "pnn50"
    public static let respiratoryRate = "respiratory_rate"
    public static let sleepingHeartRate = "sleeping_heart_rate"
    public static let heartRateDip = "heart_rate_dip"
    public static let oxygenSaturation = "oxygen_saturation"
    public static let skinTemperatureDeviation = "skin_temperature_deviation"
    public static let recovery = "recovery"
    public static let strain = "strain"
    public static let stress = "stress"
    public static let sleepDuration = "sleep_duration"
    public static let sleepEfficiency = "sleep_efficiency"
    public static let deepSleep = "deep_sleep"
    public static let remSleep = "rem_sleep"
    public static let sleepConsistency = "sleep_consistency"
    public static let vo2Max = "vo2_max"
    public static let maxHeartRate = "max_heart_rate"
    public static let activeEnergy = "active_energy"
    public static let steps = "steps"

    public static let all: [String] = [
        restingHeartRate, rmssd, sdnn, pNN50, respiratoryRate, sleepingHeartRate, heartRateDip,
        oxygenSaturation, skinTemperatureDeviation, recovery, strain, stress, sleepDuration,
        sleepEfficiency, deepSleep, remSleep, sleepConsistency, vo2Max, maxHeartRate, activeEnergy, steps
    ]
}
