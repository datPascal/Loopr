import DesignSystem
import Foundation
import JournalKit
import SwiftUI

extension EnvironmentValues {
    @Entry var metricHabitStore: (any HabitStore)? = nil
}

nonisolated extension MetricKey {
    var habitOutcome: HabitOutcomeMetricID? {
        switch self {
        case .recovery: .recoveryScore
        case .rmssd: .hrvRMSSD
        case .restingHeartRate: .restingHeartRate
        case .sleepDuration: .sleepDuration
        case .sleepEfficiency: .sleepEfficiency
        case .sleepConsistency: .sleepConsistency
        default: nil
        }
    }
}

nonisolated struct MetricHabitAssociation: Identifiable, Sendable {
    var id: HabitID { definition.id }
    let definition: HabitDefinition
    let estimate: HabitImpactEstimate
    let metric: HabitMetricEstimate
    let difference: Double

    static func select(key: MetricKey, definitions: [HabitDefinition], estimates: [HabitImpactEstimate],
                       through day: String, stage: HabitFeatureStage) -> [Self] {
        guard stage.exposesEntryPoints, let target = key.habitOutcome else { return [] }
        let active = Dictionary(uniqueKeysWithValues: definitions.filter { !$0.isArchived }.map { ($0.id, $0) })
        return estimates.compactMap { estimate -> Self? in
            guard let definition = active[estimate.habitID], estimate.windowEnd.habitKey <= day,
                  let metric = estimate.metric(target),
                  [.clearAssociation, .noClearAssociation, .enoughData, .earlySignal].contains(metric.sample?.status ?? estimate.status),
                  let difference = metric.adjustedDifference,
                  difference.isFinite, metric.adjustedRowCount > 0 else { return nil }
            return Self(definition: definition, estimate: estimate, metric: metric, difference: difference)
        }.sorted {
            if $0.metric.isClear != $1.metric.isClear { return $0.metric.isClear }
            return $0.definition.sortOrder < $1.definition.sortOrder
        }
    }

    var effectDescription: String {
        let unit = switch metric.metricID.unit {
        case .scorePoints: "points"
        case .milliseconds: "ms"
        case .beatsPerMinute: "bpm"
        case .minutes: "min"
        case .percentagePoints: "percentage points"
        }
        let amount = abs(difference).formatted(.number.precision(.fractionLength(1)).locale(LooprUnitFormatter.displayLocale))
        let effect = difference == 0 ? "No difference" : "\(amount) \(unit) \(difference > 0 ? "higher" : "lower")"
        return "\(effect) after days you answered Yes."
    }

    var evidence: String { "\(metric.isClear ? "Clear association" : "No clear association") · \(metric.adjustedRowCount) nights" }
    var explanation: String { effectDescription + " " + evidence + "." }
}

private struct MetricHabitSelection: Hashable, Identifiable { let id: HabitID }

struct MetricHabitSection: View {
    @Environment(\.metricHabitStore) private var store
    @State private var rows: [MetricHabitAssociation] = []
    @State private var loading = true
    @State private var failed = false
    @State private var requestID = UUID()
    @State private var selection: MetricHabitSelection?
    let key: MetricKey
    let day: String

    var body: some View {
        if AppHabitFeatureGate.currentStage.exposesEntryPoints {
            VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                LooprSectionHeader("What moves with this", detail: "From your Protocol check-in answers")
                if loading {
                    LooprCard { StateMessage(.loading, compact: true) }
                } else if failed {
                    LooprCard { StateMessage(.recoverableError) }
                } else if rows.isEmpty {
                    LooprCard {
                        VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                            StatusChip("No comparison yet", symbol: "chart.bar", accent: key.presentation.accent)
                            LooprText(key.habitOutcome == nil
                                ? "Check-in answers are not compared with this measurement."
                                : "Keep answering your Protocol check-in. A comparison needs enough nights with Yes and No answers.",
                                style: .prose, color: .inkSecondary)
                        }
                    }
                } else {
                    let scale = rows.map { abs($0.difference) }.max() ?? 1
                    LooprCard {
                        VStack(spacing: 0) {
                            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                                LooprAssociationRow(title: row.definition.name, detail: row.effectDescription,
                                    evidence: row.evidence, share: scale > 0 ? row.difference / scale : 0,
                                    accent: key.presentation.accent, identifier: "metric-habit-\(row.id.rawValue.uuidString)") {
                                        selection = .init(id: row.id)
                                    }
                                if index < rows.count - 1 { LooprHairline() }
                            }
                        }
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("metric-detail-habits")
            .task(id: day + (store == nil ? "-empty" : "-ready")) { await load() }
            .navigationDestination(item: $selection) { selection in
                if let store { MetricHabitDetail(store: store, habitID: selection.id) }
            }
        }
    }

    private func load() async {
        guard AppHabitFeatureGate.currentStage.exposesEntryPoints else { return }
        let request = UUID(); requestID = request
        loading = true; failed = false
        defer { if requestID == request { loading = false } }
        guard let store else { rows = []; return }
        do {
            let definitions = try await store.definitions(includeArchived: false)
            let estimates = try await store.estimates()
            guard !Task.isCancelled, requestID == request else { return }
            rows = MetricHabitAssociation.select(key: key, definitions: definitions, estimates: estimates,
                through: day, stage: AppHabitFeatureGate.currentStage)
        } catch is CancellationError { return }
        catch {
            guard !Task.isCancelled, requestID == request else { return }
            failed = true
        }
    }
}

private struct MetricHabitDetail: View {
    @StateObject private var model: HabitViewModel
    let habitID: HabitID
    init(store: any HabitStore, habitID: HabitID) {
        self.habitID = habitID
        _model = StateObject(wrappedValue: HabitViewModel(store: store, featureStageOverride: AppHabitFeatureGate.currentStage))
    }
    var body: some View {
        HabitDetailScreen(viewModel: model, habitID: habitID)
            .looprAskToolbar(origin: "Journal comparison")
            .task { await model.load() }
    }
}
