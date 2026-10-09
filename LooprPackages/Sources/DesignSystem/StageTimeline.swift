import SwiftUI

public extension SleepStage {
    /// The stage's name on screen: "Awake", "REM", "Light", "Deep".
    var title: String {
        switch self {
        case .awake: "Awake"
        case .rem: "REM"
        case .light: "Light"
        case .deep: "Deep"
        }
    }

    /// The stage's colour token, the same one `Hypnogram` uses.
    var token: LooprColorToken { color }
}

/// One continuous stretch of one sleep stage with clock times.
public struct LooprStageSpan: Identifiable, Hashable, Sendable {
    public let id: Int
    public let stage: SleepStage
    public let start: Date
    public let end: Date

    public init(id: Int, stage: SleepStage, start: Date, end: Date) {
        self.id = id
        self.stage = stage
        self.start = min(start, end)
        self.end = max(start, end)
    }

    public var minutes: Double { end.timeIntervalSince(start) / 60 }

    /// Lays `segments` end to end from `start`, which is how the derivation
    /// hands the night over (`SleepDaySnapshot.hypnogram` plus the main
    /// sleep's start). Segments with no length are skipped.
    public static func spans(from segments: [SleepSegment], start: Date) -> [LooprStageSpan] {
        var cursor = start
        var result: [LooprStageSpan] = []
        for segment in segments where segment.durationMinutes > 0 {
            let end = cursor.addingTimeInterval(Double(segment.durationMinutes) * 60)
            result.append(LooprStageSpan(id: segment.id, stage: segment.stage, start: cursor, end: end))
            cursor = end
        }
        return result
    }
}

/// The arithmetic and words behind `LooprStageTimeline`, testable on its own.
public struct LooprStageTimelineModel: Hashable, Sendable {
    public let spans: [LooprStageSpan]
    public let timeZone: TimeZone
    /// Stage minutes to report instead of the spans' own sums, for a caller
    /// whose totals come from finer epochs than the drawn minutes (the sleep
    /// derivation's 30-second accounting). Drawing still uses the spans.
    public let stageTotals: [SleepStage: Double]?

    public init(spans: [LooprStageSpan], timeZone: TimeZone = .current, stageTotals: [SleepStage: Double]? = nil) {
        self.spans = spans.sorted { $0.start < $1.start }
        self.timeZone = timeZone
        self.stageTotals = stageTotals.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Lanes from top to bottom, lightest sleep first, as in the hypnogram.
    public static let laneOrder: [SleepStage] = [.awake, .rem, .light, .deep]

    public var start: Date? { spans.first?.start }
    public var end: Date? { spans.map(\.end).max() }

    /// The span under `date`, or nil in a gap or outside the night.
    public func span(at date: Date) -> LooprStageSpan? {
        spans.first { $0.start <= date && date < $0.end } ?? spans.last.flatMap { $0.end == date ? $0 : nil }
    }

    /// Whole minutes per stage.
    public var totals: [SleepStage: Double] {
        if let stageTotals { return stageTotals }
        return spans.reduce(into: [:]) { $0[$1.stage, default: 0] += $1.minutes }
    }

    /// Minutes asleep: every stage except awake.
    public var asleepMinutes: Double {
        totals.filter { $0.key != .awake }.values.reduce(0, +)
    }

    /// Share of sleep for a stage (awake counts against time in bed instead).
    public func share(of stage: SleepStage) -> Double? {
        let total = stage == .awake ? totals.values.reduce(0, +) : asleepMinutes
        guard total > 0 else { return nil }
        return (totals[stage] ?? 0) / total
    }

    /// "23:18 to 23:56 · Deep · 38 min"
    public func readout(for span: LooprStageSpan) -> String {
        "\(clock(span.start)) to \(clock(span.end)) · \(span.stage.title) · \(LooprUnitFormatter.duration(minutes: span.minutes) ?? "")"
    }

    /// "Deep · 1 h 22 m · 18% of sleep"
    public func highlightSummary(for stage: SleepStage) -> String {
        let minutes = LooprUnitFormatter.duration(minutes: totals[stage] ?? 0) ?? "0 min"
        guard let share = share(of: stage) else { return "\(stage.title) · \(minutes)" }
        let percent = Int((share * 100).rounded())
        return "\(stage.title) · \(minutes) · \(percent)% of \(stage == .awake ? "time in bed" : "sleep")"
    }

    /// Whole-hour ticks between the ends of the night, at a step that keeps
    /// at most `maximum` of them and none too close to either end label.
    public func hourTicks(maximum: Int = 3, calendar: Calendar = .current) -> [Date] {
        guard let start, let end, end > start, maximum > 0 else { return [] }
        var calendar = calendar
        calendar.timeZone = timeZone
        let span = end.timeIntervalSince(start)
        let margin = span * 0.2
        let hours = span / 3_600
        let step = max(1, Int((hours / Double(maximum + 1)).rounded()))
        guard var tick = calendar.nextDate(after: start, matching: DateComponents(minute: 0, second: 0), matchingPolicy: .nextTime) else {
            return []
        }
        var ticks: [Date] = []
        while tick < end {
            let hour = calendar.component(.hour, from: tick)
            if hour % step == 0, tick.timeIntervalSince(start) >= margin, end.timeIntervalSince(tick) >= margin {
                ticks.append(tick)
            }
            tick = tick.addingTimeInterval(3_600)
        }
        return Array(ticks.prefix(maximum))
    }

    /// The spoken summary: "Sleep stages from 23:02 to 06:50. Deep 1 hour 22
    /// minutes, REM 1 hour 36 minutes, Light 4 hours 44 minutes, Awake 46
    /// minutes."
    public var accessibilitySummary: String {
        guard let start, let end else { return "No sleep stages for this night" }
        let parts = Self.laneOrder.reversed().compactMap { stage -> String? in
            guard let minutes = totals[stage], minutes > 0 else { return nil }
            return "\(stage.title) \(LooprUnitFormatter.spokenDuration(minutes: minutes) ?? "")"
        }
        return "Sleep stages from \(clock(start)) to \(clock(end)). " + parts.joined(separator: ", ") + "."
    }

    public func clock(_ date: Date) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        style.timeZone = timeZone
        return date.formatted(style)
    }

    func tickLabel(_ date: Date) -> String {
        clock(date)
    }
}

/// The night as four stage lanes on a clock axis, touchable.
///
/// - Hold and drag to read a stretch: "23:18 to 23:56 · Deep · 38 min" appears
///   in the line above the lanes and the stretch lights up.
/// - Tap a lane name to highlight that stage across the night; tap again to
///   clear. The highlight is a binding, so the Sleep tab's stage rows can
///   drive it too.
/// - `selection` exposes the scrubbed moment, so a heart-rate line drawn
///   above can show the same time.
///
/// ```swift
/// @State private var stage: SleepStage?
/// LooprSurface {
///     LooprStageTimeline(
///         segments: snapshot.hypnogram,
///         start: snapshot.mainSleep!.start,
///         highlightedStage: $stage
///     )
/// }
/// ```
///
/// With no spans it shows a quiet "No sleep stages for this night" line
/// instead of empty lanes.
public struct LooprStageTimeline: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .caption) private var laneHeight: CGFloat = 24
    @ScaledMetric(relativeTo: .caption) private var rawLabelWidth: CGFloat = 46

    @Binding private var highlightedStage: SleepStage?
    private let externalSelection: Binding<Date?>?
    @State private var internalSelection: Date?
    @State private var revealed = false

    private let model: LooprStageTimelineModel
    private let identifier: String
    /// An optional line above the lanes on the same clock axis, such as the
    /// overnight heart rate.
    private let line: LooprStageTimelineLine?
    @ScaledMetric(relativeTo: .caption) private var lineHeight: CGFloat = 64

    /// Lane names stop growing at xxxLarge, so the lanes keep their width.
    private var labelWidth: CGFloat { min(rawLabelWidth, 62) }

    public init(
        spans: [LooprStageSpan],
        highlightedStage: Binding<SleepStage?> = .constant(nil),
        selection: Binding<Date?>? = nil,
        timeZone: TimeZone = .current,
        identifier: String = "loopr-stage-timeline",
        line: LooprStageTimelineLine? = nil,
        stageTotals: [SleepStage: Double]? = nil
    ) {
        model = LooprStageTimelineModel(spans: spans, timeZone: timeZone, stageTotals: stageTotals)
        _highlightedStage = highlightedStage
        externalSelection = selection
        self.identifier = identifier
        self.line = line.flatMap { $0.points.isEmpty ? nil : $0 }
    }

    public init(
        segments: [SleepSegment],
        start: Date,
        highlightedStage: Binding<SleepStage?> = .constant(nil),
        selection: Binding<Date?>? = nil,
        timeZone: TimeZone = .current,
        identifier: String = "loopr-stage-timeline",
        line: LooprStageTimelineLine? = nil,
        stageTotals: [SleepStage: Double]? = nil
    ) {
        self.init(spans: LooprStageSpan.spans(from: segments, start: start), highlightedStage: highlightedStage,
                  selection: selection, timeZone: timeZone, identifier: identifier, line: line, stageTotals: stageTotals)
    }

    public var body: some View {
        if model.spans.isEmpty {
            Text("No sleep stages for this night")
                .looprTypography(.caption)
                .foregroundStyle(Color.loopr(.inkSecondary))
                .frame(maxWidth: .infinity, minHeight: laneHeight * 2, alignment: .leading)
                .accessibilityIdentifier(identifier)
        } else {
            VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                readoutLine
                if let line {
                    lineRow(line)
                }
                HStack(alignment: .top, spacing: LooprSpacing.xs) {
                    laneLabels
                    VStack(spacing: LooprSpacing.xxs + 2) {
                        lanes
                        axis
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(identifier)
            .onAppear(perform: reveal)
        }
    }

    // MARK: Pieces

    private var readoutLine: some View {
        let scrubbed = selection.flatMap(model.span(at:))
        let text: String
        let emphasised: Bool
        if let scrubbed {
            text = model.readout(for: scrubbed)
            emphasised = true
        } else if let highlightedStage {
            text = model.highlightSummary(for: highlightedStage)
            emphasised = true
        } else {
            text = "Hold and drag to read the night"
            emphasised = false
        }
        return Text(text)
            .looprTypography(emphasised ? .metricUnit : .caption)
            .fontWeight(emphasised ? .semibold : .regular)
            .foregroundStyle(Color.loopr(emphasised ? .ink : .inkSecondary))
            .monospacedDigit()
            // One line, capped like the chart's other labels: a wrapped
            // readout at accessibility sizes drew over the heart-rate line.
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
            .padding(.leading, dynamicTypeSize.isAccessibilitySize ? 0 : labelWidth + LooprSpacing.xs)
            .accessibilityHidden(true)
    }

    /// The line above the lanes: its scale in the label column, the line in
    /// the lane column, scrubbable like the lanes.
    private func lineRow(_ line: LooprStageTimelineLine) -> some View {
        HStack(alignment: .top, spacing: LooprSpacing.xs) {
            VStack(alignment: .trailing, spacing: 0) {
                Text(line.domain.map { "\(Int($0.upperBound.rounded()))" } ?? "")
                Spacer(minLength: 0)
                Text(line.unit)
                    .foregroundStyle(Color.loopr(line.accent.textInk))
                Spacer(minLength: 0)
                Text(line.domain.map { "\(Int($0.lowerBound.rounded()))" } ?? "")
            }
            .looprTypography(.confidence)
            .monospacedDigit()
            .foregroundStyle(Color.loopr(.inkSecondary))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .frame(width: labelWidth, height: lineHeight, alignment: .trailing)
            .accessibilityHidden(true)

            GeometryReader { proxy in
                let width = proxy.size.width
                LooprStageTimelineLineView(line: line, model: model, selection: selection,
                                           highlightedStage: highlightedStage, revealed: revealed || reduceMotion)
                    .contentShape(Rectangle())
                    .looprScrub { x in
                        guard let x, let start = model.start, let end = model.end else {
                            setSelection(nil)
                            return
                        }
                        setSelection(LooprScrubMath.date(x: x, width: width, start: start, end: end))
                    }
            }
            .frame(height: lineHeight)
            .accessibilityElement()
            .accessibilityLabel(line.title)
            .accessibilityValue(line.accessibilitySummary)
            .accessibilityIdentifier("\(identifier)-line")
        }
    }

    private var laneLabels: some View {
        VStack(alignment: .trailing, spacing: 0) {
            ForEach(LooprStageTimelineModel.laneOrder, id: \.self) { stage in
                Button {
                    withAnimation(reduceMotion ? nil : .snappy(duration: LooprMotion.fast)) {
                        highlightedStage = highlightedStage == stage ? nil : stage
                    }
                } label: {
                    Text(stage.title)
                        .looprTypography(.metricUnit)
                        .fontWeight(highlightedStage == stage ? .semibold : .regular)
                        .foregroundStyle(Color.loopr(labelToken(for: stage)))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                        .frame(width: labelWidth, height: laneHeight, alignment: .trailing)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(stage.title), \(LooprUnitFormatter.spokenDuration(minutes: model.totals[stage] ?? 0) ?? "")")
                .accessibilityHint(highlightedStage == stage ? "Clears the highlight" : "Highlights this stage across the night")
                .accessibilityAddTraits(highlightedStage == stage ? [.isButton, .isSelected] : .isButton)
                .accessibilityIdentifier("\(identifier)-lane-\(stage.rawValue)")
            }
        }
    }

    private var lanes: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            Canvas { context, size in
                draw(in: &context, size: size)
            }
            .mask(alignment: .leading) {
                Rectangle().frame(width: revealed || reduceMotion ? width : 0)
            }
            .overlay(alignment: .topLeading) {
                if let selection, let start = model.start, let end = model.end {
                    Rectangle()
                        .fill(Color.loopr(.ink).opacity(isDark ? 0.6 : 0.5))
                        .frame(width: 1, height: proxy.size.height)
                        .offset(x: LooprScrubMath.x(for: selection, width: width, start: start, end: end) - 0.5)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .looprScrub { x in
                guard let x, let start = model.start, let end = model.end else {
                    setSelection(nil)
                    return
                }
                setSelection(LooprScrubMath.date(x: x, width: width, start: start, end: end))
            }
            .accessibilityElement()
            .accessibilityLabel("Sleep stages")
            .accessibilityValue(model.accessibilitySummary)
            .accessibilityIdentifier("\(identifier)-lanes")
        }
        .frame(height: laneHeight * CGFloat(LooprStageTimelineModel.laneOrder.count))
    }

    private var axis: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            if let start = model.start, let end = model.end {
                ZStack {
                    ForEach(dynamicTypeSize.isAccessibilitySize ? [] : model.hourTicks(), id: \.self) { tick in
                        Text(model.tickLabel(tick))
                            .foregroundStyle(Color.loopr(.inkSecondary))
                            .fixedSize()
                            .position(x: LooprScrubMath.x(for: tick, width: width, start: start, end: end), y: 7)
                    }
                    HStack {
                        Text(model.clock(start))
                        Spacer(minLength: LooprSpacing.xs)
                        Text(model.clock(end))
                    }
                    .foregroundStyle(Color.loopr(.ink))
                    .frame(height: 14)
                    .frame(maxHeight: .infinity, alignment: .top)
                }
                .looprTypography(.confidence)
                .monospacedDigit()
            }
        }
        .frame(height: 14)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .accessibilityHidden(true)
    }

    // MARK: Drawing

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        guard let start = model.start, let end = model.end else { return }
        let lanes = LooprStageTimelineModel.laneOrder
        let rowHeight = size.height / CGFloat(lanes.count)
        let barHeight = max(6, min(rowHeight * 0.62, 16))
        let scrubbed = selection.flatMap(model.span(at:))

        for (index, _) in lanes.enumerated() {
            let track = CGRect(x: 0, y: CGFloat(index) * rowHeight + (rowHeight - barHeight) / 2, width: size.width, height: barHeight)
            context.fill(Path(roundedRect: track, cornerRadius: barHeight / 2),
                         with: .color(Color.loopr(.ink).opacity(isDark ? 0.05 : 0.045)))
        }

        func x(_ date: Date) -> CGFloat { LooprScrubMath.x(for: date, width: size.width, start: start, end: end) }
        func laneY(_ stage: SleepStage) -> CGFloat {
            CGFloat(lanes.firstIndex(of: stage) ?? 0) * rowHeight + rowHeight / 2
        }

        var previous: LooprStageSpan?
        for span in model.spans {
            if let previous, previous.stage != span.stage, abs(previous.end.timeIntervalSince(span.start)) < 1 {
                var connector = Path()
                let cx = x(span.start)
                connector.move(to: CGPoint(x: cx, y: laneY(previous.stage)))
                connector.addLine(to: CGPoint(x: cx, y: laneY(span.stage)))
                context.stroke(connector, with: .color(Color.loopr(.inkMuted).opacity(dimmed(span) || dimmed(previous) ? 0.12 : 0.35)),
                               lineWidth: 1)
            }
            let left = x(span.start)
            let width = max(x(span.end) - left, 1.5)
            let rect = CGRect(x: left, y: laneY(span.stage) - barHeight / 2, width: width, height: barHeight)
            let isScrubbed = scrubbed?.id == span.id
            let opacity: Double = if scrubbed != nil { isScrubbed ? 1 : 0.3 } else { dimmed(span) ? 0.2 : 1 }
            context.fill(Path(roundedRect: rect, cornerRadius: min(3, width / 2)),
                         with: .color(Color.loopr(span.stage.token).opacity(opacity)))
            previous = span
        }
    }

    private func dimmed(_ span: LooprStageSpan) -> Bool {
        guard let highlightedStage else { return false }
        return span.stage != highlightedStage
    }

    private func labelToken(for stage: SleepStage) -> LooprColorToken {
        guard let highlightedStage else { return .inkSecondary }
        return highlightedStage == stage ? .ink : .inkMuted
    }

    // MARK: State

    private var selection: Date? { externalSelection?.wrappedValue ?? internalSelection }

    private func setSelection(_ date: Date?) {
        if let externalSelection {
            externalSelection.wrappedValue = date
        } else {
            internalSelection = date
        }
    }

    private func reveal() {
        guard !revealed else { return }
        if reduceMotion {
            revealed = true
        } else {
            withAnimation(.easeOut(duration: LooprMotion.deliberate * 1.4)) { revealed = true }
        }
    }

    private var reduceMotion: Bool { accessibilityReduceMotion || DesignSystemRuntime.state().reduceMotion == true }
    private var isDark: Bool { LooprAppearance.isDark(colorScheme) }
}

#Preview("Stage timeline") {
    @Previewable @State var stage: SleepStage?
    let start = Calendar.current.date(bySettingHour: 22, minute: 52, second: 0, of: Date())!
    LooprSurface {
        LooprStageTimeline(segments: LooprSampleNight.segments, start: start, highlightedStage: $stage)
    }
    .padding()
    .background(Color.loopr(.background))
}
