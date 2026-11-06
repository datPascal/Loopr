import SwiftUI

/// A compact measurement and its seven-day history, used by overview grids.
public struct LooprMetricTrendTile: View {
    @ScaledMetric(relativeTo: .largeTitle) private var valueHeight = LooprTextStyle.metricCompact.baseSize * 1.25
    let title: String
    let value: String?
    let unit: String
    let points: [LooprChartPoint]
    let endingOn: Date
    let accent: LooprColorToken
    let state: MetricState?

    public init(title: String, value: String?, unit: String = "", points: [LooprChartPoint],
                endingOn: Date, accent: LooprColorToken, state: MetricState? = nil) {
        self.title = title; self.value = value; self.unit = unit; self.points = points
        self.endingOn = endingOn; self.accent = accent; self.state = state
    }

    var displayedValue: String? {
        switch state {
        case .loading, .noRecords, .absent, .recoverableError, .destructiveFailure: nil
        default: value
        }
    }

    public var accessibilitySummary: String {
        var parts = [title]
        if let displayedValue {
            parts.append([displayedValue, LooprUnitFormatter.spokenUnit(unit)].filter { !$0.isEmpty }.joined(separator: " "))
            if let state { parts.append(state.title) }
        } else { parts.append((state ?? .absent).title) }
        return parts.joined(separator: ", ")
    }

    public var body: some View {
        LooprCard(density: .compact) {
            VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                // A small label over a large number, as on every tile.
                LooprText(title, style: .sectionLabel, color: .inkSecondary)
                    .accessibilityAddTraits(.isHeader)
                if state == .loading {
                    LooprSkeleton(height: LooprTextStyle.metric.baseSize)
                } else if let value = displayedValue {
                    LooprValueText(value, unit: unit, valueStyle: .metric, unitStyle: .metricUnit)
                        .minimumScaleFactor(0.6)
                    .frame(minHeight: valueHeight, alignment: .leading)
                } else {
                    StateMessage(state ?? .absent, compact: true, accent: accent)
                }
                if displayedValue != nil, let state {
                    StatusChip(state.title, symbol: state.symbol, accent: accent)
                }
                LooprSparkline(points: points, days: 7, endingOn: endingOn, accent: accent)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: LooprSpacing.interactiveRowHeight)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }
}

#Preview {
    LooprMetricTrendTile(title: "HRV", value: "61", unit: "ms", points: [],
        endingOn: Date(), accent: .heart, state: .partial)
}
