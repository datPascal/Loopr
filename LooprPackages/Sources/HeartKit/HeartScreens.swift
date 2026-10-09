import SwiftUI
import DesignSystem

public enum HeartRoute: Hashable, Sendable, CaseIterable {
    case live
    case detail
    case trends
    case spotCheck
    case stress
}

public struct HeartScreen: View {
    @Environment(\.bandConnected) private var bandConnected
    /// The shared day, when the app provides one. The header then names that
    /// day and carries the day navigator.
    @Environment(\.looprDayNavigation) private var dayNavigation
    @Environment(\.heartTabServices) private var services
    private let viewModel: HeartViewModel
    @StateObject private var dayState: HeartDayPresentation
    @StateObject private var tabModel = HeartTabModel()
    /// Bumped when the day's snapshot changes, so the timeline reloads with it.
    @State private var snapshotRevision = 0
    @State private var advancedExpanded = false
    private let route: (HeartRoute) -> Void

    public init(viewModel: HeartViewModel, route: @escaping (HeartRoute) -> Void = { _ in }) {
        self.viewModel = viewModel
        _dayState = StateObject(wrappedValue: HeartDayPresentation(model: viewModel))
        self.route = route
    }

    public var body: some View {
        LooprTabScaffold(header: header, glow: .heart, identifier: "heart-screen") {
            VStack(alignment: .leading, spacing: 0) {
                HeartLiveTabSection(model: viewModel, zones: services?.zones,
                                    storedReading: tabModel.lastReading, bandConnected: bandConnected,
                                    pinnedNow: dayNavigation?.now, open: { route(.live) })
                    .padding(.horizontal, LooprSpacing.screenGutter)
                    .padding(.top, LooprSpacing.tabContentTop)
                LooprPhaseContainer(phase: phase) {
                    VStack(alignment: .leading, spacing: 0) {
                        phaseContent
                    }
                }
            }
        }
        .navigationTitle("")
        .task(id: tabLoadKey) {
            guard let day = selectedDay, dayNavigation?.isResolving != true else { return }
            await tabModel.load(day: day, snapshot: dayState.snapshot, services: services)
        }
        .onChange(of: dayState.snapshot) { _, snapshot in
            tabModel.snapshotChanged(snapshot)
            snapshotRevision += 1
        }
    }

    private var phase: LooprLoadPhase {
        if dayNavigation?.isResolving == true { return .loading }
        switch dayState.loadState {
        case .idle: return dayNavigation != nil ? .loading : .empty
        case .loading: return .loading
        case .failed: return .failed
        case .loaded, .live: return dayNavigation?.status == .noData ? .empty : .content
        }
    }

    @ViewBuilder
    private var phaseContent: some View {
        switch phase {
        case .loading:
            LooprLoadingPlaceholder(.cards(3))
                .padding(.top, LooprSpacing.xs)
        case .empty:
            if let dayNavigation, dayNavigation.status == .noData {
                // A day with nothing derived reads as one plain card, not a
                // list of empty rows. The live card above stays.
                VStack(alignment: .leading, spacing: LooprSpacing.lg) {
                    LooprDayEmptyState(dayNavigation, accent: .heart)
                    // A spot check measures now, so it stays on an empty today.
                    if dayNavigation.isToday {
                        navigationGroup()
                    }
                }
                .padding(.horizontal, LooprSpacing.screenGutter)
                .padding(.top, LooprSpacing.lg)
            } else {
                LooprCard { StateMessage(.noRecords, accent: .heart) }
                    .padding(.horizontal, LooprSpacing.screenGutter)
                    .padding(.top, LooprSpacing.lg)
            }
        case .failed:
            LooprCard { StateMessage(.recoverableError) }
                .padding(.horizontal, LooprSpacing.screenGutter)
                .padding(.top, LooprSpacing.lg)
        case .content:
            content
        }
    }

    /// The day the tab shows: the shared day, or the snapshot's day when the
    /// app provides no navigation (previews, older hosts).
    private var selectedDay: LooprDay? {
        if let dayNavigation { return dayNavigation.day }
        return dayState.snapshot.map { LooprDay(year: $0.day.year, month: $0.day.month, day: $0.day.day) }
    }

    private var tabLoadKey: HeartTabLoadKey {
        HeartTabLoadKey(day: selectedDay, revision: snapshotRevision, resolving: dayNavigation?.isResolving == true,
                        hasServices: services != nil, servicesRevision: services?.revision ?? 0)
    }

    @ViewBuilder
    private var content: some View {
        if let snapshot = dayState.snapshot {
            VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                HeartOvernightSection(snapshot: snapshot, title: nightTitle)
                    .padding(.horizontal, LooprSpacing.screenGutter)
                    .padding(.top, LooprSpacing.md)

                if tabModel.timeline != .unavailable {
                    LooprSectionHeader("Heart rate through the day", detail: dayDetail)
                        .padding(.horizontal, LooprSpacing.screenGutter)
                        .padding(.top, LooprSpacing.md)
                    HeartDayTimelineCard(state: tabModel.timeline, dayPhrase: dayPhrase)
                        .padding(.horizontal, LooprSpacing.screenGutter)
                }

                DisclosureGroup(isExpanded: $advancedExpanded) {
                    HeartAdvancedSection(snapshot: snapshot)
                        .padding(.top, LooprSpacing.sm)
                } label: {
                    LooprText("Advanced", style: .rowTitle)
                }
                .tint(Color.loopr(.heart))
                .padding(.horizontal, LooprSpacing.screenGutter)
                .padding(.top, LooprSpacing.md)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("heart-advanced-disclosure")

                navigationGroup()
                    .padding(.horizontal, LooprSpacing.screenGutter)
                    .padding(.top, LooprSpacing.md)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: LooprSpacing.lg) {
                StateMessage(.noRecords)
                navigationGroup()
            }
            .padding(.horizontal, LooprSpacing.screenGutter)
            .padding(.top, LooprSpacing.lg)
        }
    }

    /// "Last night" for today, "Tue 22 → Wed 23 Sep" for an earlier night.
    private var nightTitle: String {
        dayNavigation?.nightTitle ?? "Last night"
    }

    /// "Wed 23 Sep" under the heart-rate eyebrow.
    private var dayDetail: String? {
        guard let dayNavigation else { return nil }
        return dayNavigation.isToday ? "Today so far" : dayNavigation.dateText
    }

    /// Finishes "No heart rate recorded …".
    private var dayPhrase: String {
        guard let dayNavigation else { return "on this day" }
        if dayNavigation.isToday { return "today yet" }
        return dayNavigation.title == "Yesterday" ? "yesterday" : "on \(dayNavigation.dateText)"
    }

    /// Stress and a spot check, without a second home for metric history.
    private func navigationGroup() -> some View {
        var rows: [HeartNavigationItem] = []
        rows.append(HeartNavigationItem(title: "Stress", subtitle: "See stress through the day",
                                        route: .stress, identifier: "heart-stress-route"))
        rows.append(HeartNavigationItem(title: "60-second spot check", subtitle: "Measure heart rate and HRV now",
                                        route: .spotCheck, identifier: "heart-spot-check-route"))
        return HeartNavigationGroup(items: rows, route: route)
    }

    private var headerState: MetricState {
        switch dayState.loadState {
        case .idle:
            .noRecords
        case .loading:
            .loading
        case .failed:
            .recoverableError
        case .loaded, .live:
            dayState.snapshot?.state ?? .noRecords
        }
    }

    private var header: LooprTabHeaderContent {
        LooprTabHeaderContent(
            title: "Heart",
            accent: .heart,
            dayPhrase: dayNavigation.map(LooprHeaderMeta.dayPhrase) ?? headerMeta,
            freshness: dayState.loadState == .live
                ? .live
                : .sync(lastSync: dayNavigation?.lastSyncedAt, now: dayNavigation?.now),
            status: headerStatus,
            control: dayNavigation.map { .day($0) } ?? .none
        )
    }

    /// A chip only when there is something to do about it.
    private var headerStatus: StatusChip? {
        LooprHeaderStatus.chip(for: headerState, isToday: dayNavigation?.isToday ?? true,
                                 dayIsEmpty: dayNavigation?.status == .noData, accent: .heart)
    }

    /// Without a shared day (previews), the day the snapshot covers.
    private var headerMeta: String? {
        guard let day = dayState.snapshot?.day else { return nil }
        let today = LooprDay(date: Date(), calendar: .autoupdatingCurrent)
        let shown = LooprDay(year: day.year, month: day.month, day: day.day)
        return LooprDayLabel.date(for: shown, today: today, calendar: .autoupdatingCurrent).uppercased()
    }

}

struct HeartTabLoadKey: Hashable {
    let day: LooprDay?
    let revision: Int
    let resolving: Bool
    let hasServices: Bool
    let servicesRevision: Int
}

/// Heart's cards draw through `LooprCard`. `padded: false` is for a card
/// whose rows set their own insets.
private struct HeartSpectralCard<Content: View>: View {
    private let content: Content
    private let padded: Bool

    init(padded: Bool = true, @ViewBuilder content: () -> Content) {
        self.padded = padded
        self.content = content()
    }

    var body: some View {
        LooprCard(density: padded ? .regular : .flush) { content }
    }
}

struct HeartNavigationItem: Identifiable {
    let title: String
    let subtitle: String
    let route: HeartRoute
    let identifier: String
    var id: String { identifier }
}

/// Grouped rows that open the Heart sub-screens, one chevron each.
private struct HeartNavigationGroup: View {
    let items: [HeartNavigationItem]
    let route: (HeartRoute) -> Void

    var body: some View {
        HeartSpectralCard(padded: false) {
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    Button { route(item.route) } label: {
                        HStack(alignment: .center, spacing: LooprSpacing.sm) {
                            VStack(alignment: .leading, spacing: 2) {
                                LooprText(item.title, style: .rowTitle)
                                LooprText(item.subtitle, style: .caption, color: .inkSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .layoutPriority(1)
                            Spacer(minLength: LooprSpacing.sm)
                            LooprChevron()
                        }
                        .padding(.vertical, LooprSpacing.sm)
                        .frame(minHeight: 56)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.looprPressableRow)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(item.title), \(item.subtitle)")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityIdentifier(item.identifier)
                    if index < items.count - 1 {
                        Rectangle()
                            .fill(Color.loopr(.divider))
                            .frame(height: 1)
                            .accessibilityHidden(true)
                    }
                }
            }
            .padding(.horizontal, 17)
        }
    }
}

public struct HeartSpotCheckScreen: View {
    @ObservedObject private var viewModel: HeartViewModel
    @State private var runTask: Task<Void, Never>?
    public init(viewModel: HeartViewModel) { self.viewModel = viewModel }
    public var body: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.lg) {
            if let result = viewModel.spotCheck {
                MetricCard(title: "Spot-check heart rate", value: result.heartRateBPM.map { "\(Int($0.rounded()))" }, unit: "bpm", state: result.state, accent: .heart)
                MetricCard(title: "Spot-check SDNN", value: result.sdnnMilliseconds.map { "\(Int($0.rounded()))" }, unit: "ms", state: result.state, accent: .heart)
                if let detail = result.qualityDetail { LooprText(detail, color: .inkSecondary) }
                if result.resolvedAvailability == .insufficientQuality {
                    StateMessage(.lowConfidence)
                        .accessibilityIdentifier("heart-spot-check-insufficient-quality")
                }
            } else {
                StateMessage(.absent)
            }
            Button("Start spot check") {
                runTask?.cancel()
                runTask = Task { await viewModel.runSpotCheck() }
            }
                .buttonStyle(LooprButtonStyle())
                .accessibilityIdentifier("heart-spot-check-start")
        }
        .padding(LooprSpacing.screenGutter)
        .navigationTitle("Spot check")
        .accessibilityIdentifier("heart-spot-check-screen")
        .onDisappear {
            runTask?.cancel()
            runTask = nil
        }
    }
}

public struct HeartLiveScreen: View {
    public let samples: [HeartLiveSample]
    public let stats: HeartLiveSessionStats
    public let state: MetricState
    public init(samples: [HeartLiveSample], stats: HeartLiveSessionStats = HeartLiveSessionStats(), state: MetricState) {
        self.samples = samples; self.stats = stats; self.state = state
    }

    public var body: some View {
        HeartLiveExperience(samples: samples, stats: stats)
    }
}

public struct HeartDetailScreen: View {
    public let snapshot: HeartDaySnapshot
    public let title: String
    public init(snapshot: HeartDaySnapshot, title: String = "Advanced") { self.snapshot = snapshot; self.title = title }

    public var body: some View {
        ScrollView {
            HeartAdvancedSection(snapshot: snapshot)
                .padding(.horizontal, LooprSpacing.screenGutter)
                .padding(.bottom, LooprSpacing.tabBarClearance)
        }
        .background(Color.loopr(.background).ignoresSafeArea())
        .navigationTitle(title)
        .accessibilityIdentifier("heart-detail-screen")
    }

    static func isTrendsTitle(_ title: String) -> Bool {
        title.caseInsensitiveCompare("Heart trends") == .orderedSame
    }
}

/// Compatibility destination for existing deep links. History has one home.
public struct HeartTrendsScreen: View {
    public let snapshot: HeartDaySnapshot
    @Environment(\.looprMetricLink) private var metricLink
    public init(snapshot: HeartDaySnapshot) { self.snapshot = snapshot }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                LooprText("Choose a metric to see its history and usual range.", style: .prose, color: .inkSecondary)
                HeartOvernightSection(snapshot: snapshot, title: "Overnight readings")
            }
            .padding(.horizontal, LooprSpacing.screenGutter)
            .padding(.bottom, LooprSpacing.tabBarClearance)
        }
        .background(Color.loopr(.background).ignoresSafeArea())
        .navigationTitle("Metric history")
        .accessibilityIdentifier("heart-trends-screen")
    }
}
