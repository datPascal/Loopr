import AnalyticsKit
import DesignSystem
import SwiftUI
import WorkoutKit

/// The strength session in progress: recording card, the set to log, the set table and the rest timer.
///
/// The controls follow the exercise's measure: weight and reps, bodyweight reps with an added or assisting
/// load, a hold with its own timer, or a distance. The set table sits right under them, so the sets already
/// done are on screen without a scroll; the barbell and plate buttons fold behind a Plates row.
///
/// The screen reads one `TrainLiveSession` and changes nothing else. Saving, the rest cue, the
/// Live Activity and navigation belong to the app, which hears about each change through the
/// session's `onChange` and passes `onFinish`.
///
/// Pass closures that run across a suspension as `@Sendable`. In the app that reads
/// `{ @MainActor @Sendable [captures] in ... }`.
public struct TrainLiveScreen: View {
    @ObservedObject private var session: TrainLiveSession
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var rpeTarget: RPETarget?
    @State private var editTarget: EditTarget?
    @State private var showsSwap = false
    @State private var confirmsFinish = false
    @State private var finishing = false
    @State private var finishError: String?
    @State private var pauseError: String?
    @State private var picker: ExerciseLibrary?
    @State private var removeTarget: RemoveTarget?
    @State private var platesExpanded = false
    @State private var holdRunning = false
    /// True once "Add weight" is tapped on a hold. A hold with a load from last time shows it from the start.
    @State private var holdLoadShown = false
    /// Set by "Finish and save": the finish runs once the confirmation sheet is gone.
    @State private var finishAfterDismiss = false

    private let workout: WorkoutRecord?
    private let zones: HeartRateZoneSet?
    private let bandCueAvailable: Bool
    private let onPauseChange: (@MainActor @Sendable (Bool) async throws -> Void)?
    private let onFinish: @MainActor @Sendable () async throws -> Void
    private let createCustom: @Sendable (ExerciseDefinition) async throws -> ExerciseDefinition

    private static let accent: LooprColorToken = .fitnessTab

    private struct RemoveTarget: Identifiable {
        let index: Int
        let name: String
        let loggedSets: Int
        var id: Int { index }
    }

    private struct RPETarget: Identifiable {
        let exerciseIndex: Int
        let setIndex: Int
        let current: Double?
        var id: String { "\(exerciseIndex)-\(setIndex)" }
    }

    private struct EditTarget: Identifiable {
        let exerciseIndex: Int
        let setIndex: Int
        let values: TrainSetValues
        let rpe: Double?
        let tag: LoggedSet.Tag?
        let measure: TrainSetMeasure
        let wasSkipped: Bool
        var id: String { "\(exerciseIndex)-\(setIndex)" }
    }

    /// - Parameters:
    ///   - workout: The linked recording. Nil shows the card without readings.
    ///   - zones: Heart-rate zones for the zone chip.
    ///   - bandCueAvailable: False when the band cannot buzz, so the rest card does not promise it.
    ///   - onPauseChange: Pauses or resumes the recording. Nil hides the menu item.
    ///   - onFinish: Saves the session and moves on. A thrown error shows under the table.
    public init(session: TrainLiveSession, workout: WorkoutRecord?, zones: HeartRateZoneSet? = nil,
                bandCueAvailable: Bool = true,
                onPauseChange: (@MainActor @Sendable (Bool) async throws -> Void)? = nil,
                createCustom: @escaping @Sendable (ExerciseDefinition) async throws -> ExerciseDefinition = { $0 },
                onFinish: @escaping @MainActor @Sendable () async throws -> Void) {
        self.session = session
        self.createCustom = createCustom
        self.workout = workout
        self.zones = zones
        self.bandCueAvailable = bandCueAvailable
        self.onPauseChange = onPauseChange
        self.onFinish = onFinish
    }

    private var model: TrainLiveModel { session.model }
    private var isPaused: Bool { workout?.state == .paused }

    public var body: some View {
        // Only the clock-driven parts tick. Re-rendering the whole screen each second rebuilt the open
        // exercise menu, and a tap that landed during a rebuild did nothing.
        ScrollView {
            VStack(alignment: .leading, spacing: LooprSpacing.cardStack) {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    WorkoutRecordingHero(metrics: WorkoutLiveMetrics(workout: workout, zones: zones, now: session.clock()),
                                         isPaused: isPaused, expectedStrain: model.expectedStrain, style: .strip)
                }
                // While resting, one slim bar: the countdown and the RPE of the set just logged (R2-LIFT-03).
                if let rest = model.rest {
                    restBar(rest, position: model.lastLoggedPosition)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                if model.exerciseCount == 0 {
                    emptyCard
                } else if let position = model.cursor {
                    setSection(at: position)
                    table(forExerciseAt: position.exerciseIndex)
                } else {
                    completeCard
                    if let last = model.session.exercises.indices.last { table(forExerciseAt: last) }
                }
                messages
                if model.exerciseCount > 0 { exerciseList }
                if model.exerciseCount > 0 {
                    Button { openPicker() } label: { Label("Add exercise", systemImage: "plus") }
                        .buttonStyle(LooprButtonStyle(prominent: false, accent: Self.accent))
                        .accessibilityIdentifier("train-add-exercise")
                }
            }
            .padding(.horizontal, LooprSpacing.screenGutter)
            .padding(.top, LooprSpacing.sm)
            // The pinned Log bar sits over the bottom of the scroll, so the last row can always scroll clear of it.
            .padding(.bottom, LooprSpacing.tabSection + LooprSpacing.interactiveRowHeight)
            .animation(LooprMotion.stateChange, value: model.rest == nil)
        }
        // The set log is a focus screen: no tabs, and the button that logs the set is always under the thumb.
        .toolbar(.hidden, for: .tabBar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.cursor != nil {
                logBar
            }
        }
        .scrollEdgeEffectStyle(.hard, for: .top)
        .background(Color.loopr(.background).ignoresSafeArea())
        .navigationTitle(model.session.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Finish") { confirmsFinish = true }
                    .disabled(finishing)
                    .accessibilityIdentifier("train-finish")
            }
        }
        // A sheet, not a confirmation dialog: on iOS 26 the dialog anchored to the toolbar shows as a popover whose
        // buttons a UI test cannot reach, so the summary was out of the tour's reach.
        .sheet(isPresented: $confirmsFinish, onDismiss: {
            if finishAfterDismiss { finishAfterDismiss = false; finish() }
        }) {
            TrainFinishSheet(message: Self.finishMessage(openSets: model.openSetCount, loggedSets: model.countedSetCount,
                                                         logged: model.loggedSummary)) {
                finishAfterDismiss = true
                confirmsFinish = false
            }
        }
        .sheet(item: $rpeTarget) { target in
            TrainRPESheet(current: target.current) { value in
                session.setRPE(value, exerciseIndex: target.exerciseIndex, setIndex: target.setIndex)
            }
        }
        .sheet(item: $editTarget) { target in
            TrainEditSetSheet(setNumber: target.setIndex + 1, measure: target.measure, wasSkipped: target.wasSkipped,
                              values: target.values, tag: target.tag, onDelete: {
                session.removeSet(exerciseIndex: target.exerciseIndex, setIndex: target.setIndex)
            }) { values, tag in
                session.editSet(exerciseIndex: target.exerciseIndex, setIndex: target.setIndex, values: values, rpe: target.rpe)
                if tag != target.tag { session.setTag(tag, exerciseIndex: target.exerciseIndex, setIndex: target.setIndex) }
            }
        }
        .sheet(item: Binding(get: { picker.map(PickerItem.init) }, set: { if $0 == nil { picker = nil } })) { item in
            ExercisePickerScreen(library: item.library, createCustom: createCustom) { choice in
                session.addExercise(choice)
            }
        }
        .confirmationDialog(removeTarget.map { "Remove \($0.name)?" } ?? "", isPresented: Binding(get: { removeTarget != nil }, set: { if !$0 { removeTarget = nil } }),
                            titleVisibility: .visible, presenting: removeTarget) { target in
            Button("Remove", role: .destructive) { session.removeExercise(at: target.index) }
                .accessibilityIdentifier("train-remove-exercise-confirm")
            Button("Keep it", role: .cancel) {}
        } message: { target in
            Text(target.loggedSets == 0 ? "It leaves this workout." : "It leaves this workout with its \(target.loggedSets == 1 ? "logged set" : "\(target.loggedSets) logged sets").")
        }
        .sheet(isPresented: $showsSwap) {
            if let position = model.cursor {
                let line = model.session.exercises[position.exerciseIndex]
                TrainSwapExerciseSheet(
                    currentName: line.exercise.name,
                    loggedSets: line.sets.filter { !$0.skipped }.count,
                    movedSets: model.setsMovedBySwap(at: position.exerciseIndex),
                    options: model.swapOptions(forExerciseAt: position.exerciseIndex)
                ) { choice in session.swapExercise(at: position.exerciseIndex, with: choice) }
            }
        }
        .onChange(of: model.cursor) { _, _ in holdRunning = false; holdLoadShown = false }
        .sensoryFeedback(.impact(weight: .medium), trigger: model.countedSetCount)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("train-live-screen")
    }

    /// What the finish dialog says: what was logged, and what is left open.
    public static func finishMessage(openSets: Int, loggedSets: Int, logged: String? = nil) -> String {
        let done = logged.map { "Logged \($0)." }
        if openSets == 0 { return done.map { "Every set is logged. \($0)" } ?? "Every set is logged." }
        let open = openSets == 1 ? "1 set is" : "\(openSets) sets are"
        if loggedSets == 0 { return "\(open) still open and no set is logged yet." }
        return [done, "\(open) still open. They stay out of the log."].compactMap { $0 }.joined(separator: " ")
    }

    // MARK: Current set

    private func setSection(at position: TrainLiveModel.Position) -> some View {
        let line = model.session.exercises[position.exerciseIndex]
        return VStack(alignment: .leading, spacing: LooprSpacing.cardStack) {
            VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                Text(model.eyebrow.looprLabelCased)
                    .looprTypography(.sectionLabel)
                    .foregroundStyle(Color.loopr(.inkSecondary))
                    .accessibilityLabel(model.spokenEyebrow)
                    .accessibilityIdentifier("train-live-eyebrow")
                // The menu overlays the title row, so its 56 pt target does not push "Last time" down.
                LooprText(line.exercise.name, style: .titleLarge)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("train-live-exercise")
                    .padding(.trailing, LooprSpacing.interactiveRowHeight)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .trailing) { exerciseMenu(position) }
                if let last = model.lastTimeSummary(forExerciseAt: position.exerciseIndex) {
                    LooprText(last, style: .settingsRow, color: .inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("train-live-last-time")
                } else {
                    LooprText("First time logging this one.", style: .settingsRow, color: .inkSecondary)
                        .accessibilityIdentifier("train-live-last-time")
                }
                if let from = line.swappedFrom {
                    LooprText("Swapped from \(from.name).", style: .caption, color: .inkSecondary)
                }
                if let adjustment = model.recoveryAdjustment, adjustment.isAdjusted {
                    LooprInlineMessage(adjustment.message, tone: .neutral)
                        .accessibilityIdentifier("train-live-recovery")
                }
            }
            inputs(measure: line.planned.measure, index: position.exerciseIndex)
        }
    }

    /// The pinned bar: what the set is, and the one button that logs it.
    private var logBar: some View {
        let measure = session.currentMeasure
        let values = session.draft.values(for: measure)
        let what = TrainSetFormat.set(values, measure: measure)
        return Button { session.logSet() } label: {
            HStack(spacing: LooprSpacing.sm) {
                Image(systemName: "checkmark")
                    .font(.system(size: 17, weight: .bold))
                Text("Log set")
                Spacer(minLength: LooprSpacing.xs)
                Text(what)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .opacity(0.8)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .padding(.horizontal, LooprSpacing.cardHorizontal)
        }
        .buttonStyle(LooprButtonStyle(accent: Self.accent))
        .disabled(holdRunning)
        .accessibilityLabel("Log set, \(TrainSetFormat.spoken(values, measure: measure))")
        .accessibilityIdentifier("train-log-set")
        .padding(.horizontal, LooprSpacing.screenGutter)
        .padding(.top, LooprSpacing.sm)
        .padding(.bottom, LooprSpacing.xs)
        .background {
            LinearGradient(colors: [Color.loopr(.background).opacity(0), Color.loopr(.background).opacity(0.94), Color.loopr(.background)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        }
    }

    @ViewBuilder
    private func inputs(measure: TrainSetMeasure, index: Int) -> some View {
        switch measure {
        case .weight: weightInputs(index: index)
        case .bodyweight: bodyweightInputs(index: index)
        case .time: timeInputs(index: index)
        case .distance: distanceInputs(index: index)
        }
    }

    /// Why the suggestion moved from last time, under the number (R2-LIFT-08). Nothing when it copies a set or the plan.
    @ViewBuilder
    private var prefillReason: some View {
        if let reason = model.currentPrefillReason {
            LooprText(reason, style: .caption, color: .inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("train-live-prefill-reason")
        }
    }

    private var repsBinding: Binding<Int> { Binding(get: { session.draft.reps }, set: { session.draft.reps = $0 }) }
    private var loadBinding: Binding<Double> { Binding(get: { session.draft.loadKg }, set: { session.draft.loadKg = $0 }) }

    /// The weight as a number with the plates folded under it; then the reps as a strip to tap.
    private func weightInputs(index: Int) -> some View {
        let last = model.lastTopSet(forExerciseAt: index)
        return VStack(alignment: .leading, spacing: LooprSpacing.md) {
            LooprLoadPicker(value: loadBinding, lastTime: last?.loadKg, showsBarbell: model.usesBarbell(exerciseAt: index),
                            accent: Self.accent, identifier: "train-kg", platesExpanded: $platesExpanded)
            prefillReason
            LooprRepsStrip(reps: repsBinding, lastTime: last?.reps, accent: Self.accent, identifier: "train-reps")
        }
    }

    /// Bodyweight: a toggle for no extra load, an added load or assistance, its kilograms, then the reps.
    private func bodyweightInputs(index: Int) -> some View {
        let last = model.lastTopSet(forExerciseAt: index)
        let mode = session.draft.bodyweightLoad
        return VStack(alignment: .leading, spacing: LooprSpacing.md) {
            LooprChoiceControl("Load", choices: [
                LooprChoice(TrainLiveSession.Draft.BodyweightLoad.none.rawValue, title: "Bodyweight"),
                LooprChoice(TrainLiveSession.Draft.BodyweightLoad.added.rawValue, title: "Added"),
                LooprChoice(TrainLiveSession.Draft.BodyweightLoad.assisted.rawValue, title: "Assisted")
            ], selection: mode.rawValue, accent: Self.accent, identifier: "train-bw-load") { choice in
                if let choice, let next = TrainLiveSession.Draft.BodyweightLoad(rawValue: choice) { session.draft.bodyweightLoad = next }
            }
            switch mode {
            case .none:
                EmptyView()
            case .added:
                LooprValueStepper("kg", label: "Added weight", spokenUnit: "kilograms", value: loadBinding, step: 2.5,
                                  range: 0...TrainLimits.maxLoadKg, identifier: "train-bw-added",
                                  decrementIdentifier: "train-bw-added-minus", incrementIdentifier: "train-bw-added-plus")
            case .assisted:
                LooprValueStepper("kg assist", label: "Assistance", spokenUnit: "kilograms of assistance",
                                  value: Binding(get: { session.draft.assistKg }, set: { session.draft.assistKg = $0 }),
                                  step: 2.5, range: 0...TrainLimits.maxLoadKg, identifier: "train-bw-assist",
                                  decrementIdentifier: "train-bw-assist-minus", incrementIdentifier: "train-bw-assist-plus")
            }
            prefillReason
            LooprRepsStrip(reps: repsBinding, lastTime: last?.reps, limit: TrainSetMeasure.bodyweight.maxReps,
                           accent: Self.accent, identifier: "train-reps")
        }
    }

    /// A hold: the timer with its 3-2-1 lead-in, then the seconds and an optional load to adjust by hand.
    private func timeInputs(index: Int) -> some View {
        VStack(alignment: .leading, spacing: LooprSpacing.cardStack) {
            TrainHoldTimerCard(seconds: Binding(get: { session.draft.seconds }, set: { session.draft.seconds = $0 }),
                               isRunning: $holdRunning, accent: Self.accent, now: session.clock)
            let showsLoad = holdLoadShown || session.draft.loadKg > 0
            pair {
                LooprValueStepper("time", label: "Hold", spokenUnit: "seconds",
                                  value: Binding(get: { Double(session.draft.seconds) }, set: { session.draft.seconds = Int($0.rounded()) }),
                                  step: 5, range: 1...Double(TrainLimits.maxSetSeconds), identifier: "train-seconds",
                                  decrementIdentifier: "train-seconds-minus", incrementIdentifier: "train-seconds-plus", format: .clock)
                if showsLoad { loadStepper }
            }
            .disabled(holdRunning)
            // Most holds carry no load, so the load stays out of the way until asked for (R2-WOD-15).
            if !showsLoad {
                Button { holdLoadShown = true } label: { Label("Add weight", systemImage: "plus") }
                    .buttonStyle(LooprButtonStyle(prominent: false, accent: Self.accent, quiet: true))
                    .disabled(holdRunning)
                    .accessibilityHint("Shows a load for a weighted hold")
                    .accessibilityIdentifier("train-hold-add-weight")
            }
        }
    }

    /// A distance: metres and the load carried.
    private func distanceInputs(index: Int) -> some View {
        pair {
            LooprValueStepper("m", label: "Distance", spokenUnit: "metres",
                              value: Binding(get: { session.draft.metres }, set: { session.draft.metres = $0 }),
                              step: 5, range: 5...TrainLimits.maxSetMetres, identifier: "train-metres",
                              decrementIdentifier: "train-metres-minus", incrementIdentifier: "train-metres-plus")
            loadStepper
        }
    }

    private var loadStepper: some View {
        LooprValueStepper("kg", label: "Load", spokenUnit: "kilograms", value: loadBinding, step: 2.5,
                          range: 0...TrainLimits.maxLoadKg, identifier: "train-load",
                          decrementIdentifier: "train-load-minus", incrementIdentifier: "train-load-plus")
    }

    /// Two steppers side by side, stacked at accessibility text sizes.
    private func pair<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: LooprSpacing.cardStack))
            : AnyLayout(HStackLayout(spacing: LooprSpacing.cardStack))
        return layout { content() }
    }

    private func exerciseMenu(_ position: TrainLiveModel.Position) -> some View {
        Menu {
            Button("Skip set", systemImage: "forward") { session.skipSet() }
                .accessibilityIdentifier("train-skip-set")
            Button("Skip exercise", systemImage: "forward.end") { session.skipExercise(at: position.exerciseIndex) }
                .accessibilityIdentifier("train-skip-exercise")
            Button("Swap exercise", systemImage: "arrow.left.arrow.right") { showsSwap = true }
                .accessibilityIdentifier("train-swap-exercise")
            if model.canChangeMeasure(ofExerciseAt: position.exerciseIndex) {
                Picker(selection: Binding(get: { model.measure(ofExerciseAt: position.exerciseIndex) },
                                          set: { session.setMeasure($0, forExerciseAt: position.exerciseIndex) })) {
                    ForEach(TrainSetMeasure.allCases, id: \.self) { measure in
                        Text(measure.title).tag(measure)
                    }
                } label: {
                    Label("Log as", systemImage: "slider.horizontal.3")
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("train-measure-menu")
            }
            Divider()
            Button("Add a set", systemImage: "plus") { session.addSet(toExerciseAt: position.exerciseIndex) }
                .accessibilityIdentifier("train-add-set")
            let line = model.session.exercises[position.exerciseIndex]
            let total = max(line.planned.sets, line.sets.count)
            Button("Remove the last set", systemImage: "minus") {
                session.removeSet(exerciseIndex: position.exerciseIndex, setIndex: total - 1)
            }
            .disabled(total <= line.sets.count)
            .accessibilityIdentifier("train-remove-set")
            Button("Remove exercise", systemImage: "trash", role: .destructive) { askToRemove(position.exerciseIndex) }
                .accessibilityIdentifier("train-remove-exercise")
            let others = model.exerciseProgress.filter { !$0.isCurrent && ($0.status == .pending || $0.status == .swapped) }
            if !others.isEmpty {
                Section("Go to") {
                    ForEach(others) { item in
                        Button("\(item.index + 1). \(item.name)") { session.focus(exerciseAt: item.index) }
                            .accessibilityIdentifier("train-jump-\(item.index)")
                    }
                }
            }
            if let onPauseChange {
                Divider()
                Button(isPaused ? "Resume recording" : "Pause recording", systemImage: isPaused ? "play" : "pause") {
                    Task { @MainActor in
                        do { try await onPauseChange(!isPaused); pauseError = nil }
                        catch { pauseError = error.localizedDescription }
                    }
                }
                .accessibilityIdentifier("train-pause")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .looprTypography(.title)
                .foregroundStyle(Color.loopr(.inkSecondary))
                .frame(width: LooprSpacing.interactiveRowHeight, height: LooprSpacing.interactiveRowHeight)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Exercise options")
        .accessibilityIdentifier("train-exercise-menu")
    }

    // MARK: Building the workout

    private struct PickerItem: Identifiable {
        let library: ExerciseLibrary
        var id: Int { 0 }
    }

    private func openPicker() {
        picker = try? ExerciseLibrary(definitions: model.exercisePool)
        if picker == nil { picker = try? ExerciseLibrary(definitions: []) }
    }

    private func askToRemove(_ index: Int) {
        let line = model.session.exercises[index]
        removeTarget = RemoveTarget(index: index, name: line.exercise.name, loggedSets: line.sets.filter { !$0.skipped }.count)
    }

    private var emptyCard: some View {
        LooprSurface(emphasis: .hero(Self.accent)) {
            VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                LooprText("Add your first exercise", style: .titleLarge)
                LooprText("Search the library or make your own. Loopr fills in the weight and reps from last time.",
                          style: .prose, color: .inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button { openPicker() } label: { Label("Add exercise", systemImage: "plus") }
                    .buttonStyle(LooprButtonStyle(accent: Self.accent))
                    .accessibilityIdentifier("train-add-first-exercise")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("train-live-empty")
    }

    /// Every exercise in the workout with its sets. A tap moves to it; a long press adds a set or removes it.
    private var exerciseList: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprSectionHeader("This workout", detail: model.loggedSummary ?? "No sets yet")
            LooprCard(density: .flush) {
                VStack(spacing: LooprSpacing.none) {
                    ForEach(model.exerciseProgress) { item in
                        if item.index > 0 {
                            Rectangle().fill(Color.loopr(.divider)).frame(height: LooprSpacing.hairline).accessibilityHidden(true)
                        }
                        exerciseRow(item)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("train-exercise-list")
    }

    private func exerciseRow(_ item: TrainExerciseProgress) -> some View {
        let open = item.status == .pending || item.status == .swapped
        let measure = model.measure(ofExerciseAt: item.index)
        let kind = measure == .weight ? "" : " · \(measure.title.lowercased())"
        let detail: String = switch item.status {
        case .skipped: "Skipped"
        case .done: "\(item.loggedSets) of \(item.loggedSets) sets · done"
        case .pending, .swapped: "\(item.loggedSets) of \(item.plannedSets) sets\(kind)"
        }
        let symbol = item.isCurrent ? "play.circle.fill" : open ? "circle" : item.status == .skipped ? "forward.circle" : "checkmark.circle.fill"
        return Button { if open { session.focus(exerciseAt: item.index) } } label: {
            HStack(spacing: LooprSpacing.sm) {
                Image(systemName: symbol)
                    .looprTypography(.title)
                    .foregroundStyle(Color.loopr(item.isCurrent || item.status == .done ? Self.accent.textInk : .inkTertiary))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    LooprText(item.name, style: .rowTitle).fixedSize(horizontal: false, vertical: true)
                    LooprText(detail, style: .caption, color: .inkSecondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, LooprSpacing.cardHorizontal)
            .frame(maxWidth: .infinity, minHeight: LooprSpacing.interactiveRowHeight, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.looprPressableRow)
        .contextMenu {
            Button("Add a set", systemImage: "plus") { session.addSet(toExerciseAt: item.index) }
            Button("Remove exercise", systemImage: "trash", role: .destructive) { askToRemove(item.index) }
        }
        .accessibilityLabel("\(item.name), \(detail)\(item.isCurrent ? ", current" : "")")
        .accessibilityHint(open && !item.isCurrent ? "Moves to this exercise" : "")
        .accessibilityAction(named: "Add a set") { session.addSet(toExerciseAt: item.index) }
        .accessibilityAction(named: "Remove exercise") { askToRemove(item.index) }
        .accessibilityIdentifier("train-exercise-row-\(item.index)")
    }

    // MARK: Table

    /// The table's two value columns for a measure: their headers and how VoiceOver says the first one.
    static func columns(for measure: TrainSetMeasure) -> (weight: String, spokenWeight: String, reps: String) {
        switch measure {
        case .weight: ("kg", "kilograms", "Reps")
        case .bodyweight: ("Load", "", "Reps")
        case .time: ("Load", "", "Time")
        case .distance: ("Load", "", "Metres")
        }
    }

    /// The text of one row's two value cells: "20 kg assist" or "+10 kg" under Load and the reps under Reps for a
    /// bodyweight set (R2-LIFT-04), "0:45" under Time.
    static func cells(_ values: TrainSetValues, measure: TrainSetMeasure, skipped: Bool) -> (weight: String, reps: String) {
        if skipped { return ("–", "–") }
        let load = values.loadKg.flatMap { $0 > 0 ? TrainLiveFormat.kilograms($0) : nil }
        switch measure {
        case .weight: return (load ?? "–", String(values.reps))
        case .bodyweight: return (TrainSetFormat.bodyweight(addedKg: values.loadKg, assistKg: values.assistKg), String(values.reps))
        case .time: return (load.map { "\($0) kg" } ?? "–", TrainSetFormat.seconds(values.seconds ?? 0))
        case .distance: return (load.map { "\($0) kg" } ?? "–", TrainLiveFormat.kilograms(values.metres ?? 0))
        }
    }

    private static let tagOptions = LoggedSet.Tag.allCases.map { LooprSetTagOption(id: $0.rawValue, title: $0.title) }

    private func table(forExerciseAt index: Int) -> some View {
        let line = model.session.exercises[index]
        let measure = line.planned.measure
        let columns = Self.columns(for: measure)
        let rows = model.tableRows(forExerciseAt: index).map { row -> LooprSetLogRow in
            let values = row.state == .current ? session.draft.values(for: measure) : row.values
            let skipped = row.state == .skipped
            let cells = Self.cells(values, measure: measure, skipped: skipped)
            let status: LooprSetLogStatus = switch row.state {
            case .logged: .logged
            case .current: .current
            case .skipped: .skipped
            case .planned: .planned
            }
            return LooprSetLogRow(number: row.number, weight: cells.weight, reps: cells.reps,
                                  rpe: row.rpe.map(TrainLiveFormat.rpe), status: status, tag: row.tag?.letter,
                                  spokenTag: row.tag?.title.lowercased(), badge: row.isRecord ? "PR" : nil,
                                  spokenValues: measure == .weight ? nil : TrainSetFormat.spoken(values, measure: measure))
        }
        return LooprSetLogTable(
            rows: rows, accent: Self.accent, weightUnit: columns.weight, spokenWeightUnit: columns.spokenWeight,
            repsTitle: columns.reps, wideLoad: measure != .weight, rowIdentifierPrefix: "train-set-row",
            rpeIdentifierPrefix: "train-set-rpe", identifier: "train-set-table", tagOptions: Self.tagOptions
        ) { row in
            let setIndex = row.number - 1
            let current = line.sets.indices.contains(setIndex) ? line.sets[setIndex].rpe : nil
            rpeTarget = RPETarget(exerciseIndex: index, setIndex: setIndex, current: current)
        } onEdit: { row in
            let setIndex = row.number - 1
            guard line.sets.indices.contains(setIndex) else { return }
            let logged = line.sets[setIndex]
            // A skipped set holds no values, so the editor starts from what the plan would suggest.
            let suggestion = model.prefill(for: TrainLiveModel.Position(exerciseIndex: index, setIndex: setIndex))
            editTarget = EditTarget(
                exerciseIndex: index, setIndex: setIndex,
                values: logged.skipped ? suggestion.values : logged.values,
                rpe: logged.skipped ? nil : logged.rpe, tag: logged.tag, measure: measure, wasSkipped: logged.skipped)
        } onSelectTag: { row, tag in
            session.setTag(tag.flatMap(LoggedSet.Tag.init(rawValue:)), exerciseIndex: index, setIndex: row.number - 1)
        }
    }

    // MARK: Rest

    /// The rest as one slim card (R2-LIFT-03, R2-DES-01): time left, +30 s and Skip on one row, and the RPE of the set
    /// just logged on the next, so the weight, the reps and the set table stay on the first screen.
    private func restBar(_ rest: RestTimer, position: TrainLiveModel.Position?) -> some View {
        LooprCard(density: .compact) {
            VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                TimelineView(.periodic(from: .now, by: 1)) { _ in restRow(rest, now: session.clock()) }
                if let position { rpeChips(position) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("train-rest-bar")
    }

    private func restRow(_ rest: RestTimer, now: Date) -> some View {
        let remaining = rest.remainingSeconds(at: now)
        let caption: String = rest.isExpired(at: now) ? "Rest is over"
            : (model.bandRestCue && bandCueAvailable ? "Rest · the band buzzes at zero" : "Rest")
        return HStack(spacing: LooprSpacing.xs) {
            HStack(spacing: LooprSpacing.sm) {
                LooprProgressRing(value: Double(remaining), scale: LooprRingScale(fullValue: max(rest.totalSeconds, 1)),
                                  text: "", accent: Self.accent, diameter: 28, animates: false)
                VStack(alignment: .leading, spacing: 0) {
                    Text(LooprRestTimerCard.countdownText(seconds: remaining))
                        .looprTypography(.metricCompact)
                        .monospacedDigit()
                        .foregroundStyle(Color.loopr(.ink))
                        .lineLimit(1)
                    Text(caption)
                        .looprTypography(.caption)
                        .foregroundStyle(Color.loopr(.inkSecondary))
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Rest timer")
            .accessibilityValue("\(LooprRestTimerCard.spokenCountdown(seconds: remaining)) left. \(caption)")
            .accessibilityAddTraits(.updatesFrequently)
            .accessibilityIdentifier("train-rest-timer")
            Button { session.extendRest() } label: { Text("+30 s").padding(.horizontal, LooprSpacing.sm) }
                .buttonStyle(LooprButtonStyle(prominent: false, accent: Self.accent))
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityLabel("Add 30 seconds")
                .accessibilityIdentifier("train-rest-add")
            Button { session.endRest() } label: { Text("Skip").padding(.horizontal, LooprSpacing.xs) }
                .buttonStyle(LooprButtonStyle(prominent: false, accent: Self.accent, quiet: true))
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityLabel("Skip rest")
                .accessibilityIdentifier("train-rest-done")
        }
    }

    static let rpeChipValues: [Double] = [6, 7, 8, 9, 10]

    /// The line that explains RPE, shown until the person rates a set for the first time in a session.
    static let rpeExplainer = "RPE: how hard the set was, 10 is nothing left."

    /// One tap for the RPE of the set just logged, inside the rest card. Nothing is saved until a chip is tapped;
    /// the chip with last time's RPE is underlined. "More" opens the half steps.
    private func rpeChips(_ position: TrainLiveModel.Position) -> some View {
        let line = model.session.exercises[position.exerciseIndex]
        let set = line.sets[position.setIndex]
        let suggested = model.suggestedRPE(exerciseIndex: position.exerciseIndex, setIndex: position.setIndex)
        let rated = model.session.exercises.contains { $0.sets.contains { $0.rpe != nil } }
        return VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
            HStack(spacing: LooprSpacing.xxs) {
                ForEach(Self.rpeChipValues, id: \.self) { value in
                    rpeChip(value, selected: set.rpe == value, suggested: set.rpe == nil && suggested == value, position: position)
                }
                Button {
                    rpeTarget = RPETarget(exerciseIndex: position.exerciseIndex, setIndex: position.setIndex, current: set.rpe)
                } label: {
                    LooprText("More", style: .label, color: .inkSecondary)
                        .frame(minWidth: LooprSpacing.hero, minHeight: LooprSpacing.interactiveRowHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.looprPressableRow)
                .accessibilityLabel("More RPE values, in half steps")
                .accessibilityIdentifier("train-rest-rpe-more")
            }
            let caption = set.rpe.flatMap(TrainRPESheet.caption(for:)).map { "Set \(position.setIndex + 1): \($0.lowercased())." }
                ?? (rated ? "How hard was set \(position.setIndex + 1)? RPE, optional." : Self.rpeExplainer)
            LooprText(caption, style: .caption, color: .inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("train-rest-rpe-caption")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("How hard was set \(position.setIndex + 1)")
        .accessibilityIdentifier("train-rest-rpe")
    }

    private func rpeChip(_ value: Double, selected: Bool, suggested: Bool, position: TrainLiveModel.Position) -> some View {
        let text = TrainLiveFormat.rpe(value)
        return Button {
            session.setRPE(selected ? nil : value, exerciseIndex: position.exerciseIndex, setIndex: position.setIndex)
        } label: {
            VStack(spacing: 2) {
                Text(text)
                    .looprTypography(.metricCompact)
                    .monospacedDigit()
                    .foregroundStyle(selected ? Self.accent.filledLabelColor : Color.loopr(.ink))
                Capsule()
                    .fill(Color.loopr(.inkMuted))
                    .frame(width: 14, height: 3)
                    .opacity(suggested ? 1 : 0)
            }
            .frame(maxWidth: .infinity, minHeight: LooprSpacing.interactiveRowHeight)
            .background(selected ? Color.loopr(Self.accent) : Color.loopr(.surface),
                        in: RoundedRectangle(cornerRadius: LooprRadius.control, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.looprPressableRow)
        .accessibilityLabel(TrainRPESheet.caption(for: value).map { "RPE \(text), \($0)" } ?? "RPE \(text)")
        .accessibilityValue(suggested ? "Last time" : "")
        .accessibilityHint(selected ? "Tap again to clear" : "")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("train-rest-rpe-\(text)")
    }

    // MARK: Complete and messages

    private var completeCard: some View {
        LooprSurface(emphasis: .hero(Self.accent)) {
            VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                StatusChip("All sets logged", symbol: "checkmark.circle", tone: .positive)
                LooprText("Nothing left to log", style: .titleLarge)
                LooprText("Add another exercise or a set, or finish to save the session and see your personal bests.", style: .prose, color: .inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Finish session") { confirmsFinish = true }
                    .buttonStyle(LooprButtonStyle(accent: Self.accent))
                    .disabled(finishing)
                    .accessibilityIdentifier("train-finish-session")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("train-live-complete")
    }

    @ViewBuilder
    private var messages: some View {
        if let message = finishError ?? pauseError ?? session.errorMessage {
            LooprInlineMessage(message, tone: .warning)
                .accessibilityIdentifier("train-live-error")
        }
    }

    private func finish() {
        finishing = true
        finishError = nil
        Task { @MainActor in
            do { try await onFinish() }
            catch { finishError = error.localizedDescription }
            finishing = false
        }
    }
}

// MARK: Hold timer

/// The timer for a hold: Start, a 3-2-1 lead-in with a tick each second, then the hold until Stop.
/// Stop writes the whole seconds into `seconds`, ready to log. Each hold counts from its start time,
/// so the background never stretches or loses it. The dead hang test works the same way.
struct TrainHoldTimerCard: View {
    @Binding var seconds: Int
    @Binding var isRunning: Bool
    let accent: LooprColorToken
    let now: @Sendable () -> Date

    init(seconds: Binding<Int>, isRunning: Binding<Bool>, accent: LooprColorToken, now: @escaping @Sendable () -> Date) {
        _seconds = seconds; _isRunning = isRunning; self.accent = accent; self.now = now
    }

    @Environment(\.scenePhase) private var scenePhase
    @State private var timer = CapacityTimer()
    @State private var elapsed = 0.0
    @State private var countdown: Int?
    @State private var running = false
    @State private var haptic: LooprHaptic?

    private var isActive: Bool {
        switch timer.phase {
        case .leadIn, .running: true
        case .ready, .stopped: false
        }
    }

    var body: some View {
        LooprCard {
            VStack(spacing: LooprSpacing.sm) {
                Group {
                    if let countdown {
                        LooprHeroNumber(Double(countdown), style: .heroNumeralXL, color: accent)
                            .id("countdown")
                    } else {
                        Text(TrainSetFormat.seconds(Int(isActive || timer.isStopped ? elapsed : Double(seconds))))
                            .looprTypography(.heroNumeralXL)
                            .monospacedDigit()
                            .foregroundStyle(Color.loopr(running ? accent.textInk : .ink))
                            .contentTransition(.numericText())
                    }
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Hold timer")
                .accessibilityValue(spokenValue)
                .accessibilityAddTraits(.updatesFrequently)
                .accessibilityIdentifier("train-hold-value")
                LooprText(caption, style: .caption, color: .inkSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("train-hold-caption")
                if isActive {
                    Button("Stop") { stop() }
                        .buttonStyle(LooprButtonStyle(accent: accent))
                        .accessibilityIdentifier("train-hold-stop")
                } else {
                    Button(timer.isStopped ? "Time again" : "Start timer") { start() }
                        .buttonStyle(LooprButtonStyle(prominent: !timer.isStopped, accent: accent))
                        .accessibilityIdentifier("train-hold-start")
                }
            }
        }
        .looprHaptic(haptic)
        .task(id: isActive) { await follow() }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: timer.enterBackground(at: now())
            case .active: timer.enterForeground(at: now()); refresh()
            default: break
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("train-hold-timer")
    }

    private var caption: String {
        if countdown != nil { return "Get into position" }
        if running { return "Tap Stop when you come out of the hold" }
        if timer.rejectedMisTap { return "That was under a second, so Loopr did not keep it." }
        if timer.isStopped { return "Timed. Log the set, or adjust the seconds below." }
        return "Start, then take position during 3, 2, 1. Or set the seconds below."
    }

    private var spokenValue: String {
        if let countdown { return "Starting in \(countdown)" }
        return LooprSpokenSeconds.text(Int(isActive || timer.isStopped ? elapsed : Double(seconds)))
    }

    private func start() {
        if timer.isStopped { timer.reset() }
        timer.start(at: now())
        refresh()
    }

    private func stop() {
        timer.stop(at: now())
        refresh()
        if let result = timer.result { seconds = min(max(Int(result.rounded()), 1), TrainLimits.maxSetSeconds) }
    }

    /// Reads the timer at the clock's time and plays a tick each second of the lead-in, and a firmer one at the start.
    private func refresh() {
        let at = now()
        let nextCountdown = timer.countdown(at: at)
        let nextRunning: Bool = if case .running = timer.resolved(at: at) { true } else { false }
        if let nextCountdown, nextCountdown != countdown { haptic = LooprHaptic(.impact(weight: .light)) }
        if nextRunning, !running { haptic = LooprHaptic(.impact(weight: .heavy)) }
        countdown = nextCountdown
        running = nextRunning
        elapsed = timer.elapsed(at: at)
        isRunning = isActive
    }

    /// Ten times a second while the timer runs. The value always comes from the start time.
    private func follow() async {
        guard isActive else { return }
        while !Task.isCancelled {
            refresh()
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}

// MARK: Edit a set

/// Changes the values and tag of a logged set, or logs a skipped one. RPE stays as it was and has its own sheet.
struct TrainEditSetSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var loadKg: Double
    @State private var reps: Double
    @State private var seconds: Double
    @State private var metres: Double
    @State private var assistKg: Double
    @State private var tag: LoggedSet.Tag?
    @State private var holdLoadShown = false
    let setNumber: Int
    let measure: TrainSetMeasure
    let wasSkipped: Bool
    let onDelete: (() -> Void)?
    let onSave: (TrainSetValues, LoggedSet.Tag?) -> Void
    /// The finished session's editor saves RPE with the set. The live screen has its own RPE sheet, so it leaves this nil.
    private let onSaveWithRPE: ((TrainSetValues, LoggedSet.Tag?, Double?) -> Void)?
    @State private var rpe: Double?

    /// The live screen's editor. RPE has its own sheet there.
    init(setNumber: Int, measure: TrainSetMeasure, wasSkipped: Bool, values: TrainSetValues, tag: LoggedSet.Tag?,
         onDelete: (() -> Void)? = nil, onSave: @escaping (TrainSetValues, LoggedSet.Tag?) -> Void) {
        self.init(setNumber: setNumber, measure: measure, wasSkipped: wasSkipped, values: values, tag: tag, onDelete: onDelete,
                  rpe: nil, optionalSaveWithRPE: nil, onSave: onSave)
    }

    /// A finished session's editor, which saves RPE with the set.
    init(setNumber: Int, measure: TrainSetMeasure, wasSkipped: Bool, values: TrainSetValues, tag: LoggedSet.Tag?,
         onDelete: (() -> Void)? = nil, rpe: Double?, onSaveWithRPE: @escaping (TrainSetValues, LoggedSet.Tag?, Double?) -> Void) {
        self.init(setNumber: setNumber, measure: measure, wasSkipped: wasSkipped, values: values, tag: tag, onDelete: onDelete,
                  rpe: rpe, optionalSaveWithRPE: onSaveWithRPE, onSave: { _, _ in })
    }

    private init(setNumber: Int, measure: TrainSetMeasure, wasSkipped: Bool, values: TrainSetValues, tag: LoggedSet.Tag?,
                 onDelete: (() -> Void)?, rpe: Double?, optionalSaveWithRPE: ((TrainSetValues, LoggedSet.Tag?, Double?) -> Void)?,
                 onSave: @escaping (TrainSetValues, LoggedSet.Tag?) -> Void) {
        self.onSaveWithRPE = optionalSaveWithRPE
        _rpe = State(initialValue: rpe)
        self.setNumber = setNumber
        self.measure = measure
        self.wasSkipped = wasSkipped
        self.onDelete = onDelete
        self.onSave = onSave
        _loadKg = State(initialValue: values.loadKg ?? 0)
        _reps = State(initialValue: Double(max(values.reps, measure.countsReps ? 1 : 0)))
        _seconds = State(initialValue: Double(max(values.seconds ?? TemplateExercise.defaultTargetSeconds, 1)))
        _metres = State(initialValue: max(values.metres ?? TemplateExercise.defaultTargetMetres, 1))
        _assistKg = State(initialValue: values.assistKg ?? 0)
        _tag = State(initialValue: tag)
    }

    /// The edited numbers. A bodyweight set keeps the assistance when it has some, otherwise the added load.
    var values: TrainSetValues {
        switch measure {
        case .weight: TrainSetValues(loadKg: loadKg, reps: Int(reps.rounded()))
        case .bodyweight:
            TrainSetValues(loadKg: assistKg > 0 ? nil : loadKg, reps: Int(reps.rounded()), assistKg: assistKg > 0 ? assistKg : nil)
        case .time: TrainSetValues(loadKg: loadKg, reps: 0, seconds: Int(seconds.rounded()))
        case .distance: TrainSetValues(loadKg: loadKg, reps: 0, metres: metres)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: LooprSpacing.cardStack) {
                    LooprText(wasSkipped ? "Log set \(setNumber)" : "Edit set \(setNumber)", style: .titleLarge)
                        .accessibilityAddTraits(.isHeader)
                    // The set type first, as chips, so warm-up, drop and failure are in sight the moment a row opens
                    // (R2-LIFT-11). A long press on the row still offers them.
                    if !wasSkipped {
                        LooprChoiceControl("Set type", choices: [LooprChoice("working", title: "Working")]
                            + LoggedSet.Tag.allCases.map { LooprChoice($0.rawValue, title: $0.title) },
                                           selection: tag?.rawValue ?? "working", accent: .fitnessTab,
                                           identifier: "train-edit-tag") { choice in
                            tag = choice.flatMap(LoggedSet.Tag.init(rawValue:))
                        }
                        if tag == .warmUp {
                            LooprText("Warm-ups don't count toward volume, bests or your week.", style: .caption, color: .inkSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    steppers
                    if onSaveWithRPE != nil { rpePicker }
                    Button(wasSkipped ? "Log set" : "Save") {
                        if let onSaveWithRPE { onSaveWithRPE(values, tag, rpe) } else { onSave(values, tag) }
                        dismiss()
                    }
                    .buttonStyle(LooprButtonStyle(accent: .fitnessTab))
                    .accessibilityIdentifier("train-edit-save")
                    if let onDelete {
                        Button("Delete set", role: .destructive) { onDelete(); dismiss() }
                            .buttonStyle(LooprButtonStyle(prominent: false, accent: .critical))
                            .accessibilityIdentifier("train-edit-delete")
                    }
                }
                .padding(.horizontal, LooprSpacing.screenGutter)
                .padding(.top, LooprSpacing.sm)
            }
            .background(Color.loopr(.background).ignoresSafeArea())
            .navigationTitle("Set \(setNumber)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.accessibilityIdentifier("train-edit-cancel")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .accessibilityIdentifier("train-edit-sheet")
    }

    private var rpePicker: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprText("RPE", style: .rowTitle)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: LooprSpacing.xs) {
                    rpeChip(nil, title: "None")
                    ForEach(TrainRPESheet.values, id: \.self) { value in
                        rpeChip(value, title: TrainLiveFormat.rpe(value))
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("train-edit-rpe")
    }

    private func rpeChip(_ value: Double?, title: String) -> some View {
        Button { rpe = value } label: {
            LooprText(title, style: .caption, color: rpe == value ? .background : .ink)
                .padding(.horizontal, LooprSpacing.sm)
                .frame(minHeight: 36)
                .background(Color.loopr(rpe == value ? .fitnessTab : .surfaceSunk), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(value.map { "RPE \(TrainLiveFormat.rpe($0))" } ?? "No RPE")
        .accessibilityAddTraits(rpe == value ? .isSelected : [])
    }

    private var steppers: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: LooprSpacing.cardStack))
            : AnyLayout(HStackLayout(spacing: LooprSpacing.cardStack))
        return VStack(spacing: LooprSpacing.cardStack) {
            layout {
                switch measure {
                case .weight:
                    kilograms("Weight", $loadKg, id: "train-edit-kg")
                    repsStepper
                case .bodyweight:
                    repsStepper
                    if assistKg > 0 {
                        kilograms("Assistance", $assistKg, id: "train-edit-assist")
                    } else {
                        kilograms("Added weight", $loadKg, id: "train-edit-kg")
                    }
                case .time:
                    LooprValueStepper("time", label: "Hold", spokenUnit: "seconds", value: $seconds, step: 5,
                                      range: 1...Double(TrainLimits.maxSetSeconds), identifier: "train-edit-seconds",
                                      decrementIdentifier: "train-edit-seconds-minus", incrementIdentifier: "train-edit-seconds-plus",
                                      format: .clock)
                    if holdLoadShown || loadKg > 0 { kilograms("Load", $loadKg, id: "train-edit-kg") }
                case .distance:
                    LooprValueStepper("m", label: "Distance", spokenUnit: "metres", value: $metres, step: 5,
                                      range: 1...TrainLimits.maxSetMetres, identifier: "train-edit-metres",
                                      decrementIdentifier: "train-edit-metres-minus", incrementIdentifier: "train-edit-metres-plus")
                    kilograms("Load", $loadKg, id: "train-edit-kg")
                }
            }
            if measure == .time, !holdLoadShown, loadKg == 0 {
                Button { holdLoadShown = true } label: { Label("Add weight", systemImage: "plus") }
                    .buttonStyle(LooprButtonStyle(prominent: false, accent: .fitnessTab, quiet: true))
                    .accessibilityIdentifier("train-edit-add-weight")
            }
        }
    }

    private var repsStepper: some View {
        LooprValueStepper("reps", label: "Reps", spokenUnit: "reps", value: $reps, step: 1, range: 1...Double(measure.maxReps),
                          identifier: "train-edit-reps", decrementIdentifier: "train-edit-reps-minus",
                          incrementIdentifier: "train-edit-reps-plus")
    }

    private func kilograms(_ label: String, _ value: Binding<Double>, id: String) -> some View {
        LooprValueStepper("kg", label: label, spokenUnit: "kilograms", value: value, step: 2.5, range: 0...TrainLimits.maxLoadKg,
                          identifier: id, decrementIdentifier: "\(id)-minus", incrementIdentifier: "\(id)-plus")
    }
}

// MARK: RPE

/// RPE 6 to 10 in half steps. Whole values say how many reps were left.
struct TrainRPESheet: View {
    @Environment(\.dismiss) private var dismiss
    let current: Double?
    let onSelect: (Double?) -> Void

    static let values: [Double] = stride(from: 6.0, through: 10.0, by: 0.5).map { $0 }

    static func caption(for value: Double) -> String? {
        switch value {
        case 6: "Four or more reps left"
        case 7: "About three reps left"
        case 8: "About two reps left"
        case 9: "About one rep left"
        case 10: "Nothing left"
        default: nil
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: LooprSpacing.cardStack) {
                    LooprText("How hard was it?", style: .titleLarge)
                    LooprCard(density: .flush) {
                        VStack(spacing: LooprSpacing.none) {
                            ForEach(Array(Self.values.enumerated()), id: \.offset) { index, value in
                                if index > 0 { hairline }
                                row(value)
                            }
                            hairline
                            Button { onSelect(nil); dismiss() } label: {
                                HStack {
                                    LooprText("No RPE", style: .rowTitle, color: .inkSecondary)
                                    Spacer()
                                }
                                .padding(.horizontal, LooprSpacing.cardHorizontal)
                                .frame(minHeight: LooprSpacing.interactiveRowHeight)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.looprPressableRow)
                            .accessibilityIdentifier("train-rpe-clear")
                        }
                    }
                }
                .padding(.horizontal, LooprSpacing.screenGutter)
                .padding(.top, LooprSpacing.sm)
            }
            .background(Color.loopr(.background).ignoresSafeArea())
            .navigationTitle("RPE")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.accessibilityIdentifier("train-rpe-cancel")
                }
            }
        }
        .presentationDetents([.large])
        .accessibilityIdentifier("train-rpe-sheet")
    }

    private var hairline: some View {
        Rectangle().fill(Color.loopr(.divider)).frame(height: LooprSpacing.hairline).accessibilityHidden(true)
    }

    private func row(_ value: Double) -> some View {
        let text = TrainLiveFormat.rpe(value)
        let caption = Self.caption(for: value)
        return Button { onSelect(value); dismiss() } label: {
            HStack(spacing: LooprSpacing.sm) {
                Text(text)
                    .looprTypography(.metricValue)
                    .monospacedDigit()
                    .foregroundStyle(Color.loopr(.ink))
                    .frame(minWidth: LooprSpacing.xl, alignment: .leading)
                if let caption { LooprText(caption, style: .rowTitle, color: .inkSecondary) }
                Spacer(minLength: LooprSpacing.xs)
                if current == value {
                    Image(systemName: "checkmark").looprTypography(.metricValue).foregroundStyle(Color.loopr(.brandInk))
                }
            }
            .padding(.horizontal, LooprSpacing.cardHorizontal)
            .frame(minHeight: LooprSpacing.interactiveRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.looprPressableRow)
        .accessibilityLabel(caption.map { "RPE \(text), \($0)" } ?? "RPE \(text)")
        .accessibilityAddTraits(current == value ? .isSelected : [])
        .accessibilityIdentifier("train-rpe-option-\(text)")
    }
}

// MARK: Swap

/// Alternatives for the current exercise. A choice swaps it and closes the sheet.
struct TrainSwapExerciseSheet: View {
    @Environment(\.dismiss) private var dismiss
    let currentName: String
    /// Sets already logged on the current exercise. They stay with it.
    var loggedSets = 0
    /// Sets the replacement takes over.
    var movedSets = 0
    let options: [ExerciseDefinition]
    let onSelect: (ExerciseDefinition) -> Void

    /// What a swap does: "Same muscles, same plan." or, once sets are logged, where they go.
    static func explanation(currentName: String, loggedSets: Int, movedSets: Int) -> String {
        guard loggedSets > 0 else { return "Same muscles, same plan. The load starts empty." }
        let logged = loggedSets == 1 ? "Your logged set stays" : "Your \(loggedSets) logged sets stay"
        let moved = movedSets == 1 ? "The last set moves" : "The other \(movedSets) sets move"
        return "\(logged) with \(currentName). \(moved) to the new exercise."
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: LooprSpacing.cardStack) {
                    LooprText("Swap \(currentName)", style: .titleLarge)
                        .fixedSize(horizontal: false, vertical: true)
                    if options.isEmpty {
                        LooprText("No close match in the library for this exercise. Skip it, or finish and add it to your workout later.",
                                  style: .prose, color: .inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("train-swap-empty")
                    } else {
                        LooprText(Self.explanation(currentName: currentName, loggedSets: loggedSets, movedSets: movedSets),
                                  style: .prose, color: .inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("train-swap-explanation")
                        LooprCard(density: .flush) {
                            VStack(spacing: LooprSpacing.none) {
                                ForEach(Array(options.enumerated()), id: \.element.key) { index, option in
                                    if index > 0 {
                                        Rectangle().fill(Color.loopr(.divider)).frame(height: LooprSpacing.hairline).accessibilityHidden(true)
                                    }
                                    row(option, index: index)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, LooprSpacing.screenGutter)
                .padding(.top, LooprSpacing.sm)
            }
            .background(Color.loopr(.background).ignoresSafeArea())
            .navigationTitle("Swap exercise")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.accessibilityIdentifier("train-swap-cancel")
                }
            }
        }
        .accessibilityIdentifier("train-swap-sheet")
    }

    static func detail(_ option: ExerciseDefinition) -> String {
        [option.equipment, option.primaryMuscles.first].compactMap { $0 }.map(TemplateBuilderFormat.capitalized).joined(separator: " · ")
    }

    private func row(_ option: ExerciseDefinition, index: Int) -> some View {
        let detail = Self.detail(option)
        return Button { onSelect(option); dismiss() } label: {
            VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                LooprText(option.name, style: .rowTitle)
                    .fixedSize(horizontal: false, vertical: true)
                if !detail.isEmpty { LooprText(detail, style: .caption, color: .inkSecondary) }
            }
            .frame(maxWidth: .infinity, minHeight: LooprSpacing.interactiveRowHeight, alignment: .leading)
            .padding(.horizontal, LooprSpacing.cardHorizontal)
            .contentShape(Rectangle())
        }
        .buttonStyle(.looprPressableRow)
        .accessibilityLabel(detail.isEmpty ? option.name : "\(option.name), \(detail)")
        .accessibilityIdentifier("train-swap-option-\(index)")
    }
}

// MARK: Finish

/// Asks before a session is closed: what was logged and what is still open, then "Finish and save" or "Keep going".
/// A sheet in place of a confirmation dialog, which iOS 26 shows as a popover off the toolbar button.
struct TrainFinishSheet: View {
    @Environment(\.dismiss) private var dismiss
    let message: String
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.cardStack) {
            LooprText("Finish this session?", style: .titleLarge)
                .accessibilityAddTraits(.isHeader)
            LooprText(message, style: .prose, color: .inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("train-finish-message")
            VStack(spacing: LooprSpacing.sm) {
                Button("Finish and save", action: onConfirm)
                    .buttonStyle(LooprButtonStyle(accent: .fitnessTab))
                    .accessibilityIdentifier("train-finish-confirm")
                Button("Keep going") { dismiss() }
                    .buttonStyle(LooprButtonStyle(prominent: false, accent: .fitnessTab, quiet: true))
                    .accessibilityIdentifier("train-finish-cancel")
            }
        }
        .padding(.horizontal, LooprSpacing.screenGutter)
        .padding(.top, LooprSpacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.loopr(.background).ignoresSafeArea())
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("train-finish-sheet")
    }
}
