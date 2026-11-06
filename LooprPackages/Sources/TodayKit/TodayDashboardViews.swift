import Foundation
import SwiftUI
import DomainKit
import DesignSystem

/// The Today tab for a day with data, top to bottom: the day dial with its readouts (its placeholder while it loads),
/// the overnight check when two or more signals are out of range, the note and Up next. Everything else (the
/// experiment, pinned numbers, the pattern and the timeline) waits under one "More from today" row, so the
/// first screen says how the night went and what is next (UX R1-DES-01). Ask lives in the header only. Your day left
/// in round 2: every row repeated something on the dial, Food or Fitness.
struct TodayDashboardContent: View {
    @Environment(\.looprDayNavigation) private var dayNavigation

    let summary: TodaySummary
    let dashboard: TodayDashboard
    let route: (TodayRoute) -> Void
    let agent: TodayAgentContent
    let onAgentAction: (TodayAgentAction) -> Void
    let externalInsight: TodayExternalInsight?
    let onExternalInsight: (String) -> Void
    let pinnedNumbers: AnyView?
    /// The day dial. Nil while it loads, when its placeholder holds the place.
    var dial: TodayDialContent? = nil
    /// Where the coach note and Up next go under the dial (LV-04 step 3).
    var dialCompanion: AnyView? = nil
    /// The experiment strip, under "More from today".
    var dialCompanionMore: AnyView? = nil

    var body: some View {
        // No 1 by 1 point status element above the dial any more: VoiceOver met an invisible "Recovery, Waiting for last
        // night" first (ICP R2-NEW-5). The dial's recovery readout and the briefing's hero speak the same state where
        // they are drawn.
        VStack(alignment: .leading, spacing: 0) {
            if TodayLead(dial: dial) == .dial, let dial {
                TodayDialSection(content: dial, recovery: dashboard.hero, openRecovery: { route(.recoveryBreakdown) })
                    .padding(.top, LooprSpacing.xs)
                if let headsUp = dashboard.headsUp {
                    TodayHeadsUpRow(headsUp: headsUp, open: { route(.heart) })
                        .padding(.top, LooprSpacing.sm)
                }
                if let dialCompanion {
                    dialCompanion
                        .padding(.top, LooprSpacing.lg)
                }
            } else {
                // The dial is still loading: its own frame holds the place, so nothing jumps when it lands and no
                // other layout shows first (ICP R3-PAS-1).
                TodayDialPlaceholder()
                    .padding(.top, LooprSpacing.xs)
                if let headsUp = dashboard.headsUp {
                    TodayHeadsUpRow(headsUp: headsUp, open: { route(.heart) })
                        .padding(.top, LooprSpacing.sm)
                }
            }

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

            TodayMoreSection(parts: moreParts) {
                if let dialCompanionMore { dialCompanionMore }
                // No Your day card: its sleep, strain, food and workout rows each repeated the dial, Food or Fitness
                // (UX R2-DES-05, R2-VET-23).

                if let pinnedNumbers {
                    pinnedNumbers
                        .padding(.horizontal, LooprSpacing.screenGutter)
                }

                if let pattern = agent.pattern {
                    TodayPatternSection(card: pattern, act: onAgentAction)
                        .padding(.horizontal, LooprSpacing.screenGutter)
                }

                if !timelineRows.isEmpty {
                    TodayTimelineCard(rows: timelineRows) { id in
                        if id == "bedtime" { route(.sleep) } else { onAgentAction(.timelineItem(id)) }
                    }
                    .padding(.horizontal, LooprSpacing.screenGutter)
                }
            }
            .padding(.top, LooprSpacing.xl)
        }
    }

    private var moreParts: [String] {
        var parts: [String] = []
        if dialCompanionMore != nil { parts.append("Experiment") }
        if pinnedNumbers != nil { parts.append("Your numbers") }
        if agent.pattern != nil { parts.append("Pattern") }
        if !timelineRows.isEmpty { parts.append("Timeline") }
        return parts
    }

    private var isToday: Bool { dayNavigation?.isToday ?? true }

    /// The minutes since midnight on the day's clock, for a day that is still going. Past days dim nothing.
    private var nowMinute: Int? {
        guard isToday else { return nil }
        if let pinned = agent.nowMinute { return pinned }
        let calendar = dayNavigation?.calendar ?? .current
        let parts = calendar.dateComponents([.hour, .minute], from: dayNavigation?.now ?? Date())
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    private var timelineRows: [TodayTimelineRowContent] {
        TodayTimelineRules.rows(items: agent.timeline, tonight: dashboard.tonight, nowMinute: nowMinute)
    }
}

/// Today on a day the band has not filled: what the person logged still shows, and Ask stays one tap away. Without
/// this, a new install or a day before the first sync hid food, training, journal and Ask behind "Nothing for today yet".
struct TodayManualDayContent: View {
    @Environment(\.looprDayNavigation) private var dayNavigation

    let agent: TodayAgentContent
    let route: (TodayRoute) -> Void
    let onAgentAction: (TodayAgentAction) -> Void
    /// The day dial in its designed empty or partial state, when the app gives one.
    var dial: TodayDialContent? = nil
    /// The note and Up next. The rules do not need band data.
    var dialCompanion: AnyView? = nil
    /// The experiment strip, under "More from today".
    var dialCompanionMore: AnyView? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if TodayLead(dial: dial) == .dial, let dial {
                TodayDialSection(content: dial, recovery: nil, openRecovery: { route(.recoveryBreakdown) })
                    .padding(.top, LooprSpacing.lg)
                if let dialCompanion {
                    dialCompanion
                        .padding(.top, LooprSpacing.lg)
                }
            } else {
                TodayDialPlaceholder()
                    .padding(.top, LooprSpacing.lg)
            }
            if !moreParts.isEmpty {
                TodayMoreSection(parts: moreParts) {
                    if let dialCompanionMore { dialCompanionMore }

                    if let pattern = agent.pattern {
                        TodayPatternSection(card: pattern, act: onAgentAction)
                            .padding(.horizontal, LooprSpacing.screenGutter)
                    }

                    if !timelineRows.isEmpty {
                        TodayTimelineCard(rows: timelineRows) { id in
                            if id == "bedtime" { route(.sleep) } else { onAgentAction(.timelineItem(id)) }
                        }
                        .padding(.horizontal, LooprSpacing.screenGutter)
                    }
                }
                .padding(.top, LooprSpacing.xl)
            }
        }
        // A container, so the dial, its readouts and the rail keep their own identifiers inside it.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("today-manual-day")
    }

    private var isToday: Bool { dayNavigation?.isToday ?? true }

    private var moreParts: [String] {
        var parts: [String] = []
        if dialCompanionMore != nil { parts.append("Experiment") }
        if agent.pattern != nil { parts.append("Pattern") }
        if !timelineRows.isEmpty { parts.append("Timeline") }
        return parts
    }

    private var timelineRows: [TodayTimelineRowContent] {
        var minute: Int?
        if isToday {
            if let pinned = agent.nowMinute { minute = pinned } else {
                let calendar = dayNavigation?.calendar ?? .current
                let parts = calendar.dateComponents([.hour, .minute], from: dayNavigation?.now ?? Date())
                minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            }
        }
        return TodayTimelineRules.rows(items: agent.timeline, tonight: nil, nowMinute: minute)
    }
}

/// A left-aligned wrapping row. A subview wider than the row, such as a long prompt at the largest text sizes, is
/// offered the row's width so it wraps instead of running past the edge.
struct TodayFlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = Self.size(of: subview, within: width)
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
            let size = Self.size(of: subview, within: bounds.width)
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

    /// The subview's own size, or the size it takes wrapped to `width` when its own is wider.
    static func size(of subview: LayoutSubview, within width: CGFloat) -> CGSize {
        let natural = subview.sizeThatFits(.unspecified)
        guard width.isFinite, width > 0, natural.width > width else { return natural }
        return subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
    }
}

// MARK: - Recovery words

/// What VoiceOver reads for the day's recovery. The day dial's recovery readout speaks it. The old recovery ring hero
/// that drew it is gone: Today always leads with the dial (ICP R3-PAS-1).
enum TodayRecoveryHero {
    /// The score, the band, the early-estimate note and the driver sentence.
    nonisolated static func spokenLabel(for hero: TodayHeroState) -> String {
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
    /// Hides the row. Nil leaves it without a close button.
    var hide: (() -> Void)? = nil

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                    status
                    actionButton
                        .frame(maxWidth: .infinity)
                    hideButton
                }
            } else {
                HStack(spacing: LooprSpacing.sm) {
                    status
                    Spacer(minLength: LooprSpacing.xs)
                    actionButton
                    hideButton
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

    @ViewBuilder private var hideButton: some View {
        if let hide {
            Button(action: hide) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.loopr(.inkSecondary))
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityLabel("Close")
            .accessibilityHint("You can connect a band later in Settings.")
            .accessibilityIdentifier("\(statusIdentifier)-hide")
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

/// "More from today": the experiment, pinned numbers, the pattern and the timeline, folded under one row so the
/// first screen stays short (UX R1-DES-01, R1-NEW-07, R1-VET-01). It starts closed on every launch.
struct TodayMoreSection<Content: View>: View {
    let parts: [String]
    @ViewBuilder let content: () -> Content
    @State private var isOpen = LooprFoldSummary.opensForCapture

    var body: some View {
        LooprFoldSection("More from today", summary: LooprFoldSummary.list(parts), identifier: "today-more",
                         isOpen: $isOpen, spacing: LooprSpacing.xl, rowPadding: LooprSpacing.screenGutter, content: content)
    }
}
