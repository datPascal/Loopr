import Foundation
import OnboardingKit
import SwiftUI
import DesignSystem

/// Decides at process start whether RootGate opens the tab shell or the
/// onboarding flow, without waiting for the database.
///
/// The durable onboarding snapshot lives in SQLite, and reading it used to
/// mean opening the whole product repository graph behind an onboarding
/// loading view before the shell could appear. A returning user saw that
/// onboarding-looking screen on every cold launch. The cached flag below is
/// written when onboarding reaches the main shell, read synchronously here,
/// and reconciled with the durable snapshot once the shell has opened its
/// repositories. The database stays the source of truth: if it disagrees (a
/// wiped or restored store), the flag is cleared and onboarding comes back.
nonisolated enum LaunchRootDecision {
    enum Reconciliation: Equatable, Sendable {
        /// The durable snapshot agrees that onboarding finished.
        case keep
        /// The durable snapshot is missing or unfinished; onboarding must run.
        case returnToOnboarding
        /// The snapshot could not be read. Storage failure has its own
        /// surface in the shell, so the root does not change on a read error.
        case undetermined
    }

    /// Whether RootGate should treat onboarding as complete on its first
    /// frame. Fixture launches keep using their declared root; only the
    /// production composition trusts the cached flag.
    static func initialOnboardingCompleted(
        root: AppEnvironment.Root,
        composition: AppEnvironment.Composition,
        cachedOnboardingCompleted: Bool
    ) -> Bool {
        if root == .main { return true }
        return composition == .production && cachedOnboardingCompleted
    }

    static func reconcile(persistedStage: OnboardingStage?) -> Reconciliation {
        persistedStage == .mainShell ? .keep : .returnToOnboarding
    }

    static func reconcile(loading: () async throws -> OnboardingSnapshot?) async -> Reconciliation {
        do {
            return reconcile(persistedStage: try await loading()?.stage)
        } catch {
            return .undetermined
        }
    }
}

/// The cached "onboarding finished" flag. Lives in the standard defaults
/// domain and is listed in `ProductRepositoryKeys.allOwnedDefaultsKeys`, so
/// deleting all Loopr data clears it with everything else.
nonisolated struct LaunchOnboardingFlagStore {
    static let key = "loopr.launch.onboarding-completed.v1"

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isOnboardingCompleted: Bool { defaults.bool(forKey: Self.key) }

    func markOnboardingCompleted() {
        guard !isOnboardingCompleted else { return }
        defaults.set(true, forKey: Self.key)
    }

    func clear() { defaults.removeObject(forKey: Self.key) }
}

/// Runs the reconciliation once the shell's repositories are open. Kept as a
/// modifier so MainTabShell only gains one line.
struct LaunchOnboardingReconciliation: ViewModifier {
    let repositories: ProductRepositoryContainer
    let onReturnToOnboarding: (() -> Void)?

    func body(content: Content) -> some View {
        content.task(id: repositories.storageGeneration) {
            guard let onReturnToOnboarding,
                  let onboarding = repositories.persistent?.onboarding else { return }
            let outcome = await LaunchRootDecision.reconcile { try await onboarding.load() }
            if outcome == .returnToOnboarding { onReturnToOnboarding() }
        }
    }
}

/// What RootGate shows while the production shell waits for Bluetooth launch
/// inspection. It matches the launch screen: the app background and nothing
/// else. A small progress indicator fades in only if the wait passes
/// `revealDelay`, so a normal launch never shows a loading screen at all.
struct LaunchHoldView: View {
    static let revealDelay: Duration = .milliseconds(400)

    @State private var revealed = false

    var body: some View {
        ZStack {
            Color.loopr(.background)
                .ignoresSafeArea()
            if revealed {
                ProgressView()
                    .tint(Color.loopr(.inkSecondary))
                    .transition(.opacity)
                    .accessibilityLabel("Loading")
            }
        }
        .accessibilityIdentifier("main-shell-loading")
        .task {
            do { try await Task.sleep(for: Self.revealDelay) } catch { return }
            withAnimation(.easeIn(duration: 0.25)) { revealed = true }
        }
    }
}
