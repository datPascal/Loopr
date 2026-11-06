import DesignSystem
import Foundation
import Observation
import SwiftUI
import TodayKit

@MainActor @Observable
final class HealthMetricPins {
    nonisolated static let key = "loopr.health.pins.v1" // gitleaks:allow
    nonisolated static let defaults: [MetricKey] = [.recovery, .rmssd, .restingHeartRate,
        .respiratoryRate, .skinTemperatureDeviation, .sleepConsistency, .steps]
    private(set) var metrics: [MetricKey]
    @ObservationIgnored private let storage: UserDefaults?

    /// - Parameter initial: Pins to start from instead of the stored ones. Fixture launches pass them.
    init(storage: UserDefaults? = .standard, initial: [MetricKey]? = nil) {
        self.storage = storage
        if let initial {
            metrics = Self.sanitized(initial)
        } else if let data = storage?.data(forKey: Self.key),
           let raw = try? JSONDecoder().decode([String].self, from: data) {
            metrics = Self.sanitized(raw.compactMap(MetricKey.init(rawValue:)))
        } else if let data = storage?.data(forKey: TodayPreferencesStore.key),
                  let legacy = try? JSONDecoder().decode(TodayPreferences.self, from: data) {
            metrics = Self.sanitized(legacy.pinned.compactMap { MetricKey(linkID: $0.linkID) })
        } else {
            metrics = Self.defaults
        }
        persist()
    }

    #if DEBUG
    /// `--loopr-health-pins=rmssd,recovery,…` pins those metrics in a fixture launch, so a UI test can show Today's
    /// pinned card. Nil without the argument.
    nonisolated static func fixturePins(_ arguments: [String] = ProcessInfo.processInfo.arguments) -> [MetricKey]? {
        guard let raw = arguments.first(where: { $0.hasPrefix("--loopr-health-pins=") })?
            .dropFirst("--loopr-health-pins=".count) else { return nil }
        return raw.split(separator: ",").compactMap { MetricKey(rawValue: String($0)) }
    }
    #endif

    nonisolated static func sanitized(_ values: [MetricKey]) -> [MetricKey] {
        var seen = Set<MetricKey>()
        return values.filter { seen.insert($0).inserted }
    }
    func contains(_ key: MetricKey) -> Bool { metrics.contains(key) }
    /// True when the pins are not the list every install starts with. Today shows a pinned card only then, so a
    /// person who never pinned anything sees the day, not a list they did not choose.
    var isCustomised: Bool { !metrics.isEmpty && metrics != Self.defaults }
    func toggle(_ key: MetricKey) {
        if contains(key) { metrics.removeAll { $0 == key } }
        else { metrics.append(key) }
        persist()
    }
    func move(_ key: MetricKey, by offset: Int) {
        guard let index = metrics.firstIndex(of: key), metrics.indices.contains(index + offset) else { return }
        metrics.swapAt(index, index + offset)
        persist()
    }
    private func persist() {
        guard let data = try? JSONEncoder().encode(metrics.map(\.rawValue)) else { return }
        storage?.set(data, forKey: Self.key)
    }
}

extension EnvironmentValues {
    @Entry var healthMetricPins: HealthMetricPins? = nil
}

nonisolated enum HealthMetricGroup: String, CaseIterable {
    case recovery = "Recovery", sleep = "Sleep", activity = "Activity", heart = "Heart"
    var metrics: [MetricKey] {
        switch self {
        case .recovery: [.recovery, .rmssd, .restingHeartRate, .respiratoryRate, .skinTemperatureDeviation, .oxygenSaturation]
        case .sleep: [.sleepPerformance, .sleepConsistency, .deepSleep, .sleepDebt, .sleepDuration, .sleepEfficiency, .remSleep]
        case .activity: [.strain, .steps, .activeEnergy, .vo2Max]
        case .heart: [.sleepingHeartRate, .heartRateDip, .sdnn, .pNN50, .maxHeartRate, .stress]
        }
    }
    func matching(_ query: String) -> [MetricKey] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return metrics }
        return metrics.filter { key in
            (key.presentation.title + " " + key.rawValue + " " +
             (key == .respiratoryRate ? "breathing" : "")).localizedCaseInsensitiveContains(query)
        }
    }
}
