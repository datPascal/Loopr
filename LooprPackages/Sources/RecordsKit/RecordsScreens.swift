import Combine
import Foundation
import SwiftUI
import DesignSystem

public enum RecordsRoute: Hashable, Sendable, CaseIterable {
    case records
    case streaks
    case journey
    case timeline
    case recap
    case sharePreview
}

public enum RecordsScreenStateFixtures {
    public static let allStates = MetricState.allCases
    public static let accessibilityIdentifiers = ["records-screen", "records-timeline", "records-share-preview"]
    public static let statesByScreen = Dictionary(uniqueKeysWithValues: accessibilityIdentifiers.map { ($0, allStates) })
    public static func accessibilitySummary(for state: MetricState) -> String { "\(state.title). \(state.detail)" }
}

@MainActor
public final class RecordsViewModel: ObservableObject {
    @Published public private(set) var snapshot: RecordsScreenSnapshot
    @Published public private(set) var records: [PersonalRecord] = []
    @Published public private(set) var streak: Streak?
    @Published public private(set) var journey: JourneySummary?
    @Published public private(set) var recap: Recap?
    private let repository: (any RecordsStore)?

    public init(repository: (any RecordsStore)? = nil) {
        self.repository = repository
        snapshot = RecordsScreenSnapshot(state: .loading)
    }

    public func load(now: Date = Date()) async {
        guard let repository else {
            snapshot = RecordsScreenSnapshot(state: .empty)
            return
        }
        records = await repository.personalRecords()
        snapshot = RecordsScreenSnapshot(state: records.isEmpty ? .empty : .populated, timeline: await repository.timeline())
        let calendar = Calendar.autoupdatingCurrent
        let endDay = LocalDayNavigator.dayString(for: now, calendar: calendar)
        let startDay = LocalDayNavigator.dayString(for: LocalDayNavigator.addingDays(-6, to: now, calendar: calendar), calendar: calendar)
        if let metric = (await repository.metrics()).first?.metric {
            streak = await repository.streak(metric: metric, qualifying: { $0.value > 0 }, calendar: calendar, now: now)
        } else {
            streak = nil
        }
        journey = await repository.journey(startDay: startDay, endDay: endDay)
        recap = await repository.recap(period: .week, startDay: startDay, endDay: endDay)
    }
}

public enum RecordsFixtures {
    public static let correctionEvent = TimelineEvent(kind: .notableChange, day: "2026-08-18", title: "Metric corrected", sourceID: "fixture-correction", correctionProvenance: "reanalysis-v2")
}

public struct RecordsScreen: View {
    @ObservedObject private var viewModel: RecordsViewModel
    private let route: (RecordsRoute) -> Void

    public init(viewModel: RecordsViewModel, route: @escaping (RecordsRoute) -> Void = { _ in }) {
        self.viewModel = viewModel
        self.route = route
    }

    public var body: some View {
        VStack(spacing: LooprSpacing.none) {
            StickyHeader(
                title: "Records",
                meta: "PERSONAL BESTS",
                status: headerStatus
            )
            // Both screens sit in a navigation stack, so the header joins
            // the system bar instead of drawing a second bar under it.
            .looprHeaderInNavigationBar()
            .zIndex(1)

            ScrollView {
                screenContent
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, LooprSpacing.screenGutter)
                    .padding(.top, LooprSpacing.lg)
                    .padding(.bottom, LooprSpacing.tabBarClearance)
            }
            .scrollIndicators(.hidden)
            .accessibilityIdentifier("records-screen")
        }
        .background(Color.loopr(.background).ignoresSafeArea())
        .navigationTitle("")
    }

    @ViewBuilder
    private var screenContent: some View {
        switch viewModel.snapshot.state {
        case .loading:
            loadingContent
        case .empty, .noRecords:
            stateContent(.noRecords)
        case .populated:
            populated
        default:
            stateContent(viewModel.snapshot.state.metricState)
        }
    }

    private var headerStatus: StatusChip {
        switch viewModel.snapshot.state {
        case .populated:
            return StatusChip(
                recordsCountLabel,
                symbol: "checkmark.circle",
                accent: .brand
            )
        default:
            let state = viewModel.snapshot.state.metricState
            return StatusChip(state.title, symbol: state.symbol, accent: .brand)
        }
    }

    private var recordsCountLabel: String {
        let count = viewModel.records.count
        return "\(count) \(count == 1 ? "record" : "records")"
    }

    private var loadingContent: some View {
        LooprSectionGroup(title: "Personal records") {
            LooprSurface(emphasis: .hero(.brand)) {
                VStack(alignment: .leading, spacing: LooprSpacing.md) {
                    StateMessage(.loading)
                    LooprSkeleton(height: LooprSpacing.formButtonHeight)
                    LooprSkeleton(height: LooprSpacing.formButtonHeight)
                }
            }
        }
    }

    private func stateContent(_ state: MetricState) -> some View {
        LooprSectionGroup(title: "Personal records") {
            LooprSurface(emphasis: .hero(.brand)) {
                StateMessage(state)
            }
        }
    }

    private var populated: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.lg) {
            if viewModel.records.isEmpty {
                stateContent(.noRecords)
            } else {
                LooprSectionGroup(title: "Personal records") {
                    RecordsRecordMetricList(records: viewModel.records)
                }

                LooprMenuGroup(
                    title: "Explore",
                    rows: [
                        LooprMenuItem(
                            title: "Timeline",
                            value: "Committed events",
                            accessibilityIdentifier: "records-timeline",
                            action: { route(.timeline) }
                        ),
                        LooprMenuItem(
                            title: "Share preview",
                            value: "Off by default",
                            accessibilityIdentifier: "records-share-preview",
                            action: { route(.sharePreview) }
                        )
                    ]
                )
            }
        }
    }
}

public struct RecordsDestinationScreen: View {
    public let route: RecordsRoute
    public let timeline: [TimelineEvent]
    public let shareCard: RecordsShareCard?
    public let streak: Streak?
    public let journey: JourneySummary?
    public let recap: Recap?
    public let onShare: (RecordsShareOptions) -> Void

    public init(
        route: RecordsRoute,
        timeline: [TimelineEvent] = [],
        shareCard: RecordsShareCard? = nil,
        streak: Streak? = nil,
        journey: JourneySummary? = nil,
        recap: Recap? = nil,
        onShare: @escaping (RecordsShareOptions) -> Void
    ) {
        self.route = route
        self.timeline = timeline
        self.shareCard = shareCard
        self.streak = streak
        self.journey = journey
        self.recap = recap
        self.onShare = onShare
    }

    @ViewBuilder
    public var body: some View {
        if route == .sharePreview {
            RecordsSharePreviewScreen(shareCard: shareCard, onShare: onShare)
        } else {
            LooprDetailScaffold {
                destinationContent
            }
            .navigationTitle(title)
            .tint(Color.loopr(.brand))
            .accessibilityIdentifier(identifier)
        }
    }

    private var title: String {
        switch route {
        case .records: "Records"
        case .streaks: "Streaks"
        case .journey: "Journey"
        case .timeline: "Timeline"
        case .recap: "Recap"
        case .sharePreview: "Share preview"
        }
    }

    private var identifier: String {
        switch route {
        case .records: "records-detail-screen"
        case .streaks: "records-streaks-screen"
        case .journey: "records-journey-screen"
        case .timeline: "records-timeline-screen"
        case .recap: "records-recap-screen"
        case .sharePreview: "records-share-preview-screen"
        }
    }

    @ViewBuilder
    private var destinationContent: some View {
        switch route {
        case .records:
            recordsDetailContent
        case .streaks:
            streakContent
        case .journey:
            journeyContent
        case .timeline:
            timelineContent
        case .recap:
            recapContent
        case .sharePreview:
            RecordsSharePreviewScreen(shareCard: shareCard, onShare: onShare)
        }
    }

    private var recordsDetailSnapshots: [MetricSnapshot] {
        recap?.metrics ?? shareCard?.recap.metrics ?? []
    }

    private var selectedRecordsMetric: String? {
        if let streakMetric = streak?.metric,
           recordsDetailSnapshots.contains(where: { $0.metric == streakMetric }) {
            return streakMetric
        }
        return recordsDetailSnapshots.first?.metric
    }

    private var selectedRecordsHistory: [MetricSnapshot] {
        guard let selectedRecordsMetric else { return [] }
        return recordsDetailSnapshots.filter { $0.metric == selectedRecordsMetric }
    }

    @ViewBuilder
    private var recordsDetailContent: some View {
        if let selectedRecordsMetric, !selectedRecordsHistory.isEmpty {
            LooprSectionGroup(title: recordsMetricName(selectedRecordsMetric)) {
                RecordsMetricHistoryList(
                    metric: selectedRecordsMetric,
                    snapshots: selectedRecordsHistory
                )
            }
        } else {
            LooprSectionGroup(title: "Records") {
                LooprSurface {
                    StateMessage(.noRecords)
                }
            }
        }
    }

    @ViewBuilder
    private var streakContent: some View {
        LooprSectionGroup(title: "Streaks") {
            VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                LooprFormCard {
                    LooprText(
                        "A streak counts consecutive qualifying local days.",
                        style: .prose,
                        color: .inkSecondary
                    )
                }

                if let streak {
                    HairlineMetricList(rows: [
                        HairlineMetricRow(
                            title: "Current streak",
                            confidence: streak.current ? "ACTIVE" : "INACTIVE",
                            value: streak.length.formatted(),
                            unit: "days"
                        ),
                        HairlineMetricRow(
                            title: "Qualifying days",
                            value: streak.qualifyingDays.count.formatted(),
                            unit: "days"
                        )
                    ])
                    .accessibilityIdentifier("records-streaks-card")
                } else {
                    LooprSurface {
                        StateMessage(.noRecords)
                            .accessibilityIdentifier("records-streaks-empty")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var journeyContent: some View {
        LooprSectionGroup(title: "Journey") {
            VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                if let journey, journey.hasRecordedData {
                    RecordsJourneyProgression(journey: journey)
                        .accessibilityIdentifier("records-journey-state")

                    HairlineMetricList(rows: [
                        HairlineMetricRow(
                            title: "Active days",
                            value: journey.activeDays.formatted(),
                            unit: "days"
                        ),
                        HairlineMetricRow(
                            title: "Recorded events",
                            value: journey.eventCount.formatted(),
                            unit: "events"
                        )
                    ])
                } else {
                    LooprSurface {
                        StateMessage(.noRecords)
                            .accessibilityIdentifier("records-journey-state")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var timelineContent: some View {
        LooprSectionGroup(title: "Events") {
            if timeline.isEmpty {
                LooprSurface {
                    StateMessage(.noRecords)
                }
            } else {
                RecordsTimelineList(events: timeline)
            }
        }
    }

    @ViewBuilder
    private var recapContent: some View {
        if let recap {
            LooprSectionGroup(title: "Period") {
                LooprFormCard {
                    VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                        LooprText("Selected period", style: .rowTitle)
                        LooprText(
                            "\(recordsDayLabel(recap.startDay)) TO \(recordsDayLabel(recap.endDay))",
                            style: .metricUnit,
                            color: .inkSecondary
                        )
                    }
                }
            }

            LooprSectionGroup(title: "Summary") {
                HairlineMetricList(rows: [
                    HairlineMetricRow(
                        title: "Metric snapshots",
                        value: recap.metrics.count.formatted(),
                        unit: "records"
                    ),
                    HairlineMetricRow(
                        title: "Algorithm changes",
                        value: recap.algorithmDiscontinuities.count.formatted(),
                        unit: "changes"
                    ),
                    HairlineMetricRow(
                        title: "Correction days",
                        value: recap.correctionDays.count.formatted(),
                        unit: "days"
                    )
                ])
            }
        } else {
            LooprSurface {
                StateMessage(.noRecords)
            }
        }
    }
}

public struct RecordsSharePreviewScreen: View {
    public let shareCard: RecordsShareCard?
    public let onShare: (RecordsShareOptions) -> Void
    @State private var includeRoute = false
    @State private var includeJournal = false
    @State private var includeLocation = false

    public init(shareCard: RecordsShareCard?, onShare: @escaping (RecordsShareOptions) -> Void) {
        self.shareCard = shareCard
        self.onShare = onShare
        _includeRoute = State(initialValue: shareCard?.privateContent.contains("route") == true)
        _includeJournal = State(initialValue: shareCard?.privateContent.contains("journal") == true)
        _includeLocation = State(initialValue: shareCard?.privateContent.contains("location") == true)
    }

    public var body: some View {
        LooprDetailScaffold {
            VStack(alignment: .leading, spacing: LooprSpacing.lg) {
                LooprSectionGroup(title: "Preview") {
                    RecordsShareArtwork(shareCard: shareCard)
                }

                LooprSectionGroup(title: "Share contents") {
                    shareContents
                }

                LooprSectionGroup(title: "Optional private content") {
                    privateContentControls
                }

                Button("Create share preview") {
                    onShare(RecordsShareOptions(
                        includeRoute: includeRoute,
                        includeJournal: includeJournal,
                        includeLocation: includeLocation
                    ))
                }
                .buttonStyle(LooprPrimaryButtonStyle())
                .accessibilityIdentifier("records-share-create")
            }
        }
        .navigationTitle("Share preview")
        .navigationBarTitleDisplayMode(.inline)
        .tint(Color.loopr(.brand))
        .accessibilityIdentifier("records-share-preview-screen")
    }

    private var shareContents: some View {
        LooprFormCard {
            VStack(alignment: .leading, spacing: LooprSpacing.md) {
                LooprText("WILL INCLUDE", style: .sectionLabel, color: .inkSecondary)
                LooprText(includedDescription, style: .prose)
                if let shareCard {
                    LooprText(
                        recordsPeriodRange(for: shareCard.recap),
                        style: .metricUnit,
                        color: .inkSecondary
                    )
                }

                LooprHairline()

                LooprText("WILL NOT INCLUDE", style: .sectionLabel, color: .inkSecondary)
                LooprText(excludedDescription, style: .prose, color: .inkSecondary)
            }
        }
    }

    private var privateContentControls: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.sm) {
            LooprFormCard {
                LooprText(
                    "Optional private fields start off.",
                    style: .prose,
                    color: .inkSecondary
                )
            }

            LooprFormCard(padding: LooprSpacing.none) {
                VStack(spacing: LooprSpacing.none) {
                    LooprToggleRow(
                        title: "Include route",
                        subtitle: "Adds route data to the image.",
                        isOn: $includeRoute
                    )

                    LooprHairline()

                    LooprToggleRow(
                        title: "Include journal",
                        subtitle: "Adds journal entries to the image.",
                        isOn: $includeJournal
                    )

                    LooprHairline()

                    LooprToggleRow(
                        title: "Include location",
                        subtitle: "Adds location data to the image.",
                        isOn: $includeLocation
                    )
                }
            }
        }
    }

    private var includedDescription: String {
        let base = "Committed records for the selected period."

        let included = privateContentOptions.filter { $0.isIncluded }.map(\.name)
        guard !included.isEmpty else { return base }
        return "\(base) Optional fields: \(recordsListDescription(included))."
    }

    private var excludedDescription: String {
        let excluded = privateContentOptions.filter { !$0.isIncluded }.map(\.sentenceName)
        guard !excluded.isEmpty else {
            return "No optional private content is excluded."
        }
        return "\(recordsListDescription(excluded)) stay out of the image."
    }

    private var privateContentOptions: [(name: String, sentenceName: String, isIncluded: Bool)] {
        [
            ("route data", "Route data", includeRoute),
            ("journal entries", "Journal entries", includeJournal),
            ("location data", "Location data", includeLocation)
        ]
    }
}

private struct RecordsRecordMetricList: View {
    let records: [PersonalRecord]

    var body: some View {
        LooprFormCard(padding: LooprSpacing.none) {
            VStack(spacing: LooprSpacing.none) {
                ForEach(Array(records.enumerated()), id: \.element.id) { index, record in
                    HairlineMetricRow(
                        id: "record-\(record.metric)",
                        title: recordsMetricName(record.metric),
                        confidence: "PERSONAL RECORD",
                        value: record.value.formatted(),
                        unit: recordsDayLabel(record.day)
                    )
                    .accessibilityIdentifier("record-\(record.metric)")

                    if index < records.count - 1 {
                        LooprHairline()
                    }
                }
            }
            .padding(.horizontal, LooprSpacing.formCardPadding)
        }
    }
}

private struct RecordsJourneyProgression: View {
    let journey: JourneySummary

    var body: some View {
        LooprSurface(emphasis: .hero(.brand)) {
            VStack(alignment: .leading, spacing: LooprSpacing.md) {
                LooprText("DATED PROGRESSION", style: .sectionLabel, color: .inkSecondary)
                milestone(title: "Started", day: journey.startDay)
                LooprHairline()
                milestone(title: "Latest recorded day", day: journey.endDay)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "Journey from \(recordsDayLabel(journey.startDay)) to \(recordsDayLabel(journey.endDay))"
        )
    }

    private func milestone(title: String, day: String?) -> some View {
        HStack(alignment: .center, spacing: LooprSpacing.sm) {
            Circle()
                .fill(Color.loopr(.brand))
                .frame(width: LooprSpacing.sm, height: LooprSpacing.sm)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                LooprText(title, style: .rowTitle)
                LooprText(recordsDayLabel(day), style: .metricUnit, color: .inkSecondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: LooprSpacing.interactiveRowHeight, alignment: .leading)
    }
}

private struct RecordsTimelineList: View {
    let events: [TimelineEvent]

    var body: some View {
        LooprFormCard(padding: LooprSpacing.none) {
            VStack(spacing: LooprSpacing.none) {
                ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                    VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                        HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.sm) {
                            LooprText(event.title, style: .rowTitle)
                                .fixedSize(horizontal: false, vertical: true)
                                .layoutPriority(1)

                            Spacer(minLength: LooprSpacing.sm)

                            LooprText(
                                recordsDayLabel(event.day),
                                style: .metricUnit,
                                color: .inkSecondary
                            )
                            .fixedSize(horizontal: true, vertical: false)
                        }

                        LooprText(
                            event.kind.displayName.uppercased(),
                            style: .confidence,
                            color: .inkSecondary
                        )

                        if let provenance = event.correctionProvenance {
                            LooprInlineMessage(
                                "Correction source: \(provenance)",
                                tone: .warning
                            )
                        }
                    }
                    .padding(.horizontal, LooprSpacing.formCardPadding)
                    .padding(.vertical, LooprSpacing.formRowVerticalPadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)

                    if index < events.count - 1 {
                        LooprHairline()
                    }
                }
            }
        }
    }
}

private struct RecordsShareArtwork: View {
    let shareCard: RecordsShareCard?
    private let maximumMetricCount = 4

    var body: some View {
        LooprSurface(emphasis: .hero(.brand)) {
            VStack(alignment: .leading, spacing: LooprSpacing.lg) {
                HStack(alignment: .top, spacing: LooprSpacing.sm) {
                    VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                        LooprText("LOOPR RECORDS", style: .sectionLabel, color: .brand)
                        LooprText("Records recap", style: .titleLarge)
                    }

                    Spacer(minLength: LooprSpacing.sm)

                    Image(systemName: "waveform.path.ecg")
                        .looprTypography(.title)
                        .foregroundStyle(Color.loopr(.brand))
                        .accessibilityHidden(true)
                }

                if let shareCard {
                    LooprText(recordsPeriodRange(for: shareCard.recap), style: .metricUnit, color: .inkSecondary)

                    if shareCard.recap.metrics.isEmpty {
                        StateMessage(.noRecords, compact: true)
                    } else {
                        HairlineMetricList(rows: artworkRows(for: shareCard.recap))

                        if remainingMetricCount(in: shareCard.recap) > 0 {
                            HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.xxs) {
                                LooprText("+", style: .metricUnit, color: .inkSecondary)
                                MetricNumeral(remainingMetricCount(in: shareCard.recap).formatted(), compact: true)
                                LooprText("more measurements", style: .metricUnit, color: .inkSecondary)
                            }
                        }
                    }
                } else {
                    StateMessage(.loading)
                }

                LooprHairline()
                LooprText("COMMITTED DATA", style: .confidence, color: .inkSecondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        guard let shareCard else { return "Share preview loading" }
        return "Share preview, \(shareCard.recap.metrics.count) measurements, \(recordsPeriodRange(for: shareCard.recap))"
    }

    private func artworkRows(for recap: Recap) -> [HairlineMetricRow] {
        Array(recap.metrics.prefix(maximumMetricCount)).enumerated().map { index, metric in
            HairlineMetricRow(
                id: "share-metric-\(index)-\(metric.metric)-\(metric.day)",
                title: recordsMetricName(metric.metric),
                confidence: recordsDayLabel(metric.day),
                value: metric.value.formatted()
            )
        }
    }

    private func remainingMetricCount(in recap: Recap) -> Int {
        max(recap.metrics.count - maximumMetricCount, 0)
    }

}

private struct RecordsMetricHistoryList: View {
    let metric: String
    let snapshots: [MetricSnapshot]

    var body: some View {
        HairlineMetricList(rows: snapshots.map { snapshot in
            HairlineMetricRow(
                id: "records-history-\(metric)-\(snapshot.day)-\(snapshot.algorithmVersion)",
                title: recordsDayLabel(snapshot.day),
                confidence: "ALGORITHM V\(snapshot.algorithmVersion)",
                value: snapshot.value.formatted()
            )
        })
        .accessibilityIdentifier("records-detail-history")
    }
}

private extension RecordsScreenSnapshot.State {
    var metricState: MetricState {
        switch self {
        case .loading: .loading
        case .empty, .noRecords: .noRecords
        case .error, .migrationFailure, .recoverableError: .recoverableError
        case .populated: .measuredZero
        case .absent: .absent
        case .measuredZero: .measuredZero
        case .partial: .partial
        case .lowConfidence: .lowConfidence
        case .settling: .settling
        case .stale: .stale
        case .disconnected: .disconnected
        case .bluetoothOff: .bluetoothOff
        case .permissionDenied: .permissionDenied
        case .unsupportedHardware: .unsupportedHardware
        case .destructiveFailure: .destructiveFailure
        }
    }
}

private extension JourneySummary {
    var hasRecordedData: Bool {
        startDay != nil || endDay != nil || activeDays > 0 || eventCount > 0
    }
}

private func recordsMetricName(_ metric: String) -> String {
    metric
        .replacingOccurrences(of: "_", with: " ")
        .replacingOccurrences(of: "-", with: " ")
        .capitalized
}

private func recordsPeriodRange(for recap: Recap) -> String {
    "\(recordsDayLabel(recap.startDay)) TO \(recordsDayLabel(recap.endDay))"
}

private func recordsDayLabel(_ day: String?) -> String {
    guard let day, !day.isEmpty else { return "NOT RECORDED" }

    let components = day.split(separator: "-")
    guard components.count == 3,
          let year = Int(components[0]),
          let month = Int(components[1]),
          let dayOfMonth = Int(components[2]) else {
        return day.uppercased()
    }

    var calendar = Calendar(identifier: .gregorian)
    calendar.locale = Locale(identifier: "en_US_POSIX")
    calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt

    guard let date = calendar.date(from: DateComponents(year: year, month: month, day: dayOfMonth)) else {
        return day.uppercased()
    }

    return LooprDateFormatterCache.string(from: date, format: "d MMM yyyy", calendar: calendar).uppercased()
}

private func recordsListDescription(_ values: [String]) -> String {
    switch values.count {
    case 0:
        return ""
    case 1:
        return values[0]
    default:
        return values.dropLast().joined(separator: ", ") + " and " + values[values.count - 1]
    }
}
