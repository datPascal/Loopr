import Foundation
import SwiftUI
import DomainKit
import DesignSystem

enum TodayHeaderFormatting {
    /// The meta line under the Today title, in the grammar every tab shares:
    /// the day, then how long ago the band last synced. "THU 24 SEP · SYNCED
    /// 10 H AGO" on today, "YESTERDAY · WED 23 SEP · SYNCED 25 MIN AGO" on
    /// another day.
    static func meta(navigation: LooprDayNavigation, lastSync: Date?, now: Date) -> String {
        LooprHeaderMeta.line(
            dayPhrase: LooprHeaderMeta.dayPhrase(navigation),
            freshness: LooprHeaderMeta.freshness(.sync(lastSync: lastSync), indicator: nil, now: now)
        )
    }

    /// "Tue 14 Nov" for a summary's own day, for hosts without a shared day.
    static func dayLabel(for day: DayIdentity) -> String? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = .autoupdatingCurrent

        guard let date = calendar.date(from: DateComponents(
            era: day.era,
            year: day.year,
            month: day.month,
            day: day.day
        )) else {
            return nil
        }

        return LooprDateFormatterCache.string(from: date, format: "EEE d MMM", calendar: calendar)
    }
}

struct TodayExternalInsightCard: View {
    let insight: TodayExternalInsight
    let action: (String) -> Void

    var body: some View {
        Button { action(insight.routeToken) } label: {
            LooprCard {
                VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                    LooprText("HABIT INSIGHT", style: .sectionLabel, color: .inkSecondary)
                    LooprText(insight.title, style: .cardTitle)
                    LooprText(insight.detail, style: .prose, color: .inkSecondary)
                }
            }
        }
        .buttonStyle(.looprPressableCard)
        .padding(.horizontal, LooprSpacing.screenGutter)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(insight.accessibilityText)
        .accessibilityHint("Opens the habit insight details.")
        .accessibilityIdentifier("today-habit-insight")
    }
}

struct TodayGoalsCard: View {
    let summary: TodaySummary
    let route: (TodayRoute) -> Void

    @ViewBuilder
    var body: some View {
        if !summary.goals.isEmpty {
            LooprCard {
                VStack(alignment: .leading, spacing: 11) {
                    HStack(alignment: .firstTextBaseline) {
                        LooprText("GOALS", style: .sectionLabel, color: .inkSecondary)
                            .accessibilityIdentifier("today-goals")
                        Spacer(minLength: LooprSpacing.sm)
                        Text("\(onTrackCount) of \(summary.goals.count) on track")
                            .looprTypography(.caption)
                            .foregroundStyle(Color.loopr(.inkSecondary))
                            .multilineTextAlignment(.trailing)
                    }

                    ForEach(summary.goals) { goal in
                        Button {
                            route(.goalSettings)
                        } label: {
                            TodayGoalBlock(goal: goal)
                        }
                        .buttonStyle(.looprPressableRow)
                        .contentShape(Rectangle())
                        .accessibilityIdentifier("today-goal-" + goal.id)
                        .accessibilityLabel(goalAccessibilityLabel(for: goal))
                    }
                }
            }
            .padding(.horizontal, LooprSpacing.screenGutter)
        }
    }

    private var onTrackCount: Int {
        summary.goals.count { goal in
            guard let progress = goal.progressFraction else { return false }
            return progress >= 0.8
        }
    }

    private func goalAccessibilityLabel(for goal: TodayGoalProgress) -> String {
        goal.value.map { value in
            "\(goal.title), \(value) of \(goal.target ?? "unknown") \(goal.unit)"
        } ?? "\(goal.title), \(goal.state.title)"
    }
}

private struct TodayGoalBlock: View {
    let goal: TodayGoalProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.sm) {
                Text(goal.title)
                    .font(.custom("SpaceGrotesk-Medium", size: 13, relativeTo: .body))
                    .foregroundStyle(Color.loopr(.ink))
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
                Spacer(minLength: LooprSpacing.xs)
                Text(valueLabel)
                    .font(.custom("IBMPlexMono-SemiBold", size: 12, relativeTo: .caption))
                    .foregroundStyle(Color.loopr(.inkSecondary))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }

            TodayProgressRail(fraction: goal.progressFraction, accent: accent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var valueLabel: String {
        goal.value.map { value in
            "\(value) / \(goal.target ?? "—") \(goal.unit)"
        } ?? goal.state.detail
    }

    private var accent: LooprColorToken {
        let identity = "\(goal.id) \(goal.title)".lowercased()
        if identity.contains("sleep") { return .sleep }
        if identity.contains("strain") { return .strain }
        return .brand
    }
}

private struct TodayProgressRail: View {
    @Environment(\.colorScheme) private var colorScheme

    let fraction: Double?
    let accent: LooprColorToken

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Color.loopr(.divider))
                if let fraction {
                    Capsule(style: .continuous)
                        .fill(fill)
                        .frame(width: geometry.size.width * clampedFraction(fraction))
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 3)
        .accessibilityHidden(true)
    }

    /// Dark ramps the rail from a dimmed accent into the accent; the optical
    /// white set fills it solid.
    private var fill: LinearGradient {
        LinearGradient(
            colors: isDark
                ? [Color.loopr(accent).opacity(0.4), Color.loopr(accent)]
                : [Color.loopr(accent), Color.loopr(accent)],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private func clampedFraction(_ value: Double) -> CGFloat {
        CGFloat(min(max(value, 0), 1))
    }

    private var isDark: Bool {
        switch DesignSystemRuntime.state().appearance {
        case .system: colorScheme == .dark
        case .light: false
        case .dark: true
        }
    }
}

extension TodayRoute {
    var todayTitle: String {
        switch self {
        case .sleep: "Sleep"
        case .heart: "Heart"
        case .body: "Body"
        case .coach: "Coach"
        case .stress: "Stress"
        case .journal: "Journal"
        case .records: "Records"
        case .streaks: "Streaks"
        case .journey: "Journey"
        case .timeline: "Timeline"
        case .goalSettings: "Goal settings"
        case .settings: "Settings"
        case .recoveryBreakdown: "Recovery"
        case .strainBreakdown: "Strain"
        }
    }

    var todayIdentifier: String {
        switch self {
        case .sleep: "today-entry-sleep"
        case .heart: "today-entry-heart"
        case .body: "today-entry-body"
        case .coach: "today-coach"
        case .stress: "today-entry-stress"
        case .journal: "today-entry-journal"
        case .records: "today-entry-records"
        case .streaks: "today-entry-streaks"
        case .journey: "today-entry-journey"
        case .timeline: "today-entry-timeline"
        case .goalSettings: "today-entry-goal-settings"
        case .settings: "today-entry-settings"
        case .recoveryBreakdown: "today-entry-recovery"
        case .strainBreakdown: "today-entry-strain"
        }
    }
}

extension TodayMetricID {
    /// The metric detail page a Today row opens. The four signature lenses
    /// and the heart row keep routing to their tab screens.
    public var metricLinkID: String? {
        switch self {
        case .hrv: LooprMetricLinkID.rmssd
        case .restingHeartRate: LooprMetricLinkID.restingHeartRate
        case .calories: LooprMetricLinkID.activeEnergy
        case .steps: LooprMetricLinkID.steps
        case .readiness, .recovery, .sleep, .heart, .strain, .stress, .wearQuality: nil
        }
    }
}
