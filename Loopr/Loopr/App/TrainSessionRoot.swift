import AnalyticsKit
import DesignSystem
import SwiftUI
import TrainKit
import WorkoutKit

/// What the shell lends the session screens: finishing, pausing, the summary's Done, and the
/// recording they read heart rate from. Closures that cross a suspension are `@Sendable`, and the
/// shell writes them `{ @MainActor @Sendable [captures] in ... }`.
struct TrainSessionActions {
    /// Saves the session, finishes the workout and moves to the summary.
    let finish: @MainActor @Sendable () async throws -> Void
    /// Pauses or resumes the recording.
    let pauseChange: (@MainActor @Sendable (Bool) async throws -> Void)?
    /// Leaves the summary for the workout detail. The argument is the linked workout, if any.
    let summaryDone: @MainActor @Sendable (UUID?) -> Void
    let zones: HeartRateZoneSet?
    let workoutSession: WorkoutSessionController?
}

/// The live set screen and the summary, from the pushed route or the mini-player sheet.
struct TrainSessionRoot: View {
    let route: TrainRoute
    @ObservedObject var runtime: TrainLiveRuntime
    let actions: TrainSessionActions

    var body: some View {
        switch route {
        case .summary(let id):
            TrainSummaryHost(sessionID: id, actions: actions)
        default:
            if let session = runtime.session {
                TrainLiveHost(runtime: runtime, session: session, actions: actions)
            } else {
                ContentUnavailableView("No session in progress", systemImage: "figure.strengthtraining.traditional",
                                       description: Text("Start one from a template on the Fitness tab."))
                    .accessibilityIdentifier("train-live-unavailable")
            }
        }
    }
}

/// Feeds the live screen the recording it reads heart rate and strain from.
private struct TrainLiveHost: View {
    @ObservedObject var runtime: TrainLiveRuntime
    let session: TrainLiveSession
    let actions: TrainSessionActions
    @EnvironmentObject private var repositories: ProductRepositoryContainer
    @State private var workout: WorkoutRecord?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TrainLiveScreen(session: session, workout: workout, zones: actions.zones,
                        bandCueAvailable: runtime.bandCueAvailable,
                        onPauseChange: actions.pauseChange,
                        createCustom: { [repository = repositories.makeTrainRepository()] exercise in
                            try await repository.saveCustomExercise(exercise)
                        },
                        onFinish: actions.finish)
            .task(id: runtime.workoutID) {
                guard let id = runtime.workoutID, let workoutSession = actions.workoutSession else { return }
                workout = await workoutSession.workout(id: id)
                for await update in await workoutSession.updates(for: id) {
                    guard !Task.isCancelled else { break }
                    workout = update
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { runtime.sceneBecameActive() }
            }
    }
}

/// Loads a finished session and shows its summary.
private struct TrainSummaryHost: View {
    let sessionID: UUID
    let actions: TrainSessionActions
    @EnvironmentObject private var repositories: ProductRepositoryContainer
    @State private var phase: Phase = .loading

    private enum Phase {
        case loading
        case ready(TrainSessionDetail, TrainSummaryScreen.Mode, TrainSession, [TrainSession], WorkoutRecord?)
        case failed(String)
    }

    var body: some View {
        Group {
            switch phase {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.loopr(.background))
                    .accessibilityLabel("Loading the summary")
                    .accessibilityIdentifier("train-summary-loading")
            case .ready(let detail, let mode, let session, let history, let workout):
                TrainSummaryScreen(detail: detail, mode: mode, session: session, history: history, workout: workout,
                                   save: { @Sendable [train = repositories.makeTrainRepository()] corrected in
                                       try await train.saveSession(corrected)
                                   }) { actions.summaryDone(detail.summary.workoutID) }
            case .failed(let message):
                VStack(spacing: LooprSpacing.cardStack) {
                    LooprText(message, style: .body, color: .inkSecondary)
                        .accessibilityIdentifier("train-summary-error")
                    Button("Try again") { Task { await load() } }
                        .buttonStyle(LooprButtonStyle(accent: .movement))
                        .accessibilityIdentifier("train-summary-retry")
                    Button("Done") { actions.summaryDone(nil) }
                        .buttonStyle(LooprButtonStyle(prominent: false, accent: .movement))
                        .accessibilityIdentifier("train-summary-done")
                }
                .padding(LooprSpacing.screenGutter)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.loopr(.background))
            }
        }
        .task(id: sessionID) { await load() }
    }

    /// A session that ended in the last half hour is the one just finished: "Session saved" and the week's dots. An
    /// older one opens as a record, "Saved Tue 7 Nov", with no pinned bar (R2-NEW-07, R2-LIFT-02).
    static func mode(for session: TrainSession, now: Date) -> TrainSummaryScreen.Mode {
        guard let ended = session.endedAt else { return .past }
        return now.timeIntervalSince(ended) < 30 * 60 ? .finished : .past
    }

    private func load() async {
        phase = .loading
        do {
            let train = repositories.makeTrainRepository()
            guard let session = try await train.session(id: sessionID) else { throw TrainError.missingRecord }
            var workout: WorkoutRecord?
            if let id = session.workoutID { workout = await actions.workoutSession?.workout(id: id) }
            let history = (try? await train.recentSessions(limit: 200)) ?? []
            phase = .ready(TrainSessionDetail(session: session, workout: workout), Self.mode(for: session, now: Date()), session, history, workout)
        } catch is CancellationError {
            return
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}
