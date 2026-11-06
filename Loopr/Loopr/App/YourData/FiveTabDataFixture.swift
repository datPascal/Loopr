#if DEBUG
import DesignSystem
import SwiftUI

/// One real, populated pair of ledgers per fixture launch. Preparing them is
/// test setup, separate from the screen's inventory and export operations.
@MainActor enum FiveTabDataFixture {
    private static var preparation: Task<YourDataStores, Error>?

    static func stores() async throws -> YourDataStores {
        if let preparation { return try await preparation.value }
        let task = Task {
            try await YourDataFileWorker.run { try YourDataModel.fixtureStores() }
        }
        preparation = task
        return try await task.value
    }
}

struct FiveTabFixturePreparation<Content: View>: View {
    let enabled: Bool
    @ViewBuilder let content: () -> Content
    @State private var ready = false
    @State private var failure: String?

    var body: some View {
        if !enabled || ready {
            content()
        } else {
            VStack {
                if let failure {
                    LooprText("Fixture setup failed: " + failure, style: .prose)
                        .accessibilityIdentifier("five-tab-fixture-error")
                } else {
                    StateMessage(.loading)
                        .accessibilityIdentifier("five-tab-fixture-loading")
                }
            }
            .task {
                do {
                    _ = try await FiveTabDataFixture.stores()
                    ready = true
                } catch {
                    failure = error.localizedDescription
                }
            }
        }
    }
}
#endif
