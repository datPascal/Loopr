import Foundation

public struct HabitTodayCandidate: Equatable, Sendable {
    public let estimate: HabitImpactEstimate
    public let metric: HabitMetricEstimate

    public init(estimate: HabitImpactEstimate, metric: HabitMetricEstimate) {
        self.estimate = estimate
        self.metric = metric
    }
}

public enum HabitTodaySelectionPolicy {
    public static let retentionInterval: TimeInterval = 7 * 24 * 60 * 60

    public static func candidate(for estimate: HabitImpactEstimate) -> HabitTodayCandidate? {
        guard [.clearAssociation, .noClearAssociation].contains(estimate.status) else { return nil }
        if let recovery = estimate.metric(.recoveryScore), recovery.isClear {
            return HabitTodayCandidate(estimate: estimate, metric: recovery)
        }
        guard let secondary = HabitOutcomeMetricID.allCases
            .filter({ $0 != .recoveryScore })
            .compactMap({ estimate.metric($0) })
            .first(where: \.isClear) else { return nil }
        return HabitTodayCandidate(estimate: estimate, metric: secondary)
    }

    public static func ranked(_ estimates: [HabitImpactEstimate]) -> [HabitTodayCandidate] {
        estimates.compactMap(candidate(for:)).sorted(by: precedes)
    }

    public static func shouldRetain(_ selection: HabitTodaySelection, at now: Date) -> Bool {
        let age = now.timeIntervalSince(selection.selectedAt)
        return age >= 0 && age < retentionInterval
    }

    private static func precedes(_ lhs: HabitTodayCandidate, _ rhs: HabitTodayCandidate) -> Bool {
        let lhsMetric = HabitOutcomeMetricID.allCases.firstIndex(of: lhs.metric.metricID) ?? .max
        let rhsMetric = HabitOutcomeMetricID.allCases.firstIndex(of: rhs.metric.metricID) ?? .max
        if lhsMetric != rhsMetric { return lhsMetric < rhsMetric }
        let lhsWidth = relativeIntervalWidth(lhs.metric)
        let rhsWidth = relativeIntervalWidth(rhs.metric)
        if lhsWidth != rhsWidth { return lhsWidth < rhsWidth }
        if lhs.estimate.calculatedAt != rhs.estimate.calculatedAt {
            return lhs.estimate.calculatedAt > rhs.estimate.calculatedAt
        }
        return lhs.estimate.habitID < rhs.estimate.habitID
    }

    private static func relativeIntervalWidth(_ estimate: HabitMetricEstimate) -> Double {
        guard let lower = estimate.intervalLower, let upper = estimate.intervalUpper,
              let effect = estimate.adjustedDifference else { return .infinity }
        return abs(upper - lower) / max(abs(effect), 0.000_001)
    }
}
