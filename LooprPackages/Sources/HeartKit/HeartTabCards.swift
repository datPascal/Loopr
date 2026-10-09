import SwiftUI
import DesignSystem
import DomainKit

// MARK: Chart geometry

/// Maps dates and values onto a chart's plot rectangle. Pure, so the maths
/// the Heart charts share can be tested.
public struct HeartChartGeometry: Equatable, Sendable {
    public let start: Date
    public let end: Date
    public let domain: ClosedRange<Double>
    public let size: CGSize

    public init(start: Date, end: Date, domain: ClosedRange<Double>, size: CGSize) {
        self.start = start
        self.end = max(end, start.addingTimeInterval(1))
        self.domain = domain.upperBound > domain.lowerBound ? domain : domain.lowerBound...(domain.lowerBound + 1)
        self.size = size
    }

    public func x(_ date: Date) -> CGFloat {
        let fraction = date.timeIntervalSince(start) / end.timeIntervalSince(start)
        return CGFloat(min(max(fraction, 0), 1)) * size.width
    }

    public func y(_ value: Double) -> CGFloat {
        let fraction = (value - domain.lowerBound) / (domain.upperBound - domain.lowerBound)
        return size.height - CGFloat(min(max(fraction, 0), 1)) * size.height
    }

    public func date(atX x: CGFloat) -> Date {
        guard size.width > 0 else { return start }
        let fraction = Double(min(max(x / size.width, 0), 1))
        return start.addingTimeInterval(fraction * end.timeIntervalSince(start))
    }
}

// MARK: Live

/// The live card while the band streams: the number tinted by zone, the zone
/// pill, and the last three minutes as a line.
struct HeartLiveCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.heartTabServices) private var services
    let reading: HeartLiveReading
    /// Nil on the live screen itself, where the card does not navigate.
    let open: (() -> Void)?
    /// The band dropped for a moment. The card keeps the last reading,
    /// dimmed, until the link is back or the app gives up waiting.
    var isReconnecting: Bool = false

    private var spokenText: String {
        isReconnecting ? "Reconnecting. Last live heart rate, \(reading.bpmText) beats per minute" : reading.spokenText
    }

    var body: some View {
        if let open {
            Button(action: open) { card }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(spokenText)
                .accessibilityHint("Opens live heart rate")
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("heart-live-card")
        } else {
            card
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(spokenText)
                .accessibilityIdentifier("heart-live-reading")
        }
    }

    private var card: some View {
            LooprSurface(emphasis: .hero(reading.zone?.token ?? .heart)) {
                VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                    HStack(alignment: .center, spacing: LooprSpacing.xs) {
                        if isReconnecting {
                            Circle()
                                .fill(Color.loopr(.inkMuted))
                                .frame(width: 7, height: 7)
                        } else {
                            TimelineView(.animation(minimumInterval: reduceMotion ? 1 : 1.0 / 30)) { context in
                                let phase = context.date.timeIntervalSinceReferenceDate
                                    .truncatingRemainder(dividingBy: 60 / max(35, reading.bpm))
                                Circle()
                                    .fill(Color.loopr(reading.zone?.token ?? .heart))
                                    .frame(width: 7, height: 7)
                                    .scaleEffect(reduceMotion ? 1 : 1 + 0.28 * exp(-phase * 13))
                            }
                        }
                        LooprText(isReconnecting ? "RECONNECTING" : "LIVE", style: .sectionLabel,
                                  color: isReconnecting ? .inkSecondary : (reading.zone?.textToken ?? .heart))
                            .contentTransition(.opacity)
                        Spacer(minLength: LooprSpacing.xs)
                        if open != nil { LooprChevron() }
                    }
                    HStack(alignment: .bottom, spacing: LooprSpacing.xs) {
                        HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.xs) {
                            Text(reading.bpmText)
                                .looprTypography(.display)
                                .foregroundStyle(Color.loopr(reading.zone?.textToken ?? .ink))
                                .monospacedDigit()
                                .contentTransition(.numericText())
                                .animation(reduceMotion ? nil : .smooth(duration: LooprMotion.standard), value: reading.bpmText)
                                .opacity(isReconnecting ? 0.55 : 1)
                                .accessibilityIdentifier("heart-live-bpm")
                            LooprText("bpm", style: .metricUnit, color: .inkSecondary)
                        }
                        Spacer(minLength: 0)
                        if let zone = reading.zone, !dynamicTypeSize.isAccessibilitySize {
                            HeartCardZoneLabel(zone: zone, range: services?.zones?.zones.bpmRange(for: zone.number))
                        }
                    }
                    if let zone = reading.zone, dynamicTypeSize.isAccessibilitySize {
                        HeartCardZoneLabel(zone: zone, range: services?.zones?.zones.bpmRange(for: zone.number))
                    }
                    if reading.fromBeatToBeat {
                        LooprText("From beat-to-beat intervals", style: .caption, color: .inkSecondary)
                    }
                    HeartLiveLine(reading: reading, zones: services?.zones?.zones)
                        .frame(height: 56)
                        .opacity(isReconnecting ? 0.45 : 1)
                    HStack {
                        LooprText("3 MIN AGO", style: .confidence, color: .inkMuted)
                        Spacer()
                        LooprText("NOW", style: .confidence, color: .inkMuted)
                    }
                    .accessibilityHidden(true)
                }
            }
            .animation(reduceMotion ? nil : .smooth(duration: LooprMotion.standard), value: isReconnecting)
    }
}

private struct HeartCardZoneLabel: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let zone: HeartZone
    let range: ClosedRange<Int>?

    var body: some View {
        VStack(alignment: .trailing, spacing: LooprSpacing.xxs) {
            Text(zone.title)
                .looprTypography(.chip)
                .foregroundStyle(Color.loopr(zone.textToken))
                .padding(.horizontal, LooprSpacing.xs)
                .padding(.vertical, LooprSpacing.xxs)
                .background(Color.loopr(zone.token).opacity(0.14), in: Capsule())
            if let range, !dynamicTypeSize.isAccessibilitySize {
                LooprText("\(range.lowerBound)–\(range.upperBound) bpm", style: .caption, color: .inkSecondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("heart-live-card-zone")
    }
}

struct HeartZonePill: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let zone: HeartZone

    var body: some View {
        Text(dynamicTypeSize.isAccessibilitySize ? zone.title : zone.pillText)
            .looprTypography(.chip)
            // The small pill needs more contrast than the large bpm number.
            .foregroundStyle(Color.loopr(zone.textToken).mix(with: Color.loopr(.ink), by: 0.30))
            .lineLimit(1)
            .padding(.horizontal, LooprSpacing.xs)
            .padding(.vertical, LooprSpacing.xxs)
            .background(Color.loopr(zone.token).opacity(0.14), in: Capsule())
            .accessibilityLabel(zone.spokenText)
    }
}

/// The last three minutes. The line is drawn in the current zone's colour
/// over a faint fill, oldest on the left.
///
/// One `Canvas` draws the zone bands, the fill, the line and the dot. The line
/// is stroked in runs that share a zone, so a three-minute window is a handful
/// of strokes instead of one view per segment.
struct HeartLiveLine: View {
    let reading: HeartLiveReading
    let zones: HeartRateZones?

    var body: some View {
        Canvas { context, size in
            let now = reading.receivedAt
            let geometry = HeartChartGeometry(start: now.addingTimeInterval(-HeartLiveReading.lineSeconds), end: now,
                                              domain: reading.lineDomain, size: size)
            let tint = Color.loopr(reading.zone?.token ?? .heart)
            if let zones {
                for number in 1...5 {
                    guard let range = zones.bpmRange(for: number) else { continue }
                    let top = max(0, min(size.height, geometry.y(Double(range.upperBound))))
                    let bottom = max(0, min(size.height, geometry.y(Double(range.lowerBound))))
                    guard bottom > top else { continue }
                    context.fill(
                        Path(CGRect(x: 0, y: top, width: size.width, height: bottom - top)),
                        with: .color(Color.loopr(HeartZone(number: number, percentOfMax: 0).token).opacity(0.05))
                    )
                }
            }
            let points = reading.line.map { CGPoint(x: geometry.x($0.date), y: geometry.y($0.bpm)) }
            if points.count > 1 {
                var fill = Path()
                fill.move(to: CGPoint(x: points[0].x, y: size.height))
                for point in points { fill.addLine(to: point) }
                fill.addLine(to: CGPoint(x: points[points.count - 1].x, y: size.height))
                fill.closeSubpath()
                context.fill(fill, with: .linearGradient(
                    Gradient(colors: [tint.opacity(0.22), tint.opacity(0)]),
                    startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)
                ))

                let style = StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
                var runToken = token(at: 1)
                var run = Path()
                run.move(to: points[0])
                for index in 1..<points.count {
                    let segmentToken = token(at: index)
                    if segmentToken != runToken {
                        context.stroke(run, with: .color(Color.loopr(runToken)), style: style)
                        run = Path()
                        run.move(to: points[index - 1])
                        runToken = segmentToken
                    }
                    run.addLine(to: points[index])
                }
                context.stroke(run, with: .color(Color.loopr(runToken)), style: style)
            }
            if let last = points.last {
                context.fill(Path(ellipseIn: CGRect(x: last.x - 3.5, y: last.y - 3.5, width: 7, height: 7)),
                             with: .color(tint))
            }
        }
        .clipped()
        .accessibilityHidden(true)
    }

    /// The colour of the segment that ends at `index`.
    private func token(at index: Int) -> LooprColorToken {
        guard let zones else { return .heart }
        return HeartZone(number: zones.number(for: reading.line[index].bpm), percentOfMax: 0).token
    }
}

/// The compact row shown when the band is not streaming: the newest stored
/// reading, or what to do to get one. It opens the live screen.
struct HeartLiveStatusRow: View {
    @Environment(\.heartTabServices) private var services
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.looprBandIndicator) private var bandIndicator
    let lastReading: HeartLastReading?
    let bandConnected: Bool
    let liveError: String?
    let now: Date
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            LooprSurface(emphasis: .hero(.heart)) {
                VStack(alignment: .leading, spacing: bandConnected ? LooprSpacing.sm : LooprSpacing.xs) {
                    HStack {
                        Circle()
                            .fill(Color.loopr(bandConnected ? .heart : .inkMuted))
                            .frame(width: 7, height: 7)
                        LooprText(bandConnected ? "HEART RATE" : "BAND NOT CONNECTED",
                                  style: .sectionLabel, color: .inkSecondary)
                        Spacer()
                        LooprChevron()
                    }
                    if let lastReading {
                        HStack(alignment: .bottom, spacing: LooprSpacing.xs) {
                            HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.xs) {
                                Text(String(Int(lastReading.bpm.rounded())))
                                    .looprTypography(.display)
                                    .monospacedDigit()
                                    .foregroundStyle(Color.loopr(.ink))
                                    .contentTransition(.numericText())
                                    .animation(reduceMotion ? nil : .smooth(duration: LooprMotion.standard),
                                               value: Int(lastReading.bpm.rounded()))
                                LooprText("bpm", style: .metricUnit, color: .inkSecondary)
                            }
                            Spacer(minLength: 0)
                            if let zone = services?.zones?.zone(for: lastReading.bpm), !dynamicTypeSize.isAccessibilitySize {
                                HeartCardZoneLabel(zone: zone, range: services?.zones?.zones.bpmRange(for: zone.number))
                            }
                        }
                        if let zone = services?.zones?.zone(for: lastReading.bpm), dynamicTypeSize.isAccessibilitySize {
                            HeartCardZoneLabel(zone: zone, range: services?.zones?.zones.bpmRange(for: zone.number))
                        }
                        LooprText("Last reading · \(HeartLastReading.when(lastReading.at, now: now, calendar: .current, locale: Locale(identifier: "en_GB")))",
                                  style: .caption, color: .inkSecondary)
                    } else {
                        HStack {
                            LooprText("No reading yet", style: .cardTitle)
                            Spacer(minLength: 0)
                        }
                        LooprText(subtitle, style: .caption, color: .inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if bandConnected {
                        LooprText(waitingCaption, style: .confidence, color: .inkMuted)
                            .contentTransition(.opacity)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel)
        .accessibilityHint("Opens live heart rate")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("heart-live-card")
    }

    private var title: String { bandConnected ? "Live heart rate" : "Band not connected" }

    private var waitingCaption: String {
        switch bandIndicator?.link {
        case .syncing: "Your band is syncing"
        case .reconnecting: "Connecting to your band"
        default: "Waiting for live data"
        }
    }

    private var subtitle: String {
        if let liveError { return liveError }
        return bandConnected ? "Wear your band snugly to start a reading" : "Connect your band to start a reading"
    }

    private var spokenLabel: String {
        if let lastReading {
            let zone = services?.zones?.zone(for: lastReading.bpm)
            let zonePart = zone.map { ", \($0.spokenText)" } ?? ""
            return "\(title). Last reading, \(lastReading.spokenText(now: now))\(zonePart)"
        }
        return "Live heart rate. \(subtitle)"
    }
}

// MARK: Resting heart rate and HRV

/// A nightly metric against your usual range: the value, the change, and
/// 30 nights with the usual band and the 7-day average.
struct HeartBaselineCard: View {
    let trend: HeartBaselineTrend
    let open: (() -> Void)?
    @State private var scrubDay: Date?

    /// Fewer nights than this and the chart would be a lone dot in an empty
    /// box, so the card shows learning progress instead.
    static let minimumChartNights = 3

    var body: some View {
        LooprSurface {
            VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                header
                if trend.points.count >= Self.minimumChartNights {
                    HeartBaselineChart(trend: trend, scrubDay: $scrubDay)
                        .frame(height: 76)
                        .contentShape(Rectangle())
                        .onTapGesture { open?() }
                    footer
                } else if case .learning(let measured, let needed) = trend.state {
                    HeartLearningProgress(measured: measured, needed: needed)
                        .contentShape(Rectangle())
                        .onTapGesture { open?() }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(trend.spokenSummary)
        .accessibilityAddTraits(open == nil ? [] : .isButton)
        .accessibilityAction { open?() }
        .accessibilityIdentifier(trend.metric.identifier)
    }

    private var header: some View {
        Button { open?() } label: {
            VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                HStack(alignment: .center, spacing: LooprSpacing.sm) {
                    LooprText(trend.metric.title, style: .rowTitle, color: .inkSecondary)
                    Spacer(minLength: LooprSpacing.xs)
                    if open != nil { LooprChevron() }
                }
                if let scrubDay {
                    scrubbedValue(scrubDay)
                } else {
                    currentValue
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(open == nil)
    }

    /// While learning, the progress bar says it; with a chart, a line under
    /// the value does.
    private var isLearning: Bool {
        if case .learning = trend.state { return true }
        return false
    }

    @ViewBuilder
    private var currentValue: some View {
        if let valueText = trend.valueText, isLearning {
            LooprValueText(valueText, unit: trend.metric.unit, valueStyle: .metric)
            if trend.points.count >= Self.minimumChartNights { caption }
        } else if let valueText = trend.valueText {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.sm) {
                    LooprValueText(valueText, unit: trend.metric.unit, valueStyle: .metric)
                    Spacer(minLength: LooprSpacing.xs)
                    caption
                }
                VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                    LooprValueText(valueText, unit: trend.metric.unit, valueStyle: .metric)
                    caption
                }
            }
        } else {
            LooprText("No reading for this night", style: .prose, color: .inkSecondary)
                .padding(.vertical, LooprSpacing.xxs)
        }
    }

    @ViewBuilder
    private var caption: some View {
        if let delta = trend.delta {
            LooprDeltaCaption(delta, accent: .heart)
                .fixedSize()
        }
    }

    @ViewBuilder
    private func scrubbedValue(_ day: Date) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.sm) {
            if let point = trend.point(on: day) {
                LooprValueText(String(Int(point.value.rounded())), unit: trend.metric.unit, valueStyle: .metric)
            } else {
                LooprText("No reading", style: .metricValue, color: .inkSecondary)
            }
            Spacer(minLength: LooprSpacing.xs)
            VStack(alignment: .trailing, spacing: 2) {
                LooprText(Self.dayFormatter.string(from: day), style: .metricUnit, color: .ink)
                if let average = trend.averagePoint(on: day) {
                    LooprText("7-day average \(Int(average.value.rounded()))", style: .metricUnit, color: .inkSecondary)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
    }

    private var footer: some View {
        // One line when it fits, otherwise one legend entry per line.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: LooprSpacing.sm) {
                legendEntries
                Spacer(minLength: 0)
                LooprText("30 nights", style: .caption, color: .inkMuted)
            }
            .lineLimit(1)
            VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                legendEntries
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var legendEntries: some View {
        if let usualText = trend.usualText {
            HStack(spacing: LooprSpacing.xs) {
                legendSwatch(band: true)
                LooprText(usualText, style: .caption, color: .inkSecondary)
            }
        }
        if !trend.average.isEmpty {
            HStack(spacing: LooprSpacing.xs) {
                legendSwatch(band: false)
                LooprText("7-day average", style: .caption, color: .inkSecondary)
            }
        }
    }

    private func legendSwatch(band: Bool) -> some View {
        Group {
            if band {
                RoundedRectangle(cornerRadius: 2).fill(Color.loopr(.heart).opacity(0.22))
                    .frame(width: 12, height: 8)
            } else {
                Capsule().fill(Color.loopr(.heart)).frame(width: 12, height: 2)
            }
        }
    }

    static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "EEE d MMM"
        return formatter
    }()
}

/// Nights towards a usual range, one segment per night, for a card that has
/// too few nights to chart.
struct HeartLearningProgress: View {
    let measured: Int
    let needed: Int

    var body: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            HStack(spacing: 3) {
                ForEach(0..<max(1, needed), id: \.self) { index in
                    Capsule()
                        .fill(index < measured ? Color.loopr(.heart) : Color.loopr(.divider))
                        .frame(height: 4)
                }
            }
            LooprText("Learning your usual · \(min(measured, needed)) of \(needed) nights", style: .metricUnit, color: .inkSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityHidden(true)
    }
}

/// Nights as dots, the usual range as a band and the 7-day average as a
/// line. Hold to read a night; the card's header shows it.
struct HeartBaselineChart: View {
    @Environment(\.colorScheme) private var colorScheme
    let trend: HeartBaselineTrend
    @Binding var scrubDay: Date?

    var body: some View {
        GeometryReader { proxy in
            let geometry = HeartChartGeometry(start: trend.windowStart, end: trend.windowEnd,
                                              domain: trend.yDomain, size: proxy.size)
            ZStack(alignment: .topLeading) {
                if let band = trend.band {
                    let top = geometry.y(band.upper)
                    let bottom = geometry.y(band.lower)
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.loopr(.heart).opacity(isDark ? 0.10 : 0.09))
                        .frame(width: proxy.size.width, height: max(2, bottom - top))
                        .offset(y: top)
                }
                if trend.average.count > 1 {
                    Path { path in
                        path.addLines(trend.average.map { CGPoint(x: geometry.x(mid($0.date)), y: geometry.y($0.value)) })
                    }
                    .stroke(Color.loopr(.heart), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
                ForEach(trend.points) { point in
                    let isDay = point.date == trend.day
                    Circle()
                        .fill(Color.loopr(isDay ? .heart : .inkSecondary).opacity(isDay ? 1 : 0.55))
                        .frame(width: isDay ? 9 : 5, height: isDay ? 9 : 5)
                        .overlay {
                            if isDay {
                                Circle().strokeBorder(Color.loopr(.surface), lineWidth: 1.5)
                            }
                        }
                        .position(x: geometry.x(mid(point.date)), y: geometry.y(point.value))
                }
                if let scrubDay {
                    let x = geometry.x(mid(scrubDay))
                    Rectangle()
                        .fill(Color.loopr(.ink).opacity(isDark ? 0.55 : 0.45))
                        .frame(width: 1, height: proxy.size.height)
                        .position(x: x, y: proxy.size.height / 2)
                }
            }
            .contentShape(Rectangle())
            .looprScrub { x in
                guard let x else { scrubDay = nil; return }
                let date = geometry.date(atX: x)
                scrubDay = min(Calendar.current.startOfDay(for: date), trend.day)
            }
        }
        .accessibilityHidden(true)
    }

    /// Nights sit in the middle of their day's slot.
    private func mid(_ day: Date) -> Date { day.addingTimeInterval(43_200) }

    private var isDark: Bool { LooprAppearance.isDark(colorScheme) }
}
