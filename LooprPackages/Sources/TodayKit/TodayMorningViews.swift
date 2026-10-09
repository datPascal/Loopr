import DesignSystem
import SwiftUI

struct TodayMorningBriefingView: View {
    let hero: TodayHeroState
    let headsUp: TodayHeadsUp?
    let openRecovery: () -> Void
    let openCheck: () -> Void

    var body: some View {
        VStack(spacing: LooprSpacing.sm) {
            TodayRecoveryHero(hero: hero, isInteractive: true, action: openRecovery)
            if let headsUp {
                Button(action: openCheck) {
                    HStack(alignment: .top, spacing: LooprSpacing.sm) {
                        Image(systemName: "waveform.path.ecg")
                            .foregroundStyle(Color.loopr(.caution))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                            LooprText(headsUp.title, style: .prose)
                                .fixedSize(horizontal: false, vertical: true)
                            LooprText("View overnight check", style: .label, color: .brand)
                        }
                        Spacer(minLength: 0)
                        LooprChevron()
                    }
                    .padding(.horizontal, LooprSpacing.cardHorizontal)
                    .padding(.vertical, LooprSpacing.sm)
                    .looprCardBackground()
                }
                .buttonStyle(.looprPressableCard)
                .accessibilityIdentifier("today-heads-up")
                .padding(.horizontal, LooprSpacing.screenGutter)
            }
        }
    }
}

struct TodayMorningContributorsView: View {
    let signals: TodayMorningSignals
    let subtitle: String?
    let open: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprSectionHeader("Last night's signals", detail: subtitle)
                .accessibilityIdentifier("today-signals-header")
            if signals == .empty {
                LooprText("Wear your band overnight and sync in the morning.", style: .caption, color: .inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, LooprSpacing.xxs)
                    .accessibilityIdentifier("today-signals-empty")
            } else if case .readings(let rows) = signals {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { LooprHairline().padding(.horizontal, LooprSpacing.cardHorizontal) }
                        LooprOvernightSignalRow(title: row.title, value: row.value, unit: row.unit,
                            comparison: row.comparison, range: row.range, status: row.statusText,
                            accent: row.linkID == LooprMetricLinkID.sleepDuration ? .sleep : .heart,
                            compact: true, identifier: "today-contributor-\(row.id)") { open(row.linkID) }
                            .padding(.horizontal, LooprSpacing.cardHorizontal)
                    }
                }
                .looprCardBackground()
            }
        }
        .padding(.horizontal, LooprSpacing.screenGutter)
    }
}

struct TodayComparisonCaption: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let delta: LooprDelta
    let accent: LooprColorToken

    var body: some View {
        if case .learning = delta.kind {
            Text(TodayMorningComparison.text(delta))
                .looprTypography(.confidence)
                .foregroundStyle(Color.loopr(.inkSecondary))
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                .minimumScaleFactor(0.8)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(TodayMorningComparison.spoken(delta))
        } else if case .usual = delta.kind {
            LooprText("In your usual range", style: .caption, color: .inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if TodayMorningComparison.isSameAsUsual(delta) {
            LooprText(TodayMorningComparison.text(delta), style: .caption, color: .inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            LooprDeltaCaption(delta, accent: accent, style: .confidence, wraps: true)
        }
    }
}
