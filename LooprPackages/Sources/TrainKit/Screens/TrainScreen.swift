import DesignSystem
import SwiftUI
import WorkoutKit

/// What a tap on the Train overview asks the app to do.
public enum TrainOverviewAction {
    /// A route Workouts already had: the start picker, interval timer, manual log or a detected workout.
    case workoutRoute(WorkoutRoute)
    /// A saved session row. `.detail`, or `.recovery` for an interrupted one.
    case workout(WorkoutRoute, WorkoutRecord)
    /// Start today's session.
    case startSession(TrainTodayPlan)
    /// Start a strength workout from a template, or an empty one with nil.
    case startWorkout(UUID?)
    /// Start any saved template now: a strength one opens the set log, a cardio one starts recording.
    case startTemplate(UUID)
    /// A finished gym session's sets: the Train summary, by session id (R1-LIFT-03, R1-NEW-11).
    case openSession(UUID)
    /// Every exercise logged, with bests and history.
    case openExercises
    /// Hard sets per muscle group this week (R2-LIFT-06).
    case openMuscleVolume
    case openTemplate(UUID)
    case newTemplate
    case openProgram(UUID)
    case newProgram
    /// Accept an agent draft. The app saves it as an active program.
    case acceptDraft(TrainDraftSummary)
    /// Discard an agent draft and the templates it carried.
    case discardDraft(TrainDraftSummary)
    /// The Protocol tab, where the weekly targets are set (R2-NEW-06).
    case openProtocol
    /// Add the starter week's rules to the protocol (R2-NEW-06, R1-NEW-03).
    case useStarterWeek
    /// Save the beginner's full-body workout and start it (R3-NEW-01).
    case startStarterRoutine
}

/// The Fitness tab (DEC-12.1, LV-06.2), in the order round 1 of the Fitness review set (R1-DES-06, R1-NEW-10,
/// R1-VET-03, R1-WOD-12): the week strip with a dot per session, today's short card, the dose field, a slim row for
/// anything the band found, one rail of starts, this week's sessions as flat rows, then two folds: Plans (saved
/// workouts and programs) and Fitness checks (VO₂max and the capacity tests). The tab draws its colour field in the
/// Fitness accent and plays its entrance once a day.
///
/// The screen keeps the Workouts and Train identifiers that still name something (DEC-10): `workouts-screen`,
/// `workouts-header-start`, `workouts-start` (the Run chip), `workouts-manual-entry` (the Log chip),
/// `workout-detected-row-*`, `workout-row-*`, `train-header-ask` and the `train-*` controls. The interval timer moved
/// into the start sheet (`train-start-intervals`).
public struct TrainScreen: View {
    @ObservedObject private var viewModel: WorkoutViewModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.looprMeasurementSystem) private var measurementSystem
    @Environment(\.looprAsk) private var ask
    @State private var showingSwap = false
    @State private var showingStart = false
    @State private var fitnessEntrance = false
    @State private var capacityTest: FitnessCapacityFlowRequest?
    @State private var pendingLanding: FitnessCapacityLanding?
    @State private var capacityLanding: FitnessCapacityLanding?
    /// "Fitness checks" open: the VO₂max gauge and the capacity tests.
    @State private var showsFitnessChecks = LooprFoldSummary.opensForCapture
    /// "Plans" open: saved workouts and programs.
    @State private var showsPlans = LooprFoldSummary.opensForCapture
    /// The week strip's selected day. Nil is today.
    @State private var selectedDay: String?
    private let overview: TrainOverview?
    private let fitness: FitnessOverview?
    private let capacityActions: FitnessCapacityActions?
    private let failure: String?
    private let swap: @MainActor (UUID?) -> Void
    private let action: @MainActor (TrainOverviewAction) -> Void

    /// - Parameters:
    ///   - overview: Nil while the first load runs.
    ///   - fitness: The dose, the VO₂max gauge and the capacity tests. Nil while they load.
    ///   - failure: A sentence when the saved plans could not load. The quick starts still work.
    ///   - swap: Called with the template the person picked for today.
    ///   - capacityActions: Where the capacity tests save results and goals. Nil makes the tests read only.
    public init(viewModel: WorkoutViewModel, overview: TrainOverview?, fitness: FitnessOverview? = nil,
                capacityActions: FitnessCapacityActions? = nil, failure: String? = nil,
                swap: @escaping @MainActor (UUID?) -> Void = { _ in },
                action: @escaping @MainActor (TrainOverviewAction) -> Void) {
        self.viewModel = viewModel
        self.overview = overview
        self.fitness = fitness
        self.capacityActions = capacityActions
        self.failure = failure
        self.swap = swap
        self.action = action
    }

    public var body: some View {
        LooprTabScaffold(header: header, glow: .fitnessTab, field: .fitness, identifier: "workouts-screen") {
            LooprPhaseContainer(phase: phase) { phaseContent }
        }
        .navigationTitle("")
        // Once a day the dots drop in, the plates slide on and the needle sweeps up. The flag drops back
        // after the entrance, so a view rebuilt later shows its final state.
        .looprEntrance(tab: LooprColorFieldTab.fitness.rawValue, animates: $fitnessEntrance, duration: Self.entranceDuration)
        .task(id: fitnessEntrance) {
            guard fitnessEntrance else { return }
            try? await Task.sleep(for: .seconds(Self.entranceDuration + 0.3))
            guard !Task.isCancelled else { return }
            fitnessEntrance = false
        }
        // A test is a focus screen over the tab. A saved result flies into its tile once the test has closed.
        .fullScreenCover(item: $capacityTest, onDismiss: {
            capacityLanding = pendingLanding
            pendingLanding = nil
        }) { request in
            if let tile = fitness?.tile(request.kind) {
                FitnessCapacityTestScreen(tile: tile, actions: capacityActions) { pendingLanding = $0 }
            }
        }
        .sheet(isPresented: $showingSwap) {
            TrainSwapSheet(choices: overview?.swapChoices ?? []) { id in
                showingSwap = false
                swap(id)
            }
        }
        .sheet(isPresented: $showingStart) {
            TrainStartSheet(templates: overview?.templates ?? []) { choice in
                showingStart = false
                switch choice {
                case .gym(let id): action(.startWorkout(id))
                case .template(let id): action(.startTemplate(id))
                case .activity(let activity): action(.workoutRoute(.prepare(activity)))
                case .intervals: action(.workoutRoute(.intervals))
                // The clock starts from the WOD log, so the name, format and cap are set before it runs (R2-WOD-01).
                case .wodClock: action(.workoutRoute(.wod))
                case .starterRoutine: action(.startStarterRoutine)
                case .logPast: action(.workoutRoute(.log))
                case .newTemplate: action(.newTemplate)
                }
            }
        }
    }

    /// Long enough for the last dot of a full week to land.
    static let entranceDuration = 2.0

    // MARK: Header

    private var header: LooprTabHeaderContent {
        LooprTabHeaderContent(
            title: "Fitness",
            accent: .fitnessTab,
            dayPhrase: fitness?.meta ?? overview?.headerMeta ?? weeklyHeaderMeta,
            // Train is not a day tab: mock 10 shows the week and program, not band sync age.
            freshness: .hidden,
            control: .action(LooprHeaderAction(
                symbol: "plus",
                label: "Start a workout",
                identifier: "workouts-header-start",
                run: { showingStart = true }
            )),
            // The Ask button keeps the identifier it had when this tab was called Train. The shell's `looprAsk` replaces
            // its empty action with the Ask sheet, so it is not a dead button (R1-DES-21).
            secondaryAction: LooprHeaderAction(symbol: "sparkles", label: "Ask", identifier: "train-header-ask", run: {})
        )
    }

    /// "3 this week" while no program is running. Nothing while the list loads.
    private var weeklyHeaderMeta: String? {
        guard viewModel.snapshot.state != .loading else { return nil }
        return sections.headerMeta
    }

    /// This week is the ISO week the strip and the dose show, Monday first, in the tab's time zone.
    private var sections: WorkoutListSections {
        var calendar = overview?.calendar ?? Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        return WorkoutListSections(workouts: viewModel.snapshot.value ?? [], now: viewModel.listReferenceDate, calendar: calendar)
    }

    private var phase: LooprLoadPhase {
        if overview == nil, failure == nil { return .loading }
        return viewModel.snapshot.state == .loading ? .loading : .content
    }

    // MARK: Content

    @ViewBuilder
    private var phaseContent: some View {
        if phase == .loading {
            LooprLoadingPlaceholder(.cards(4))
        } else {
            VStack(alignment: .leading, spacing: LooprSpacing.tabSection) {
                if let failure { failureCard(failure) }
                // The week and today, then the dose as the answer to "did this week give me enough", with anything the
                // band found right under it. Then one rail of starts, the log, and the two folds (R1-DES-06).
                // A new person meets the starts first, then the starter week (R2-DES-09, R2-NEW-06).
                if isNewPerson { startRail }
                VStack(alignment: .leading, spacing: LooprSpacing.cardStack) {
                    if let overview {
                        if overview.showsWeekStrip { weekStrip(overview) }
                        todayCard(overview)
                    }
                    if let fitness {
                        FitnessDoseField(dose: fitness.dose, entrance: fitnessEntrance,
                                         openProtocol: { action(.openProtocol) }, useStarterWeek: { action(.useStarterWeek) })
                    }
                    if fitness != nil, !isNewPerson { muscleVolumeRow }
                    if !viewModel.detectedWorkouts.isEmpty { detectedRows }
                }
                if !isNewPerson { startRail }
                workoutSections(overview)
                if let overview { plansSection(overview) }
                if let fitness { fitnessSections(fitness) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, LooprSpacing.screenGutter)
            .padding(.top, LooprSpacing.tabContentTop)
            .looprDotFlightHost()
        }
    }

    /// No plans, no targets and nothing logged this week.
    private var isNewPerson: Bool {
        (overview?.isEmpty ?? true) && (fitness?.dose.isBlank ?? false) && sections.thisWeek.isEmpty
    }

    // MARK: Hard sets

    /// "Hard sets this week", right under the dose field, opening one bar per muscle group (R2-LIFT-06).
    private var muscleVolumeRow: some View {
        LooprCard(density: .flush) {
            LooprNavigationRow(title: "Hard sets this week", caption: "Working sets per muscle group", accent: .fitnessTab,
                               accessibilityLabel: "Hard sets this week, working sets per muscle group",
                               identifier: "train-muscle-volume", showsDivider: false) { action(.openMuscleVolume) }
        }
    }

    // MARK: Fitness

    /// The VO₂max gauge and the capacity instruments behind one "Fitness checks" row, last on the tab. They are the
    /// expert half of the tab and took two screens above everything else (UX R1-NEW-20, R1-VET-15).
    @ViewBuilder
    private func fitnessSections(_ fitness: FitnessOverview) -> some View {
        // A result landing in its tile opens the fold, so the flight has somewhere to land.
        LooprFoldSection("Fitness checks", summary: FitnessChecksSummary.text(fitness), identifier: "fitness-checks",
                         isOpen: Binding(get: { showsFitnessChecks || capacityLanding != nil },
                                         set: { showsFitnessChecks = $0 })) {
            FitnessVO2MaxCard(vo2Max: fitness.vo2Max, progress: fitness.vo2MaxProgress, entrance: fitnessEntrance)
            FitnessCapacityTiles(tiles: fitness.capacity, heartRateRecovery: fitness.heartRateRecovery, landing: capacityLanding,
                                 open: { capacityTest = FitnessCapacityFlowRequest(kind: $0.kind) },
                                 landed: { capacityLanding = nil })
        }
    }

    private func failureCard(_ message: String) -> some View {
        LooprCard {
            VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                StatusChip("Could not load plans", symbol: "exclamationmark.triangle", tone: .warning)
                LooprText(message, style: .prose, color: .inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("train-load-failure")
    }

    // MARK: Week strip

    /// The strip in dot mode (R1-DES-15, R1-NEW-12, R1-LIFT-18): a dot per session, today ringed, and the selected day's
    /// caption on one line underneath, where it has the full width. The line opens that day's template when it has one.
    private func weekStrip(_ overview: TrainOverview) -> some View {
        let workouts = viewModel.snapshot.value ?? []
        let gymWorkouts = Set(overview.sessionsByWorkoutID.keys)
        let marked = overview.week.map { day in
            (day, TrainWeekMarks.day(day, workouts: workouts, gymWorkoutIDs: gymWorkouts, calendar: overview.calendar))
        }
        let days = marked.map { day, marks in
            LooprWeekStripDay(identifier: day.id, weekdayLetter: day.letter, dateNumeral: day.numeral, caption: marks.caption,
                              isDone: day.isDone, isToday: day.isToday, accessibilityLabel: Self.spokenDay(day, marks: marks.marks),
                              marks: marks.marks)
        }
        let selected = marked.first { $0.0.id == selectedDay } ?? marked.first { $0.0.isToday } ?? marked.first
        return VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprWeekStrip(days: days, accent: .fitnessTab, identifier: "train-week-strip",
                           selection: selected?.0.id) { day in selectedDay = day.identifier }
            if let selected { dayCaption(selected.0, marks: selected.1) }
        }
    }

    /// "Tuesday 14 November, Upper A, today, 2 planned".
    static func spokenDay(_ day: TrainWeekDay, marks: [LooprWeekStripMark]) -> String {
        let done = marks.filter { $0 == .done }.count
        let planned = marks.count - done
        var parts = [day.spokenLabel]
        if done > 0 { parts.append("\(done) done") }
        if planned > 0 { parts.append("\(planned) planned") }
        return parts.joined(separator: ", ")
    }

    /// "Done today: CrossFit, cycling, stretching." (R2-DES-15)
    private func dayCaption(_ day: TrainWeekDay, marks: TrainWeekMarkDay) -> some View {
        let text = marks.line(day: day.isToday ? "today" : TrainOverviewModel.dayLabel(localDay: day.localDay))
        return Group {
            if let id = day.templateID {
                Button { action(.openTemplate(id)) } label: {
                    HStack(spacing: LooprSpacing.sm) {
                        LooprText(text, style: .label)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: LooprSpacing.xs)
                        LooprChevron()
                    }
                    .padding(.horizontal, LooprSpacing.xxs)
                    .frame(maxWidth: .infinity, minHeight: LooprSpacing.interactiveRowHeight, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.looprPressableRow)
                .accessibilityHint("Opens the workout to edit")
            } else {
                LooprText(text, style: .label, color: .inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, LooprSpacing.xxs)
            }
        }
        .accessibilityIdentifier("train-week-caption")
    }

    // MARK: Today

    /// One card for today (R2-NEW-03, R2-VET-01, R2-DES-06, R2-WOD-04). Once the day has sessions it reads "Done
    /// today" with what counted and offers the plan as optional; the protocol's daily Zone 2 is a line on the card, done
    /// when today's measured minutes meet it.
    @ViewBuilder
    private func todayCard(_ overview: TrainOverview) -> some View {
        let card = TrainTodayCard.make(overview: overview, workouts: viewModel.snapshot.value ?? [],
                                       todayZone2Minutes: fitness?.dose.today?.zone2Minutes)
        if let card, card.isDone {
            doneCard(card, overview: overview)
        } else {
            switch overview.today {
            case .none:
                // Nothing planned: the start rail is the card (UX R1-DES-03).
                EmptyView()
            case .plan(let plan):
                planCard(plan, rule: card, canSwap: !overview.swapChoices.isEmpty)
            case .done(let session):
                heroCard(chips: { todayChip; StatusChip("Done", symbol: "checkmark.circle", tone: .positive) },
                         title: session.name, line: session.detail.isEmpty ? "Done for today." : session.detail,
                         spoken: "Today. \(session.spokenLabel), done") { EmptyView() }
            case .rest(let next):
                heroCard(chips: { todayChip; recoveryChip(overview.todayRecovery) }, title: "Rest day",
                         line: next.map { "Nothing planned today. Next is \($0)." } ?? "Nothing planned today.",
                         rule: card?.rule.map { ($0, card?.ruleIsDone ?? false) },
                         spoken: "Today. Rest day. \(card?.rule ?? "")") {
                    if !overview.swapChoices.isEmpty {
                        Button("Choose a session") { showingSwap = true }
                            .buttonStyle(LooprButtonStyle(prominent: false, accent: .fitnessTab))
                            .accessibilityIdentifier("train-swap")
                    }
                }
            }
        }
    }

    private var todayChip: some View { startChip(minute: nil) }

    /// "Today", or "Today · 18:00" when the planned session has a start time.
    private func startChip(minute: Int?) -> some View {
        StatusChip(minute.map { "Today · \(TrainClockText.time(minute: $0))" } ?? "Today", symbol: nil, accent: .fitnessTab)
    }

    /// "Recovery 79" in its band's colour, or nothing without a reading.
    @ViewBuilder
    private func recoveryChip(_ shown: Int?) -> some View {
        if let shown, let band = LooprRecoveryBand(score: Double(shown)) {
            StatusChip("Recovery \(shown)", symbol: nil, accent: band.token)
        }
    }

    /// The day already has sessions: a short card under the strip, which already names them (R3-DES-03). It says what
    /// they counted, the protocol's Zone 2, and the planned session as one optional line with a small Start, so the
    /// dose field still reaches the first screen.
    private func doneCard(_ card: TrainTodayCard, overview: TrainOverview) -> some View {
        let plan = card.plan
        var spoken = "Today. \(TrainTodayCard.doneTitle). \(card.doneLine ?? "")"
        if let counted = card.countedLine { spoken += " \(counted)" }
        if let rule = card.rule { spoken += " \(rule)." }
        if let plan { spoken += " Optional: \(plan.name), \(Self.optionalLine(plan))." }
        if let recovery = plan?.recoveryShown ?? overview.todayRecovery { spoken += " Recovery is \(recovery)." }
        return LooprCard {
            VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.xs) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.loopr(.fitnessTab))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        LooprText(TrainTodayCard.doneTitle, style: .rowTitle)
                        if let counted = card.countedLine ?? card.doneLine {
                            LooprText(counted, style: .caption, color: .inkSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let rule = card.rule {
                            LooprText(rule, style: .caption, color: card.ruleIsDone ? .inkSecondary : .ink)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("train-today-rule")
                        }
                    }
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(spoken)
                .accessibilityIdentifier("train-today-summary")
                if let plan {
                    HStack(spacing: LooprSpacing.sm) {
                        LooprText("\(plan.name) is optional\(plan.startMinute.map { " · \(TrainClockText.time(minute: $0))" } ?? "")",
                                  style: .caption, color: .inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("train-today-optional")
                        Spacer(minLength: LooprSpacing.sm)
                        if !overview.swapChoices.isEmpty {
                            Button("Swap") { showingSwap = true }
                                .buttonStyle(LooprButtonStyle(prominent: false, accent: .fitnessTab, quiet: true))
                                .fixedSize()
                                .accessibilityHint("Choose another session for today")
                                .accessibilityIdentifier("train-swap")
                        }
                        Button("Start") { action(.startSession(plan)) }
                            .buttonStyle(LooprButtonStyle(prominent: false, accent: .fitnessTab))
                            .fixedSize()
                            .accessibilityLabel("Start \(plan.name)")
                            .accessibilityIdentifier("train-start")
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("train-today-card")
    }

    /// "Optional · 18:30 · 6 exercises · about 55 min".
    static func optionalLine(_ plan: TrainTodayPlan) -> String {
        let line = plan.summary.isEmpty ? plan.detail : plan.summary
        return (["Optional"] + [plan.startMinute.map(TrainClockText.time(minute:))].compactMap { $0 } + [line])
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// Title, one line, the chips, and Start as the one primary button with Swap as text beside it (R1-NEW-09,
    /// R1-LIFT-18, blueprint 6.2). The protocol's daily Zone 2 is a line under the title, not a second plan in a chip
    /// (R2-NEW-03). A line of reasons appears only when recovery or the program changed the session.
    private func planCard(_ plan: TrainTodayPlan, rule card: TrainTodayCard?, canSwap: Bool) -> some View {
        let band = LooprRecoveryBand(score: plan.recoveryScore)
        let line = plan.summary.isEmpty ? plan.detail : plan.summary
        var reasons: [String] = []
        if plan.recoveryAdjusts, let message = plan.recoveryMessage { reasons.append(message) }
        if let note = plan.scheduleNote { reasons.append(note) }
        var spoken = "Today. \(plan.name). \(line)."
        if let message = plan.recoveryMessage { spoken += " \(message)" }
        if let note = plan.scheduleNote { spoken += " \(note)" }
        if let rule = card?.rule { spoken += " \(rule)." }
        return heroCard(
            chips: {
                startChip(minute: plan.startMinute)
                if let shown = plan.recoveryShown, let band {
                    StatusChip("Recovery \(shown)", symbol: nil, accent: band.token)
                } else if plan.kind == .strength {
                    StatusChip("No recovery reading", symbol: nil, tone: .neutral)
                }
                if plan.isLight { StatusChip("Lighter week", symbol: nil, tone: .neutral) }
            },
            title: plan.name, line: line, reasons: reasons, rule: card?.rule.map { ($0, card?.ruleIsDone ?? false) },
            spoken: spoken
        ) {
            planButtons(plan, canSwap: canSwap)
        }
    }

    /// Swap as text and Start as the one primary button. At accessibility sizes the two stack, so neither label is cut.
    private func planButtons(_ plan: TrainTodayPlan, canSwap: Bool) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: LooprSpacing.xs))
            : AnyLayout(HStackLayout(spacing: LooprSpacing.xs))
        return layout {
            Button { showingSwap = true } label: {
                Text("Swap").padding(.horizontal, LooprSpacing.sm)
            }
            .buttonStyle(LooprButtonStyle(prominent: false, accent: .fitnessTab, quiet: true))
            .fixedSize(horizontal: true, vertical: false)
            .disabled(!canSwap)
            .accessibilityHint(canSwap ? "Choose another session for today" : "Save another template to swap")
            .accessibilityIdentifier("train-swap")
            Button("Start") { action(.startSession(plan)) }
                .buttonStyle(LooprButtonStyle(accent: .fitnessTab))
                .accessibilityIdentifier("train-start")
        }
    }

    /// The one hero: chips, title, one line, an optional line of reasons, the protocol's rule, then the buttons.
    private func heroCard<Chips: View, Buttons: View>(
        @ViewBuilder chips: () -> Chips, title: String, line: String, reasons: [String] = [],
        rule: (text: String, done: Bool)? = nil, spoken: String,
        @ViewBuilder buttons: () -> Buttons
    ) -> some View {
        LooprSurface(emphasis: .hero(.fitnessTab)) {
            VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                TrainChipFlow(spacing: LooprSpacing.xs) { chips() }
                VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                    LooprText(title, style: .titleLarge)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    if !line.isEmpty {
                        LooprText(line, style: .prose, color: .inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(Array(reasons.enumerated()), id: \.offset) { _, reason in
                        LooprText(reason, style: .caption, color: .inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let rule {
                    HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.xs) {
                        Image(systemName: rule.done ? "checkmark.circle.fill" : "list.bullet.clipboard")
                            .foregroundStyle(rule.done ? Color.loopr(.fitnessTab) : Color.loopr(.inkSecondary))
                            .accessibilityHidden(true)
                        LooprText(rule.text, style: .label, color: rule.done ? .ink : .inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("train-today-rule")
                }
                buttons()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(spoken)
        .accessibilityIdentifier("train-today-card")
    }

    // MARK: Start

    /// One start surface (R1-DES-07, R1-NEW-02, R2-NEW-01): capsule chips with Gym, Walk and Log pinned, recent
    /// activities filling the rest, and More last. Gym leads in every state (R1-LIFT-12). The chips wrap onto a second line instead
    /// of scrolling sideways, so Log and More are never hidden off the edge. Each chip that replaced an older tile also
    /// carries that tile's identifier on a wrapper, so older tests and tours still find it.
    private var startRail: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprSectionHeader("Start", identifier: "train-start-header")
            TrainChipFlow(spacing: LooprSpacing.xs) {
                ForEach(TrainStartRail.items(recent: viewModel.snapshot.value ?? []), id: \.self) { item in
                    railChip(item)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("train-rail")
        }
    }

    @ViewBuilder
    private func railChip(_ item: TrainRailItem) -> some View {
        let chip = TrainRailChip(title: item.title, symbol: item.symbol, spoken: item.spokenLabel, identifier: item.identifier,
                                 prominent: item == .gym && !hasPlanToday) { start(item) }
        if let legacy = item.legacyIdentifier {
            HStack(spacing: 0) { chip }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(legacy)
        } else {
            chip
        }
    }

    private func start(_ item: TrainRailItem) {
        switch item {
        case .gym, .more: showingStart = true
        case .activity(let activity): action(.workoutRoute(.prepare(activity)))
        case .log: action(.workoutRoute(.log))
        }
    }

    private var hasPlanToday: Bool {
        if case .plan? = overview?.today { return true }
        return false
    }

    // MARK: Pending

    /// A workout the band found, as one slim row under the dose (R1-DES-14, R2-DES-02): "Band saw a 10 min run" on one
    /// line, "6:20, not saved yet" under it, Review on the right. Where the title would wrap, the badge goes first, then
    /// Review moves under the text, so the row grows instead of spilling out of its card. It is not counted until saved.
    @ViewBuilder
    private var detectedRows: some View {
        ForEach(viewModel.detectedWorkouts, id: \.detectionID) { detection in
            Button { action(.workoutRoute(.detectedReview(detection))) } label: {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: LooprSpacing.sm) {
                        TrainActivityBadge(symbol: detection.activity.symbolName, size: 36)
                        pendingText(detection, oneLine: true)
                        Spacer(minLength: LooprSpacing.xs)
                        reviewCapsule
                    }
                    HStack(spacing: LooprSpacing.sm) {
                        pendingText(detection, oneLine: true)
                        Spacer(minLength: LooprSpacing.xs)
                        reviewCapsule
                    }
                    VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                        pendingText(detection, oneLine: false)
                        reviewCapsule
                    }
                }
                .padding(.horizontal, LooprSpacing.cardHorizontal)
                .padding(.vertical, LooprSpacing.xs)
                .frame(maxWidth: .infinity, minHeight: LooprSpacing.interactiveRowHeight, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .looprCardBackground(density: .compact)
                .contentShape(Rectangle())
            }
            .buttonStyle(.looprPressableCard)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(TrainRowText.pendingTitle(detection)). \(Self.pendingCaption(detection)). Review")
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("workout-detected-row-\(detection.detectionID)")
        }
    }

    private func pendingText(_ detection: DetectedWorkout, oneLine: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            LooprText(TrainRowText.pendingTitle(detection), style: .rowTitle)
                .lineLimit(oneLine ? 1 : nil)
                .fixedSize(horizontal: oneLine, vertical: true)
            LooprText(Self.pendingCaption(detection), style: .caption, color: .inkSecondary)
                .lineLimit(oneLine ? 1 : nil)
                .fixedSize(horizontal: oneLine, vertical: true)
        }
    }

    private var reviewCapsule: some View {
        Text("Review")
            .looprTypography(.label)
            .foregroundStyle(LooprColorToken.fitnessTab.tintedLabelColor)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, LooprSpacing.sm)
            .padding(.vertical, LooprSpacing.xxs + 2)
            .background(Color.loopr(.fitnessTab).opacity(0.12), in: Capsule(style: .continuous))
    }

    /// "6:20, not saved yet". The start time follows the phone's 12 or 24 hour setting.
    static func pendingCaption(_ detection: DetectedWorkout) -> String {
        TrainRowText.pendingCaption(detection)
    }

    /// "07:10 · 34 min · Review before saving". The start time follows the phone's 12 or 24 hour setting.
    static func detectedLine(_ detection: DetectedWorkout) -> String {
        let minutes = Int((detection.endedAt.timeIntervalSince(detection.startedAt) / 60).rounded())
        // "Started 06:20" so the time does not read as a pace or a duration (R3-OPT-10).
        var parts = ["Started " + detection.startedAt.formatted(date: .omitted, time: .shortened)]
        if minutes > 0 { parts.append("\(minutes) min") }
        parts.append("Review before saving")
        return parts.joined(separator: " · ")
    }

    // MARK: Plans

    /// Agent drafts stay above the fold, since they wait for an answer. Saved workouts and programs live behind one
    /// "Plans" row (R1-DES-06, R1-NEW-10, R1-WOD-12): they repeat the start sheet and made the tab 12 screens long.
    @ViewBuilder
    private func plansSection(_ overview: TrainOverview) -> some View {
        if !overview.drafts.isEmpty {
            VStack(alignment: .leading, spacing: LooprSpacing.cardStack) {
                ForEach(overview.drafts) { draft in draftCard(draft) }
            }
        }
        LooprFoldSection("Plans", summary: Self.plansSummary(overview), identifier: "train-plans", isOpen: $showsPlans) {
            templatesSection(overview)
            programsSection(overview)
        }
    }

    /// "5 saved workouts · Strength block, week 3 of 8".
    static func plansSummary(_ overview: TrainOverview) -> String {
        let count = overview.templates.count
        let workouts = count == 0 ? "No saved workouts" : count == 1 ? "1 saved workout" : "\(count) saved workouts"
        let running = overview.programs.first { $0.status == .active && $0.value != nil }
        let programs: String
        if let running, let value = running.value, let unit = running.valueUnit {
            programs = "\(running.name), week \(value) \(unit)"
        } else {
            programs = overview.programs.isEmpty ? "no programs" : overview.programs.count == 1 ? "1 program" : "\(overview.programs.count) programs"
        }
        return "\(workouts) · \(programs)"
    }

    private func programsSection(_ overview: TrainOverview) -> some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprSectionHeader("Programs", actionTitle: "New", accent: .fitnessTab, identifier: "train-programs-header",
                               actionIdentifier: "train-program-new") { action(.newProgram) }
            if overview.programs.isEmpty {
                if overview.drafts.isEmpty { emptyListCard("No programs yet.") }
            } else {
                LooprCard(density: .flush) {
                    VStack(spacing: LooprSpacing.none) {
                        ForEach(Array(overview.programs.enumerated()), id: \.element.id) { index, program in
                            LooprNavigationRow(
                                title: program.name, caption: program.caption, progress: program.progress,
                                value: program.value, valueUnit: program.valueUnit, accent: .fitnessTab,
                                accessibilityLabel: program.spokenLabel, identifier: "train-program-\(program.slug)",
                                showsDivider: index < overview.programs.count - 1
                            ) { action(.openProgram(program.id)) }
                        }
                    }
                }
            }
        }
    }

    /// A draft from Ask. It sits above the programs and does nothing until the person accepts it.
    private func draftCard(_ draft: TrainDraftSummary) -> some View {
        LooprCard(style: .warning) {
            VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                Button { action(.openProgram(draft.id)) } label: {
                    HStack(spacing: LooprSpacing.sm) {
                        VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                            StatusChip("Draft", symbol: "sparkles", tone: .warning)
                            LooprText(draft.name, style: .rowTitle)
                            LooprText(draft.caption, style: .caption, color: .inkSecondary)
                        }
                        Spacer(minLength: LooprSpacing.sm)
                        LooprChevron()
                    }
                    .frame(minHeight: LooprSpacing.interactiveRowHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.looprPressableRow)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(draft.spokenLabel)
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("train-program-\(draft.slug)")
                LooprText(ProgramScreenModel.draftMessage, style: .prose, color: .inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                let layout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(spacing: LooprSpacing.sm))
                    : AnyLayout(HStackLayout(spacing: LooprSpacing.sm))
                layout {
                    Button("Discard") { action(.discardDraft(draft)) }
                        .buttonStyle(LooprButtonStyle(prominent: false, accent: .fitnessTab))
                        .accessibilityIdentifier("program-draft-discard-\(draft.slug)")
                    Button("Accept") { action(.acceptDraft(draft)) }
                        .buttonStyle(LooprButtonStyle(accent: .fitnessTab))
                        .accessibilityIdentifier("program-draft-accept-\(draft.slug)")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("train-draft-\(draft.slug)")
    }

    private func templatesSection(_ overview: TrainOverview) -> some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprSectionHeader("Your workouts", actionTitle: "New", accent: .fitnessTab, identifier: "train-templates-header",
                               actionIdentifier: "train-template-new") { action(.newTemplate) }
            if overview.templates.isEmpty {
                emptyListCard("Save a workout you repeat and start it here with one tap.")
            } else {
                LooprCard(density: .flush) {
                    VStack(spacing: LooprSpacing.none) {
                        ForEach(Array(overview.templates.enumerated()), id: \.element.id) { index, template in
                            if index > 0 {
                                Rectangle().fill(Color.loopr(.divider)).frame(height: LooprSpacing.hairline)
                                    .padding(.leading, LooprSpacing.cardHorizontal + 44 + LooprSpacing.sm).accessibilityHidden(true)
                            }
                            templateRow(template)
                        }
                    }
                }
            }
        }
    }

    /// A saved workout: a tap on the name edits it, the play button starts it.
    private func templateRow(_ template: TrainTemplateSummary) -> some View {
        HStack(spacing: LooprSpacing.sm) {
            Button { action(.openTemplate(template.id)) } label: {
                HStack(spacing: LooprSpacing.sm) {
                    TrainKindBadge(kind: template.kind)
                    VStack(alignment: .leading, spacing: 2) {
                        LooprText(template.name, style: .rowTitle)
                            .fixedSize(horizontal: false, vertical: true)
                        LooprText(template.caption, style: .caption, color: .inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: LooprSpacing.interactiveRowHeight + 8, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.looprPressableRow)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(template.spokenLabel)
            .accessibilityHint("Opens the workout to edit")
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("train-template-\(template.slug)")
            Button { action(.startTemplate(template.id)) } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(LooprColorToken.fitnessTab.filledLabelColor)
                    .frame(width: 44, height: 44)
                    .background(Color.loopr(.fitnessTab), in: Circle())
                    .frame(width: LooprSpacing.interactiveRowHeight, height: LooprSpacing.interactiveRowHeight)
                    .contentShape(Circle())
            }
            .buttonStyle(.looprPressableRow)
            .accessibilityLabel("Start \(template.name)")
            .accessibilityIdentifier("train-play-\(template.slug)")
        }
        .padding(.leading, LooprSpacing.cardHorizontal)
        .padding(.trailing, LooprSpacing.xs)
    }

    private func emptyListCard(_ text: String) -> some View {
        LooprCard {
            LooprText(text, style: .prose, color: .inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Sessions

    /// This week and Earlier as flat rows (R1-DES-16, R1-LIFT-13): glyph, name and day, the numbers on the right, a
    /// chevron. Only an exception gets a pill, and an unsaved workout says on its own row why it is not counted.
    @ViewBuilder
    private func workoutSections(_ overview: TrainOverview?) -> some View {
        let sections = sections
        let now = viewModel.listReferenceDate
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprSectionHeader("This week", actionTitle: "Exercises", accent: .fitnessTab, identifier: "train-this-week-header",
                               actionIdentifier: "train-exercises") { action(.openExercises) }
            if sections.thisWeek.isEmpty {
                emptyListCard("Nothing logged yet this week.")
            } else {
                sessionList(sections.thisWeek, overview: overview, now: now)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("train-this-week-list")
            }
            if !sections.earlier.isEmpty {
                LooprSectionHeader("Earlier")
                    .padding(.top, LooprSpacing.sm)
                sessionList(sections.earlier, overview: overview, now: now)
            }
        }
    }

    private func sessionList(_ workouts: [WorkoutRecord], overview: TrainOverview?, now: Date) -> some View {
        LooprCard(density: .flush) {
            VStack(spacing: LooprSpacing.none) {
                ForEach(Array(workouts.enumerated()), id: \.element.id) { index, workout in
                    if index > 0 {
                        Rectangle().fill(Color.loopr(.divider)).frame(height: LooprSpacing.hairline)
                            .padding(.leading, LooprSpacing.cardHorizontal + 36 + LooprSpacing.sm).accessibilityHidden(true)
                    }
                    sessionRow(workout, overview: overview, now: now)
                }
            }
        }
    }

    /// A row: the name (a WOD's name with its score, R2-WOD-03), the day and the app that saved it on the left, the
    /// minutes and distance on the right, each on one line (R2-VET-04).
    private func sessionRow(_ workout: WorkoutRecord, overview: TrainOverview?, now: Date) -> some View {
        let summary = overview?.sessionsByWorkoutID[workout.id]
        let title = summary?.name ?? TrainRowText.title(workout)
        let calendar = overview?.calendar ?? .autoupdatingCurrent
        let day = summary?.dayLabel ?? TrainOverviewModel.dayLabel(
            localDay: TrainWeekMarks.localDay(workout.startedAt ?? workout.createdAt, calendar: calendar))
        let caption = summary == nil ? TrainRowText.caption(day: day, workout: workout, system: measurementSystem) : day
        let numbers = summary.flatMap { $0.detail.isEmpty ? nil : $0.detail }
            ?? TrainRowText.numbers(workout, system: measurementSystem)
            ?? TrainRowText.numbers(fromDetailLine: WorkoutSessionPresentation.detailLine(for: workout, system: measurementSystem, now: now))
        let unsaved = workout.state == .interruptedAndRecoverable
        let completed = workout.state == .completed
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: LooprSpacing.xxs))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: LooprSpacing.sm))
        var spoken = "\(summary?.spokenLabel ?? "\(title), \(workout.activity.displayName)"), \(caption)"
        if summary == nil, let numbers { spoken += ", \(numbers)" }
        if unsaved { spoken += ", \(WorkoutSessionPresentation.statusLabel(for: workout.state)). \(TrainRowText.unsavedNote)" }
        else if !completed { spoken += ", \(workout.state.displayName)" }
        return Button {
            // A gym session opens its sets, not the bare workout record (R1-LIFT-03, R1-NEW-11).
            if let summary, completed { action(.openSession(summary.id)) }
            else { action(.workout(unsaved ? .recovery : .detail, workout)) }
        } label: {
            HStack(alignment: .center, spacing: LooprSpacing.sm) {
                TrainActivityBadge(symbol: summary != nil ? ActivityType.strength.symbolName : workout.activity.symbolName, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    layout {
                        LooprText(title, style: .rowTitle)
                            .fixedSize(horizontal: false, vertical: true)
                            .layoutPriority(1)
                        if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: LooprSpacing.xs) }
                        if let numbers {
                            Text(numbers)
                                .looprTypography(.metricUnit)
                                .foregroundStyle(Color.loopr(.ink))
                                .monospacedDigit()
                                .lineLimit(1)
                                .fixedSize(horizontal: !dynamicTypeSize.isAccessibilitySize, vertical: true)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                    LooprText(caption, style: .caption, color: .inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if unsaved {
                        StatusChip(WorkoutSessionPresentation.statusLabel(for: workout.state),
                                   symbol: WorkoutSessionPresentation.statusSymbol(for: workout.state), tone: .warning)
                            .padding(.top, LooprSpacing.xxs)
                        LooprText(TrainRowText.unsavedNote, style: .caption, color: .inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("train-week-unsaved")
                    } else if !completed {
                        StatusChip(workout.state.displayName, symbol: nil, tone: .neutral)
                            .padding(.top, LooprSpacing.xxs)
                    }
                }
                LooprChevron()
            }
            .padding(.horizontal, LooprSpacing.cardHorizontal)
            .padding(.vertical, LooprSpacing.sm)
            .frame(maxWidth: .infinity, minHeight: LooprSpacing.interactiveRowHeight, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.looprPressableRow)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("workout-row-\(workout.id.uuidString)")
    }
}

/// Today's alternatives: every saved template except the one shown.
struct TrainSwapSheet: View {
    let choices: [TrainTemplateSummary]
    let pick: @MainActor (UUID?) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                    LooprText("Pick a session for today. Your plan stays as it is.", style: .prose, color: .inkSecondary)
                        .padding(.horizontal, LooprSpacing.xxs)
                    LooprCard(density: .flush) {
                        VStack(spacing: LooprSpacing.none) {
                            ForEach(Array(choices.enumerated()), id: \.element.id) { index, choice in
                                LooprNavigationRow(
                                    title: choice.name, caption: choice.caption, accent: .fitnessTab,
                                    accessibilityLabel: choice.spokenLabel, identifier: "train-swap-option-\(choice.slug)",
                                    showsDivider: index < choices.count - 1
                                ) { pick(choice.id) }
                            }
                        }
                    }
                }
                .padding(.horizontal, LooprSpacing.screenGutter)
                .padding(.top, LooprSpacing.md)
            }
            .background(Color.loopr(.background).ignoresSafeArea())
            .navigationTitle("Swap today's session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.accessibilityIdentifier("train-swap-cancel")
                }
            }
        }
        .tint(Color.loopr(.fitnessTab))
        .accessibilityIdentifier("train-swap-sheet")
        .presentationDetents([.medium, .large])
    }
}
