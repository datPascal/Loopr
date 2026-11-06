import Foundation
import SwiftUI
import DesignSystem

// The sections under the recovery hero on Today: the Ask card, Your day, the pattern card and the timeline.
// They draw from DesignSystem parts only. Taps go out through closures, so this file never reads a store.

// MARK: - Ask

/// The Ask field and three prompt chips. The field opens Ask from Today. A chip opens Ask with its question
/// already in the message field. Nothing is sent until the person taps Send.
struct TodayAskCard: View {
    @Environment(\.looprAsk) private var ask
    let prompts: [String]
    var placeholder = TodayAskPrompts.placeholder

    var body: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprAskField(placeholder, accessibilityLabel: placeholder,
                          identifier: "today-ask-composer") { ask?.open("Today") }
            TodayFlowLayout(spacing: LooprSpacing.xs) {
                ForEach(Array(prompts.enumerated()), id: \.offset) { index, prompt in
                    TodayPromptChip(text: prompt, identifier: "today-ask-chip-\(index)") { ask?.open("Today", prompt: prompt) }
                }
            }
        }
    }
}

/// A question chip. It reads like the status chips: a tinted capsule with a thin outline, but in sentence
/// case because the text is a question the person will read and tap.
struct TodayPromptChip: View {
    @Environment(\.colorScheme) private var colorScheme
    let text: String
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(text)
                .looprTypography(.label)
                .foregroundStyle(Color.loopr(.brandChip))
                .multilineTextAlignment(.leading)
                .padding(.horizontal, LooprSpacing.sm)
                .frame(minHeight: 44)
                .background(Color.loopr(.brand).opacity(isDark ? 0.10 : 0.08), in: Capsule(style: .continuous))
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(Color.loopr(.brand).opacity(isDark ? 0.35 : 0.30), lineWidth: 1)
                        .allowsHitTesting(false)
                }
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.looprPressableRow)
        .accessibilityLabel(text)
        .accessibilityHint("Opens Ask with this question.")
        .accessibilityIdentifier(identifier)
    }

    private var isDark: Bool { LooprAppearance.isDark(colorScheme) }
}

// MARK: - Your day

struct TodayYourDayCard: View {
    let metrics: [TodayYourDayMetric]
    let rows: [TodayYourDayRow]
    let openMetric: (TodayYourDayMetric.Kind) -> Void
    let openRow: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprSectionHeader("Your day", identifier: "today-your-day-header")
            LooprCard(density: .flush) {
                VStack(spacing: 0) {
                    ForEach(Array(metrics.enumerated()), id: \.element.id) { index, metric in
                        if index > 0 { LooprHairline().padding(.horizontal, LooprSpacing.cardHorizontal) }
                        metricRow(metric)
                    }
                    ForEach(rows) { row in
                        LooprHairline().padding(.horizontal, LooprSpacing.cardHorizontal)
                        TodayYourDayRowView(row: row) { openRow(row.id) }
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("today-your-day")
        }
    }

    private func metricRow(_ metric: TodayYourDayMetric) -> some View {
        LooprContributorRow(
            title: metric.title, value: metric.value, unit: metric.unit, comparison: metric.caption,
            range: metric.range.map { LooprContributorRange(value: $0.value, usual: $0.usual, domain: $0.domain) },
            accent: metric.kind == .sleep ? .sleep : .strain, identifier: metric.identifier
        ) { openMetric(metric.kind) }
        .padding(.horizontal, LooprSpacing.cardHorizontal)
    }
}

/// A Food, Train or Journal row: the title and a quiet line on the left, then a number or a status chip.
struct TodayYourDayRowView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let row: TodayYourDayRow
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: LooprSpacing.sm) {
                VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                    LooprText(row.title, style: .rowTitle)
                    if let caption = row.caption {
                        LooprText(caption, style: .caption, color: .inkSecondary)
                    }
                    if dynamicTypeSize.isAccessibilitySize { trailing }
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                if !dynamicTypeSize.isAccessibilitySize { trailing }
                LooprChevron()
            }
            .padding(.horizontal, LooprSpacing.cardHorizontal)
            .padding(.vertical, LooprSpacing.sm + 1)
            .frame(minHeight: LooprSpacing.interactiveRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.looprPressableRow)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier(row.identifier)
    }

    @ViewBuilder
    private var trailing: some View {
        if let value = row.value {
            // Beside the title the value keeps one line. Under it, at accessibility sizes, it may wrap: one fixed line
            // ("1,240 of 2,450 kcal" is 403 pt at AX5) made the card, and with it all of Today, wider than the screen.
            LooprValueText(value, unit: row.unit)
                .fixedSize(horizontal: !dynamicTypeSize.isAccessibilitySize, vertical: true)
        } else if let chip = row.chip {
            StatusChip(chip, symbol: nil, tone: .brand)
        }
    }
}

// MARK: - Pattern

struct TodayPatternSection: View {
    let card: TodayPatternCard
    let act: (TodayAgentAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprSectionHeader("Pattern this week", detail: card.nightsLine, actionTitle: "All",
                               identifier: "today-pattern-header", actionIdentifier: "today-pattern-all") { act(.patterns) }
            LooprCard(style: .hero(.brand)) {
                VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                    StatusChip(card.strengthLabel, symbol: nil, tone: .brand)
                    LooprText(card.title, style: .cardTitle)
                        .fixedSize(horizontal: false, vertical: true)
                    LooprText(card.detail, style: .prose, color: .inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: LooprSpacing.sm) {
                        Button("Show the nights") { act(.patterns) }
                            .buttonStyle(LooprButtonStyle(prominent: false))
                            .accessibilityIdentifier("today-pattern-show")
                        if card.canStartTest {
                            Button("Test it for 14 days") { act(.startPatternTest(card.id)) }
                                .buttonStyle(LooprButtonStyle())
                                .accessibilityIdentifier("today-pattern-try")
                        }
                    }
                    .padding(.top, LooprSpacing.xxs)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("today-pattern-card")
        }
    }
}

// MARK: - Timeline

struct TodayTimelineCard: View {
    let rows: [TodayTimelineRowContent]
    let open: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprSectionHeader("Timeline", identifier: "today-timeline-header")
            LooprCard(density: .flush) {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        LooprTimelineRow(time: row.time, title: row.title, detail: row.detail, isDimmed: row.isDimmed,
                                         identifier: "today-timeline-\(row.id)", showsDivider: index < rows.count - 1,
                                         action: row.isInteractive ? { open(row.id) } : nil)
                    }
                }
            }
            // The last element on the page. The visual lane scrolls until it is on screen.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("today-timeline-end")
        }
    }
}
