import DesignSystem
import DomainKit
import SwiftUI
import TrainKit
import WorkoutKit

/// The past gym session logger, pushed from Gym in the quick log (R2-LIFT-05). It loads the exercise library and the
/// finished sessions, and Save writes a manual strength workout for the chosen time and the session linked to it, so
/// the dose, the week strip and the lists count it once. Then it pops back to Fitness.
struct TrainPastSessionRoot: View {
    let workoutSession: WorkoutSessionController?

    @EnvironmentObject private var repositories: ProductRepositoryContainer
    @Environment(\.dismiss) private var dismiss
    @State private var phase: Phase = .loading

    private enum Phase {
        case loading
        case ready(library: ExerciseLibrary, history: [TrainSession], templates: [WorkoutTemplate], repository: AppTrainRepository)
        case failed(String)
    }

    var body: some View {
        Group {
            switch phase {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.loopr(.background))
                    .accessibilityLabel("Loading")
                    .accessibilityIdentifier("train-past-loading")
            case .failed(let message):
                VStack(spacing: LooprSpacing.cardStack) {
                    LooprText(message, style: .body, color: .inkSecondary)
                        .accessibilityIdentifier("train-past-error")
                    Button("Try again") { Task { await load() } }
                        .buttonStyle(LooprButtonStyle(accent: .movement))
                        .accessibilityIdentifier("train-past-retry")
                }
                .padding(LooprSpacing.screenGutter)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.loopr(.background))
            case .ready(let library, let history, let templates, let repository):
                TrainPastSessionScreen(
                    library: library, history: history, templates: templates, now: { now },
                    createCustom: { @Sendable [repository] exercise in try await repository.saveCustomExercise(exercise) },
                    save: { draft in
                        try await save(draft, repository: repository)
                        dismiss()
                    })
            }
        }
        .task { await load() }
    }

    /// The Train fixture's Tuesday in a fixture launch, so a logged session lands in the fixture week.
    private var now: Date {
        #if DEBUG
        if repositories.isFixtureComposition, AppTrainFixtures.isRequested() { return AppTrainFixtures.now }
        #endif
        return repositories.environment.dateProvider.now()
    }

    private func makeRepository() -> AppTrainRepository {
        if let persistent = repositories.persistent {
            return AppTrainRepository(store: persistent.train, environment: repositories.environment)
        }
        #if DEBUG
        return repositories.fixtureTrainRepository
        #else
        return AppTrainRepository(environment: repositories.environment)
        #endif
    }

    private func load() async {
        phase = .loading
        let repository = makeRepository()
        do {
            let custom = try await repository.customExercises()
            let history = try await repository.recentSessions(limit: 200, status: .completed)
            let templates = try await repository.templates()
            let bundled = try await Task.detached(priority: .userInitiated) { try TrainTemplateRoot.loadBundledLibrary() }.value
            phase = .ready(library: try bundled.merged(withCustom: custom), history: history, templates: templates,
                           repository: repository)
        } catch is CancellationError {
            return
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// The workout record first, so the session can name it; a session without one would count only in Train.
    private func save(_ draft: TrainPastSessionDraft, repository: AppTrainRepository) async throws {
        let at = now
        var workoutID: UUID?
        if let workoutSession {
            let record = try await workoutSession.logManual(activity: .strength, startedAt: draft.startedAt, endedAt: draft.endedAt)
            workoutID = record.id
        }
        let session = try draft.session(workoutID: workoutID, now: at)
        _ = try await repository.saveSession(session)
    }
}
