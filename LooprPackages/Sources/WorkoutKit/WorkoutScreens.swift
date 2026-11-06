import AnalyticsKit
import Combine
import MapKit
import Foundation
import DomainKit
import SwiftUI
import DesignSystem

/// Typed destinations keep the workout flow independent from the app shell's
/// navigation implementation.
public enum WorkoutRoute: Hashable, Sendable {
    case catalog
    case intervals
    case log
    case edit
    case startPicker
    /// The start screen with one activity already chosen.
    case prepare(ActivityType)
    case live(ActivityType)
    case finish
    case detail
    case recovery
    case route
    case sharePreview
    case detectedReview(DetectedWorkout)
    /// The quick log with this type chosen.
    case logActivity(ActivityType)
    /// The WOD log, empty.
    case wod
    /// The WOD log filled from the last result with this name ("Do it again").
    case repeatWOD(String)
    /// The empty gym workout, started from the quick log's Gym chip.
    case gymWorkout
    /// Heart's zone settings, from the start screen's Zone 2 chip when no range is set (R2-DES-17).
    case heartSettings

    public static let allCases: [WorkoutRoute] = [
        .catalog,
        .intervals,
        .log,
        .edit,
        .startPicker,
        .prepare(.run),
        .live(.run),
        .finish,
        .detail,
        .recovery,
        .route,
        .sharePreview,
        .detectedReview(WorkoutFixtures.detectedRun),
        .logActivity(.yoga),
        .wod,
        .repeatWOD("Fran"),
        .gymWorkout,
        .heartSettings
    ]
}

public enum WorkoutScreenStateFixtures {
    public static let allStates = MetricState.allCases
    public static let accessibilityIdentifiers = [
        "workouts-screen", "workouts-start", "workouts-manual-entry",
        "workout-recovery-screen", "workout-detail-screen",
        "workout-finish-screen", "workout-finish-loading", "workout-finish-completed",
        "workout-finish-unavailable", "workout-finish-error",
        "workout-finish-details"
    ]
    public static let statesByScreen = Dictionary(uniqueKeysWithValues: accessibilityIdentifiers.map { ($0, allStates) })
    public static func accessibilitySummary(for state: MetricState) -> String { "\(state.title). \(state.detail)" }
}

public enum WorkoutDetailRoute: Hashable, Sendable, CaseIterable {
    case edit
    /// Sent after the record is deleted, so the shell can leave the screen.
    case delete
    case sharePreview
    case route
    /// The WOD log, filled from this WOD ("Do it again").
    case doAgain
}

@MainActor
public final class WorkoutViewModel: ObservableObject {
    @Published public private(set) var snapshot: WorkoutScreenSnapshot<[WorkoutRecord]>
    @Published public private(set) var detectedWorkouts: [DetectedWorkout] = []
    private let controller: WorkoutSessionController?
    private let detectedRepository: (any DetectedWorkoutRepository)?
    private let shareExporter: any WorkoutShareExporter
    private let finalizationHooks: WorkoutFinalizationHooks
    private var lastQuery: WorkoutLogQuery?
    /// The clock the last list load used. Fixture launches pin it, so the
    /// "this week" split matches the rows it was loaded with.
    public var listReferenceDate: Date { lastQuery?.now ?? Date() }
    private var lastDetail: WorkoutListDetail = .full

    public init(
        controller: WorkoutSessionController? = nil,
        detectedRepository: (any DetectedWorkoutRepository)? = nil,
        shareExporter: any WorkoutShareExporter = LocalWorkoutShareExporter(),
        finalizationHooks: WorkoutFinalizationHooks = .init()
    ) {
        self.controller = controller
        self.detectedRepository = detectedRepository
        self.shareExporter = shareExporter
        self.finalizationHooks = finalizationHooks
        snapshot = WorkoutScreenSnapshot(state: .loading, accessibilitySummary: "Workouts loading")
    }

    /// `detail: .listing` loads rows for a list; see `WorkoutRecord.listingRow`.
    public func load(query: WorkoutLogQuery, detail: WorkoutListDetail = .full) async {
        lastQuery = query
        lastDetail = detail
        detectedWorkouts = await detectedRepository?.allDetections() ?? []
        guard let controller else {
            let state: WorkoutScreenSnapshot<[WorkoutRecord]>.State = detectedWorkouts.isEmpty ? .noRecords : .ready
            snapshot = WorkoutScreenSnapshot(state: state, value: [], accessibilitySummary: detectedWorkouts.isEmpty ? "No workouts recorded" : "Detected workouts need review")
            return
        }
        let rows = await controller.list(query, detail: detail)
        let hasContent = !rows.isEmpty || !detectedWorkouts.isEmpty
        let state: WorkoutScreenSnapshot<[WorkoutRecord]>.State = hasContent ? .ready : .noRecords
        snapshot = WorkoutScreenSnapshot(state: state, value: rows, accessibilitySummary: hasContent ? "\(rows.count) workout records" : "No workouts recorded")
    }

    public func recoverInterrupted() async throws {
        guard let controller else { throw WorkoutTransitionError.missingWorkout }
        _ = try await controller.recoverInterrupted()
    }

    public func resume(id: UUID) async throws {
        guard let controller else { throw WorkoutTransitionError.missingWorkout }
        _ = try await controller.resumeRecovered(id: id)
        await reload()
    }

    public func discard(id: UUID) async throws {
        guard let controller else { throw WorkoutTransitionError.missingWorkout }
        try await controller.discard(id: id)
        await reload()
    }

    public func edit(id: UUID, activity: ActivityType? = nil, startedAt: Date? = nil, endedAt: Date? = nil) async throws {
        guard let controller else { throw WorkoutTransitionError.missingWorkout }
        _ = try await controller.edit(id: id, activity: activity, startedAt: startedAt, endedAt: endedAt)
        await reload()
    }

    /// Sets or clears how hard a finished workout felt.
    @discardableResult
    public func setEffort(id: UUID, effort: Int?) async throws -> WorkoutRecord {
        guard let controller else { throw WorkoutTransitionError.missingWorkout }
        let row = try await controller.setEffort(id: id, effort: effort)
        await reload()
        return row
    }

    public func delete(id: UUID) async throws {
        guard let controller else { throw WorkoutTransitionError.missingWorkout }
        try await controller.delete(id: id)
        await reload()
    }

    @discardableResult
    public func saveManual(activity: ActivityType, startedAt: Date, endedAt: Date) async throws -> WorkoutRecord {
        guard let controller else { throw WorkoutTransitionError.missingWorkout }
        let row = try await controller.logManual(activity: activity, startedAt: startedAt,
                                                 endedAt: endedAt, hooks: finalizationHooks)
        await reload()
        return row
    }

    @discardableResult
    public func saveManual(_ entry: WorkoutLogEntry) async throws -> WorkoutRecord {
        guard let controller else { throw WorkoutTransitionError.missingWorkout }
        let row = try await controller.logManual(entry, hooks: finalizationHooks)
        await reload()
        return row
    }

    public func detection(id: String) async -> DetectedWorkout? {
        await detectedRepository?.detection(id: id)
    }

    @discardableResult
    public func acceptDetection(
        id: String,
        activity: ActivityType? = nil,
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        title: String? = nil
    ) async throws -> WorkoutRecord {
        guard let controller, let detectedRepository,
              let detection = await detectedRepository.detection(id: id) else {
            throw WorkoutTransitionError.missingWorkout
        }
        let candidate = try DetectedWorkoutCandidate.record(
            from: detection,
            activity: activity,
            startedAt: startedAt,
            endedAt: endedAt,
            title: title
        )
        let row = try await controller.reconcile(candidate, hooks: finalizationHooks)
        try await detectedRepository.remove(id: id)
        await reload()
        return row
    }

    public func discardDetection(id: String) async throws {
        guard let detectedRepository else { throw DetectedWorkoutRepositoryError.missingDetection }
        try await detectedRepository.remove(id: id)
        await reload()
    }

    @discardableResult
    public func finish(id: UUID? = nil, hooks: WorkoutFinalizationHooks? = nil) async throws -> WorkoutRecord {
        guard let controller else { throw WorkoutTransitionError.missingWorkout }
        let row = try await controller.finish(id: id, hooks: hooks ?? finalizationHooks)
        await reload()
        return row
    }

    public func makeSharePreview(id: UUID, includeRoute: Bool = false, includeLocation: Bool = false) async throws -> WorkoutSharePreview {
        guard let controller else { throw WorkoutTransitionError.missingWorkout }
        guard let row = await controller.workout(id: id) else {
            throw WorkoutTransitionError.missingWorkout
        }
        return try await shareExporter.makePreview(
            workout: row,
            request: WorkoutShareRequest(workoutID: id, includeRoute: includeRoute, includeLocation: includeLocation)
        )
    }

    private func reload() async {
        guard let lastQuery else { return }
        await load(query: lastQuery, detail: lastDetail)
    }
}

public struct WorkoutRecoveryScreen: View {
    @ObservedObject private var viewModel: WorkoutViewModel
    private let workout: WorkoutRecord
    @State private var errorMessage: String?
    @State private var isWorking = false
    @State private var haptic: LooprHaptic?

    public init(workout: WorkoutRecord, viewModel: WorkoutViewModel) {
        self.workout = workout
        self.viewModel = viewModel
    }

    public var body: some View {
        LooprDetailScaffold {
            LooprSurface(emphasis: .hero(.warning)) {
                VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                    StatusChip("Recovery needed", symbol: "exclamationmark.arrow.circlepath", tone: .warning)
                    LooprText("Your \(workout.activity.displayName.lowercased()) workout was interrupted.", style: .title)
                    LooprText("Choose whether to resume or discard this session.", style: .prose, color: .inkSecondary)
                }
            }
            LooprSectionGroup(title: "Choose an action") {
                VStack(spacing: LooprSpacing.sm) {
                    Button("Resume workout") { perform(.success) { try await viewModel.resume(id: workout.id) } }
                        .buttonStyle(LooprPrimaryButtonStyle(accent: .workoutAccent))
                        .disabled(isWorking)
                        .accessibilityIdentifier("workout-recovery-resume")
                    Button("Discard workout") { perform(LooprHaptic(.impact(weight: .medium))) { try await viewModel.discard(id: workout.id) } }
                        .buttonStyle(LooprDestructiveButtonStyle())
                        .disabled(isWorking)
                        .accessibilityIdentifier("workout-recovery-discard")
                }
            }
            if let errorMessage {
                LooprInlineMessage(errorMessage, tone: .warning)
                    .workoutMessageTransition()
                    .accessibilityIdentifier("workout-recovery-error")
            }
        }
        .workoutErrorFeedback(errorMessage)
        .looprHaptic(haptic)
        .navigationTitle("Resume workout")
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workout-recovery-screen")
    }

    private func perform(_ success: LooprHaptic, _ action: @escaping @MainActor () async throws -> Void) {
        isWorking = true
        errorMessage = nil
        Task { @MainActor in
            do {
                try await action()
                haptic = success
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }
}

public extension EnvironmentValues {
    /// The app resolves route storage and supplies a ShareLink for a saved route.
    @Entry var workoutRouteExport: AnyView? = nil
}

public struct WorkoutDetailScreen: View {
    @Environment(\.workoutRouteExport) private var routeExport
    @ObservedObject private var viewModel: WorkoutViewModel
    private let source: WorkoutRecord
    private let route: (WorkoutDetailRoute) -> Void
    /// The record after a tap on "How hard was it?", until the list hands back the same thing.
    @State private var saved: WorkoutRecord?
    @State private var pageContext: WorkoutPageContext?
    @State private var heartExport: WorkoutCSVFile?
    @State private var errorMessage: String?
    @State private var isDeleting = false
    @State private var isConfirmingDelete = false
    @State private var haptic: LooprHaptic?

    public init(workout: WorkoutRecord, viewModel: WorkoutViewModel, route: @escaping (WorkoutDetailRoute) -> Void = { _ in }) {
        source = workout
        self.viewModel = viewModel
        self.route = route
    }

    private var workout: WorkoutRecord { saved ?? source }

    /// Route rows only for a session with a route it can draw (R1-DES-13). Gym, swim, yoga and the rest never show them.
    private var hasRoute: Bool { pageContext?.route?.canBeDrawn == true }

    public var body: some View {
        LooprDetailScaffold {
            WorkoutPageBody(
                workout: workout,
                justFinished: false,
                wod: workout.wod.map { AnyView(wodSection($0)) },
                openRoute: { route(.route) },
                saveEffort: { effort in saved = try await viewModel.setEffort(id: workout.id, effort: effort) },
                edit: { route(.edit) },
                onLoaded: { context, analysis in
                    pageContext = context
                    heartExport = analysis.hasHeartRate
                        ? WorkoutCSVFile.heartRate(samples: analysis.samples, startedAt: workout.startedAt ?? workout.createdAt)
                        : nil
                }
            )

            LooprSectionGroup(title: "Actions") {
                LooprFormCard(padding: LooprSpacing.none) {
                    VStack(spacing: LooprSpacing.none) {
                        actionRow(workout.wod == nil ? "Edit workout" : "Edit WOD", identifier: "workout-detail-edit", destination: .edit)
                        if workout.wod?.historyKey != nil {
                            LooprHairline()
                            actionRow("Do it again", identifier: "workout-detail-again", destination: .doAgain)
                        }
                        if hasRoute {
                            LooprHairline()
                            actionRow("Share preview", identifier: "workout-detail-share", destination: .sharePreview)
                            LooprHairline()
                            actionRow("Route details", identifier: "workout-detail-route", destination: .route)
                        }
                        if let routeExport {
                            LooprHairline()
                            routeExport
                        }
                        if let heartExport {
                            LooprHairline()
                            exportRow("Export heart rate as CSV", identifier: "workout-share-heart-csv", file: heartExport)
                        }
                    }
                }
            }

            if let errorMessage {
                LooprInlineMessage(errorMessage, tone: .warning)
                    .workoutMessageTransition()
                    .accessibilityIdentifier("workout-detail-error")
            }
        }
        .workoutErrorFeedback(errorMessage)
        .looprHaptic(haptic)
        .navigationTitle(workout.wod == nil ? "Workout details" : "WOD")
        .accessibilityIdentifier("workout-detail-screen")
        .onChange(of: source) { _, _ in saved = nil }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { route(.edit) } label: { Label("Edit", systemImage: "pencil") }
                        .accessibilityIdentifier("workout-detail-menu-edit")
                    Button(role: .destructive) { isConfirmingDelete = true } label: {
                        Label("Delete workout", systemImage: "trash")
                    }
                    .disabled(isDeleting)
                    .accessibilityIdentifier("workout-detail-delete")
                } label: {
                    Image(systemName: "ellipsis")
                        .accessibilityLabel("More")
                }
                .accessibilityIdentifier("workout-detail-menu")
            }
        }
        .confirmationDialog(
            "Delete this workout?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete workout", role: .destructive) {
                deleteWorkout()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the workout from this device and cannot be undone.")
        }
    }

    private func exportRow(_ title: String, identifier: String, file: WorkoutCSVFile) -> some View {
        ShareLink(item: file, preview: SharePreview(title)) {
            HStack(spacing: LooprSpacing.sm) {
                LooprText(title, style: .settingsRow)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: LooprSpacing.sm)
                Image(systemName: "square.and.arrow.up")
                    .looprTypography(.label)
                    .foregroundStyle(Color.loopr(.inkMuted))
            }
            .padding(.horizontal, LooprSpacing.formCardPadding)
            .padding(.vertical, LooprSpacing.formRowVerticalPadding)
            .frame(maxWidth: .infinity, minHeight: LooprSpacing.interactiveRowHeight, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.looprPressableRow)
        .accessibilityIdentifier(identifier)
    }

    private func wodSection(_ wod: WODResult) -> some View {
        let history = wod.name.flatMap { WODBenchmarkHistory.named($0, in: viewModel.snapshot.value ?? []) }
        let entry = history?.entries.first { $0.id == workout.id }
        return LooprSectionGroup(title: wod.format.displayName) {
            LooprFormCard {
                VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                    HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.xs) {
                        if let score = wod.score {
                            LooprValueText(wod.capped ? "Capped, \(score.text)" : score.text, valueStyle: .metric)
                                .accessibilityIdentifier("workout-detail-wod-score")
                        } else {
                            LooprText("No score logged", style: .prose, color: .inkSecondary)
                        }
                        StatusChip(wod.scaling.displayName, symbol: nil, accent: .workoutAccent)
                        if entry?.isPR == true {
                            StatusChip("PR", symbol: "star.fill", accent: .workoutAccent)
                                .accessibilityIdentifier("workout-detail-wod-pr")
                        }
                    }
                    if let cap = wod.timeCapSeconds, let label = wod.format.timeLabel {
                        LooprText("\(label) \(WODScore.clock(cap))", style: .caption, color: .inkSecondary)
                    }
                    if let note = wod.scalingNote {
                        LooprText("Scaled: \(note)", style: .caption, color: .inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !wod.movements.isEmpty {
                        LooprHairline()
                        VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                            ForEach(Array(wod.movements.enumerated()), id: \.offset) { _, line in
                                LooprText(line, style: .prose).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("workout-detail-wod-movements")
                    }
                    if let history, history.entries.count > 1 {
                        LooprHairline()
                        LooprText("\(history.name) history", style: .sectionLabel, color: .inkSecondary)
                        ForEach(history.entries.prefix(5)) { item in
                            HStack(spacing: LooprSpacing.xs) {
                                LooprText(WorkoutDetailDates.day(item.date, now: WorkoutDetailContext.fallback(for: workout).now, calendar: WorkoutDetailContext.fallback(for: workout).calendar),
                                          style: .caption, color: .inkSecondary)
                                    .frame(minWidth: 92, alignment: .leading)
                                LooprText(item.result.scoreLine ?? "No score", style: item.id == workout.id ? .rowTitle : .prose)
                                if item.isPR { Image(systemName: "star.fill").foregroundStyle(Color.loopr(.workoutAccent)).accessibilityLabel("PR") }
                                if item.id == history.best?.id {
                                    LooprText("Best", style: .caption, color: .inkSecondary)
                                }
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workout-detail-wod")
    }

    private func actionRow(_ title: String, identifier: String, destination: WorkoutDetailRoute) -> some View {
        Button { route(destination) } label: {
            HStack(spacing: LooprSpacing.sm) {
                LooprText(title, style: .settingsRow)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: LooprSpacing.sm)
                LooprChevron()
            }
            .padding(.horizontal, LooprSpacing.formCardPadding)
            .padding(.vertical, LooprSpacing.formRowVerticalPadding)
            .frame(maxWidth: .infinity, minHeight: LooprSpacing.interactiveRowHeight, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.looprPressableRow)
        .accessibilityIdentifier(identifier)
    }

    private func importedRows(_ summary: WorkoutImportedSummary) -> [HairlineMetricRow] {
        let definitions: [(String, String, Double?, String)] = [
            ("strain", "Strain", summary.strain, "/21"),
            ("energy", "Energy", summary.energyKcal, "kcal"),
            ("average", "Average heart rate", summary.averageHeartRate, "bpm"),
            ("maximum", "Maximum heart rate", summary.maximumHeartRate, "bpm")
        ]
        // A value the export did not give is left out, not shown as a blank.
        var rows = definitions.compactMap { id, title, value, unit -> HairlineMetricRow? in
            guard let value else { return nil }
            return HairlineMetricRow(id: "import-" + id, title: title,
                value: value.formatted(.number.precision(.fractionLength(0...1))), unit: unit, accent: .workoutAccent)
        }
        for zone in summary.zonePercentages.keys.sorted() {
            rows.append(HairlineMetricRow(id: "import-zone-\(zone)", title: "Zone \(zone)",
                value: summary.zonePercentages[zone]!.formatted(.number.precision(.fractionLength(0...1))), unit: "%", accent: .workoutAccent))
        }
        return rows
    }

    private func deleteWorkout() {
        isDeleting = true
        errorMessage = nil
        Task { @MainActor in
            do {
                try await viewModel.delete(id: workout.id)
                haptic = LooprHaptic(.impact(weight: .medium))
                route(.delete)
            } catch {
                errorMessage = error.localizedDescription
            }
            isDeleting = false
        }
    }
}

/// The page itself, the same after finishing and from the list. Modules run in the order the type calls for,
/// and a module with nothing to show draws nothing.
struct WorkoutPageBody: View {
    @Environment(\.workoutPageProvider) private var pageProvider
    @Environment(\.workoutDetailContextProvider) private var contextProvider
    @Environment(\.workoutHeartRateRecoveryProvider) private var recoveryProvider
    @Environment(\.looprMeasurementSystem) private var measurementSystem
    let workout: WorkoutRecord
    let justFinished: Bool
    var wod: AnyView?
    let openRoute: () -> Void
    let saveEffort: (Int?) async throws -> Void
    var edit: (() -> Void)?
    var onLoaded: (WorkoutPageContext, WorkoutSessionAnalysis) -> Void = { _, _ in }
    @State private var page = WorkoutPageContext()
    /// The clock, zones and week rules from the app. Until it arrives the detail uses Loopr's own classification.
    @State private var context: WorkoutDetailContext?
    @State private var heartRateRecovery: WorkoutRecoveryPresentation?

    private var resolvedContext: WorkoutDetailContext { context ?? .fallback(for: workout) }
    private var zones: HeartRateZones? { resolvedContext.zones ?? page.fallbackZones }

    private var zoneSet: HeartRateZoneSet? {
        guard let zones else { return nil }
        let source: HRMaxSource = switch zones.source {
        case .manual: .manual
        case .observed: .measured
        case .estimated: .agePredicted
        }
        guard let set = ActivityAnalytics.zones(zones, source: source).value else { return nil }
        // Strain needs the resting heart rate the zones were resolved with.
        return HeartRateZoneSet(zones: set.zones, maxHR: set.maxHR, source: set.source, restingHR: set.restingHR ?? zones.restingHeartRate)
    }

    /// The record with band history in place of samples it never got, so every section reads one set of readings.
    private var effective: WorkoutRecord {
        guard let history = page.history, !workout.samples.contains(where: { $0.heartRate != nil }) else { return workout }
        var copy = workout
        copy.samples += history.samples.map { WorkoutSample(timestamp: $0.date, heartRate: Int($0.bpm.rounded())) }
        return copy
    }

    var body: some View {
        let zoneSet = zoneSet
        let analysis = WorkoutSessionAnalysis(workout: workout, history: page.history, zones: zoneSet)
        let presentation = WorkoutPagePresentation(workout: workout, analysis: analysis, route: page.route, system: measurementSystem)
        let effective = effective
        let heartRate = WorkoutHeartRateSummary.make(effective)
        let split = heartRate.flatMap { summary in zones.flatMap { WorkoutZoneSplit.make(summary.points, zones: $0) } }

        hero(presentation, weekLine: WorkoutWeekCount.line(for: effective, context: resolvedContext, heartRate: heartRate, split: split))
            // Editing the times or the activity changes what the page reads.
            .task(id: workout) {
                context = await contextProvider?.context(for: workout)
                if let pageProvider { page = await pageProvider.context(for: workout) }
                onLoaded(page, WorkoutSessionAnalysis(workout: workout, history: page.history, zones: self.zoneSet))
            }
            .task(id: workout.id) {
                heartRateRecovery = await recoveryProvider?.recovery(for: workout)
            }

        if let wod { wod }
        WorkoutTargetSummaryView(workout: workout)
        ForEach(presentation.modules, id: \.self) { module in
            self.module(module, analysis: analysis, heartRate: heartRate, split: split, zoneSet: zoneSet)
        }

        // A drawn route's distance is in the hero. Two rounding sources for one run read as two answers.
        let rows = WorkoutDetailPresentation.rows(for: effective, system: measurementSystem)
            .filter { !($0.id == "distance" && page.route?.canBeDrawn == true) }
        if !rows.isEmpty {
            LooprSectionGroup(title: workout.source == .manual ? "What you logged" : "Session") {
                HairlineMetricList(rows: rows.map {
                    HairlineMetricRow(id: "workout-detail-\($0.id)", title: $0.title, confidence: $0.source,
                                      value: $0.value, unit: $0.unit, accent: .workoutAccent)
                })
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("workout-detail-logged")
        }

        // An account export's own totals (strain, zone shares) stay as it gave them.
        if workout.source == .imported, let imported = workout.importedSummary {
            WorkoutPageImportedCard(summary: imported)
        }

        if let notes = workout.notes {
            LooprSectionGroup(title: "Notes") {
                LooprFormCard {
                    LooprText(notes, style: .prose)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("workout-detail-notes")
                }
            }
        }
    }

    private func hero(_ presentation: WorkoutPagePresentation, weekLine: String) -> some View {
        LooprSurface(emphasis: .hero(.workoutAccent)) {
            VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                // One source line for the record; each value below names its own (R2-NEW-05).
                HStack(spacing: LooprSpacing.xs) {
                    Label {
                        LooprText(workout.detailSourceLine, style: .caption, color: .inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: workout.detailSourceSymbol)
                            .foregroundStyle(Color.loopr(.workoutAccent))
                            .accessibilityHidden(true)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("workout-detail-source")
                    if justFinished {
                        Spacer(minLength: LooprSpacing.xs)
                        StatusChip("Saved", symbol: "checkmark.circle.fill", tone: .positive)
                    }
                }
                if workout.state != .completed {
                    StatusChip(workout.state.displayName, symbol: "exclamationmark.circle", tone: .warning)
                }
                LooprText(workout.displayTitle, style: .titleLarge)
                    .fixedSize(horizontal: false, vertical: true)
                if workout.displayTitle != workout.activity.displayName {
                    LooprText(workout.activity.displayName, style: .prose, color: .inkSecondary)
                }
                if let line = WorkoutDetailDates.whenLine(workout, now: resolvedContext.now, calendar: resolvedContext.calendar) {
                    LooprText(line, style: .caption, color: .inkSecondary)
                }
                if let value = presentation.headlineValue {
                    LooprValueText(value, unit: presentation.headlineUnit, valueStyle: .metric)
                        .accessibilityIdentifier("workout-page-headline")
                } else {
                    LooprText("Duration not recorded", style: .prose, color: .inkSecondary)
                }
                if !presentation.companions.isEmpty {
                    HStack(alignment: .top, spacing: LooprSpacing.lg) {
                        ForEach(presentation.companions) { companion in
                            VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                                LooprText(companion.label, style: .caption, color: .inkSecondary)
                                LooprValueText(companion.value, unit: companion.unit)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
                if let sentence = presentation.sentence {
                    LooprText(sentence, style: .prose)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("workout-page-sentence")
                }
                // What the session did for its week (R2-NEW-14, R2-NEW-01): the first thing many people came to find out.
                LooprText(weekLine, style: .prose, color: .inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("workout-detail-counts")
                if let comparison = page.comparison {
                    LooprText(comparison, style: .caption, color: .inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("workout-page-comparison")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workout-detail-metric-face")
    }

    private func stayedBelowZones(_ analysis: WorkoutSessionAnalysis, _ zones: HeartRateZoneSet?) -> Bool {
        guard let peak = analysis.peakBPM, let floor = zones?.zones.first?.lowerBPM else { return false }
        return Double(peak) < floor
    }

    /// A range saved when the session started can differ from today's zones after a birthday or a new max heart rate.
    private func targetNote(_ split: WorkoutZoneSplit?) -> String? {
        guard let split, let target = workout.currentZoneTarget, target.target == .zoneTwo else { return nil }
        let today = split.range(2)
        guard target.lower != today.lowerBound || target.upper != today.upperBound else { return nil }
        return "This session's target was \(target.lower) to \(target.upper) bpm, as set when it started. These rows and the week use your current Zone 2, \(today.lowerBound) to \(today.upperBound) bpm."
    }

    @ViewBuilder
    private func module(_ module: WorkoutPageModule, analysis: WorkoutSessionAnalysis, heartRate: WorkoutHeartRateSummary?,
                        split: WorkoutZoneSplit?, zoneSet: HeartRateZoneSet?) -> some View {
        let route = page.route.flatMap { $0.canBeDrawn ? $0 : nil }
        switch module {
        case .effort:
            if let heartRate {
                WorkoutHeartRateSection(summary: heartRate, analysis: analysis, zones: zoneSet, workout: workout)
            }
        case .zones:
            // A session with a target already says its minutes. Without zones the card would only ask for a birth year.
            if let heartRate, !heartRate.points.isEmpty, split != nil || WorkoutTargetZoneSummary(workout: workout) == nil {
                WorkoutZoneSplitSection(split: split, stayedBelowZones: stayedBelowZones(analysis, zoneSet), targetNote: targetNote(split))
            }
        case .map:
            if let route {
                WorkoutPageMapCard(route: route, open: openRoute)
            } else if workout.activity.recordsRoute, workout.source == .live {
                LooprText("No route was recorded.", style: .caption, color: .inkSecondary)
                    .accessibilityIdentifier("workout-page-no-route")
            }
        case .splits:
            if let route, !route.splits.isEmpty {
                WorkoutPageSplitsCard(route: route, activity: workout.activity, system: measurementSystem)
            }
        case .elevation:
            if let route, route.ascentMeters != nil, route.elevation.count >= 2 { WorkoutPageElevationCard(route: route) }
        case .efforts:
            if !analysis.efforts.isEmpty { WorkoutPageEffortsCard(analysis: analysis) }
        case .recovery:
            if let heartRateRecovery { WorkoutHeartRateRecoveryCard(presentation: heartRateRecovery) }
        case .howHard:
            if workout.state == .completed { WorkoutPageHowHardCard(workout: workout, save: saveEffort, edit: edit) }
        }
    }
}

/// The start flow is intentionally package-owned so the tab shell only
/// provides navigation. Keeping activity choice and the explicit transition
/// to a live session here prevents a shell placeholder from becoming a
/// second, subtly different workout implementation.
///
/// One activity line with a Change menu replaces the tile grid (R1-DES-11, R1-VET-14). The heart rate target only
/// shows for types where it fits (R1-NEW-08, R1-WOD-14), and "Log it" beside Start opens the quick log with the
/// type chosen.
///
/// Round 2 (R2-DES-17, R2-NEW-11): without a Zone 2 range the target shows a small "Set up Zone 2" chip that opens
/// Heart's zone settings. Mind and body types put "Log it" first and say in one line what recording adds.
public struct WorkoutStartPickerScreen: View {
    private let route: (WorkoutRoute) -> Void
    @State private var selectedActivity: ActivityType
    @State private var context = WorkoutZoneContext()
    @State private var preference = WorkoutZoneAlertPreference()
    @State private var loaded = false
    private let preferenceStore: WorkoutZoneAlertPreferenceStore
    private let loadZoneContext: @Sendable () async -> WorkoutZoneContext

    public init(initialActivity: ActivityType = .run,
                preferenceStore: WorkoutZoneAlertPreferenceStore = .init(),
                loadZoneContext: @escaping @Sendable () async -> WorkoutZoneContext = { .init() },
                route: @escaping (WorkoutRoute) -> Void = { _ in }) {
        self.route = route
        self.preferenceStore = preferenceStore
        self.loadZoneContext = loadZoneContext
        _selectedActivity = State(initialValue: ActivityType.recordable.contains(initialActivity) ? initialActivity : .run)
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LooprSpacing.tabSection) {
                activityLine
                if selectedActivity.offersHeartRateTarget {
                    heartRateTarget
                } else if let note = Self.doseNote(for: selectedActivity) {
                    LooprText(note, style: .prose, color: .inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("workout-start-dose-note")
                }
                if !Self.logsFirst(selectedActivity) {
                    LooprText("Live samples stay on this device until the session ends.", style: .caption, color: .inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, LooprSpacing.screenGutter)
            .padding(.top, LooprSpacing.sm)
            .padding(.bottom, LooprSpacing.lg)
            .animation(LooprMotion.stateChange, value: selectedActivity)
        }
        .scrollEdgeEffectStyle(.hard, for: .top)
        .background(Color.loopr(.background).ignoresSafeArea())
        // On the scroll view, not the whole screen: there it would rename the pinned Start button too.
        .accessibilityIdentifier("workout-start-picker-screen")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // Mind and body sessions are mostly logged after the class, so Log it is the main action for them
            // (R2-NEW-11). It stays the leading button either way.
            let logsFirst = Self.logsFirst(selectedActivity)
            HStack(spacing: LooprSpacing.sm) {
                logButton(prominent: logsFirst)
                Button { route(.live(selectedActivity)) } label: {
                    Label("Start \(selectedActivity.shortName.lowercased())", systemImage: "play.fill")
                        .contentTransition(.opacity)
                }
                .buttonStyle(LooprButtonStyle(prominent: !logsFirst, accent: .workoutAccent))
                .accessibilityIdentifier("workout-start-confirm")
            }
            .padding(.horizontal, LooprSpacing.screenGutter)
            .padding(.top, LooprSpacing.sm)
            .padding(.bottom, LooprSpacing.xs)
            .background {
                LinearGradient(colors: [Color.loopr(.background).opacity(0), Color.loopr(.background)], startPoint: .top, endPoint: .center)
                    .ignoresSafeArea()
            }
        }
        .navigationTitle("Start")
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.selection, trigger: selectedActivity)
        .task { preference = preferenceStore.preference(for: selectedActivity); context = await loadZoneContext(); loaded = true }
        .onChange(of: selectedActivity) { _, activity in preference = preferenceStore.preference(for: activity) }
    }

    private func logButton(prominent: Bool) -> some View {
        Button { route(.logActivity(selectedActivity)) } label: {
            Label("Log it", systemImage: "square.and.pencil")
        }
        .buttonStyle(LooprButtonStyle(prominent: prominent, accent: .workoutAccent))
        .accessibilityHint("Logs a \(selectedActivity.displayName.lowercased()) session you already did")
        .accessibilityIdentifier("workout-start-log")
    }

    /// True for yoga, Pilates and mobility: Log it comes first and the caption names the band's heart rate.
    static func logsFirst(_ activity: ActivityType) -> Bool { activity.countsAsMobility }

    /// What recording adds, in one line. Mind and body types get the plain version (R2-NEW-11).
    static func recordsLine(for activity: ActivityType) -> String {
        logsFirst(activity) ? "Uses your band's heart rate if it is on." : activity.recordsCaption
    }

    /// The chosen activity on one line: its figure, its name, what gets recorded, and a Change menu.
    private var activityLine: some View {
        LooprCard {
            HStack(spacing: LooprSpacing.md) {
                ZStack {
                    Circle().fill(Color.loopr(.workoutAccent).opacity(0.16))
                    Image(systemName: selectedActivity.symbolName)
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(Color.loopr(LooprColorToken.workoutAccent.spectralChipLabel))
                        .contentTransition(.symbolEffect(.replace))
                }
                .frame(width: 56, height: 56)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                    LooprText(selectedActivity.displayName, style: .title)
                        .contentTransition(.opacity)
                        .accessibilityIdentifier("workout-start-activity")
                    LooprText(Self.recordsLine(for: selectedActivity), style: .caption, color: .inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("workout-start-records")
                }
                Spacer(minLength: LooprSpacing.xs)
                Menu {
                    Picker("Activity", selection: $selectedActivity) {
                        ForEach(ActivityType.recordable, id: \.self) { activity in
                            Label(activity.displayName, systemImage: activity.symbolName)
                                .tag(activity)
                                .accessibilityIdentifier("workout-activity-\(activity.rawValue)")
                        }
                    }
                } label: {
                    LooprText("Change", style: .label, color: LooprColorToken.workoutAccent.spectralChipLabel)
                        .frame(minWidth: LooprSpacing.interactiveRowHeight, minHeight: LooprSpacing.interactiveRowHeight)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Change activity, \(selectedActivity.displayName)")
                .accessibilityIdentifier("workout-start-change")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workout-activity-picker")
    }

    private var heartRateTarget: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprSectionHeader("Heart rate target")
            LooprCard {
                VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                    Toggle(isOn: Binding(get: { preference.target == .zoneTwo }, set: { enabled in
                        preference.target = enabled ? .zoneTwo : .off
                        preferenceStore.set(preference, for: selectedActivity)
                    })) {
                        VStack(alignment: .leading, spacing: 4) {
                            LooprText(preset.map { "Zone 2 · \($0.lower)–\($0.upper) bpm" } ?? "Zone 2", style: .rowTitle)
                            LooprText(presetSource, style: .caption, color: .inkSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .tint(Color.loopr(.workoutAccent))
                    .disabled(preset == nil && preference.target != .zoneTwo)
                    .accessibilityIdentifier("workout-start-zone-two")
                    if preset == nil, loaded { zoneSetupChip }
                    if context.usesPhoneCues {
                        LooprText("Alerts use your iPhone on this band.", style: .caption, color: .inkSecondary)
                    }
                }
            }
        }
    }

    /// Opens Heart's zone settings, where the age or max heart rate behind Zone 2 is set (R2-DES-17).
    private var zoneSetupChip: some View {
        Button { route(.heartSettings) } label: {
            HStack(spacing: LooprSpacing.xxs) {
                Image(systemName: "heart.text.square").imageScale(.small).accessibilityHidden(true)
                Text("Set up Zone 2").looprTypography(.label)
                Image(systemName: "chevron.right").imageScale(.small).accessibilityHidden(true)
            }
            .foregroundStyle(Color.loopr(LooprColorToken.workoutAccent.spectralChipLabel))
            .padding(.horizontal, LooprSpacing.sm)
            .frame(minHeight: LooprSpacing.interactiveRowHeight)
            .background(Color.loopr(.workoutAccent).opacity(0.12), in: Capsule(style: .continuous))
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.looprPressableRow)
        .accessibilityHint("Opens Heart, where your age or max heart rate sets the range")
        .accessibilityIdentifier("workout-start-zone-setup")
    }

    /// What a type without a heart rate target adds to the week.
    static func doseNote(for activity: ActivityType) -> String? {
        activity.countsAsMobility ? "Counts as a mobility session in your week." : nil
    }

    private var preset: ZoneTwoRange? { preference.resolvedZoneTwo(context.zoneTwo) }
    private var presetSource: String {
        switch preset?.source {
        case .restingHeartRate: "From your resting and max heart rate"
        case .maximumHeartRate: "From max heart rate"
        case .manual: "Manual range"
        case nil: loaded ? "Needs your age or max heart rate." : "Loading heart rate range"
        }
    }
}

public struct WorkoutLiveScreen: View {
    private let route: (WorkoutRoute) -> Void
    private let onFinish: @Sendable () async throws -> WorkoutRecord
    private let onPauseChange: (@Sendable (Bool) async throws -> Void)?
    private let session: WorkoutSessionController?
    private let workoutID: UUID?
    private let selectedActivity: ActivityType
    private let zones: HeartRateZoneSet?
    private let zoneTwo: ZoneTwoRange?
    private let usesPhoneCues: Bool
    private let loadRoute: (@Sendable () async -> WorkoutLiveRoute?)?
    private let onAlertPreference: (WorkoutZoneAlertPreference) -> Void
    private let preferenceStore: WorkoutZoneAlertPreferenceStore
    @ScaledMetric(relativeTo: .largeTitle) private var heartRateFontSize: CGFloat = 76
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    private var reduceMotion: Bool { LooprMotion.reducesMotion(accessibilityReduceMotion) }
    @State private var liveWorkout: WorkoutRecord?
    @State private var routeSnapshot: WorkoutLiveRoute?
    @State private var now = Date()
    @State private var isPaused = false
    @State private var errorMessage: String?
    @State private var isFinishing = false
    @State private var alertPreference: WorkoutZoneAlertPreference
    @State private var customLower = 130
    @State private var customUpper = 150
    @State private var editingZoneTwo = false
    @State private var isLoadingCustomRange = false

    public init(
        activity: ActivityType = .run,
        session: WorkoutSessionController? = nil,
        workoutID: UUID? = nil,
        zones: HeartRateZoneSet? = nil,
        zoneTwo: ZoneTwoRange? = nil,
        usesPhoneCues: Bool = false,
        loadRoute: (@Sendable () async -> WorkoutLiveRoute?)? = nil,
        preferenceStore: WorkoutZoneAlertPreferenceStore = .init(),
        onAlertPreference: @escaping (WorkoutZoneAlertPreference) -> Void = { _ in },
        onPauseChange: (@Sendable (Bool) async throws -> Void)? = nil,
        route: @escaping (WorkoutRoute) -> Void = { _ in },
        onFinish: @escaping @Sendable () async throws -> WorkoutRecord = WorkoutLiveScreen.unavailableFinish
    ) {
        selectedActivity = activity
        self.session = session
        self.workoutID = workoutID
        self.zones = zones
        self.zoneTwo = zoneTwo
        self.usesPhoneCues = usesPhoneCues
        self.loadRoute = loadRoute
        self.preferenceStore = preferenceStore
        self.onAlertPreference = onAlertPreference
        self.onPauseChange = onPauseChange
        self.route = route
        self.onFinish = onFinish
        let preference = preferenceStore.preference(for: activity)
        _alertPreference = State(initialValue: preference)
        if case .custom(let lower, let upper) = preference.target {
            _customLower = State(initialValue: lower)
            _customUpper = State(initialValue: upper)
        }
    }

    public var body: some View {
        let metrics = WorkoutLiveMetrics(workout: liveWorkout, zones: zones, now: now)
        ScrollView {
            VStack(alignment: .leading, spacing: LooprSpacing.lg) {
                LooprSurface(emphasis: .hero(.workoutAccent)) {
                    VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                        StatusChip(isPaused ? "Paused" : "Recording", symbol: isPaused ? "pause.circle" : "record.circle", tone: isPaused ? .warning : .positive)
                            .id(isPaused)
                            .transition(.opacity.combined(with: .scale(scale: 0.92)))
                        LooprText((liveWorkout?.activity ?? selectedActivity).displayName, style: .title)
                        HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.sm) {
                            Text(metrics.heartRate.map(String.init) ?? "--")
                                .font(.system(size: heartRateFontSize, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .minimumScaleFactor(0.5)
                                .lineLimit(1)
                                .contentTransition(.numericText(value: Double(metrics.heartRate ?? 0)))
                            Text("bpm").font(.title3)
                        }
                        .foregroundStyle(Color.loopr(.heart))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(metrics.heartRate.map { "Heart rate, \($0) beats per minute" } ?? "No heart rate")
                        .accessibilityIdentifier("workout-live-heart-rate")
                        if let target = resolvedTarget {
                            WorkoutTargetStatusView(target: target, heartRate: metrics.heartRate,
                                                    status: targetStatus(bpm: metrics.heartRate))
                        } else if let zone = metrics.zone {
                            HStack {
                                Text("Zone \(zone.number) · \(zone.name)")
                                    .font(.title3.bold())
                                    .foregroundStyle(zoneColor(zone.number))
                                    .contentTransition(.interpolate)
                                Spacer()
                                Text("\(Int(ceil(zone.lowerBPM)))–\(Int(ceil(zone.upperBPM))) bpm")
                                    .font(.caption)
                            }
                            GeometryReader { geometry in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Color.loopr(.surfaceSunk))
                                    Capsule().fill(zoneColor(zone.number))
                                        .frame(width: max(3, geometry.size.width * zone.progress))
                                        // The bar slides to the new reading instead of jumping.
                                        .animation(reduceMotion ? nil : .smooth(duration: LooprMotion.standard), value: zone.progress)
                                }
                            }
                            .frame(height: 12)
                            .accessibilityLabel("Zone \(zone.number), \(Int(zone.progress * 100)) percent through zone")
                            .accessibilityIdentifier("workout-live-zone-bar")
                            if zones?.source == .agePredicted {
                                Text("Zones use your age to estimate max heart rate")
                                    .font(.caption)
                                    .foregroundStyle(Color.loopr(.inkSecondary))
                            }
                        } else {
                            Text(metrics.heartRate == nil ? "No heart rate" : "Zones need your birth year in Profile")
                                .foregroundStyle(Color.loopr(.inkSecondary))
                                .accessibilityIdentifier("workout-live-zone-unavailable")
                        }
                    }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110))], alignment: .leading, spacing: LooprSpacing.md) {
                    metricCard("Elapsed", value: metrics.elapsed.map(formatDuration) ?? "--")
                    if let strain = metrics.strain { metricCard("Strain", value: strain.formatted(.number.precision(.fractionLength(1)))) }
                    if let calories = metrics.caloriesKcal { metricCard("Calories", value: "\(Int(calories.rounded())) kcal") }
                }
                if let zones {
                    LooprSurface {
                        VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                            Text("Time in zones").font(.headline)
                            ForEach(zones.zones, id: \.number) { zone in
                                HStack {
                                    Circle().fill(zoneColor(zone.number)).frame(width: 10, height: 10)
                                    Text("Zone \(zone.number) · \(WorkoutZoneDisplay.name(for: zone.number))")
                                    Spacer()
                                    if targetZoneNumber == zone.number {
                                        Text("Target")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(Color.loopr(.workoutAccent))
                                    }
                                    Text(metrics.secondsInZones.isEmpty ? "--" : formatDuration(metrics.secondsInZones[zone.number] ?? 0)).monospacedDigit()
                                }
                                .padding(.horizontal, LooprSpacing.xs)
                                .padding(.vertical, LooprSpacing.xs)
                                .background {
                                    if targetZoneNumber == zone.number {
                                        RoundedRectangle(cornerRadius: LooprRadius.compactCard)
                                            .fill(Color.loopr(.workoutAccent).opacity(0.10))
                                    }
                                }
                                .accessibilityElement(children: .combine)
                                .accessibilityIdentifier("workout-zone-row-\(zone.number)")
                            }
                        }
                    }
                }
                if [.run, .cycle, .walk].contains(selectedActivity), loadRoute != nil {
                    routeSection
                }
                alertSection
                HStack(spacing: LooprSpacing.md) {
                    Button(isPaused ? "Resume" : "Pause") {
                        Task { @MainActor in
                            do {
                                if let onPauseChange { try await onPauseChange(!isPaused) }
                                else if let session { _ = try await session.transition(to: isPaused ? .active : .paused) }
                            } catch { errorMessage = error.localizedDescription }
                        }
                    }
                        .buttonStyle(LooprButtonStyle(prominent: false, accent: .workoutAccent))
                        .accessibilityIdentifier("workout-live-pause")
                    Button("Finish") {
                        isFinishing = true
                        errorMessage = nil
                        Task { @MainActor in
                            do { _ = try await onFinish(); route(.finish) }
                            catch { errorMessage = error.localizedDescription }
                            isFinishing = false
                        }
                    }
                    // The Fitness accent, not the default teal, under the Fitness tab (R2-VET-11).
                    .buttonStyle(LooprButtonStyle(accent: .workoutAccent))
                    .disabled(isFinishing)
                    .accessibilityIdentifier("workout-live-finish")
                }
                if let errorMessage {
                    LooprInlineMessage(errorMessage, tone: .warning)
                        .workoutMessageTransition()
                        .accessibilityIdentifier("workout-live-error")
                }
            }
            .padding(LooprSpacing.screenGutter)
            // Pause, resume and new readings change state with a spring.
            .animation(reduceMotion ? .easeInOut(duration: LooprMotion.fast) : WorkoutMotion.change, value: isPaused)
            .animation(reduceMotion ? nil : WorkoutMotion.change, value: metrics.heartRate)
            .animation(reduceMotion ? nil : WorkoutMotion.change, value: metrics.zone?.number)
        }
        .workoutErrorFeedback(errorMessage)
        // The activity, "Run", not "Active workout" (R2-VET-11).
        .navigationTitle((liveWorkout?.activity ?? selectedActivity).shortName)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workout-live-screen")
        .task {
            guard let session, let workoutID else { return }
            liveWorkout = await session.workout(id: workoutID)
            if let saved = liveWorkout?.zoneAlertPreference { alertPreference = saved }
            let updates = await session.updates(for: workoutID)
            for await update in updates {
                guard !Task.isCancelled else { break }
                liveWorkout = update
                // A new receipt can arrive between display ticks. Advance the
                // freshness clock with it so it is not treated as future data.
                now = Date()
                isPaused = update.state == .paused
            }
        }
        .task {
            while !Task.isCancelled {
                now = Date()
                if let loadRoute { routeSnapshot = await loadRoute() }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var routeSection: some View {
        LooprSurface {
            VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                Text("Route").font(.headline)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100))], alignment: .leading, spacing: LooprSpacing.sm) {
                    metricCard("Distance", value: routeSnapshot?.distanceMeters.map { String(format: "%.2f km", $0 / 1000) } ?? "--")
                    metricCard("Current pace", value: pace(routeSnapshot?.currentPaceSecondsPerKilometer))
                    metricCard("Average pace", value: pace(routeSnapshot?.averagePaceSecondsPerKilometer))
                }
                if let snapshot = routeSnapshot, snapshot.segments.contains(where: { $0.count > 1 }) {
                    Map {
                        ForEach(snapshot.segments.indices, id: \.self) { index in
                            MapPolyline(coordinates: snapshot.segments[index].map {
                                CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                            })
                            .stroke(Color.loopr(.workoutAccent), lineWidth: 4)
                        }
                    }
                    .frame(height: 180)
                    .accessibilityLabel("Recorded route, \(snapshot.points.count) points")
                } else {
                    Text("Waiting for route points").foregroundStyle(Color.loopr(.inkSecondary))
                }
            }
        }
    }

    private var alertSection: some View {
        LooprSurface {
            VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                Text("Heart rate alerts").font(.headline)
                Picker("Target", selection: Binding(get: { targetChoice }, set: { choice in
                    guard choice != 7 || alertPreference.resolvedZoneTwo(zoneTwo) != nil else { return }
                    alertPreference.target = choice == 0 ? .off : choice == 7 ? .zoneTwo : choice == 6 ? .custom(lower: customLower, upper: customUpper) : .zone(choice)
                    editingZoneTwo = false
                    savePreference()
                })) {
                    Text(alertPreference.resolvedZoneTwo(zoneTwo) == nil ? "Zone 2 · Unavailable" : "Zone 2")
                        .tag(7).disabled(alertPreference.resolvedZoneTwo(zoneTwo) == nil)
                    Text("Off").tag(0)
                    if zones != nil { ForEach(1...5, id: \.self) { Text($0 == 2 ? "Zone 2 · Calculated" : "Zone \($0)").tag($0) } }
                    Text("Custom range").tag(6)
                }
                .accessibilityIdentifier("workout-alert-target")
                if alertPreference.resolvedZoneTwo(zoneTwo) == nil {
                    Text("Set your birth year or max heart rate in Heart to use Zone 2.")
                        .font(.caption).foregroundStyle(Color.loopr(.inkSecondary))
                }
                if let target = resolvedTarget {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(target.lower)–\(target.upper) bpm").font(.subheadline.weight(.semibold))
                            Text(target.source).font(.caption).foregroundStyle(Color.loopr(.inkSecondary))
                        }
                        Spacer()
                        Button("Change") {
                            isLoadingCustomRange = true
                            customLower = target.lower; customUpper = min(240, target.upper)
                            Task { @MainActor in isLoadingCustomRange = false }
                            if targetChoice == 7 { editingZoneTwo = true }
                            else { alertPreference.target = .custom(lower: customLower, upper: customUpper); savePreference() }
                        }
                        .accessibilityIdentifier("workout-alert-change")
                    }
                }
                if targetChoice == 6 || editingZoneTwo {
                    Stepper("Low: \(customLower) bpm", value: $customLower, in: 30...239)
                    Stepper("High: \(customUpper) bpm", value: $customUpper, in: 31...240)
                    if customLower >= customUpper { Text("Set high above low").foregroundStyle(Color.loopr(.critical)) }
                }
                if targetChoice == 7, alertPreference.manualZoneTwo != nil {
                    Button("Use calculated range") { alertPreference.manualZoneTwo = nil; editingZoneTwo = false; savePreference() }
                        .disabled(zoneTwo == nil)
                }
                if targetChoice != 0 {
                    Toggle("Alert when too low", isOn: $alertPreference.alertWhenTooLow)
                    Toggle("Buzz when back in zone", isOn: $alertPreference.buzzWhenBackInZone)
                    Stepper("Warm-up: \(alertPreference.warmUpMinutes) min", value: $alertPreference.warmUpMinutes, in: 0...15)
                    Toggle("Play sound on iPhone", isOn: $alertPreference.playSound)
                    Text("Buzzes twice after 30 s above your zone, then every 90 s, up to 3 times.")
                        .font(.caption).foregroundStyle(Color.loopr(.inkSecondary))
                    if usesPhoneCues { Text("Alerts use your iPhone on this band.").font(.caption).foregroundStyle(Color.loopr(.inkSecondary)) }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workout-alert-settings")
        .onChange(of: customLower) { _, _ in updateCustomRange() }
        .onChange(of: customUpper) { _, _ in updateCustomRange() }
        .onChange(of: alertPreference.alertWhenTooLow) { _, _ in savePreference() }
        .onChange(of: alertPreference.buzzWhenBackInZone) { _, _ in savePreference() }
        .onChange(of: alertPreference.warmUpMinutes) { _, _ in savePreference() }
        .onChange(of: alertPreference.playSound) { _, _ in savePreference() }
    }

    private var targetZoneNumber: Int? {
        switch resolvedTarget?.target {
        case .zoneTwo: 2
        case .zone(let number): number
        default: nil
        }
    }

    private var resolvedTarget: WorkoutZoneTarget? {
        if let liveWorkout, liveWorkout.zoneAlertPreference == alertPreference { return liveWorkout.currentZoneTarget }
        return .init(preference: alertPreference, zones: zones, zoneTwo: zoneTwo)
    }
    private func targetStatus(bpm: Int?) -> String {
        if isPaused { return "Paused" }
        let remaining = Double(alertPreference.warmUpMinutes * 60) - (liveWorkout?.activeElapsed(at: now) ?? 0)
        if remaining > 0 { let seconds = Int(ceil(remaining)); return "Warm-up \(seconds / 60):\(String(format: "%02d", seconds % 60))" }
        return resolvedTarget?.status(bpm: bpm) ?? "No heart rate"
    }
    private var targetChoice: Int {
        switch alertPreference.target { case .off: 0; case .zoneTwo: 7; case .zone(let number): number; case .custom: 6 }
    }
    private func updateCustomRange() {
        guard !isLoadingCustomRange, customLower < customUpper else { return }
        if editingZoneTwo { alertPreference.manualZoneTwo = .init(lower: customLower, upper: customUpper, source: .manual) }
        else if targetChoice == 6 { alertPreference.target = .custom(lower: customLower, upper: customUpper) }
        else { return }
        savePreference()
    }
    private func savePreference() {
        preferenceStore.set(alertPreference, for: selectedActivity)
        onAlertPreference(alertPreference)
    }
    private func metricCard(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(Color.loopr(.inkSecondary))
            Text(value).font(.headline).monospacedDigit().minimumScaleFactor(0.7).lineLimit(1)
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
    private func zoneColor(_ number: Int) -> Color {
        switch number {
        case 1: Color.loopr(.brand)
        case 2: Color.loopr(.recovery)
        case 3: Color.loopr(.movement)
        case 4: Color.loopr(.warning)
        default: Color.loopr(.critical)
        }
    }
    private func pace(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds > 0 else { return "--" }
        return "\(Int(seconds) / 60):\(String(format: "%02d", Int(seconds) % 60))/km"
    }
    private func formatDuration(_ seconds: TimeInterval) -> String {
        let whole = Int(max(0, seconds))
        return String(format: "%02d:%02d:%02d", whole / 3600, whole / 60 % 60, whole % 60)
    }

    public static func unavailableFinish() async throws -> WorkoutRecord { throw WorkoutTransitionError.missingWorkout }
}

public struct WorkoutFinishScreen: View {
    private enum LoadState {
        case loading
        case completed(WorkoutRecord)
        case unavailable(String)
        case error(String)
    }

    private let onAction: (WorkoutFinishSummaryAction) -> Void
    /// Leaves the page. Without it the button opens the workout's details instead.
    private let onDone: (() -> Void)?
    private let onEdit: ((UUID) -> Void)?
    private let session: WorkoutSessionController?
    private let workoutID: UUID?
    @State private var loadState: LoadState = .loading
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        session: WorkoutSessionController? = nil,
        workoutID: UUID? = nil,
        onDone: (() -> Void)? = nil,
        onEdit: ((UUID) -> Void)? = nil,
        onAction: @escaping (WorkoutFinishSummaryAction) -> Void = { _ in }
    ) {
        self.session = session
        self.workoutID = workoutID
        self.onDone = onDone
        self.onEdit = onEdit
        self.onAction = onAction
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LooprSpacing.lg) {
                switch loadState {
                case .loading:
                    ProgressView("Loading completed workout")
                        .accessibilityIdentifier("workout-finish-loading")
                case .completed(let workout):
                    Group {
                        WorkoutPageBody(
                            workout: workout,
                            justFinished: true,
                            openRoute: { onAction(WorkoutFinishSummaryAction(workout: workout)) },
                            saveEffort: { effort in
                                guard let session else { throw WorkoutTransitionError.missingWorkout }
                                loadState = .completed(try await session.setEffort(id: workout.id, effort: effort))
                            },
                            edit: onEdit.map { edit in { edit(workout.id) } }
                        )
                    }
                    .transition(LooprMotion.reducesMotion(reduceMotion)
                        ? .opacity
                        : .opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                    .accessibilityIdentifier("workout-finish-completed")
                case .unavailable(let message):
                    unavailableSummary(
                        title: "Workout summary unavailable",
                        message: message,
                        identifier: "workout-finish-unavailable"
                    )
                case .error(let message):
                    unavailableSummary(
                        title: "Workout not finalized",
                        message: message,
                        identifier: "workout-finish-error"
                    )
                }
            }
            .padding(LooprSpacing.screenGutter)
        }
        // The page is long, so Done stays in reach instead of waiting at the bottom.
        .safeAreaInset(edge: .bottom) {
            if case .completed(let workout) = loadState {
                Button(onDone == nil ? "View workout details" : "Done") {
                    if let onDone { onDone() } else { onAction(WorkoutFinishSummaryAction(workout: workout)) }
                }
                .buttonStyle(LooprButtonStyle(accent: .workoutAccent))
                .padding(.horizontal, LooprSpacing.screenGutter)
                .padding(.vertical, LooprSpacing.xs)
                .background(.bar)
                .accessibilityIdentifier("workout-finish-details")
            }
        }
        .navigationTitle("Workout summary")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workout-finish-screen")
        .task {
            guard let workoutID, let session else {
                loadState = .unavailable("No completed workout is available.")
                return
            }
            guard let workout = await session.workout(id: workoutID), workout.id == workoutID else {
                loadState = .unavailable("This workout could not be found.")
                return
            }
            guard workout.state == .completed, workout.finalizationStage == .activeStateCleared else {
                loadState = .error("The workout has not finished saving. Check your workout list before trying again.")
                return
            }
            withAnimation(LooprMotion.reducesMotion(reduceMotion) ? .easeInOut(duration: LooprMotion.fast) : WorkoutMotion.reveal) {
                loadState = .completed(workout)
            }
        }
    }

    @ViewBuilder
    private func unavailableSummary(title: String, message: String, identifier: String) -> some View {
        LooprSurface {
            VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                StatusChip(title, symbol: "exclamationmark.triangle", tone: .warning)
                LooprText(message, style: .caption, color: .inkSecondary)
            }
        }
        .accessibilityIdentifier(identifier)
    }
}

/// The post-commit action available from `WorkoutFinishScreen`.
///
/// Live finalization completes before this screen is pushed. Keeping the
/// completed identity on the action makes the navigation-only behavior
/// explicit and prevents a summary button from accidentally starting another
/// finalization.
public struct WorkoutFinishSummaryAction: Equatable, Sendable {
    public let workoutID: UUID

    public init(workout: WorkoutRecord) {
        workoutID = workout.id
    }
}

public struct WorkoutDetectedReviewScreen: View {
    public let detection: DetectedWorkout
    private let onSave: (ActivityType, Date, Date, String?) async throws -> WorkoutRecord
    private let onDiscard: () async throws -> Void
    private let onAccepted: (WorkoutRecord) -> Void
    private let onDiscarded: () -> Void
    @State private var activity: ActivityType
    @State private var title = ""
    @State private var startedAt: Date
    @State private var endedAt: Date
    @State private var errorMessage: String?
    @State private var isWorking = false

    public init(
        detection: DetectedWorkout,
        onSave: @escaping (ActivityType, Date, Date, String?) async throws -> WorkoutRecord,
        onDiscard: @escaping () async throws -> Void,
        onAccepted: @escaping (WorkoutRecord) -> Void = { _ in },
        onDiscarded: @escaping () -> Void = {}
    ) {
        self.detection = detection
        self.onSave = onSave
        self.onDiscard = onDiscard
        self.onAccepted = onAccepted
        self.onDiscarded = onDiscarded
        _activity = State(initialValue: detection.activity)
        _startedAt = State(initialValue: detection.startedAt)
        _endedAt = State(initialValue: detection.endedAt)
    }

    @State private var showsTimes = false

    public var body: some View {
        LooprDetailScaffold {
            LooprSurface(emphasis: .hero(.workoutAccent)) {
                VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                    LooprText(Self.headline(startedAt: startedAt, endedAt: endedAt), style: .titleLarge)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("workout-detected-when")
                    LooprText("The band saw raised heart rate and movement. Pick what it was, or say it was not a workout.",
                              style: .prose, color: .inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            LooprSectionGroup(title: "What was it") {
                WorkoutChipFlow {
                    ForEach(Self.activities, id: \.self) { type in
                        WorkoutChip(title: type.shortName, symbol: type.symbolName, selected: activity == type,
                                    spoken: type.displayName, identifier: "workout-detected-type-\(type.rawValue)") {
                            activity = type
                        }
                    }
                }
                .accessibilityIdentifier("workout-detected-activity")
                if activity == .crossfit {
                    LooprText("Keep opens the WOD log for its format and score.", style: .caption, color: .inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            LooprFormCard(padding: LooprSpacing.none) {
                VStack(spacing: LooprSpacing.none) {
                    HStack(spacing: LooprSpacing.sm) {
                        LooprText("Name", style: .settingsRow)
                        Spacer(minLength: LooprSpacing.sm)
                        TextField(text: $title, prompt: Text(activity.titleExample).foregroundStyle(Color.loopr(.inkSecondary))) {
                            Text("Name")
                        }
                        .multilineTextAlignment(.trailing)
                        .looprTypography(.settingsRow)
                        .accessibilityIdentifier("workout-detected-title")
                    }
                    .padding(.horizontal, LooprSpacing.formCardPadding)
                    .padding(.vertical, LooprSpacing.formRowVerticalPadding)
                    .frame(minHeight: LooprSpacing.interactiveRowHeight)
                    LooprHairline()
                    DisclosureGroup(isExpanded: $showsTimes) {
                        VStack(spacing: LooprSpacing.none) {
                            WorkoutDatePickerRow(title: "Started", selection: $startedAt)
                            LooprHairline()
                            WorkoutDatePickerRow(title: "Ended", selection: $endedAt)
                        }
                    } label: {
                        LooprText("Change the times", style: .settingsRow)
                    }
                    .padding(.horizontal, LooprSpacing.formCardPadding)
                    .padding(.vertical, LooprSpacing.formRowVerticalPadding)
                    .accessibilityIdentifier("workout-detected-times")
                }
            }
            VStack(spacing: LooprSpacing.sm) {
                Button("Keep") {
                    isWorking = true
                    errorMessage = nil
                    Task { @MainActor in
                        do {
                            let row = try await onSave(activity, startedAt, endedAt, WorkoutLogEntry.cleaned(title))
                            onAccepted(row)
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                        isWorking = false
                    }
                }
                .buttonStyle(LooprPrimaryButtonStyle(accent: .workoutAccent))
                .disabled(isWorking)
                .accessibilityHint("Saves it as \(activity.displayName.lowercased())")
                .accessibilityIdentifier("workout-detected-save")
                Button("Not a workout", role: .destructive) {
                    isWorking = true
                    errorMessage = nil
                    Task { @MainActor in
                        do {
                            try await onDiscard()
                            onDiscarded()
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                        isWorking = false
                    }
                }
                .buttonStyle(LooprButtonStyle(prominent: false, accent: .workoutAccent))
                .disabled(isWorking)
                .accessibilityIdentifier("workout-detected-discard")
            }
            if let errorMessage {
                LooprInlineMessage(errorMessage, tone: .warning)
                    .workoutMessageTransition()
                    .accessibilityIdentifier("workout-detected-error")
            }
        }
        .workoutErrorFeedback(errorMessage)
        .navigationTitle("Band session")
        .tint(Color.loopr(.workoutAccent))
        .accessibilityIdentifier("workout-detected-review-screen")
    }

    /// "Today, 6:20 to 6:52 · 32 min", "Yesterday, ..." or "Mon 13 Nov, ..." (R2-DES-04): the day in words.
    static func headline(startedAt: Date, endedAt: Date, now: Date = Date(), calendar: Calendar = .autoupdatingCurrent) -> String {
        let day: String
        if calendar.isDate(startedAt, inSameDayAs: now) {
            day = "Today"
        } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(startedAt, inSameDayAs: yesterday) {
            day = "Yesterday"
        } else {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_GB")
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.dateFormat = "EEE d MMM"
            day = formatter.string(from: startedAt)
        }
        var timeStyle = Date.FormatStyle(date: .omitted, time: .shortened)
        timeStyle.timeZone = calendar.timeZone
        let minutes = max(Int((endedAt.timeIntervalSince(startedAt) / 60).rounded()), 0)
        return "\(day), \(startedAt.formatted(timeStyle)) to \(endedAt.formatted(timeStyle)) · \(minutes) min"
    }

    /// Every type a band session can be, the quick log's order (R1-WOD-09).
    static let activities: [ActivityType] = ActivityType.loggable
}

public struct WorkoutSharePreviewScreen: View {
    public let workout: WorkoutRecord
    private let exporter: any WorkoutShareExporter
    @State private var includeRoute = false
    @State private var includeLocation = false
    @State private var preview: WorkoutSharePreview?
    @State private var errorMessage: String?
    @State private var isCreating = false
    @State private var haptic: LooprHaptic?

    public init(
        workout: WorkoutRecord = WorkoutFixtures.completedRun,
        exporter: any WorkoutShareExporter = LocalWorkoutShareExporter()
    ) {
        self.workout = workout
        self.exporter = exporter
    }

    public var body: some View {
        LooprDetailScaffold {
            LooprSectionGroup(title: "Workout") {
                HairlineMetricList(rows: [
                    HairlineMetricRow(id: "workout-share-activity", title: "Activity", value: workout.activity.displayName),
                    HairlineMetricRow(id: "workout-share-duration", title: "Duration",
                                     value: WorkoutDurationText.formatted(workout.duration) ?? "No reading")
                ])
            }
            LooprSectionGroup(title: "Private content") {
                LooprFormCard(padding: LooprSpacing.none) {
                    VStack(spacing: LooprSpacing.none) {
                        LooprToggleRow(title: "Include route", isOn: $includeRoute)
                        LooprHairline()
                        LooprToggleRow(title: "Include location", isOn: $includeLocation)
                    }
                }
            }
            LooprText("Route and location are off until you turn them on.",
                      style: .prose, color: .inkSecondary)
            Button("Create share preview") {
                isCreating = true
                errorMessage = nil
                Task { @MainActor in
                    do {
                        let made = try await exporter.makePreview(
                            workout: workout,
                            request: WorkoutShareRequest(workoutID: workout.id, includeRoute: includeRoute, includeLocation: includeLocation)
                        )
                        withAnimation(WorkoutMotion.change) { preview = made }
                        haptic = .success
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                    isCreating = false
                }
            }
                .buttonStyle(LooprPrimaryButtonStyle(accent: .workoutAccent))
                .disabled(isCreating)
                .accessibilityIdentifier("workout-share-create")
            if let preview {
                LooprSectionGroup(title: "Ready to review") {
                    LooprFormCard {
                        VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                            LooprText(preview.summary, style: .prose)
                                .accessibilityIdentifier("workout-share-summary")
                            LooprText(preview.includesRoute ? "Route included" : "Route excluded",
                                      style: .caption, color: .inkSecondary)
                            LooprText(preview.includesLocation ? "Location included" : "Location excluded",
                                      style: .caption, color: .inkSecondary)
                        }
                    }
                }
            }
            if let errorMessage {
                LooprInlineMessage(errorMessage, tone: .warning)
                    .workoutMessageTransition()
                    .accessibilityIdentifier("workout-share-error")
            }
        }
        .workoutErrorFeedback(errorMessage)
        .looprHaptic(haptic)
        .navigationTitle("Share preview")
        .accessibilityIdentifier("workout-share-preview-screen")
    }
}

/// Springs the workout screens share.
enum WorkoutMotion {
    static let change: Animation = .smooth(duration: LooprMotion.standard)
    static let reveal: Animation = .spring(duration: LooprMotion.deliberate, bounce: 0.18)
}

private extension View {
    /// An error message slides in under the buttons rather than popping.
    func workoutMessageTransition() -> some View {
        transition(.move(edge: .top).combined(with: .opacity))
    }

    /// A failed save or step buzzes once when its message appears.
    func workoutErrorFeedback(_ message: String?) -> some View {
        sensoryFeedback(.error, trigger: message) { _, new in new != nil }
            .animation(.smooth(duration: LooprMotion.fast), value: message)
    }
}

public enum WorkoutFixtures {
    public static let completedRun: WorkoutRecord = {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let identity = WorkoutIdentity.make(activity: .run, sourceKey: "fixture-run", startedAt: start, endedAt: start.addingTimeInterval(1_800))
        return WorkoutRecord(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000701")!,
            identity: identity,
            activity: .run,
            // Recorded with the band: its heart rate and distance are the band's, so the detail names one source
            // (R2-VET-10, R2-DES-13). It was `.manual` with band samples, which no real record has.
            source: .live,
            state: .completed,
            createdAt: start,
            startedAt: start,
            endedAt: start.addingTimeInterval(1_800),
            // A 30-minute run ends at its full distance: 5.2 km is a 5:46 pace, not 250 m in half an hour.
            samples: [WorkoutSample(timestamp: start.addingTimeInterval(60), heartRate: 142, distanceMeters: 250),
                      WorkoutSample(timestamp: start.addingTimeInterval(1_800), heartRate: 151, distanceMeters: 5_200)],
            checkpointNumber: 2,
            finalizationStage: .activeStateCleared
        )
    }()

    public static let interrupted = WorkoutRecord(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000702")!,
        identity: WorkoutIdentity(canonicalKey: "fixture:interrupted"),
        activity: .cycle,
        source: .live,
        state: .interruptedAndRecoverable,
        createdAt: Date(timeIntervalSince1970: 1_700_000_100),
        startedAt: Date(timeIntervalSince1970: 1_700_000_100),
        // The last checkpoint, 41 minutes in, so the row says how far the ride got before it stopped.
        samples: [WorkoutSample(timestamp: Date(timeIntervalSince1970: 1_700_002_560), heartRate: 138, distanceMeters: 14_300)],
        checkpointNumber: 1,
        lastCheckpointAt: Date(timeIntervalSince1970: 1_700_002_560),
        finalizationStage: .none
    )

    public static let detectedRun = DetectedWorkout(
        detectionID: "fixture-detected-run",
        activity: .run,
        startedAt: Date(timeIntervalSince1970: 1_700_000_400),
        endedAt: Date(timeIntervalSince1970: 1_700_001_000)
    )
}

public struct WorkoutScreen: View {
    @ObservedObject private var viewModel: WorkoutViewModel
    private let route: (WorkoutRoute) -> Void
    private let selectedRoute: ((WorkoutRoute, WorkoutRecord) -> Void)?

    public init(
        viewModel: WorkoutViewModel,
        route: @escaping (WorkoutRoute) -> Void = { _ in },
        selectedRoute: ((WorkoutRoute, WorkoutRecord) -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.route = route
        self.selectedRoute = selectedRoute
    }

    public var body: some View {
        LooprTabScaffold(header: header, glow: .workoutAccent, identifier: "workouts-screen") {
            LooprPhaseContainer(phase: phase) {
                phaseContent
            }
        }
        .navigationTitle("")
    }

    private var header: LooprTabHeaderContent {
        LooprTabHeaderContent(
            title: "Fitness",
            accent: .workoutAccent,
            dayPhrase: weeklyHeaderMeta,
            freshness: .sync(lastSync: nil),
            control: .action(LooprHeaderAction(
                symbol: "plus",
                label: "Start a workout",
                identifier: "workouts-header-start",
                run: { route(.startPicker) }
            ))
        )
    }

    private var phase: LooprLoadPhase {
        switch viewModel.snapshot.state {
        case .loading: .loading
        case .noRecords: .empty
        case .ready: .content
        default: .failed
        }
    }

    @ViewBuilder
    private var phaseContent: some View {
        if phase == .loading {
            LooprLoadingPlaceholder(.cards(4))
        } else {
            VStack(alignment: .leading, spacing: LooprSpacing.lg) {
                switch phase {
                case .empty:
                    LooprCard { LooprText("No workouts yet", style: .title) }
                    readyContent
                case .content:
                    readyContent
                default:
                    LooprCard {
                        LooprText(
                            viewModel.snapshot.accessibilitySummary,
                            style: .prose,
                            color: .inkSecondary
                        )
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, LooprSpacing.screenGutter)
            .padding(.top, LooprSpacing.tabContentTop)
        }
    }

    @ViewBuilder
    private var readyContent: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.sm) {
            Button { route(.startPicker) } label: {
                WorkoutPrimaryActionCard()
                    .accessibilityElement(children: .combine)
            }
            .buttonStyle(.looprPressableCard)
            .accessibilityIdentifier("workouts-start")

            Button { route(.intervals) } label: {
                WorkoutCardSurface(tone: .neutral) {
                    WorkoutActionRow(title: "Interval timer", subtitle: "Work and rest with band cues")
                }
                .accessibilityElement(children: .combine)
            }
            .buttonStyle(.looprPressableCard)
            .accessibilityIdentifier("workouts-interval-timer")

            Button { route(.log) } label: {
                WorkoutCardSurface(tone: .neutral) {
                    WorkoutActionRow(
                        title: "Log manually",
                        subtitle: "Add a completed session without location"
                    )
                }
                .accessibilityElement(children: .combine)
            }
            .buttonStyle(.looprPressableCard)
            .accessibilityIdentifier("workouts-manual-entry")

            ForEach(viewModel.detectedWorkouts, id: \.detectionID) { detection in
                Button { route(.detectedReview(detection)) } label: {
                    WorkoutCardSurface(tone: .warning) {
                        WorkoutActionRow(
                            title: "Detected \(detection.activity.displayName.lowercased())",
                            subtitle: "Review before saving",
                            subtitleColor: .strainChip,
                            arrowColor: .strain
                        )
                    }
                    .accessibilityElement(children: .combine)
                }
                .buttonStyle(.looprPressableCard)
                .accessibilityIdentifier("workout-detected-row-\(detection.detectionID)")
            }

            weeklySection
        }
    }

    private var sections: WorkoutListSections {
        WorkoutListSections(workouts: viewModel.snapshot.value ?? [], now: viewModel.listReferenceDate)
    }

    /// The list is split where the calendar week starts: "This week" holds only this week's sessions, "Earlier" the rest.
    private var weeklySection: some View {
        let sections = sections
        let now = viewModel.listReferenceDate
        return LazyVStack(alignment: .leading, spacing: 10) {
            if !sections.thisWeek.isEmpty {
                LooprText("This week", style: .sectionLabel, color: .inkSecondary)
                ForEach(sections.thisWeek) { workout in sessionRow(workout, now: now) }
            }
            if !sections.earlier.isEmpty {
                LooprText("Earlier", style: .sectionLabel, color: .inkSecondary)
                    .padding(.top, sections.thisWeek.isEmpty ? 0 : LooprSpacing.sm)
                ForEach(sections.earlier) { workout in sessionRow(workout, now: now) }
            }
        }
        .padding(.top, LooprSpacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sessionRow(_ workout: WorkoutRecord, now: Date) -> some View {
        Button {
            let destination: WorkoutRoute = workout.state == .interruptedAndRecoverable ? .recovery : .detail
            if let selectedRoute {
                selectedRoute(destination, workout)
            } else {
                route(destination)
            }
        } label: {
            WorkoutSessionCard(workout: workout, now: now)
        }
        .buttonStyle(.looprPressableCard)
        .accessibilityIdentifier("workout-row-\(workout.id.uuidString)")
        .accessibilityLabel("\(workout.displayTitle) workout, \(workout.state.displayName)")
    }

    /// "3 this week". Nothing while the list is still loading.
    private var weeklyHeaderMeta: String? {
        guard viewModel.snapshot.state != .loading else { return nil }
        return sections.headerMeta
    }
}

/// The Workouts list split at the start of the calendar week. The list loads
/// three months, so only the first part may be called "this week". Both parts run newest first (R2-DES-16,
/// R2-WOD-11, R2-VET-09, R2-NEW-12).
public struct WorkoutListSections {
    public let thisWeek: [WorkoutRecord]
    public let earlier: [WorkoutRecord]

    public init(workouts: [WorkoutRecord], now: Date, calendar: Calendar = .autoupdatingCurrent) {
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start
            ?? calendar.startOfDay(for: now)
        var thisWeek: [WorkoutRecord] = []
        var earlier: [WorkoutRecord] = []
        let newestFirst = workouts.sorted { ($0.startedAt ?? $0.createdAt) > ($1.startedAt ?? $1.createdAt) }
        for workout in newestFirst {
            if (workout.startedAt ?? workout.createdAt) >= weekStart {
                thisWeek.append(workout)
            } else {
                earlier.append(workout)
            }
        }
        self.thisWeek = thisWeek
        self.earlier = earlier
    }

    /// "3 this week", or "No workouts this week".
    public var headerMeta: String {
        thisWeek.isEmpty ? "No workouts this week" : "\(thisWeek.count) this week"
    }
}

private enum WorkoutCardTone: Equatable {
    case primary
    case neutral
    case warning
    case session
}

/// Workouts' cards draw through `LooprCard`. The primary card keeps its
/// swept glow inside the card shape.
private struct WorkoutCardSurface<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    private let tone: WorkoutCardTone
    private let content: Content

    init(tone: WorkoutCardTone, @ViewBuilder content: () -> Content) {
        self.tone = tone
        self.content = content()
    }

    var body: some View {
        content
            .padding(.vertical, tone == .primary ? LooprSpacing.lg : LooprSpacing.cardVertical)
            .padding(.horizontal, LooprSpacing.cardHorizontal)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if tone == .primary {
                    Color.clear
                        .overlay(alignment: .topTrailing) {
                            WorkoutSweptGlow(isDark: isDark)
                                .frame(width: isDark ? 170 : 180, height: isDark ? 170 : 180)
                                .offset(x: 40, y: isDark ? -60 : -70)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: LooprRadius.surface(isDark: isDark), style: .continuous))
                        .accessibilityHidden(true)
                }
            }
            .looprCardBackground(style)
    }

    private var style: LooprCardStyle {
        switch tone {
        case .primary: .hero(.brand)
        case .warning: .warning
        case .neutral, .session: .standard
        }
    }

    private var isDark: Bool { LooprAppearance.isDark(colorScheme) }
}

private struct WorkoutSweptGlow: View {
    private let isDark: Bool

    init(isDark: Bool) {
        self.isDark = isDark
    }

    var body: some View {
        Circle()
            .fill(gradient)
            .blur(radius: isDark ? 16 : 18)
            .accessibilityHidden(true)
    }

    private var gradient: AngularGradient {
        let accentAlpha = isDark ? 0.50 : 0.45
        let partnerAlpha = isDark ? 0.35 : 0.30
        let fadeLocation = 134.0 / 360.0
        return AngularGradient(
            gradient: Gradient(stops: [
                .init(color: Color.loopr(.brand).opacity(0), location: 0),
                .init(color: Color.loopr(.brand).opacity(accentAlpha), location: 50.0 / 360.0),
                .init(
                    color: Color.loopr(LooprColorToken.brand.spectralSweepPartner).opacity(partnerAlpha),
                    location: 84.0 / 360.0
                ),
                .init(color: Color.loopr(.brand).opacity(0), location: fadeLocation),
                .init(color: Color.loopr(.brand).opacity(0), location: 1)
            ]),
            center: .center,
            startAngle: .degrees(LooprColorToken.brand.spectralStartAngle),
            endAngle: .degrees(LooprColorToken.brand.spectralStartAngle + 360)
        )
    }

}

private struct WorkoutPrimaryActionCard: View {
    var body: some View {
        WorkoutCardSurface(tone: .primary) {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    LooprText("Start a workout", style: .cardTitle)
                    LooprText(
                        "Run, cycle, walk, or another supported activity",
                        style: .caption,
                        color: .inkSecondary
                    )
                    .frame(maxWidth: 230, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .layoutPriority(1)

                Spacer(minLength: 0)

                LooprChevron()
            }
        }
    }
}

private struct WorkoutActionRow: View {
    private let title: String
    private let subtitle: String
    private let subtitleColor: LooprColorToken
    private let arrowColor: LooprColorToken

    init(
        title: String,
        subtitle: String,
        subtitleColor: LooprColorToken = .inkSecondary,
        arrowColor: LooprColorToken = .inkSecondary
    ) {
        self.title = title
        self.subtitle = subtitle
        self.subtitleColor = subtitleColor
        self.arrowColor = arrowColor
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                LooprText(title, style: .rowTitle)
                LooprText(subtitle, style: .metricUnit, color: subtitleColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .layoutPriority(1)

            Spacer(minLength: LooprSpacing.sm)

            LooprChevron()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct WorkoutSessionCard: View {
    let workout: WorkoutRecord
    var now = Date()
    @Environment(\.looprMeasurementSystem) private var measurementSystem
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        WorkoutCardSurface(tone: .session) {
            // At accessibility sizes the chip moves under the text, so the
            // detail line keeps the full width instead of wrapping word by word.
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: LooprSpacing.sm))
                : AnyLayout(HStackLayout(alignment: .center, spacing: LooprSpacing.sm))
            layout {
                VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                    LooprText(workout.displayTitle, style: .cardTitle)
                    if let detailLine = WorkoutSessionPresentation.detailLine(
                        for: workout,
                        system: measurementSystem,
                        now: now
                    ) {
                        LooprText(detailLine, style: .metricUnit, color: .inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .layoutPriority(1)

                if !dynamicTypeSize.isAccessibilitySize {
                    Spacer(minLength: 0)
                }

                StatusChip(
                    WorkoutSessionPresentation.statusLabel(for: workout.state),
                    symbol: WorkoutSessionPresentation.statusSymbol(for: workout.state),
                    tone: workout.state == .completed ? .positive : .warning
                )
            }
        }
    }
}

/// How a workout row words itself. Train's list reads the same lines.
public enum WorkoutSessionPresentation {
    public static func detailLine(
        for workout: WorkoutRecord,
        system: LooprMeasurementSystem = .metric,
        now: Date = Date()
    ) -> String? {
        var segments: [String] = []
        let date = workout.startedAt ?? workout.createdAt
        segments.append(dateSegment(date, now: now))
        if let source = workout.importedSummary?.source { segments.append(source) }

        let duration = workout.duration ?? recoverableElapsed(of: workout)
        if let duration {
            segments.append(durationSegment(duration))
        }
        if let distance = latestDistance(in: workout) ?? workout.resolvedDistanceMeters {
            segments.append(distanceSegment(distance, system: system))
            if workout.state == .completed, workout.lengths == nil,
               let speed = WorkoutPagePresentation.speedCompanion(activity: workout.activity, meters: distance, seconds: duration, system: system) {
                segments.append([speed.value, speed.unit?.looprLabelCased].compactMap { $0 }.joined(separator: " "))
            }
        }
        if let calories = workout.loggedCalories { segments.append("\(calories) kcal") }
        if let score = workout.wod?.scoreLine { segments.append(score) }

        return segments.isEmpty ? nil : segments.joined(separator: " · ")
    }

    /// An interrupted workout has no end. Its last checkpoint or sample says how long it ran at least, so the row
    /// shows that instead of nothing.
    private static func recoverableElapsed(of workout: WorkoutRecord) -> TimeInterval? {
        guard workout.state == .interruptedAndRecoverable else { return nil }
        let last = ([workout.lastCheckpointAt] + workout.samples.map { Optional($0.timestamp) }).compactMap { $0 }.max()
        return last.flatMap { workout.activeElapsed(at: $0) }.flatMap { $0 > 0 ? $0 : nil }
    }

    public static func statusLabel(for state: WorkoutLifecycleState) -> String {
        // The workout stopped before it was saved; the row opens the screen that saves it (R2-UPG-11).
        state == .interruptedAndRecoverable ? "Finish saving" : state.displayName
    }

    public static func statusSymbol(for state: WorkoutLifecycleState) -> String {
        state == .interruptedAndRecoverable ? "arrow.clockwise" : "checkmark"
    }

    private static func durationSegment(_ duration: TimeInterval) -> String {
        let seconds = max(0, Int(duration.rounded()))
        if seconds < 60 {
            return "\(seconds) SEC"
        }
        return "\(seconds / 60) min"
    }

    /// The weekday within the last six days ("TUE"), the date before that
    /// ("14 SEP"), so a row from last month never reads as this week.
    private static func dateSegment(_ date: Date, now: Date) -> String {
        let calendar = Calendar.autoupdatingCurrent
        let startOfWeek = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)) ?? now
        let style: Date.FormatStyle = date >= startOfWeek
            ? .dateTime.weekday(.abbreviated)
            : .dateTime.day().month(.abbreviated)
        return date.formatted(style).looprLabelCased
    }

    private static func latestDistance(in workout: WorkoutRecord) -> Double? {
        guard let distanceMeters = workout.latestDistanceSample?.distanceMeters,
              distanceMeters >= 0 else {
            return nil
        }
        return distanceMeters
    }

    private static func distanceSegment(
        _ distanceMeters: Double,
        system: LooprMeasurementSystem
    ) -> String {
        let distance = LooprUnitFormatter.distance(meters: distanceMeters, system: system)
        return "\(distance.value) \(distance.unit.looprLabelCased)"
    }
}
