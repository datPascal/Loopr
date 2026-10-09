import Foundation
import SwiftUI
import DomainKit
import DesignSystem

/// The Today tab for a day with data, top to bottom: heads-up, recovery hero,
/// the three secondary rings, your numbers, goals, tonight,
/// the coach line when it has something, and More.
struct TodayDashboardContent: View {
    @Environment(\.looprMetricLink) private var metricLink

    let summary: TodaySummary
    let dashboard: TodayDashboard
    let route: (TodayRoute) -> Void
    let externalInsight: TodayExternalInsight?
    let onExternalInsight: (String) -> Void
    let accessory: AnyView?
    let onDismissHeadsUp: () -> Void
    let onEditNumbers: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TodayStatusProbe(summary: summary, hero: dashboard.hero)

            TodayMorningBriefingView(hero: dashboard.hero, headsUp: dashboard.headsUp,
                openRecovery: { route(.recoveryBreakdown) }, openCheck: { route(.heart) })
                .padding(.top, LooprSpacing.xs)
            if dashboard.morningSignals != .hidden {
                TodayMorningContributorsView(signals: dashboard.morningSignals, subtitle: dashboard.morningSignalsSubtitle) { id in
                    if let metricLink, metricLink.supports(id) { metricLink.open(id) }
                    else { route(id == LooprMetricLinkID.sleepDuration ? .sleep : .heart) }
                }
                .padding(.top, LooprSpacing.sm)
            }

            TodaySecondaryRings(rings: dashboard.rings) { id in
                switch id {
                case .sleep: route(.sleep)
                case .strain: route(.strainBreakdown)
                default: route(.stress)
                }
            }
            .padding(.horizontal, LooprSpacing.screenGutter)
            .padding(.top, LooprSpacing.sm)

            if summary.notableChanges.contains(TodayDayInsight.sustainedStressHint) {
                Button { route(.stress) } label: {
                    HStack(spacing: LooprSpacing.xs) {
                        Circle().fill(Color.loopr(.stress)).frame(width: 6, height: 6)
                            .accessibilityHidden(true)
                        LooprText("Stress ran above your usual range today", style: .caption, color: .inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        LooprChevron()
                    }
                    .padding(.horizontal, LooprSpacing.cardHorizontal)
                    .frame(maxWidth: .infinity, minHeight: LooprSpacing.interactiveRowHeight, alignment: .leading)
                    .looprCardBackground()
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("today-hourly-stress-hint")
                .accessibilityHint("Opens hourly stress.")
                .padding(.horizontal, LooprSpacing.screenGutter)
                .padding(.top, LooprSpacing.sm)
            }

            TodayYourNumbers(tiles: dashboard.tiles, onEdit: onEditNumbers) { metric in
                open(metric.linkID, fallback: fallbackRoute(for: metric))
            }
            .padding(.top, LooprSpacing.xl)

            if dashboard.tonight != nil || accessory != nil {
                section("Tonight", detail: nil) {
                    VStack(spacing: LooprSpacing.sm) {
                        if let tonight = dashboard.tonight {
                            TodayTonightCard(plan: tonight)
                        }
                        if let accessory { accessory }
                    }
                }
                .padding(.top, LooprSpacing.xl)
            }

            TodayGoalsCard(summary: summary, route: route)
                .padding(.top, LooprSpacing.sm)

            section("More", detail: nil) {
                TodayMoreGrid(route: route)
            }
            .padding(.top, LooprSpacing.xl)
        }
    }

    private func section<Content: View>(_ title: String, detail: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprSectionHeader(title, detail: detail)
            content()
        }
        .padding(.horizontal, LooprSpacing.screenGutter)
    }

    private func open(_ linkID: String, fallback: TodayRoute) {
        if let metricLink, metricLink.supports(linkID) {
            metricLink.open(linkID)
        } else {
            route(fallback)
        }
    }

    private func fallbackRoute(for metric: TodayTrackedMetric) -> TodayRoute {
        switch metric {
        case .sleep, .sleepEfficiency, .deepSleep, .remSleep: .sleep
        case .hrv, .restingHeartRate, .respiratoryRate: .heart
        case .recovery: .recoveryBreakdown
        case .strain: .strainBreakdown
        case .stress: .stress
        case .steps, .activeEnergy: .body
        }
    }
}

/// One off-screen element that tells VoiceOver where the day stands before
/// it reaches the hero.
private struct TodayStatusProbe: View {
    let summary: TodaySummary
    let hero: TodayHeroState

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
    }

    private var label: String {
        switch hero {
        case .scored(let reading): "Recovery \(reading.text) out of 100, \(reading.band.verdict)."
        case .carried(let reading, let day, _): "Recovery from \(day), \(reading.text) out of 100."
        case .calculating(let title, _), .unavailable(let title, _): "Recovery, \(title)."
        case .learning(let have, let need, _): "Recovery, learning your usual, \(have) of \(need) nights."
        }
    }
}

// MARK: - Heads-up

struct TodayHeadsUpCard: View {
    let headsUp: TodayHeadsUp
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.sm) {
            HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.xs) {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.loopr(.caution))
                    .accessibilityHidden(true)
                Text(headsUp.title)
                    .looprTypography(.rowTitle)
                    .foregroundStyle(Color.loopr(.ink))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: LooprSpacing.xs)
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.loopr(.inkTertiary))
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, -8)
                .padding(.vertical, -8)
                .accessibilityLabel("Hide for today")
                .accessibilityIdentifier("today-heads-up-dismiss")
            }

            TodayChipFlow(items: headsUp.signals.map(\.text), tone: .signal)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(headsUp.signals.map(\.spoken).joined(separator: ". "))

            if !headsUp.factors.isEmpty {
                VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                    LooprText("Might explain it", style: .sectionLabel, color: .inkSecondary)
                        .textCase(.uppercase)
                    TodayChipFlow(items: headsUp.factors, tone: .factor)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Might explain it: " + headsUp.factors.joined(separator: ", "))
            }

            Text(headsUp.detail)
                .looprTypography(.prose)
                .foregroundStyle(Color.loopr(.inkSecondary))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, LooprSpacing.cardVertical)
        .padding(.horizontal, LooprSpacing.cardHorizontal)
        .frame(maxWidth: .infinity, alignment: .leading)
        .looprCardBackground(.warning)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("today-heads-up")
    }
}

/// Small capsules that wrap onto new lines.
struct TodayChipFlow: View {
    enum Tone { case signal, factor }
    @Environment(\.colorScheme) private var colorScheme
    let items: [String]
    let tone: Tone

    var body: some View {
        TodayFlowLayout(spacing: 6) {
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(tone == .signal
                          ? .custom("IBMPlexMono-Medium", size: 11, relativeTo: .caption)
                          : .custom("SpaceGrotesk-Medium", size: 12, relativeTo: .caption))
                    .monospacedDigit()
                    .foregroundStyle(Color.loopr(tone == .signal ? .ink : .inkSecondary))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(
                        Color.loopr(tone == .signal ? .caution : .ink).opacity(tone == .signal ? (isDark ? 0.16 : 0.12) : 0.06),
                        in: Capsule(style: .continuous)
                    )
            }
        }
    }

    private var isDark: Bool { LooprAppearance.isDark(colorScheme) }
}

/// A left-aligned wrapping row.
struct TodayFlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                y += lineHeight + spacing
                x = 0
                lineHeight = 0
            }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: min(widest, width), height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += lineHeight + spacing
                x = bounds.minX
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

// MARK: - Recovery hero

/// The one large ring. Coloured by band when there is a score; a quiet track
/// with the reason when there is not.
struct TodayRecoveryHero: View {
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1

    let hero: TodayHeroState
    let isInteractive: Bool
    let action: () -> Void

    var body: some View {
        Group {
            if isInteractive {
                Button(action: action) { content }
                    .buttonStyle(.looprPressableCard)
                    .accessibilityHint("Opens what shaped your recovery.")
            } else {
                content
            }
        }
        .containerRelativeFrame(.horizontal) { width, _ in
            max(0, width - 2 * LooprSpacing.screenGutter)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel)
        .accessibilityIdentifier("today-metric-recovery")
    }

    private var content: some View {
        VStack(spacing: 0) {
            if case .carried(_, let day, _) = hero {
                Text(day.uppercased())
                    .looprTypography(.chip)
                    .foregroundStyle(Color.loopr(.inkSecondary))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.loopr(.ink).opacity(0.07), in: Capsule(style: .continuous))
                    .padding(.bottom, LooprSpacing.sm)
            }

            LooprProgressRing(
                value: ringValue,
                scale: ringScale,
                text: isLearning ? "" : ringText,
                format: ringFormat,
                caption: isLearning ? nil : ringCaption,
                accent: ringAccent,
                diameter: diameter
            )
            .overlay {
                if isLearning {
                    // A count, not a score: set small so it never reads as one.
                    VStack(spacing: 4) {
                        Text(ringText)
                            .font(.custom("SpaceGrotesk-SemiBold", size: 26, relativeTo: .title2))
                            .foregroundStyle(Color.loopr(.ink))
                            .monospacedDigit()
                        Text("NIGHTS")
                            .looprTypography(.lensCaption)
                            .foregroundStyle(Color.loopr(.inkSecondary))
                    }
                    .accessibilityHidden(true)
                }
            }
            .opacity(isCarried ? 0.72 : 1)

            VStack(spacing: 6) {
                HStack(spacing: LooprSpacing.xs) {
                    if let band = hero.reading?.band {
                        Circle()
                            .fill(Color.loopr(band.token))
                            .frame(width: 9, height: 9)
                            .accessibilityHidden(true)
                    }
                    Text(headline)
                        .looprTypography(.cardTitle)
                        .foregroundStyle(Color.loopr(.ink))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(detail)
                    .looprTypography(.prose)
                    .foregroundStyle(Color.loopr(.inkSecondary))
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 330)
                if let early = hero.reading?.earlyEstimate, !isCarried {
                    Text(early).looprTypography(.confidence)
                        .foregroundStyle(Color.loopr(.inkSecondary))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let guidance = hero.reading?.guidance, !isCarried {
                    Text(guidance)
                        .looprTypography(.label)
                        .foregroundStyle(Color.loopr(.ink))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if isInteractive, hero.reading != nil {
                    HStack(spacing: 4) {
                        Text(isCarried ? "See that day" : "What shaped it")
                            .looprTypography(.label)
                            .foregroundStyle(Color.loopr(LooprColorToken.brand.textInk))
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        LooprChevron()
                    }
                    .padding(.top, 4)
                }
            }
            .padding(.top, LooprSpacing.md)
            .padding(.horizontal, LooprSpacing.lg)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, LooprSpacing.lg)
        .padding(.bottom, LooprSpacing.md)
        .contentShape(Rectangle())
    }

    private var diameter: CGFloat { 184 * min(max(scale, 1), 1.15) }
    private var isCarried: Bool { if case .carried = hero { true } else { false } }
    private var isLearning: Bool { if case .learning = hero { true } else { false } }

    private var ringValue: Double? {
        switch hero {
        case .scored(let reading), .carried(let reading, _, _): reading.score
        case .learning(let have, _, _): Double(have)
        default: nil
        }
    }

    private var ringScale: LooprRingScale? {
        switch hero {
        case .scored, .carried: LooprRingScale(fullValue: 100)
        case .learning(_, let need, _): LooprRingScale(fullValue: Double(max(need, 1)))
        default: nil
        }
    }

    private var ringText: String {
        switch hero {
        case .scored(let reading), .carried(let reading, _, _): reading.text
        case .learning(let have, let need, _): "\(min(have, need)) of \(need)"
        default: "—"
        }
    }

    private var ringFormat: LooprRingNumberFormat? {
        switch hero {
        case .scored, .carried: .integer
        default: nil
        }
    }

    private var ringCaption: String {
        switch hero {
        case .learning: "Nights"
        default: "Recovery"
        }
    }

    private var ringAccent: LooprColorToken {
        hero.reading?.band.token ?? .recovery
    }

    private var headline: String {
        switch hero {
        case .scored(let reading): reading.band.verdict
        case .carried(let reading, _, _): reading.band.verdict
        case .calculating(let title, _), .unavailable(let title, _): title
        case .learning: "Learning your usual"
        }
    }

    private var detail: String {
        switch hero {
        case .scored(let reading): reading.driver
        case .carried(_, _, let reason): reason
        case .calculating(_, let detail), .unavailable(_, let detail), .learning(_, _, let detail): detail
        }
    }

    private var spokenLabel: String {
        switch hero {
        case .scored(let reading):
            "Recovery \(reading.text) out of 100, \(reading.band.spokenDescription). \(reading.earlyEstimate.map { $0 + ". " } ?? "")\(reading.sentence)"
        case .carried(let reading, let day, let reason):
            "Recovery from \(day), \(reading.text) out of 100, \(reading.band.spokenDescription). \(reason)"
        case .learning(let have, let need, let detail):
            "Recovery, learning your usual, \(min(have, need)) of \(need) nights. \(detail)"
        case .calculating(let title, let detail), .unavailable(let title, let detail):
            "Recovery, \(title). \(detail)"
        }
    }
}

// MARK: - Secondary rings

struct TodaySecondaryRings: View {
    @Environment(\.profileAgeAction) private var profileAgeAction
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let rings: [TodayRingItem]
    let open: (TodayMetricID) -> Void

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 0) {
                    ForEach(Array(rings.enumerated()), id: \.element.id) { index, ring in
                        if index > 0 { Divider() }
                        button(for: ring, index: index)
                            .padding(.vertical, LooprSpacing.xs)
                    }
                }
            } else {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(Array(rings.enumerated()), id: \.element.id) { index, ring in
                        button(for: ring, index: index)
                    }
                }
            }
        }
        .padding(.vertical, LooprSpacing.lg)
        .padding(.horizontal, LooprSpacing.xs)
        .looprCardBackground()
    }

    private func button(for ring: TodayRingItem, index: Int) -> some View {
        Button {
            if ring.needsAge, let profileAgeAction { profileAgeAction.open() }
            else { open(ring.id) }
        } label: {
            TodaySecondaryRing(ring: ring, revealDelay: 0.15 + Double(index) * LooprProgressRing.staggerInterval)
        }
        .buttonStyle(.looprPressableCard)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken(ring))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("today-metric-\(ring.id.rawValue)")
    }

    private func spoken(_ ring: TodayRingItem) -> String {
        var parts = [ring.caption]
        if let value = ring.reading.value {
            switch ring.id {
            case .sleep: parts.append(LooprUnitFormatter.spokenDuration(minutes: value) ?? ring.text)
            case .strain: parts.append("\(ring.text) of 21")
            default: parts.append("\(ring.text) of 100")
            }
            if let fill = ring.reading.accessibilityFill, ring.id == .sleep { parts.append(fill) }
            if let delta = ring.delta { parts.append(TodayMorningComparison.spoken(delta)) }
            if let range = ring.suggestedRange {
                parts.append("Suggested range \(String(format: "%.0f", range.lowerBound)) to \(String(format: "%.0f", range.upperBound))")
            }
        } else {
            parts.append(ring.needsAge ? ProfileAgePrompt.action : ring.settlingCaption.map(TodayDashboard.spokenSettling) ?? "No reading")
        }
        return parts.joined(separator: ", ")
    }

    private var isDark: Bool { LooprAppearance.isDark(colorScheme) }
}

private struct TodaySecondaryRing: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1
    let ring: TodayRingItem
    let revealDelay: Double

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                HStack(spacing: LooprSpacing.md) {
                    graphic
                    labels
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                VStack(spacing: 8) {
                    graphic
                    labels
                }
            }
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    private var graphic: some View {
        LooprProgressRing(
            value: ring.reading.value,
            scale: ring.reading.scale,
            text: ring.text,
            format: ring.reading.format,
            accent: ring.accent,
            diameter: diameter,
            revealDelay: revealDelay
        )
        .overlay {
            if let range = ring.suggestedRange {
                LooprRingRangeOverlay(range: range, maximum: 21, diameter: diameter + 12)
            }
        }
        .padding(16)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    private var labels: some View {
        VStack(alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .center, spacing: 3) {
            Text(ring.caption.uppercased())
                .looprTypography(.lensCaption)
                .foregroundStyle(Color.loopr(.inkSecondary))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let range = ring.suggestedRange {
                Text("Target \(Int(range.lowerBound.rounded()))–\(Int(range.upperBound.rounded()))")
                    .looprTypography(.confidence)
                    .foregroundStyle(Color.loopr(.inkSecondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let delta = ring.delta {
                TodayComparisonCaption(delta: delta, accent: ring.accent)
                    .multilineTextAlignment(dynamicTypeSize.isAccessibilitySize ? .leading : .center)
            } else {
                Text(ring.needsAge ? ProfileAgePrompt.action : ring.reading.value == nil ? (ring.settlingCaption ?? "No reading") : " ")
                    .looprTypography(.caption)
                    .foregroundStyle(Color.loopr(ring.needsAge ? .strain : .inkSecondary))
                    .multilineTextAlignment(dynamicTypeSize.isAccessibilitySize ? .leading : .center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var diameter: CGFloat { 84 * min(max(scale, 1), 1.15) }
}

/// The suggested strain range drawn just outside the ring.
struct TodayRangeArc: View {
    let range: ClosedRange<Double>
    let scaleMax: Double
    let diameter: CGFloat

    var body: some View {
        let from = min(max(range.lowerBound / scaleMax, 0), 1)
        let to = min(max(range.upperBound / scaleMax, 0), 1)
        Circle()
            .trim(from: from, to: to)
            .stroke(Color.loopr(.ink).opacity(0.45), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            .frame(width: diameter, height: diameter)
            .rotationEffect(.degrees(-90))
            .accessibilityHidden(true)
    }
}

// MARK: - Your numbers

struct TodayYourNumbers: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let tiles: [TodayNumberTile]
    let onEdit: () -> Void
    let open: (TodayTrackedMetric) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprSectionHeader("Your numbers", actionTitle: "Edit", accent: .brand, identifier: "today-numbers", action: onEdit)
            if tiles.isEmpty {
                Button(action: onEdit) {
                    HStack {
                        Text("Pick up to six numbers to keep here.")
                            .looprTypography(.prose)
                            .foregroundStyle(Color.loopr(.inkSecondary))
                        Spacer()
                        LooprChevron()
                    }
                    .padding(LooprSpacing.md)
                    .frame(maxWidth: .infinity)
                    .looprCardBackground(density: .compact)
                }
                .buttonStyle(.looprPressableCard)
            } else {
                LazyVGrid(columns: columns, spacing: LooprSpacing.xs) {
                    ForEach(tiles) { tile in
                        Button { open(tile.metric) } label: {
                            TodayNumberTileView(tile: tile)
                                .looprMetricZoomSource(tile.metric.linkID, cornerRadius: LooprRadius.compactCard)
                        }
                            .buttonStyle(.looprPressableCard)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(spoken(tile))
                            .accessibilityAddTraits(.isButton)
                            .accessibilityIdentifier("today-number-\(tile.metric.rawValue)")
                    }
                }
            }
        }
        .padding(.horizontal, LooprSpacing.screenGutter)
    }

    private var columns: [GridItem] {
        let count = dynamicTypeSize.isAccessibilitySize ? 1 : 2
        return Array(repeating: GridItem(.flexible(), spacing: LooprSpacing.xs), count: count)
    }

    private func spoken(_ tile: TodayNumberTile) -> String {
        var parts = [tile.metric.title]
        if let value = tile.value {
            parts.append([value, tile.unit.map(LooprUnitFormatter.spokenUnit)].compactMap { $0 }.joined(separator: " "))
            if let delta = tile.delta { parts.append(TodayMorningComparison.spoken(delta)) }
            if tile.metric.isEstimate { parts.append("Estimate") }
        } else {
            parts.append(tile.detail ?? "Sync your band to see this reading")
        }
        return parts.joined(separator: ", ")
    }
}

private struct TodayNumberTileView: View {
    let tile: TodayNumberTile

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(tile.metric.shortTitle)
                    .looprTypography(.label)
                    .foregroundStyle(Color.loopr(.inkSecondary))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if tile.metric.isEstimate {
                    Text("EST")
                        .looprTypography(.chip)
                        .foregroundStyle(Color.loopr(.inkSecondary))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.loopr(.ink).opacity(0.06), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
                Spacer(minLength: 0)
            }
            if let value = tile.value {
                LooprValueText(value, unit: tile.unit, valueStyle: .metricCompact)
                    .minimumScaleFactor(0.7)
                    .contentTransition(.numericText())
                    .animation(LooprMotion.stateChange, value: value)
            } else {
                Text("No reading")
                    .looprTypography(.caption)
                    .foregroundStyle(Color.loopr(.inkSecondary))
                    .frame(minHeight: 28, alignment: .bottomLeading)
            }
            Group {
                if let delta = tile.delta, tile.value != nil {
                    TodayComparisonCaption(delta: delta, accent: tile.metric.accent)
                } else {
                    Text(tile.detail ?? " ").looprTypography(.confidence)
                        .foregroundStyle(Color.loopr(.inkSecondary))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, LooprSpacing.compactCardHorizontal)
        .padding(.vertical, LooprSpacing.compactCardVertical)
        .frame(maxWidth: .infinity, alignment: .leading)
        .looprCardBackground(density: .compact)
    }
}

// MARK: - Tonight, coach, more

private struct TodayTonightCard: View {
    let plan: TodayTonightPlan

    var body: some View {
        HStack(alignment: .top, spacing: LooprSpacing.sm) {
            Image(systemName: "moon.stars")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Color.loopr(.sleep))
                .frame(width: 24)
                .padding(.top, 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(plan.title)
                    .looprTypography(.rowTitle)
                    .foregroundStyle(Color.loopr(.ink))
                Text(plan.detail)
                    .looprTypography(.prose)
                    .foregroundStyle(Color.loopr(.inkSecondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, LooprSpacing.cardHorizontal)
        .padding(.vertical, LooprSpacing.cardVertical)
        .frame(maxWidth: .infinity, alignment: .leading)
        .looprCardBackground()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("today-tonight")
    }
}

private struct TodayCoachLineRow: View {
    let line: TodayCoachLine
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: LooprSpacing.sm) {
                Image(systemName: "sparkles")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.loopr(.brand))
                    .frame(width: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(line.title)
                        .looprTypography(.rowTitle)
                        .foregroundStyle(Color.loopr(.ink))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(line.detail)
                        .looprTypography(.prose)
                        .foregroundStyle(Color.loopr(.inkSecondary))
                        .lineLimit(2)
                }
                Spacer(minLength: LooprSpacing.xs)
                LooprChevron()
            }
            .padding(.horizontal, LooprSpacing.cardHorizontal)
            .padding(.vertical, LooprSpacing.cardVertical)
            .frame(maxWidth: .infinity, alignment: .leading)
            .looprCardBackground()
        }
        .buttonStyle(.looprPressableCard)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("today-coach-line")
    }
}

struct TodayMoreGrid: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let route: (TodayRoute) -> Void

    static let entries: [(TodayRoute, String, String)] = [
        (.journal, "Journal", "book.closed"),
        (.records, "Records", "trophy"),
        (.streaks, "Streaks", "flame"),
        (.journey, "Journey", "map"),
        (.timeline, "Timeline", "clock.arrow.circlepath"),
        (.coach, "Coach", "sparkles")
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: LooprSpacing.xs) {
            ForEach(Self.entries, id: \.0) { destination, title, symbol in
                Button { route(destination) } label: {
                    VStack(spacing: 7) {
                        Image(systemName: symbol)
                            .font(.system(size: 17, weight: .regular))
                            .foregroundStyle(Color.loopr(.inkSecondary))
                            .frame(height: 20)
                            .accessibilityHidden(true)
                        Text(title)
                            .looprTypography(.label)
                            .foregroundStyle(Color.loopr(.ink))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity, minHeight: 72)
                    .looprCardBackground(density: .compact)
                }
                .buttonStyle(.looprPressableCard)
                .accessibilityLabel(title)
                .accessibilityIdentifier(destination.todayIdentifier)
            }
        }
    }

    private var columns: [GridItem] {
        let count = dynamicTypeSize.isAccessibilitySize ? 2 : 3
        return Array(repeating: GridItem(.flexible(), spacing: LooprSpacing.xs), count: count)
    }
}

// MARK: - Band status

/// A slim line about the band for someone who already has history: never a
/// hero-sized card above their numbers.
struct TodayBandStatusRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let title: String
    let detail: String?
    let actionTitle: String
    let actionIdentifier: String
    let statusIdentifier: String
    let action: () -> Void

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                    status
                    actionButton
                        .frame(maxWidth: .infinity)
                }
            } else {
                HStack(spacing: LooprSpacing.sm) {
                    status
                    Spacer(minLength: LooprSpacing.xs)
                    actionButton
                }
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .looprCardBackground(density: .compact)
    }

    private var status: some View {
        HStack(alignment: .top, spacing: LooprSpacing.sm) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.loopr(.inkSecondary))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .looprTypography(.label)
                    .foregroundStyle(Color.loopr(.ink))
                if let detail {
                    Text(detail)
                        .looprTypography(.caption)
                        .foregroundStyle(Color.loopr(.inkSecondary))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(statusIdentifier)
        }
    }

    private var actionButton: some View {
        Button(action: action) {
            Text(actionTitle)
                .looprTypography(.label)
                .foregroundStyle(Color.loopr(LooprColorToken.brand.textInk))
                .padding(.horizontal, 12)
                .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil, minHeight: 32)
                .background(Color.loopr(.brand).opacity(0.12), in: Capsule(style: .continuous))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .frame(minHeight: 44)
        .accessibilityIdentifier(actionIdentifier)
    }
}
