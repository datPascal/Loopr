import SwiftUI
import TrainKit

/// Loads the exercises the person logged last and hands them to the exercise picker through
/// `exerciseRecentKeys`, so the picker opens with Recent above the full list.
private struct TrainExerciseRecentsLoader: ViewModifier {
    @EnvironmentObject private var repositories: ProductRepositoryContainer
    @State private var keys: [String] = []

    func body(content: Content) -> some View {
        content
            .environment(\.exerciseRecentKeys, keys)
            .task {
                guard let sessions = try? await repositories.makeTrainRepository().recentSessions(limit: 200, status: .completed) else { return }
                keys = ExerciseRecents.keys(from: sessions)
            }
    }
}

extension View {
    /// Supplies `exerciseRecentKeys` to every exercise picker this view presents.
    func loadsExerciseRecents() -> some View { modifier(TrainExerciseRecentsLoader()) }
}
