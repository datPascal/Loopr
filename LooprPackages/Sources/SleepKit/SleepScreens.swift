import SwiftUI
import DesignSystem

public enum SleepRoute: Hashable, Sendable, CaseIterable {
    case day
    case hypnogram
    case trends
    case suggestedAlarm
    case corrections
    case coach
}

public struct SleepScreen: View {
    /// The shared day, when the app provides one. The header then names that
    /// day's night and carries the day navigator.
    @Environment(\.looprDayNavigation) private var dayNavigation
    @Environment(\.looprMetricLink) private var metricLink
    @Environment(\.bandPaired) private var bandPaired
    @ObservedObject private var viewModel: SleepViewModel
    /// The stage lit up in the timeline, shared with the stage rows.
    @State private var highlightedStage: SleepStage?
    /// The night, or one of the trend ranges, picked at the top of the page (Data ICP R1: one Sleep page).
    @State private var scope: SleepPageScope = .night
    /// Days of sleep history behind the range pills, so 6M and longer wait for that much history (Data ICP R4-SW-01).
    @State private var historyDays: Int?
    private let route: (SleepRoute) -> Void
    /// A card the app places under the night's numbers, such as the wake
    /// alarm. When present it replaces the suggested alarm row, because the
    /// card already offers the suggestion.
    private let accessory: AnyView?
    private let tonightAccessory: AnyView?
    /// The "What was different" card the app places between Stages and Tonight. SleepKit does not know what it
    /// reads, it only gives it a spot. The app passes nil, or a view that draws nothing, when there is no comparison.
    private let differenceAccessory: AnyView?
    private let showsNightDetails: Bool
    /// The page's last row, such as Data's "How sleep is worked out" (Data ICP R3-VET).
    private let footer: AnyView?

    public init(viewModel: SleepViewModel, route: @escaping (SleepRoute) -> Void = { _ in }, accessory: AnyView? = nil,
                tonightAccessory: AnyView? = nil, differenceAccessory: AnyView? = nil, showsNightDetails: Bool = false,
                footer: AnyView? = nil) {
        self.viewModel = viewModel
        self.route = route
        self.accessory = accessory
        self.tonightAccessory = tonightAccessory
        self.differenceAccessory = differenceAccessory
        self.showsNightDetails = showsNightDetails
        self.footer = footer
    }

    public var body: some View {
        LooprTabScaffold(header: header, glow: .sleep, identifier: "sleep-screen") {
            LooprPhaseContainer(phase: phase) {
                VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                    phaseContent
                }
            }
        }
        .navigationTitle("Sleep")
    }

    /// Days from the first recorded night to this one, from the stored history and the snapshot's own nights.
    static func historyDays(_ snapshot: SleepDaySnapshot, history: [LooprChartPoint]) -> Int {
        let end = SleepCivilDay(snapshot.day)?.noon(in: .current) ?? Date()
        return LooprChartRange.historyDays(SleepTrendsScreen.trendPoints(snapshot.trend, key: nil) + history, endingOn: end)
    }

    private func loadHistoryDays(_ snapshot: SleepDaySnapshot) async {
        var history: [LooprChartPoint] = []
        if let metricLink, metricLink.supports(LooprMetricLinkID.sleepDuration) {
            history = await metricLink.history(LooprMetricLinkID.sleepDuration, LooprChartRange.longestDayCount)
        }
        guard !Task.isCancelled else { return }
        let days = Self.historyDays(snapshot, history: history)
        historyDays = days
        if case .range(let range) = scope, SleepPageScope.locked(historyDays: days).contains(.range(range)) {
            scope = .range(LooprChartRange.resolved(range, available: LooprChartRange.unlocked(historyDays: days)))
        }
    }

    private var phase: LooprLoadPhase {
        if dayNavigation?.isResolving == true { return .loading }
        switch viewModel.loadState {
        case .idle: return dayNavigation != nil ? .loading : .empty
        case .loading: return .loading
        case .failed: return .failed
        case .loaded:
            if dayNavigation?.status == .noData || viewModel.snapshot == nil { return .empty }
            return .content
        }
    }

    @ViewBuilder
    private var phaseContent: some View {
        switch phase {
        case .loading:
            LooprLoadingPlaceholder(.heroCard(cards: 2))
        case .empty:
            if let dayNavigation, viewModel.loadState == .loaded, dayNavigation.status == .noData {
                // A night with nothing recorded reads as one plain card, not
                // a list of empty rows.
                LooprDayEmptyState(dayNavigation, accent: .sleep, todayCopy: Self.emptyTodayCopy(bandPaired: bandPaired))
                    .padding(.horizontal, LooprSpacing.screenGutter)
                    .padding(.top, LooprSpacing.lg)
                accessoryCard
            } else {
                LooprCard { StateMessage(.noRecords, accent: .sleep) }
                    .padding(.horizontal, LooprSpacing.screenGutter)
                    .padding(.top, LooprSpacing.lg)
                if viewModel.loadState == .loaded { accessoryCard }
            }
        case .failed:
            LooprCard { StateMessage(.recoverableError) }
                .padding(.horizontal, LooprSpacing.screenGutter)
                .padding(.top, LooprSpacing.lg)
        case .content:
            if let snapshot = viewModel.snapshot {
                content(snapshot)
            }
        }
    }

    @ViewBuilder
    private var accessoryCard: some View {
        if let accessory {
            accessory
                .padding(.horizontal, LooprSpacing.screenGutter)
        }
    }

    @ViewBuilder
    private func content(_ snapshot: SleepDaySnapshot) -> some View {
        // Which night this is, with arrows to the nights before (Data ICP R2-SW-01, R2-DES-03). A main sleep that
        // starts in the morning is named a day sleep, for shift workers.
        if showsNightDetails, scope == .night, let dayNavigation {
            LooprDayNavigator(dayNavigation, style: .bar(title: dayNavigation.nightTitle,
                                                         subtitle: snapshot.mainSleep.map(Self.sleepSpan)), accent: .sleep)
                .padding(.horizontal, LooprSpacing.screenGutter)
                .padding(.top, LooprSpacing.xs)
                .accessibilityIdentifier("sleep-night-navigator")
        }
        if showsNightDetails, snapshot.mainSleep != nil, !snapshot.trend.isEmpty {
            LooprPillPicker(selection: $scope, options: SleepPageScope.options, accent: .sleep, identifier: "sleep-scope",
                            locked: SleepPageScope.locked(historyDays: historyDays ?? Self.historyDays(snapshot, history: [])))
                .padding(.horizontal, LooprSpacing.screenGutter)
                .padding(.top, LooprSpacing.xs)
                .task(id: snapshot.day) { await loadHistoryDays(snapshot) }
        }
        if case .range(let range) = scope, showsNightDetails {
            VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                SleepTrendsContent(snapshot: snapshot, range: Binding(get: { range }, set: { scope = .range($0) }),
                                   insights: viewModel.insights)
            }
            .padding(.horizontal, LooprSpacing.screenGutter)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("sleep-trends-screen")
        } else {
            nightPage(snapshot)
        }
        if showsNightDetails, let footer {
            footer
                .padding(.horizontal, LooprSpacing.screenGutter)
                .padding(.top, LooprSpacing.md)
        }
    }

    @ViewBuilder
    private func nightPage(_ snapshot: SleepDaySnapshot) -> some View {
        if let main = snapshot.mainSleep {
            nightContent(snapshot, main: main)
        } else {
            LooprCard { StateMessage(snapshot.state) }
                .padding(.horizontal, LooprSpacing.screenGutter)
                .padding(.top, LooprSpacing.lg)
        }

        // The derivation finds daytime naps and they were never shown, so a
        // two-hour afternoon sleep looked like nothing happened.
        if showsNightDetails, !snapshot.naps.isEmpty {
            SleepNapList(naps: snapshot.naps)
                .padding(.horizontal, LooprSpacing.screenGutter)
                .padding(.top, LooprSpacing.md)
        }

        if !showsNightDetails, let differenceAccessory, snapshot.mainSleep != nil {
            differenceAccessory
                .padding(.horizontal, LooprSpacing.screenGutter)
                .padding(.top, LooprSpacing.md)
        }

        tonightSection

        if showsNightDetails {
            SleepHairlineList(navigationItems(for: snapshot)) { item in
                SleepNavigationRow(item: item)
            }
            .padding(.horizontal, LooprSpacing.screenGutter)
            .padding(.top, LooprSpacing.md)
        }
    }

    /// Hero, stages, debt, timing and the remaining numbers for a night with
    /// a main sleep.
    @ViewBuilder
    private func nightContent(_ snapshot: SleepDaySnapshot, main: SleepSessionSummary) -> some View {
        let insights = viewModel.insights
        SleepNightHero(main: main, insights: insights, score: snapshot.metric("score"),
                       open: openMetric(LooprMetricLinkID.sleepDuration), compact: showsNightDetails)
            .padding(.top, LooprSpacing.xs)


        if let insights {
            if !snapshot.hypnogram.isEmpty || !insights.stages.isEmpty {
                section("Stages", detail: showsNightDetails ? Self.stagesDetail(insights) : SleepNightInsights.learningNote(insights.stages.map(\.usual))
                        ?? (insights.stages.contains { $0.usual.range != nil } ? "Usual is the middle half of your nights in the last month" : nil)) {
                    if showsNightDetails {
                        SleepStagesCard(snapshot: snapshot, main: main, stages: insights.stages,
                                        heartRate: viewModel.heartRate, highlighted: $highlightedStage)
                    } else {
                        Button { route(.day) } label: {
                            LooprCard {
                                LooprStageTimeline(segments: snapshot.hypnogram, start: main.start,
                                    identifier: "sleep-stage-timeline", showsReadout: false)
                                    .allowsHitTesting(false)
                            }
                        }
                        .buttonStyle(.looprPressableCard)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Sleep stages")
                        .accessibilityHint("Opens stage totals, overnight heart rate and night details")
                        .accessibilityIdentifier("sleep-stages-card")
                    }
                }
            }
            // What was different follows the stages: the stages are why people open the night (Data ICP R2-SW-02).
            if showsNightDetails, let differenceAccessory {
                differenceAccessory
                    .padding(.horizontal, LooprSpacing.screenGutter)
                    .padding(.top, LooprSpacing.md)
            }
            // Debt and bedtime cover many nights, so with the range picker they live under 7D to 1Y, not on one night
            // (Data ICP R2-DES-02).
            if showsNightDetails, !hasRangePicker(snapshot), insights.ledger.measuredNights > 0 {
                section(insights.target.sectionTitle) {
                    SleepDebtCard(ledger: insights.ledger, target: insights.target)
                }
            }
            if showsNightDetails, !hasRangePicker(snapshot), !insights.consistency.measured.isEmpty {
                section("Bedtime and wake time") {
                    SleepTimingCard(consistency: insights.consistency, regularity: snapshot.metric("regularity"))
                }
            }
            if showsNightDetails, !insights.rows.isEmpty {
                section("Night details", detail: SleepNightInsights.learningNote(insights.rows.compactMap(\.usual))) {
                    SleepDetailRows(rows: insights.rows)
                }
            }
        }
    }

    private func section<Content: View>(_ title: String, detail: String? = nil,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprSectionHeader(title, detail: detail, accent: .sleep)
            content()
        }
        .padding(.horizontal, LooprSpacing.screenGutter)
        .padding(.top, LooprSpacing.md)
    }

    /// Tonight: a bedtime to aim for and the wake alarm card, for the night
    /// that is still ahead. A past night gets neither.
    @ViewBuilder
    private var tonightSection: some View {
        if showsTonight {
            let plan = viewModel.insights?.tonight
            if plan != nil || accessory != nil {
                VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                    LooprSectionHeader("Tonight", accent: .sleep)
                        .padding(.horizontal, LooprSpacing.screenGutter)
                    if !showsNightDetails, let tonightAccessory {
                        LooprCard {
                            VStack(spacing: 0) {
                                if let plan {
                                    Button { route(.day) } label: {
                                        LooprRow(title: "Bedtime", subtitle: "For \(LooprUnitFormatter.duration(minutes: plan.sleepMinutes) ?? "") of sleep", symbol: nil) {
                                            HStack(spacing: LooprSpacing.sm) {
                                                LooprValueText(plan.bedtimeText)
                                                LooprChevron()
                                            }
                                        }
                                    }
                                    .buttonStyle(.looprPressableRow)
                                    .accessibilityIdentifier("sleep-tonight-bedtime")
                                    LooprHairline()
                                }
                                tonightAccessory
                            }
                        }
                        .padding(.horizontal, LooprSpacing.screenGutter)
                    } else {
                      if let plan {
                        SleepTonightCard(plan: plan)
                            .padding(.horizontal, LooprSpacing.screenGutter)
                      }
                      accessoryCard
                    }
                }
                .padding(.top, LooprSpacing.md)
            }
        }
    }

    /// Today, or the latest night with data when today has none yet.
    private var showsTonight: Bool {
        guard let dayNavigation else { return true }
        return dayNavigation.isToday || dayNavigation.day == dayNavigation.latestDayWithData
    }

    private func openMetric(_ id: String) -> (() -> Void)? {
        guard let metricLink, metricLink.supports(id) else { return nil }
        return { metricLink.open(id) }
    }

    private func navigationItems(for snapshot: SleepDaySnapshot) -> [SleepNavigationItem] {
        var items: [SleepNavigationItem] = []

        // The page's own range picker shows the trends; the row stays only where there is no picker.
        if !snapshot.trend.isEmpty, snapshot.mainSleep == nil {
            items.append(trendsItem)
        }

        if !snapshot.hypnogram.isEmpty {
            items.append(hypnogramItem)
        }

        if accessory == nil, let suggestion = snapshot.suggestedAlarm {
            items.append(suggestedAlarmItem(suggestion))
        }

        // The audit trail is only worth a row once something has been
        // corrected. An always-visible "0 audit entries" told nobody anything.
        if !viewModel.corrections.isEmpty {
            items.append(correctionsItem)
        }

        // The coach is the Ask button in the header, so the page no longer repeats it as a row (Data ICP R1-DES-24).
        return items
    }

    private var hypnogramItem: SleepNavigationItem {
        SleepNavigationItem(
            id: "sleep-hypnogram-route",
            title: "Stage changes",
            detail: "Every change of stage with its clock time",
            accessibilityLabel: "Stage changes, every change of stage with its clock time",
            action: { route(.hypnogram) }
        )
    }

    private var trendsItem: SleepNavigationItem {
        SleepNavigationItem(
            id: "sleep-trends-route",
            title: "Sleep trends",
            detail: "Sleep, stages and timing over weeks and months",
            accessibilityLabel: "Sleep trends, sleep, stages and timing over weeks and months",
            action: { route(.trends) }
        )
    }

    private func suggestedAlarmItem(_ suggestion: SleepSuggestedAlarm) -> SleepNavigationItem {
        SleepNavigationItem(
            id: "sleep-suggested-alarm",
            title: "Suggested alarm \(suggestion.localTime)",
            detail: "Review and confirm before anything changes",
            accessibilityLabel: "Suggested alarm \(suggestion.localTime), "
                + "review and confirm before anything changes",
            action: { route(.suggestedAlarm) }
        )
    }

    private var correctionsItem: SleepNavigationItem {
        let count = viewModel.corrections.count
        let detail = count == 1 ? "1 change to this night" : "\(count) changes to this night"
        return SleepNavigationItem(
            id: "sleep-corrections-route",
            title: "Corrections",
            detail: detail,
            accessibilityLabel: "Corrections, \(detail)",
            action: { route(.corrections) }
        )
    }

    private func coachItem(_ coach: SleepCoachLink) -> SleepNavigationItem {
        SleepNavigationItem(
            id: "sleep-coach-route",
            title: coach.title,
            detail: coach.detail,
            accessibilityLabel: "\(coach.title), \(coach.detail)",
            action: { route(.coach) }
        )
    }

    private func hasRangePicker(_ snapshot: SleepDaySnapshot) -> Bool {
        showsNightDetails && snapshot.mainSleep != nil && !snapshot.trend.isEmpty
    }

    /// "10:30 PM to 6:58 AM", or "Day sleep, 8:10 AM to 3:40 PM" when the main sleep starts between 6 AM and 4 PM.
    nonisolated static func sleepSpan(_ main: SleepSessionSummary) -> String {
        let span = "\(main.start.formatted(date: .omitted, time: .shortened)) to \(main.end.formatted(date: .omitted, time: .shortened))"
        let hour = Calendar.current.component(.hour, from: main.start)
        return (6..<16).contains(hour) ? "Day sleep, \(span)" : span
    }

    /// The stages section says what kind of number it is: an estimate from a wrist band (Data ICP R2-VET-04).
    nonisolated static func stagesDetail(_ insights: SleepNightInsights) -> String {
        let usual = SleepNightInsights.learningNote(insights.stages.map(\.usual))
            ?? (insights.stages.contains { $0.usual.range != nil } ? "Usual is the middle half of your nights in the last month." : nil)
        return ["Estimated from your band, not a sleep study.", usual].compactMap { $0 }.joined(separator: " ")
    }

    /// Sleep's own words for a today with no night, instead of the shared "Log a meal" card (Data ICP R1-NEW-04).
    nonisolated static func emptyTodayCopy(bandPaired: Bool) -> (title: String, detail: String) {
        bandPaired
            ? ("No sleep recorded yet", "Wear your band tonight and open Loopr after you wake up. Your night shows here.")
            : ("No sleep recorded yet", "Pair a band and wear it tonight. Your first night shows here in the morning.")
    }

    private var header: LooprTabHeaderContent {
        LooprTabHeaderContent(
            title: "Sleep",
            accent: .sleep,
            dayPhrase: dayNavigation.map(LooprHeaderMeta.nightPhrase) ?? headerMeta,
            freshness: .sync(lastSync: dayNavigation?.lastSyncedAt, now: dayNavigation?.now),
            status: headerStatus,
            control: dayNavigation.map { .day($0) } ?? .none
        )
    }

    private var headerMeta: String {
        viewModel.snapshot.map { SleepDateFormatting.nightMeta(for: $0) } ?? "Last night"
    }

    /// A chip only when there is something to do about it.
    private var headerStatus: StatusChip? {
        LooprHeaderStatus.chip(for: headerState, isToday: dayNavigation?.isToday ?? true,
                                 dayIsEmpty: dayNavigation?.status == .noData, accent: .sleep)
    }

    private var headerState: MetricState {
        switch viewModel.loadState {
        case .idle: .noRecords
        case .loading: .loading
        case .failed: .recoverableError
        case .loaded: viewModel.snapshot?.state ?? .noRecords
        }
    }
}

public struct SleepHypnogramScreen: View {
    public let snapshot: SleepDaySnapshot
    private let heartRate: SleepOvernightHeartRate?
    /// The same stage minutes the tab shows.
    private let stages: [SleepStageSummary]
    @State private var highlighted: SleepStage?
    /// Keeps the stage names in one column whatever the clock times' widths.
    @ScaledMetric(relativeTo: .caption) private var timeColumnWidth: CGFloat = 132

    public init(snapshot: SleepDaySnapshot, heartRate: SleepOvernightHeartRate? = nil) {
        self.snapshot = snapshot
        self.heartRate = heartRate
        stages = SleepNightInsights.stages(snapshot: snapshot, history: SleepNightHistory(trend: [], day: snapshot.day))
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                if snapshot.hypnogram.isEmpty {
                    LooprSurface {
                        StateMessage(snapshot.state, accent: .sleep)
                    }
                } else {
                    LooprSurface {
                        VStack(alignment: .leading, spacing: LooprSpacing.lg) {
                            summary
                            if let mainSleep = snapshot.mainSleep {
                                LooprStageTimeline(segments: snapshot.hypnogram, start: mainSleep.start,
                                                   highlightedStage: $highlighted,
                                                   identifier: "sleep-hypnogram-timeline", line: heartRate?.line,
                                                   stageTotals: Dictionary(stages.map { ($0.stage, $0.minutes) },
                                                                           uniquingKeysWith: { first, _ in first }))
                            } else {
                                Hypnogram(segments: snapshot.hypnogram)
                            }
                        }
                    }

                    if !stages.isEmpty {
                        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                            LooprSectionHeader("Time by stage", accent: .sleep)
                            SleepHairlineList(stages) { summary in
                                stageRow(summary)
                            }
                        }
                        .padding(.top, LooprSpacing.sm)
                    }

                    if !spans.isEmpty {
                        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                            LooprSectionHeader("Every stretch", detail: "\(spans.count) stretches, in order", accent: .sleep)
                            SleepHairlineList(spans) { span in
                                spanRow(span)
                            }
                        }
                        .padding(.top, LooprSpacing.sm)
                    }
                }
            }
            .padding(LooprSpacing.screenGutter)
            .padding(.bottom, LooprSpacing.tabBarClearance)
        }
        .background(Color.loopr(.background).ignoresSafeArea())
        .navigationTitle("Sleep stages")
        .toolbarTitleDisplayMode(.inlineLarge)
        .accessibilityIdentifier("sleep-hypnogram-screen")
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
            LooprText("TIME IN BED", style: .sectionLabel, color: .inkSecondary)
            LooprValueText(recordedDuration, valueStyle: .metricCompact)
            if let mainSleep = snapshot.mainSleep {
                LooprText("\(LooprUnitFormatter.duration(minutes: Double(mainSleep.durationMinutes)) ?? mainSleep.durationLabel) asleep, "
                          + "\(clock(mainSleep.start)) to \(clock(mainSleep.end))", style: .prose, color: .inkSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var spans: [LooprStageSpan] {
        guard let start = snapshot.mainSleep?.start else { return [] }
        return LooprStageSpan.spans(from: snapshot.hypnogram, start: start)
    }

    private func spanRow(_ span: LooprStageSpan) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.sm) {
            Text("\(clock(span.start)) to \(clock(span.end))")
                .looprTypography(.metricUnit)
                .monospacedDigit()
                .foregroundStyle(Color.loopr(.inkSecondary))
                .lineLimit(1)
                .frame(minWidth: timeColumnWidth, alignment: .leading)
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Color.loopr(span.stage.token))
                .frame(width: 8, height: 8)
            Text(span.stage.title)
                .looprTypography(.rowTitle)
                .foregroundStyle(Color.loopr(.ink))
            Spacer(minLength: LooprSpacing.xs)
            Text(LooprUnitFormatter.duration(minutes: span.minutes) ?? "")
                .looprTypography(.metricUnit)
                .monospacedDigit()
                .foregroundStyle(Color.loopr(.ink))
        }
        .padding(.vertical, 11)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(span.stage.title) from \(clock(span.start)) to \(clock(span.end)), "
                            + (LooprUnitFormatter.spokenDuration(minutes: span.minutes) ?? ""))
    }

    private var recordedDuration: String {
        LooprUnitFormatter.duration(minutes: Double(recordedMinutes)) ?? "0 min"
    }

    private var recordedMinutes: Int {
        snapshot.hypnogram.reduce(0) { $0 + max($1.durationMinutes, 0) }
    }

    private func stageRow(_ summary: SleepStageSummary) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.xs) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Color.loopr(summary.stage.token))
                .frame(width: 10, height: 10)
            Text(summary.stage.title)
                .looprTypography(.rowTitle)
                .foregroundStyle(Color.loopr(.ink))
            Spacer(minLength: LooprSpacing.xs)
            Text(LooprUnitFormatter.duration(minutes: summary.minutes) ?? "")
                .looprTypography(.metricUnit)
                .fontWeight(.semibold)
                .monospacedDigit()
                .foregroundStyle(Color.loopr(.ink))
            Text(summary.stage == .awake ? "\(summary.percent)% of the night" : "\(summary.percent)% of sleep")
                .looprTypography(.caption)
                .foregroundStyle(Color.loopr(.inkSecondary))
        }
        .padding(.vertical, 13)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(summary.stage.title), \(LooprUnitFormatter.spokenDuration(minutes: summary.minutes) ?? ""), \(summary.percent) percent")
        .accessibilityIdentifier("sleep-stage-\(summary.stage.rawValue)")
    }

    private func clock(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}

public struct SleepTrendsScreen: View {
    public let snapshot: SleepDaySnapshot
    @State private var range: LooprChartRange

    public init(snapshot: SleepDaySnapshot) {
        self.snapshot = snapshot
        // With a week or less of nights, a 30-day chart is mostly empty.
        let nights = snapshot.trend.filter { $0.value != nil }.count
        _range = State(initialValue: nights <= 7 ? .week : .month)
    }

    /// The charts, in order. Each reads a year of the metric's daily history
    /// and falls back to the nights folded into the snapshot.
    static let charts: [(id: String, title: String, trendKey: String?, kind: LooprChartKind, step: Double)] = [
        (LooprMetricLinkID.sleepDuration, "Time asleep", nil, .bars, 120),
        (LooprMetricLinkID.deepSleep, "Deep sleep", "deep", .bars, 30),
        (LooprMetricLinkID.remSleep, "REM sleep", "rem", .bars, 30),
        (LooprMetricLinkID.sleepEfficiency, "Efficiency", "efficiency", .line, 5)
    ]

    public var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: LooprSpacing.sm) {
                LooprRangePicker(selection: $range, accent: .sleep, identifier: "sleep-trends-range")
                SleepTrendsContent(snapshot: snapshot, range: $range)
            }
            .padding(LooprSpacing.screenGutter)
            .padding(.bottom, LooprSpacing.tabBarClearance)
        }
        .background(Color.loopr(.background).ignoresSafeArea())
        .navigationTitle("Sleep trends")
        .toolbarTitleDisplayMode(.inlineLarge)
        .accessibilityIdentifier("sleep-trends-screen")
    }

    static let percentText: @Sendable (Double) -> String = { "\(Int($0.rounded()))" }
    static let durationText: @Sendable (Double) -> String = { LooprUnitFormatter.duration(minutes: $0) ?? "" }
    /// Axis labels for minutes: "30 min" under two hours, "6 h" above.
    static let minuteAxisText: @Sendable (Double) -> String = { value in
        value.rounded() == 0 ? "0" : value < 120 ? "\(Int(value.rounded())) min" : "\(Int((value / 60).rounded())) h"
    }

    /// The metric history up to the selected night, with the snapshot's own
    /// nights filling any day the history lacks. History wins on a day both
    /// have, since it is what the metric pages show.
    static func merged(history: [LooprChartPoint], trend: [LooprChartPoint], endingOn: Date,
                       calendar: Calendar = .current) -> [LooprChartPoint] {
        let last = calendar.startOfDay(for: endingOn)
        var byDay: [Date: LooprChartPoint] = [:]
        for point in trend where calendar.startOfDay(for: point.date) <= last {
            byDay[calendar.startOfDay(for: point.date)] = point
        }
        for point in history where calendar.startOfDay(for: point.date) <= last {
            byDay[calendar.startOfDay(for: point.date)] = point
        }
        return byDay.values.sorted { $0.date < $1.date }
    }

    /// Chart points from the snapshot's own nights: minutes asleep, or one
    /// of the per-night values.
    static func trendPoints(_ trend: [SleepTrendPoint], key: String?, calendar: Calendar = .current) -> [LooprChartPoint] {
        trend.compactMap { point in
            guard let day = SleepCivilDay(label: point.localDay), let date = day.noon(in: calendar) else { return nil }
            let value: Double? = key.map { point.values[$0] } ?? point.value.map { $0 * 60 }
            return value.map { LooprChartPoint(date: calendar.startOfDay(for: date), value: $0) }
        }
        .sorted { $0.date < $1.date }
    }

}

/// Sleep's trend charts for one range: time asleep, deep, REM and efficiency, then bedtime and wake time. The Sleep
/// page shows them under its range picker and the older Sleep trends screen wraps them (Data ICP R1: one Sleep page).
public struct SleepTrendsContent: View {
    @Environment(\.looprMetricLink) private var metricLink
    public let snapshot: SleepDaySnapshot
    private let insights: SleepNightInsights?
    @Binding private var range: LooprChartRange
    @State private var loaded: [String: [LooprChartPoint]] = [:]
    @State private var showsMore = false

    /// - Parameter insights: the night's insights, for the sleep debt card. Nil leaves debt out.
    public init(snapshot: SleepDaySnapshot, range: Binding<LooprChartRange>, insights: SleepNightInsights? = nil) {
        self.snapshot = snapshot
        self.insights = insights
        _range = range
    }

    public var body: some View {
        Group {
            // One sentence first: how many nights, the average, and the person's usual (Data ICP R2-NEW-07, R2-SW-04).
            if let summary = Self.summary(points(for: LooprMetricLinkID.sleepDuration, trendKey: nil), range: range,
                                          endingOn: endingOn) {
                LooprCard {
                    LooprText(summary, style: .prose)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityIdentifier("sleep-trends-summary")
            }
            chart(SleepTrendsScreen.charts[0])

            if let insights, insights.ledger.measuredNights > 0 {
                LooprSectionHeader(insights.target.sectionTitle, detail: "Last 14 nights", accent: .sleep)
                    .padding(.top, LooprSpacing.sm)
                SleepDebtCard(ledger: insights.ledger, target: insights.target)
            }

            let consistency = SleepConsistency(history: SleepNightHistory(trend: snapshot.trend, day: snapshot.day))
            if consistency.measured.count >= 2 {
                VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                    LooprSectionHeader("Bedtime and wake time", detail: "Last 14 nights", accent: .sleep)
                    LooprSurface {
                        VStack(alignment: .leading, spacing: LooprSpacing.md) {
                            if let summary = consistency.summary {
                                Text(summary)
                                    .looprTypography(.prose)
                                    .foregroundStyle(Color.loopr(.ink))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            SleepTimingChart(consistency: consistency)
                        }
                    }
                }
                .padding(.top, LooprSpacing.sm)
            }

            // Deep, REM and efficiency look alike as bars, so they wait behind one row.
            LooprFoldSection("More sleep numbers", summary: "Deep sleep, REM sleep and efficiency",
                             identifier: "sleep-trends-more", isOpen: $showsMore) {
                ForEach(SleepTrendsScreen.charts.dropFirst(), id: \.id) { chart($0) }
            }
            .padding(.top, LooprSpacing.sm)
        }
        .task(id: snapshot.day) { await loadHistory() }
    }

    @ViewBuilder
    private func chart(_ chart: (id: String, title: String, trendKey: String?, kind: LooprChartKind, step: Double)) -> some View {
        let points = points(for: chart.id, trendKey: chart.trendKey)
        LooprSectionHeader(chart.title, accent: .sleep)
            .padding(.top, LooprSpacing.sm)
        LooprMetricTrendCard(
            title: chart.title,
            points: points,
            endingOn: endingOn,
            range: $range,
            kind: chart.kind,
            accent: .sleep,
            unit: chart.id == LooprMetricLinkID.sleepEfficiency ? "%" : "",
            valueFormat: chart.id == LooprMetricLinkID.sleepEfficiency ? SleepTrendsScreen.percentText : SleepTrendsScreen.durationText,
            axisFormat: chart.id == LooprMetricLinkID.sleepEfficiency ? SleepTrendsScreen.percentText : SleepTrendsScreen.minuteAxisText,
            baseline: LooprBaselineBand.trailing(points, before: endingOn),
            identifier: "sleep-trend-\(chart.id)",
            showsRangePicker: false,
            yAxisStep: chart.step
        )
    }

    /// "30 nights with a reading. You averaged 7 h 36 m. Your usual is 7 h 23 m to 7 h 49 m." Nil with no night in the
    /// range. Without a usual range yet, the last sentence goes.
    nonisolated static func summary(_ points: [LooprChartPoint], range: LooprChartRange, endingOn: Date,
                        calendar: Calendar = .current) -> String? {
        let end = calendar.startOfDay(for: endingOn)
        guard let start = calendar.date(byAdding: .day, value: -(range.dayCount - 1), to: end) else { return nil }
        let values = points.filter { $0.date >= start && $0.date <= end && $0.value.isFinite }.map(\.value)
        guard !values.isEmpty, let average = LooprUnitFormatter.duration(minutes: values.reduce(0, +) / Double(values.count))
        else { return nil }
        var text = "\(values.count == 1 ? "1 night" : "\(values.count) nights") with a reading. You averaged \(average)."
        if let band = LooprBaselineBand.trailing(points, before: endingOn),
           let low = LooprUnitFormatter.duration(minutes: band.lower), let high = LooprUnitFormatter.duration(minutes: band.upper) {
            text += " Your usual is \(low) to \(high)."
        }
        return text
    }

    /// The selected night's day at noon, local time.
    private var endingOn: Date {
        SleepCivilDay(snapshot.day)?.noon(in: .current) ?? Date()
    }

    private func points(for id: String, trendKey: String?) -> [LooprChartPoint] {
        SleepTrendsScreen.merged(history: loaded[id] ?? [], trend: SleepTrendsScreen.trendPoints(snapshot.trend, key: trendKey), endingOn: endingOn)
    }

    private func loadHistory() async {
        guard let metricLink else { return }
        var result: [String: [LooprChartPoint]] = [:]
        for chart in SleepTrendsScreen.charts where metricLink.supports(chart.id) {
            let points = await metricLink.history(chart.id, LooprChartRange.longestDayCount)
            if !points.isEmpty { result[chart.id] = points }
        }
        loaded = result
    }
}

public struct SleepSuggestedAlarmScreen: View {
    public let suggestion: SleepSuggestedAlarm
    private let onConfirm: @Sendable () async -> SleepAlarmConfirmation
    @State private var isConfirming = false
    @State private var confirmation: SleepAlarmConfirmation?

    public init(
        suggestion: SleepSuggestedAlarm,
        onConfirm: @escaping @Sendable () async -> SleepAlarmConfirmation = {
            .unavailable("Alarm scheduling is unavailable on this device.")
        }
    ) {
        self.suggestion = suggestion
        self.onConfirm = onConfirm
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                LooprSurface {
                    VStack(alignment: .leading, spacing: LooprSpacing.md) {
                        LooprText("Suggested alarm", style: .cardTitle)
                        HStack(alignment: .firstTextBaseline) {
                            LooprText("Local time", style: .rowTitle)
                            Spacer(minLength: LooprSpacing.sm)
                            LooprText(suggestion.localTime, style: .metricValue)
                        }
                        LooprText(suggestion.reason, style: .prose, color: .inkSecondary)
                        LooprText("Source: \(suggestion.source)", style: .confidence, color: .inkSecondary)
                    }
                }

                Button("Confirm suggested alarm") {
                    guard !isConfirming else { return }
                    isConfirming = true
                    Task { @MainActor in
                        confirmation = await onConfirm()
                        isConfirming = false
                    }
                }
                .buttonStyle(LooprButtonStyle())
                .disabled(isConfirming)
                .accessibilityIdentifier("sleep-suggested-alarm-confirm")

                if isConfirming {
                    ProgressView("Checking availability…")
                        .tint(Color.loopr(.sleep))
                }

                if let confirmation {
                    switch confirmation {
                    case .applied:
                        Label("Alarm confirmed", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Color.loopr(.sleep))
                            .accessibilityIdentifier("sleep-suggested-alarm-applied")
                    case .unavailable(let message):
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(Color.loopr(.inkSecondary))
                            .accessibilityIdentifier("sleep-suggested-alarm-unavailable")
                    }
                }

                LooprText(
                    "Nothing changes until you confirm. If notification or strap-alarm support is unavailable, "
                        + "Loopr keeps the suggestion as an un-applied recommendation.",
                    style: .prose,
                    color: .inkSecondary
                )
            }
            .padding(LooprSpacing.screenGutter)
            .padding(.bottom, LooprSpacing.tabBarClearance)
        }
        .background(Color.loopr(.background).ignoresSafeArea())
        .navigationTitle("Suggested alarm")
        .toolbarTitleDisplayMode(.inlineLarge)
        .accessibilityIdentifier("sleep-suggested-alarm-screen")
    }
}

public struct SleepCorrectionsScreen: View {
    public let corrections: [SleepCorrection]
    public init(corrections: [SleepCorrection]) { self.corrections = corrections }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                if corrections.isEmpty {
                    LooprSurface {
                        LooprText("No corrections", style: .rowTitle)
                    }
                } else {
                    SleepHairlineList(corrections) { correction in
                        VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                            Text(correction.target)
                                .looprTypography(.rowTitle)
                                .foregroundStyle(Color.loopr(.ink))
                            Text("\(correction.before ?? "absent") → \(correction.after ?? "absent")")
                                .looprTypography(.metricUnit)
                                .foregroundStyle(Color.loopr(.inkSecondary))
                            Text("\(correction.reason) · \(correction.source)")
                                .looprTypography(.confidence)
                                .foregroundStyle(Color.loopr(.inkSecondary))
                        }
                        .padding(.vertical, 13)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            .padding(LooprSpacing.screenGutter)
            .padding(.bottom, LooprSpacing.tabBarClearance)
        }
        .background(Color.loopr(.background).ignoresSafeArea())
        .navigationTitle("Sleep corrections")
        .toolbarTitleDisplayMode(.inlineLarge)
        .accessibilityIdentifier("sleep-corrections-screen")
    }
}

/// What the Sleep page shows: one night, or the trend charts for a range.
public enum SleepPageScope: Hashable, Sendable {
    case night
    case range(LooprChartRange)

    static let options: [LooprPillOption<SleepPageScope>] =
        [LooprPillOption(.night, title: "Night", spokenTitle: "This night", identifier: "sleep-scope-night")]
        + LooprChartRange.allCases.map {
            LooprPillOption(.range($0), title: $0.title, spokenTitle: $0.spokenTitle, identifier: "sleep-scope-\($0.rawValue)")
        }

    /// The ranges longer than the history, shown dimmed: a 2Y pill over three months of nights would head a "2-year
    /// average" it does not have (Data ICP R4-SW-01, R4-DES-01). The same rule as the metric pages' range picker.
    static func locked(historyDays: Int) -> Set<SleepPageScope> {
        let open = LooprChartRange.unlocked(historyDays: historyDays)
        return Set(LooprChartRange.allCases.filter { !open.contains($0) }.map { .range($0) })
    }
}
