import DesignSystem
import SwiftUI
#if canImport(UIKit)
import AudioToolbox
import UIKit
#endif

/// Runs a WOD on the clock (R2-WOD-01, R2-DES-20). Start counts in 3, 2, 1, then For time counts up to its cap and
/// AMRAP counts down its length. Round +1 counts rounds and a stepper the reps into the next one. On For time, Finish
/// is the big button, since that is the tap that matters at the end; on AMRAP, Round +1 is (R3-WOD-01). Finish, or the
/// cap running out, opens the score step filled from the clock; "Back to the clock" undoes a Finish tapped by mistake,
/// and "Use this score" hands the score to the WOD log. Short tones mark 3, 2, 1, Go, each minute, the last 10 seconds
/// and the end, unless Sound is off (R3-WOD-02). The screen stays awake while it is open.
public struct WODClockScreen: View {
    private let setup: WODClockSetup
    private let name: String?
    private let now: () -> Date
    private let onScore: (WODClockResult) -> Void
    private let onClose: () -> Void

    @ScaledMetric(relativeTo: .largeTitle) private var numeralSize: CGFloat = 104
    @State private var clock: WODClock?
    @State private var tick = Date()
    @State private var scoring: WODClockResult?
    @State private var minutesText = ""
    @State private var secondsText = ""
    @State private var roundsText = ""
    @State private var repsText = ""
    @State private var errorMessage: String?
    @State private var confirmsClose = false
    @State private var runs = 0
    @State private var lastReading: WODClockReading?
    @AppStorage("loopr.wodClock.sound") private var soundOn = true

    public init(setup: WODClockSetup, name: String? = nil, now: @escaping () -> Date = Date.init,
                onScore: @escaping (WODClockResult) -> Void, onClose: @escaping () -> Void) {
        self.setup = setup
        self.name = WorkoutLogEntry.cleaned(name)
        self.now = now
        self.onScore = onScore
        self.onClose = onClose
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LooprSpacing.lg) {
                LooprText([name, setup.summary].compactMap { $0 }.joined(separator: " · "), style: .rowTitle,
                          color: .inkSecondary)
                    .accessibilityIdentifier("wod-clock-setup")
                if let scoring { scoreStep(scoring) } else { clockFace }
            }
            .padding(.horizontal, LooprSpacing.screenGutter)
            .padding(.top, LooprSpacing.sm)
            .padding(.bottom, LooprSpacing.lg)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color.loopr(.background).ignoresSafeArea())
        .accessibilityIdentifier("wod-clock-screen")
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
        .navigationTitle("WOD clock")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") {
                    if clock != nil, scoring == nil { confirmsClose = true } else { onClose() }
                }
                .accessibilityIdentifier("wod-clock-close")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { soundOn.toggle() } label: {
                    Image(systemName: soundOn ? "speaker.wave.2.fill" : "speaker.slash")
                }
                .accessibilityLabel(soundOn ? "Sound on" : "Sound off")
                .accessibilityHint("Tones for the count-in, each minute and the end")
                .accessibilityIdentifier("wod-clock-sound")
            }
        }
        .confirmationDialog("Stop the clock?", isPresented: $confirmsClose, titleVisibility: .visible) {
            Button("Stop without a score", role: .destructive) { onClose() }
                .accessibilityIdentifier("wod-clock-close-confirm")
            Button("Keep going", role: .cancel) {}
        } message: {
            Text("The rounds you counted are not kept.")
        }
        .interactiveDismissDisabled(clock != nil)
        .sensoryFeedback(.impact(weight: .heavy), trigger: clock?.rounds)
        .sensoryFeedback(.selection, trigger: leadInNumber)
        .sensoryFeedback(.success, trigger: scoring != nil) { _, new in new }
        .task(id: runs) { await run() }
        .onChange(of: tick) { _, _ in playCue() }
        .onAppear { keepAwake(true) }
        .onDisappear { keepAwake(false) }
    }

    // MARK: Clock

    private var reading: WODClockReading? { clock?.reading(at: tick) }

    private var leadInNumber: Int? {
        if case .leadIn(let number)? = reading?.phase { return number }
        return nil
    }

    private var clockFace: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.lg) {
            LooprSurface(emphasis: .hero(.workoutAccent)) {
                VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                    LooprText(phaseLabel, style: .sectionLabel, color: .inkSecondary)
                        .accessibilityIdentifier("wod-clock-phase")
                    Text(numeral)
                        .font(.system(size: numeralSize, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.4)
                        .foregroundStyle(Color.loopr(.ink))
                        .contentTransition(.numericText(countsDown: setup.kind == .amrap || leadInNumber != nil))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel(spokenNumeral)
                        .accessibilityAddTraits(.updatesFrequently)
                        .accessibilityIdentifier("wod-clock-time")
                    if let limitLine {
                        LooprText(limitLine, style: .caption, color: .inkSecondary)
                    }
                }
            }
            if clock != nil { counter }
        }
    }

    private var phaseLabel: String {
        switch reading?.phase {
        case nil: setup.kind == .amrap ? "Time left" : "Time"
        case .leadIn: "Get ready"
        case .running: setup.kind == .amrap ? "Time left" : "Time"
        case .timeUp: "Time's up"
        case .finished: "Done"
        }
    }

    private var numeral: String {
        if let leadInNumber { return "\(leadInNumber)" }
        if let reading { return WODScore.clock(reading.displaySeconds) }
        return WODScore.clock(setup.kind == .amrap ? setup.limitSeconds ?? 0 : 0)
    }

    private var spokenNumeral: String {
        if let leadInNumber { return "Starting in \(leadInNumber)" }
        let seconds = reading?.displaySeconds ?? (setup.kind == .amrap ? setup.limitSeconds ?? 0 : 0)
        let words = "\(seconds / 60) minutes \(seconds % 60) seconds"
        return setup.kind == .amrap ? "\(words) left" : words
    }

    /// "Cap 10:00" under a For time clock with a cap. Nil otherwise.
    private var limitLine: String? {
        guard setup.kind == .forTime, let cap = setup.limitSeconds else { return nil }
        return "Cap \(WODScore.clock(cap))"
    }

    /// The rounds done and the reps into the next round, with a stepper and an undo for a mistaken tap.
    private var counter: some View {
        LooprFormCard(padding: LooprSpacing.none) {
            VStack(spacing: LooprSpacing.none) {
                HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.sm) {
                    LooprText("Rounds done", style: .settingsRow)
                    Spacer(minLength: LooprSpacing.sm)
                    if (clock?.rounds ?? 0) > 0 {
                        Button("Undo") { clock?.removeRound() }
                            .looprTypography(.label)
                            .tint(Color.loopr(LooprColorToken.workoutAccent.spectralChipLabel))
                            .frame(minHeight: LooprSpacing.interactiveRowHeight)
                            .accessibilityLabel("Take back one round")
                            .accessibilityIdentifier("wod-clock-round-undo")
                    }
                    LooprText("\(clock?.rounds ?? 0)", style: .metricValue)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .frame(minWidth: 44, alignment: .trailing)
                        .accessibilityLabel("\(clock?.rounds ?? 0) rounds done")
                        .accessibilityIdentifier("wod-clock-rounds")
                }
                .padding(.horizontal, LooprSpacing.formCardPadding)
                .frame(minHeight: LooprSpacing.interactiveRowHeight)
                LooprHairline()
                HStack(spacing: LooprSpacing.xs) {
                    LooprText("Reps into round \((clock?.rounds ?? 0) + 1)", style: .settingsRow)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: LooprSpacing.sm)
                    repButton("minus", spoken: "One rep less", direction: -1)
                    LooprText("\(clock?.reps ?? 0)", style: .metricValue)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .frame(minWidth: 44)
                        .accessibilityLabel("\(clock?.reps ?? 0) reps into this round")
                        .accessibilityIdentifier("wod-clock-reps")
                    repButton("plus", spoken: "One rep more", direction: 1)
                }
                .padding(.horizontal, LooprSpacing.formCardPadding)
                .padding(.vertical, LooprSpacing.xs)
                .frame(minHeight: LooprSpacing.interactiveRowHeight)
            }
        }
        .disabled(clock.map { $0.isOver(at: tick) } ?? true)
    }

    private func repButton(_ symbol: String, spoken: String, direction: Int) -> some View {
        Button { clock?.stepReps(direction) } label: {
            Image(systemName: symbol)
                .looprTypography(.title)
                .foregroundStyle(Color.loopr(.ink))
                .frame(width: LooprSpacing.interactiveRowHeight, height: LooprSpacing.interactiveRowHeight)
                .glassEffect(.regular.interactive(), in: Circle())
        }
        .buttonStyle(.plain)
        .buttonRepeatBehavior(.enabled)
        .accessibilityLabel(spoken)
        .accessibilityIdentifier("wod-clock-reps-\(symbol)")
    }

    // MARK: Bottom bar

    @ViewBuilder
    private var bottomBar: some View {
        VStack(spacing: LooprSpacing.sm) {
            if let scoring {
                Button { useScore() } label: { Text("Use this score").frame(maxWidth: .infinity) }
                    .buttonStyle(LooprPrimaryButtonStyle(accent: .workoutAccent))
                    .accessibilityIdentifier("wod-clock-use-score")
                if !scoring.capped, setup.kind == .forTime || clock?.limitAt.map({ now() < $0 }) == true {
                    Button { resume() } label: { Text("Back to the clock").frame(maxWidth: .infinity) }
                        .buttonStyle(LooprButtonStyle(prominent: false, accent: .workoutAccent))
                        .accessibilityHint("The clock runs on from where it is")
                        .accessibilityIdentifier("wod-clock-resume")
                }
            } else if let clock, setup.kind == .forTime {
                // For time: Finish is the tap that matters, so it is the big one (R3-WOD-01).
                Button { self.clock?.addRound() } label: {
                    Text("Round +1").frame(maxWidth: .infinity, minHeight: 52)
                }
                .buttonStyle(LooprButtonStyle(prominent: false, accent: .workoutAccent))
                .disabled(clock.isOver(at: tick) || leadInNumber != nil)
                .accessibilityLabel("Round plus one")
                .accessibilityValue("\(clock.rounds) rounds done")
                .accessibilityIdentifier("wod-clock-round")
                Button { finish() } label: {
                    Text("Finish").font(.system(.largeTitle, design: .rounded, weight: .bold))
                        .frame(maxWidth: .infinity, minHeight: 132)
                        .contentShape(Rectangle())
                }
                .buttonStyle(LooprPrimaryButtonStyle(accent: .workoutAccent))
                .disabled(leadInNumber != nil)
                .accessibilityHint("Stops the clock and opens the score")
                .accessibilityIdentifier("wod-clock-finish")
            } else if let clock {
                Button { self.clock?.addRound() } label: {
                    VStack(spacing: LooprSpacing.xxs) {
                        Text("Round +1").font(.system(.largeTitle, design: .rounded, weight: .bold))
                        Text("Tap at the end of each round").looprTypography(.caption)
                    }
                    .frame(maxWidth: .infinity, minHeight: 132)
                    .contentShape(Rectangle())
                }
                .buttonStyle(LooprPrimaryButtonStyle(accent: .workoutAccent))
                .disabled(clock.isOver(at: tick) || leadInNumber != nil)
                .accessibilityLabel("Round plus one")
                .accessibilityValue("\(clock.rounds) rounds done")
                .accessibilityIdentifier("wod-clock-round")
                Button { finish() } label: { Text("Finish").frame(maxWidth: .infinity) }
                    .buttonStyle(LooprButtonStyle(prominent: false, accent: .workoutAccent))
                    .accessibilityHint("Stops the clock and opens the score")
                    .accessibilityIdentifier("wod-clock-finish")
            } else {
                Button { start() } label: { Text("Start").frame(maxWidth: .infinity, minHeight: 72) }
                    .buttonStyle(LooprPrimaryButtonStyle(accent: .workoutAccent))
                    .accessibilityHint("Counts in from 3, then starts the clock")
                    .accessibilityIdentifier("wod-clock-start")
                LooprText("Counts in 3, 2, 1. The screen stays on.", style: .caption, color: .inkSecondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, LooprSpacing.screenGutter)
        .padding(.top, LooprSpacing.sm)
        .padding(.bottom, LooprSpacing.xs)
        .background(Color.loopr(.background).ignoresSafeArea())
    }

    // MARK: Score step

    private func scoreStep(_ result: WODClockResult) -> some View {
        VStack(alignment: .leading, spacing: LooprSpacing.md) {
            LooprSurface(emphasis: .hero(.workoutAccent)) {
                VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                    LooprText(result.capped ? "Capped at \(WODScore.clock(setup.limitSeconds ?? 0))"
                              : setup.kind == .amrap ? "Time's up" : "Done", style: .sectionLabel, color: .inkSecondary)
                    LooprText(result.score.text, style: .title)
                        .accessibilityIdentifier("wod-clock-score")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            LooprSectionGroup(title: "Score") {
                LooprFormCard(padding: LooprSpacing.none) {
                    VStack(spacing: LooprSpacing.none) {
                        if result.score.kind == .time {
                            WODTimeField(title: "Time", minutes: $minutesText, seconds: $secondsText,
                                         identifier: "wod-clock-score-time")
                        } else {
                            WorkoutNumberFieldRow(title: "Rounds", placeholder: "0", unit: nil, text: $roundsText,
                                                  identifier: "wod-clock-score-rounds")
                            LooprHairline()
                            WorkoutNumberFieldRow(title: "Extra reps", placeholder: "0", unit: "reps", text: $repsText,
                                                  identifier: "wod-clock-score-reps")
                        }
                    }
                }
            }
            LooprText("From the clock. Fix it here if you stopped late or missed a round.",
                      style: .caption, color: .inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let errorMessage {
                LooprInlineMessage(errorMessage, tone: .warning).accessibilityIdentifier("wod-clock-error")
            }
        }
    }

    // MARK: Actions

    private func start() {
        let started = now()
        tick = started
        lastReading = nil
        clock = WODClock(setup: setup, startedAt: started)
        runs += 1
    }

    /// Advances the display until the clock is over; the cap or the AMRAP length running out opens the score.
    private func run() async {
        while !Task.isCancelled, let clock, scoring == nil {
            tick = now()
            if case .timeUp = clock.reading(at: tick).phase { finish(); return }
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
        }
    }

    /// Undoes Finish: the clock runs on from the time it shows now.
    private func resume() {
        guard var clock else { return }
        clock.resume(at: now())
        guard !clock.isOver(at: now()) else { return }
        self.clock = clock
        scoring = nil
        errorMessage = nil
        runs += 1
    }

    private func playCue() {
        guard let clock else { lastReading = nil; return }
        let reading = clock.reading(at: tick)
        defer { lastReading = reading }
        guard soundOn, let cue = clock.cue(from: lastReading, to: reading) else { return }
        #if canImport(UIKit)
        let sound: SystemSoundID = switch cue {
        case .tick: 1103
        case .go: 1113
        case .minute: 1057
        case .end: 1005
        }
        AudioServicesPlaySystemSound(sound)
        #endif
    }

    private func finish() {
        guard var clock else { return }
        let end = now()
        clock.finish(at: end)
        self.clock = clock
        tick = end
        let result = clock.result(at: end)
        switch result.score.kind {
        case .time:
            (minutesText, secondsText) = WODTimeEntry.fields(for: result.score.seconds ?? 0)
        default:
            roundsText = "\(result.score.rounds ?? 0)"
            repsText = (result.score.reps ?? 0) > 0 ? "\(result.score.reps ?? 0)" : ""
        }
        scoring = result
    }

    /// Hands the score, with any fix typed in the step, to the WOD log.
    private func useScore() {
        guard let result = scoring else { return }
        let score: WODScore
        switch result.score.kind {
        case .time:
            guard case .seconds(let seconds) = WODTimeEntry(minutes: minutesText, seconds: secondsText), seconds > 0 else {
                errorMessage = WODLogInputError.time.errorDescription
                return
            }
            score = .time(seconds: seconds)
        default:
            let rounds = WorkoutNumberFieldRow.number(roundsText).map { Int($0) } ?? 0
            let reps = WorkoutNumberFieldRow.number(repsText).map { Int($0) } ?? 0
            score = .roundsAndReps(rounds: rounds, reps: reps)
        }
        onScore(WODClockResult(score: score, capped: result.capped, workSeconds: result.workSeconds,
                               startedAt: result.startedAt, endedAt: result.endedAt))
    }

    private func keepAwake(_ awake: Bool) {
        #if canImport(UIKit)
        UIApplication.shared.isIdleTimerDisabled = awake
        #endif
    }
}
