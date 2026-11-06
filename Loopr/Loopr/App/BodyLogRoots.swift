import BodyKit
import DomainKit
import SwiftUI

// LV-08b step 5: the roots that put the weight and body composition log on screen. The log screen is a Data
// destination (`AppHealthRoute.bodyLog`); the Body screen reads the log's newest values through a modifier.

/// The log screen over the app's stored entries and Apple Health.
@MainActor
struct BodyLogFeatureRoot: View {
    let repositories: ProductRepositoryContainer?
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var viewModel: BodyLogViewModel

    init(environment: AppEnvironment, repositories: ProductRepositoryContainer?) {
        self.repositories = repositories
        let provider = BodyLogProviderFactory.make(environment: environment, repositories: repositories)
        _viewModel = StateObject(wrappedValue: BodyLogViewModel(
            provider: provider, timeZoneIdentifier: environment.timeZoneProvider.timeZone.identifier,
            now: { environment.dateProvider.now() }))
    }

    var body: some View {
        BodyLogScreen(viewModel: viewModel)
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await viewModel.load() } }
            }
            .onReceive(NotificationCenter.default.publisher(for: looprHealthReadPreferencesChanged)) { _ in
                Task { await viewModel.load() }
            }
            .productStorageGate(repositories)
    }
}

/// Gives the Body screen the newest weight, body fat and lean mass across typed entries and Apple Health.
struct BodyLogSummaryModifier: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var loader: BodyLogSummaryLoader

    @MainActor
    init(environment: AppEnvironment, repositories: ProductRepositoryContainer?) {
        _loader = StateObject(wrappedValue: BodyLogSummaryLoader(
            provider: BodyLogProviderFactory.make(environment: environment, repositories: repositories),
            now: { environment.dateProvider.now() }))
    }

    func body(content: Content) -> some View {
        content
            .environment(\.bodyLogSummary, loader.summary)
            .task { await loader.load() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await loader.load() } }
            }
            .onReceive(NotificationCenter.default.publisher(for: looprBodyLogChanged)) { _ in
                Task { await loader.load() }
            }
            .onReceive(NotificationCenter.default.publisher(for: looprHealthReadPreferencesChanged)) { _ in
                Task { await loader.load() }
            }
    }
}
