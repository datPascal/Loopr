import SwiftUI

/// The segmented 7D / 30D / 90D / 1Y control in the Loopr chip style.
public struct LooprRangePicker: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Namespace private var indicator
    @Binding private var selection: LooprChartRange
    private let accent: LooprColorToken
    private let identifier: String
    private let available: Set<LooprChartRange>?

    /// - Parameter available: Ranges that can be picked. Others show as
    ///   locked (dimmed, not tappable). Nil makes every range available.
    public init(
        selection: Binding<LooprChartRange>,
        accent: LooprColorToken,
        identifier: String = "loopr-range-picker",
        available: Set<LooprChartRange>? = nil
    ) {
        _selection = selection
        self.accent = accent
        self.identifier = identifier
        self.available = available
    }

    private func isLocked(_ range: LooprChartRange) -> Bool {
        guard let available else { return false }
        return !available.contains(range)
    }

    public var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: LooprSpacing.xxs) {
                    rangeButtons
                }
            } else {
                HStack(spacing: LooprSpacing.xxs) { rangeButtons }
            }
        }
        .padding(LooprSpacing.xxs - 1)
        .background(Color.loopr(.ink).opacity(isDark ? 0.05 : 0.04), in: RoundedRectangle(cornerRadius: dynamicTypeSize.isAccessibilitySize ? LooprRadius.control : 100, style: .continuous))
        .sensoryFeedback(.selection, trigger: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Time range")
        .accessibilityIdentifier(identifier)
    }

    private var rangeButtons: some View {
        ForEach(LooprChartRange.allCases) { range in
            Button {
                guard range != selection else { return }
                withAnimation(reduceMotion ? nil : .snappy(duration: LooprMotion.standard)) {
                    selection = range
                }
            } label: {
                Text(range.title)
                    // The 9 pt mono D reads as 0 on a phone. Use the
                    // regular word face for every range row.
                    .looprTypography(.label)
                    .foregroundStyle(Color.loopr(range == selection ? accent.spectralChipLabel : .inkSecondary))
                    .opacity(isLocked(range) ? 0.55 : 1)
                    .frame(maxWidth: .infinity, minHeight: 34)
                    .background {
                        if range == selection {
                            Capsule(style: .continuous)
                                .fill(Color.loopr(accent).opacity(isDark ? 0.16 : 0.12))
                                .overlay {
                                    Capsule(style: .continuous)
                                        .strokeBorder(Color.loopr(accent).opacity(isDark ? 0.34 : 0.28), lineWidth: 1)
                                }
                                .matchedGeometryEffect(id: "selection", in: indicator)
                        }
                    }
                    .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(isLocked(range))
            .accessibilityLabel(range.spokenTitle)
            .accessibilityHint(isLocked(range) ? "Needs a longer history" : "")
            .accessibilityAddTraits(range == selection ? [.isSelected, .isButton] : .isButton)
            .accessibilityIdentifier("\(identifier)-\(range.rawValue)")
        }
    }

    private var reduceMotion: Bool {
        accessibilityReduceMotion || DesignSystemRuntime.state().reduceMotion == true
    }

    private var isDark: Bool { LooprAppearance.isDark(colorScheme) }
}

/// The complete history block for a metric: a header that shows the range
/// average and swaps to the selected day while scrubbing, the range picker,
/// the chart and a legend for the usual-range band.
public struct LooprMetricTrendCard: View {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var selectedDate: Date?
    @Binding private var range: LooprChartRange

    private let title: String
    private let points: [LooprChartPoint]
    private let endingOn: Date
    private let kind: LooprChartKind
    private let accent: LooprColorToken
    private let unit: String
    private let valueFormat: @Sendable (Double) -> String
    private let axisFormat: (@Sendable (Double) -> String)?
    private let baseline: LooprBaselineBand?
    private let identifier: String
    private let showsRangePicker: Bool
    private let yAxisStep: Double?
    private let options: LooprTrendCardOptions

    public init(
        title: String,
        points: [LooprChartPoint],
        endingOn: Date,
        range: Binding<LooprChartRange>,
        kind: LooprChartKind,
        accent: LooprColorToken,
        unit: String,
        valueFormat: @escaping @Sendable (Double) -> String,
        axisFormat: (@Sendable (Double) -> String)? = nil,
        baseline: LooprBaselineBand? = nil,
        identifier: String = "metric-trend",
        showsRangePicker: Bool = true,
        yAxisStep: Double? = nil,
        options: LooprTrendCardOptions = .standard
    ) {
        self.title = title
        self.points = points
        self.endingOn = endingOn
        _range = range
        self.kind = kind
        self.accent = accent
        self.unit = unit
        self.valueFormat = valueFormat
        self.axisFormat = axisFormat
        self.baseline = baseline
        self.identifier = identifier
        self.showsRangePicker = showsRangePicker
        self.yAxisStep = yAxisStep
        self.options = options
    }

    /// The range drawn: the chosen one, or the longest unlocked one below it.
    private var shownRange: LooprChartRange {
        LooprChartRange.resolved(range, available: options.availableRanges)
    }

    private var pickerSelection: Binding<LooprChartRange> {
        Binding(get: { shownRange }, set: { range = $0 })
    }

    public var body: some View {
        let range = shownRange
        let series = LooprChartSeries.prepare(points, range: range, endingOn: endingOn, kind: kind, baseline: baseline, scale: options.scale)
        LooprSurface {
            VStack(alignment: .leading, spacing: LooprSpacing.md) {
                header(series)
                    .accessibilityIdentifier("\(identifier)-header")
                if showsRangePicker {
                    VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                        LooprRangePicker(selection: pickerSelection, accent: accent, identifier: "\(identifier)-range", available: options.availableRanges)
                        if options.hasLockedRanges {
                            Text(options.lockedCaption)
                                .looprTypography(.caption)
                                .foregroundStyle(Color.loopr(.inkSecondary))
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, LooprSpacing.xxs)
                                .accessibilityIdentifier("\(identifier)-locked-caption")
                        }
                    }
                }
                if series.isEmpty {
                    emptyChart
                } else {
                    LooprMetricTrendChart(
                        series: series,
                        kind: kind,
                        accent: accent,
                        title: "\(title), \(range.spokenTitle)",
                        unit: unit,
                        valueFormat: valueFormat,
                        axisFormat: axisFormat,
                        selectedDate: $selectedDate,
                        yAxisStep: yAxisStep
                    )
                    .animation(reduceMotion ? nil : .smooth(duration: LooprMotion.deliberate), value: range)
                }
                if let band = series.baseline, !series.isEmpty {
                    legend(band)
                }
            }
        }
        .onChange(of: range) { _, _ in selectedDate = nil }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }

    // MARK: Header

    @ViewBuilder
    private func header(_ series: LooprChartSeries) -> some View {
        let content = headerContent(series)
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: LooprSpacing.xs))
            : AnyLayout(HStackLayout(alignment: .lastTextBaseline, spacing: LooprSpacing.sm))
        layout {
            VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                Text(content.eyebrow)
                    .looprTypography(.sectionLabel)
                    .foregroundStyle(Color.loopr(content.isSelection ? accent.spectralChipLabel : .inkSecondary))
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                    .fixedSize(horizontal: false, vertical: true)
                    .minimumScaleFactor(0.8)
                if content.hasValue {
                    // Numbers large, unit words small: "7 h 36 m", "53 ms".
                    LooprValueText(content.value, unit: unit.isEmpty ? nil : unit, valueStyle: .metricCompact)
                        .contentTransition(.numericText())
                        .minimumScaleFactor(0.6)
                } else {
                    Text(content.value)
                        .looprTypography(.metricCompact)
                        .foregroundStyle(Color.loopr(.inkSecondary))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
            }
            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: LooprSpacing.xs) }
            if let trailing = content.trailing {
                Text(trailing)
                    .looprTypography(.confidence)
                    .foregroundStyle(Color.loopr(.inkSecondary))
                    .multilineTextAlignment(dynamicTypeSize.isAccessibilitySize ? .leading : .trailing)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .animation(reduceMotion ? nil : .snappy(duration: LooprMotion.fast), value: content.value)
        .accessibilityElement(children: .combine)
    }

    struct HeaderContent: Equatable {
        let eyebrow: String
        let value: String
        let trailing: String?
        let hasValue: Bool
        let isSelection: Bool
    }

    func headerContent(_ series: LooprChartSeries) -> HeaderContent {
        let range = shownRange
        let noun = options.smallDataNoun ?? .days
        if let selectedDate {
            let bucketDate = series.bucketStart(for: selectedDate)
            let label = series.window.bucket == .week
                ? "WEEK OF " + LooprChartDateText.day(bucketDate)
                : LooprChartDateText.day(bucketDate)
            guard let point = series.point(at: selectedDate) else {
                return HeaderContent(eyebrow: label, value: "No reading", trailing: nil, hasValue: false, isSelection: true)
            }
            var trailing: String?
            if let low = point.low, let high = point.high, kind == .rangeBars || series.window.bucket == .week {
                trailing = "RANGE \(valueFormat(low))-\(valueFormat(high))"
            }
            if series.window.bucket == .week {
                let days = "\(point.measuredDays) OF 7 \(noun.plural.uppercased())"
                trailing = trailing.map { "\($0)\n\(days)" } ?? days
            }
            return HeaderContent(eyebrow: label, value: valueFormat(point.value), trailing: trailing, hasValue: true, isSelection: true)
        }
        let eyebrow = "\(range == .year ? "1-YEAR" : "\(range.dayCount)-\(noun.singular.uppercased())") AVERAGE"
        let stats = LooprSeriesStatistics.compute(points, window: series.window, endingOn: endingOn)
        guard let stats else {
            return HeaderContent(eyebrow: eyebrow, value: "No readings", trailing: nil, hasValue: false, isSelection: false)
        }
        if let noun = options.smallDataNoun, stats.measuredDays < options.smallDataThreshold {
            // "30-day average" over two readings overstates what is there.
            let words = stats.measuredDays == 1
                ? "\(noun.count(1)) so far"
                : "Average of \(noun.count(stats.measuredDays))"
            return HeaderContent(eyebrow: words.uppercased(), value: valueFormat(stats.mean), trailing: nil, hasValue: true, isSelection: false)
        }
        return HeaderContent(
            eyebrow: eyebrow,
            value: valueFormat(stats.mean),
            trailing: "\(stats.measuredDays) OF \(stats.windowDays) \(noun.plural.uppercased())",
            hasValue: true,
            isSelection: false
        )
    }

    // MARK: Pieces

    private var emptyChart: some View {
        VStack(spacing: LooprSpacing.xs) {
            Image(systemName: "chart.xyaxis.line")
                .looprTypography(.title)
                .foregroundStyle(Color.loopr(accent).opacity(0.6))
                .accessibilityHidden(true)
            Text("No readings in the last \(shownRange.spokenTitle)")
                .looprTypography(.prose)
                .foregroundStyle(Color.loopr(.inkSecondary))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 160)
        .background(
            RoundedRectangle(cornerRadius: LooprRadius.control, style: .continuous)
                .strokeBorder(Color.loopr(.divider), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
        )
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("\(identifier)-empty")
    }

    private func legend(_ band: LooprBaselineBand) -> some View {
        HStack(spacing: LooprSpacing.xs) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Color.loopr(accent).opacity(0.28))
                .frame(width: 14, height: 8)
                .accessibilityHidden(true)
            Text(options.legendShowsValues
                 ? "USUAL RANGE \(valueFormat(band.lower))-\(valueFormat(band.upper)) \(unit.uppercased())"
                 : "YOUR USUAL RANGE")
                .looprTypography(.confidence)
                .foregroundStyle(Color.loopr(.inkSecondary))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var reduceMotion: Bool {
        accessibilityReduceMotion || DesignSystemRuntime.state().reduceMotion == true
    }
}
