import Foundation
import SwiftUI
import DomainKit
import DesignSystem

// The Body tab's sections. Each lays out a model from `BodyInsights.swift`
// and owns no rules of its own.

/// Opens the profile in Settings, where age, height and weight live. The app
/// sets it; without it the profile prompt tells people where to go instead.
public struct BodyProfileAction: Sendable {
    public let open: @MainActor @Sendable () -> Void

    public init(open: @escaping @MainActor @Sendable () -> Void) { self.open = open }
}

extension EnvironmentValues {
    @Entry public var bodyOpenProfile: BodyProfileAction? = nil
}

// MARK: Layout

/// A section: the eyebrow, then its content, with the tab's rhythm.
struct BodySection<Content: View>: View {
    let title: String
    var detail: String? = nil
    var identifier: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprSectionHeader(title, detail: detail)
            content
        }
        .modifier(BodyOptionalIdentifier(identifier))
    }
}

struct BodyOptionalIdentifier: ViewModifier {
    let identifier: String?
    init(_ identifier: String?) { self.identifier = identifier }

    func body(content: Content) -> some View {
        // A container keeps its children's own identifiers; without
        // `.contain` SwiftUI would stamp this one onto every child.
        if let identifier {
            content.accessibilityElement(children: .contain).accessibilityIdentifier(identifier)
        } else {
            content
        }
    }
}

/// Rows inside a card: 12 pt of air above and below, a hairline between.
struct BodyRowStack<Row: Identifiable, RowView: View>: View {
    let rows: [Row]
    @ViewBuilder let row: (Row) -> RowView

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, item in
                row(item)
                    .padding(.vertical, LooprSpacing.sm)
                if index < rows.count - 1 {
                    Rectangle().fill(Color.loopr(.divider)).frame(height: 1).accessibilityHidden(true)
                }
            }
        }
        .padding(.vertical, -LooprSpacing.sm)
    }
}

// MARK: Strain hero

/// Strain on the 0 to 21 ring, the suggested range for the day's recovery
/// drawn on the track, and the verdict against it.
struct BodyStrainHeroView: View {
    @Environment(\.looprMetricLink) private var metricLink
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let hero: BodyStrainHero
    let isToday: Bool
    /// False until the day's history has loaded, so the hero never claims
    /// there is no recovery score before it has looked.
    var showsSentence = true
    let usualDelta: LooprDelta?

    private static let scale = LooprRingScale(fullValue: 21)

    var body: some View {
        if let metricLink, metricLink.supports(LooprMetricLinkID.strain) {
            Button { metricLink.open(LooprMetricLinkID.strain) } label: {
                seat.looprMetricZoomSource(LooprMetricLinkID.strain)
            }
                .buttonStyle(.looprPressableCard)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(hero.accessibilityLabel(isToday: isToday))
                .accessibilityValue(usualDelta?.spokenText ?? "")
                .accessibilityHint("Opens strain history and explanation")
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("body-strain-lens")
        } else {
            seat
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(hero.accessibilityLabel(isToday: isToday))
                .accessibilityIdentifier("body-strain-lens")
        }
    }

    /// Open on the dark background, on a white card in light mode, as every
    /// tab hero is seated.
    @ViewBuilder
    private var seat: some View {
        if isDark {
            stack
                .padding(.top, 22)
                .padding(.horizontal, LooprSpacing.md)
                .padding(.bottom, LooprSpacing.xs)
                .frame(maxWidth: .infinity)
        } else {
            stack
                .padding(.top, 24)
                .padding(.horizontal, 18)
                .padding(.bottom, 22)
                .frame(maxWidth: .infinity)
                .background(Color.loopr(.sheetFill), in: RoundedRectangle(cornerRadius: LooprRadius.card, style: .continuous))
                .shadow(color: Color.loopr(.ink).opacity(0.06), radius: 2, y: 1)
                .shadow(color: Color.loopr(.ink).opacity(0.05), radius: 15, y: 10)
                .padding(.horizontal, LooprSpacing.md)
        }
    }

    private var stack: some View {
        VStack(spacing: LooprSpacing.sm) {
            ZStack {
                if let target = hero.target {
                    LooprRingRange(target.range, scale: Self.scale, accent: .strain, diameter: diameter)
                }
                LooprProgressRing(
                    value: hero.strain,
                    scale: Self.scale,
                    text: text,
                    format: .oneDecimal,
                    caption: "Strain",
                    accent: .strain,
                    diameter: diameter
                )
            }
            .padding(.bottom, 2)

            VStack(spacing: LooprSpacing.xs) {
                if let verdict = hero.verdict {
                    LooprText(verdict, style: .title)
                        .multilineTextAlignment(.center)
                }
                if hero.target != nil {
                    legend
                }
                if let reason = hero.target?.reason {
                    LooprText(reason, style: .caption, color: .inkSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityHidden(true)
                }
                if showsSentence, let sentence = hero.sentence(isToday: isToday) {
                    Text(sentence)
                        .looprTypography(.prose)
                        .foregroundStyle(Color.loopr(.inkSecondary))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 320)
                }
                if let usualDelta {
                    LooprDeltaCaption(usualDelta, accent: .strain)
                        .padding(.top, 2)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// A key for the brighter track segment, so the range reads without the
    /// sentence.
    private var legend: some View {
        HStack(spacing: LooprSpacing.xs) {
            Capsule(style: .continuous)
                .fill(Color.loopr(.strain).opacity(isDark ? 0.42 : 0.34))
                .overlay(alignment: .leading) { tick }
                .overlay(alignment: .trailing) { tick }
                .frame(width: 22, height: 6)
            Text(hero.rangeLegend ?? "")
                .looprTypography(.caption)
                .foregroundStyle(Color.loopr(.inkSecondary))
        }
        .accessibilityHidden(true)
    }

    private var tick: some View {
        Capsule().fill(Color.loopr(LooprColorToken.strain.textInk)).frame(width: 2, height: 10)
    }

    private var text: String {
        if case .measured(_, let text, _) = hero.state { return text }
        return "—"
    }

    private var diameter: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 200 : 180
    }

    private var isDark: Bool { LooprAppearance.isDark(colorScheme) }
}

/// Strain waits on the profile: one small card with the reason and one
/// button, in place of an empty ring.
struct BodyProfilePromptCard: View {
    @Environment(\.profileAgeAction) private var profileAgeAction
    @Environment(\.bodyOpenProfile) private var openProfile
    let prompt: BodyProfilePrompt

    var body: some View {
        LooprSurface(emphasis: .hero(.strain)) {
            VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                HStack(alignment: .center, spacing: LooprSpacing.sm) {
                    ZStack {
                        Circle()
                            .fill(Color.loopr(.strain).opacity(0.14))
                            .frame(width: 36, height: 36)
                        Image(systemName: "person.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.loopr(LooprColorToken.strain.textInk))
                    }
                    .accessibilityHidden(true)
                    LooprText(prompt.title, style: .cardTitle)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(prompt.message)
                    .looprTypography(.prose)
                    .foregroundStyle(Color.loopr(.inkSecondary))
                    .fixedSize(horizontal: false, vertical: true)
                if profileAgeAction != nil || openProfile != nil {
                    Button {
                        if let profileAgeAction { profileAgeAction.open() }
                        else { openProfile?.open() }
                    } label: {
                        HStack(spacing: LooprSpacing.xxs) {
                            Text(prompt.actionTitle)
                                .looprTypography(.label)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .accessibilityHidden(true)
                        }
                        .foregroundStyle(Color.loopr(LooprColorToken.strain.textInk))
                        .padding(.horizontal, LooprSpacing.md)
                        .frame(minHeight: 44)
                        .background(Color.loopr(.strain).opacity(0.14), in: Capsule(style: .continuous))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.looprPressableCard)
                    .accessibilityIdentifier("body-profile-prompt-action")
                    .accessibilityHint("Opens your profile in Settings")
                } else {
                    LooprText(ProfileAgePrompt.action, style: .caption, color: .inkSecondary)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("body-profile-prompt")
    }
}

/// No strain for a reason the person cannot fix here: a quiet line, not a
/// ring with a word in it.
struct BodyMissingStrainRow: View {
    let reason: String?

    var body: some View {
        LooprSurface {
            HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.sm) {
                VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                    LooprText("Strain", style: .rowTitle)
                    if let reason {
                        Text(reason)
                            .looprTypography(.caption)
                            .foregroundStyle(Color.loopr(.inkSecondary))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: LooprSpacing.sm)
                LooprText("No reading", style: .caption, color: .inkSecondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("body-strain-missing")
    }
}

// MARK: Strain and recovery week

struct BodyStrainWeekSection: View {
    let days: [LooprPairedBarDay]

    var body: some View {
        BodySection(title: "Strain and recovery", detail: "Each day's strain beside the following morning's recovery",
                    identifier: "body-strain-week") {
            LooprSurface {
                VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                    if BodyStrainWeek.isWorthShowing(days) {
                        LooprPairedBars(days: days, first: .strain, second: .recovery,
                                        title: "Strain and next-morning recovery, last 14 days", height: 150,
                                        identifier: "body-strain-week-chart")
                    }
                    let paired = days.filter { $0.first != nil && $0.second != nil }.count
                    LooprText(paired > 0 ? "Both readings are recorded for \(paired) of 14 days." :
                        "No paired days yet. Wear your band during the day and overnight, then sync the next morning.",
                        style: .prose, color: .inkSecondary)
                }
            }
        }
    }
}

// MARK: Training load

struct BodyTrainingLoadCard: View {
    let state: BodyTrainingLoad.State
    let points: [BodyLoadTrendPoint]
    let open: () -> Void

    var body: some View {
        BodySection(title: "Training load", detail: "Recent strain against your longer-term load") {
            Button(action: open) {
                LooprSurface {
                    VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                        HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.sm) {
                            LooprText(state.title, style: isReady ? .cardTitle : .rowTitle)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: LooprSpacing.xs)
                            LooprChevron()
                        }
                        Text(state.detail)
                            .looprTypography(.prose)
                            .foregroundStyle(Color.loopr(.inkSecondary))
                            .fixedSize(horizontal: false, vertical: true)
                        if points.contains(where: { $0.acute != nil }) {
                            BodyLoadTrendChart(points: points)
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.looprPressableCard)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Training load. \(state.title). \(state.detail)")
            .accessibilityHint("Opens training load")
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("body-training-load")
        }
    }

    private var isReady: Bool {
        if case .ready = state { return true }
        return false
    }
}

/// This week's daily strain as a dot against the usual band.
struct BodyLoadRangeBar: View {
    let load: BodyTrainingLoad

    var body: some View {
        let band = load.usualRange
        let upper = max(band.upperBound * 1.45, load.acute * 1.1, 1)
        LooprTypicalRangeBar(
            value: load.acute,
            typical: band,
            domain: 0...upper,
            accent: .strain,
            lowLabel: LooprUnitFormatter.number(band.lowerBound, digits: 1),
            highLabel: LooprUnitFormatter.number(band.upperBound, digits: 1)
        )
        .padding(.top, LooprSpacing.xxs)
    }
}

// MARK: Heart-rate zones

enum BodyZoneStyle {
    static func color(for id: Int) -> Color {
        Color.loopr(LooprZonePalette.token(for: id))
    }
}

struct BodyZoneSection: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var grown = false
    let bar: BodyZoneBar
    let isToday: Bool

    var body: some View {
        BodySection(title: isToday ? "Heart-rate zones today" : "Heart-rate zones",
                    detail: "\(BodyZoneBar.minutesText(bar.totalMinutes)) in zones",
                    identifier: "body-zone-minutes") {
            LooprSurface {
                VStack(alignment: .leading, spacing: LooprSpacing.md) {
                    proportionalBar
                    BodyRowStack(rows: bar.segments) { segment in
                        row(segment)
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(bar.accessibilitySummary)
        }
        .onAppear {
            guard !grown else { return }
            if reduceMotion || DesignSystemRuntime.state().reduceMotion == true { grown = true } else {
                withAnimation(.snappy(duration: LooprMotion.deliberate)) { grown = true }
            }
        }
    }

    private var proportionalBar: some View {
        GeometryReader { proxy in
            let gap: CGFloat = 2
            let visible = bar.segments.filter { $0.minutes > 0 }.count
            let widths = bar.widths(total: Double(max(proxy.size.width - gap * CGFloat(max(visible - 1, 0)), 0)), minimum: 4)
            HStack(spacing: gap) {
                ForEach(Array(bar.segments.enumerated()), id: \.element.id) { index, segment in
                    if widths[index] > 0 {
                        Rectangle()
                            .fill(BodyZoneStyle.color(for: segment.id))
                            .frame(width: CGFloat(widths[index]))
                    }
                }
            }
            .frame(width: proxy.size.width, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .scaleEffect(x: grown ? 1 : 0.001, y: 1, anchor: .leading)
        }
        .frame(height: 14)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func row(_ segment: BodyZoneBar.Segment) -> some View {
        let swatch = RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(BodyZoneStyle.color(for: segment.id))
            .frame(width: 12, height: 12)
        let minutes = LooprValueText(BodyZoneBar.minutesText(segment.minutes), valueStyle: .metricUnit, unitStyle: .caption,
                                     color: segment.minutes > 0 ? .ink : .inkSecondary)
        let percent = LooprText(BodyZoneBar.percentText(segment.share), style: .caption, color: .inkSecondary)
        if dynamicTypeSize.isAccessibilitySize {
            // Large text: the zone on one line, its time under it, so no
            // word has to break.
            VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                HStack(alignment: .center, spacing: LooprSpacing.sm) {
                    swatch
                    LooprText("Zone \(segment.id) · \(segment.name)", style: .rowTitle)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.sm) {
                    minutes
                    percent
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.sm) {
                swatch.alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.xs) {
                    LooprText("Zone \(segment.id)", style: .rowTitle)
                    LooprText(segment.name, style: .caption, color: .inkSecondary)
                }
                Spacer(minLength: LooprSpacing.xs)
                percent
                minutes.frame(minWidth: 64, alignment: .trailing)
            }
        }
    }
}

// MARK: Activity

struct BodyActivitySection: View {
    @Environment(\.looprMetricLink) private var metricLink
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let rows: [BodyActivityRow]

    var body: some View {
        BodySection(title: "Activity", detail: "Estimates from your band's motion and heart rate") {
            LooprSurface {
                BodyRowStack(rows: rows) { row in
                    rowView(row)
                }
            }
        }
    }

    @ViewBuilder
    private func rowView(_ row: BodyActivityRow) -> some View {
        if let linkID = row.metricLinkID, let metricLink, metricLink.supports(linkID) {
            Button { metricLink.open(linkID) } label: {
                content(row, navigable: true).looprMetricZoomSource(linkID, cornerRadius: 0)
            }
                .buttonStyle(.looprPressableRow)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(row.accessibilityLabel)
                .accessibilityHint("Opens history and explanation")
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("body-metric-\(row.id.rawValue)")
        } else {
            content(row, navigable: false)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(row.accessibilityLabel)
                .accessibilityIdentifier("body-metric-\(row.id.rawValue)")
        }
    }

    private func content(_ row: BodyActivityRow, navigable: Bool) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: LooprSpacing.xs))
            : AnyLayout(HStackLayout(alignment: .top, spacing: LooprSpacing.sm))
        return HStack(alignment: .center, spacing: LooprSpacing.sm) {
            layout {
                VStack(alignment: .leading, spacing: 3) {
                    LooprText(row.title, style: .rowTitle)
                    if let caption = row.caption {
                        Text(caption)
                            .looprTypography(.caption)
                            .foregroundStyle(Color.loopr(.inkSecondary))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)
                VStack(alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .trailing, spacing: 3) {
                    if let value = row.value {
                        LooprValueText(value, unit: row.unit, valueStyle: .metricCompact)
                    } else {
                        LooprText("No reading", style: .caption, color: .inkSecondary)
                    }
                    if let delta = row.delta {
                        LooprDeltaCaption(delta, accent: .strain, length: .compact, style: .caption)
                    }
                }
                .fixedSize()
            }
            if navigable { LooprChevron() }
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}

// MARK: Age estimates

struct BodyAgeSection: View {
    let cardio: BodyAgeLock
    let loopr: BodyAgeLock
    let route: (BodyRoute) -> Void

    var body: some View {
        BodySection(title: "Age estimates", identifier: "body-age-estimates") {
            LooprSurface {
                BodyRowStack(rows: [AgeRow(id: .cardioAge, lock: cardio), AgeRow(id: .looprAge, lock: loopr)]) { row in
                    Button { route(row.id) } label: { BodyAgeLockRow(lock: row.lock) }
                        .buttonStyle(.looprPressableRow)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(row.lock.accessibilityLabel)
                        .accessibilityAddTraits(.isButton)
                        .accessibilityIdentifier(row.id == .cardioAge ? "body-cardio-age" : "body-loopr-age")
                }
            }
        }
    }

    private struct AgeRow: Identifiable {
        let id: BodyRoute
        let lock: BodyAgeLock
    }
}

struct BodyAgeLockRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let lock: BodyAgeLock

    var body: some View {
        HStack(alignment: .center, spacing: LooprSpacing.sm) {
            ZStack {
                Circle()
                    .fill(Color.loopr(lock.isAvailable ? .heart : .inkMuted).opacity(lock.isAvailable ? 0.14 : 0.16))
                    .frame(width: 34, height: 34)
                Image(systemName: lock.isAvailable ? "heart.fill" : "lock.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.loopr(lock.isAvailable ? .heart : .inkSecondary))
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                let status = LooprText(lock.status, style: lock.isAvailable ? .metricUnit : .caption,
                                       color: lock.isAvailable ? .ink : .inkSecondary)
                if dynamicTypeSize.isAccessibilitySize {
                    LooprText(lock.title, style: .rowTitle)
                    status
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.xs) {
                        LooprText(lock.title, style: .rowTitle)
                        Spacer(minLength: LooprSpacing.xs)
                        status
                    }
                }
                Text(lock.summary)
                    .looprTypography(.caption)
                    .foregroundStyle(Color.loopr(.inkSecondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
            LooprChevron()
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}

// MARK: Body composition

struct BodyCompositionSection: View {
    @Environment(\.bodyOpenProfile) private var openProfile
    let composition: BodyCompositionRows

    var body: some View {
        BodySection(title: "Body composition", detail: composition.source, identifier: "body-composition") {
            LooprSurface {
                if composition.rows.isEmpty {
                    empty
                } else {
                    BodyRowStack(rows: composition.rows) { row in
                        HStack(alignment: .firstTextBaseline) {
                            LooprText(row.title, style: .rowTitle)
                            Spacer(minLength: LooprSpacing.sm)
                            LooprValueText(row.value, valueStyle: .metricUnit, unitStyle: .caption)
                        }
                        .frame(minHeight: 28)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var empty: some View {
        let content = HStack(alignment: .center, spacing: LooprSpacing.sm) {
            VStack(alignment: .leading, spacing: 3) {
                LooprText("No weight or height yet", style: .rowTitle)
                LooprText(openProfile == nil ? "Add them in Settings, under Profile." : "Add them to your profile.",
                          style: .caption, color: .inkSecondary)
            }
            Spacer(minLength: LooprSpacing.sm)
            if openProfile != nil { LooprChevron() }
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        if let openProfile {
            Button { openProfile.open() } label: { content }
                .buttonStyle(.looprPressableRow)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("body-composition-add")
        } else {
            content.accessibilityElement(children: .combine)
        }
    }
}
