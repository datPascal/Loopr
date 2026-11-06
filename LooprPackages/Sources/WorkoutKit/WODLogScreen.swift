import DesignSystem
import SwiftUI

/// Logs a WOD after the fact (R1-WOD-01, 02, 03, 13, R1-DES-02): the format, a name with benchmark suggestions
/// that fill in the standard movements, the whiteboard as text, a time cap, one score typed by format, Rx or
/// Scaled, the duration and notes. A name logged before shows the last result and the best, and "Do it again"
/// fills the form from the last one. The same screen edits a saved WOD.
///
/// Round 2 (R2-WOD-01, 02, 09, 10, 14): Score sits under Format, the time is typed as minutes and seconds, the cap
/// has 5, 10, 15 and 20 minute chips, "Start clock" runs the WOD on `WODClockScreen` and brings its score back, and
/// a new WOD ends on a short result: the score, how it sits against your best, and what it added to the week.
public struct WODLogScreen: View {
    public enum Mode: String, Sendable { case create, edit }

    private let mode: Mode
    private let initialName: String?
    private let route: (WorkoutRoute) -> Void
    private let loadRecords: @Sendable () async -> [WorkoutRecord]
    private let loadWorkout: (() async -> WorkoutRecord?)?
    private let onSave: (WorkoutLogEntry) async throws -> WorkoutRecord
    private let clock: () -> Date
    private let calendar: Calendar

    @State private var records: [WorkoutRecord] = []
    @State private var format: WODFormat = .forTime
    @State private var name = ""
    @State private var movements = ""
    @State private var capMinutes: Int?
    @State private var otherScoreKind: WODScoreKind = .time
    @State private var minutesText = ""
    @State private var secondsText = ""
    @State private var roundsText = ""
    @State private var repsText = ""
    @State private var totalRepsText = ""
    @State private var loadText = ""
    @State private var capped = false
    @State private var scaling: WODScaling = .rx
    @State private var scalingNote = ""
    @State private var day: WorkoutLogDay = .today
    @State private var pickedDay: Date
    @State private var durationMinutes = 30
    @State private var endsNow = true
    @State private var endTime: Date
    @State private var notes = ""
    @State private var editing: WorkoutRecord?
    @State private var errorMessage: String?
    @State private var isSaving = false
    @State private var hasLoaded: Bool
    /// The history the form was last filled from, so its card does not offer "Do it again" a second time.
    @State private var filledFrom: String?
    @State private var showsClock = false
    /// The score fields as the clock filled them. The "From the clock" line shows until one is edited.
    @State private var clockFields: [String]?
    /// Set once a new WOD is saved: the result the screen shows instead of the form.
    @State private var saved: WODSaveSummary?

    public init(
        mode: Mode = .create,
        initialName: String? = nil,
        now: @escaping () -> Date = Date.init,
        calendar: Calendar = .autoupdatingCurrent,
        loadRecords: @escaping @Sendable () async -> [WorkoutRecord] = { [] },
        loadWorkout: (() async -> WorkoutRecord?)? = nil,
        route: @escaping (WorkoutRoute) -> Void = { _ in },
        onSave: @escaping (WorkoutLogEntry) async throws -> WorkoutRecord
    ) {
        self.mode = mode
        self.initialName = initialName
        self.route = route
        self.loadRecords = loadRecords
        self.loadWorkout = loadWorkout
        self.onSave = onSave
        self.clock = now
        self.calendar = calendar
        let start = now()
        _pickedDay = State(initialValue: start)
        _endTime = State(initialValue: start)
        _hasLoaded = State(initialValue: mode == .create)
    }

    public var body: some View {
        ScrollView {
            if let saved {
                resultCard(saved)
                    .padding(.horizontal, LooprSpacing.screenGutter)
                    .padding(.top, LooprSpacing.sm)
            } else {
                form
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color.loopr(.background).ignoresSafeArea())
        .accessibilityIdentifier("wod-log-screen")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if saved != nil {
                WorkoutPinnedSaveButton(title: "Done", enabled: true, identifier: "wod-result-done") { route(.finish) }
            } else {
                WorkoutPinnedSaveButton(title: mode == .create ? "Save WOD" : "Save changes", enabled: !isSaving && hasLoaded,
                                        identifier: "wod-save", action: save)
            }
        }
        .sensoryFeedback(.error, trigger: errorMessage) { _, new in new != nil }
        .sensoryFeedback(.success, trigger: saved?.isPR == true) { _, new in new }
        .navigationTitle(saved != nil ? "WOD saved" : mode == .create ? "Log a WOD" : "Edit WOD")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(saved != nil)
        .fullScreenCover(isPresented: $showsClock) {
            if let setup = WODClockSetup(format: format, capMinutes: capMinutes) {
                NavigationStack {
                    // The clock reads the real time: the log's clock is pinned in fixture launches.
                    WODClockScreen(setup: setup, name: name, onScore: { result in
                        apply(result)
                        showsClock = false
                    }, onClose: { showsClock = false })
                }
                .tint(Color.loopr(.workoutAccent))
            }
        }
        .task { await load() }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.lg) {
            nameSection
            if let history { historyCard(history) } else if WODResult.historyKey(name) == nil, !histories.isEmpty {
                benchmarksSection
            }
            formatSection
            scoreSection
            movementsSection
            WorkoutLogWhenSection(day: $day, pickedDay: $pickedDay, durationMinutes: $durationMinutes,
                                  endsNow: $endsNow, endTime: $endTime, now: clock(), identifier: "wod")
            notesSection
            if let errorMessage {
                LooprInlineMessage(errorMessage, tone: .warning).accessibilityIdentifier("wod-error")
            }
        }
        .padding(.horizontal, LooprSpacing.screenGutter)
        .padding(.top, LooprSpacing.sm)
        .padding(.bottom, LooprSpacing.lg)
        .animation(LooprMotion.stateChange, value: format)
        .animation(LooprMotion.stateChange, value: capped)
        .animation(LooprMotion.stateChange, value: scaling)
    }

    // MARK: Name and history

    private var histories: [WODBenchmarkHistory] { WODBenchmarkHistory.all(records) }
    private var history: WODBenchmarkHistory? {
        WODBenchmarkHistory.named(name, in: records.filter { $0.id != editing?.id })
    }

    private var nameSection: some View {
        LooprSectionGroup(title: "Name") {
            LooprFormCard {
                VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                    TextField(text: $name, prompt: Text("Fran, or the gym's name for it")
                        .foregroundStyle(Color.loopr(.inkSecondary))) { Text("Name") }
                        .looprTypography(.settingsRow)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
                        .accessibilityIdentifier("wod-name")
                    if !suggestions.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: LooprSpacing.xs) {
                                ForEach(suggestions, id: \.self) { suggestion in
                                    WorkoutChip(title: suggestion, selected: false,
                                                identifier: "wod-suggestion-\(suggestion.lowercased())") { pick(suggestion) }
                                }
                            }
                        }
                        .scrollClipDisabled()
                        LooprText("A benchmark fills in its standard movements. Change them to match your board.",
                                  style: .caption, color: .inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    /// Your own WOD names first, then benchmarks that start with what was typed.
    private var suggestions: [String] {
        let typed = WODResult.historyKey(name)
        let own = histories.map(\.name).filter { own in
            guard let typed else { return true }
            let key = WODResult.historyKey(own) ?? ""
            return key.hasPrefix(typed) && key != typed
        }
        let benchmarks = WODBenchmark.suggestions(for: name).map(\.name)
            .filter { benchmark in !own.contains { $0.caseInsensitiveCompare(benchmark) == .orderedSame } }
        return Array((own + benchmarks).prefix(14))
    }

    private func historyCard(_ history: WODBenchmarkHistory) -> some View {
        LooprCard {
            VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                HStack {
                    LooprText(history.name, style: .cardTitle)
                    Spacer()
                    LooprText("\(history.entries.count) logged", style: .caption, color: .inkSecondary)
                }
                if let last = history.last { resultLine("Last", entry: last) }
                if let best = history.best { resultLine("Best", entry: best) }
                // One "Do it again" (R2-WOD-10): not when the form was just filled from this history.
                if mode == .create, filledFrom != history.key {
                    Button("Do it again") { repeatLast(history) }
                        .buttonStyle(LooprButtonStyle(prominent: false, accent: .workoutAccent))
                        .accessibilityHint("Fills the form from your last \(history.name)")
                        .accessibilityIdentifier("wod-history-again")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wod-history")
    }

    private func resultLine(_ label: String, entry: WODBenchmarkHistory.Entry) -> some View {
        HStack(spacing: LooprSpacing.xs) {
            LooprText(label, style: .label, color: .inkSecondary).frame(width: 44, alignment: .leading)
            LooprText(entry.result.scoreLine ?? "No score", style: .metricValue)
            if entry.isPR { StatusChip("PR", symbol: "star.fill", accent: .workoutAccent) }
            Spacer(minLength: LooprSpacing.xs)
            LooprText(entry.date.formatted(.dateTime.day().month(.abbreviated)), style: .caption, color: .inkSecondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var benchmarksSection: some View {
        LooprSectionGroup(title: "Your benchmarks") {
            LooprFormCard(padding: LooprSpacing.none) {
                VStack(spacing: LooprSpacing.none) {
                    ForEach(Array(histories.prefix(6).enumerated()), id: \.element.id) { index, history in
                        if index > 0 { LooprHairline() }
                        HStack(spacing: LooprSpacing.sm) {
                            VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                                LooprText(history.name, style: .rowTitle)
                                LooprText(summary(history), style: .caption, color: .inkSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: LooprSpacing.sm)
                            Button("Do it again") { repeatLast(history) }
                                .looprTypography(.label)
                                .tint(Color.loopr(LooprColorToken.workoutAccent.spectralChipLabel))
                                .frame(minHeight: LooprSpacing.interactiveRowHeight)
                                .accessibilityLabel("Do \(history.name) again")
                                .accessibilityIdentifier("wod-again-\(history.key)")
                        }
                        .padding(.horizontal, LooprSpacing.formCardPadding)
                        .padding(.vertical, LooprSpacing.xs)
                    }
                }
            }
        }
    }

    private func summary(_ history: WODBenchmarkHistory) -> String {
        var parts: [String] = []
        if let last = history.last?.result.scoreLine { parts.append("Last \(last)") }
        if let best = history.best, best.id != history.last?.id, let line = best.result.scoreLine { parts.append("best \(line)") }
        return parts.isEmpty ? "\(history.entries.count) logged" : parts.joined(separator: ", ")
    }

    // MARK: Result

    /// The result after a save (R2-WOD-09): the score, PR or the gap to the best, what it added to the week.
    private func resultCard(_ summary: WODSaveSummary) -> some View {
        LooprSurface(emphasis: .hero(.workoutAccent)) {
            VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                HStack(spacing: LooprSpacing.xs) {
                    LooprText("Saved", style: .sectionLabel, color: .inkSecondary)
                    Spacer(minLength: LooprSpacing.xs)
                    if summary.isPR {
                        StatusChip("PR", symbol: "star.fill", accent: .workoutAccent)
                            .accessibilityIdentifier("wod-result-pr")
                    }
                }
                LooprText(summary.title, style: .title)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("wod-result-score")
                if let line = summary.standingLine {
                    LooprText(line, style: .prose)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("wod-result-standing")
                }
                LooprText(summary.weekLine, style: .prose, color: .inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("wod-result-week")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wod-result")
    }

    // MARK: Format, movements, score

    private var formatSection: some View {
        LooprSectionGroup(title: "Format") {
            LooprFormCard {
                VStack(alignment: .leading, spacing: LooprSpacing.md) {
                    WorkoutChipFlow {
                        ForEach(WODFormat.allCases, id: \.self) { option in
                            WorkoutChip(title: option.displayName, selected: format == option,
                                        identifier: "wod-format-\(option.rawValue)") { choose(option) }
                        }
                    }
                    if let label = format.timeLabel {
                        LooprHairline()
                        capRow(label)
                        capChips(label)
                    }
                    if mode == .create, let entry = clockEntry {
                        LooprHairline()
                        entry
                    }
                }
            }
        }
    }

    /// 5, 10, 15 and 20 minutes in one tap (R2-WOD-14). The stepper beside them does the rest.
    private func capChips(_ label: String) -> some View {
        WorkoutChipFlow {
            ForEach(Self.capChipMinutes, id: \.self) { minutes in
                WorkoutChip(title: "\(minutes) min", selected: capMinutes == minutes, spoken: "\(label), \(minutes) minutes",
                            identifier: "wod-cap-chip-\(minutes)") { capMinutes = minutes }
            }
        }
    }

    static let capChipMinutes = [5, 10, 15, 20]

    /// "Start clock" for For time and AMRAP; EMOM and Tabata run on the interval timer (R2-WOD-01, R2-DES-20).
    private var clockEntry: AnyView? {
        if WODClockKind(format: format) != nil {
            return AnyView(VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                Button { showsClock = true } label: {
                    Label("Start clock", systemImage: "stopwatch").frame(maxWidth: .infinity)
                }
                .buttonStyle(LooprButtonStyle(accent: .workoutAccent))
                .accessibilityHint("Runs the WOD on a clock with a round counter, then fills in the score")
                .accessibilityIdentifier("wod-start-clock")
                LooprText(format == .amrap ? "Counts down the length. Tap Round +1 at the end of each round."
                          : "Counts up to the cap. Tap Round +1 at the end of each round.",
                          style: .caption, color: .inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            })
        }
        if format == .emom || format == .tabata {
            return AnyView(Button { route(.intervals) } label: {
                Label("Open the interval timer", systemImage: "timer").frame(maxWidth: .infinity)
            }
            .buttonStyle(LooprButtonStyle(prominent: false, accent: .workoutAccent))
            .accessibilityIdentifier("wod-open-intervals"))
        }
        return nil
    }

    private func capRow(_ label: String) -> some View {
        HStack(spacing: LooprSpacing.xs) {
            LooprText(label, style: .settingsRow)
            Spacer(minLength: LooprSpacing.sm)
            capButton("minus", spoken: "One minute less") {
                guard let minutes = capMinutes else { return }
                capMinutes = minutes > 1 ? minutes - 1 : nil
                if capMinutes == nil { capped = false }
            }
            LooprText(capMinutes.map { "\($0) min" } ?? "None", style: .metricValue)
                .monospacedDigit()
                .frame(minWidth: 64)
                .accessibilityLabel("\(label), \(capMinutes.map { "\($0) minutes" } ?? "none")")
                .accessibilityIdentifier("wod-cap-value")
            capButton("plus", spoken: "One minute more") { capMinutes = min((capMinutes ?? 0) + 1, 180) }
        }
    }

    private func capButton(_ symbol: String, spoken: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .looprTypography(.label)
                .foregroundStyle(Color.loopr(.ink))
                .frame(width: LooprSpacing.interactiveRowHeight, height: LooprSpacing.interactiveRowHeight)
                .glassEffect(.regular.interactive(), in: Circle())
        }
        .buttonStyle(.plain)
        .buttonRepeatBehavior(.enabled)
        .accessibilityLabel(spoken)
        .accessibilityIdentifier("wod-cap-\(symbol)")
    }

    private var movementsSection: some View {
        LooprSectionGroup(title: "Movements") {
            LooprFormCard {
                VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                    TextField(text: $movements, prompt: Text("One line per movement, as on the board")
                        .foregroundStyle(Color.loopr(.inkSecondary)), axis: .vertical) { Text("Movements") }
                        .lineLimit(3...14)
                        .looprTypography(.prose)
                        .accessibilityIdentifier("wod-movements")
                }
            }
        }
    }

    private var scoreFields: [String] { [minutesText, secondsText, roundsText, repsText] }
    private var scoreFromClock: Bool { clockFields != nil && clockFields == scoreFields }

    private var scoreKind: WODScoreKind {
        if format.canBeCapped, capped { return .roundsAndReps }
        return format.scoreKind ?? otherScoreKind
    }

    private var scoreSection: some View {
        LooprSectionGroup(title: "Score") {
            LooprFormCard(padding: LooprSpacing.none) {
                VStack(spacing: LooprSpacing.none) {
                    if format == .other {
                        WorkoutChipFlow {
                            ForEach(WODScoreKind.allCases, id: \.self) { kind in
                                WorkoutChip(title: kind.displayName, selected: otherScoreKind == kind,
                                            identifier: "wod-score-kind-\(kind.rawValue)") { otherScoreKind = kind }
                            }
                        }
                        .padding(LooprSpacing.formCardPadding)
                        LooprHairline()
                    }
                    if format.canBeCapped, capMinutes != nil {
                        LooprToggleRow(title: "Hit the time cap", subtitle: capped ? "Type the rounds and reps you finished." : nil,
                                       accent: .workoutAccent, identifier: "wod-capped", isOn: $capped)
                        LooprHairline()
                    }
                    scoreRows
                    if scoreFromClock {
                        LooprText("From the clock.", style: .caption, color: .inkSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, LooprSpacing.formCardPadding)
                            .padding(.bottom, LooprSpacing.xs)
                            .accessibilityIdentifier("wod-score-from-clock")
                    }
                    LooprHairline()
                    VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                        LooprChoiceControl("Rx or Scaled", choices: WODScaling.allCases.map { LooprChoice($0.rawValue, title: $0.displayName) },
                                           selection: scaling.rawValue, accent: .workoutAccent, identifier: "wod-scaling") { id in
                            scaling = id.flatMap(WODScaling.init(rawValue:)) ?? .rx
                        }
                        if scaling == .scaled {
                            TextField(text: $scalingNote, prompt: Text("What you changed, like 30 kg thrusters")
                                .foregroundStyle(Color.loopr(.inkSecondary))) { Text("Scaling") }
                                .looprTypography(.settingsRow)
                                .accessibilityIdentifier("wod-scaling-note")
                        }
                    }
                    .padding(LooprSpacing.formCardPadding)
                }
            }
        }
    }

    @ViewBuilder
    private var scoreRows: some View {
        switch scoreKind {
        case .time:
            WODTimeField(title: "Time", minutes: $minutesText, seconds: $secondsText, identifier: "wod-score-time")
        case .roundsAndReps:
            WorkoutNumberFieldRow(title: "Rounds", placeholder: "0", unit: nil, text: $roundsText, identifier: "wod-score-rounds")
            LooprHairline()
            WorkoutNumberFieldRow(title: "Extra reps", placeholder: "0", unit: "reps", text: $repsText, identifier: "wod-score-reps")
        case .reps:
            WorkoutNumberFieldRow(title: "Total reps", placeholder: "0", unit: "reps", text: $totalRepsText,
                                  identifier: "wod-score-total-reps")
        case .load:
            WorkoutNumberFieldRow(title: "Load", placeholder: "0", unit: "kg", decimal: true, text: $loadText,
                                  identifier: "wod-score-load")
        }
    }

    private var notesSection: some View {
        LooprSectionGroup(title: "Notes, optional") {
            LooprFormCard {
                TextField(text: $notes, prompt: Text("How it went").foregroundStyle(Color.loopr(.inkSecondary)),
                          axis: .vertical) { Text("Notes") }
                    .lineLimit(2...6)
                    .looprTypography(.prose)
                    .accessibilityIdentifier("wod-notes")
            }
        }
    }

    // MARK: Actions

    private func choose(_ option: WODFormat) {
        format = option
        if !option.canBeCapped { capped = false }
        if option == .tabata { capMinutes = nil }
        if (option == .amrap || option == .emom), capMinutes == nil { capMinutes = option == .amrap ? 12 : 10 }
    }

    /// A suggestion: your last result with that name, or the benchmark's standard movements.
    private func pick(_ suggestion: String) {
        if let history = WODBenchmarkHistory.named(suggestion, in: records) {
            repeatLast(history)
        } else if let benchmark = WODBenchmark.named(suggestion) {
            name = benchmark.name
            format = benchmark.format
            movements = benchmark.movements.joined(separator: "\n")
            capMinutes = benchmark.timeCapSeconds.map { $0 / 60 }
            capped = false
            filledFrom = nil
        } else {
            name = suggestion
        }
    }

    private func repeatLast(_ history: WODBenchmarkHistory) {
        guard let last = history.last?.result else { return }
        name = last.name ?? history.name
        format = last.format
        movements = last.movements.joined(separator: "\n")
        capMinutes = last.timeCapSeconds.map { $0 / 60 }
        scaling = last.scaling
        scalingNote = last.scalingNote ?? ""
        capped = false
        minutesText = ""; secondsText = ""; roundsText = ""; repsText = ""; totalRepsText = ""; loadText = ""
        clockFields = nil
        if format == .other, let kind = last.score?.kind { otherScoreKind = kind }
        filledFrom = history.key
    }

    /// The clock's score in the Score fields, its work time as the duration, ended now (R2-WOD-01).
    private func apply(_ result: WODClockResult) {
        capped = result.capped
        minutesText = ""; secondsText = ""; roundsText = ""; repsText = ""
        switch result.score.kind {
        case .time:
            (minutesText, secondsText) = WODTimeEntry.fields(for: result.score.seconds ?? 0)
        default:
            roundsText = "\(result.score.rounds ?? 0)"
            repsText = (result.score.reps ?? 0) > 0 ? "\(result.score.reps ?? 0)" : ""
        }
        clockFields = scoreFields
        day = .today
        endsNow = true
        durationMinutes = min(max(1, Int((Double(result.workSeconds) / 60).rounded(.up))), WorkoutLogTiming.durationRange.upperBound)
        errorMessage = nil
    }

    private func load() async {
        records = await loadRecords()
        if mode == .create, let initialName {
            if let history = WODBenchmarkHistory.named(initialName, in: records) { repeatLast(history) } else { pick(initialName) }
        }
        guard mode == .edit, let loadWorkout else { return }
        guard let workout = await loadWorkout(), let entry = WorkoutLogEntry(record: workout) else {
            errorMessage = "This workout is unavailable for editing."
            return
        }
        editing = workout
        let result = entry.wod ?? WODResult(format: .forTime)
        name = result.name ?? entry.title ?? ""
        format = result.format
        movements = result.movements.joined(separator: "\n")
        capMinutes = result.timeCapSeconds.map { $0 / 60 }
        capped = result.capped
        scaling = result.scaling
        scalingNote = result.scalingNote ?? ""
        if let score = result.score {
            if format == .other { otherScoreKind = score.kind }
            switch score.kind {
            case .time: (minutesText, secondsText) = WODTimeEntry.fields(for: score.seconds ?? 0)
            case .roundsAndReps: roundsText = "\(score.rounds ?? 0)"; repsText = (score.reps ?? 0) > 0 ? "\(score.reps ?? 0)" : ""
            case .reps: totalRepsText = "\(score.reps ?? 0)"
            case .load: loadText = (score.kilograms ?? 0).formatted(.number.precision(.fractionLength(0...1)).grouping(.never))
            }
        }
        let now = clock()
        day = WorkoutLogTiming.day(for: entry.endedAt, now: now, calendar: calendar)
        pickedDay = entry.endedAt
        endsNow = false
        endTime = entry.endedAt
        durationMinutes = max(1, Int(entry.endedAt.timeIntervalSince(entry.startedAt) / 60))
        notes = entry.notes ?? ""
        hasLoaded = true
    }

    /// The score from the fields. Nil when they are empty; throws a message when they cannot be read.
    private func score() throws -> WODScore? {
        switch scoreKind {
        case .time:
            switch WODTimeEntry(minutes: minutesText, seconds: secondsText) {
            case .empty: return nil
            case .seconds(let seconds) where seconds > 0: return .time(seconds: seconds)
            case .seconds, .invalid: throw WODLogInputError.time
            }
        case .roundsAndReps:
            let rounds = WorkoutNumberFieldRow.number(roundsText).map { Int($0) }
            let reps = WorkoutNumberFieldRow.number(repsText).map { Int($0) }
            guard rounds != nil || reps != nil else { return nil }
            return .roundsAndReps(rounds: rounds ?? 0, reps: reps ?? 0)
        case .reps:
            return WorkoutNumberFieldRow.number(totalRepsText).map { .reps(Int($0)) }
        case .load:
            return WorkoutNumberFieldRow.number(loadText).map { .load(kilograms: $0) }
        }
    }

    private func save() {
        let now = clock()
        let interval = WorkoutLogTiming.interval(day: day, pickedDay: pickedDay, endsNow: endsNow, endTime: endTime,
                                                 durationMinutes: durationMinutes, now: now, calendar: calendar)
        let result: WODResult
        do {
            result = WODResult(format: format, name: name, movements: movements.components(separatedBy: .newlines),
                               timeCapSeconds: capMinutes.map { $0 * 60 }, score: try score(),
                               capped: format.canBeCapped && capped, scaling: scaling, scalingNote: scalingNote)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        var entry = WorkoutLogEntry(activity: .crossfit, startedAt: interval.start, endedAt: interval.end,
                                    notes: notes, wod: result)
        if let editing, let original = WorkoutLogEntry(record: editing) {
            let sameTime = !endsNow && calendar.isDate(endTime, equalTo: original.endedAt, toGranularity: .minute)
                && day == WorkoutLogTiming.day(for: original.endedAt, now: now, calendar: calendar)
                && durationMinutes == max(1, Int(original.endedAt.timeIntervalSince(original.startedAt) / 60))
            var kept = original
            kept.activity = .crossfit
            kept.notes = notes
            kept.wod = result
            if !sameTime { kept.startedAt = interval.start; kept.endedAt = interval.end }
            entry = kept
        }
        do { _ = try entry.validated(now: now, allowingFuture: mode == .edit) }
        catch { errorMessage = error.localizedDescription; return }
        isSaving = true
        errorMessage = nil
        let earlier = records.filter { $0.id != editing?.id }
        let inCurrentWeek = calendar.isDate(entry.startedAt, equalTo: now, toGranularity: .weekOfYear)
        Task { @MainActor in
            do {
                let record = try await onSave(entry)
                // A new WOD shows its result first (R2-WOD-09); an edit goes straight back.
                if mode == .create {
                    saved = WODSaveSummary(result: record.wod ?? result.cleaned,
                                           earlier: earlier.filter { $0.id != record.id }, inCurrentWeek: inCurrentWeek)
                } else {
                    route(.finish)
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            isSaving = false
        }
    }
}

enum WODLogInputError: Error, LocalizedError {
    case time
    var errorDescription: String? { "Type the minutes, and seconds from 0 to 59." }
}
