import DesignSystem
import SwiftUI
import TrainKit

/// The workout builder, pushed from the Train tab for a template or for a new one.
///
/// It loads the template, the bundled exercise library and the person's custom exercises
/// through `AppTrainRepository`, which keeps SQLite off the main actor. Save writes the template
/// and pops. Back discards, after asking when there are edits.
struct TrainTemplateRoot: View {
    let route: TrainRoute

    @EnvironmentObject private var repositories: ProductRepositoryContainer
    @Environment(\.looprAsk) private var ask
    @Environment(\.dismiss) private var dismiss
    @State private var phase: Phase = .loading

    private enum Phase {
        case loading
        case ready(template: WorkoutTemplate, library: ExerciseLibrary, repository: AppTrainRepository)
        case failed(String)
    }

    var body: some View {
        Group {
            switch route {
            case .libraryPicker:
                ContentUnavailableView("Add exercises from the builder", systemImage: "list.bullet.rectangle",
                    description: Text("Open a workout and choose Add exercise."))
                    .accessibilityIdentifier("train-library-picker-unavailable")
            default:
                content
            }
        }
        .task(id: route) { await load() }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.loopr(.background))
                .accessibilityLabel("Loading the workout")
                .accessibilityIdentifier("template-loading")
        case .failed(let message):
            VStack(spacing: LooprSpacing.cardStack) {
                LooprText(message, style: .body, color: .inkSecondary)
                    .accessibilityIdentifier("template-load-error")
                Button("Try again") { Task { await load() } }
                    .buttonStyle(LooprButtonStyle(accent: .movement))
                    .accessibilityIdentifier("template-retry")
            }
            .padding(LooprSpacing.screenGutter)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.loopr(.background))
        case .ready(let template, let library, let repository):
            TemplateBuilderScreen(
                template: template, library: library,
                save: { @Sendable [repository] template in try await repository.saveTemplate(template, at: Date()) },
                createCustom: { @Sendable [repository] exercise in try await repository.saveCustomExercise(exercise) },
                onDescribe: { ask?.run("Workout builder") },
                onClose: { dismiss() })
                .id(template.id)
        }
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
        guard case .template(let id) = route else { return }
        phase = .loading
        let repository = makeRepository()
        do {
            let template: WorkoutTemplate
            if let id {
                guard let stored = try await repository.template(id: id) else { throw TrainError.missingRecord }
                template = stored
            } else {
                template = WorkoutTemplate(name: "")
            }
            let custom = try await repository.customExercises()
            let bundled = try await Task.detached(priority: .userInitiated) { try Self.loadBundledLibrary() }.value
            phase = .ready(template: template, library: try bundled.merged(withCustom: custom), repository: repository)
        } catch is CancellationError {
            return
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Reads the bundled dataset and the movements Loopr added (`ExerciseLibrary.bundled(in:)`).
    nonisolated static func loadBundledLibrary(bundle: Bundle = .main) throws -> ExerciseLibrary {
        try ExerciseLibrary.bundled(in: bundle)
    }
}
