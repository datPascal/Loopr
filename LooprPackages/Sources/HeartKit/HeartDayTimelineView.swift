import SwiftUI
import Charts
import DesignSystem

/// The selected day's heart rate: the day's lowest, average and highest, then
/// 5-minute averages with their lowest to highest band, sleep shaded,
/// workouts marked, and hold to read a time.
struct HeartDayTimelineCard: View {
    let state: HeartTabModel.TimelineState
    /// "yesterday", "on Tue 22 Sep": finishes "Nothing recorded …".
    let dayPhrase: String

    var body: some View {
        switch state {
        case .unavailable:
            EmptyView()
        case .loading:
            LooprSurface {
                VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                    LooprSkeleton(height: 168).frame(maxWidth: .infinity)
                    LooprSkeleton(height: 36).frame(maxWidth: .infinity)
                }
            }
            .accessibilityIdentifier("heart-day-timeline-loading")
        case .loaded(let timeline):
            if let timeline, !timeline.isEmpty {
                HeartDayTimelineContent(timeline: timeline).id(timeline.dayStart)
            } else {
                LooprSurface {
                    LooprText("No heart rate recorded \(dayPhrase).", style: .prose, color: .inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityIdentifier("heart-day-timeline-empty")
            }
        }
    }
}

private struct HeartDayTimelineContent: View {
    let timeline: HeartDayTimeline
    @Environment(\.heartTabServices) private var services
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var scrubDate: Date?
    @State private var visibleSeconds: TimeInterval
    @State private var scrollStart: Date
    @State private var plotWidth: Double = 300
    @State private var fineTimeline: HeartDayTimeline?
    @State private var readFailed = false
    @State private var dataRevision = 0

    init(timeline: HeartDayTimeline) {
        self.timeline = timeline
        _scrollStart = State(initialValue: timeline.dayStart)
        _visibleSeconds = State(initialValue: timeline.dayEnd.timeIntervalSince(timeline.dayStart))
    }

    private var dayDuration: TimeInterval { timeline.dayEnd.timeIntervalSince(timeline.dayStart) }
    private var shownTimeline: HeartDayTimeline { fineTimeline ?? timeline }
    private var request: HeartTimelineRangeRequest {
        let duration = min(visibleSeconds, timeline.dayEnd.timeIntervalSince(timeline.dayStart))
        let start = min(max(scrollStart, timeline.dayStart), timeline.dayEnd.addingTimeInterval(-duration))
        return HeartTimelineRangeRequest(start: start, end: start.addingTimeInterval(duration), pixelWidth: plotWidth)
    }
    private struct LoadKey: Equatable {
        let request: HeartTimelineRangeRequest
        let revision: Int
        let dataRevision: Int
    }

    var body: some View {
        LooprSurface {
            VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                // The numbers sit above the chart; while a finger holds the
                // chart, the reading under it takes their place.
                Group {
                    if let scrubDate {
                        readout(scrubDate)
                    } else if let summary = timeline.summary {
                        summaryRow(summary)
                    }
                }
                .frame(minHeight: 44, alignment: .topLeading)
                HeartDayTimelineChart(timeline: shownTimeline, scrubDate: $scrubDate,
                    visibleSeconds: min(visibleSeconds, timeline.dayEnd.timeIntervalSince(timeline.dayStart)), scrollStart: $scrollStart)
                    .frame(height: 186)
                    .onGeometryChange(for: Double.self, of: { Double($0.size.width.rounded()) }) { width in
                        if plotWidth != width { plotWidth = width }
                    }
                zoomControls
                if readFailed {
                    LooprText("Could not load finer readings. Showing the day summary.", style: .caption, color: .inkSecondary)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: LooprSpacing.sm) {
                        legends
                        Spacer(minLength: 0)
                        LooprText("Hold to read", style: .caption, color: .inkMuted)
                    }
                    .lineLimit(1)
                    VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                        legends
                        LooprText("Hold to read", style: .caption, color: .inkMuted)
                    }
                }
                .accessibilityHidden(true)
                if timeline.hasUnconfirmed {
                    LooprText(Self.unconfirmedNote, style: .caption, color: .inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Heart rate over the day")
        .accessibilityValue(spokenSummary)
        .accessibilityIdentifier("heart-day-timeline")
        .onChange(of: timeline) { _, _ in dataRevision += 1 }
        .task(id: LoadKey(request: request, revision: services?.revision ?? 0, dataRevision: dataRevision)) {
            await loadRange(request)
        }
    }

    private var zoomControls: some View {
        HStack(spacing: LooprSpacing.xxs) {
            Button { zoom(to: min(dayDuration, visibleSeconds * 2)) } label: {
                Image(systemName: "minus.magnifyingglass")
                    .looprTypography(.label)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .disabled(visibleSeconds >= dayDuration)
            .accessibilityLabel("Zoom out")
            LooprText(rangeLabel, style: .metricUnit, color: .inkSecondary)
                .monospacedDigit()
                .fixedSize()
                .accessibilityIdentifier("heart-timeline-range")
            Button { zoom(to: max(900, visibleSeconds / 2)) } label: {
                Image(systemName: "plus.magnifyingglass")
                    .looprTypography(.label)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .disabled(visibleSeconds <= 900)
            .accessibilityLabel("Zoom in")
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.loopr(.inkSecondary))
        .padding(.horizontal, LooprSpacing.xxs)
        .background(Color.loopr(.ink).opacity(0.05), in: Capsule())
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("heart-timeline-zoom")
    }

    private var rangeLabel: String {
        if visibleSeconds >= dayDuration { return "Full day" }
        if visibleSeconds.truncatingRemainder(dividingBy: 3600) == 0 { return "\(Int(visibleSeconds / 3600)) h" }
        return "\(Int(visibleSeconds / 60)) min"
    }

    private func zoom(to duration: TimeInterval) {
        let center = (scrubDate ?? request.start.addingTimeInterval(request.end.timeIntervalSince(request.start) / 2))
        scrubDate = nil
        visibleSeconds = duration
        scrollStart = min(max(timeline.dayStart, center.addingTimeInterval(-duration / 2)),
            max(timeline.dayStart, timeline.dayEnd.addingTimeInterval(-duration)))
        // No animated axis rescaling: it keeps the selected time stable and
        // also respects Reduce Motion without a second code path.
    }

    private func loadRange(_ range: HeartTimelineRangeRequest) async {
        guard let loader = services?.timelineRange, visibleSeconds < dayDuration else {
            fineTimeline = nil; readFailed = false; return
        }
        do {
            // Cancel/debounce pans before opening SQLite. Unchanged range
            // keys do no work, and SwiftUI cancels superseded range tasks.
            try await Task.sleep(for: .milliseconds(150))
            let samples = try await loader(range)
            try Task.checkCancellation()
            let coarse = timeline
            let next = await Task.detached(priority: .userInitiated) {
                let fine = HeartTimelineRange.downsample(samples, request: range, unconfirmed: coarse.buckets)
                let outside = coarse.buckets.filter { $0.end <= range.start || $0.start >= range.end }
                return HeartDayTimeline(dayStart: coarse.dayStart, dayEnd: coarse.dayEnd, bucketSeconds: coarse.bucketSeconds,
                    buckets: (outside + fine).sorted { $0.start < $1.start }, sleep: coarse.sleep, workouts: coarse.workouts, summary: coarse.summary)
            }.value
            try Task.checkCancellation()
            if fineTimeline != next { fineTimeline = next }
            readFailed = false
        } catch {
            guard !Task.isCancelled else { return }
            fineTimeline = nil; readFailed = true
        }
    }

    static let unconfirmedNote = "Grey marks times your wrist was still but the band's heart rate and its beat timing disagreed. They are left out of the numbers above."

    private func summaryRow(_ summary: HeartTimelineSummary) -> some View {
        // Three columns, or three lines when large text will not fit them.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: LooprSpacing.xs) {
                stat("Lowest", summary.lowest)
                stat("Average", summary.average)
                stat("Highest", summary.highest)
            }
            VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                statLine("Lowest", summary.lowest)
                statLine("Average", summary.average)
                statLine("Highest", summary.highest)
            }
        }
    }

    private func statLine(_ title: String, _ value: Double) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline))
        return layout {
            LooprText(title.uppercased(), style: .sectionLabel, color: .inkSecondary)
            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: LooprSpacing.xs) }
            LooprValueText(String(Int(value.rounded())), unit: "bpm")
        }
    }

    private func stat(_ title: String, _ value: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            LooprText(title.uppercased(), style: .sectionLabel, color: .inkSecondary)
            LooprValueText(String(Int(value.rounded())), unit: "bpm")
                .fixedSize()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func readout(_ date: Date) -> some View {
        let bucket = shownTimeline.bucket(at: date)
        let span = timeline.span(at: date)
        let includesSeconds = bucket.map { $0.end.timeIntervalSince($0.start) < 60 } ?? (visibleSeconds <= 3600)
        var title = bucket.map { "\(HeartDayTimelineChart.time($0.start, includesSeconds: includesSeconds)) to \(HeartDayTimelineChart.time($0.end, includesSeconds: includesSeconds))" }
            ?? HeartDayTimelineChart.time(date, includesSeconds: includesSeconds)
        if let span { title += " · " + (span.kind == .sleep ? "Asleep" : (span.title ?? "Workout")) }
        return VStack(alignment: .leading, spacing: 2) {
            LooprText(title.uppercased(), style: .sectionLabel, color: .inkSecondary)
            if let bucket {
                HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.xs) {
                    LooprValueText(String(Int(bucket.average.rounded())), unit: "bpm",
                                   color: bucket.isUnconfirmed ? .inkSecondary : .ink)
                    LooprText("Range \(Int(bucket.minimum.rounded())) to \(Int(bucket.maximum.rounded()))",
                              style: .metricUnit, color: .inkSecondary)
                    if bucket.isUnconfirmed {
                        LooprText("Unconfirmed", style: .caption, color: .inkSecondary)
                    }
                }
            } else {
                LooprText("No reading", style: .prose, color: .inkSecondary)
            }
        }
        .accessibilityIdentifier("heart-timeline-readout")
    }

    @ViewBuilder
    private var legends: some View {
        if !timeline.sleep.isEmpty { legend(.sleep, "Sleep") }
        if !timeline.workouts.isEmpty { legend(.strain, "Workout") }
        if timeline.hasUnconfirmed { legend(.inkMuted, "Unconfirmed") }
    }

    private func legend(_ token: LooprColorToken, _ title: String) -> some View {
        HStack(spacing: LooprSpacing.xxs) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.loopr(token).opacity(0.35))
                .frame(width: 10, height: 10)
            LooprText(title, style: .caption, color: .inkSecondary)
        }
    }

    private var spokenSummary: String {
        var parts: [String] = []
        if let summary = timeline.summary {
            parts.append("Lowest \(Int(summary.lowest.rounded())), average \(Int(summary.average.rounded())), highest \(Int(summary.highest.rounded())) beats per minute")
        }
        if !timeline.sleep.isEmpty {
            parts.append(timeline.sleep.map { "Asleep \(HeartDayTimelineChart.time($0.start)) to \(HeartDayTimelineChart.time($0.end))" }.joined(separator: ", "))
        }
        for workout in timeline.workouts {
            var text = "\(workout.title ?? "Workout") \(HeartDayTimelineChart.time(workout.start)) to \(HeartDayTimelineChart.time(workout.end))"
            if let peak = timeline.peak(in: workout) { text += ", peak \(Int(peak.average.rounded()))" }
            parts.append(text)
        }
        if timeline.hasUnconfirmed { parts.append(Self.unconfirmedNote) }
        return parts.joined(separator: ". ")
    }
}

struct HeartDayTimelineChart: View {
    let timeline: HeartDayTimeline
    @Binding var scrubDate: Date?
    let visibleSeconds: TimeInterval
    @Binding var scrollStart: Date
    @State private var plotBounds: CGRect = .zero

    var body: some View {
        let domain = timeline.yDomain()
        Chart {
            ForEach(timeline.sleep) { span in
                RectangleMark(xStart: .value("Sleep start", span.start), xEnd: .value("Sleep end", span.end),
                    yStart: .value("Low", domain.lowerBound), yEnd: .value("High", domain.upperBound))
                    .foregroundStyle(Color.loopr(.sleep).opacity(0.12))
                    .accessibilityLabel("Sleep, \(Self.time(span.start)) to \(Self.time(span.end))")
            }
            ForEach(timeline.workouts) { span in
                RectangleMark(xStart: .value("Workout start", span.start), xEnd: .value("Workout end", span.end),
                    yStart: .value("Low", domain.lowerBound), yEnd: .value("High", domain.upperBound))
                    .foregroundStyle(Color.loopr(.strain).opacity(0.16))
                    .accessibilityLabel("\(span.title ?? "Workout"), \(Self.time(span.start)) to \(Self.time(span.end))")
            }
            ForEach(Array(timeline.segments.enumerated()), id: \.offset) { index, segment in
                ForEach(segment) { bucket in
                    AreaMark(x: .value("Time", bucket.middle), yStart: .value("Lowest", bucket.minimum),
                        yEnd: .value("Highest", bucket.maximum), series: .value("Segment", index))
                        .foregroundStyle(Color.loopr(bucket.isUnconfirmed ? .inkMuted : .heart).opacity(0.18))
                        .accessibilityHidden(true)
                    LineMark(x: .value("Time", bucket.middle), y: .value("Heart rate", bucket.average), series: .value("Segment", index))
                        .foregroundStyle(Color.loopr(bucket.isUnconfirmed ? .inkSecondary : .heart))
                        .lineStyle(StrokeStyle(lineWidth: 1.6, dash: bucket.isUnconfirmed ? [3, 3] : []))
                        .accessibilityLabel(Self.time(bucket.middle))
                        .accessibilityValue("\(Int(bucket.average.rounded())) beats per minute\(bucket.isUnconfirmed ? ", unconfirmed" : "")")
                    if segment.count == 1 {
                        PointMark(x: .value("Time", bucket.middle), y: .value("Heart rate", bucket.average))
                            .foregroundStyle(Color.loopr(bucket.isUnconfirmed ? .inkSecondary : .heart))
                            .accessibilityHidden(true)
                    }
                }
            }
            if let scrubDate {
                RuleMark(x: .value("Selected time", scrubDate))
                    .foregroundStyle(Color.loopr(.inkMuted))
                    .accessibilityHidden(true)
            }
        }
        .chartXScale(domain: timeline.dayStart...timeline.dayEnd)
        .chartYScale(domain: domain)
        .chartScrollableAxes(.horizontal)
        .chartXVisibleDomain(length: visibleSeconds)
        .chartScrollPosition(x: $scrollStart)
        .chartOverlay { proxy in
            Color.clear
                .onGeometryChange(for: CGRect.self) { geometry in
                    proxy.plotContainerFrame.map { geometry[$0] } ?? .zero
                } action: { bounds in
                    plotBounds = bounds
                }
                .allowsHitTesting(false)
        }
        // The recognizer belongs to the chart parent, so its transparent
        // measurement overlay cannot intercept the scroll view's pans.
        .looprScrub { x in
            guard let x, plotBounds.width > 0 else { return }
            let start = min(max(scrollStart, timeline.dayStart),
                            timeline.dayEnd.addingTimeInterval(-visibleSeconds))
            scrubDate = LooprScrubMath.date(x: x - plotBounds.minX,
                                          width: plotBounds.width,
                                          start: start, end: start.addingTimeInterval(visibleSeconds))
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .minute, count: visibleSeconds <= 3600 ? 15 : visibleSeconds <= 14400 ? 60 : 360)) { value in
                AxisGridLine().foregroundStyle(Color.loopr(.divider))
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(Self.time(date)).looprTypography(.confidence)
                            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                            .foregroundStyle(Color.loopr(.inkMuted))
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine().foregroundStyle(Color.loopr(.divider))
                AxisValueLabel {
                    if let bpm = value.as(Double.self) {
                        Text(String(format: "%.0f", bpm)).looprTypography(.confidence)
                            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                            .foregroundStyle(Color.loopr(.inkMuted))
                    }
                }
            }
        }
        .accessibilityLabel("Heart rate timeline. Swipe to move through the day. Use zoom controls to change the range.")
        .accessibilityValue("\(Self.time(scrollStart)) to \(Self.time(scrollStart.addingTimeInterval(visibleSeconds)))")
        .accessibilityIdentifier("heart-timeline-plot")
    }

    static func time(_ date: Date, includesSeconds: Bool = false) -> String {
        LooprDateFormatterCache.string(from: date, format: includesSeconds ? "HH:mm:ss" : "HH:mm", calendar: .current)
    }
}
