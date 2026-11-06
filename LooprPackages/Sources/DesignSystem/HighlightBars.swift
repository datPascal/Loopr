import SwiftUI

/// One day in `LooprHighlightBars`. `value` nil means no reading: the chart leaves a gap with a
/// small dot, never a zero bar. `isHighlighted` marks the days the caption is about.
public struct LooprHighlightBar: Identifiable, Hashable, Sendable {
    public let date: Date
    public let value: Double?
    public let isHighlighted: Bool

    public var id: Date { date }

    public init(date: Date, value: Double?, isHighlighted: Bool = false) {
        self.date = date
        self.value = value.flatMap { $0.isFinite ? $0 : nil }
        self.isHighlighted = isHighlighted
    }
}

/// Pure layout for `LooprHighlightBars`.
public struct LooprHighlightBarsModel: Hashable, Sendable {
    public let bars: [LooprHighlightBar]
    /// The value that fills the plot: the largest reading, or `minimumTop`.
    public let top: Double

    public init(bars: [LooprHighlightBar], minimumTop: Double = 0) {
        self.bars = bars
        let largest = bars.compactMap(\.value).map { max($0, 0) }.max() ?? 0
        top = max(largest, minimumTop, .ulpOfOne)
    }

    /// The bar's length as a share of the plot height, 0...1. Negative readings draw no bar.
    public func share(of value: Double) -> Double {
        min(max(value / top, 0), 1)
    }

    /// True when at least one bar is highlighted. With none, every bar draws at full strength,
    /// because there is nothing to tell apart.
    public var hasHighlight: Bool { bars.contains { $0.isHighlighted && $0.value != nil } }

    public var highlightedCount: Int { bars.filter { $0.isHighlighted && $0.value != nil }.count }

    /// The bars as plain daily bars, for the shared speech and audio graph.
    var daily: [LooprDailyBar] { bars.map { LooprDailyBar(date: $0.date, value: $0.value) } }
}

/// Daily bars from zero where some days are drawn brighter than the rest. The caption above the
/// chart says what the bright days have in common ("Brighter bars had dinner after 21:00"). The
/// chart draws only the values it is given.
///
/// ```swift
/// LooprHighlightBars(
///     bars: nights.map { LooprHighlightBar(date: $0.day, value: $0.deepMinutes, isHighlighted: $0.lateDinner) },
///     accent: .sleep,
///     title: "Deep sleep, minutes",
///     valueFormat: { "\(Int($0.rounded())) min" }
/// )
/// ```
///
/// - Highlighted bars use `accent` at full strength. The others use it at 35%. With no highlighted
///   day, every bar is at full strength.
/// - Hold and drag to read a day. The readout shows the date and the value.
/// - Bars grow from the baseline once on first appearance. Reduce Motion skips it.
/// - VoiceOver gets a summary that names the highlighted days, and the audio graph.
public struct LooprHighlightBars: View {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var scrubIndex: Int?
    @State private var grown = false

    private let model: LooprHighlightBarsModel
    private let accent: LooprColorToken
    private let title: String
    private let valueFormat: @Sendable (Double) -> String
    private let height: CGFloat
    private let identifier: String

    /// - Parameters:
    ///   - title: Names the chart for VoiceOver ("Deep sleep, minutes").
    ///   - valueFormat: Writes one bar's value for the readout and for VoiceOver.
    ///   - minimumTop: The smallest top of the scale, so a quiet week does not fill the chart.
    public init(
        bars: [LooprHighlightBar],
        accent: LooprColorToken,
        title: String,
        valueFormat: @escaping @Sendable (Double) -> String,
        minimumTop: Double = 0,
        height: CGFloat = 148,
        identifier: String = "loopr-highlight-bars"
    ) {
        model = LooprHighlightBarsModel(bars: bars, minimumTop: minimumTop)
        self.accent = accent
        self.title = title
        self.valueFormat = valueFormat
        self.height = height
        self.identifier = identifier
    }

    public var body: some View {
        VStack(spacing: LooprSpacing.xxs + 2) {
            plot.frame(height: height)
            LooprDailyAxis(dates: model.bars.map(\.date))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(LooprHighlightBarsSpeech.summary(model: model, format: valueFormat))
        .accessibilityChartDescriptor(LooprDailyBarsDescriptor(title: title, bars: model.daily, format: valueFormat))
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
            let baseY = proxy.size.height
            let slot = width / CGFloat(count)
            let barWidth = max(3, min(slot * 0.5, 22))
            ZStack(alignment: .topLeading) {
                ForEach([0.0, 1.0 / 3, 2.0 / 3], id: \.self) { fraction in
                    Rectangle()
                        .fill(Color.loopr(.divider))
                        .frame(width: width, height: 1)
                        .offset(y: headroom + plotHeight * CGFloat(fraction) - 0.5)
                }
                Rectangle()
                    .fill(Color.loopr(.divider))
                    .frame(width: width, height: 1)
                    .offset(y: baseY - 0.5)
                ForEach(Array(model.bars.enumerated()), id: \.element.id) { index, bar in
                    let centerX = LooprScrubMath.center(of: index, count: count, width: width)
                    if let value = bar.value {
                        let length = max(CGFloat(model.share(of: value)) * plotHeight * (grown ? 1 : 0), value <= 0 ? 0 : 2)
                        RoundedRectangle(cornerRadius: min(barWidth / 2, 5), style: .continuous)
                            .fill(Color.loopr(accent).opacity(opacity(index: index, bar: bar)))
                            .frame(width: barWidth, height: length)
                            .position(x: centerX, y: baseY - length / 2)
                    } else {
                        Circle()
                            .fill(Color.loopr(.inkMuted))
                            .frame(width: 4, height: 4)
                            .position(x: centerX, y: baseY - 2)
                    }
                }
                if let scrubIndex, model.bars.indices.contains(scrubIndex) {
                    let bar = model.bars[scrubIndex]
                    LooprScrubReadout(
                        x: LooprScrubMath.center(of: scrubIndex, count: count, width: width),
                        title: LooprDailyAxis.readoutDate(bar.date),
                        value: bar.value.map(valueFormat),
                        accent: accent
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

    private func opacity(index: Int, bar: LooprHighlightBar) -> Double {
        if let scrubIndex { return scrubIndex == index ? 1 : 0.3 }
        return LooprHighlightBarsModel.opacity(isHighlighted: bar.isHighlighted, hasHighlight: model.hasHighlight)
    }

    private var reduceMotion: Bool { accessibilityReduceMotion || DesignSystemRuntime.state().reduceMotion == true }
}

extension LooprHighlightBarsModel {
    /// Highlighted bars and charts with no highlight draw at full strength. The rest are dimmed.
    static func opacity(isHighlighted: Bool, hasHighlight: Bool) -> Double {
        (isHighlighted || !hasHighlight) ? 1 : 0.35
    }
}

/// Spoken summary for highlight bars. It names the highlighted days, so the emphasis is not
/// colour alone.
enum LooprHighlightBarsSpeech {
    static func summary(model: LooprHighlightBarsModel, format: (Double) -> String) -> String {
        var text = LooprDailyBarsSpeech.summary(bars: model.daily, format: format)
        guard model.hasHighlight else { return text }
        let marked = model.bars.filter { $0.isHighlighted && $0.value != nil }
        let days = marked.map { "\(LooprDailyBarsSpeech.spoken($0.date)) \(format($0.value ?? 0))" }
        text += ". Highlighted, \(marked.count) \(marked.count == 1 ? "day" : "days"): " + days.joined(separator: ", ")
        return text
    }
}

extension LooprSampleNight {
    /// A week of deep sleep where three nights followed a late dinner, for the gallery and previews.
    static func highlightedDeepSleep(endingOn: Date, calendar: Calendar = .current) -> [LooprHighlightBar] {
        let values: [Double] = [72, 70, 69, 58, 51, 47, 56]
        let late: Set<Int> = [3, 4, 5]
        let last = calendar.startOfDay(for: endingOn)
        return values.enumerated().compactMap { index, value in
            calendar.date(byAdding: .day, value: index - (values.count - 1), to: last)
                .map { LooprHighlightBar(date: $0, value: value, isHighlighted: late.contains(index)) }
        }
    }
}

#Preview("Highlight bars") {
    LooprSurface {
        VStack(alignment: .leading, spacing: LooprSpacing.md) {
            LooprSectionHeader("Deep sleep, minutes", detail: "Brighter bars had dinner after 21:00")
            LooprHighlightBars(
                bars: LooprSampleNight.highlightedDeepSleep(endingOn: Date()),
                accent: .sleep,
                title: "Deep sleep, minutes",
                valueFormat: { "\(Int($0.rounded())) min" }
            )
        }
    }
    .padding()
    .background(Color.loopr(.background))
}
