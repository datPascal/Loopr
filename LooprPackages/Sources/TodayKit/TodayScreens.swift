import Foundation
import SwiftUI
import DesignSystem
#if DEBUG
import OSLog
#endif

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
    @State private var isEditingNumbers = false
    /// One tap when the pinned numbers are saved or a heads-up is put away.
    @State private var haptic: LooprHaptic?

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
        accessory: AnyView? = nil
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
    }

    public var body: some View {
        LooprTabScaffold(header: header, glow: glow, identifier: "today-screen") {
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
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isEditingNumbers) {
            TodayEditNumbersSheet(pinned: viewModel.preferences.pinned) { pinned in
                if pinned != viewModel.preferences.pinned { haptic = .success }
                withAnimation(LooprMotion.phaseChange(reduceMotion: reduceMotion)) {
                    viewModel.setPinned(pinned)
                }
            }
        }
        .looprHaptic(haptic)
    }

    private var header: LooprTabHeaderContent {
        LooprTabHeaderContent(
            title: "Today",
            accent: .brand,
            dayPhrase: dayNavigation.map(LooprHeaderMeta.dayPhrase)
                ?? viewModel.summary.flatMap { TodayHeaderFormatting.dayLabel(for: $0.day)?.uppercased() },
            freshness: .sync(
                lastSync: dayNavigation?.lastSyncedAt ?? viewModel.summary?.freshness.updatedAt,
                now: dayNavigation?.now
            ),
            status: headerStatus,
            control: dayNavigation.map { .day($0) } ?? .none,
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
            LooprLoadingPlaceholder(.ringHero(cards: 2))
        case .emptyDay:
            if let dayNavigation {
                // A day with nothing derived reads as one plain card, not a
                // page of empty rings and rows.
                LooprDayEmptyState(dayNavigation, accent: .brand)
                    .padding(.horizontal, LooprSpacing.screenGutter)
                    .padding(.top, LooprSpacing.lg)
            }
        case .content:
            if let summary = viewModel.summary,
               let dashboard = viewModel.dashboard(isToday: dayNavigation?.isToday ?? true) {
                TodayDashboardContent(
                    summary: summary,
                    dashboard: dashboard,
                    route: route,
                    externalInsight: externalInsight,
                    onExternalInsight: onExternalInsight,
                    accessory: isLoading ? nil : accessory,
                    onDismissHeadsUp: {
                        haptic = .light
                        withAnimation(.easeOut(duration: LooprMotion.standard)) {
                            viewModel.dismissHeadsUp(for: summary.day)
                        }
                    },
                    onEditNumbers: { isEditingNumbers = true }
                )
            }
        case .failed:
            LooprCard { StateMessage(.recoverableError) }
                .padding(.horizontal, LooprSpacing.screenGutter)
                .padding(.top, LooprSpacing.lg)
        case .empty:
            LooprCard { TodayEmptyState() }
                .padding(.horizontal, LooprSpacing.screenGutter)
                .padding(.top, LooprSpacing.lg)
        }
    }

    private enum BannerKind: Hashable { case none, invitation, noBand, connection }

    private var bannerKind: BannerKind {
        if showsConnectBand { return hasHistory ? .noBand : .invitation }
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
        if showsConnectBand, !hasHistory {
            TodayConnectBandCard(action: onConnectBand)
                .transition(bannerTransition)
        } else if showsConnectBand {
            TodayBandStatusRow(
                title: "No band connected",
                detail: "Connect to sync new nights.",
                actionTitle: "Connect",
                actionIdentifier: "today-connect-band",
                statusIdentifier: "today-band-status",
                action: onConnectBand
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

private struct TodayConnectBandCard: View {
    let action: () -> Void
    #if DEBUG
    private let pairingLogger = Logger(subsystem: "com.loopr.ios", category: "pairing")
    #endif

    var body: some View {
        LooprCard {
            VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                LooprText("CONNECT YOUR BAND", style: .sectionLabel, color: .brand)
                LooprText(
                    "Pair your band to start syncing health and activity data.",
                    style: .prose,
                    color: .inkSecondary
                )
                Button {
                    #if DEBUG
                    pairingLogger.debug("Today Connect button tapped")
                    #endif
                    action()
                } label: {
                    Label("Connect band", systemImage: "antenna.radiowaves.left.and.right")
                }
                .buttonStyle(LooprButtonStyle())
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

/// Goal editing stays beside the Today projection.  The app may inject a
/// durable save closure, while this package-owned view remains usable in the
/// fixture composition and never mutates the metric summary itself.
public struct TodayGoalSettingsScreen: View {
    public let initialStepGoal: Int?
    public let initialStrainTarget: Double?
    public let onSave: (Int?, Double?) -> Void

    @State private var stepGoal: String
    @State private var strainTarget: String

    public init(
        initialStepGoal: Int? = 10_000,
        initialStrainTarget: Double? = 10,
        onSave: @escaping (Int?, Double?) -> Void = { _, _ in }
    ) {
        self.initialStepGoal = initialStepGoal
        self.initialStrainTarget = initialStrainTarget
        self.onSave = onSave
        _stepGoal = State(initialValue: initialStepGoal.map(String.init) ?? "")
        _strainTarget = State(initialValue: initialStrainTarget.map { String($0) } ?? "")
    }

    public var body: some View {
        Form {
            Section("Daily goals") {
                TextField("Estimated steps", text: $stepGoal)
                    .keyboardType(.numberPad)
                    .accessibilityIdentifier("goal-step-input")
                TextField("Strain target", text: $strainTarget)
                    .keyboardType(.decimalPad)
                    .accessibilityIdentifier("goal-strain-input")
            }
            Section {
                Button("Save goals") {
                    onSave(Int(stepGoal), Double(strainTarget))
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity, minHeight: 44)
                .accessibilityIdentifier("goal-save")
            } footer: {
                Text("Goals are personal targets, not medical recommendations. Missing values remain unset.")
            }
        }
        .navigationTitle("Goal Settings")
        .accessibilityIdentifier("goal-settings-screen")
    }
}
