import DesignSystem
import SwiftUI

/// The goal and the weight that follows it, under the day's food. Without targets it only offers
/// the weight log; the plan prompt sits at the top of the tab instead.
struct FoodGoalCard: View {
    @Environment(\.calendar) private var calendar
    let progress: FoodGoalProgress?
    let trend: FoodWeightTrend?
    let now: Date
    let onEdit: () -> Void
    let onLogWeight: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprSectionHeader(progress == nil ? "Weight" : "Goal", actionTitle: progress == nil ? nil : "Edit", accent: .energy,
                               identifier: "food-goal-header", actionIdentifier: "food-goal-edit", action: progress == nil ? nil : onEdit)
            LooprCard {
                VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                    if let progress {
                        HStack(spacing: LooprSpacing.sm) {
                            Image(systemName: progress.goal == .lose ? "arrow.down.right" : progress.goal == .build ? "dumbbell.fill" : "equal")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Color.loopr(.energy))
                                .frame(width: 32, height: 32)
                                .background(Color.loopr(.energy).opacity(0.12), in: Circle())
                                .accessibilityHidden(true)
                            LooprText(progress.headline, style: .cardTitle)
                                .accessibilityIdentifier("food-goal-headline")
                        }
                    }
                    if let trend { readings(trend) } else {
                        HStack(alignment: .top, spacing: LooprSpacing.sm) {
                            if progress == nil {
                                Image(systemName: "scalemass.fill")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(Color.loopr(.energy))
                                    .frame(width: 32, height: 32)
                                    .background(Color.loopr(.energy).opacity(0.12), in: Circle())
                                    .accessibilityHidden(true)
                            }
                            LooprText("Weigh in most mornings. One reading moves with water and food, so Loopr draws a smoothed trend once you have \(FoodWeightTrend.minimumDays) weigh-ins in \(FoodWeightTrend.windowDays) days.",
                                      style: .prose, color: .inkSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Button(action: onLogWeight) { Label("Log weight", systemImage: "plus") }
                        .buttonStyle(LooprButtonStyle(prominent: false, accent: .energy))
                        .accessibilityIdentifier("food-log-weight")
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("food-goal-card")
        }
    }

    @ViewBuilder private func readings(_ trend: FoodWeightTrend) -> some View {
        let goalWeight = progress?.plan?.goalWeightKg
        let stale = trend.isStale(at: now)
        HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.xxs) {
            LooprText(FoodGoalProgress.kilograms(stale ? trend.latest.kilograms : trend.current), style: .metric)
            LooprText("kg", style: .metricUnit, color: .inkSecondary)
            Spacer(minLength: LooprSpacing.sm)
            if let goalWeight, progress?.goal != .maintain {
                VStack(alignment: .trailing, spacing: 2) {
                    LooprText("Goal", style: .caption, color: .inkSecondary)
                    LooprText("\(FoodGoalProgress.kilograms(goalWeight)) kg", style: .rowTitle)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenWeight(trend, goalWeight: goalWeight))
        .accessibilityIdentifier("food-weight-average")
        LooprText(trendLine(trend), style: .caption, color: .inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("food-weight-trend-line")
        if let progress, let fraction = progress.fraction, let done = progress.doneKg, let plan = progress.plan, let goal = plan.goalWeightKg {
            LooprLinearProgress(value: fraction, target: 1, accent: .energy)
                .accessibilityHidden(true)
            let total = abs(goal - plan.startWeightKg)
            LooprText("\(FoodGoalProgress.kilograms(done)) of \(FoodGoalProgress.kilograms(total)) kg \(progress.goal == .lose ? "lost" : "gained")",
                      style: .caption, color: .inkSecondary)
        }
        if let progress, let date = progress.expectedDate(from: now, calendar: calendar), let goal = progress.plan?.goalWeightKg {
            LooprText("At this pace you reach \(FoodGoalProgress.kilograms(goal)) kg around \(date.formatted(.dateTime.day().month(.abbreviated))).",
                      style: .caption, color: .inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("food-goal-date")
        } else if let progress, progress.remainingKg.map({ $0 <= 0.05 }) == true {
            LooprText("You have reached your goal weight. Edit your goal to keep it or set a new one.", style: .caption, color: .recoveryHigh)
                .fixedSize(horizontal: false, vertical: true)
        }
        if trend.daily.count >= 2 {
            LooprSparkline(points: trend.daily.map { LooprChartPoint(date: $0.date, value: $0.kilograms) },
                           days: 30, endingOn: now, accent: .energy, height: 48)
                .accessibilityHidden(true)
        }
        if let progress, let suggestion = FoodWeightSuggestion(trend: trend, goal: progress.goal, plan: progress.plan, now: now) {
            suggestionView(suggestion)
        }
    }

    /// The trend against the plan, with its working, and a way to the targets. Loopr never changes them itself
    /// (UX R2-MAC-09).
    private func suggestionView(_ suggestion: FoodWeightSuggestion) -> some View {
        VStack(alignment: .leading, spacing: LooprSpacing.sm) {
            LooprText(suggestion.sentence, style: .body, color: .ink)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: onEdit) { Text("Open goal and targets").frame(maxWidth: .infinity) }
                .buttonStyle(LooprButtonStyle(prominent: false, accent: .energy))
                .accessibilityHint("Your targets change only when you save them there")
                .accessibilityIdentifier("food-weight-suggestion-open")
        }
        .padding(LooprSpacing.sm)
        .background(Color.loopr(.energy).opacity(0.08), in: RoundedRectangle(cornerRadius: LooprRadius.control, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("food-weight-suggestion")
    }

    /// "Trend weight · −0.4 kg a week · last 78.2 kg on 3 Nov". With too few weigh-ins it says how many the trend needs.
    private func trendLine(_ trend: FoodWeightTrend) -> String {
        let latest = trend.latest
        let day = latest.measuredAt.formatted(.dateTime.day().month(.abbreviated))
        if trend.isStale(at: now) { return "No weigh-in in the last 7 days. Last reading on \(day)." }
        guard trend.hasEnoughReadings else {
            return "Weighed \(day). The trend needs \(FoodWeightTrend.minimumDays) weigh-ins in \(FoodWeightTrend.windowDays) days, \(trend.daysNeeded) more."
        }
        var line = "Trend weight"
        if let change = trend.weeklyChange { line += " · \(FoodGoalProgress.signedKilograms(change)) kg a week" }
        line += " · last \(FoodGoalProgress.kilograms(latest.kilograms)) kg on \(day)"
        return line
    }

    private func spokenWeight(_ trend: FoodWeightTrend, goalWeight: Double?) -> String {
        var text = trend.isStale(at: now)
            ? "Weight, last reading \(FoodGoalProgress.kilograms(trend.latest.kilograms)) kilograms"
            : trend.hasEnoughReadings ? "Weight trend \(FoodGoalProgress.kilograms(trend.current)) kilograms"
            : "Weight \(FoodGoalProgress.kilograms(trend.current)) kilograms"
        if let goalWeight { text += ", goal \(FoodGoalProgress.kilograms(goalWeight)) kilograms" }
        return text
    }
}

/// Shown in the hero under the ring until targets are set.
struct FoodPlanPrompt: View {
    let action: () -> Void

    var body: some View {
        // A quiet link, not a second primary: the Camera button leads on a new day (UX R1-NEW-03, R1-DES-19).
        VStack(spacing: LooprSpacing.xxs) {
            Button { action() } label: {
                Label("Set my targets", systemImage: "target")
                    .looprTypography(.label)
                    .foregroundStyle(Color.loopr(.energy))
                    .frame(minHeight: 44)
                    .padding(.horizontal, LooprSpacing.sm)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.looprPressableCard)
            .accessibilityHint("Six questions. Loopr works out calories, protein, carbs and fat with a published formula. Answers stay on this iPhone.")
            .accessibilityIdentifier("food-plan-start")
            LooprText("Six questions, about a minute. Answers stay on this iPhone.", style: .caption, color: .inkSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("food-plan-prompt")
    }
}
