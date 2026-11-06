import DesignSystem
import SwiftUI

/// Work and rest rounds with band cues. Presets cover Norwegian 4x4, EMOM 10 min, Tabata and 30/30; the steppers
/// move 5 s below a minute and 15 s above, and repeat on a long press (R1-VET-08, R1-WOD-05). A finished session
/// saves as a HIIT workout on its own; Discard removes it again.
///
/// Round 2 (R2-VET-05): an optional warm-up and cool-down, a total without a rest after the last interval, and a
/// name the session saves under, filled from the preset ("Norwegian 4x4") until the person types their own.
public struct IntervalTimerScreen: View {
    @ObservedObject private var model: IntervalTimerModel
    private let hooks: IntervalTimerHooks
    private let liveSource: (any WorkoutLiveSampleSource)?
    private let bandCueUnavailableReason: (@Sendable () async -> String?)?
    @State private var cueUnavailableReason: String?
    private let onSave: (@Sendable (IntervalSessionResult, String) async throws -> UUID)?
    private let onDiscard: (@Sendable (UUID) async throws -> Void)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.bandConnected) private var bandConnected
    @State private var work = 30
    @State private var rest = 30
    @State private var rounds = 10
    @State private var warmUpMinutes = 0
    @State private var coolDownMinutes = 0
    /// The typed name. Nil until the person types one; the field then shows the preset's or a made-up name.
    @State private var typedName: String?
    @State private var busy = false
    @State private var errorMessage: String?

    private static let workRange = 5...3600
    private static let restRange = 0...3600

    public init(model: IntervalTimerModel, hooks: IntervalTimerHooks = .init(), liveSource: (any WorkoutLiveSampleSource)? = nil,
                onSave: (@Sendable (IntervalSessionResult, String) async throws -> UUID)? = nil,
                onDiscard: (@Sendable (UUID) async throws -> Void)? = nil,
                bandCueUnavailableReason: (@Sendable () async -> String?)? = nil) {
        self.model = model; self.hooks = hooks; self.liveSource = liveSource; self.onSave = onSave; self.onDiscard = onDiscard
        self.bandCueUnavailableReason = bandCueUnavailableReason
    }

    public var body: some View {
        LooprDetailScaffold {
            if let schedule = model.schedule, let progress = model.progress {
                LooprSurface(emphasis: progress.phase == .work ? .hero(.workoutAccent) : .standard) {
                    VStack(alignment: .leading, spacing: LooprSpacing.md) {
                        LooprText(progress.phase.title, style: .sectionLabel, color: .inkSecondary)
                            .accessibilityIdentifier("interval-phase")
                        Text(String(format: "%02d:%02d", progress.remainingSeconds / 60, progress.remainingSeconds % 60))
                            .looprTypography(.hero)
                            .foregroundStyle(Color.loopr(.ink))
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                            .monospacedDigit()
                            .accessibilityLabel("\(progress.remainingSeconds) seconds remaining")
                            .accessibilityIdentifier("interval-countdown")
                        if progress.phase == .work || progress.phase == .rest {
                            LooprText("Round \(progress.round) of \(schedule.configuration.rounds)", style: .prose, color: .inkSecondary)
                        }
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            if let bpm = model.heartRate(at: context.date) {
                                Label {
                                    LooprValueText(String(bpm), unit: "bpm")
                                } icon: {
                                    Image(systemName: "heart.fill").foregroundStyle(Color.loopr(.heart))
                                }
                                .accessibilityLabel("Live heart rate, \(bpm) beats per minute")
                                .accessibilityIdentifier("interval-heart-rate")
                            }
                        }
                    }
                    .transaction { $0.animation = nil }
                }
                .animation(LooprMotion.reducesMotion(reduceMotion) ? nil : .easeInOut(duration: LooprMotion.standard), value: progress.phase)
            }
            if model.progress?.phase == .complete, onSave != nil { savedCard }
            if !model.isRunning {
                LooprSectionGroup(title: "Presets") {
                    WorkoutChipFlow {
                        ForEach(IntervalPreset.all) { preset in
                            WorkoutChip(title: preset.name, selected: configuration.intervals == preset.configuration,
                                        identifier: "interval-preset-\(preset.id)") { set(preset.configuration) }
                        }
                    }
                }
                LooprFormCard(padding: LooprSpacing.none) {
                    VStack(spacing: LooprSpacing.none) {
                        easyRow("Warm-up", minutes: $warmUpMinutes, identifier: "interval-warmup")
                        LooprHairline()
                        IntervalStepperRow(title: "Work", value: LooprValueFormat.clockText(seconds: Double(work)),
                                           spoken: LooprValueFormat.spokenClock(seconds: Double(work)), identifier: "interval-work",
                                           canDecrement: work > Self.workRange.lowerBound, canIncrement: work < Self.workRange.upperBound) { direction in
                            work = IntervalConfiguration.steppedSeconds(work, direction: direction, range: Self.workRange)
                        }
                        LooprHairline()
                        IntervalStepperRow(title: "Rest", value: rest == 0 ? "None" : LooprValueFormat.clockText(seconds: Double(rest)),
                                           spoken: rest == 0 ? "No rest" : LooprValueFormat.spokenClock(seconds: Double(rest)), identifier: "interval-rest",
                                           canDecrement: rest > Self.restRange.lowerBound, canIncrement: rest < Self.restRange.upperBound) { direction in
                            rest = IntervalConfiguration.steppedSeconds(rest, direction: direction, range: Self.restRange)
                        }
                        LooprHairline()
                        IntervalStepperRow(title: "Rounds", value: "\(rounds)", spoken: "\(rounds) rounds", identifier: "interval-rounds",
                                           canDecrement: rounds > 1, canIncrement: rounds < 100) { direction in
                            rounds = min(max(rounds + direction, 1), 100)
                        }
                        LooprHairline()
                        easyRow("Cool-down", minutes: $coolDownMinutes, identifier: "interval-cooldown")
                    }
                }
                LooprText(totalLine, style: .caption, color: .inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("interval-total")
                if onSave != nil { nameField }
            }
            Button {
                busy = true
                Task { @MainActor in
                    if model.isRunning { await model.stop() }
                    else {
                        errorMessage = nil
                        await model.start(configuration: configuration, title: sessionName, hooks: hooks, liveSource: liveSource)
                    }
                    busy = false
                }
            } label: {
                Text(model.isRunning ? "Stop timer" : "Start timer")
                    .frame(maxWidth: .infinity, minHeight: LooprSpacing.formButtonHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(LooprPrimaryButtonStyle(accent: .workoutAccent))
            .disabled(busy)
            .accessibilityIdentifier(model.isRunning ? "interval-stop" : "interval-start")
            LooprText(cueFootnote, style: .caption, color: .inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let errorMessage { LooprInlineMessage(errorMessage, tone: .warning).accessibilityIdentifier("interval-error") }
        }
        .navigationTitle("Interval timer")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("interval-timer-screen")
        .onChange(of: model.progress?.phase) { _, phase in if phase == .complete { saveFinished() } }
        .task { saveFinished() }
        .task {
            guard let bandCueUnavailableReason else { return }
            while !Task.isCancelled {
                cueUnavailableReason = await bandCueUnavailableReason()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    private var configuration: IntervalConfiguration {
        .init(workSeconds: work, restSeconds: rest, rounds: rounds, warmUpSeconds: warmUpMinutes * 60,
              coolDownSeconds: coolDownMinutes * 60)
    }

    /// "Total 25:00" for the 4x4. With a rest set, it says the last one is left out.
    private var totalLine: String {
        let total = "Total \(LooprValueFormat.clockText(seconds: configuration.duration))"
        return rest > 0 && rounds > 1 ? "\(total). No rest after the last interval." : total
    }

    /// The name the session saves under: what was typed, else the preset's name or one made from the rounds.
    private var sessionName: String {
        WorkoutLogEntry.cleaned(typedName) ?? IntervalPreset.workoutTitle(for: configuration)
    }

    private var nameField: some View {
        LooprFormCard {
            HStack(spacing: LooprSpacing.sm) {
                LooprText("Save as", style: .settingsRow)
                Spacer(minLength: LooprSpacing.sm)
                TextField(text: Binding(get: { typedName ?? IntervalPreset.workoutTitle(for: configuration) },
                                        set: { typedName = $0 }),
                          prompt: Text("Norwegian 4x4").foregroundStyle(Color.loopr(.inkSecondary))) { Text("Save as") }
                    .multilineTextAlignment(.trailing)
                    .looprTypography(.settingsRow)
                    .submitLabel(.done)
                    .accessibilityIdentifier("interval-name")
            }
        }
    }

    /// A warm-up or cool-down row: none, or 1 to 30 minutes a minute at a time.
    private func easyRow(_ title: String, minutes: Binding<Int>, identifier: String) -> some View {
        let range = IntervalConfiguration.easyMinutesRange
        return IntervalStepperRow(title: title, value: minutes.wrappedValue == 0 ? "None" : "\(minutes.wrappedValue) min",
                                  spoken: minutes.wrappedValue == 0 ? "None" : "\(minutes.wrappedValue) minutes",
                                  identifier: identifier, canDecrement: minutes.wrappedValue > range.lowerBound,
                                  canIncrement: minutes.wrappedValue < range.upperBound) { direction in
            minutes.wrappedValue = min(max(minutes.wrappedValue + direction, range.lowerBound), range.upperBound)
        }
    }

    private var savedCard: some View {
        LooprCard {
            HStack(spacing: LooprSpacing.sm) {
                Image(systemName: model.savedWorkoutID == nil ? "xmark.circle" : "checkmark.circle.fill")
                    .foregroundStyle(Color.loopr(model.savedWorkoutID == nil ? .inkSecondary : .workoutAccent))
                    .accessibilityHidden(true)
                LooprText(model.savedWorkoutID != nil ? "Saved as \(model.title ?? "a HIIT workout")"
                          : model.completionHandled ? "Not saved" : "Saving",
                          style: .rowTitle)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("interval-saved")
                Spacer(minLength: LooprSpacing.sm)
                if let id = model.savedWorkoutID, let onDiscard {
                    Button("Discard", role: .destructive) {
                        busy = true
                        Task { @MainActor in
                            do { try await onDiscard(id); model.savedWorkoutID = nil }
                            catch { errorMessage = error.localizedDescription }
                            busy = false
                        }
                    }
                    .disabled(busy)
                    .frame(minHeight: LooprSpacing.interactiveRowHeight)
                    .accessibilityIdentifier("interval-discard")
                }
            }
        }
    }

    /// Saves a finished session once. Coming back to the screen later does not save it again.
    private func saveFinished() {
        guard !model.completionHandled, let session = model.finishedSession, let onSave else { return }
        model.completionHandled = true
        let title = model.title ?? IntervalPreset.workoutTitle(for: session.schedule.configuration)
        Task { @MainActor in
            do { model.savedWorkoutID = try await onSave(session, title) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    private var cueFootnote: String {
        let cues = !bandConnected ? "Connect your band for buzzes. Phone cues still work."
            : cueUnavailableReason ?? "One buzz for work, two for rest."
        // Hard minutes come from heart rate, never from the timer's work phases (R2-VET-05).
        return cues + " The timer keeps running when your iPhone is locked. Hard minutes come from your heart rate, not from this timer."
    }

    private func set(_ preset: IntervalConfiguration) {
        work = preset.workSeconds; rest = preset.restSeconds; rounds = preset.rounds
        typedName = nil
    }
}

/// A label, a value, and minus and plus buttons that repeat while held.
private struct IntervalStepperRow: View {
    let title: String
    let value: String
    let spoken: String
    let identifier: String
    let canDecrement: Bool
    let canIncrement: Bool
    let step: (Int) -> Void

    var body: some View {
        HStack(spacing: LooprSpacing.xs) {
            LooprText(title, style: .settingsRow)
            Spacer(minLength: LooprSpacing.sm)
            button("minus", enabled: canDecrement, direction: -1)
            LooprText(value, style: .metricValue)
                .monospacedDigit()
                .contentTransition(.numericText())
                .frame(minWidth: 64)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(title)
                .accessibilityValue(spoken)
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: step(1)
                    case .decrement: step(-1)
                    @unknown default: break
                    }
                }
                .accessibilityIdentifier(identifier)
            button("plus", enabled: canIncrement, direction: 1)
        }
        .padding(.horizontal, LooprSpacing.formCardPadding)
        .padding(.vertical, LooprSpacing.xs)
        .frame(minHeight: LooprSpacing.interactiveRowHeight)
    }

    private func button(_ symbol: String, enabled: Bool, direction: Int) -> some View {
        Button { step(direction) } label: {
            Image(systemName: symbol)
                .looprTypography(.title)
                .foregroundStyle(Color.loopr(.ink))
                .frame(width: LooprSpacing.interactiveRowHeight, height: LooprSpacing.interactiveRowHeight)
                .glassEffect(.regular.interactive(), in: Circle())
        }
        .buttonStyle(.plain)
        .buttonRepeatBehavior(.enabled)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityLabel(direction > 0 ? "More \(title.lowercased())" : "Less \(title.lowercased())")
        .accessibilityIdentifier("\(identifier)-\(symbol)")
    }
}
