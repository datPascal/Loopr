import DesignSystem
import SwiftUI

/// "What moves with this": the person's other metrics that rose and fell
/// with this one over the range on screen, in plain sentences, with the
/// reminder that moving together is not cause. Loads after the rest of the
/// page and says so quietly while it does.
struct MetricCorrelationSection: View {
    let key: MetricKey
    let state: MetricDetailModel.CorrelationState
    let range: LooprChartRange
    /// Whether a longer range than the one shown is available.
    var canWiden: Bool = true
    let accent: LooprColorToken
    /// Opens another metric's page; nil where no link is installed.
    let open: ((MetricKey) -> Void)?

    static let causationNote = "These move together. That does not mean one causes the other."

    var body: some View {
        if state != .waiting {
            VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                MetricDetailEyebrow("What moves with this")
                content
                    .padding(LooprSpacing.formCardPadding)
                    .modifier(MetricDetailCardBackground())
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("metric-detail-correlations")
            .animation(.snappy(duration: LooprMotion.standard), value: state)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .waiting:
            EmptyView()
        case .loading:
            HStack(spacing: LooprSpacing.sm) {
                ProgressView()
                    .controlSize(.small)
                LooprText("Comparing with your other numbers", style: .prose, color: .inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("metric-detail-correlations-loading")
        case .tooFewDays(let measured):
            note(Self.tooFewText(measured: measured, range: range, canWiden: canWiden, noun: MetricDetailRules.countNoun(for: key)))
                .accessibilityIdentifier("metric-detail-correlations-few")
        case .loaded(let found) where found.isEmpty:
            note("Nothing else moved clearly with \(MetricCorrelations.name(key)) in the last \(range.spokenTitle).")
                .accessibilityIdentifier("metric-detail-correlations-none")
        case .loaded(let found):
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(found.enumerated()), id: \.element.id) { index, correlation in
                    if index > 0 { MetricDetailHairline().padding(.vertical, LooprSpacing.sm) }
                    row(correlation)
                }
                MetricDetailHairline().padding(.top, LooprSpacing.sm)
                LooprText(Self.causationNote, style: .caption, color: .inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, LooprSpacing.sm)
                    .accessibilityIdentifier("metric-detail-correlations-note")
            }
        }
    }

    static func tooFewText(measured: Int, range: LooprChartRange, canWiden: Bool, noun: LooprCountNoun) -> String {
        let needed = MetricCorrelations.minimumPairedDays
        if range == .week, canWiden {
            return "A week is too short to see what moves together. Pick 30D or longer."
        }
        if range == .week {
            return "Loopr looks for patterns once it has \(needed) \(noun.plural) with readings. It has \(measured) so far."
        }
        return "Loopr looks for patterns once this range holds \(needed) \(noun.plural) with readings. It has \(measured) so far."
    }

    private func note(_ text: String) -> some View {
        LooprText(text, style: .prose, color: .inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func row(_ correlation: MetricCorrelation) -> some View {
        let rowContent = HStack(alignment: .center, spacing: LooprSpacing.sm) {
            VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                LooprText(correlation.other.presentation.title, style: .rowTitle)
                LooprText(MetricCorrelations.sentence(correlation, target: key), style: .prose, color: .inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                LooprText(MetricCorrelations.caption(correlation), style: .caption, color: .inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            MetricCorrelationBar(r: correlation.r, accent: correlation.other.presentation.accent)
            if open != nil { LooprChevron() }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(MetricCorrelations.spoken(correlation, target: key))
        .accessibilityIdentifier("metric-detail-correlation-\(correlation.other.rawValue)")
        if let open {
            Button { open(correlation.other) } label: { rowContent }
                .buttonStyle(.plain)
                .accessibilityAddTraits(.isButton)
        } else {
            rowContent
        }
    }
}

/// A small signed bar for r: from the centre to the right when the two rise
/// together, to the left when one rises as the other falls.
struct MetricCorrelationBar: View {
    let r: Double
    let accent: LooprColorToken

    private let width: CGFloat = 44

    var body: some View {
        let half = width / 2
        let length = max(CGFloat(min(abs(r), 1)) * half, 2)
        ZStack(alignment: .leading) {
            Capsule().fill(Color.loopr(.ink).opacity(0.08)).frame(width: width, height: 6)
            Capsule()
                .fill(Color.loopr(accent))
                .frame(width: length, height: 6)
                .offset(x: r >= 0 ? half : half - length)
            Rectangle().fill(Color.loopr(.inkSecondary)).frame(width: 1, height: 10).offset(x: half - 0.5)
        }
        .frame(width: width, height: 10)
        .accessibilityHidden(true)
    }
}
