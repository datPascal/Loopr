import Foundation
import SwiftUI
import DomainKit
import DesignSystem
import AnalyticsKit

public enum BodyRoute: Hashable, Sendable, CaseIterable {
    case day
    case load
    case cardioAge
    case looprAge
}

public struct BodyScreen: View {
    @Environment(\.bodyAppleHealthVO2Max) private var appleHealthVO2Max
    /// The shared day, when the app provides one. The header then names that
    /// day and carries the day navigator.
    @Environment(\.looprDayNavigation) private var dayNavigation
    @ObservedObject private var viewModel: BodyViewModel
    private let route: (BodyRoute) -> Void

    public init(viewModel: BodyViewModel, route: @escaping (BodyRoute) -> Void = { _ in }) {
        self.viewModel = viewModel
        self.route = route
    }

    public var body: some View {
        LooprTabScaffold(header: header, glow: .strain, identifier: "body-screen") {
            LooprPhaseContainer(phase: phase) {
                VStack(alignment: .leading, spacing: 0) {
                    phaseContent
                }
            }
        }
        .navigationTitle("")
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
                // A day with nothing derived reads as one plain card.
                LooprDayEmptyState(dayNavigation, accent: .strain)
                    .padding(.horizontal, LooprSpacing.screenGutter)
                    .padding(.top, LooprSpacing.lg)
            } else {
                BodyStateSurface(state: .noRecords)
            }
        case .failed:
            BodyStateSurface(state: .recoverableError)
        case .content:
            if let snapshot = viewModel.snapshot {
                content(snapshot)
            }
        }
    }

    @ViewBuilder
    private func content(_ snapshot: BodyDaySnapshot) -> some View {
        let isToday = dayNavigation?.isToday ?? true
        let history = viewModel.history
        let recovery = history?.day(snapshot.day)?.recovery
        let end = snapshot.day.bodyAdding(days: -1)
        let load = history.map { BodyTrainingLoad.compute(history: $0, endingOn: end) }
        let model: TrainingLoad? = if case .ready(let ready) = load { ready.model } else { nil }
        let hero = BodyStrainHero.make(metric: snapshot.metric(.strain), recovery: recovery, trainingLoad: model)
        let prompt = BodyProfileGaps.prompt(for: snapshot)
        let fitness = cardioFitness(snapshot)
        let cardioAge = BodyDaySnapshot.cardioAgePresentation(for: snapshot.cardioAge ?? fitness?.resolution?.cardioAge)

        VStack(alignment: .leading, spacing: LooprSpacing.tabSection) {
            switch hero.state {
            case .measured:
                BodyStrainHeroView(hero: hero, isToday: isToday, showsSentence: history != nil,
                                   usualDelta: hero.usualDelta(history: history, anchorIsToday: isToday))
            case .needsAge:
                if let prompt {
                    BodyProfilePromptCard(prompt: prompt)
                        .padding(.horizontal, LooprSpacing.screenGutter)
                        .padding(.top, LooprSpacing.md)
                }
            case .missing(let reason):
                BodyMissingStrainRow(reason: reason)
                    .padding(.horizontal, LooprSpacing.screenGutter)
                    .padding(.top, LooprSpacing.md)
            }

            VStack(alignment: .leading, spacing: LooprSpacing.tabSection) {
                // Everything built on strain waits with the prompt instead of
                // showing its own empty state.
                if prompt == nil, let history {
                    let week = BodyStrainWeek.days(history: history, anchorIsToday: isToday)
                    BodyStrainWeekSection(days: week)
                    let end = BodyStrainWeek.lastCompleteDay(anchor: history.anchor, anchorIsToday: isToday)
                    let load = BodyTrainingLoad.compute(history: history, endingOn: end)
                    BodyTrainingLoadCard(state: load, points: BodyTrainingLoad.trend(history: history, endingOn: end, days: 14)) { route(.load) }
                }

                if let zones = BodyZoneBar.make(snapshot.zoneMinutes) {
                    BodyZoneSection(bar: zones, isToday: isToday)
                }

                let activity = BodyActivityRow.rows(snapshot: snapshot, history: history, anchorIsToday: isToday)
                if !activity.isEmpty {
                    BodyActivitySection(rows: activity)
                }

                BodySection(title: "Cardio fitness") {
                    BodyCardioFitnessCard(presentation: fitness?.presentation ?? BodyCardioFitnessPresenter.empty)
                }

                // Both ages show, locked with what is missing, rather than
                // hiding until a number exists. Cardio Age comes only from
                // Apple Health or a lab test, never from the estimate above.
                BodyAgeSection(
                    cardio: BodyAgeLock.cardio(snapshot: snapshot, presentation: cardioAge),
                    loopr: BodyAgeLock.loopr(presentation: snapshot.looprAgePresentation),
                    route: route
                )

                BodyCompositionSection(composition: BodyCompositionRows.make(snapshot.composition))
            }
            .padding(.horizontal, LooprSpacing.screenGutter)
        }
        .padding(.top, LooprSpacing.xs)
    }

    private func cardioFitness(_ snapshot: BodyDaySnapshot)
        -> (presentation: BodyCardioFitnessPresentation, resolution: CardioFitnessResolution?)? {
        guard !appleHealthVO2Max.isEmpty, let fitness = snapshot.cardioFitness else { return nil }
        guard let resolution = fitness.resolve(appleHealth: appleHealthVO2Max, now: Date()),
              resolution.source == .appleHealth else { return nil }
        return (BodyCardioFitnessPresenter.present(fitness, resolution: resolution), resolution)
    }

    private var headerState: MetricState {
        switch viewModel.loadState {
        case .idle: .noRecords
        case .loading: .loading
        case .failed: .recoverableError
        case .loaded: viewModel.snapshot?.state ?? .noRecords
        }
    }

    private var header: LooprTabHeaderContent {
        LooprTabHeaderContent(
            title: "Body",
            accent: .strain,
            dayPhrase: dayNavigation.map(LooprHeaderMeta.dayPhrase) ?? headerMeta,
            freshness: .sync(lastSync: dayNavigation?.lastSyncedAt, now: dayNavigation?.now),
            status: headerStatus,
            control: dayNavigation.map { .day($0) } ?? .none
        )
    }

    /// A chip only when there is something to do about it.
    private var headerStatus: StatusChip? {
        LooprHeaderStatus.chip(for: headerState, isToday: dayNavigation?.isToday ?? true,
                                 dayIsEmpty: dayNavigation?.status == .noData, accent: .strain)
    }

    private var headerMeta: String {
        guard let day = viewModel.snapshot?.day,
              let formattedDate = day.bodyHeaderDate else {
            return "LOAD & OUTPUT"
        }
        return "\(formattedDate) · LOAD & OUTPUT"
    }
}

public struct BodyAgeScreen: View {
    @Environment(\.bodyAppleHealthVO2Max) private var appleHealthVO2Max
    public let title: String
    public let presentation: BodyAgePresentation
    public let cardioFitness: BodyCardioFitness?
    public let looprAge: LooprAgeResult?
    /// What a locked Cardio Age still needs, from `BodyAgeLock.cardio`.
    public let requirements: [BodyAgeRequirement]

    public init(
        title: String,
        presentation: BodyAgePresentation,
        cardioFitness: BodyCardioFitness? = nil,
        looprAge: LooprAgeResult? = nil,
        requirements: [BodyAgeRequirement] = []
    ) {
        self.title = title
        self.cardioFitness = cardioFitness
        // Keep persisted composite-age results behind DEC-02.12's lock.
        self.presentation = title == "Loopr Age"
            ? .unavailable(reason: "Loopr Age is still being validated.", state: .absent)
            : presentation
        self.looprAge = title == "Loopr Age" ? nil : looprAge
        self.requirements = requirements
    }

    public var body: some View {
        let shown = resolvedPresentation
        ScrollView {
            if title == "Loopr Age" {
                LooprAgeDetailContent(
                    presentation: presentation,
                    result: looprAge
                )
            } else if shown.isAvailable {
                BodyAgeCard(
                    title: title,
                    presentation: shown,
                    accent: .heart
                )
                .padding(.horizontal, LooprSpacing.screenGutter)
                .padding(.top, LooprSpacing.md)
                .padding(.bottom, LooprSpacing.tabBarClearance)
            } else {
                BodyCardioAgeLockedContent(presentation: shown, requirements: requirements)
                    .padding(.horizontal, LooprSpacing.screenGutter)
                    .padding(.top, LooprSpacing.md)
                    .padding(.bottom, LooprSpacing.tabBarClearance)
            }
        }
        .background(Color.loopr(.background).ignoresSafeArea())
        .navigationTitle(title)
        .accessibilityIdentifier(title == "Cardio Age" ? "cardio-age-screen" : "loopr-age-screen")
    }

    private var resolvedPresentation: BodyAgePresentation {
        guard title == "Cardio Age", let cardioFitness, !appleHealthVO2Max.isEmpty,
              let result = cardioFitness.resolve(appleHealth: appleHealthVO2Max, now: Date()),
              let age = result.cardioAge else { return presentation }
        return BodyDaySnapshot.cardioAgePresentation(for: age)
    }
}

private struct LooprAgeDetailContent: View {
    let presentation: BodyAgePresentation
    let result: LooprAgeResult?

    var body: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.sm) {
            LooprAgeHero(presentation: presentation, result: result)

            if let result {
                LooprAgeComparisonCard(result: result)
                LooprAgeCoverageCard(result: result)
            }

            LooprAgeMethodCard(isAvailable: presentation.isAvailable)
            LooprAgeFactorsCard(contributors: result?.contributors ?? [])
            if presentation.isAvailable {
                LooprAgeChangeCard()
            }
        }
        .padding(.bottom, LooprSpacing.tabBarClearance)
    }
}

private struct LooprAgeHero: View {
    let presentation: BodyAgePresentation
    let result: LooprAgeResult?

    var body: some View {
        SpectralLens(
            value: value,
            caption: "LOOPR AGE",
            accent: .brand,
            diameter: 184
        ) {
            VStack(spacing: LooprSpacing.xxs) {
                HStack(spacing: 6) {
                    Image(systemName: statusSymbol)
                        .font(.system(size: 12, weight: .semibold))
                        .accessibilityHidden(true)
                    Text(statusLabel.uppercased())
                        .looprTypography(.confidence)
                }
                .foregroundStyle(Color.loopr(statusColor))

                Text(summary)
                    .looprTypography(.prose)
                    .foregroundStyle(Color.loopr(.inkSecondary))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 320)
        }
        .padding(.top, 4)
        .padding(.bottom, LooprSpacing.xs)
    }

    private var value: String {
        guard case .available(let label, _, _) = presentation else { return "\u{2014}" }
        return label.replacingOccurrences(of: " years", with: "")
    }

    private var statusLabel: String {
        switch presentation {
        case .available(_, let confidence, _): confidence
        case .unavailable(_, let state): state.title
        }
    }

    private var statusSymbol: String {
        switch presentation {
        case .available: "checkmark.circle.fill"
        case .unavailable(_, let state): state.symbol
        }
    }

    private var statusColor: LooprColorToken {
        presentation.isAvailable ? .brand : .inkSecondary
    }

    private var summary: String {
        switch presentation {
        case .available:
            guard let result, let looprAge = result.looprAgeYears else {
                return "Your long-term fitness and healthspan estimate."
            }
            let difference = looprAge - result.realAgeYears
            if difference == 0 { return "In line with your chronological age." }
            let years = abs(difference)
            let unit = years == 1 ? "year" : "years"
            return "\(years) \(unit) \(difference < 0 ? "below" : "above") your chronological age."
        case .unavailable(let reason, _):
            return reason
        }
    }
}

private struct LooprAgeComparisonCard: View {
    let result: LooprAgeResult

    var body: some View {
        LooprSurface {
            VStack(alignment: .leading, spacing: LooprSpacing.md) {
                LooprText("AGE COMPARISON", style: .sectionLabel, color: .inkSecondary)
                HStack(spacing: 0) {
                    ageColumn(label: "YOUR AGE", value: "\(result.realAgeYears)")
                    Rectangle()
                        .fill(Color.loopr(.divider))
                        .frame(width: 1, height: 48)
                        .padding(.horizontal, LooprSpacing.lg)
                        .accessibilityHidden(true)
                    ageColumn(
                        label: "LOOPR AGE",
                        value: result.looprAgeYears.map(String.init) ?? "\u{2014}",
                        accent: result.looprAgeYears == nil ? .inkMuted : .brand
                    )
                }
            }
        }
        .padding(.horizontal, LooprSpacing.screenGutter)
        .accessibilityElement(children: .combine)
    }

    private func ageColumn(
        label: String,
        value: String,
        accent: LooprColorToken = .ink
    ) -> some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
            LooprText(label, style: .confidence, color: .inkSecondary)
            Text(value)
                .looprTypography(.metricValue)
                .foregroundStyle(Color.loopr(accent))
            LooprText("years", style: .metricUnit, color: .inkSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct LooprAgeCoverageCard: View {
    let result: LooprAgeResult

    var body: some View {
        LooprSurface {
            VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                LooprText("YOUR DATA", style: .sectionLabel, color: .inkSecondary)

                HStack(alignment: .firstTextBaseline) {
                    LooprText(coverageTitle, style: .cardTitle)
                    Spacer(minLength: LooprSpacing.sm)
                    LooprText(coveragePercent, style: .metricUnit, color: .brand)
                }

                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.loopr(.divider))
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [Color.loopr(.brand).opacity(0.45), Color.loopr(.brand)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: proxy.size.width * coverageFraction)
                    }
                }
                .frame(height: 5)
                .accessibilityHidden(true)

                HStack(spacing: LooprSpacing.xxs) {
                    Label(windowLabel, systemImage: "calendar")
                    Spacer(minLength: LooprSpacing.sm)
                    Label(updatedLabel, systemImage: "clock")
                }
                .looprTypography(.caption)
                .foregroundStyle(Color.loopr(.inkSecondary))
            }
        }
        .padding(.horizontal, LooprSpacing.screenGutter)
        .accessibilityElement(children: .combine)
    }

    private var coverageFraction: CGFloat {
        CGFloat(min(max(result.coverage.coverageFraction, 0), 1))
    }

    private var coverageTitle: String {
        let days = result.coverage.eligibleDays
        return days == 1 ? "1 eligible day" : "\(days) eligible days"
    }

    private var coveragePercent: String {
        "\(Int((result.coverage.coverageFraction * 100).rounded()))% coverage"
    }

    private var windowLabel: String {
        let days = max(result.coverage.windowDays, Int(result.modelWindow.duration / 86_400))
        return "\(days)-day window"
    }

    private var updatedLabel: String {
        result.generatedAt.formatted(.dateTime.month(.abbreviated).day())
    }
}

private struct LooprAgeMethodCard: View {
    let isAvailable: Bool

    var body: some View {
        LooprSurface {
            VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                LooprText("HOW IT WORKS", style: .sectionLabel, color: .inkSecondary)
                LooprText(
                    "Built from long-term data",
                    style: .cardTitle
                )
                LooprText(bodyCopy, style: .prose, color: .inkSecondary)
            }
        }
        .padding(.horizontal, LooprSpacing.screenGutter)
    }

    private var bodyCopy: String {
        if isAvailable {
            return "Loopr compares your long-term fitness and activity patterns with a reference group, then shows the difference as an age estimate."
        }
        return "Loopr Age is still being checked. Loopr will show an estimate when the model and your history meet its requirements."
    }
}

private struct LooprAgeFactorsCard: View {
    let contributors: [AgeContributor]

    var body: some View {
        LooprSurface {
            VStack(alignment: .leading, spacing: 0) {
                LooprText("WHAT SHAPES IT", style: .sectionLabel, color: .inkSecondary)
                    .padding(.bottom, LooprSpacing.xs)

                factorRow(
                    title: "Fitness",
                    detail: "Cardio fitness and resting heart rate",
                    symbol: "heart.fill",
                    kinds: [.cardioCapacity, .restingHeartRate]
                )
                divider
                factorRow(
                    title: "Movement",
                    detail: "Daily movement, aerobic work, and strength",
                    symbol: "figure.run",
                    kinds: [.dailyMovement, .lowModerateAerobicActivity, .vigorousAerobicActivity, .strengthActivity]
                )
                divider
                factorRow(
                    title: "Sleep",
                    detail: "Sleep duration and consistency",
                    symbol: "moon.fill",
                    kinds: [.sleepDuration, .sleepConsistency]
                )
                divider
                factorRow(
                    title: "Body",
                    detail: "Body composition when available",
                    symbol: "figure.arms.open",
                    kinds: [.bodyComposition]
                )
            }
        }
        .padding(.horizontal, LooprSpacing.screenGutter)
    }

    private func factorRow(
        title: String,
        detail: String,
        symbol: String,
        kinds: [AgeContributorKind]
    ) -> some View {
        HStack(spacing: LooprSpacing.sm) {
            ZStack {
                Circle()
                    .fill(Color.loopr(.brandSoft))
                    .frame(width: 34, height: 34)
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.loopr(.brand))
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                LooprText(title, style: .rowTitle)
                LooprText(detail, style: .caption, color: .inkSecondary)
            }

            Spacer(minLength: LooprSpacing.sm)

            if let status = status(for: kinds) {
                Image(systemName: status.symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.loopr(status.color))
                    .accessibilityLabel(status.label)
            }
        }
        .padding(.vertical, LooprSpacing.sm)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.loopr(.divider))
            .frame(height: 1)
            .padding(.leading, 46)
            .accessibilityHidden(true)
    }

    private func status(for kinds: [AgeContributorKind]) -> FactorStatus? {
        let matching = contributors.filter { kinds.contains($0.kind) }
        guard !matching.isEmpty else { return nil }
        if matching.allSatisfy({ if case .available = $0.availability { true } else { false } }) {
            return FactorStatus(symbol: "checkmark.circle.fill", color: .brand, label: "Data available")
        }
        return FactorStatus(symbol: "circle.dashed", color: .inkMuted, label: "More data needed")
    }

    private struct FactorStatus {
        let symbol: String
        let color: LooprColorToken
        let label: String
    }
}

private struct LooprAgeChangeCard: View {
    var body: some View {
        LooprSurface {
            HStack(alignment: .top, spacing: LooprSpacing.sm) {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Color.loopr(.brand))
                    .frame(width: 28)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                    LooprText("Why it changes", style: .cardTitle)
                    LooprText(
                        "Loopr Age follows long-term patterns and updates at most once a week. One unusual night or workout should not move it on its own.",
                        style: .prose,
                        color: .inkSecondary
                    )
                }
            }
        }
        .padding(.horizontal, LooprSpacing.screenGutter)
    }
}

/// A locked Cardio Age: what it is, what it still needs, and why Loopr
/// will not guess it.
private struct BodyCardioAgeLockedContent: View {
    let presentation: BodyAgePresentation
    let requirements: [BodyAgeRequirement]

    var body: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xl) {
            LooprSurface {
                VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                    HStack(spacing: LooprSpacing.xs) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .accessibilityHidden(true)
                        LooprText("Locked", style: .label, color: .inkSecondary)
                    }
                    .foregroundStyle(Color.loopr(.inkSecondary))
                    LooprText("Cardio Age compares your VO₂ max with people of your age and sex.", style: .cardTitle)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("It needs a VO₂ max from a workout or lab test in Apple Health. Resting heart rate alone is too rough to turn into an age.")
                        .looprTypography(.prose)
                        .foregroundStyle(Color.loopr(.inkSecondary))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)

            if !requirements.isEmpty {
                BodySection(title: "What it needs") {
                    LooprSurface {
                        BodyRowStack(rows: requirements) { requirement in
                            HStack(alignment: .top, spacing: LooprSpacing.sm) {
                                Image(systemName: requirement.isMet ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 17, weight: .medium))
                                    .foregroundStyle(Color.loopr(requirement.isMet ? LooprColorToken.brand.textInk : .inkMuted))
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 3) {
                                    LooprText(requirement.title, style: .rowTitle)
                                    Text(requirement.detail)
                                        .looprTypography(.caption)
                                        .foregroundStyle(Color.loopr(.inkSecondary))
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 0)
                            }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("\(requirement.title), \(requirement.isMet ? "done" : "still needed"). \(requirement.detail)")
                            .accessibilityIdentifier("cardio-age-requirement-\(requirement.id)")
                        }
                    }
                }
            } else if case .unavailable(let reason, _) = presentation {
                LooprText(reason, style: .prose, color: .inkSecondary)
            }
        }
    }
}

private struct BodyAgeCard: View {
    let title: String
    let presentation: BodyAgePresentation
    let accent: LooprColorToken

    var body: some View {
        LooprSurface(emphasis: .hero(accent)) {
            VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                LooprText(title, style: .cardTitle)
                switch presentation {
                case .available(let label, let confidence, let source):
                    MetricNumeral(label)
                    LooprText("\(confidence) · \(source)", style: .prose, color: .inkSecondary)
                case .unavailable(let reason, let state):
                    StateMessage(state)
                    LooprText(reason, style: .prose, color: .inkSecondary)
                }
            }
        }
    }
}

private struct BodyStateSurface: View {
    let state: MetricState

    var body: some View {
        LooprCard(style: .hero(.strain)) {
            StateMessage(state, accent: .strain)
        }
        .padding(.horizontal, LooprSpacing.screenGutter)
        .padding(.top, LooprSpacing.lg)
    }
}

/// Only the load metrics have a screen of their own. Steps and active energy
/// have nothing behind them, and sending them to `.day` pushed a second copy
/// of the screen the person was already reading.
extension BodyMetricID {
    /// The metric detail page this row opens, or nil when there is none.
    public var metricLinkID: String? {
        switch self {
        case .strain: LooprMetricLinkID.strain
        case .steps: LooprMetricLinkID.steps
        case .energy: LooprMetricLinkID.activeEnergy
        case .zones, .acuteLoad, .chronicLoad, .monotony, .fitnessFatigue, .effort: nil
        }
    }
}

private extension DayIdentity {
    var bodyHeaderDate: String? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt

        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else {
            return nil
        }

        return LooprDateFormatterCache.string(from: date, format: "EEE d MMM", calendar: calendar).uppercased()
    }
}
