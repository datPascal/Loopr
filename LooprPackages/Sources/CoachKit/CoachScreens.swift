import SwiftUI
import DesignSystem

public struct CoachScreen: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var viewModel: CoachViewModel

    public init(viewModel: CoachViewModel) { self.viewModel = viewModel }

    public var body: some View {
        LooprDetailScaffold {
            content
        }
        .navigationTitle("Local coach")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(LooprAppearance.isDark(colorScheme) ? .dark : .light, for: .navigationBar)
        .tint(Color.loopr(.brand))
        .accessibilityIdentifier("coach-screen")
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.loadState {
        case .idle:
            stateSurface(
                state: .noRecords,
                label: "No records yet",
                symbol: MetricState.noRecords.symbol,
                explanation: "A plan appears once readiness, sleep, and strain measurements are available with enough confidence."
            )
        case .loading:
            loadingSurface
        case .failed(let message):
            failureSurface(message: message)
        case .loaded:
            if let decision = viewModel.decision {
                decisionContent(decision)
            } else {
                stateSurface(
                    state: .absent,
                    label: "No plan returned",
                    symbol: MetricState.absent.symbol,
                    explanation: "No action is available until the coach returns a result from the current evidence."
                )
            }
        }

        if !viewModel.history.isEmpty {
            historySection
        }
    }

    private var loadingSurface: some View {
        LooprSectionGroup(title: "Plan") {
            LooprSurface(emphasis: .hero(.brand)) {
                VStack(alignment: .leading, spacing: LooprSpacing.md) {
                    surfaceHeader(label: MetricState.loading.title, symbol: MetricState.loading.symbol)
                    StateMessage(.loading)
                    LooprSkeleton(height: LooprSpacing.md)
                    LooprSkeleton(height: LooprSpacing.xl)
                }
            }
        }
    }

    private func stateSurface(
        state: MetricState,
        label: String,
        symbol: String,
        explanation: String
    ) -> some View {
        LooprSectionGroup(title: "Plan") {
            LooprSurface(emphasis: .hero(.brand)) {
                VStack(alignment: .leading, spacing: LooprSpacing.md) {
                    surfaceHeader(label: label, symbol: symbol)
                    StateMessage(state)
                    LooprInlineMessage(explanation, tone: .brand)
                }
            }
        }
    }

    private func failureSurface(message: String) -> some View {
        LooprSectionGroup(title: "Plan") {
            LooprSurface(emphasis: .hero(.brand)) {
                VStack(alignment: .leading, spacing: LooprSpacing.md) {
                    surfaceHeader(label: MetricState.recoverableError.title, symbol: MetricState.recoverableError.symbol)
                    StateMessage(.recoverableError)
                    LooprInlineMessage(failureDetail(message), tone: .warning)
                    Button("Try again") {
                        Task { await viewModel.reload() }
                    }
                    .buttonStyle(LooprButtonStyle(prominent: false))
                    .accessibilityIdentifier("coach-retry")
                }
            }
        }
    }

    @ViewBuilder
    private func decisionContent(_ decision: CoachDecision) -> some View {
        switch decision {
        case .plan(let plan):
            planContent(plan)
        case .abstain(let abstention):
            abstentionContent(abstention)
        }
    }

    @ViewBuilder
    private func planContent(_ plan: CoachPlan) -> some View {
        if plan.recommendations.isEmpty {
            stateSurface(
                state: .absent,
                label: "No actions",
                symbol: MetricState.absent.symbol,
                explanation: "The coach returned no action for the current evidence."
            )
        } else {
            LooprSectionGroup(title: "Plan") {
                planOverview
            }

            LooprSectionGroup(title: "Actions") {
                VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                    ForEach(Array(plan.recommendations.enumerated()), id: \.element.id) { index, recommendation in
                        recommendationCard(
                            recommendation,
                            order: index,
                            planEvidence: plan.evidence
                        )
                    }
                }
            }

            LooprSectionGroup(title: "Evidence") {
                evidenceContent(plan)
            }
        }
    }

    private var planOverview: some View {
        LooprSurface(emphasis: .hero(.brand)) {
            VStack(alignment: .leading, spacing: LooprSpacing.md) {
                surfaceHeader(label: "Plan ready", symbol: "checkmark.circle")
                LooprText("Your plan", style: .titleLarge)
                LooprText(
                    "Each action is linked to the evidence that supports it.",
                    style: .prose,
                    color: .inkSecondary
                )
            }
        }
    }

    private func recommendationCard(
        _ recommendation: CoachRecommendation,
        order: Int,
        planEvidence: [CoachEvidence]
    ) -> some View {
        let evidence = linkedEvidence(for: recommendation, in: planEvidence)

        return LooprSurface {
            VStack(alignment: .leading, spacing: LooprSpacing.md) {
                HStack(alignment: .top, spacing: LooprSpacing.sm) {
                    LooprText(orderLabel(order), style: .metricValue, color: .brand)
                        .frame(minWidth: LooprSpacing.xl, alignment: .leading)

                    VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                        HStack(alignment: .top, spacing: LooprSpacing.sm) {
                            StatusChip(
                                recommendation.kind.displayName,
                                symbol: symbol(for: recommendation.kind),
                                tone: .brand,
                                accent: .brand
                            )

                            Spacer(minLength: LooprSpacing.sm)

                            LooprText(
                                confidenceLabel(recommendation.confidence),
                                style: .confidence,
                                color: .brand
                            )
                            .multilineTextAlignment(.trailing)
                            .fixedSize(horizontal: false, vertical: true)
                        }

                        LooprText(recommendation.title, style: .cardTitle)
                        LooprText(recommendation.detail, style: .prose, color: .inkSecondary)
                    }
                }

                LooprHairline()
                evidenceLine(for: recommendation, matchedEvidence: evidence)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(recommendationAccessibilityLabel(recommendation, order: order, evidence: evidence))
    }

    @ViewBuilder
    private func evidenceLine(
        for recommendation: CoachRecommendation,
        matchedEvidence: [CoachEvidence]
    ) -> some View {
        let labels = matchedEvidence.isEmpty
            ? recommendation.evidence.map(\.displayName)
            : matchedEvidence.map(\.label)

        if labels.isEmpty {
            LooprInlineMessage("Evidence for this action is not listed.", tone: .warning)
        } else {
            VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                LooprText("EVIDENCE", style: .sectionLabel, color: .inkSecondary)
                LooprText(labels.joined(separator: " · ").uppercased(), style: .confidence, color: .inkSecondary)
            }
        }
    }

    @ViewBuilder
    private func evidenceContent(_ plan: CoachPlan) -> some View {
        let evidence = linkedEvidence(for: plan)

        if evidence.isEmpty {
            LooprFormCard {
                LooprInlineMessage("No measurements were listed for this plan.", tone: .warning)
            }
        } else {
            VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                LooprText(
                    "Measurements supporting the actions above.",
                    style: .prose,
                    color: .inkSecondary
                )
                HairlineMetricList(rows: evidence.map(evidenceRow))
            }
        }
    }

    private func abstentionContent(_ abstention: CoachAbstention) -> some View {
        LooprSectionGroup(title: "Plan") {
            LooprSurface(emphasis: .hero(.brand)) {
                VStack(alignment: .leading, spacing: LooprSpacing.md) {
                    surfaceHeader(label: "Waiting for evidence", symbol: "pause.circle")
                    StateMessage(.partial)
                    LooprInlineMessage(abstention.reason, tone: .brand)
                    LooprText(
                        "A plan appears once \(planRequirement(for: abstention.missingEvidence)) are available with enough confidence.",
                        style: .prose,
                        color: .inkSecondary
                    )
                }
            }
        }
    }

    private var historySection: some View {
        LooprSectionGroup(title: "History") {
            LooprFormCard(padding: LooprSpacing.none) {
                VStack(spacing: LooprSpacing.none) {
                    ForEach(Array(viewModel.history.enumerated()), id: \.offset) { index, decision in
                        historyRow(decision)
                        if index < viewModel.history.count - 1 {
                            LooprHairline()
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func historyRow(_ decision: CoachDecision) -> some View {
        switch decision {
        case .plan(let plan):
            LooprRow(title: plan.recommendations.first?.title ?? "No actions", subtitle: "Plan available", symbol: "checkmark.circle") {
                StatusChip("Plan", symbol: "checkmark.circle", tone: .brand, accent: .brand)
            }
        case .abstain:
            LooprRow(title: "No plan", subtitle: "Waiting for more evidence", symbol: "pause.circle") {
                StatusChip("Waiting", symbol: "pause.circle", tone: .brand, accent: .brand)
            }
        }
    }

    private func surfaceHeader(label: String, symbol: String) -> some View {
        HStack(alignment: .center, spacing: LooprSpacing.sm) {
            StatusChip(label, symbol: symbol, tone: .brand, accent: .brand)
            Spacer(minLength: LooprSpacing.sm)
            StatusChip("On device", symbol: "iphone", tone: .brand, accent: .brand)
        }
    }

    private func linkedEvidence(for recommendation: CoachRecommendation, in evidence: [CoachEvidence]) -> [CoachEvidence] {
        recommendation.evidence.compactMap { id in
            evidence.first { $0.id == id }
        }
    }

    private func linkedEvidence(for plan: CoachPlan) -> [CoachEvidence] {
        var ids: [CoachEvidenceID] = []
        for recommendation in plan.recommendations {
            for id in recommendation.evidence where !ids.contains(id) {
                ids.append(id)
            }
        }
        return plan.evidence.filter { ids.contains($0.id) }
    }

    private func evidenceRow(_ evidence: CoachEvidence) -> HairlineMetricRow {
        let showsValue = evidence.isUsable && evidence.value != nil
        return HairlineMetricRow(
            id: "coach-evidence-\(evidence.id.rawValue)",
            title: evidence.label,
            confidence: confidenceLabel(evidence.confidence),
            value: showsValue ? evidence.value!.formatted() : evidence.state.title,
            unit: showsValue && !evidence.unit.isEmpty ? evidence.unit : nil
        )
    }

    private func recommendationAccessibilityLabel(
        _ recommendation: CoachRecommendation,
        order: Int,
        evidence: [CoachEvidence]
    ) -> String {
        let evidenceLabels = evidence.isEmpty
            ? recommendation.evidence.map(\.displayName)
            : evidence.map(\.label)
        let evidenceText = evidenceLabels.isEmpty
            ? "Evidence not listed"
            : evidenceLabels.joined(separator: ", ")
        return "Step \(order + 1), \(recommendation.title). \(recommendation.detail). \(confidenceLabel(recommendation.confidence)). Based on \(evidenceText)."
    }

    private func planRequirement(for ids: [CoachEvidenceID]) -> String {
        let names = ids.map(\.displayName)
        guard !names.isEmpty else { return "the required measurements" }
        return names.joined(separator: ", ") + " measurements"
    }

    private func failureDetail(_ message: String) -> String {
        message.isEmpty
            ? "The local coach could not load. Return to Today and open it again."
            : message
    }

    private func confidenceLabel(_ confidence: Double) -> String {
        guard confidence.isFinite else { return "CONFIDENCE UNAVAILABLE" }
        let percentage = Int((min(max(confidence, 0), 1) * 100).rounded())
        return "\(percentage)% CONFIDENCE"
    }

    private func orderLabel(_ order: Int) -> String {
        let value = order + 1
        return value < 10 ? "0\(value)" : "\(value)"
    }

    private func symbol(for kind: CoachRecommendationKind) -> String {
        switch kind {
        case .rest: "bed.double"
        case .sleep: "moon.stars"
        case .recovery: "heart"
        case .load: "chart.bar"
        case .workout: "figure.run"
        }
    }
}
