#if DEBUG
import DesignSystem
import Foundation
import HeartKit

/// Deterministic synthetic history for previews, UI tests and screenshots.
/// Compiled into Debug builds only, and used only when a test or preview asks
/// for it, so production can never show these numbers.
///
/// The numbers come from `LooprFixtureMetrics`, the same source the tab
/// fixtures use, so every page ends on the value its tab shows.
nonisolated struct FixtureMetricHistoryProvider: MetricHistoryProviding {
    static let launchArgument = "--loopr-metric-history-fixture"

    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArgument)
    }

    /// Keys that return no history, so the empty state stays covered. Loopr
    /// does not calculate either.
    static var emptyKeys: Set<MetricKey> {
        Set(MetricKey.allCases.filter { LooprFixtureMetrics.emptyIDs.contains($0.rawValue) })
    }

    var calendar: Calendar = .current

    func series(for key: MetricKey, days: Int, endingOn: Date) async throws -> [MetricHistoryPoint] {
        if key == .skinTemperatureDeviation, DebugCaptureFixtures.siVitalsMode != nil {
            return DebugCaptureFixtures.siVitalsSeries(days: days, endingOn: endingOn, calendar: calendar)
        }
        if let points = DebugCaptureFixtures.siVitalsRecoverySeries(for: key, days: days, endingOn: endingOn, calendar: calendar) {
            return points
        }
        if let points = DebugCaptureFixtures.siBodyMetricPoints(key: key, days: days, endingOn: endingOn, calendar: calendar) {
            return points
        }
        return Self.points(for: key, days: days, endingOn: endingOn, calendar: calendar)
    }

    func skinTemperature(endingOn: Date) async throws -> HeartSkinTemperatureVital? {
        DebugCaptureFixtures.siVitalsVital(endingOn: endingOn, calendar: calendar)
    }

    static func points(for key: MetricKey, days: Int, endingOn: Date, calendar: Calendar = .current) -> [MetricHistoryPoint] {
        let last = calendar.startOfDay(for: endingOn)
        return LooprFixtureMetrics.history(key.rawValue, days: days, endingOn: endingOn, calendar: calendar).map { point in
            let offset = calendar.dateComponents([.day], from: calendar.startOfDay(for: point.date), to: last).day ?? 0
            return MetricHistoryPoint(
                day: point.date,
                value: point.value,
                source: source(for: key, offset: offset),
                low: point.low,
                high: point.high
            )
        }
    }

    /// VO2 max and oxygen come from Apple Health; older steps too, so the
    /// "Data source" section shows a mix.
    private static func source(for key: MetricKey, offset: Int) -> MetricSampleSource {
        if key == .vo2Max || key == .oxygenSaturation { return .appleHealth }
        if key == .steps, offset > 300 { return .appleHealth }
        return .band
    }
}
#endif
