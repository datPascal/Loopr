import AnalyticsKit
import BodyKit
import DesignSystem
import AnalyticsKit
import HeartKit
import DomainKit
import ProfileKit
import SwiftUI

/// Loads a metric's history once, for the longest range and the day the
/// page is about, and keeps it for every range the page shows. The other
/// metrics' histories for "What moves with this" load after the page, off the
/// main actor.
@MainActor
@Observable
final class MetricDetailModel {
    enum LoadState: Equatable {
        case loading
        case loaded
        case failed
    }

    enum CorrelationState: Equatable {
        /// The page itself is still loading.
        case waiting
        /// Too few readings of this metric in the range shown to look.
        case tooFewDays(measured: Int)
        case loading
        case loaded([MetricCorrelation])
    }

    static let historyDays = 400

    let key: MetricKey
    private(set) var state: LoadState = .loading
    private(set) var history: [MetricHistoryPoint] = []
    private(set) var points: [LooprChartPoint] = []
    private(set) var anchor: MetricDetailAnchor
    private(set) var availableRanges: Set<LooprChartRange> = [.week]
    private(set) var recoveryCalendar: LooprRecoveryCalendarModel?
    private(set) var strainTarget: StrainTarget?
    private(set) var skinTemperature: HeartSkinTemperatureVital?
    private(set) var correlationState: CorrelationState = .waiting

    @ObservationIgnored private var others: [MetricKey: [Date: Double]]?
    @ObservationIgnored private var othersAnchor: Date?

    init(key: MetricKey, anchor: MetricDetailAnchor = MetricDetailAnchor(day: Date(), today: Date())) {
        self.key = key
        self.anchor = anchor
    }

    // This model owns values only. It needs no executor-bound cleanup.
    // Avoid the implicit isolated deinit path that aborts in TaskLocal
    // teardown when UIKit releases a hosted metric page on iOS 26.3.
    nonisolated deinit {}

    func load(from provider: any MetricHistoryProviding, anchor: MetricDetailAnchor) async {
        if anchor != self.anchor {
            self.anchor = anchor
            state = .loading
            correlationState = .waiting
        }
        strainTarget = nil
        do {
            let loaded = try await provider.series(for: key, days: Self.historyDays, endingOn: anchor.endOfDay)
            let sorted = loaded
                .filter { $0.value.isFinite && $0.day <= anchor.endOfDay }
                .sorted { $0.day < $1.day }
            if key == .skinTemperatureDeviation { skinTemperature = try await provider.skinTemperature(endingOn: anchor.day) }
            history = sorted
            points = MetricTrendNarrative.chartPoints(sorted)
            availableRanges = MetricDetailRules.availableRanges(points, anchor: anchor.day, calendar: anchor.calendar)
            if key == .recovery {
                let calendar = LooprRecoveryCalendarModel(points: points, endingOn: anchor.day, calendar: anchor.calendar)
                recoveryCalendar = calendar.isWorthShowing ? calendar : nil
            }
            if key == .strain, let latest = anchor.latest(in: points) {
                let recovery = try? await provider.series(for: .recovery, days: 1, endingOn: latest.date)
                let sameDay = recovery?.last { anchor.calendar.isDate($0.day, inSameDayAs: latest.date) }
                let day = DayIdentity(bodyDate: latest.date, calendar: anchor.calendar)
                let byDay = Dictionary(sorted.map {
                    (DayIdentity(bodyDate: $0.day, calendar: anchor.calendar), $0.value)
                }, uniquingKeysWith: { _, latest in latest })
                let daily = BodyHistory.window(endingOn: day.bodyAdding(days: -1), length: BodyHistory.lookbackDays)
                    .map { byDay[$0] }
                strainTarget = StrainTarget(recovery: sameDay?.value, trainingLoad: ActivityAnalytics.trainingLoad(dailyStrain: daily))
            }
            state = .loaded
        } catch is CancellationError {
            return
        } catch {
            state = .failed
        }
    }

    /// Finds the metrics that moved with this one over `range`. The other
    /// histories are read once per day on screen; changing the range only
    /// re-ranks.
    func loadCorrelations(for range: LooprChartRange, provider: any MetricHistoryProviding) async {
        guard state == .loaded, MetricCorrelations.canCompare(key) else {
            correlationState = .waiting
            return
        }
        let calendar = anchor.calendar
        let values = MetricCorrelations.daily(history, calendar: calendar)
        let window = MetricCorrelations.window(range, anchor: anchor.day, calendar: calendar)
        let measured = MetricCorrelations.measuredDays(values, in: window)
        guard measured >= MetricCorrelations.minimumPairedDays else {
            correlationState = .tooFewDays(measured: measured)
            return
        }
        if others == nil || othersAnchor != anchor.day {
            correlationState = .loading
            let loaded = await MetricCorrelations.loadOthers(
                for: key, provider: provider, days: Self.historyDays, endingOn: anchor.endOfDay, calendar: calendar
            )
            guard !Task.isCancelled else { return }
            others = loaded
            othersAnchor = anchor.day
        }
        let ranked = await MetricCorrelations.rankOffMain(target: key, values: values, others: others ?? [:], window: window)
        guard !Task.isCancelled else { return }
        correlationState = .loaded(ranked)
    }

    /// The reading the hero shows: the anchor day's, or the latest before it.
    var latest: LooprChartPoint? { anchor.latest(in: points) }

    var sourceCounts: (band: Int, appleHealth: Int, accountExport: Int) {
        history.reduce(into: (0, 0, 0)) { counts, point in
            switch point.source {
            case .band: counts.0 += 1
            case .appleHealth: counts.1 += 1
            case .whoopExport: counts.2 += 1
            }
        }
    }
}

/// The page every metric card opens: the value for the day the tabs show
/// against the person's own usual range, the history chart, a plain-words
/// trend summary, what else moved with it, and what the number means and how
/// Loopr works it out.
struct MetricDetailScreen: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.metricHistoryProvider) private var provider
    @Environment(\.looprDaySelection) private var daySelection
    @Environment(\.looprMetricLink) private var metricLink
    @Environment(\.sleepNeedRepository) private var sleepNeedRepository
    @State private var model: MetricDetailModel
    @State private var range: LooprChartRange = MetricDetailDebugLaunch.initialRange ?? .month
    @State private var showsFullMethod = false
    @State private var sleepNeedMinutes = SleepNeed.defaultMinutes

    private let key: MetricKey
    private let presentation: MetricPresentation
    private let content: MetricContent

    init(key: MetricKey, model: MetricDetailModel? = nil) {
        self.key = key
        presentation = key.presentation
        content = MetricContentCatalog.content(for: key)
        _model = State(initialValue: model ?? MetricDetailModel(key: key))
    }

    /// The tabs' shared day. Outside the tab shell (previews), today.
    ///
    /// The civil day is placed in `Calendar.current`, the calendar the
    /// history store and the charts bucket days in. Mixing in the selection's
    /// own calendar (a pinned zone in fixtures) moved the chart one day away
    /// from the hero.
    private var anchor: MetricDetailAnchor {
        MetricDetailAnchor(
            selectedDay: daySelection.map { LooprDays.looprDay($0.day) },
            today: daySelection.map { LooprDays.looprDay($0.today) },
            calendar: .current
        )
    }

    /// The range drawn: the chosen one unless history is too short for it.
    private var shownRange: LooprChartRange {
        LooprChartRange.resolved(range, available: model.availableRanges)
    }

    private struct CorrelationRequest: Hashable {
        let day: Date
        let range: LooprChartRange
        let loaded: Bool
    }

    var body: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                        Group {
                            hero
                                .accessibilityElement(children: .contain)
                                .accessibilityIdentifier("metric-detail-hero")
                            trend
                                .id("metric-detail-trend")
                            if let calendar = model.recoveryCalendar, model.state == .loaded {
                                MetricDetailSection(title: "Recovery calendar", identifier: "metric-detail-recovery-calendar") {
                                    LooprRecoveryCalendar(model: calendar, identifier: "metric-detail-recovery-calendar-grid")
                                }
                                .id("metric-detail-recovery-calendar")
                            }
                            if model.state == .loaded, !model.points.isEmpty, key != .skinTemperatureDeviation {
                                summary
                                    .id("metric-detail-summary")
                            }
                            if model.state == .loaded, model.latest != nil, MetricCorrelations.canCompare(key) {
                                MetricCorrelationSection(
                                    key: key,
                                    state: model.correlationState,
                                    range: shownRange,
                                    canWiden: model.availableRanges.count > 1,
                                    accent: presentation.accent,
                                    open: metricLink.map { link in { other in link.open(other.rawValue) } }
                                )
                                .id("metric-detail-correlations")
                            }
                            MetricDetailSection(title: "What it is", identifier: "metric-detail-definition") {
                                MetricDetailProse(paragraphs: content.definition)
                            }
                            .id("metric-detail-definition")
                            MetricDetailSection(title: latestIsImported ? "About this reading" : "How Loopr calculates it", identifier: "metric-detail-calculation") {
                                calculation
                            }
                            if !content.raises.isEmpty || !content.lowers.isEmpty {
                                MetricDetailSection(title: "What tends to change it", identifier: "metric-detail-movers") {
                                    MetricDetailMovers(raises: content.raises, lowers: content.lowers, accent: presentation.accent)
                                }
                                .id("metric-detail-movers")
                            }
                            MetricDetailSection(title: "Good to know", identifier: "metric-detail-facts") {
                                MetricDetailFacts(facts: content.facts, sources: content.sources, accent: presentation.accent)
                            }
                            .id("metric-detail-facts")
                            MetricDetailSection(title: "Data source", identifier: "metric-detail-source") {
                                sourceContent
                            }
                            .id("metric-detail-source")
                        }
                        // Give each section the viewport width. A long word
                        // in a later section must not widen every card.
                        .frame(width: max(0, viewport.size.width - 2 * LooprSpacing.screenGutter), alignment: .leading)
                    }
                    .padding(.horizontal, LooprSpacing.screenGutter)
                    .padding(.top, LooprSpacing.xs)
                    .padding(.bottom, LooprSpacing.tabBarClearance)
                    // The history arriving fades the hero over and lets the
                    // sections that need it settle in, instead of popping.
                    .animation(LooprMotion.phaseChange(reduceMotion: reduceMotion), value: model.state)
                }
                .task(id: model.state) {
                    #if DEBUG
                    guard model.state == .loaded, let target = MetricDetailDebugLaunch.consumeScrollTarget() else { return }
                    try? await Task.sleep(for: .milliseconds(600))
                    proxy.scrollTo(target, anchor: .top)
                    #endif
                }
            }
        }
        .background(Color.loopr(.background).ignoresSafeArea())
        .navigationTitle(presentation.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.loopr(.background), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .accessibilityIdentifier("metric-detail-screen")
        .task(id: anchor) {
            if key == .sleepDuration, let sleepNeedRepository {
                sleepNeedMinutes = SleepNeed.minutes(from: (try? await sleepNeedRepository.readGoals()) ?? [])
            }
            await model.load(from: provider, anchor: anchor)
        }
        .task(id: CorrelationRequest(day: model.anchor.day, range: shownRange, loaded: model.state == .loaded)) {
            // After the page has drawn, so the first frame never waits on it.
            await model.loadCorrelations(for: shownRange, provider: provider)
        }
    }

    // MARK: Hero

    @ViewBuilder
    private var hero: some View {
        LooprSurface(emphasis: .hero(presentation.accent)) {
            Group {
                switch model.state {
                case .loading:
                    VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                        LooprSkeleton(height: 12).frame(width: 120)
                        LooprSkeleton(height: 40).frame(width: 160)
                        LooprSkeleton(height: 14)
                    }
                case .failed:
                    StateMessage(.recoverableError, accent: presentation.accent)
                case .loaded:
                    if key == .skinTemperatureDeviation {
                        temperatureHero
                    } else if let latest = model.latest {
                        heroValue(latest)
                    } else {
                        heroEmpty
                    }
                }
            }
            .transition(.opacity)
        }
    }

    private var temperatureBand: LooprBaselineBand? {
        guard let value = model.skinTemperature?.deviation.value, !value.likelyFitChange,
              let usual = value.usualRange else { return nil }
        return .init(center: 0, lower: usual.lowerBound - value.baselineCelsius,
            upper: usual.upperBound - value.baselineCelsius, measuredDays: value.baselineNights + 1)
    }

    private var temperatureHero: some View {
        let vital = model.skinTemperature
        let shown = HeartVitalsPresenter.skinTemperature(vital)
        let deviation = vital?.deviation.value
        return VStack(alignment: .leading, spacing: LooprSpacing.sm) {
            LooprText(model.anchor.isToday ? "LAST NIGHT" : model.anchor.dateText(model.anchor.day).uppercased(), style: .sectionLabel, color: .inkSecondary)
            if let deviation, !deviation.likelyFitChange {
                if deviation.trusted && !deviation.outsideUsualRange {
                    LooprText("Within your usual range", style: .title)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("metric-detail-value")
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.xs) {
                            heroNumber(presentation.value(deviation.deltaCelsius), unit: "°C")
                            LooprText("vs usual", style: .label, color: .inkSecondary)
                        }
                        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                            heroNumber(presentation.value(deviation.deltaCelsius), unit: "°C")
                            LooprText("vs usual", style: .label, color: .inkSecondary)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Skin temperature \(HeartVitalsPresenter.signedTenths(deviation.deltaCelsius)) degrees Celsius from your usual")
                    .accessibilityIdentifier("metric-detail-value")
                }
                if !deviation.trusted || deviation.outsideUsualRange {
                    LooprText(shown.detail ?? "", style: .prose, color: .inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let band = temperatureBand {
                    LooprTypicalRangeBar(value: deviation.deltaCelsius, typical: band.lower...band.upper, accent: presentation.accent)
                    LooprText("Usual range \(presentation.value(band.lower)) to \(presentation.value(band.upper)) °C", style: .caption, color: .inkSecondary)
                        .accessibilityIdentifier("metric-detail-usual-range")
                }
            } else {
                LooprText(shown.eyebrow ?? "No reading for this night", style: .cardTitle)
                    .accessibilityIdentifier("metric-detail-empty")
                LooprText(shown.detail ?? "", style: .prose, color: .inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let celsius = vital?.nightlyCelsius, deviation?.likelyFitChange != true {
                LooprText("Approximate wrist value \(String(format: "%.1f", celsius)) °C", style: .caption, color: .inkSecondary)
                    .accessibilityIdentifier("metric-detail-temperature-approximate")
            }
        }
    }

    private func heroValue(_ latest: LooprChartPoint) -> some View {
        let anchor = model.anchor
        let band = MetricTrendNarrative.baseline(model.points, today: latest.date, calendar: anchor.calendar)
        let delta = heroDelta(latest, band: band)
        let valueText = presentation.value(latest.value)
        let unit = presentation.format == .duration ? nil : (presentation.unit.isEmpty ? nil : presentation.unit)
        return VStack(alignment: .leading, spacing: LooprSpacing.md) {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                    heroDate(latest)
                    heroSource
                }
            } else {
                HStack(alignment: .firstTextBaseline) {
                    heroDate(latest)
                    Spacer(minLength: LooprSpacing.xs)
                    heroSource
                }
            }
            VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.sm) {
                        heroNumber(valueText, unit: unit)
                        recoveryBandLabel(latest.value)
                    }
                    VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                        heroNumber(valueText, unit: unit)
                        recoveryBandLabel(latest.value)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(heroSpokenValue(latest.value))
                .accessibilityIdentifier("metric-detail-value")
                if let missing = anchor.missingCaption(for: latest.date) {
                    LooprText(missing, style: .caption, color: .inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("metric-detail-missing-day")
                }
            }
            if let delta {
                heroStatus(delta)
                    .accessibilityIdentifier("metric-detail-status")
            }
            if key == .sleepDuration {
                let difference = latest.value - sleepNeedMinutes
                let need = LooprUnitFormatter.duration(minutes: sleepNeedMinutes) ?? "8 h"
                let delta = LooprDelta(kind: .change(difference), isOutsideUsual: difference < -60,
                                       higherIsBetter: true, format: .duration, reference: "need")
                LooprText("\(need) needed · \(delta.text)", style: .caption, color: .inkSecondary)
                    .accessibilityIdentifier("metric-detail-sleep-need")
            }
            if let band {
                VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                    LooprTypicalRangeBar(value: latest.value, typical: band.lower...band.upper, accent: presentation.accent)
                    LooprText(usualRangeText(band), style: .caption, color: .inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("metric-detail-usual-range")
                }
            }
            if key == .strain, let target = model.strainTarget {
                VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                    LooprText("Suggested \(target.text) · recovery \(target.recovery)", style: .caption, color: .inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let reason = target.reason {
                        LooprText(reason, style: .caption, color: .inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("metric-detail-strain-target")
            }
        }
    }

    private func heroDate(_ latest: LooprChartPoint) -> some View {
        LooprText(model.anchor.heroEyebrow(for: latest.date, key: key), style: .sectionLabel, color: .inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("metric-detail-day")
    }

    @ViewBuilder private var heroSource: some View {
        if let source = model.history.last(where: { $0.day <= model.anchor.endOfDay })?.source, source == .appleHealth {
            StatusChip("Apple Health", symbol: "heart.text.square", accent: presentation.accent)
        } else if model.history.last(where: { $0.day <= model.anchor.endOfDay })?.source == .whoopExport {
            StatusChip("Account export", symbol: "doc", accent: presentation.accent)
        }
    }

    private func heroNumber(_ value: String, unit: String?) -> some View {
        LooprValueText(value, unit: unit, valueStyle: .display, unitStyle: .metricValue)
            .minimumScaleFactor(0.6)
    }

    @ViewBuilder
    private func recoveryBandLabel(_ value: Double) -> some View {
        if key == .recovery, let band = LooprRecoveryBand(score: value) {
            LooprRecoveryBandLabel(band, style: .rowTitle)
                .accessibilityIdentifier("metric-detail-recovery-band")
        }
    }

    private func heroSpokenValue(_ value: Double) -> String {
        var text = "\(presentation.title), "
        if presentation.format == .duration {
            text += LooprUnitFormatter.spokenDuration(minutes: value) ?? presentation.value(value)
        } else {
            text += "\(presentation.value(value)) \(presentation.spokenUnit)"
        }
        if key == .recovery, let band = LooprRecoveryBand(score: value) { text += ", \(band.spokenDescription)" }
        return text
    }

    private func heroDelta(_ latest: LooprChartPoint, band: LooprBaselineBand?) -> LooprDelta? {
        LooprDelta.compare(
            latest.value,
            usual: band,
            higherIsBetter: MetricDetailRules.higherIsBetter(key),
            unit: MetricDetailRules.deltaUnit(key),
            format: MetricDetailRules.deltaFormat(key),
            learning: (MetricDetailRules.learningCount(model.points, latest: latest.date, calendar: model.anchor.calendar), LooprBaselineBand.minimumDays),
            learningNoun: MetricDetailRules.countNoun(for: key).plural
        )
    }

    /// One line: "+7 ms vs usual", "Within your usual range" or "Learning
    /// your usual · 2 of 14 nights".
    private func heroStatus(_ delta: LooprDelta) -> some View {
        let text: String = switch delta.kind {
        case .usual: "Within your usual range"
        case .change, .learning: delta.text
        }
        let color: LooprColorToken = switch delta.tone {
        case .good: presentation.accent.textInk
        case .caution: .caution
        case .neutral: delta.kind == .usual ? .ink : .inkSecondary
        }
        return LooprText(text, style: .label, color: color)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(delta.kind == .usual ? text : delta.spokenText)
    }

    /// The one place the page states the usual range.
    private func usualRangeText(_ band: LooprBaselineBand) -> String {
        let high = presentation.unit.hasPrefix("/") ? presentation.value(band.upper) : presentation.valueWithUnit(band.upper)
        return "Usual \(presentation.value(band.lower)) to \(high), from your last \(LooprBaselineBand.windowDays) days"
    }

    private var heroEmpty: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.sm) {
            LooprText(model.anchor.isToday ? presentation.period : model.anchor.dateText(model.anchor.day).uppercased(), style: .sectionLabel, color: .inkSecondary)
            HStack(alignment: .top, spacing: LooprSpacing.sm) {
                Image(systemName: emptySymbol)
                    .looprTypography(.title)
                    .foregroundStyle(Color.loopr(presentation.accent))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                    LooprText(emptyTitle, style: .rowTitle)
                    LooprText(emptyDetail, style: .prose, color: .inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
        }
        .accessibilityIdentifier("metric-detail-empty")
    }

    private var emptyTitle: String {
        switch presentation.availability {
        case .calculated: "No readings yet"
        case .appleHealthOnly: "No readings from Apple Health"
        case .importedOnly: "No imported readings"
        case .notYetCalculated: "Not calculated yet"
        }
    }

    private var emptyDetail: String {
        if let detail = presentation.emptyDetail { return detail }
        return switch presentation.availability {
        case .calculated:
            "Loopr fills this in once your band has recorded a full day and night. Wear it to sleep tonight."
        case .appleHealthOnly:
            "Loopr does not work this out from your band. If another device writes it to Apple Health, the history shows up here."
        case .importedOnly:
            "This band doesn't report blood oxygen. Imported readings appear when available."
        case .notYetCalculated:
            "Loopr does not produce this number yet. The explanation below says what it will measure and why."
        }
    }

    private var emptySymbol: String {
        switch presentation.availability {
        case .calculated: MetricDetailRules.isNightly(key) ? "moon.zzz" : "chart.bar"
        case .appleHealthOnly, .importedOnly: "heart.text.square"
        case .notYetCalculated: "hourglass"
        }
    }

    // MARK: Trend

    @ViewBuilder
    private var trend: some View {
        if model.state == .loaded, !model.points.isEmpty {
            let format = presentation.format
            LooprMetricTrendCard(
                title: presentation.title,
                points: model.points,
                endingOn: model.anchor.day,
                range: $range,
                kind: effectiveChartKind,
                accent: presentation.accent,
                unit: presentation.format == .duration ? "" : presentation.unit,
                valueFormat: { format.string($0) },
                axisFormat: { format.axisString($0) },
                baseline: key == .skinTemperatureDeviation ? temperatureBand : MetricTrendNarrative.baseline(model.points, today: model.anchor.day, calendar: model.anchor.calendar),
                identifier: "metric-detail-trend",
                yAxisStep: presentation.yAxisStep,
                options: LooprTrendCardOptions(
                    scale: MetricDetailRules.scale(for: key),
                    availableRanges: model.availableRanges,
                    smallDataNoun: MetricDetailRules.countNoun(for: key),
                    legendShowsValues: false
                )
            )
        } else if model.state == .loading {
            LooprSurface {
                VStack(alignment: .leading, spacing: LooprSpacing.md) {
                    LooprSkeleton(height: 34)
                    LooprSkeleton(height: 200)
                }
            }
        }
    }

    /// Range bars need daily extremes; without them the metric draws a line.
    private var effectiveChartKind: LooprChartKind {
        guard presentation.chartKind == .rangeBars else { return presentation.chartKind }
        return model.points.contains { $0.low != nil && $0.high != nil } ? .rangeBars : .line
    }

    // MARK: Summary

    @ViewBuilder
    private var summary: some View {
        let range = shownRange
        let result = MetricTrendNarrative.summary(points: model.points, key: key, range: range, today: model.anchor.day, calendar: model.anchor.calendar)
        let rows = summaryRows(result, range: range)
        // Without a usual range the hero already says Loopr is still
        // learning; the direction card would only say it again.
        let showsDirection = result.baseline != nil
        if showsDirection || !rows.isEmpty {
            VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                MetricDetailEyebrow("Trend")
                if showsDirection {
                    VStack(alignment: .leading, spacing: LooprSpacing.xxs + 2) {
                        HStack(spacing: LooprSpacing.xs) {
                            Image(systemName: directionSymbol(result.direction))
                                .looprTypography(.rowTitle)
                                .foregroundStyle(Color.loopr(presentation.accent.spectralChipLabel))
                                .frame(width: 26, height: 26)
                                .background(Color.loopr(presentation.accent).opacity(0.14), in: Circle())
                                .accessibilityHidden(true)
                            LooprText(result.directionLabel, style: .cardTitle)
                        }
                        LooprText(result.headline, style: .prose, color: .inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(LooprSpacing.formCardPadding)
                    .modifier(MetricDetailCardBackground())
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("metric-detail-direction")
                }
                if !rows.isEmpty {
                    HairlineMetricList(rows)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("metric-detail-summary")
        }
    }

    /// Highest, lowest and day-to-day change only once the range holds a
    /// week of readings; with two readings they are just those two numbers.
    private func summaryRows(_ result: MetricTrendNarrative.Summary, range: LooprChartRange) -> [HairlineMetricRow] {
        guard MetricDetailRules.showsFullStatistics(measuredDays: result.rangeMeasuredDays) else { return [] }
        var rows: [HairlineMetricRow] = []
        let unit = presentation.unit.isEmpty ? nil : presentation.unit
        let noun = MetricDetailRules.countNoun(for: key)
        if let average = result.weekAverage, range != .week {
            rows.append(HairlineMetricRow(id: "metric-detail-week-average", title: "7-day average", confidence: "\(result.weekMeasuredDays) of 7 \(noun.plural) measured", value: presentation.value(average), unit: unit))
        }
        if let highest = result.highest {
            rows.append(HairlineMetricRow(id: "metric-detail-highest", title: "Highest in \(range.spokenTitle)", confidence: model.anchor.dateText(highest.date), value: presentation.value(highest.value), unit: unit))
        }
        if let lowest = result.lowest {
            rows.append(HairlineMetricRow(id: "metric-detail-lowest", title: "Lowest in \(range.spokenTitle)", confidence: model.anchor.dateText(lowest.date), value: presentation.value(lowest.value), unit: unit))
        }
        if let change = result.typicalDailyChange {
            rows.append(HairlineMetricRow(id: "metric-detail-variability", title: "Day-to-day change", confidence: "Average move between measured days", value: "±" + presentation.value(change), unit: unit))
        }
        return rows
    }

    private func directionSymbol(_ direction: MetricTrendNarrative.Direction) -> String {
        switch direction {
        case .higher: "arrow.up.right"
        case .lower: "arrow.down.right"
        case .steady: "arrow.right"
        case .notEnoughData: "hourglass"
        }
    }

    // MARK: Calculation

    /// The first paragraph always shows; the full method on request, so a
    /// first read is not a page of maths.
    private var latestIsImported: Bool {
        model.history.last(where: { $0.day <= model.anchor.endOfDay })?.source == .whoopExport
    }

    private var calculation: some View {
        let paragraphs = latestIsImported
            ? ["The account export supplies this reading. Loopr stores its value and unit."]
            : content.calculation
        return VStack(alignment: .leading, spacing: LooprSpacing.sm) {
            MetricDetailProse(paragraphs: Array(paragraphs.prefix(showsFullMethod ? paragraphs.count : 1)))
            if paragraphs.count > 1 {
                Button {
                    withAnimation(.snappy(duration: LooprMotion.standard)) { showsFullMethod.toggle() }
                } label: {
                    HStack(spacing: LooprSpacing.xxs + 2) {
                        Text(showsFullMethod ? "Show less" : "Read the full method")
                            .looprTypography(.label)
                        Image(systemName: showsFullMethod ? "chevron.up" : "chevron.down")
                            .font(.caption.weight(.semibold))
                            .accessibilityHidden(true)
                    }
                    .foregroundStyle(Color.loopr(presentation.accent.textInk))
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("metric-detail-calculation-toggle")
            }
        }
    }

    // MARK: Source

    private var sourceContent: some View {
        let counts = model.sourceCounts
        return VStack(alignment: .leading, spacing: LooprSpacing.sm) {
            MetricDetailProse(paragraphs: counts.band == 0 && counts.appleHealth == 0 && counts.accountExport > 0
                ? ["These readings came from your account export."]
                : [content.provenance])
            if counts.band + counts.appleHealth + counts.accountExport > 0 {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: LooprSpacing.xs) { sourceChips(counts) }
                    VStack(alignment: .leading, spacing: LooprSpacing.xs) { sourceChips(counts) }
                }
                if counts.band > 0, counts.appleHealth + counts.accountExport > 0 {
                    LooprText("When both have a value for the same day, Loopr uses the band.", style: .caption, color: .inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private func sourceChips(_ counts: (band: Int, appleHealth: Int, accountExport: Int)) -> some View {
        let noun = MetricDetailRules.countNoun(for: key)
        if counts.band > 0 {
            StatusChip("Band · \(noun.count(counts.band))", symbol: "sensor.tag.radiowaves.forward", accent: presentation.accent)
        }
        if counts.accountExport > 0 {
            StatusChip("Account export · \(noun.count(counts.accountExport))", symbol: "doc", tone: .neutral)
        }
        if counts.appleHealth > 0 {
            StatusChip("Apple Health · \(noun.count(counts.appleHealth))", symbol: "heart.text.square", tone: .neutral)
        }
    }
}

// MARK: - Section pieces

struct MetricDetailEyebrow: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .looprTypography(.sectionLabel)
            .foregroundStyle(Color.loopr(.inkSecondary))
            .padding(.leading, LooprSpacing.xxs)
            .padding(.top, LooprSpacing.sm)
            .accessibilityAddTraits(.isHeader)
    }
}

struct MetricDetailHairline: View {
    var body: some View {
        Rectangle()
            .fill(Color.loopr(.divider))
            .frame(height: 1)
            .accessibilityHidden(true)
    }
}

struct MetricDetailCardBackground: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let isDark = LooprAppearance.isDark(colorScheme)
        let radius = isDark ? LooprRadius.compactCard : LooprRadius.card
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isDark ? Color.loopr(.surface) : Color.loopr(.sheetFill),
                in: RoundedRectangle(cornerRadius: radius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.loopr(.surfaceStroke), lineWidth: isDark ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .shadow(color: isDark ? .clear : Color.loopr(.ink).opacity(0.06), radius: 2, y: 1)
    }
}

struct MetricDetailSection<Content: View>: View {
    let title: String
    let identifier: String
    let content: Content

    init(title: String, identifier: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.identifier = identifier
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            MetricDetailEyebrow(title)
            content
                .padding(LooprSpacing.formCardPadding)
                .modifier(MetricDetailCardBackground())
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
}

private struct MetricDetailProse: View {
    let paragraphs: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.sm) {
            ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                Text(paragraph)
                    .looprTypography(.prose)
                    .foregroundStyle(Color.loopr(.ink).opacity(0.86))
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct MetricDetailMovers: View {
    let raises: [String]
    let lowers: [String]
    let accent: LooprColorToken

    var body: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.md) {
            group(title: "Tends to push it up", symbol: "arrow.up", items: raises)
            MetricDetailHairline()
            group(title: "Tends to push it down", symbol: "arrow.down", items: lowers)
        }
    }

    private func group(title: String, symbol: String, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: LooprSpacing.sm) {
            HStack(spacing: LooprSpacing.xs) {
                Image(systemName: symbol)
                    .looprTypography(.chip)
                    .foregroundStyle(Color.loopr(accent.spectralChipLabel))
                    .frame(width: 20, height: 20)
                    .background(Color.loopr(accent).opacity(0.14), in: Circle())
                    .accessibilityHidden(true)
                Text(title.uppercased())
                    .looprTypography(.sectionLabel)
                    .foregroundStyle(Color.loopr(.inkSecondary))
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.sm) {
                    Circle()
                        .fill(Color.loopr(accent).opacity(0.7))
                        .frame(width: 5, height: 5)
                        .alignmentGuide(.firstTextBaseline) { dimensions in dimensions[.bottom] + 4 }
                        .accessibilityHidden(true)
                    Text(item)
                        .looprTypography(.prose)
                        .foregroundStyle(Color.loopr(.ink).opacity(0.86))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, LooprSpacing.xxs + 2)
            }
        }
    }
}

private struct MetricDetailFacts: View {
    let facts: [String]
    let sources: [String]
    let accent: LooprColorToken

    var body: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.md) {
            ForEach(Array(facts.enumerated()), id: \.offset) { index, fact in
                HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.sm) {
                    Text(String(format: "%02d", index + 1))
                        .looprTypography(.metricUnit)
                        .foregroundStyle(Color.loopr(accent.spectralChipLabel))
                        .accessibilityHidden(true)
                    Text(fact)
                        .looprTypography(.prose)
                        .foregroundStyle(Color.loopr(.ink).opacity(0.86))
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !sources.isEmpty {
                MetricDetailHairline()
                VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                    Text("SOURCES")
                        .looprTypography(.sectionLabel)
                        .foregroundStyle(Color.loopr(.inkSecondary))
                    Text(sources.joined(separator: " · "))
                        .looprTypography(.caption)
                        .foregroundStyle(Color.loopr(.inkSecondary))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("metric-detail-sources")
            }
        }
    }
}

#if DEBUG
#Preview("RMSSD") {
    NavigationStack {
        MetricDetailScreen(key: .rmssd)
    }
    .environment(\.metricHistoryProvider, FixtureMetricHistoryProvider())
    .preferredColorScheme(.dark)
}
#endif
