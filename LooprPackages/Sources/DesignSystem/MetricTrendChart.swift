import Charts
import SwiftUI

/// The metric history chart: dates on the x axis, one mark per day (or per
/// week in the year view), a gap wherever a day has no reading, an optional
/// band for the person's usual range, and a latest-value dot.
///
/// Selection is owned by the caller so a header can swap its summary for the
/// selected day while the finger is down.
public struct LooprMetricTrendChart: View {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private let series: LooprChartSeries
    private let kind: LooprChartKind
    private let accent: LooprColorToken
    private let title: String
    private let unit: String
    private let valueFormat: @Sendable (Double) -> String
    private let axisFormat: @Sendable (Double) -> String
    private let height: CGFloat
    private let yAxisStep: Double?
    @Binding private var selectedDate: Date?

    public init(
        series: LooprChartSeries,
        kind: LooprChartKind,
        accent: LooprColorToken,
        title: String,
        unit: String,
        valueFormat: @escaping @Sendable (Double) -> String,
        axisFormat: (@Sendable (Double) -> String)? = nil,
        selectedDate: Binding<Date?>,
        height: CGFloat = 208,
        yAxisStep: Double? = nil
    ) {
        self.series = series
        self.kind = kind
        self.accent = accent
        self.title = title
        self.unit = unit
        self.valueFormat = valueFormat
        self.axisFormat = axisFormat ?? valueFormat
        self.height = height
        self.yAxisStep = yAxisStep
        _selectedDate = selectedDate
    }

    public var body: some View {
        chart
            .frame(height: height)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityValue(accessibilitySummary)
            .accessibilityChartDescriptor(descriptor)
            .accessibilityIdentifier("loopr-metric-trend-chart")
    }

    private var chart: some View {
        Chart {
            baselineMarks
            switch kind {
            case .line: lineMarks
            case .bars: barMarks
            case .rangeBars: rangeBarMarks
            }
            selectionMarks
        }
        .chartXScale(domain: series.xDomain(), range: .plotDimension(startPadding: 4, endPadding: endPadding))
        .chartYScale(domain: series.yDomain)
        .chartXAxis { xAxis }
        .chartYAxis { yAxis }
        .chartLegend(.hidden)
        .chartOverlay { proxy in
            // Hold-then-drag instead of `chartXSelection`, which grabbed every
            // touch and turned page scrolls that started on the chart into
            // scrubs. See `looprScrub`.
            GeometryReader { geometry in
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .looprScrub { x in
                        guard let x else {
                            rawSelection.wrappedValue = nil
                            return
                        }
                        let originX = proxy.plotFrame.map { geometry[$0].origin.x } ?? 0
                        if let date: Date = proxy.value(atX: x - originX) {
                            rawSelection.wrappedValue = date
                        }
                    }
            }
        }
    }

    // MARK: Marks

    @ChartContentBuilder
    private var baselineMarks: some ChartContent {
        if let band = series.baseline {
            let domain = series.xDomain()
            RectangleMark(
                xStart: .value("Start", domain.lowerBound),
                xEnd: .value("End", domain.upperBound),
                yStart: .value("Usual low", band.lower),
                yEnd: .value("Usual high", band.upper)
            )
            .foregroundStyle(Color.loopr(accent).opacity(isDark ? 0.10 : 0.08))

            RuleMark(y: .value("Usual", band.center))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 4]))
                .foregroundStyle(Color.loopr(accent).opacity(isDark ? 0.45 : 0.40))
        }
    }

    @ChartContentBuilder
    private var lineMarks: some ChartContent {
        let lowerBound = series.yDomain.lowerBound
        // A few readings get dots and a line only: an area under two points
        // reads as a solid block.
        ForEach(series.points.count < Self.dotEveryPointBelow ? [] : series.points) { point in
            AreaMark(
                x: .value("Day", point.date, unit: xUnit),
                yStart: .value("Floor", lowerBound),
                yEnd: .value(unit, point.value),
                series: .value("Segment", point.segment)
            )
            .interpolationMethod(.linear)
            .foregroundStyle(areaGradient)
            .opacity(selectionDimming(for: point) ? 0.45 : 1)
        }
        if isDark {
            ForEach(series.points) { point in
                LineMark(
                    x: .value("Day", point.date, unit: xUnit),
                    y: .value(unit, point.value),
                    series: .value("Glow", "glow-\(point.segment)")
                )
                .interpolationMethod(.linear)
                .lineStyle(StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
                .foregroundStyle(Color.loopr(accent).opacity(0.14))
            }
        }
        ForEach(series.points) { point in
            LineMark(
                x: .value("Day", point.date, unit: xUnit),
                y: .value(unit, point.value),
                series: .value("Segment", "line-\(point.segment)")
            )
            .interpolationMethod(.linear)
            .lineStyle(StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            .foregroundStyle(Color.loopr(accent))
        }
        ForEach(dottedPoints) { point in
            PointMark(x: .value("Day", point.date, unit: xUnit), y: .value(unit, point.value))
                .symbolSize(isolatedIDs.contains(point.id) ? 36 : 22)
                .foregroundStyle(Color.loopr(accent))
        }
        if let latest = series.latest, selectedDate == nil {
            PointMark(x: .value("Day", latest.date, unit: xUnit), y: .value(unit, latest.value))
                .symbol { LooprChartEndDot(accent: accent) }
        }
    }

    @ChartContentBuilder
    private var barMarks: some ChartContent {
        ForEach(series.points) { point in
            BarMark(
                x: .value("Day", point.date, unit: xUnit),
                y: .value(unit, point.value),
                width: .ratio(barWidthRatio)
            )
            .clipShape(RoundedRectangle(cornerRadius: barCornerRadius, style: .continuous))
            .foregroundStyle(barStyle(for: point))
        }
    }

    @ChartContentBuilder
    private var rangeBarMarks: some ChartContent {
        ForEach(series.points) { point in
            BarMark(
                x: .value("Day", point.date, unit: xUnit),
                yStart: .value("Low", point.low ?? point.value),
                yEnd: .value("High", point.high ?? point.value),
                width: .ratio(barWidthRatio * 0.8)
            )
            .clipShape(Capsule(style: .continuous))
            .foregroundStyle(Color.loopr(accent).opacity(selectionDimming(for: point) ? 0.14 : 0.32))
        }
        ForEach(series.points) { point in
            PointMark(x: .value("Day", point.date, unit: xUnit), y: .value(unit, point.value))
                .symbolSize(series.points.count > 45 ? 10 : 26)
                .foregroundStyle(Color.loopr(accent).opacity(selectionDimming(for: point) ? 0.4 : 1))
        }
    }

    @ChartContentBuilder
    private var selectionMarks: some ChartContent {
        if let selectedDate {
            let snapped = series.bucketStart(for: selectedDate)
            let point = series.point(at: selectedDate)
            RuleMark(x: .value("Selected", snapped, unit: xUnit))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: point == nil ? [2, 3] : []))
                .foregroundStyle(Color.loopr(.inkSecondary).opacity(0.55))
            if let point, kind != .bars {
                PointMark(x: .value("Selected", point.date, unit: xUnit), y: .value(unit, point.value))
                    .symbol { LooprChartEndDot(accent: accent, prominent: true) }
            }
        }
    }

    // MARK: Axes

    private var xAxis: some AxisContent {
        AxisMarks(values: xAxisDates) { value in
            AxisGridLine(stroke: StrokeStyle(lineWidth: 1))
                .foregroundStyle(Color.loopr(.divider))
            AxisValueLabel(anchor: .top) {
                if let date = value.as(Date.self) {
                    Text(xLabel(for: date))
                        .looprTypography(.confidence)
                        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                        .foregroundStyle(Color.loopr(.inkSecondary))
                        .multilineTextAlignment(.center)
                        .lineSpacing(1)
                        .fixedSize()
                }
            }
        }
    }

    private var yAxis: some AxisContent {
        AxisMarks(position: .trailing, values: yAxisValues) { value in
            AxisGridLine(stroke: StrokeStyle(lineWidth: 1, dash: [2, 4]))
                .foregroundStyle(Color.loopr(.divider))
            AxisValueLabel {
                if let number = value.as(Double.self) {
                    Text(axisFormat(number))
                        .looprTypography(.confidence)
                        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                        .foregroundStyle(Color.loopr(.inkMuted))
                }
            }
        }
    }

    private var yAxisValues: AxisMarkValues {
        guard let yAxisStep, yAxisStep > 0 else {
            return .automatic(desiredCount: dynamicTypeSize >= .accessibility1 ? 2 : 3)
        }
        return .stride(by: LooprTrendAxis.yStride(step: yAxisStep, domain: series.yDomain))
    }

    private var xAxisDates: [Date] {
        LooprTrendAxis.dates(for: series, dense: dynamicTypeSize >= .accessibility1)
    }

    private func xLabel(for date: Date) -> String {
        LooprTrendAxis.label(for: date, window: series.window)
    }

    // MARK: Helpers

    private var rawSelection: Binding<Date?> {
        Binding(
            get: { selectedDate },
            set: { newValue in
                guard let newValue else {
                    selectedDate = nil
                    return
                }
                let domain = series.xDomain()
                let clamped = min(max(newValue, domain.lowerBound), domain.upperBound.addingTimeInterval(-1))
                let snapped = series.bucketStart(for: clamped)
                if selectedDate.map({ series.bucketStart(for: $0) }) != snapped {
                    selectedDate = snapped
                }
            }
        )
    }

    private var xUnit: Calendar.Component {
        series.window.bucket == .week ? .weekOfYear : .day
    }

    private var endPadding: CGFloat {
        kind == .line ? 8 : 4
    }

    private var lineWidth: CGFloat {
        series.points.count > 120 ? 2 : 2.5
    }

    private var barWidthRatio: Double {
        switch series.window.dayCount {
        case ...10: 0.5
        case ...40: 0.62
        default: 0.7
        }
    }

    private var barCornerRadius: CGFloat {
        series.window.dayCount <= 10 ? 5 : 2
    }

    /// Isolated points (a measured day between two gaps) have no line of
    /// their own, so they always get a dot or they would vanish.
    private var isolatedIDs: Set<Date> {
        let counts = Dictionary(grouping: series.points, by: \.segment).mapValues(\.count)
        return Set(series.points.filter { counts[$0.segment] == 1 }.map(\.id))
    }

    /// A line through a handful of readings hides how few there are, so
    /// every reading gets a dot below this count.
    static let dotEveryPointBelow = 15

    private var dottedPoints: [LooprPlottedPoint] {
        if series.window.dayCount <= 10 || series.points.count < Self.dotEveryPointBelow {
            return series.points.filter { $0.id != series.latest?.id }
        }
        let isolated = isolatedIDs
        return series.points.filter { isolated.contains($0.id) && $0.id != series.latest?.id }
    }

    private func selectionDimming(for point: LooprPlottedPoint) -> Bool {
        guard let selectedDate else { return false }
        return series.bucketStart(for: selectedDate) != point.date
    }

    private func barStyle(for point: LooprPlottedPoint) -> AnyShapeStyle {
        if selectionDimming(for: point) {
            return AnyShapeStyle(Color.loopr(accent).opacity(0.28))
        }
        let isLatest = point.id == series.latest?.id && selectedDate == nil
        return AnyShapeStyle(
            LinearGradient(
                colors: [Color.loopr(accent), Color.loopr(accent).opacity(isLatest ? 0.85 : 0.55)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private var areaGradient: LinearGradient {
        LinearGradient(
            colors: [Color.loopr(accent).opacity(isDark ? 0.24 : 0.18), Color.loopr(accent).opacity(0.0)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var isDark: Bool { LooprAppearance.isDark(colorScheme) }

    private var accessibilitySummary: String {
        LooprTrendAxis.accessibilitySummary(series: series, unit: unit, valueFormat: valueFormat)
    }

    private var descriptor: LooprTrendChartDescriptor {
        LooprTrendChartDescriptor(
            title: title,
            unit: unit,
            summary: accessibilitySummary,
            series: series,
            isContinuous: kind == .line,
            valueFormat: valueFormat
        )
    }
}

/// The latest-value marker: an accent core with a background ring and a soft
/// halo, so it reads on the line and on the area fill.
struct LooprChartEndDot: View {
    let accent: LooprColorToken
    var prominent = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.loopr(accent).opacity(prominent ? 0.22 : 0.18))
                .frame(width: prominent ? 22 : 18, height: prominent ? 22 : 18)
            Circle()
                .fill(Color.loopr(accent))
                .frame(width: prominent ? 10 : 9, height: prominent ? 10 : 9)
                .overlay {
                    Circle().strokeBorder(Color.loopr(.background), lineWidth: 2)
                }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Axis and accessibility helpers

enum LooprTrendAxis {
    /// Doubles `step` until the domain holds at most four gridlines.
    static func yStride(step: Double, domain: ClosedRange<Double>) -> Double {
        var stride = step
        while (domain.upperBound - domain.lowerBound) / stride > 4 { stride *= 2 }
        return stride
    }

    /// Label positions, centred on the day (or week) they name.
    static func dates(for series: LooprChartSeries, dense: Bool, calendar: Calendar = .current) -> [Date] {
        let window = series.window
        func noon(_ date: Date) -> Date { calendar.date(byAdding: .hour, value: 12, to: date) ?? date }
        switch window.dayCount {
        case ...10:
            let step = dense ? 2 : 1
            return stride(from: 0, to: window.dayCount, by: step).compactMap { offset in
                calendar.date(byAdding: .day, value: -offset, to: series.lastDay).map(noon)
            }.reversed()
        case ...40:
            // Weekly labels counted from the first day, so none sits on the
            // trailing edge where the value axis would clip it.
            let step = dense ? 14 : 7
            return stride(from: 2, to: window.dayCount - 3, by: step).compactMap { offset in
                calendar.date(byAdding: .day, value: offset, to: series.start).map(noon)
            }
        default:
            let monthStep = window.dayCount > 120 ? (dense ? 3 : 2) : 1
            var dates: [Date] = []
            var cursor = calendar.dateInterval(of: .month, for: series.lastDay)?.start ?? series.lastDay
            // Skip a month start that falls in the last few days: its label
            // would run into the value axis.
            if let edge = calendar.date(byAdding: .day, value: -(window.dayCount / 12), to: series.lastDay), cursor > edge,
               let previous = calendar.date(byAdding: .month, value: -1, to: cursor) {
                cursor = previous
            }
            while cursor >= series.start {
                dates.append(cursor)
                guard let previous = calendar.date(byAdding: .month, value: -monthStep, to: cursor) else { break }
                cursor = previous
            }
            return dates.reversed()
        }
    }

    /// Every day label carries its weekday: "TUE" over "22" in the week
    /// view, "FRI" over "4 SEP" in the month view. Longer views label months.
    static func label(for date: Date, window: LooprChartWindow, calendar: Calendar = .current) -> String {
        switch window.dayCount {
        case ...10: LooprChartDateText.string(date, "EEE'\n'd", calendar: calendar).uppercased()
        case ...40: LooprChartDateText.string(date, "EEE'\n'd MMM", calendar: calendar).uppercased()
        default: LooprChartDateText.string(date, "MMM", calendar: calendar).uppercased()
        }
    }

    static func accessibilitySummary(series: LooprChartSeries, unit: String, valueFormat: (Double) -> String) -> String {
        guard let latest = series.latest else {
            return "No readings in the last \(series.window.dayCount) days"
        }
        let values = series.points.map(\.value)
        var parts = ["\(series.measuredDays) of \(series.window.dayCount) days measured"]
        if let low = values.min(), let high = values.max() {
            parts.append("lowest \(valueFormat(low)) \(unit)")
            parts.append("highest \(valueFormat(high)) \(unit)")
        }
        parts.append("latest \(valueFormat(latest.value)) \(unit) on \(latest.date.formatted(date: .abbreviated, time: .omitted))")
        if let band = series.baseline {
            parts.append("usual range \(valueFormat(band.lower)) to \(valueFormat(band.upper)) \(unit)")
        }
        return parts.joined(separator: ", ")
    }
}

/// Gives VoiceOver users the audio graph and a data table for the chart.
struct LooprTrendChartDescriptor: AXChartDescriptorRepresentable {
    let title: String
    let unit: String
    let summary: String
    let series: LooprChartSeries
    let isContinuous: Bool
    let valueFormat: @Sendable (Double) -> String

    func makeChartDescriptor() -> AXChartDescriptor {
        let domain = series.xDomain()
        let format = valueFormat
        let xAxis = AXNumericDataAxisDescriptor(
            title: "Date",
            range: domain.lowerBound.timeIntervalSince1970...domain.upperBound.timeIntervalSince1970,
            gridlinePositions: []
        ) { value in
            Date(timeIntervalSince1970: value).formatted(date: .abbreviated, time: .omitted)
        }
        let yAxis = AXNumericDataAxisDescriptor(
            title: unit,
            range: series.yDomain,
            gridlinePositions: []
        ) { value in
            format(value)
        }
        let data = AXDataSeriesDescriptor(
            name: title,
            isContinuous: isContinuous,
            dataPoints: series.points.map { point in
                AXDataPoint(x: point.date.timeIntervalSince1970, y: point.value)
            }
        )
        return AXChartDescriptor(
            title: title,
            summary: summary,
            xAxis: xAxis,
            yAxis: yAxis,
            additionalAxes: [],
            series: [data]
        )
    }
}
