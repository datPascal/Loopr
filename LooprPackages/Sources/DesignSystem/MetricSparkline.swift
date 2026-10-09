import Charts
import SwiftUI

/// A compact trend for metric cards: no axes, gaps kept, the usual range as a
/// faint band and the latest reading as a dot. Decorative for VoiceOver; the
/// card that hosts it speaks the numbers.
public struct LooprSparkline: View {
    @Environment(\.colorScheme) private var colorScheme

    private let series: LooprChartSeries
    private let kind: LooprChartKind
    private let accent: LooprColorToken
    private let height: CGFloat

    public init(
        points: [LooprChartPoint],
        days: Int = 30,
        endingOn: Date,
        kind: LooprChartKind = .line,
        accent: LooprColorToken,
        baseline: LooprBaselineBand? = nil,
        height: CGFloat = 40
    ) {
        let drawKind: LooprChartKind = kind == .rangeBars ? .line : kind
        series = LooprChartSeries.prepare(
            points,
            window: LooprChartWindow(dayCount: days),
            endingOn: endingOn,
            kind: drawKind,
            baseline: baseline
        )
        self.kind = drawKind
        self.accent = accent
        self.height = height
    }

    public var isEmpty: Bool { series.isEmpty }

    public var body: some View {
        Chart {
            if let band = series.baseline, kind == .line {
                let domain = series.xDomain()
                RectangleMark(
                    xStart: .value("Start", domain.lowerBound),
                    xEnd: .value("End", domain.upperBound),
                    yStart: .value("Low", band.lower),
                    yEnd: .value("High", band.upper)
                )
                .foregroundStyle(Color.loopr(accent).opacity(isDark ? 0.07 : 0.06))
            }
            if kind == .bars {
                ForEach(series.points) { point in
                    BarMark(x: .value("Day", point.date, unit: .day), y: .value("Value", point.value), width: .ratio(0.6))
                        .clipShape(RoundedRectangle(cornerRadius: 1.5, style: .continuous))
                        .foregroundStyle(Color.loopr(accent).opacity(point.id == series.latest?.id ? 1 : 0.5))
                }
            } else {
                ForEach(series.points) { point in
                    LineMark(
                        x: .value("Day", point.date, unit: .day),
                        y: .value("Value", point.value),
                        series: .value("Segment", "line-\(point.segment)")
                    )
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                    .foregroundStyle(Color.loopr(accent))
                }
                ForEach(isolatedPoints) { point in
                    PointMark(x: .value("Day", point.date, unit: .day), y: .value("Value", point.value))
                        .symbolSize(14)
                        .foregroundStyle(Color.loopr(accent))
                }
                if let latest = series.latest {
                    PointMark(x: .value("Day", latest.date, unit: .day), y: .value("Value", latest.value))
                        .symbol {
                            Circle()
                                .fill(Color.loopr(accent))
                                .frame(width: 6, height: 6)
                                .overlay { Circle().strokeBorder(Color.loopr(.background), lineWidth: 1.5) }
                        }
                }
            }
        }
        .chartXScale(domain: series.xDomain(), range: .plotDimension(startPadding: 2, endPadding: 4))
        .chartYScale(domain: series.yDomain)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .frame(height: height)
        .accessibilityHidden(true)
    }

    private var isolatedPoints: [LooprPlottedPoint] {
        let counts = Dictionary(grouping: series.points, by: \.segment).mapValues(\.count)
        return series.points.filter { counts[$0.segment] == 1 && $0.id != series.latest?.id }
    }

    private var isDark: Bool { LooprAppearance.isDark(colorScheme) }
}
