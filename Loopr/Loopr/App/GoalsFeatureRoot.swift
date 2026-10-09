import ProfileKit
import SettingsKit
import SwiftUI

/// The one goals editor. Today's goal card and Settings both open it, and it
/// writes only the canonical ProfileKit goals store.
///
/// Today used to push a second editor that knew about steps and strain only,
/// next to this one with all five goals.
@MainActor
struct GoalsFeatureRoot: View {
    let repositories: ProductRepositoryContainer?
    var accessibilityIdentifier = "settings-goals-editor"

    var body: some View {
        if let goals {
            CanonicalGoalsEditorScreen(repository: goals, accessibilityIdentifier: accessibilityIdentifier)
                .productStorageGate(repositories)
        } else {
            ContentUnavailableView {
                Label("Goals unavailable", systemImage: "target")
            } description: {
                Text("Loopr could not open the store that holds your goals. Close Loopr and open it again.")
            }
            .accessibilityIdentifier(accessibilityIdentifier)
        }
    }

    private var goals: (any GoalsRepository)? {
        if let persistent = repositories?.persistent { return persistent.profile }
        if repositories?.isFixtureComposition ?? true { return FixtureGoalsRepository.shared }
        return nil
    }
}

/// Goals for fixture launches: the same targets the Today fixture shows, held
/// in memory for the life of the process.
actor FixtureGoalsRepository: GoalsRepository {
    static let shared = FixtureGoalsRepository()

    private let store = InMemoryProfileRepository()
    private var seeded = false

    func readGoals() async throws -> [Goal] {
        try await seedIfNeeded()
        return try await store.readGoals()
    }

    func saveGoal(type: GoalType, target: Double, unit: String, isEnabled: Bool) async throws -> Goal {
        try await seedIfNeeded()
        return try await store.saveGoal(type: type, target: target, unit: unit, isEnabled: isEnabled)
    }

    func deleteGoals() async throws {
        seeded = true
        try await store.deleteGoals()
    }

    private func seedIfNeeded() async throws {
        guard !seeded else { return }
        seeded = true
        _ = try await store.saveGoal(type: .steps, target: 10_000, unit: "steps", isEnabled: true)
        _ = try await store.saveGoal(type: .strain, target: 10, unit: "strain", isEnabled: true)
    }
}
