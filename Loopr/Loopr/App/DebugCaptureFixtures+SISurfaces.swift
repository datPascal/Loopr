#if DEBUG
import DesignSystem
import Foundation
import SharedSurfaceKit
import TodayKit

extension DebugCaptureFixtures {
    static var siSurfacesState: String? {
        let prefix = "--loopr-si-surfaces-state="
        return ProcessInfo.processInfo.arguments.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
    }
    static func siSurfacesSnapshot(state: String, now: Date) -> SurfaceSnapshot? {
        guard state != "empty" else { return nil }
        let previous = state == "stale"
        let source = previous ? now.addingTimeInterval(-86_400) : now
        let components = Calendar.current.dateComponents([.year, .month, .day], from: source)
        let score: Double? = state == "learning" || state == "flagged-unscored" ? nil : state == "flagged" ? 28 : state == "steady" ? 52 : SIPolishFixtureWorld.recovery
        return SurfaceSnapshot(generation: 1, createdAt: source,
            sourceDay: String(format: "%04d-%02d-%02d", components.year!, components.month!, components.day!),
            syncDate: source.addingTimeInterval(-300),
            metrics: .init(recovery: score, strain: LooprFixtureMetrics.today(LooprMetricLinkID.strain), heartRate: 51, hrv: 61, steps: 4200, sleepMinutes: LooprFixtureMetrics.today(LooprMetricLinkID.sleepDuration)),
            battery: .init(level: 0.74, observedAt: source), activeWorkout: nil, staleReasons: previous ? [.noRecentSync] : [],
            insight: .init(headline: state == "flagged" ? "Your overnight heart rate was above usual and HRV was below." : SIPolishFixtureWorld.headline,
                recoveryStyle: LooprDerivedDataPublisher.recoveryStyle(score: score),
                recoveryUnavailableReason: state == "flagged-unscored" ? "Recovery needs at least two overnight heart readings." : nil,
                nightsRecorded: state == "learning" ? 1 : nil, nightsNeeded: state == "learning" ? 4 : nil,
                sleepNeedMinutes: LooprFixtureMetrics.sleepNeedMinutes))
    }
}

/// Synthetic histories for empty, learning and outside-usual HR dip captures.
nonisolated struct SISurfacesMetricHistoryProvider: MetricHistoryProviding {
    let state: String
    func series(for key: MetricKey, days: Int, endingOn end: Date) async throws -> [MetricHistoryPoint] {
        guard state != "empty" else { return [] }
        let calendar = Calendar.current
        let count = state == "learning" ? 3 : min(days, 35)
        return (0..<count).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: calendar.startOfDay(for: end)) else { return nil }
            guard let base = Self.latestValue(for: key, state: offset == 0 ? state : "ready") else { return nil }
            return MetricHistoryPoint(day: date, value: base + (offset == 0 ? 0 : LooprFixtureMetrics.variation(seed: "si-" + key.rawValue, offset: offset) * 4), source: .band)
        }
    }

    static func latestValue(for key: MetricKey, state: String) -> Double? {
        guard state != "empty" else { return nil }
        return switch key {
        case .heartRateDip: state == "flagged" ? -4 : 17
        case .sleepingHeartRate: state == "flagged" ? 78 : 60
        case .maxHeartRate: state == "flagged" ? 190 : 160
        default: nil
        }
    }
}
#endif
