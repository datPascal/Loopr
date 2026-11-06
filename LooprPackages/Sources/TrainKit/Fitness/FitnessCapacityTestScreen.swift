import DesignSystem
import SwiftUI

/// What the capacity tests need from the app: where results and goals are saved, the clock the timers
/// read, and the time zone results are recorded in.
public struct FitnessCapacityActions: Sendable {
    public var saveResults: @MainActor @Sendable ([CapacityResult]) async throws -> Void
    public var saveGoal: @MainActor @Sendable (CapacityGoal) async throws -> Void
    /// The clock every timer reads. Tests and fixtures pass their own.
    public var now: @Sendable () -> Date
    public var timeZoneIdentifier: String

    public init(saveResults: @escaping @MainActor @Sendable ([CapacityResult]) async throws -> Void,
                saveGoal: @escaping @MainActor @Sendable (CapacityGoal) async throws -> Void,
                now: @escaping @Sendable () -> Date = { Date() }, timeZoneIdentifier: String) {
        self.saveResults = saveResults; self.saveGoal = saveGoal; self.now = now; self.timeZoneIdentifier = timeZoneIdentifier
    }
}

/// Which test is open.
struct FitnessCapacityFlowRequest: Identifiable, Equatable {
    let kind: CapacityTestKind
    var id: String { kind.rawValue }
}

/// One capacity test as a focus screen (DESIGN_LANGUAGE "focus screen"): it covers the tab bar, keeps
/// one action pinned at the bottom, and offers Cancel and the result history at the top. On Save it
/// hands back where its hero number was, so the result can fly into its tile.
struct FitnessCapacityTestScreen: View {
    let tile: FitnessCapacityTile
    let actions: FitnessCapacityActions?
    let saved: (FitnessCapacityLanding) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showsHistory = false
    @State private var heroFrame: CGRect = .zero
    @State private var saving = false
    @State private var problem: String?

    private var now: @Sendable () -> Date {
        if let actions { return actions.now }
        return { Date() }
    }
    private var timeZone: String { actions?.timeZoneIdentifier ?? TimeZone.current.identifier }

    var body: some View {
        NavigationStack {
            content
                .background(Color.loopr(.background).ignoresSafeArea())
                .navigationTitle(tile.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(tile.kind == .heartRateRecovery ? "Done" : "Cancel") { dismiss() }
                            .accessibilityIdentifier("fitness-test-cancel")
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button("Results") { showsHistory = true }
                            .accessibilityIdentifier("fitness-test-history")
                    }
                }
        }
        .tint(Color.loopr(.strain))
        .accessibilityIdentifier("fitness-test-\(FitnessCapacityTiles.kebab(tile.kind))")
        .sheet(isPresented: $showsHistory) {
            FitnessCapacityHistorySheet(tile: tile, saveGoal: saveGoal)
        }
    }

    @ViewBuilder
    private var content: some View {
        let context = FitnessTestContext(now: now, timeZone: timeZone, saving: saving, problem: problem,
                                         heroFrame: $heroFrame, save: save)
        switch tile.kind {
        case .grip: FitnessGripTestView(tile: tile, context: context)
        case .deadHang, .oneLegBalance: FitnessTimedTestView(tile: tile, context: context)
        case .sitToStand: FitnessSitToStandTestView(tile: tile, context: context)
        case .heartRateRecovery: FitnessHeartRateRecoveryView(tile: tile, done: { dismiss() })
        }
    }

    private var saveGoal: ((Double) async throws -> Void)? {
        guard let actions, let scale = CapacityGoalScale.scale(for: tile.kind) else { return nil }
        let kind = tile.kind
        return { value in try await actions.saveGoal(try scale.goal(kind: kind, value: value, at: actions.now())) }
    }

    /// No store to save into: Loopr's storage did not open.
    static let noStoreProblem = "Loopr's storage did not open, so Loopr cannot save this result. Close Loopr and open it again."
    /// The store refused the result.
    static let saveFailedProblem = "Loopr did not save this result. Tap Save to try again."

    private func save(_ results: [CapacityResult]) {
        guard !results.isEmpty else { return }
        guard let actions else {
            problem = Self.noStoreProblem
            return
        }
        saving = true
        problem = nil
        Task { @MainActor in
            do {
                try await actions.saveResults(results)
                let outcome = try CapacityFlowOutcome(kind: tile.kind, previousBest: tile.bestValue, results: results,
                                                      goal: tile.goalValue)
                saved(FitnessCapacityLanding(outcome: outcome, heroFrame: heroFrame))
                dismiss()
            } catch {
                problem = Self.saveFailedProblem
            }
            saving = false
        }
    }
}

/// What every test body shares with its screen.
struct FitnessTestContext {
    let now: @Sendable () -> Date
    let timeZone: String
    let saving: Bool
    let problem: String?
    @Binding var heroFrame: CGRect
    let save: ([CapacityResult]) -> Void
}

extension View {
    /// Reports the hero's frame on screen, so a saved result can fly from it.
    func fitnessHeroFrame(_ frame: Binding<CGRect>) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame.wrappedValue = $0 }
    }

    /// The one action, pinned at the bottom on the screen's own background, with a short fade above it. A saving
    /// problem or a hint sits right above the action on that solid background, so it never draws over the last
    /// instruction (R2-UPG-3, R3-NEW-4).
    func fitnessPinnedAction<Bar: View>(problem: String? = nil, hint: String? = nil, @ViewBuilder _ bar: () -> Bar) -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: LooprSpacing.xs) {
                FitnessTestProblem(text: problem)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if problem == nil, let hint {
                    LooprText(hint, style: .caption, color: .inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("fitness-test-hint")
                }
                bar()
            }
                .padding(.horizontal, LooprSpacing.screenGutter)
                .padding(.top, LooprSpacing.sm)
                .padding(.bottom, LooprSpacing.xs)
                .background { Color.loopr(.background).ignoresSafeArea() }
                .overlay(alignment: .top) {
                    LinearGradient(colors: [Color.loopr(.background).opacity(0), Color.loopr(.background)],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: LooprSpacing.md)
                        .offset(y: -LooprSpacing.md)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
        }
    }
}

/// Left or right, as two 56 pt buttons.
struct FitnessSidePicker: View {
    let kind: CapacityTestKind
    @Binding var side: CapacitySide

    var body: some View {
        HStack(spacing: LooprSpacing.xs) {
            ForEach(CapacitySide.allCases, id: \.self) { option in
                Button(Self.title(option, kind: kind)) { side = option }
                    .buttonStyle(LooprButtonStyle(prominent: side == option, accent: .strain))
                    .accessibilityAddTraits(side == option ? .isSelected : [])
                    .accessibilityIdentifier("fitness-test-side-\(option.rawValue)")
            }
        }
    }

    static func title(_ side: CapacitySide, kind: CapacityTestKind) -> String {
        let limb = kind == .grip ? "hand" : "leg"
        return "\(side == .left ? "Left" : "Right") \(limb)"
    }
}

/// A short list of plain steps.
struct FitnessInstructions: View {
    let lines: [String]

    var body: some View {
        LooprCard {
            VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.xs) {
                        Circle().fill(Color.loopr(.strain)).frame(width: 5, height: 5).accessibilityHidden(true)
                        LooprText(line, style: .prose, color: .inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("fitness-test-instructions")
    }
}

/// The saving problem, when there is one.
struct FitnessTestProblem: View {
    let text: String?

    var body: some View {
        if let text {
            LooprText(text, style: .caption, color: .warning)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("fitness-test-problem")
        }
    }
}

// MARK: - Timed tests

/// Dead hang and one-leg balance: Start, a 3-2-1 lead-in with a tick each second, then the phone times
/// the run until Stop. Balance runs with eyes closed, so a tap anywhere stops it and a tick plays at the
/// start and every ten seconds. Each run is worked out from its start time, so the background never
/// stretches or loses it.
struct FitnessTimedTestView: View {
    let tile: FitnessCapacityTile
    let context: FitnessTestContext

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var timer = CapacityTimer()
    @State private var side: CapacitySide = .left
    @State private var elapsed = 0.0
    @State private var countdown: Int?
    @State private var ticks = 0
    @State private var running = false
    @State private var haptic: LooprHaptic?

    private var isBalance: Bool { tile.kind == .oneLegBalance }

    static let misTap = "That was under a second, so Loopr did not keep it. Start again when you are ready."
    static let backgrounded = "Loopr was in the background for part of this run. The time still counts from when it started."

    static func instructions(_ kind: CapacityTestKind) -> [String] {
        kind == .oneLegBalance ? [
            "Stand on one leg with your arms by your sides, near a wall or a chair.",
            "Tap Start. After 3, 2, 1 you feel a tap. Then close your eyes.",
            "A tap every 10 seconds tells you the time.",
            "When your foot touches down or you open your eyes, tap anywhere on the screen."
        ] : [
            "Hang from a bar with straight arms and both hands over the bar.",
            "Tap Start and take hold of the bar during 3, 2, 1. The timer starts when the count ends.",
            "Tap Stop as soon as you let go."
        ]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LooprSpacing.md) {
                if isBalance { FitnessSidePicker(kind: tile.kind, side: $side).disabled(isActive) }
                hero
                if timer.rejectedMisTap { message(Self.misTap) }
                if timer.wasBackgrounded, timer.isStopped { message(Self.backgrounded) }
                FitnessInstructions(lines: Self.instructions(tile.kind))
            }
            .padding(.horizontal, LooprSpacing.screenGutter)
            .padding(.top, LooprSpacing.md)
            .padding(.bottom, LooprSpacing.lg)
        }
        .overlay {
            if isBalance, running {
                // Eyes closed: the whole screen stops the run.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { stop() }
                    .accessibilityHidden(true)
            }
        }
        .fitnessPinnedAction(problem: context.problem) { actionBar }
        .looprHaptic(haptic)
        .task(id: isActive) { await follow() }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: timer.enterBackground(at: context.now())
            case .active: timer.enterForeground(at: context.now()); refresh()
            default: break
            }
        }
    }

    private var isActive: Bool {
        switch timer.phase {
        case .leadIn, .running: true
        case .ready, .stopped: false
        }
    }

    private var hero: some View {
        VStack(spacing: LooprSpacing.xs) {
            if let countdown {
                LooprHeroNumber(Double(countdown), style: .heroNumeralXXL, color: .strain)
                    .id("countdown")
                LooprText(isBalance ? "Close your eyes at the tap" : "Take hold of the bar", style: .caption, color: .inkSecondary)
            } else {
                LooprHeroNumber(elapsed, unit: "s", spokenUnit: "seconds", fractionDigits: 1, style: .heroNumeralXXL,
                                color: running ? .strain : .ink)
                LooprText(caption, style: .caption, color: .inkSecondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 180)
        .fitnessHeroFrame(context.$heroFrame)
        .transition(.opacity)
        .animation(LooprMotion.reducesMotion(reduceMotion) ? .easeOut(duration: LooprMotion.fast) : .smooth, value: countdown)
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Start timer") { start() }
        .accessibilityAction(named: "Stop timer") { stop() }
        .accessibilityIdentifier("fitness-test-hero")
    }

    private var caption: String {
        if running { return isBalance ? "Tap anywhere when your foot touches down" : "Tap Stop when you let go" }
        if timer.isStopped { return FitnessOverview.valueText(tile.kind, (elapsed * 10).rounded() / 10) + (isBalance ? " seconds" : "") }
        guard let best = tile.valueText else { return "Not tested yet" }
        let unit = tile.unitText.map { " " + $0 } ?? ""
        return "Your best is \(best)\(unit)"
    }

    private func message(_ text: String) -> some View {
        LooprText(text, style: .caption, color: .inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("fitness-test-message")
    }

    @ViewBuilder
    private var actionBar: some View {
        switch timer.phase {
        case .ready:
            Button("Start") { start() }
                .buttonStyle(LooprButtonStyle(accent: .strain))
                .accessibilityIdentifier("fitness-test-start")
        case .leadIn, .running:
            Button("Stop") { stop() }
                .buttonStyle(LooprButtonStyle(accent: .strain))
                .accessibilityIdentifier("fitness-test-stop")
        case .stopped:
            Button("Save") { save() }
                .buttonStyle(LooprButtonStyle(accent: .strain))
                .disabled(context.saving)
                .accessibilityIdentifier("fitness-test-save")
            Button("Try again") { timer.reset(); refresh() }
                .buttonStyle(LooprButtonStyle(prominent: false, accent: .strain))
                .disabled(context.saving)
                .accessibilityIdentifier("fitness-test-retry")
        }
    }

    private func start() {
        timer.start(at: context.now())
        refresh()
    }

    private func stop() {
        timer.stop(at: context.now())
        refresh()
    }

    private func save() {
        let now = context.now()
        guard let result = try? timer.capacityResult(kind: tile.kind, side: side, at: now, timeZoneIdentifier: context.timeZone) else {
            return
        }
        context.save([result])
    }

    /// Reads the timer at the clock's time, and plays the ticks: one each second of the lead-in, one as
    /// the run starts, and for balance one every ten seconds.
    private func refresh() {
        let now = context.now()
        let nextCountdown = timer.countdown(at: now)
        let nextRunning: Bool = if case .running = timer.resolved(at: now) { true } else { false }
        let nextTicks = timer.ticks(at: now)
        if let nextCountdown, nextCountdown != countdown { haptic = LooprHaptic(.impact(weight: .light)) }
        if nextRunning, !running { haptic = LooprHaptic(.impact(weight: .heavy)) }
        if isBalance, nextRunning, nextTicks > ticks { haptic = LooprHaptic(.impact(weight: .medium)) }
        countdown = nextCountdown
        running = nextRunning
        ticks = nextRunning ? nextTicks : 0
        elapsed = timer.elapsed(at: now)
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

// MARK: - Grip

/// Grip typed in from a dynamometer: pick the hand, read the dial, add the trial. Up to three trials per
/// hand; the best of each hand is saved.
struct FitnessGripTestView: View {
    let tile: FitnessCapacityTile
    let context: FitnessTestContext

    @State private var trials = GripTrials()
    @State private var side: CapacitySide = .right
    @State private var value: Double = 40
    /// False until the person moves the dial or the stepper. The dial starts at 40 kg to give it a place, but 40 is
    /// not a reading, so nothing is shown as one and no trial can be added until the person sets it.
    @State private var entered = false

    static let instructions = [
        "Sit with your elbow bent at a right angle and your wrist straight.",
        "Squeeze the dynamometer as hard as you can for about three seconds.",
        "Rest a minute between trials. Do up to three with each hand.",
        "Loopr keeps the best trial of each hand."
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LooprSpacing.md) {
                FitnessSidePicker(kind: .grip, side: $side)
                VStack(spacing: LooprSpacing.xs) {
                    LooprHeroNumber(shownValue, unit: "kg", spokenUnit: "kilograms",
                                    fractionDigits: GripTrials.snapped(shownValue ?? 0).truncatingRemainder(dividingBy: 1) == 0 ? 0 : 1,
                                    style: .heroNumeralXXL, color: .ink) { LooprText("–", style: .heroNumeralXXL, color: .inkMuted) }
                    LooprText(heroCaption, style: .caption, color: .inkSecondary)
                }
                .frame(maxWidth: .infinity, minHeight: 150)
                .fitnessHeroFrame(context.$heroFrame)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("fitness-test-hero")
                LooprRulerPicker("Grip", value: $value, in: 1...100, step: GripTrials.step, majorEvery: 20, unit: "kg", accent: .strain,
                                 majorsFromZero: true)
                    .frame(height: 64)
                LooprValueStepper("kg", label: "Grip", spokenUnit: "kilograms", value: $value, step: GripTrials.step,
                                  range: GripTrials.range, identifier: "fitness-grip-value",
                                  decrementIdentifier: "fitness-grip-minus", incrementIdentifier: "fitness-grip-plus")
                // Until a trial exists, adding one is the only action. Save joins it after the first.
                if trials.hasTrials { addTrialButton(prominent: false) }
                trialList
                FitnessInstructions(lines: Self.instructions)
            }
            .padding(.horizontal, LooprSpacing.screenGutter)
            .padding(.top, LooprSpacing.md)
            .padding(.bottom, LooprSpacing.lg)
        }
        .onChange(of: value) { _, _ in entered = true }
        .fitnessPinnedAction(problem: context.problem) {
            if trials.hasTrials {
                Button("Save") {
                    if let results = try? trials.results(at: context.now(), timeZoneIdentifier: context.timeZone) { context.save(results) }
                }
                .buttonStyle(LooprButtonStyle(accent: .strain))
                .disabled(context.saving)
                .accessibilityIdentifier("fitness-test-save")
            } else {
                addTrialButton(prominent: true)
            }
        }
    }

    /// The reading on the dial once the person has set it, else the best trial. Nil before either.
    private var shownValue: Double? { trials.best ?? (entered ? value : nil) }

    private var heroCaption: String {
        if trials.hasTrials { return "Best so far" }
        return entered ? "The reading to add" : "Set the dial to your reading"
    }

    private func addTrialButton(prominent: Bool) -> some View {
        Button(trials.canAdd(side) ? "Add trial for \(FitnessSidePicker.title(side, kind: .grip).lowercased())"
                                   : "Three trials for this hand") {
            trials.add(value, side: side)
        }
        .buttonStyle(LooprButtonStyle(prominent: prominent, accent: .strain))
        .disabled(!trials.canAdd(side) || !entered)
        .accessibilityIdentifier("fitness-grip-add-trial")
    }

    @ViewBuilder
    private var trialList: some View {
        if trials.hasTrials {
            LooprCard(density: .flush) {
                VStack(spacing: LooprSpacing.none) {
                    ForEach(CapacitySide.allCases, id: \.self) { hand in
                        ForEach(Array(trials.trials(hand).enumerated()), id: \.offset) { index, trial in
                            trialRow(hand: hand, index: index, value: trial)
                        }
                    }
                }
            }
        }
    }

    private func trialRow(hand: CapacitySide, index: Int, value: Double) -> some View {
        let isBest = trials.best(hand) == value && trials.trials(hand).firstIndex(of: value) == index
        let text = "\(FitnessOverview.valueText(.grip, value)) kg"
        return HStack(spacing: LooprSpacing.sm) {
            LooprText("\(FitnessSidePicker.title(hand, kind: .grip)), trial \(index + 1)", style: .rowTitle)
            Spacer(minLength: LooprSpacing.xs)
            if isBest { StatusChip("Best", symbol: nil, accent: .strain) }
            Text(verbatim: text).looprTypography(.metricValue).foregroundStyle(Color.loopr(.ink))
            Button { trials.remove(at: index, side: hand) } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(Color.loopr(.inkMuted))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(text)")
        }
        .padding(.horizontal, LooprSpacing.cardHorizontal)
        .frame(minHeight: LooprSpacing.interactiveRowHeight)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("fitness-grip-trial-\(hand.rawValue)-\(index)")
    }
}

// MARK: - Sit to stand

/// The sitting-rising test, scored by the person: five points for sitting down to the floor and five
/// for standing up, less a point for each support and half a point for each wobble.
struct FitnessSitToStandTestView: View {
    let tile: FitnessCapacityTile
    let context: FitnessTestContext

    static let scoreBothHint = "Score both halves to save."

    @State private var score = SitToStandScore()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LooprSpacing.md) {
                VStack(spacing: LooprSpacing.xs) {
                    LooprHeroNumber(score.total, unit: "/10", spokenUnit: "out of 10",
                                    fractionDigits: (score.total ?? 0).truncatingRemainder(dividingBy: 1) == 0 ? 0 : 1,
                                    style: .heroNumeralXXL, color: .ink) { LooprText("–", style: .heroNumeralXXL, color: .inkMuted) }
                    LooprText(score.isComplete ? "Your score" : "Score both halves", style: .caption, color: .inkSecondary)
                }
                .frame(maxWidth: .infinity, minHeight: 150)
                .fitnessHeroFrame(context.$heroFrame)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("fitness-test-hero")
                half("Sitting down", value: score.sitting, identifier: "fitness-sit-sitting",
                     set: { score.setSitting($0) }, start: { score.setSitting(SitToStandScore.phaseMaximum) })
                half("Standing up", value: score.rising, identifier: "fitness-sit-rising",
                     set: { score.setRising($0) }, start: { score.setRising(SitToStandScore.phaseMaximum) })
                FitnessInstructions(lines: SitToStandScore.rules)
            }
            .padding(.horizontal, LooprSpacing.screenGutter)
            .padding(.top, LooprSpacing.md)
            .padding(.bottom, LooprSpacing.lg)
        }
        .fitnessPinnedAction(problem: context.problem, hint: score.isComplete ? nil : Self.scoreBothHint) {
            Button("Save") {
                if let result = try? score.result(at: context.now(), timeZoneIdentifier: context.timeZone) { context.save([result]) }
            }
            .buttonStyle(LooprButtonStyle(accent: .strain))
            .disabled(!score.isComplete || context.saving)
            // The shared button style does not dim, so an unscored Save looked live and did nothing (R3-UPG-10).
            .opacity(score.isComplete ? 1 : 0.45)
            .accessibilityIdentifier("fitness-test-save")
        }
    }

    /// One half of the score. Until the person scores it there is only a button, so a half is never 5 by default.
    @ViewBuilder
    private func half(_ title: String, value: Double?, identifier: String, set: @escaping (Double) -> Void,
                      start: @escaping () -> Void) -> some View {
        if let value {
            LooprValueStepper(title, label: title, spokenUnit: "points",
                              value: Binding(get: { value }, set: set),
                              step: SitToStandScore.step, range: 0...SitToStandScore.phaseMaximum,
                              identifier: identifier, decrementIdentifier: identifier + "-minus",
                              incrementIdentifier: identifier + "-plus")
        } else {
            Button(action: start) {
                HStack {
                    LooprText(title, style: .rowTitle)
                    Spacer(minLength: LooprSpacing.xs)
                    LooprText("Not scored. Tap to start at 5", style: .caption, color: .inkSecondary)
                }
                .frame(maxWidth: .infinity, minHeight: LooprSpacing.interactiveRowHeight, alignment: .leading)
                .padding(.horizontal, LooprSpacing.cardHorizontal)
                .looprCardBackground(density: .compact)
                .contentShape(Rectangle())
            }
            .buttonStyle(.looprPressableCard)
            .accessibilityLabel("\(title), not scored. Starts at 5 points")
            .accessibilityIdentifier(identifier + "-start")
        }
    }
}

// MARK: - Heart rate recovery

/// Heart rate recovery, read only: how far heart rate fell in the first minute after the latest workout
/// that has a score.
struct FitnessHeartRateRecoveryView: View {
    let tile: FitnessCapacityTile
    let done: () -> Void

    static let explanation = [
        "This is how far your heart rate fell in the first minute after a workout ended.",
        "Loopr reads it from completed workouts with a heart rate recording, so there is nothing to do here."
    ]
    static let empty = "No workout has a heart rate recovery yet. Finish a workout with the band on and keep it on for a minute afterwards."

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LooprSpacing.md) {
                VStack(spacing: LooprSpacing.xs) {
                    if let value = tile.bestValue {
                        LooprHeroNumber(value, unit: "bpm", spokenUnit: "beats a minute", style: .heroNumeralXXL, color: .ink)
                        if let source = tile.sourceLine { LooprText(source, style: .caption, color: .inkSecondary) }
                    } else {
                        LooprText(Self.empty, style: .prose, color: .inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 150)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("fitness-test-hero")
                FitnessInstructions(lines: Self.explanation)
            }
            .padding(.horizontal, LooprSpacing.screenGutter)
            .padding(.top, LooprSpacing.md)
            .padding(.bottom, LooprSpacing.lg)
        }
        .fitnessPinnedAction {
            Button("Done") { done() }
                .buttonStyle(LooprButtonStyle(accent: .strain))
                .accessibilityIdentifier("fitness-test-done")
        }
    }
}
