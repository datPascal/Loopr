import DesignSystem
import SwiftUI
import TrainKit

/// Loads finished sessions and shows the exercise list, one exercise when the route names it, or this week's hard
/// sets per muscle group for `.muscleVolume`.
struct TrainExerciseHistoryRoot: View {
    let route: TrainRoute
    @EnvironmentObject private var repositories: ProductRepositoryContainer
    @State private var history: ExerciseHistory?
    /// Keys that name one lift two ways, mapped to the key history keeps, so a link by either key opens it.
    @State private var canonicalKeys: [String: String] = [:]
    @State private var muscleVolume: MuscleVolumeWeek?
    @State private var failure: String?
    @State private var selected: String?

    var body: some View {
        Group {
            if case .exercise(let key) = route {
                if let exercise = history?.exercise(key: canonicalKeys[key] ?? key) {
                    ExerciseDetailScreen(exercise: exercise)
                } else if history != nil {
                    ContentUnavailableView("No sets logged for this exercise", systemImage: "dumbbell")
                        .accessibilityIdentifier("exercise-detail-missing")
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else if case .muscleVolume = route {
                MuscleVolumeScreen(week: muscleVolume, failure: failure, calendar: repositories.trainProgramClock.calendar)
            } else {
                ExerciseListScreen(history: history, failure: failure) { selected = $0 }
                    .navigationDestination(item: $selected) { key in
                        if let exercise = history?.exercise(key: key) { ExerciseDetailScreen(exercise: exercise) }
                    }
            }
        }
        .task { await load() }
    }

    private func load() async {
        do {
            let repository = repositories.makeTrainRepository()
            let sessions = try await repository.recentSessions(limit: 5_000, status: .completed)
            if case .muscleVolume = route {
                let clock = repositories.trainProgramClock
                let custom = try await repository.customExercises()
                muscleVolume = try await Task.detached(priority: .userInitiated) {
                    let library = try TrainTemplateRoot.loadBundledLibrary().merged(withCustom: custom)
                    guard let week = ISOWeek(containing: clock.now, calendar: clock.calendar) else { throw TrainError.invalidRecord }
                    return MuscleVolumeWeek(sessions: sessions, week: week, definition: library.definition(forKey:))
                }.value
                return
            }
            let built = await Task.detached(priority: .userInitiated) {
                (ExerciseHistory(mergingAliasesIn: sessions), ExerciseHistoryMerge.canonicalKeys(in: sessions))
            }.value
            canonicalKeys = built.1
            history = built.0
        } catch is CancellationError {
        } catch {
            failure = error.localizedDescription
        }
    }
}
