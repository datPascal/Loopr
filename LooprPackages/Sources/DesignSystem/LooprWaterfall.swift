import SwiftUI

/// One additive term in a waterfall: how far it moves the running total, in the chart's unit.
public struct LooprWaterfallStep: Hashable, Sendable, Identifiable {
    public let id: String
    public let label: String
    public let value: Double

    public init(id: String, label: String, value: Double) {
        self.id = id
        self.label = label
        self.value = value
    }
}

/// Pure layout for `LooprWaterfall`: where each bar starts and ends on one shared axis.
public struct LooprWaterfallModel: Hashable, Sendable {
    public struct Bar: Hashable, Sendable, Identifiable {
        public let id: String
        public let label: String
        /// The step's own value. For the total bar, the sum of every step.
        public let value: Double
        public let from: Double
        public let to: Double
        public let isTotal: Bool
    }

    /// Where a bar sits on a track of a given width, in points.
    public struct Segment: Hashable, Sendable {
        public let x: Double
        public let width: Double
    }

    /// Where the chart starts, such as real age or the neutral score of 50.
    public let start: Double
    public let steps: [LooprWaterfallStep]
    /// A step bar per term, then the total bar from `start` to `end`.
    public let bars: [Bar]
    /// The shared scale runs from the lowest to the highest running total, so the largest swing fills the track.
    public let lower: Double
    public let upper: Double

    /// Non-finite steps are dropped, so one bad term cannot hide the rest.
    public init(start: Double, steps: [LooprWaterfallStep], totalLabel: String) {
        self.start = start
        let kept = steps.filter(\.value.isFinite)
        self.steps = kept
        var running = start
        var bars: [Bar] = []
        for step in kept {
            bars.append(Bar(id: step.id, label: step.label, value: step.value, from: running, to: running + step.value,
                            isTotal: false))
            running += step.value
        }
        bars.append(Bar(id: "total", label: totalLabel, value: running - start, from: start, to: running, isTotal: true))
        self.bars = bars
        let ends = bars.flatMap { [$0.from, $0.to] } + [start]
        lower = ends.min() ?? start
        upper = ends.max() ?? start
    }

    /// The sum of the steps.
    public var sum: Double { steps.reduce(0) { $0 + $1.value } }
    /// Where the chart ends: `start + sum`.
    public var end: Double { start + sum }

    /// A value's place on the axis, from 0 at the left edge to 1 at the right.
    public func position(_ value: Double) -> Double {
        let span = upper - lower
        guard span > 0 else { return 0.5 }
        return min(max((value - lower) / span, 0), 1)
    }

    /// Points per unit on a track `trackWidth` wide. Every bar uses the same scale.
    public func pointsPerUnit(trackWidth: Double) -> Double {
        let span = upper - lower
        return span > 0 ? trackWidth / span : 0
    }

    /// The bar from its running total before the step to the total after it. Its width is proportional to the step,
    /// and never less than `minimumWidth`, so a small term stays visible next to a dominant one. A bar widened to the
    /// minimum grows from its own start in the step's direction and stays inside the track.
    public func segment(for bar: Bar, trackWidth: Double, minimumWidth: Double) -> Segment {
        let left = position(min(bar.from, bar.to)) * trackWidth
        let right = position(max(bar.from, bar.to)) * trackWidth
        let width = min(max(right - left, minimumWidth), trackWidth)
        let anchor = position(bar.from) * trackWidth
        let x = bar.to >= bar.from ? anchor : anchor - width
        return Segment(x: min(max(x, 0), max(trackWidth - width, 0)), width: width)
    }
}

/// A horizontal waterfall: each term of an additive formula as a bar from the running total before it to the total
/// after it, on one shared scale, then the total from the starting point to the result.
///
/// Built for method pages ("What moved it"): PhenoAge's marker terms in years against real age, or recovery's points
/// against a usual morning.
///
/// ```swift
/// LooprWaterfall(model: .init(start: 50, steps: steps, totalLabel: "Blood age"),
///                startLabel: "Real age", increaseLabel: "Adds years", decreaseLabel: "Takes years off",
///                valueFormat: { $0.formatted(.number.precision(.fractionLength(1))) },
///                identifier: "method-waterfall")
/// ```
///
/// - The scale spans the lowest to the highest running total, so the largest swing fills the track. A term too small
///   to see is drawn at `minimumBarWidth`; its printed value stays exact.
/// - Each row puts its label and signed value above a full-width track. A hairline marks the starting value on every
///   row, the start row carries a marker there, and the total row is a bar in ink from start to result.
/// - Raises and lowers use two accents, and a legend names them in words. Each value is printed with its sign, so the
///   direction never rests on colour alone.
/// - Each row is one VoiceOver element: the label and the signed value.
public struct LooprWaterfall: View {
    private let model: LooprWaterfallModel
    private let startLabel: String
    private let increaseLabel: String
    private let decreaseLabel: String
    private let increaseAccent: LooprColorToken
    private let decreaseAccent: LooprColorToken
    private let valueFormat: @Sendable (Double) -> String
    private let identifier: String

    public init(model: LooprWaterfallModel, startLabel: String, increaseLabel: String = "Raises the total",
                decreaseLabel: String = "Lowers the total", increaseAccent: LooprColorToken = .brand,
                decreaseAccent: LooprColorToken = .sleep, valueFormat: @escaping @Sendable (Double) -> String,
                identifier: String) {
        self.model = model
        self.startLabel = startLabel
        self.increaseLabel = increaseLabel
        self.decreaseLabel = decreaseLabel
        self.increaseAccent = increaseAccent
        self.decreaseAccent = decreaseAccent
        self.valueFormat = valueFormat
        self.identifier = identifier
    }

    public nonisolated static let barHeight: CGFloat = 12
    /// The narrowest bar drawn, so a term worth a fraction of the scale still shows.
    public nonisolated static let minimumBarWidth: CGFloat = 4
    nonisolated static let markerDiameter: CGFloat = 10

    public var body: some View {
        LooprCard {
            VStack(alignment: .leading, spacing: LooprSpacing.md) {
                legend
                row(label: startLabel, value: valueFormat(model.start), spoken: valueFormat(model.start), bar: nil)
                ForEach(model.bars) { bar in
                    if bar.isTotal {
                        Rectangle()
                            .fill(Color.loopr(.divider))
                            .frame(height: LooprSpacing.hairline)
                            .accessibilityHidden(true)
                        row(label: bar.label, value: valueFormat(bar.to), spoken: valueFormat(bar.to), bar: bar)
                    } else {
                        row(label: bar.label, value: signed(bar.value), spoken: spokenSigned(bar.value), bar: bar)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }

    private var legend: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: LooprSpacing.md) { legendItems }
            VStack(alignment: .leading, spacing: LooprSpacing.xxs) { legendItems }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var legendItems: some View {
        legendItem(increaseAccent, "+", increaseLabel)
        legendItem(decreaseAccent, "−", decreaseLabel)
    }

    private func legendItem(_ accent: LooprColorToken, _ sign: String, _ text: String) -> some View {
        HStack(spacing: LooprSpacing.xxs) {
            Capsule()
                .fill(Color.loopr(accent))
                .frame(width: 18, height: Self.barHeight * 0.75)
                .accessibilityHidden(true)
            LooprText("\(sign) \(text)", style: .caption, color: .inkSecondary)
        }
    }

    private func signed(_ value: Double) -> String {
        let text = valueFormat(abs(value))
        return value < 0 ? "−" + text : "+" + text
    }

    private func spokenSigned(_ value: Double) -> String {
        (value < 0 ? "\(decreaseLabel), minus " : "\(increaseLabel), plus ") + valueFormat(abs(value))
    }

    private func row(label: String, value: String, spoken: String, bar: LooprWaterfallModel.Bar?) -> some View {
        let isTotal = bar?.isTotal == true
        return VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
            HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.xs) {
                LooprText(label, style: isTotal ? .label : .caption, color: isTotal ? .ink : .inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: LooprSpacing.xs)
                Text(value)
                    .looprTypography(.label)
                    .monospacedDigit()
                    .foregroundStyle(Color.loopr(.ink))
            }
            track(bar)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(spoken)
    }

    private func track(_ bar: LooprWaterfallModel.Bar?) -> some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let origin = model.position(model.start) * width
            ZStack(alignment: .topLeading) {
                Capsule()
                    .fill(Color.loopr(.inkMuted).opacity(0.12))
                    .frame(width: width, height: Self.barHeight)
                Rectangle()
                    .fill(Color.loopr(.inkMuted).opacity(0.6))
                    .frame(width: LooprSpacing.hairline, height: Self.barHeight + 6)
                    .offset(x: min(origin, width - LooprSpacing.hairline), y: -3)
                if let bar {
                    let segment = model.segment(for: bar, trackWidth: width, minimumWidth: Self.minimumBarWidth)
                    Capsule()
                        .fill(Color.loopr(color(for: bar)))
                        .frame(width: segment.width, height: Self.barHeight)
                        .offset(x: segment.x)
                } else {
                    Circle()
                        .fill(Color.loopr(.ink))
                        .frame(width: Self.markerDiameter, height: Self.markerDiameter)
                        .offset(x: min(max(origin - Self.markerDiameter / 2, 0), max(width - Self.markerDiameter, 0)),
                                y: (Self.barHeight - Self.markerDiameter) / 2)
                }
            }
        }
        .frame(height: Self.barHeight)
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }

    private func color(for bar: LooprWaterfallModel.Bar) -> LooprColorToken {
        if bar.isTotal { return .ink }
        return bar.value < 0 ? decreaseAccent : increaseAccent
    }
}
