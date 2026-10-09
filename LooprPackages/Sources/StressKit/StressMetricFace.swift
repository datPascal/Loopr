import DesignSystem
import SwiftUI

/// The daily resting score and its context. The source does not record a
/// timestamp within the day, so the face names the measured day explicitly.
struct StressMetricFace: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let value: Double?
    let state: MetricState
    let day: Date?
    let confidence: Double?
    let usual: LooprBaselineBand?
    let measuredDays: Int

    var body: some View {
        LooprSurface(emphasis: .hero(.stress)) {
            VStack(alignment: .leading, spacing: LooprSpacing.md) {
                LooprText("RESTING STRESS", style: .sectionLabel, color: .inkSecondary)

                if let value, value.isFinite {
                    LooprValueText(
                        String(Int(value.rounded())),
                        unit: "/100",
                        valueStyle: .display,
                        unitStyle: .metricValue
                    )
                        .minimumScaleFactor(0.6)
                        .accessibilityIdentifier("stress-score-face")

                    if let delta = LooprDelta.compare(
                        value,
                        usual: usual,
                        higherIsBetter: nil,
                        learning: (measured: measuredDays, needed: LooprBaselineBand.minimumDays),
                        learningNoun: "days"
                    ) {
                        LooprDeltaCaption(
                            delta,
                            accent: .stress,
                            length: dynamicTypeSize.isAccessibilitySize ? .compact : .standard
                        )
                            .accessibilityIdentifier("stress-usual-delta")
                    }

                    if let usual {
                        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                            LooprTypicalRangeBar(value: value, typical: usual.lower...usual.upper, accent: .stress)
                            LooprText(
                                "Usual \(Int(usual.lower.rounded())) to \(Int(usual.upper.rounded())) from your last 30 days",
                                style: .caption,
                                color: .inkSecondary
                            )
                        }
                    }
                } else {
                    StateMessage(state, accent: .stress)
                }

                LooprText(sourceLine, style: .prose, color: .inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let confidence, confidence < 0.6, value != nil {
                    StatusChip("Limited signal", symbol: "waveform.path", tone: .neutral)
                }
            }
        }
        .accessibilityIdentifier("stress-metric-face")
    }

    private var sourceLine: String {
        guard let day else { return "From resting beat intervals recorded by your band." }
        return "From resting beat intervals on \(day.formatted(.dateTime.day().month(.abbreviated)))."
    }
}
