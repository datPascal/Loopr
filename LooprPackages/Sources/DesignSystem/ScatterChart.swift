import Charts
import SwiftUI

public struct LooprScatterPoint: Identifiable, Sendable, Equatable {
    public let id: String
    public let x: Double
    public let y: Double
    public init(id: String, x: Double, y: Double) { self.id = id; self.x = x; self.y = y }
}

/// A point per observation, with no fitted line or implied causal trend.
public struct LooprScatterChart: View {
    private let points: [LooprScatterPoint]
    private let title: String
    private let xTitle: String
    private let yTitle: String
    private let xDomain: ClosedRange<Double>
    private let yDomain: ClosedRange<Double>
    private let threshold: Double?
    private let accent: LooprColorToken
    private let xFormat: @Sendable (Double) -> String
    private let yFormat: @Sendable (Double) -> String
    public init(points: [LooprScatterPoint], title: String, xTitle: String, yTitle: String,
                xDomain: ClosedRange<Double>, yDomain: ClosedRange<Double>, threshold: Double? = nil,
                accent: LooprColorToken, xFormat: @escaping @Sendable (Double) -> String,
                yFormat: @escaping @Sendable (Double) -> String) {
        self.points = points.filter { $0.x.isFinite && $0.y.isFinite }
        self.title = title; self.xTitle = xTitle; self.yTitle = yTitle
        self.xDomain = xDomain; self.yDomain = yDomain; self.threshold = threshold
        self.accent = accent; self.xFormat = xFormat; self.yFormat = yFormat
    }
    public var accessibilitySummary: String { "\(points.count) observations. \(xTitle) and \(yTitle)." }
    public var body: some View {
        VStack(spacing: LooprSpacing.sm) {
            Chart {
                if let threshold {
                    RuleMark(x: .value(xTitle, threshold))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 4]))
                        .foregroundStyle(Color.loopr(.inkMuted))
                }
                ForEach(points) { point in
                    PointMark(x: .value(xTitle, point.x), y: .value(yTitle, point.y))
                        .foregroundStyle(Color.loopr(accent))
                }
            }
            .chartXScale(domain: xDomain).chartYScale(domain: yDomain)
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 1, dash: [2, 4])).foregroundStyle(Color.loopr(.divider))
                    AxisValueLabel {
                        if let number = value.as(Double.self) {
                            Text(yFormat(number)).looprTypography(.confidence).foregroundStyle(Color.loopr(.inkSecondary))
                        }
                    }
                }
            }
            .frame(height: LooprSpacing.xxl * 5)
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            HStack {
                Text(xFormat(xDomain.lowerBound))
                Spacer(minLength: LooprSpacing.xs)
                Text(xTitle.looprLabelCased)
                Spacer(minLength: LooprSpacing.xs)
                Text(xFormat(xDomain.upperBound))
            }.looprTypography(.confidence).foregroundStyle(Color.loopr(.inkSecondary))
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title).accessibilityValue(accessibilitySummary)
        .accessibilityChartDescriptor(ScatterDescriptor(title: title, xTitle: xTitle, yTitle: yTitle,
            xDomain: xDomain, yDomain: yDomain, points: points, xFormat: xFormat, yFormat: yFormat))
    }
}

private struct ScatterDescriptor: AXChartDescriptorRepresentable {
    let title: String
    let xTitle: String
    let yTitle: String
    let xDomain: ClosedRange<Double>
    let yDomain: ClosedRange<Double>
    let points: [LooprScatterPoint]
    let xFormat: @Sendable (Double) -> String
    let yFormat: @Sendable (Double) -> String
    func makeChartDescriptor() -> AXChartDescriptor {
        .init(title: title, summary: "Each point is one observation.",
              xAxis: AXNumericDataAxisDescriptor(title: xTitle, range: xDomain, gridlinePositions: [], valueDescriptionProvider: xFormat),
              yAxis: AXNumericDataAxisDescriptor(title: yTitle, range: yDomain, gridlinePositions: [], valueDescriptionProvider: yFormat),
              additionalAxes: [], series: [AXDataSeriesDescriptor(name: title, isContinuous: false,
                dataPoints: points.map { AXDataPoint(x: $0.x, y: $0.y) })])
    }
}

#Preview {
    LooprCard {
        LooprScatterChart(points: [.init(id: "1", x: 19, y: 72), .init(id: "2", x: 22, y: 56)],
            title: "Last meal and deep sleep", xTitle: "Last meal", yTitle: "Deep sleep minutes",
            xDomain: 18...23, yDomain: 40...90, threshold: 21, accent: .sleep,
            xFormat: { "\(Int($0)):00" }, yFormat: { "\(Int($0))m" })
    }.padding()
}
