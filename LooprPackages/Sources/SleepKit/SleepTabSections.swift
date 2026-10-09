import SwiftUI
import DesignSystem

// The sections of the Sleep tab, top to bottom. Every number here comes from
// `SleepNightInsights`, which the view model works out once per night.

/// The hero: time asleep as a ring against the night's target, the target in
/// words, bedtime and wake time, and "vs usual".
struct SleepNightHero: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let main: SleepSessionSummary
    let insights: SleepNightInsights?
    let score: SleepMetricValue?
    let open: (() -> Void)?

    private var asleep: Double { Double(main.durationMinutes) }
    private var target: SleepTarget? { insights?.target }

    var body: some View {
        Group {
            if let open {
                Button(action: open) { hero }
                    .buttonStyle(.looprPressableCard)
                    .accessibilityHint("Opens sleep duration history")
                    .accessibilityAddTraits(.isButton)
            } else {
                hero
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier("sleep-metric-duration")
    }

    private var hero: some View {
        LooprRingHero(
            value: asleep,
            scale: target?.ringScale,
            text: LooprUnitFormatter.duration(minutes: asleep) ?? main.durationLabel,
            format: .hoursMinutesSpelled,
            caption: "Asleep",
            accent: .sleep
        ) {
            VStack(spacing: LooprSpacing.xs) {
                if let target {
                    Text(target.line(asleepMinutes: asleep))
                        .looprTypography(.label)
                        .foregroundStyle(Color.loopr(.ink))
                        .multilineTextAlignment(.center)
                }
                if let delta = insights?.durationUsual.delta(for: asleep, higherIsBetter: true, format: .duration) {
                    if case .usual = delta.kind {
                        // A lone "Usual" under the hero reads like a label
                        // for nothing; say what is usual.
                        Text("A usual length for you")
                            .looprTypography(.caption)
                            .foregroundStyle(Color.loopr(.inkSecondary))
                            .accessibilityLabel(delta.spokenText)
                    } else if case .learning = delta.kind, dynamicTypeSize.isAccessibilitySize {
                        Text(delta.text)
                            .looprTypography(.confidence)
                            .foregroundStyle(Color.loopr(.inkSecondary))
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel(delta.spokenText)
                    } else {
                        LooprDeltaCaption(delta, accent: .sleep, style: .confidence)
                    }
                }
                HStack(spacing: LooprSpacing.md) {
                    clockPair("Bedtime", main.start)
                    Rectangle().fill(Color.loopr(.divider)).frame(width: 1, height: 26)
                    clockPair(main.isPartial ? "Latest" : "Woke", main.end)
                    if let score, let value = score.numericValue {
                        Rectangle().fill(Color.loopr(.divider)).frame(width: 1, height: 26)
                        VStack(spacing: 2) {
                            Text("SCORE").looprTypography(.sectionLabel).foregroundStyle(Color.loopr(.inkSecondary))
                            Text("\(Int(value.rounded()))").looprTypography(.metricUnit).fontWeight(.semibold)
                                .foregroundStyle(Color.loopr(.ink))
                        }
                    }
                }
                .padding(.top, LooprSpacing.xxs)
                if main.isPartial {
                    note("This night is still being recorded, so the total may change.")
                } else if let provisional = target?.provisionalNote {
                    note(provisional)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func clockPair(_ title: String, _ date: Date) -> some View {
        VStack(spacing: 2) {
            Text(title.uppercased())
                .looprTypography(.sectionLabel)
                .foregroundStyle(Color.loopr(.inkSecondary))
            Text(date.formatted(date: .omitted, time: .shortened))
                .looprTypography(.metricUnit)
                .fontWeight(.semibold)
                .monospacedDigit()
                .foregroundStyle(Color.loopr(.ink))
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .looprTypography(.caption)
            .foregroundStyle(Color.loopr(.inkSecondary))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 320)
            .padding(.top, LooprSpacing.xxs)
    }

    private var accessibilityLabel: String {
        var parts = ["Asleep \(LooprUnitFormatter.spokenDuration(minutes: asleep) ?? main.durationLabel)"]
        if let target { parts.append(target.spokenLine(asleepMinutes: asleep)) }
        if let delta = insights?.durationUsual.delta(for: asleep, higherIsBetter: true, format: .duration) {
            parts.append(delta.spokenText)
        }
        parts.append("Bedtime \(main.start.formatted(date: .omitted, time: .shortened))")
        parts.append("\(main.isPartial ? "Latest reading" : "Woke") \(main.end.formatted(date: .omitted, time: .shortened))")
        if let value = score?.numericValue { parts.append("Sleep score \(Int(value.rounded()))") }
        if main.isPartial {
            parts.append("This night is still being recorded")
        } else if let provisional = target?.provisionalNote {
            parts.append(provisional)
        }
        return parts.joined(separator: ". ")
    }
}

/// The night's stages: the touchable timeline (with the heart-rate line when
/// there is one) and a row per stage against its usual range. Tapping a row
/// highlights that stage in the timeline, and the other way round.
struct SleepStagesCard: View {
    let snapshot: SleepDaySnapshot
    let main: SleepSessionSummary
    let stages: [SleepStageSummary]
    let heartRate: SleepOvernightHeartRate?
    @Binding var highlighted: SleepStage?

    /// Every stage still learning: the section header says so once.
    private var showsComparison: Bool {
        SleepNightInsights.learningNote(stages.map(\.usual)) == nil
    }

    var body: some View {
        LooprSurface {
            VStack(alignment: .leading, spacing: LooprSpacing.md) {
                if !snapshot.hypnogram.isEmpty {
                    LooprStageTimeline(
                        segments: snapshot.hypnogram,
                        start: main.start,
                        highlightedStage: $highlighted,
                        identifier: "sleep-stage-timeline",
                        line: heartRate?.line,
                        stageTotals: Dictionary(stages.map { ($0.stage, $0.minutes) }, uniquingKeysWith: { first, _ in first })
                    )
                }
                if !stages.isEmpty {
                    if !snapshot.hypnogram.isEmpty {
                        Rectangle().fill(Color.loopr(.divider)).frame(height: 1).accessibilityHidden(true)
                    }
                    VStack(spacing: LooprSpacing.xxs) {
                        ForEach(stages) { summary in
                            SleepStageRow(summary: summary, showsComparison: showsComparison, highlighted: $highlighted)
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sleep-stages-card")
    }
}

struct SleepStageRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let summary: SleepStageSummary
    var showsComparison = true
    @Binding var highlighted: SleepStage?

    private var isHighlighted: Bool { highlighted == summary.stage }
    private var isDimmed: Bool { highlighted != nil && !isHighlighted }

    var body: some View {
        Button {
            withAnimation(reduceMotion ? nil : .snappy(duration: LooprMotion.fast)) {
                highlighted = isHighlighted ? nil : summary.stage
            }
        } label: {
            VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.xs) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.loopr(summary.stage.token))
                        .frame(width: 10, height: 10)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                    Text(summary.stage.title)
                        .looprTypography(.rowTitle)
                        .foregroundStyle(Color.loopr(.ink))
                    Spacer(minLength: LooprSpacing.xs)
                    if !dynamicTypeSize.isAccessibilitySize { numbers }
                }
                if dynamicTypeSize.isAccessibilitySize {
                    HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.xs) { numbers }
                        .padding(.leading, 18)
                }
                if showsComparison {
                    comparison
                }
            }
            .padding(.vertical, LooprSpacing.xs)
            .padding(.horizontal, LooprSpacing.xs)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.loopr(summary.stage.token).opacity(isHighlighted ? 0.12 : 0))
            )
            .opacity(isDimmed ? 0.5 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.looprPressableRow)
        .padding(.horizontal, -LooprSpacing.xs)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summary.accessibilitySummary)
        .accessibilityHint(isHighlighted ? "Clears the highlight" : "Highlights this stage in the timeline")
        .accessibilityAddTraits(isHighlighted ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("sleep-stage-\(summary.stage.rawValue)")
    }

    @ViewBuilder
    private var numbers: some View {
        Text(LooprUnitFormatter.duration(minutes: summary.minutes) ?? "")
            .looprTypography(.metricUnit)
            .fontWeight(.semibold)
            .monospacedDigit()
            .foregroundStyle(Color.loopr(.ink))
        Text(summary.shareText)
            .looprTypography(.confidence)
            .monospacedDigit()
            .foregroundStyle(Color.loopr(.inkSecondary))
            .frame(minWidth: summary.stage == .awake ? nil : 34, alignment: .trailing)
    }

    @ViewBuilder
    private var comparison: some View {
        switch summary.usual {
        case .range(let range):
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: LooprSpacing.xxs))
                : AnyLayout(HStackLayout(alignment: .center, spacing: LooprSpacing.sm))
            layout {
                LooprTypicalRangeBar(value: summary.minutes, typical: range.lower...range.upper, accent: summary.stage.token)
                    .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : 150)
                    .padding(.leading, dynamicTypeSize.isAccessibilitySize ? 0 : 18)
                if let delta = summary.delta {
                    if case .usual = delta.kind, let usualText = summary.usualText {
                        Text(usualText)
                            .looprTypography(.confidence)
                            .monospacedDigit()
                            .foregroundStyle(Color.loopr(.inkSecondary))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    } else {
                        LooprDeltaCaption(delta, accent: .sleep, style: .confidence)
                    }
                }
                if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }
            }
        case .learning(let measured, let needed):
            Text("Learning your usual · " + LooprLearningText.progress(have: measured, need: needed))
                .looprTypography(.caption)
                .foregroundStyle(Color.loopr(.inkSecondary))
                .padding(.leading, dynamicTypeSize.isAccessibilitySize ? 0 : 18)
        }
    }
}

/// Fourteen nights of slept minus target, the net and one thing to do.
struct SleepDebtCard: View {
    let ledger: SleepDebtLedger
    let target: SleepTarget

    private var isTotal: Bool {
        switch ledger.suggestion {
        case .ahead, .behind: true
        case .even, .needsNights: false
        }
    }

    var body: some View {
        LooprSurface {
            VStack(alignment: .leading, spacing: LooprSpacing.md) {
                VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                    Text(ledger.headline)
                        // A running total reads as a number; "Even" or a
                        // night count reads as words.
                        .looprTypography(isTotal ? .metricCompact : .title)
                        .foregroundStyle(Color.loopr(.ink))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text("Over the last 14 nights, against \(target.durationText) a night")
                        .looprTypography(.caption)
                        .foregroundStyle(Color.loopr(.inkSecondary))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                LooprDivergingBars(
                    bars: ledger.bars,
                    title: "Sleep against target",
                    positiveAccent: .sleep,
                    valueFormat: { LooprUnitFormatter.signedDuration(minutes: $0) ?? "" },
                    axisFormat: { LooprUnitFormatter.signedDuration(minutes: $0) ?? "" },
                    minimumSpan: 60,
                    height: 132,
                    identifier: "sleep-debt-chart"
                )
                Text(ledger.actionLine)
                    .looprTypography(.prose)
                    .foregroundStyle(Color.loopr(.ink))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("sleep-debt-action")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sleep-debt-card")
    }
}

/// Bedtime and wake time over 14 nights, with the regularity score when the
/// derivation has one.
struct SleepTimingCard: View {
    @Environment(\.looprMetricLink) private var metricLink
    let consistency: SleepConsistency
    let regularity: SleepMetricValue?

    var body: some View {
        LooprSurface {
            VStack(alignment: .leading, spacing: LooprSpacing.md) {
                if let summary = consistency.summary {
                    Text(summary)
                        .looprTypography(.prose)
                        .foregroundStyle(Color.loopr(.ink))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if consistency.measured.count >= 2 {
                    SleepTimingChart(consistency: consistency)
                }
                if let shift = consistency.shiftLine {
                    Text(shift)
                        .looprTypography(.caption)
                        .foregroundStyle(Color.loopr(.inkSecondary))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let regularity, let value = regularity.numericValue, regularity.state != .absent {
                    regularityRow(value)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sleep-timing-card")
    }

    @ViewBuilder
    private func regularityRow(_ value: Double) -> some View {
        let content = HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.xs) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Regularity")
                    .looprTypography(.rowTitle)
                    .foregroundStyle(Color.loopr(.ink))
                Text("How closely your sleep lines up from one day to the next, out of 100")
                    .looprTypography(.caption)
                    .foregroundStyle(Color.loopr(.inkSecondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: LooprSpacing.xs)
            Text("\(Int(value.rounded()))")
                .looprTypography(.metricCompact)
                .foregroundStyle(Color.loopr(.ink))
            if openRegularity != nil { LooprChevron() }
        }
        .padding(.top, LooprSpacing.xs)
        .overlay(alignment: .top) { Rectangle().fill(Color.loopr(.divider)).frame(height: 1) }
        if let open = openRegularity {
            Button(action: open) { content.contentShape(Rectangle()) }
                .buttonStyle(.looprPressableRow)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Regularity, \(Int(value.rounded())) out of 100")
                .accessibilityHint("Opens history and explanation")
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("sleep-metric-regularity")
        } else {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Regularity, \(Int(value.rounded())) out of 100")
                .accessibilityIdentifier("sleep-metric-regularity")
        }
    }

    private var openRegularity: (() -> Void)? {
        guard let metricLink, metricLink.supports(LooprMetricLinkID.sleepConsistency) else { return nil }
        return { metricLink.open(LooprMetricLinkID.sleepConsistency) }
    }
}

/// The remaining numbers, each against its usual range.
struct SleepDetailRows: View {
    @Environment(\.looprMetricLink) private var metricLink
    let rows: [SleepDetailRow]

    var body: some View {
        // With every row still learning, the section header says it once.
        let showsDelta = SleepNightInsights.learningNote(rows.compactMap(\.usual)) == nil
        return LooprContributorList(rows.map { row in
            LooprContributorRow(
                title: row.title,
                value: row.valueText,
                unit: row.unit,
                delta: showsDelta ? row.delta : nil,
                range: row.usual?.range.flatMap { LooprContributorRange(value: row.value, band: $0.band) },
                accent: .sleep,
                identifier: "sleep-metric-\(row.id)",
                action: open(row)
            )
        })
    }

    private func open(_ row: SleepDetailRow) -> (() -> Void)? {
        guard let id = row.metricLinkID, let metricLink, metricLink.supports(id) else { return nil }
        return { metricLink.open(id) }
    }
}

/// Tonight: a bedtime to aim for, then the wake alarm card.
struct SleepTonightCard: View {
    let plan: SleepTonightPlan

    var body: some View {
        LooprSurface {
            HStack(alignment: .top, spacing: LooprSpacing.sm) {
                Image(systemName: "bed.double")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Color.loopr(LooprColorToken.sleep.textInk))
                    .frame(width: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                    Text(plan.headline)
                        .looprTypography(.cardTitle)
                        .foregroundStyle(Color.loopr(.ink))
                    Text(plan.detail)
                        .looprTypography(.prose)
                        .foregroundStyle(Color.loopr(.inkSecondary))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("sleep-tonight-bedtime")
    }
}
