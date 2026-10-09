import Foundation
import SwiftUI
import DomainKit
import DesignSystem

/// What shaped the day's recovery: the hero again, each signal's push, the
/// last 30 days by band, and how the score is calculated.
public struct TodayRecoveryBreakdownScreen: View {
    @Environment(\.looprMetricLink) private var metricLink
    @Environment(\.looprDayNavigation) private var dayNavigation
    @ObservedObject private var viewModel: TodayViewModel
    private let route: (TodayRoute) -> Void

    public init(viewModel: TodayViewModel, route: @escaping (TodayRoute) -> Void = { _ in }) {
        self.viewModel = viewModel
        self.route = route
    }

    public var body: some View {
        VStack(spacing: 0) {
            StickyHeader(title: "Recovery", meta: meta)
            ScrollView {
                if let summary = viewModel.summary, let dashboard = viewModel.dashboard(isToday: isToday) {
                    let explanation = TodayRecoveryExplanation(summary: summary, context: viewModel.context)
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            LooprText("Score weights", style: .cardTitle)
                            Spacer()
                            if let reading = dashboard.hero.reading { LooprText(reading.text, style: .metricCompact) }
                        }.padding(.horizontal, LooprSpacing.screenGutter).padding(.top, LooprSpacing.lg)

                        TodayBreakdownSection(title: "What shaped it", detail: "Last night against your earlier nights") {
                            VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                                LooprContributorList(explanation.rows.map(row))
                                TodayNote(explanation.note)
                                if let sleepNote = explanation.sleepNote {
                                    TodayNote(sleepNote, symbol: "bed.double")
                                }
                            }
                        }
                        .padding(.top, LooprSpacing.lg)

                        if explanation.trend.contains(where: { $0.value != nil }) {
                            TodayBreakdownSection(title: "Last 30 days", detail: "Hold and drag to read a day") {
                                TodayTrendBars(
                                    bars: explanation.trend,
                                    maximum: 100,
                                    accent: .recovery,
                                    colour: { LooprRecoveryBand(score: $0)?.token ?? .recovery },
                                    valueText: { "\(Int($0.rounded()))" },
                                    identifier: "today-recovery-trend",
                                    guides: [67, 34]
                                )
                                .modifier(TodayChartCard())
                            }
                            .padding(.top, LooprSpacing.xl)
                        }

                        TodayBreakdownSection(title: "How it's calculated", detail: nil) {
                            VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                                Text(Self.howItWorks)
                                    .looprTypography(.prose)
                                    .foregroundStyle(Color.loopr(.inkSecondary))
                                    .lineSpacing(3)
                                    .fixedSize(horizontal: false, vertical: true)
                                TodayLinkList([
                                    TodayLinkList.Item(title: "Recovery history", identifier: "today-breakdown-recovery-metric") {
                                        open(LooprMetricLinkID.recovery)
                                    }
                                ])
                            }
                        }
                        .padding(.top, LooprSpacing.xl)
                    }
                    .padding(.bottom, LooprSpacing.tabBarClearance)
                } else {
                    LooprCard { StateMessage(.noRecords) }
                        .padding(LooprSpacing.screenGutter)
                }
            }
        }
        .background(Color.loopr(.background).ignoresSafeArea())
        .accessibilityIdentifier("today-recovery-breakdown-screen")
    }

    static let howItWorks = "Recovery needs at least two usable signals. Before 14 nights it is an early estimate. Each morning Loopr compares last night's HRV, resting heart rate and breathing rate with your own earlier nights, up to 28 of them. HRV above your usual raises the score. Resting heart rate or breathing rate above your usual lowers it. HRV counts most and breathing rate least. 67 and up is Ready, 34 to 66 is Steady, 33 and below is Recover."

    private var isToday: Bool { dayNavigation?.isToday ?? true }
    private var meta: String { (dayNavigation?.dateText ?? "").uppercased() }

    private func row(_ row: TodayRecoveryExplanation.Row) -> LooprContributorRow {
        LooprContributorRow(
            title: row.title,
            value: row.value,
            unit: row.unit,
            delta: row.delta,
            impact: row.share.map { LooprContributorImpact(share: $0, label: row.pointsLabel) },
            status: row.status,
            accent: .recovery,
            identifier: "today-breakdown-\(row.signal.rawValue)"
        ) { open(row.signal.metric.linkID) }
    }

    private func open(_ id: String) {
        if let metricLink, metricLink.supports(id) { metricLink.open(id) }
    }
}

/// Where the day's strain came from: time per heart-rate zone, how the day
/// compares, and the last 30 days.
public struct TodayStrainBreakdownScreen: View {
    @Environment(\.looprMetricLink) private var metricLink
    @Environment(\.looprDayNavigation) private var dayNavigation
    @ObservedObject private var viewModel: TodayViewModel
    private let route: (TodayRoute) -> Void

    public init(viewModel: TodayViewModel, route: @escaping (TodayRoute) -> Void = { _ in }) {
        self.viewModel = viewModel
        self.route = route
    }

    public var body: some View {
        VStack(spacing: 0) {
            StickyHeader(title: "Strain", meta: (dayNavigation?.dateText ?? "").uppercased())
            ScrollView {
                if let summary = viewModel.summary {
                    let explanation = TodayStrainExplanation(summary: summary, context: viewModel.context)
                    VStack(alignment: .leading, spacing: 0) {
                        hero(explanation)

                        TodayBreakdownSection(title: "Time in each zone", detail: zoneDetail(explanation)) {
                            if explanation.zones.isEmpty {
                                TodayNote("No time above your resting zones on this day, so strain stayed low.")
                            } else {
                                TodayZoneBars(zones: explanation.zones)
                                    .modifier(TodayChartCard())
                            }
                        }
                        .padding(.top, LooprSpacing.lg)

                        if explanation.trend.contains(where: { $0.value != nil }) {
                            TodayBreakdownSection(title: "Last 30 days", detail: "Hold and drag to read a day") {
                                TodayTrendBars(
                                    bars: explanation.trend,
                                    maximum: 21,
                                    accent: .strain,
                                    colour: { _ in .strain },
                                    valueText: { String(format: "%.1f", $0) },
                                    identifier: "today-strain-trend"
                                )
                                .modifier(TodayChartCard())
                            }
                            .padding(.top, LooprSpacing.xl)
                        }

                        TodayBreakdownSection(title: "How it's calculated", detail: nil) {
                            VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                                Text(Self.howItWorks)
                                    .looprTypography(.prose)
                                    .foregroundStyle(Color.loopr(.inkSecondary))
                                    .lineSpacing(3)
                                    .fixedSize(horizontal: false, vertical: true)
                                TodayLinkList([
                                    TodayLinkList.Item(title: "Strain history", identifier: "today-breakdown-strain-metric") {
                                        if let metricLink, metricLink.supports(LooprMetricLinkID.strain) {
                                            metricLink.open(LooprMetricLinkID.strain)
                                        }
                                    },
                                    TodayLinkList.Item(title: "Body and training load", identifier: "today-breakdown-body") {
                                        route(.body)
                                    }
                                ])
                            }
                        }
                        .padding(.top, LooprSpacing.xl)
                    }
                    .padding(.bottom, LooprSpacing.tabBarClearance)
                } else {
                    LooprCard { StateMessage(.noRecords) }
                        .padding(LooprSpacing.screenGutter)
                }
            }
        }
        .background(Color.loopr(.background).ignoresSafeArea())
        .accessibilityIdentifier("today-strain-breakdown-screen")
    }

    static let howItWorks = "Strain adds up every minute your heart rate sits above resting, and a minute near your maximum counts many times more than an easy one. The 0 to 21 scale is logarithmic, so moving from 14 to 16 takes far more work than moving from 4 to 6."

    private func zoneDetail(_ explanation: TodayStrainExplanation) -> String? {
        guard explanation.totalZoneMinutes > 0 else { return nil }
        return (LooprUnitFormatter.duration(minutes: explanation.totalZoneMinutes) ?? "") + " above resting"
    }

    private func hero(_ explanation: TodayStrainExplanation) -> some View {
        VStack(spacing: LooprSpacing.sm) {
            LooprProgressRing(value: explanation.value, scale: LooprRingScale(fullValue: 21), text: explanation.text,
                              format: explanation.value == nil ? nil : .oneDecimal, caption: "Strain",
                              accent: .strain, diameter: 172)
                .overlay {
                    if let range = viewModel.context?.suggestedStrainRange {
                        TodayRangeArc(range: range, scaleMax: 21, diameter: 186)
                    }
                }
            if let delta = explanation.delta {
                LooprDeltaCaption(delta, accent: .strain, style: .metricUnit)
            }
            if let rangeText = explanation.rangeText {
                Text(rangeText)
                    .looprTypography(.prose)
                    .foregroundStyle(Color.loopr(.inkSecondary))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, LooprSpacing.xl)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Strain \(explanation.text) of 21. \(explanation.delta?.spokenText ?? "")")
    }
}

// MARK: - Shared pieces

struct TodayBreakdownSection<Content: View>: View {
    let title: String
    let detail: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprSectionHeader(title, detail: detail)
            content
        }
        .padding(.horizontal, LooprSpacing.screenGutter)
    }
}

/// A quiet explanatory line with a small symbol.
struct TodayNote: View {
    let text: String
    let symbol: String

    init(_ text: String, symbol: String = "info.circle") {
        self.text = text
        self.symbol = symbol
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.xs) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.loopr(.inkTertiary))
                .accessibilityHidden(true)
            Text(text)
                .looprTypography(.caption)
                .foregroundStyle(Color.loopr(.inkSecondary))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 4)
    }
}

/// Navigation rows in one card with hairlines between them.
struct TodayLinkList: View {
    struct Item: Identifiable {
        let title: String
        let identifier: String
        let action: () -> Void
        var id: String { identifier }
    }

    let items: [Item]

    init(_ items: [Item]) { self.items = items }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                Button(action: item.action) {
                    HStack {
                        Text(item.title)
                            .looprTypography(.rowTitle)
                            .foregroundStyle(Color.loopr(.ink))
                        Spacer()
                        LooprChevron()
                    }
                    .frame(maxWidth: .infinity, minHeight: LooprSpacing.interactiveRowHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.looprPressableCard)
                .accessibilityIdentifier(item.identifier)
                if index < items.count - 1 {
                    Rectangle().fill(Color.loopr(.divider)).frame(height: 1).accessibilityHidden(true)
                }
            }
        }
        .padding(.horizontal, LooprSpacing.cardHorizontal)
        .looprCardBackground(density: .compact)
    }
}

struct TodayChartCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 10)
            .looprCardBackground(density: .compact)
    }
}

/// Thirty daily bars with a hold-to-read readout. Gaps are small dots, never
/// zero bars.
struct TodayTrendBars: View {
    let bars: [TodayTrendBar]
    let maximum: Double
    let accent: LooprColorToken
    let colour: (Double) -> LooprColorToken
    let valueText: (Double) -> String
    let identifier: String
    /// Faint reference lines, such as the recovery band edges.
    var guides: [Double] = []

    @State private var selected: Int?
    private let chartHeight: CGFloat = 132
    private let headroom: CGFloat = 34

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { proxy in
                let width = proxy.size.width
                let slot = width / CGFloat(max(bars.count, 1))
                let barWidth = max(2, slot * 0.62)
                ZStack(alignment: .bottomLeading) {
                    ForEach(guides, id: \.self) { guide in
                        let y = headroom + chartHeight - CGFloat(min(max(guide / maximum, 0), 1)) * chartHeight
                        Path { path in
                            path.move(to: CGPoint(x: 0, y: y))
                            path.addLine(to: CGPoint(x: width, y: y))
                        }
                        .stroke(Color.loopr(.inkSecondary).opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                        Text(String(format: "%.0f", guide))
                            .looprTypography(.confidence)
                            .foregroundStyle(Color.loopr(.inkSecondary))
                            .position(x: width - 8, y: y - 8)
                    }
                    ForEach(Array(bars.enumerated()), id: \.element.id) { index, bar in
                        let x = slot * (CGFloat(index) + 0.5)
                        if let value = bar.value {
                            let height = max(3, CGFloat(min(max(value / maximum, 0), 1)) * chartHeight)
                            RoundedRectangle(cornerRadius: min(barWidth / 2, 3), style: .continuous)
                                .fill(Color.loopr(colour(value)).opacity(selected == nil || selected == index ? 1 : 0.35))
                                .frame(width: barWidth, height: height)
                                .position(x: x, y: headroom + chartHeight - height / 2)
                        } else {
                            Circle()
                                .fill(Color.loopr(.inkSecondary).opacity(0.35))
                                .frame(width: 3, height: 3)
                                .position(x: x, y: headroom + chartHeight - 1.5)
                        }
                    }
                    if let selected, bars.indices.contains(selected) {
                        LooprScrubReadout(
                            x: LooprScrubMath.center(of: selected, count: bars.count, width: width),
                            title: TodayDashboard.shortDayLabel(bars[selected].date),
                            value: bars[selected].value.map(valueText),
                            accent: accent,
                            showsRule: false
                        )
                    }
                }
                .contentShape(Rectangle())
                .looprScrub { x in
                    selected = x.flatMap { LooprScrubMath.index(x: $0, width: width, count: bars.count) }
                }
            }
            .frame(height: headroom + chartHeight)

            HStack {
                Text(bars.first.map { TodayDashboard.shortDayLabel($0.date) } ?? "")
                Spacer()
                Text(bars.last.map { TodayDashboard.shortDayLabel($0.date) } ?? "")
            }
            .looprTypography(.confidence)
            .foregroundStyle(Color.loopr(.inkSecondary))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenSummary)
        .accessibilityIdentifier(identifier)
    }

    private var spokenSummary: String {
        let measured = bars.compactMap(\.value)
        guard let last = bars.last(where: { $0.value != nil })?.value, !measured.isEmpty else { return "No readings in the last 30 days" }
        let mean = measured.reduce(0, +) / Double(measured.count)
        return "Last 30 days, \(measured.count) days measured, average \(valueText(mean)), latest \(valueText(last))"
    }
}

/// Minutes per heart-rate zone as horizontal bars.
struct TodayZoneBars: View {
    let zones: [TodayStrainExplanation.Zone]

    var body: some View {
        VStack(spacing: 10) {
            ForEach(zones) { zone in
                HStack(spacing: LooprSpacing.sm) {
                    Text(zone.name)
                        .looprTypography(.label)
                        .foregroundStyle(Color.loopr(.ink))
                        .frame(width: 84, alignment: .leading)
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule(style: .continuous)
                                .fill(Color.loopr(.ink).opacity(0.06))
                            Capsule(style: .continuous)
                                .fill(Color.loopr(.strain).opacity(0.35 + 0.13 * Double(zone.id)))
                                .frame(width: max(zone.minutes > 0 ? 4 : 0, proxy.size.width * zone.share))
                        }
                    }
                    .frame(height: 8)
                    Text(LooprUnitFormatter.duration(minutes: zone.minutes) ?? "0 min")
                        .looprTypography(.metricUnit)
                        .foregroundStyle(Color.loopr(.inkSecondary))
                        .monospacedDigit()
                        .frame(width: 64, alignment: .trailing)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(zone.name), \(LooprUnitFormatter.spokenDuration(minutes: zone.minutes) ?? "no time")")
            }
        }
        .padding(.vertical, 4)
    }
}
