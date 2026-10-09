import DesignSystem
import SwiftUI

public struct IntervalTimerScreen: View {
    @ObservedObject private var model: IntervalTimerModel
    private let hooks: IntervalTimerHooks
    private let liveSource: (any WorkoutLiveSampleSource)?
    private let bandCueUnavailableReason: (@Sendable () async -> String?)?
    @State private var cueUnavailableReason: String?
    private let onSave: (@Sendable (Date, Date) async throws -> Void)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.bandConnected) private var bandConnected
    @State private var work = 30
    @State private var rest = 30
    @State private var rounds = 10
    @State private var busy = false
    @State private var saved = false
    @State private var errorMessage: String?

    public init(model: IntervalTimerModel, hooks: IntervalTimerHooks = .init(), liveSource: (any WorkoutLiveSampleSource)? = nil,
                onSave: (@Sendable (Date, Date) async throws -> Void)? = nil,
                bandCueUnavailableReason: (@Sendable () async -> String?)? = nil) {
        self.model = model; self.hooks = hooks; self.liveSource = liveSource; self.onSave = onSave
        self.bandCueUnavailableReason = bandCueUnavailableReason
    }

    public var body: some View {
        LooprDetailScaffold {
            if let schedule = model.schedule, let progress = model.progress {
                LooprSurface(emphasis: progress.phase == .work ? .hero(.movement) : .standard) {
                    VStack(alignment: .leading, spacing: LooprSpacing.md) {
                        LooprText(progress.phase == .complete ? "Complete" : progress.phase == .work ? "Work" : "Rest", style: .sectionLabel, color: .inkSecondary)
                            .accessibilityIdentifier("interval-phase")
                        Text(String(format: "%02d:%02d", progress.remainingSeconds / 60, progress.remainingSeconds % 60))
                            .font(.custom("IBMPlexMono-SemiBold", size: LooprTextStyle.hero.baseSize, relativeTo: .largeTitle))
                            .foregroundStyle(Color.loopr(.ink))
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                            .monospacedDigit()
                            .accessibilityLabel("\(progress.remainingSeconds) seconds remaining")
                            .accessibilityIdentifier("interval-countdown")
                        LooprText("Round \(progress.round) of \(schedule.configuration.rounds)", style: .prose, color: .inkSecondary)
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
            if !model.isRunning {
                LooprSectionGroup(title: "Presets") {
                    HStack {
                        Button("30/30 × 10") { set(.thirtyThirty) }
                        Button("Tabata 20/10 × 8") { set(.tabata) }
                    }
                    .buttonStyle(.bordered)
                }
                LooprFormCard {
                    Stepper("Work \(work) seconds", value: $work, in: 1...3600)
                        .accessibilityIdentifier("interval-work")
                    Stepper("Rest \(rest) seconds", value: $rest, in: 0...3600)
                    Stepper("\(rounds) rounds", value: $rounds, in: 1...100)
                }
            }
            Button {
                busy = true
                Task { @MainActor in
                    if model.isRunning { await model.stop() }
                    else {
                        saved = false; errorMessage = nil
                        await model.start(configuration: .init(workSeconds: work, restSeconds: rest, rounds: rounds), hooks: hooks, liveSource: liveSource)
                    }
                    busy = false
                }
            } label: {
                Text(model.isRunning ? "Stop timer" : "Start timer")
                    .frame(maxWidth: .infinity, minHeight: LooprSpacing.formButtonHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(LooprPrimaryButtonStyle(accent: .movement))
            .disabled(busy)
            .accessibilityIdentifier(model.isRunning ? "interval-stop" : "interval-start")
            LooprText(cueFootnote, style: .caption, color: .inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.progress?.phase == .complete, let schedule = model.schedule, let onSave {
                Button(saved ? "Workout saved" : "Save as HIIT workout") {
                    busy = true
                    Task { @MainActor in
                        do { try await onSave(schedule.startedAt, schedule.endsAt); saved = true }
                        catch { errorMessage = error.localizedDescription }
                        busy = false
                    }
                }
                .buttonStyle(.bordered)
                .disabled(busy || saved)
            }
            if let errorMessage { LooprInlineMessage(errorMessage, tone: .warning) }
        }
        .navigationTitle("Interval timer")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("interval-timer-screen")
        .task {
            guard let bandCueUnavailableReason else { return }
            while !Task.isCancelled {
                cueUnavailableReason = await bandCueUnavailableReason()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    private var cueFootnote: String {
        let cues = !bandConnected ? "Connect your band for buzzes. Phone cues still work."
            : cueUnavailableReason ?? "One buzz for work, two for rest."
        return cues + " The timer keeps running when your iPhone is locked."
    }

    private func set(_ preset: IntervalConfiguration) {
        work = preset.workSeconds; rest = preset.restSeconds; rounds = preset.rounds
    }
}
