import Charts
import SwiftUI

/// One day of a paired bar chart: two readings on their own scales. Either
/// may be nil, which leaves a gap for that bar only.
public struct LooprPairedBarDay: Identifiable, Hashable, Sendable {
    public let date: Date
    public let first: Double?
    public let second: Double?

    public var id: Date { date }

    public init(date: Date, first: Double?, second: Double?) {
        self.date = date
        self.first = first.flatMap { $0.isFinite ? $0 : nil }
        self.second = second.flatMap { $0.isFinite ? $0 : nil }
    }
}

/// How one of the two series in `LooprPairedBars` looks and reads.
public struct LooprBarSeriesStyle: Sendable {
    public let title: String
    /// The value that fills the full bar height: 21 for strain, 100 for
    /// recovery. Each series keeps its own scale.
    public let fullScale: Double
    public let accent: LooprColorToken
    /// Colours an individual bar from its value, for recovery bands. Nil uses
    /// `accent` for every bar.
    public let tint: (@Sendable (Double) -> LooprColorToken)?
    /// Writes a value for the readout: "12.4", "71".
    public let valueFormat: @Sendable (Double) -> String

    public init(
        title: String,
        fullScale: Double,
        accent: LooprColorToken,
        tint: (@Sendable (Double) -> LooprColorToken)? = nil,
        valueFormat: @escaping @Sendable (Double) -> String
    ) {
        self.title = title
        self.fullScale = fullScale > 0 && fullScale.isFinite ? fullScale : 1
        self.accent = accent
        self.tint = tint
        self.valueFormat = valueFormat
    }

    /// Strain on the 0 to 21 scale. Drawn in neutral slate, not the strain
    /// amber: next to banded recovery bars, amber and the middle-band yellow
    /// were too close to tell apart.
    public static let strain = LooprBarSeriesStyle(
        title: "Strain", fullScale: 21, accent: .inkSecondary,
        valueFormat: { LooprUnitFormatter.number($0, digits: 1) ?? "" }
    )

    /// Next-morning recovery on 0 to 100, each bar in its recovery band colour.
    public static let recovery = LooprBarSeriesStyle(
        title: "Recovery", fullScale: 100, accent: .recoveryHigh,
        tint: { LooprRecoveryBand(score: $0)?.token ?? .inkMuted },
        valueFormat: { LooprUnitFormatter.number($0, digits: 0) ?? "" }
    )

    /// Share of the full bar height, 0...1.
    public func share(of value: Double) -> Double {
        min(max(value / fullScale, 0), 1)
    }

    func token(for value: Double) -> LooprColorToken {
        tint?(value) ?? accent
    }
}

/// Two bars per day on one date axis, each on its own scale. Built for
/// "strain vs next-morning recovery" over the last 7 days, where the pattern
/// between the two matters more than either number.
///
/// ```swift
/// LooprPairedBars(
///     days: week.map { LooprPairedBarDay(date: $0.day, first: $0.strain, second: $0.nextRecovery) },
///     first: .strain,
///     second: .recovery,
///     title: "Strain and next-morning recovery"
/// )
/// ```
///
/// - A legend names both series above the plot.
/// - Hold and drag to read a day: "Tue 22 Sep" over "Strain 12.4 · Recovery 71".
/// - Bars rise once on first appearance; Reduce Motion skips it.
/// - VoiceOver reads one summary per day through the audio graph and a
///   plain-language value.
public struct LooprPairedBars: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var scrubIndex: Int?
    @State private var grown = false

    private let days: [LooprPairedBarDay]
    private let first: LooprBarSeriesStyle
    private let second: LooprBarSeriesStyle
    private let title: String
    private let height: CGFloat
    private let identifier: String

    public init(
        days: [LooprPairedBarDay],
        first: LooprBarSeriesStyle,
        second: LooprBarSeriesStyle,
        title: String,
        height: CGFloat = 156,
        identifier: String = "loopr-paired-bars"
    ) {
        self.days = days
        self.first = first
        self.second = second
        self.title = title
        self.height = height
        self.identifier = identifier
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.sm) {
            legend
            VStack(spacing: LooprSpacing.xxs + 2) {
                plot.frame(height: height)
                LooprDailyAxis(dates: days.map(\.date))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(spokenSummary)
        .accessibilityChartDescriptor(LooprPairedBarsDescriptor(title: title, days: days, first: first, second: second))
        .accessibilityIdentifier(identifier)
        .onAppear {
            guard !grown else { return }
            if reduceMotion { grown = true } else {
                withAnimation(.snappy(duration: LooprMotion.deliberate)) { grown = true }
            }
        }
    }

    private var legend: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: LooprSpacing.xxs))
            : AnyLayout(HStackLayout(spacing: LooprSpacing.md))
        return layout {
            legendItem(first)
            legendItem(second)
            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }
        }
    }

    private func legendItem(_ style: LooprBarSeriesStyle) -> some View {
        HStack(spacing: LooprSpacing.xxs + 2) {
            if style.tint != nil {
                // A banded series shows its three band colours.
                HStack(spacing: 1) {
                    ForEach(LooprRecoveryBand.allCases.reversed(), id: \.self) { band in
                        RoundedRectangle(cornerRadius: 1.5).fill(Color.loopr(band.token)).frame(width: 4, height: 10)
                    }
                }
            } else {
                RoundedRectangle(cornerRadius: 2).fill(Color.loopr(style.accent)).frame(width: 10, height: 10)
            }
            Text(style.title.uppercased())
                .looprTypography(.sectionLabel)
                .foregroundStyle(Color.loopr(.inkSecondary))
        }
    }

    private let headroom: CGFloat = 34

    private var plot: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let count = max(days.count, 1)
            let plotHeight = proxy.size.height - headroom
            let baseline = proxy.size.height
            let slot = width / CGFloat(count)
            let barWidth = max(3, min(slot * 0.26, 14))
            let gap = max(2, barWidth * 0.3)
            ZStack(alignment: .topLeading) {
                ForEach([0.5, 1.0], id: \.self) { level in
                    Rectangle()
                        .fill(Color.loopr(.divider))
                        .frame(width: width, height: 1)
                        .offset(y: baseline - plotHeight * level)
                }
                Rectangle()
                    .fill(Color.loopr(.inkMuted).opacity(0.5))
                    .frame(width: width, height: 1)
                    .offset(y: baseline - 1)
                ForEach(Array(days.enumerated()), id: \.element.id) { index, day in
                    let center = LooprScrubMath.center(of: index, count: count, width: width)
                    bar(day.first, style: first, index: index, plotHeight: plotHeight, width: barWidth)
                        .position(x: center - (barWidth + gap) / 2, y: baseline - barHeight(day.first, style: first, plotHeight: plotHeight) / 2)
                    bar(day.second, style: second, index: index, plotHeight: plotHeight, width: barWidth)
                        .position(x: center + (barWidth + gap) / 2, y: baseline - barHeight(day.second, style: second, plotHeight: plotHeight) / 2)
                }
                if let scrubIndex, days.indices.contains(scrubIndex) {
                    let day = days[scrubIndex]
                    LooprScrubReadout(
                        x: LooprScrubMath.center(of: scrubIndex, count: count, width: width),
                        title: LooprDailyAxis.readoutDate(day.date),
                        value: readoutValue(day),
                        accent: first.accent
                    )
                    .frame(width: width, height: proxy.size.height)
                }
            }
            .frame(width: width, height: proxy.size.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .looprScrub { x in
                scrubIndex = x.flatMap { LooprScrubMath.index(x: $0, width: width, count: days.count) }
            }
        }
    }

    @ViewBuilder
    private func bar(_ value: Double?, style: LooprBarSeriesStyle, index: Int, plotHeight: CGFloat, width: CGFloat) -> some View {
        if let value {
            UnevenRoundedRectangle(topLeadingRadius: width / 2, topTrailingRadius: width / 2, style: .continuous)
                .fill(Color.loopr(style.token(for: value)).opacity(scrubIndex.map { $0 == index ? 1 : 0.3 } ?? 1))
                .frame(width: width, height: barHeight(value, style: style, plotHeight: plotHeight))
        } else {
            Circle()
                .fill(Color.loopr(.inkMuted))
                .frame(width: 4, height: 4)
        }
    }

    private func barHeight(_ value: Double?, style: LooprBarSeriesStyle, plotHeight: CGFloat) -> CGFloat {
        guard let value else { return 4 }
        return max(CGFloat(style.share(of: value)) * plotHeight * (grown ? 1 : 0), value > 0 ? 2 : 0)
    }

    private func readoutValue(_ day: LooprPairedBarDay) -> String? {
        let parts = [(first, day.first), (second, day.second)].compactMap { style, value in
            value.map { "\(style.title) \(style.valueFormat($0))" }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var spokenSummary: String {
        let described = days.map { day -> String in
            let date = LooprDailyBarsSpeech.spoken(day.date)
            let values = [(first, day.first), (second, day.second)].map { style, value in
                value.map { "\(style.title) \(style.valueFormat($0))" } ?? "\(style.title) no reading"
            }
            return "\(date): " + values.joined(separator: ", ")
        }
        return described.joined(separator: ". ")
    }

    private var reduceMotion: Bool { accessibilityReduceMotion || DesignSystemRuntime.state().reduceMotion == true }
}

/// The audio graph for paired bars: two series on one date axis, each
/// normalised to a share of its own scale so they can be compared.
struct LooprPairedBarsDescriptor: AXChartDescriptorRepresentable {
    let title: String
    let days: [LooprPairedBarDay]
    let first: LooprBarSeriesStyle
    let second: LooprBarSeriesStyle

    func makeChartDescriptor() -> AXChartDescriptor {
        let start = days.first?.date.timeIntervalSince1970 ?? 0
        let end = max(days.last?.date.timeIntervalSince1970 ?? 1, start + 1)
        let xAxis = AXNumericDataAxisDescriptor(title: "Date", range: start...end, gridlinePositions: []) {
            Date(timeIntervalSince1970: $0).formatted(date: .abbreviated, time: .omitted)
        }
        let yAxis = AXNumericDataAxisDescriptor(title: "Share of full scale", range: 0...100, gridlinePositions: []) {
            "\(Int($0.rounded())) percent of full scale"
        }
        let series = [(first, \LooprPairedBarDay.first), (second, \LooprPairedBarDay.second)].map { style, path in
            AXDataSeriesDescriptor(name: style.title, isContinuous: false, dataPoints: days.compactMap { day in
                day[keyPath: path].map { AXDataPoint(x: day.date.timeIntervalSince1970, y: style.share(of: $0) * 100) }
            })
        }
        return AXChartDescriptor(title: title, summary: nil, xAxis: xAxis, yAxis: yAxis, additionalAxes: [], series: series)
    }
}

#Preview("Paired bars") {
    LooprSurface {
        VStack(alignment: .leading, spacing: LooprSpacing.md) {
            LooprSectionHeader("Strain and recovery", detail: "Each day's strain next to the recovery that followed")
            LooprPairedBars(days: LooprSampleNight.strainRecoveryWeek(endingOn: Date()), first: .strain, second: .recovery,
                            title: "Strain and next-morning recovery")
        }
    }
    .padding()
    .background(Color.loopr(.background))
}
