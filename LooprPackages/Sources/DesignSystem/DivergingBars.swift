import Charts
import SwiftUI

/// One day in a daily bar chart. `value` nil means no reading: the chart
/// leaves a gap with a small dot, never a zero bar.
public struct LooprDailyBar: Identifiable, Hashable, Sendable {
    public let date: Date
    public let value: Double?

    public var id: Date { date }

    public init(date: Date, value: Double?) {
        self.date = date
        self.value = value.flatMap { $0.isFinite ? $0 : nil }
    }
}

/// Pure layout for `LooprDivergingBars`.
public struct LooprDivergingBarsModel: Hashable, Sendable {
    public let bars: [LooprDailyBar]
    /// Half the vertical scale: the largest magnitude, or `minimumSpan`.
    public let extent: Double

    public init(bars: [LooprDailyBar], minimumSpan: Double = 0) {
        self.bars = bars
        let largest = bars.compactMap(\.value).map(abs).max() ?? 0
        extent = max(largest, minimumSpan, .ulpOfOne)
    }

    /// The bar's signed length as a share of half the plot height, -1...1.
    public func share(of value: Double) -> Double {
        min(max(value / extent, -1), 1)
    }

    /// Days with a reading.
    public var measured: [LooprDailyBar] { bars.filter { $0.value != nil } }

    /// Sum of all readings, for a ledger total such as net sleep debt.
    public var total: Double { measured.compactMap(\.value).reduce(0, +) }
}

/// Signed daily bars around a zero line: above for surplus, below for
/// shortfall. Built for the 14-night sleep debt ledger (slept minus need)
/// and any other "more or less than a target" series.
///
/// ```swift
/// LooprDivergingBars(
///     bars: nights.map { LooprDailyBar(date: $0.day, value: $0.sleptMinutes - $0.needMinutes) },
///     title: "Sleep vs need",
///     positiveAccent: .sleep,
///     valueFormat: { LooprUnitFormatter.signedDuration(minutes: $0) ?? "" },
///     axisFormat: { LooprUnitFormatter.signedDuration(minutes: $0) ?? "" },
///     minimumSpan: 60
/// )
/// ```
///
/// - Colours: above zero in `positiveAccent`, below zero in `negativeAccent`
///   (grey by default; pass `.caution` only when below zero means outside
///   the usual range). Never red.
/// - Hold and drag to read a day. The readout shows the date and the value.
/// - Bars grow from the zero line once on first appearance; Reduce Motion
///   skips it.
/// - VoiceOver gets a summary and the audio graph.
public struct LooprDivergingBars: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var scrubIndex: Int?
    @State private var grown = false

    private let model: LooprDivergingBarsModel
    private let title: String
    private let positiveAccent: LooprColorToken
    private let negativeAccent: LooprColorToken
    private let valueFormat: @Sendable (Double) -> String
    private let axisFormat: (@Sendable (Double) -> String)?
    private let height: CGFloat
    private let identifier: String

    /// - Parameters:
    ///   - title: Names the chart for VoiceOver ("Sleep vs need").
    ///   - valueFormat: Writes one bar's value for the readout, with its sign.
    ///   - axisFormat: Writes the top and bottom scale labels. Nil hides them.
    ///   - minimumSpan: The smallest half-scale, so a quiet fortnight of
    ///     ±5 minute nights does not fill the chart like ±2 hours would.
    public init(
        bars: [LooprDailyBar],
        title: String,
        positiveAccent: LooprColorToken,
        negativeAccent: LooprColorToken = .inkSecondary,
        valueFormat: @escaping @Sendable (Double) -> String,
        axisFormat: (@Sendable (Double) -> String)? = nil,
        minimumSpan: Double = 0,
        height: CGFloat = 148,
        identifier: String = "loopr-diverging-bars"
    ) {
        model = LooprDivergingBarsModel(bars: bars, minimumSpan: minimumSpan)
        self.title = title
        self.positiveAccent = positiveAccent
        self.negativeAccent = negativeAccent
        self.valueFormat = valueFormat
        self.axisFormat = axisFormat
        self.height = height
        self.identifier = identifier
    }

    public var body: some View {
        VStack(spacing: LooprSpacing.xxs + 2) {
            HStack(alignment: .top, spacing: LooprSpacing.xs) {
                plot
                if let axisFormat {
                    scaleLabels(axisFormat)
                }
            }
            .frame(height: height)
            LooprDailyAxis(dates: model.bars.map(\.date), trailingInset: axisFormat == nil ? 0 : scaleWidth + LooprSpacing.xs)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(LooprDailyBarsSpeech.summary(bars: model.bars, format: valueFormat))
        .accessibilityChartDescriptor(LooprDailyBarsDescriptor(title: title, bars: model.bars, format: valueFormat))
        .accessibilityIdentifier(identifier)
        .onAppear {
            guard !grown else { return }
            if reduceMotion { grown = true } else {
                withAnimation(.snappy(duration: LooprMotion.deliberate)) { grown = true }
            }
        }
    }

    private let headroom: CGFloat = 34

    private var plot: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let count = max(model.bars.count, 1)
            let plotHeight = proxy.size.height - headroom
            let half = plotHeight / 2
            let zeroY = headroom + half
            let slot = width / CGFloat(count)
            let barWidth = max(3, min(slot * 0.56, 18))
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(Color.loopr(.divider))
                    .frame(width: width, height: 1)
                    .offset(y: zeroY - 0.5)
                ForEach(Array(model.bars.enumerated()), id: \.element.id) { index, bar in
                    let centerX = LooprScrubMath.center(of: index, count: count, width: width)
                    if let value = bar.value {
                        let length = max(CGFloat(abs(model.share(of: value))) * half * (grown ? 1 : 0), value == 0 ? 0 : 2)
                        RoundedRectangle(cornerRadius: min(barWidth / 2, 4), style: .continuous)
                            .fill(Color.loopr(value >= 0 ? positiveAccent : negativeAccent)
                                .opacity(opacity(index: index, value: value)))
                            .frame(width: barWidth, height: length)
                            .position(x: centerX, y: value >= 0 ? zeroY - length / 2 : zeroY + length / 2)
                    } else {
                        Circle()
                            .fill(Color.loopr(.inkMuted))
                            .frame(width: 4, height: 4)
                            .position(x: centerX, y: zeroY)
                    }
                }
                if let scrubIndex, model.bars.indices.contains(scrubIndex) {
                    let bar = model.bars[scrubIndex]
                    LooprScrubReadout(
                        x: LooprScrubMath.center(of: scrubIndex, count: count, width: width),
                        title: LooprDailyAxis.readoutDate(bar.date),
                        value: bar.value.map(valueFormat),
                        accent: bar.value.map { $0 >= 0 ? positiveAccent : negativeAccent } ?? positiveAccent
                    )
                    .frame(width: width, height: proxy.size.height)
                }
            }
            .frame(width: width, height: proxy.size.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .looprScrub { x in
                scrubIndex = x.flatMap { LooprScrubMath.index(x: $0, width: width, count: model.bars.count) }
            }
        }
    }

    private var scaleWidth: CGFloat { dynamicTypeSize >= .accessibility1 ? 56 : 40 }

    private func scaleLabels(_ format: @Sendable (Double) -> String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: headroom - 6)
            Text(format(model.extent))
            Spacer(minLength: 0)
            Text("0")
            Spacer(minLength: 0)
            Text(format(-model.extent))
                .padding(.bottom, -6)
        }
        .looprTypography(.confidence)
        .foregroundStyle(Color.loopr(.inkMuted))
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .frame(width: scaleWidth, alignment: .leading)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    private func opacity(index: Int, value: Double) -> Double {
        if let scrubIndex { return scrubIndex == index ? 1 : 0.3 }
        return value >= 0 ? 1 : (negativeAccent == .inkSecondary ? 0.75 : 1)
    }

    private var reduceMotion: Bool { accessibilityReduceMotion || DesignSystemRuntime.state().reduceMotion == true }
}

/// Day labels under a daily bar chart: narrow weekdays for a fortnight or
/// less, day numbers every few days beyond that.
struct LooprDailyAxis: View {
    let dates: [Date]
    var trailingInset: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width - trailingInset
            let step = dates.count > 14 ? 7 : 1
            ZStack(alignment: .topLeading) {
                ForEach(Array(dates.enumerated()), id: \.element) { index, date in
                    if (dates.count - 1 - index) % step == 0 {
                        Text(Self.label(date, dense: dates.count > 14))
                            .looprTypography(.confidence)
                            .foregroundStyle(Color.loopr(index == dates.count - 1 ? .ink : .inkSecondary))
                            .fixedSize()
                            .position(x: LooprScrubMath.center(of: index, count: dates.count, width: width), y: 7)
                    }
                }
            }
        }
        .frame(height: 14)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .accessibilityHidden(true)
    }

    static func label(_ date: Date, dense: Bool) -> String {
        dense
            ? date.formatted(.dateTime.day().month(.abbreviated)).uppercased()
            : date.formatted(.dateTime.weekday(.narrow)).uppercased()
    }

    static func readoutDate(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }
}

/// Spoken summaries for daily bar charts.
enum LooprDailyBarsSpeech {
    static func summary(bars: [LooprDailyBar], format: (Double) -> String) -> String {
        let measured = bars.compactMap { bar in bar.value.map { (bar.date, $0) } }
        guard let latest = measured.last else { return "No readings" }
        var parts = ["\(measured.count) of \(bars.count) days measured"]
        if let high = measured.max(by: { $0.1 < $1.1 }), let low = measured.min(by: { $0.1 < $1.1 }), measured.count > 1 {
            parts.append("highest \(format(high.1)) on \(spoken(high.0))")
            parts.append("lowest \(format(low.1)) on \(spoken(low.0))")
        }
        parts.append("latest \(format(latest.1)) on \(spoken(latest.0))")
        return parts.joined(separator: ", ")
    }

    static func spoken(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }
}

/// The audio graph for daily bars.
struct LooprDailyBarsDescriptor: AXChartDescriptorRepresentable {
    let title: String
    let bars: [LooprDailyBar]
    let format: @Sendable (Double) -> String

    func makeChartDescriptor() -> AXChartDescriptor {
        let values = bars.compactMap(\.value)
        let low = min(values.min() ?? 0, 0)
        let high = max(values.max() ?? 1, low + 1)
        let format = format
        let first = bars.first?.date.timeIntervalSince1970 ?? 0
        let last = max(bars.last?.date.timeIntervalSince1970 ?? 1, first + 1)
        let xAxis = AXNumericDataAxisDescriptor(title: "Date", range: first...last, gridlinePositions: []) {
            Date(timeIntervalSince1970: $0).formatted(date: .abbreviated, time: .omitted)
        }
        let yAxis = AXNumericDataAxisDescriptor(title: title, range: low...high, gridlinePositions: [0]) { format($0) }
        let series = AXDataSeriesDescriptor(
            name: title,
            isContinuous: false,
            dataPoints: bars.compactMap { bar in
                bar.value.map { AXDataPoint(x: bar.date.timeIntervalSince1970, y: $0) }
            }
        )
        return AXChartDescriptor(title: title, summary: nil, xAxis: xAxis, yAxis: yAxis, additionalAxes: [], series: [series])
    }
}

#Preview("Diverging bars") {
    LooprSurface {
        VStack(alignment: .leading, spacing: LooprSpacing.md) {
            LooprSectionHeader("Sleep debt", detail: "Slept minus need, last 14 nights")
            LooprDivergingBars(
                bars: LooprSampleNight.debtLedger(endingOn: Date()),
                title: "Sleep vs need",
                positiveAccent: .sleep,
                valueFormat: { LooprUnitFormatter.signedDuration(minutes: $0) ?? "" },
                axisFormat: { LooprUnitFormatter.signedDuration(minutes: $0) ?? "" },
                minimumSpan: 60
            )
        }
    }
    .padding()
    .background(Color.loopr(.background))
}
