import Foundation
import SwiftUI
import DesignSystem
#if DEBUG
import OSLog
#endif

/// The Ask shortcut in Today's header. It lives in the sticky header so it stays one tap away at any
/// scroll depth, on every day. Ask reads the day the person is looking at.
enum TodayHeaderShortcut {
    static let coachIdentifier = "today-header-coach"
    static let coachLabel = "Ask your coach"

    static func coach(open: @escaping @MainActor () -> Void) -> LooprHeaderAction {
        LooprHeaderAction(symbol: "sparkles", label: coachLabel, title: "Ask", identifier: coachIdentifier, run: open)
    }
}

public enum TodayRoute: Hashable, Sendable, CaseIterable {
    case sleep
    case heart
    case body
    case coach
    case stress
    case journal
    case records
    case streaks
    case journey
    case timeline
    case goalSettings
    case settings
    /// What shaped the day's recovery.
    case recoveryBreakdown
    /// Where the day's strain came from.
    case strainBreakdown
}

public struct TodayScreen: View {
    @Environment(\.bandConnected) private var bandConnected
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The shared day, when the app provides one. The header then names that
    /// day and carries the day navigator.
    @Environment(\.looprDayNavigation) private var dayNavigation
    /// The person hid "No band connected" (ICP R3-NEW-7).
    @AppStorage(TodayBandBannerPreference.hiddenKey) private var noBandHidden = false
    private let bandConnectionTitle: String
    private let bandConnectionMessage: String?
    private let bandModelName: String?
    private let bandIsExperimental: Bool
    @ObservedObject private var viewModel: TodayViewModel
    private let route: (TodayRoute) -> Void
    private let externalInsight: TodayExternalInsight?
    private let onExternalInsight: (String) -> Void
    private let showsConnectBand: Bool
    private let onConnectBand: () -> Void
    /// A card the app places under the day's content, such as the wake
    /// alarm. TodayKit does not know what it is; it only gives it a spot.
    private let accessory: AnyView?
    private let pinnedNumbers: AnyView?
    /// Rows, timeline moments and the pattern card the app reads from Food, Train, Journal and Patterns.
    private let agent: TodayAgentContent
    private let onAgentAction: (TodayAgentAction) -> Void
    /// The day dial the app read from its stores (DEC-12.3). Nil while it loads: its placeholder holds the place.
    private let dial: TodayDialContent?
    /// What sits under the dial: the coach note, the protocol rail and the experiment strip (LV-04 step 3).
    private let dialCompanion: AnyView?
    /// The experiment strip, under "More from today".
    private let dialCompanionMore: AnyView?

    public init(
        viewModel: TodayViewModel,
        route: @escaping (TodayRoute) -> Void = { _ in },
        externalInsight: TodayExternalInsight? = nil,
        onExternalInsight: @escaping (String) -> Void = { _ in },
        showsConnectBand: Bool = false,
        bandConnectionMessage: String? = nil,
        bandConnectionTitle: String = "Band not connected",
        bandModelName: String? = nil,
        bandIsExperimental: Bool = false,
        onConnectBand: @escaping () -> Void = {},
        accessory: AnyView? = nil,
        pinnedNumbers: AnyView? = nil,
        agent: TodayAgentContent = .empty,
        onAgentAction: @escaping (TodayAgentAction) -> Void = { _ in },
        dial: TodayDialContent? = nil,
        dialCompanion: AnyView? = nil,
        dialCompanionMore: AnyView? = nil
    ) {
        self.bandConnectionTitle = bandConnectionTitle
        self.bandConnectionMessage = bandConnectionMessage
        self.bandModelName = bandModelName
        self.bandIsExperimental = bandIsExperimental
        self.viewModel = viewModel
        self.route = route
        self.externalInsight = externalInsight
        self.onExternalInsight = onExternalInsight
        self.showsConnectBand = showsConnectBand
        self.onConnectBand = onConnectBand
        self.accessory = accessory
        self.pinnedNumbers = pinnedNumbers
        self.agent = agent
        self.onAgentAction = onAgentAction
        self.dial = dial
        self.dialCompanion = dialCompanion
        self.dialCompanionMore = dialCompanionMore
    }

    public var body: some View {
        // Today always stands on its own field, loading or not, so the first frame is already the dial's page.
        LooprTabScaffold(header: header, glow: glow, field: .today, identifier: "today-screen") {
            VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                bandBanner
                if let bandModelName, !showsConnectBand {
                    HStack(spacing: LooprSpacing.xs) {
                        LooprText(bandModelName, style: .caption, color: .inkSecondary)
                        if bandIsExperimental {
                            LooprText("Experimental", style: .caption, color: .inkSecondary)
                        }
                    }
                    .padding(.horizontal, LooprSpacing.screenGutter)
                    .padding(.top, LooprSpacing.xs)
                    .transition(bannerTransition)
                    .accessibilityIdentifier("today-band-model")
                }

                LooprPhaseContainer(phase: phase) {
                    phaseContent
                }

                if let accessory, !isLoading, viewModel.summary == nil {
                    accessory
                        .padding(.horizontal, LooprSpacing.screenGutter)
                }
            }
            // The band row slides in and out instead of shoving the hero.
            .animation(LooprMotion.stateChange, value: bannerKind)
            // At the largest text sizes a prompt chip or a readout has an ideal width past the screen. Without this it
            // widens the whole vertical scroll view and the header, so every card runs off both edges (as 91903334 fixed
            // on the metric pages).
            .containerRelativeFrame(.horizontal)
            // Meals and workouts fly their dots onto the dial.
            .looprDotFlightHost()
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: LooprTabHeaderContent {
        LooprTabHeaderContent(
            title: "Today",
            accent: .brand,
            dayPhrase: dayNavigation.map(LooprHeaderMeta.dayPhrase)
                ?? viewModel.summary.flatMap { TodayHeaderFormatting.dayLabel(for: $0.day)?.looprLabelCased },
            freshness: .sync(
                lastSync: dayNavigation?.lastSyncedAt ?? viewModel.summary?.freshness.updatedAt,
                now: dayNavigation?.now
            ),
            status: headerStatus,
            control: dayNavigation.map { .day($0) } ?? .none,
            secondaryAction: TodayHeaderShortcut.coach { route(.coach) },
            settingsFallback: { route(.settings) }
        )
    }

    /// The recovery colour of the day, held while the next day loads so the
    /// glow never flashes back to teal in between.
    private var glow: LooprColorToken? {
        if phase == .loading { return nil }
        return viewModel.dashboard(isToday: dayNavigation?.isToday ?? true)?.hero.reading?.band.token ?? .brand
    }

    private enum Phase: Hashable {
        case loading
        case emptyDay
        case content
        case failed
        case empty
    }

    private var phase: Phase {
        if isAwaitingData || dayNavigation?.isResolving == true { return .loading }
        if let dayNavigation, dayNavigation.status == .noData, !isFailed { return .emptyDay }
        if viewModel.summary != nil, viewModel.dashboard(isToday: dayNavigation?.isToday ?? true) != nil { return .content }
        if isFailed { return .failed }
        return dayNavigation == nil ? .empty : .emptyDay
    }

    @ViewBuilder
    private var phaseContent: some View {
        switch phase {
        case .loading:
            // The dial's own frame in the dial's place, then the cards, so the page keeps its shape (ICP R3-PAS-1).
            VStack(alignment: .leading, spacing: 0) {
                TodayDialPlaceholder()
                    .padding(.top, LooprSpacing.xs)
                LooprLoadingPlaceholder(.cards(2))
            }
        case .emptyDay:
            if let dayNavigation {
                // A day with nothing derived reads as one plain card, not a
                // page of empty rings and rows. What the person logged follows it.
                VStack(alignment: .leading, spacing: 0) {
                    // First run already shows the one teaching card above; a second "nothing yet" card under it said
                    // the same thing again (UX R1-DES-12).
                    if bannerKind != .invitation {
                        LooprDayEmptyState(dayNavigation, accent: .brand, context: .logsBelow)
                            .padding(.horizontal, LooprSpacing.screenGutter)
                            .padding(.top, LooprSpacing.lg)
                    }
                    TodayManualDayContent(agent: agent, route: route, onAgentAction: onAgentAction, dial: dial,
                                          dialCompanion: dialCompanion, dialCompanionMore: dialCompanionMore)
                }
            }
        case .content:
            if let summary = viewModel.summary,
               let dashboard = viewModel.dashboard(isToday: dayNavigation?.isToday ?? true) {
                TodayDashboardContent(
                    summary: summary,
                    dashboard: dashboard,
                    route: route,
                    agent: agent,
                    onAgentAction: onAgentAction,
                    externalInsight: externalInsight,
                    onExternalInsight: onExternalInsight,
                    pinnedNumbers: pinnedNumbers,
                    dial: dial,
                    dialCompanion: dialCompanion,
                    dialCompanionMore: dialCompanionMore
                )
            }
        case .failed:
            LooprCard { StateMessage(.recoverableError) }
                .padding(.horizontal, LooprSpacing.screenGutter)
                .padding(.top, LooprSpacing.lg)
        case .empty:
            VStack(alignment: .leading, spacing: 0) {
                if bannerKind != .invitation {
                    LooprCard { TodayEmptyState() }
                        .padding(.horizontal, LooprSpacing.screenGutter)
                        .padding(.top, LooprSpacing.lg)
                }
                TodayManualDayContent(agent: agent, route: route, onAgentAction: onAgentAction, dial: dial,
                                          dialCompanion: dialCompanion, dialCompanionMore: dialCompanionMore)
            }
        }
    }

    private enum BannerKind: Hashable { case none, invitation, noBand, connection }

    private var bannerKind: BannerKind {
        // An empty today without a band gets the one card with its two buttons, history or not; a slim row over a
        // "nothing yet" card said the same thing twice with no button (UX R2-NEW-01, R2-DES-17).
        if showsConnectBand {
            if !hasHistory || (isEmptyToday && !noBandHidden) { return .invitation }
            return noBandHidden ? .none : .noBand
        }
        if bandConnectionMessage != nil, !bandConnected { return .connection }
        return .none
    }

    private var bannerTransition: AnyTransition {
        LooprMotion.reducesMotion(reduceMotion) ? .opacity : .move(edge: .top).combined(with: .opacity)
    }

    /// First run with no band and no history gets the full invitation. Anyone
    /// with history gets one slim line, so their numbers stay on top.
    @ViewBuilder
    private var bandBanner: some View {
        if bannerKind == .invitation {
            TodayConnectBandCard(action: onConnectBand, logMeal: { onAgentAction(.yourDayRow("food")) })
                .transition(bannerTransition)
        } else if showsConnectBand, !noBandHidden {
            TodayBandStatusRow(
                title: "No band connected",
                detail: "Connect it to sync your nights.",
                actionTitle: "Connect band",
                actionIdentifier: "today-connect-band",
                statusIdentifier: "today-band-status",
                action: onConnectBand,
                hide: { withAnimation(LooprMotion.reducesMotion(reduceMotion) ? nil : LooprMotion.stateChange) { noBandHidden = true } }
            )
            .padding(.horizontal, LooprSpacing.screenGutter)
            .padding(.top, LooprSpacing.sm)
            .transition(bannerTransition)
        } else if let bandConnectionMessage, !bandConnected {
            TodayBandStatusRow(
                title: bandConnectionTitle,
                detail: bandConnectionMessage,
                actionTitle: "View",
                actionIdentifier: "today-band-connection-open",
                statusIdentifier: "today-band-connection",
                action: { route(.settings) }
            )
            .padding(.horizontal, LooprSpacing.screenGutter)
            .padding(.top, LooprSpacing.sm)
            .transition(bannerTransition)
        }
    }

    /// Today, with nothing derived for it.
    private var isEmptyToday: Bool {
        (dayNavigation?.isToday ?? true) && (phase == .emptyDay || phase == .empty)
    }

    /// Band history exists when any day has data, or this day has a summary.
    private var hasHistory: Bool {
        dayNavigation?.latestDayWithData != nil || viewModel.summary != nil
    }

    private var isLoading: Bool {
        if case .loading = viewModel.loadState { return true }
        return false
    }

    /// Before the first load starts the state is `.idle`. Showing the empty
    /// state there flashed "no records" for a frame on every launch.
    private var isAwaitingData: Bool {
        isLoading || (viewModel.loadState == .idle && viewModel.summary == nil)
    }

    private var isFailed: Bool {
        if case .failed = viewModel.loadState { return true }
        return false
    }

    /// A chip only when there is something to do: a failed read, or today's
    /// numbers going out of date. "Partial data" beside a card that already
    /// says what is missing told nobody anything.
    private var headerStatus: StatusChip? {
        let state: MetricState? = if isFailed {
            .recoverableError
        } else if viewModel.summary?.freshness.state == .stale {
            .stale
        } else {
            viewModel.summary?.overallState
        }
        return LooprHeaderStatus.chip(for: state, isToday: dayNavigation?.isToday ?? true,
                                 dayIsEmpty: dayNavigation?.status == .noData, accent: .brand)
    }
}

/// First run without a band: what a band adds, what works without one, and the two first steps. Pairing is offered,
/// never demanded (R1-NEW-2).
enum TodayNoBandCopy {
    static let label = "Start with a meal or a workout"
    static let body = "Whatever you log shows up here. Sleep and recovery need a WHOOP 4.0 band and appear after its first night."
    static let logMeal = "Log a meal"
    static let connect = "Connect a band"
}

private struct TodayConnectBandCard: View {
    let action: () -> Void
    let logMeal: () -> Void
    #if DEBUG
    private let pairingLogger = Logger(subsystem: "com.loopr.ios", category: "pairing")
    #endif

    var body: some View {
        LooprCard {
            VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                LooprText(TodayNoBandCopy.label, style: .title, color: .ink)
                    .accessibilityAddTraits(.isHeader)
                LooprText(TodayNoBandCopy.body, style: .prose, color: .inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: logMeal) {
                    Label(TodayNoBandCopy.logMeal, systemImage: "fork.knife")
                }
                .buttonStyle(LooprButtonStyle())
                .accessibilityIdentifier("today-no-band-log-meal")
                Button {
                    #if DEBUG
                    pairingLogger.debug("Today Connect button tapped")
                    #endif
                    action()
                } label: {
                    Label(TodayNoBandCopy.connect, systemImage: "antenna.radiowaves.left.and.right")
                }
                .buttonStyle(LooprButtonStyle(prominent: false))
                .accessibilityIdentifier("today-connect-band")
            }
        }
        .padding(.horizontal, LooprSpacing.screenGutter)
        .padding(.top, LooprSpacing.lg)
    }
}

private struct TodayEmptyState: View {
    var body: some View {
        StateMessage(.noRecords)
            .padding(LooprSpacing.md)
    }
}
