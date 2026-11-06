import DesignSystem
import Foundation
import Observation

@MainActor @Observable
final class HealthMetricsModel {
    private(set) var history: [MetricKey: [MetricHistoryPoint]] = [:]
    private(set) var failures = Set<MetricKey>()
    private(set) var isLoading = true
    private var requestID = UUID()

    func load(keys: [MetricKey], provider: any MetricHistoryProviding, anchor: MetricDetailAnchor) async {
        let request = UUID(); requestID = request
        isLoading = true; history = [:]; failures = []
        for key in keys {
            do {
                let points = try await provider.series(for: key, days: 31, endingOn: anchor.endOfDay)
                guard !Task.isCancelled, requestID == request else { return }
                history[key] = points.filter { $0.value.isFinite && $0.day <= anchor.endOfDay }.sorted { $0.day < $1.day }
            } catch is CancellationError { return }
            catch {
                guard !Task.isCancelled, requestID == request else { return }
                failures.insert(key)
            }
        }
        isLoading = false
    }

    func reading(_ key: MetricKey, on day: Date) -> HealthMetricReading {
        HealthMetricReading(key: key, history: history[key] ?? [], day: day,
            state: isLoading ? .loading : failures.contains(key) ? .recoverableError : .partial)
    }
}

nonisolated struct HealthMetricReading {
    let key: MetricKey
    let value: Double?
    let points: [LooprChartPoint]
    let baseline: LooprBaselineBand?
    let state: MetricState
    let comparison: String?

    init(key: MetricKey, history: [MetricHistoryPoint], day: Date, state: MetricState) {
        self.key = key
        points = MetricTrendNarrative.chartPoints(history)
        let latest = history.last { Calendar.current.isDate($0.day, inSameDayAs: day) && $0.value.isFinite }
        value = latest?.value
        baseline = MetricTrendNarrative.baseline(points, today: day)
        self.state = latest == nil && state == .partial ? .absent : state
        if key == .steps || key == .activeEnergy {
            comparison = latest?.source == .band ? "Estimated" : nil
        } else if key == .oxygenSaturation, latest == nil {
            comparison = "This band does not report it"
        } else if let value, let baseline {
            comparison = switch baseline.position(of: value) {
            case .within: "Within your usual range"
            case .above, .below:
                LooprDelta.compare(value, usual: baseline, higherIsBetter: MetricDetailRules.higherIsBetter(key),
                    unit: MetricDetailRules.deltaUnit(key), format: MetricDetailRules.deltaFormat(key))?.text
            }
        } else if latest != nil {
            comparison = "Learning your usual range"
        } else {
            comparison = state == .recoverableError ? "Could not load this measurement" : nil
        }
    }

    var formatted: String? { value.map { key.presentation.value($0) } }
    var range: LooprContributorRange? { LooprContributorRange(value: value, band: baseline) }
}

struct HealthLoadRequest: Hashable {
    let keys: [MetricKey]
    let day: Date
}
