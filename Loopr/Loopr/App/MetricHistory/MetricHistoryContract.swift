import Foundation
import HeartKit
import SwiftUI

// Shared contract between the metric-history data layer and the metric detail screens.
// Both sides code against these types only; keep changes additive.

/// Every metric that gets a persisted daily history and a detail page.
nonisolated enum MetricKey: String, CaseIterable, Codable, Hashable, Sendable {
    case restingHeartRate = "resting_heart_rate"
    case rmssd
    case sdnn
    case pNN50 = "pnn50"
    case respiratoryRate = "respiratory_rate"
    case sleepingHeartRate = "sleeping_heart_rate"
    case heartRateDip = "heart_rate_dip"
    case oxygenSaturation = "oxygen_saturation"
    case skinTemperatureDeviation = "skin_temperature_deviation"
    case recovery
    case strain
    case stress
    case sleepDuration = "sleep_duration"
    case sleepEfficiency = "sleep_efficiency"
    case deepSleep = "deep_sleep"
    case remSleep = "rem_sleep"
    case sleepConsistency = "sleep_consistency"
    case vo2Max = "vo2_max"
    case maxHeartRate = "max_heart_rate"
    case activeEnergy = "active_energy"
    case steps
}

/// Where a history value came from. Band-derived values win over Apple Health for the same day.
nonisolated enum MetricSampleSource: String, Codable, Hashable, Sendable {
    case band
    case appleHealth = "apple_health"
    case whoopExport = "whoop_export"
}

/// One day of one metric. `day` is the local start of day.
/// `low`/`high` are optional within-day extremes for range bars.
nonisolated struct MetricHistoryPoint: Hashable, Sendable {
    var day: Date
    var value: Double
    var source: MetricSampleSource
    var low: Double?
    var high: Double?

    init(day: Date, value: Double, source: MetricSampleSource, low: Double? = nil, high: Double? = nil) {
        self.day = day
        self.value = value
        self.source = source
        self.low = low
        self.high = high
    }
}

/// Reads daily history. Points are ascending by day, at most one per day, absent days omitted.
nonisolated protocol MetricHistoryProviding: Sendable {
    func series(for key: MetricKey, days: Int, endingOn: Date) async throws -> [MetricHistoryPoint]
    func skinTemperature(endingOn: Date) async throws -> HeartSkinTemperatureVital?
}

nonisolated extension MetricHistoryProviding {
    func skinTemperature(endingOn: Date) async throws -> HeartSkinTemperatureVital? { nil }
}

/// Default provider: no history. Screens must render an honest empty state with it.
nonisolated struct EmptyMetricHistoryProvider: MetricHistoryProviding {
    func series(for key: MetricKey, days: Int, endingOn: Date) async throws -> [MetricHistoryPoint] { [] }
}

extension EnvironmentValues {
    /// Injected at the app root by the history layer; screens read it.
    @Entry var metricHistoryProvider: any MetricHistoryProviding = EmptyMetricHistoryProvider()
}
