import SwiftUI
import Charts
import AnalyticsKit
import DesignSystem

/// A descriptive view of last night's beat intervals. It reports shape and
/// spread only and draws no conclusion from them.
public struct HeartBeatToBeatSection: View {
    private let summary: BeatToBeatSummary?

    public init(summary: BeatToBeatSummary?) { self.summary = summary }

    public var body: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.sm) {
            LooprText("BEAT TO BEAT", style: .sectionLabel, color: .inkSecondary)
                .accessibilityLabel("Beat to beat")
            if let summary {
                LooprText("A longer beat interval means a slower heart rate. Spread describes how much the timing varied.",
                          style: .caption, color: .inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HairlineMetricList(rows: [
                    HairlineMetricRow(id: "heart-beat-sd1", title: "Short-term spread (SD1)",
                        value: String(format: "%.0f", summary.sd1Milliseconds), unit: "ms"),
                    HairlineMetricRow(id: "heart-beat-sd2", title: "Long-term spread (SD2)",
                        value: String(format: "%.0f", summary.sd2Milliseconds), unit: "ms"),
                    HairlineMetricRow(id: "heart-beat-mean", title: "Average beat interval",
                        confidence: "\(summary.beatCount.formatted(.number)) clean beats",
                        value: String(format: "%.0f", summary.meanIntervalMilliseconds), unit: "ms")
                ])
                HeartPoincarePlot(summary: summary)
                if summary.tachogram.count >= 2 {
                    HeartTachogram(points: summary.tachogram)
                }
            } else {
                LooprSurface {
                    LooprText("Sleep with your band on to see how the time between your heartbeats changed overnight.",
                              style: .prose, color: .inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("heart-beat-to-beat-section")
    }
}

private struct HeartPoincarePlot: View {
    let summary: BeatToBeatSummary

    private var domain: ClosedRange<Int> {
        let values = summary.points.flatMap { [$0.current, $0.next] }
        let low = (values.min() ?? 600) - 20, high = (values.max() ?? 1_200) + 20
        return low...max(high, low + 1)
    }

    var body: some View {
        LooprSurface {
            VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                LooprText("Each beat against the next", style: .cardTitle)
                LooprText("Each dot pairs one interval between heartbeats with the one after it. A cloud that is wider across the diagonal means more change from beat to beat.",
                          style: .prose, color: .inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Chart(Array(summary.points.enumerated()), id: \.offset) { _, point in
                    PointMark(x: .value("Interval", point.current), y: .value("Next interval", point.next))
                        .foregroundStyle(Color.loopr(.heart).opacity(0.45))
                        .symbolSize(10)
                }
                .chartXScale(domain: domain, range: .plotDimension(startPadding: LooprSpacing.md, endPadding: LooprSpacing.md))
                .chartYScale(domain: domain, range: .plotDimension(startPadding: LooprSpacing.md, endPadding: LooprSpacing.md))
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 1))
                            .foregroundStyle(Color.loopr(.divider))
                        AxisValueLabel {
                            Text(value.as(Double.self).map { String(format: "%.0f", $0) } ?? "").looprTypography(.confidence).foregroundStyle(Color.loopr(.inkMuted)).fixedSize()
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 1, dash: [2, 4]))
                            .foregroundStyle(Color.loopr(.divider))
                        AxisValueLabel {
                            Text(value.as(Double.self).map { String(format: "%.0f", $0) } ?? "").looprTypography(.confidence).foregroundStyle(Color.loopr(.inkMuted)).fixedSize()
                        }
                    }
                }
                .aspectRatio(1, contentMode: .fit)
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                LooprText("MS, THIS INTERVAL AGAINST THE NEXT", style: .confidence, color: .inkSecondary)
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Beat interval plot, \(summary.points.count) points. Short-term spread \(Int(summary.sd1Milliseconds.rounded())) milliseconds, long-term spread \(Int(summary.sd2Milliseconds.rounded())) milliseconds. A wider cloud across the diagonal means more change from beat to beat.")
        .accessibilityIdentifier("heart-beat-poincare")
    }
}

private struct HeartTachogram: View {
    let points: [TachogramPoint]

    var body: some View {
        LooprSurface {
            VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                LooprText("Through the night", style: .cardTitle)
                LooprText("Average time between beats in two-minute steps. Higher means a slower heart rate.",
                          style: .prose, color: .inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Chart(Array(points.enumerated()), id: \.offset) { _, point in
                    LineMark(x: .value("Hours", point.minute / 60), y: .value("Interval", point.meanIntervalMilliseconds))
                        .foregroundStyle(Color.loopr(.heart))
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 5)) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 1))
                            .foregroundStyle(Color.loopr(.divider))
                        AxisValueLabel {
                            Text(value.as(Double.self).map { String(format: "%.0fh", $0) } ?? "").looprTypography(.confidence).foregroundStyle(Color.loopr(.inkMuted)).fixedSize()
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 1, dash: [2, 4]))
                            .foregroundStyle(Color.loopr(.divider))
                        AxisValueLabel {
                            Text(value.as(Double.self).map { String(format: "%.0f", $0) } ?? "").looprTypography(.confidence).foregroundStyle(Color.loopr(.inkMuted)).fixedSize()
                        }
                    }
                }
                .frame(minHeight: 140)
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                LooprText("MS BETWEEN BEATS, HOURS INTO THE NIGHT", style: .confidence, color: .inkSecondary)
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityIdentifier("heart-beat-tachogram")
    }

    private var accessibilitySummary: String {
        let values = points.map(\.meanIntervalMilliseconds)
        guard let low = values.min(), let high = values.max() else { return "Beat intervals through the night, no data" }
        return "Beat intervals through the night, from \(Int(low.rounded())) to \(Int(high.rounded())) milliseconds. Higher means a slower heart rate."
    }
}
