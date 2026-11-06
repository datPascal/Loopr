import DesignSystem
import SwiftUI

/// Logs a session after the fact in about four taps (R1-NEW-02, R1-DES-05, R1-VET-07): a type, a day, a duration,
/// Save. Title, effort, distance, a typed average heart rate and notes are optional. Choosing Gym opens the empty
/// gym workout and WOD opens the WOD log instead. The same screen edits a saved record.
public struct WorkoutQuickLogScreen: View {
    public enum Mode: String, Sendable { case create, edit }

    private static let metresPerMile = 1_609.344

    private let mode: Mode
    private let route: (WorkoutRoute) -> Void
    private let loadRecords: @Sendable () async -> [WorkoutRecord]
    private let loadWorkout: (() async -> WorkoutRecord?)?
    private let onSave: (WorkoutLogEntry) async throws -> WorkoutRecord
    private let clock: () -> Date
    private let calendar: Calendar
    @Environment(\.looprMeasurementSystem) private var measurementSystem

    @State private var records: [WorkoutRecord] = []
    @State private var activity: ActivityType?
    @State private var title = ""
    @State private var day: WorkoutLogDay = .today
    @State private var pickedDay: Date
    @State private var durationMinutes = 30
    @State private var endsNow = true
    @State private var endTime: Date
    @State private var effort: Int?
    @State private var distanceText = ""
    @State private var heartRateText = ""
    @State private var lengthsText = ""
    @State private var poolText = ""
    @State private var caloriesText = ""
    @State private var notes = ""
    @State private var editing: WorkoutRecord?
    @State private var errorMessage: String?
    @State private var isSaving = false
    @State private var hasLoaded: Bool

    public init(
        mode: Mode = .create,
        initialActivity: ActivityType? = nil,
        now: @escaping () -> Date = Date.init,
        calendar: Calendar = .autoupdatingCurrent,
        loadRecords: @escaping @Sendable () async -> [WorkoutRecord] = { [] },
        loadWorkout: (() async -> WorkoutRecord?)? = nil,
        route: @escaping (WorkoutRoute) -> Void = { _ in },
        onSave: @escaping (WorkoutLogEntry) async throws -> WorkoutRecord
    ) {
        self.mode = mode
        self.route = route
        self.loadRecords = loadRecords
        self.loadWorkout = loadWorkout
        self.onSave = onSave
        self.clock = now
        self.calendar = calendar
        let start = now()
        _pickedDay = State(initialValue: start)
        _endTime = State(initialValue: start)
        _activity = State(initialValue: initialActivity.flatMap { $0 == .strength || $0 == .crossfit ? nil : $0 })
        _hasLoaded = State(initialValue: mode == .create)
    }

    private var identifierPrefix: String { mode == .create ? "workout-log" : "workout-edit" }

    public var body: some View {
        let now = clock()
        ScrollView {
            VStack(alignment: .leading, spacing: LooprSpacing.lg) {
                typeSection
                if let activity, activity.asksForTitleUpFront { titleSection(activity) }
                WorkoutLogWhenSection(day: $day, pickedDay: $pickedDay, durationMinutes: $durationMinutes,
                                      endsNow: $endsNow, endTime: $endTime, now: now, identifier: identifierPrefix)
                detailsSection
                if let errorMessage {
                    LooprInlineMessage(errorMessage, tone: .warning)
                        .accessibilityIdentifier("\(identifierPrefix)-error")
                }
            }
            .padding(.horizontal, LooprSpacing.screenGutter)
            .padding(.top, LooprSpacing.sm)
            .padding(.bottom, LooprSpacing.lg)
            .animation(LooprMotion.stateChange, value: activity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color.loopr(.background).ignoresSafeArea())
        .accessibilityIdentifier(mode == .create ? "workout-log-screen" : "workout-edit-screen")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // A disabled Save says why (R2-DES-03, R2-WOD-06, R2-LIFT-12).
            WorkoutPinnedSaveButton(title: mode == .edit ? "Save changes" : activity == nil ? "Choose a type to save" : "Save workout",
                                    enabled: activity != nil && !isSaving && hasLoaded,
                                    identifier: mode == .create ? "workout-log-save" : "workout-edit-save", action: save)
        }
        .sensoryFeedback(.error, trigger: errorMessage) { _, new in new != nil }
        .navigationTitle(mode == .create ? "Log a workout" : "Edit workout")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    // MARK: Sections

    private var typeSection: some View {
        LooprSectionGroup(title: "Type") {
            WorkoutChipFlow {
                ForEach(types, id: \.self) { type in
                    WorkoutChip(title: type.shortName, symbol: type.symbolName, selected: activity == type,
                                spoken: type.displayName, identifier: "\(identifierPrefix)-type-\(type.rawValue)") { choose(type) }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("\(identifierPrefix)-types")
            if mode == .create {
                LooprText(activity == nil ? "Gym opens your set log. WOD opens the WOD log." : activity!.displayName,
                          style: .caption, color: .inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func titleSection(_ activity: ActivityType) -> some View {
        LooprSectionGroup(title: "Name") {
            LooprFormCard(padding: LooprSpacing.none) { titleField(activity) }
        }
    }

    private func titleField(_ activity: ActivityType) -> some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            TextField(text: $title, prompt: Text(activity.titleExample).foregroundStyle(Color.loopr(.inkSecondary))) {
                Text("Name")
            }
            .looprTypography(.settingsRow)
            .submitLabel(.done)
            .accessibilityIdentifier("\(identifierPrefix)-title")
            let suggestions = activity.recentTitles(records).filter { $0 != title }
            if !suggestions.isEmpty {
                WorkoutChipFlow {
                    ForEach(Array(suggestions.enumerated()), id: \.offset) { index, suggestion in
                        WorkoutChip(title: suggestion, selected: false,
                                    identifier: "\(identifierPrefix)-title-suggestion-\(index)") { title = suggestion }
                    }
                }
            }
        }
        .padding(.horizontal, LooprSpacing.formCardPadding)
        .padding(.vertical, LooprSpacing.formRowVerticalPadding)
        .frame(maxWidth: .infinity, minHeight: LooprSpacing.interactiveRowHeight, alignment: .leading)
    }

    private var detailsSection: some View {
        LooprSectionGroup(title: "Details, optional") {
            LooprFormCard(padding: LooprSpacing.none) {
                VStack(spacing: LooprSpacing.none) {
                    if let activity, !activity.asksForTitleUpFront {
                        titleField(activity)
                        LooprHairline()
                    }
                    WorkoutEffortPicker(effort: $effort, identifier: "\(identifierPrefix)-effort")
                    if showsDistance {
                        LooprHairline()
                        WorkoutNumberFieldRow(title: "Distance", placeholder: "0.0", unit: distanceUnit, decimal: true,
                                              text: $distanceText, identifier: "\(identifierPrefix)-distance")
                    }
                    if activity?.takesLengths == true {
                        LooprHairline()
                        WorkoutNumberFieldRow(title: "Lengths", placeholder: "Optional", unit: nil,
                                              text: $lengthsText, identifier: "\(identifierPrefix)-lengths")
                        LooprHairline()
                        WorkoutNumberFieldRow(title: "Pool length", placeholder: "\(WorkoutRecord.defaultPoolLengthMeters)", unit: "m",
                                              text: $poolText, identifier: "\(identifierPrefix)-pool")
                    }
                    if activity?.takesCalories == true {
                        LooprHairline()
                        WorkoutNumberFieldRow(title: "Calories on the machine", placeholder: "Optional", unit: "kcal",
                                              text: $caloriesText, identifier: "\(identifierPrefix)-calories")
                    }
                    if showsTypedHeartRate {
                        LooprHairline()
                        WorkoutNumberFieldRow(title: "Average heart rate", placeholder: "Optional", unit: "bpm",
                                              caption: "Typed in. It shows on the workout and does not count as zone minutes.",
                                              text: $heartRateText, identifier: "\(identifierPrefix)-heart-rate")
                    }
                    LooprHairline()
                    VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                        LooprText("Notes", style: .settingsRow)
                        TextField(text: $notes, prompt: Text("How it went").foregroundStyle(Color.loopr(.inkSecondary)),
                                  axis: .vertical) { Text("Notes") }
                            .lineLimit(2...6)
                            .looprTypography(.prose)
                            .accessibilityIdentifier("\(identifierPrefix)-notes")
                    }
                    .padding(.horizontal, LooprSpacing.formCardPadding)
                    .padding(.vertical, LooprSpacing.formRowVerticalPadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    // MARK: Rules

    private var types: [ActivityType] {
        let ordered = ActivityType.recentFirst(records)
        guard mode == .edit else { return ordered }
        // An edit keeps the record's own type and never opens another flow.
        return ordered.filter { $0 != .strength || editing?.activity == .strength }
    }

    /// Distance only for the types that cover one, and not when the band measured it.
    private var showsDistance: Bool {
        guard let activity, activity.logsDistance else { return false }
        return editing?.latestDistanceSample == nil
    }

    /// A typed heart rate only when the band measured none.
    private var showsTypedHeartRate: Bool { editing?.measuredAverageHeartRate == nil }

    private var distanceUnit: String { measurementSystem == .imperial ? "mi" : "km" }

    private func choose(_ type: ActivityType) {
        if mode == .create, type == .strength { route(.gymWorkout); return }
        if mode == .create, type == .crossfit { route(.wod); return }
        activity = type
    }

    // MARK: Load and save

    private func load() async {
        records = await loadRecords()
        guard mode == .edit, let loadWorkout else { return }
        guard let workout = await loadWorkout(), let entry = WorkoutLogEntry(record: workout) else {
            errorMessage = "This workout is unavailable for editing."
            return
        }
        editing = workout
        activity = entry.activity
        title = entry.title ?? ""
        let now = clock()
        day = WorkoutLogTiming.day(for: entry.endedAt, now: now, calendar: calendar)
        pickedDay = entry.endedAt
        endsNow = false
        endTime = entry.endedAt
        durationMinutes = max(1, Int(((workout.duration ?? entry.endedAt.timeIntervalSince(entry.startedAt)) / 60).rounded()))
        effort = entry.effort
        if let meters = entry.distanceMeters {
            let value = measurementSystem == .imperial ? meters / Self.metresPerMile : meters / 1_000
            distanceText = value.formatted(.number.precision(.fractionLength(0...2)).grouping(.never))
        }
        heartRateText = entry.typedAverageHeartRate.map(String.init) ?? ""
        lengthsText = entry.lengths.map(String.init) ?? ""
        poolText = entry.poolLengthMeters.map(String.init) ?? ""
        caloriesText = entry.calories.map(String.init) ?? ""
        notes = entry.notes ?? ""
        hasLoaded = true
    }

    private func save() {
        guard let activity else { return }
        let now = clock()
        let interval = WorkoutLogTiming.interval(day: day, pickedDay: pickedDay, endsNow: endsNow, endTime: endTime,
                                                 durationMinutes: durationMinutes, now: now, calendar: calendar)
        var entry = WorkoutLogEntry(activity: activity, startedAt: interval.start, endedAt: interval.end)
        if let editing, let original = WorkoutLogEntry(record: editing) {
            entry = original
            entry.activity = activity
            // An edit that leaves the time alone keeps the saved start and end, pauses included.
            let unchanged = endsNow == false && day == WorkoutLogTiming.day(for: original.endedAt, now: now, calendar: calendar)
                && calendar.isDate(endTime, equalTo: original.endedAt, toGranularity: .minute)
                && durationMinutes == max(1, Int(((editing.duration ?? original.endedAt.timeIntervalSince(original.startedAt)) / 60).rounded()))
            if !unchanged { entry.startedAt = interval.start; entry.endedAt = interval.end }
        }
        entry.title = title
        entry.effort = effort
        entry.notes = notes
        let distance = WorkoutNumberFieldRow.number(distanceText)
        if showsDistance {
            entry.distanceMeters = distance.map { measurementSystem == .imperial ? $0 * Self.metresPerMile : $0 * 1_000 }
        }
        entry.lengths = WorkoutNumberFieldRow.number(lengthsText).map { Int($0.rounded()) }
        entry.poolLengthMeters = entry.lengths == nil ? nil : WorkoutNumberFieldRow.number(poolText).map { Int($0.rounded()) }
        entry.calories = WorkoutNumberFieldRow.number(caloriesText).map { Int($0.rounded()) }
        if showsTypedHeartRate { entry.typedAverageHeartRate = WorkoutNumberFieldRow.number(heartRateText).map { Int($0.rounded()) } }
        if let distance, distance <= 0 { errorMessage = WorkoutLogError.distanceOutOfRange.errorDescription; return }
        do { _ = try entry.validated(now: now, allowingFuture: mode == .edit) }
        catch { errorMessage = error.localizedDescription; return }
        isSaving = true
        errorMessage = nil
        Task { @MainActor in
            do {
                _ = try await onSave(entry)
                route(.finish)
            } catch {
                errorMessage = error.localizedDescription
            }
            isSaving = false
        }
    }
}

/// Edits a saved record in the screen that logged its kind: the WOD log for a CrossFit session, the quick log
/// for everything else.
public struct WorkoutEditScreen: View {
    private let now: () -> Date
    private let calendar: Calendar
    private let loadRecords: @Sendable () async -> [WorkoutRecord]
    private let loadWorkout: () async -> WorkoutRecord?
    private let route: (WorkoutRoute) -> Void
    private let onSave: (WorkoutLogEntry) async throws -> WorkoutRecord
    @State private var workout: WorkoutRecord?
    @State private var loaded = false

    public init(now: @escaping () -> Date = Date.init, calendar: Calendar = .autoupdatingCurrent,
                loadRecords: @escaping @Sendable () async -> [WorkoutRecord] = { [] },
                loadWorkout: @escaping () async -> WorkoutRecord?,
                route: @escaping (WorkoutRoute) -> Void = { _ in },
                onSave: @escaping (WorkoutLogEntry) async throws -> WorkoutRecord) {
        self.now = now; self.calendar = calendar; self.loadRecords = loadRecords; self.loadWorkout = loadWorkout
        self.route = route; self.onSave = onSave
    }

    public var body: some View {
        Group {
            if !loaded {
                ProgressView("Loading workout").accessibilityIdentifier("workout-edit-loading")
            } else if workout?.activity == .crossfit {
                WODLogScreen(mode: .edit, now: now, calendar: calendar, loadRecords: loadRecords,
                             loadWorkout: { [workout] in workout }, route: route, onSave: onSave)
            } else {
                WorkoutQuickLogScreen(mode: .edit, now: now, calendar: calendar, loadRecords: loadRecords,
                                      loadWorkout: { [workout] in workout }, route: route, onSave: onSave)
            }
        }
        .task {
            workout = await loadWorkout()
            loaded = true
        }
    }
}
