import Combine
import DesignSystem
import SwiftUI

/// Coalesces refresh requests for one visible feature root. A burst of
/// committed history batches posts one notification per batch; without this
/// the visible screen would re-derive once per batch.
@MainActor
final class ProductionRefreshCoordinator: ObservableObject {
    /// The same window Edge's derive scheduler uses.
    nonisolated static let debounceSeconds: TimeInterval = 8

    private let debounce: TimeInterval
    private var pending: Task<Void, Never>?
    private var lastRunAt: Date?

    init(debounce: TimeInterval = ProductionRefreshCoordinator.debounceSeconds) {
        self.debounce = debounce
    }

    deinit { pending?.cancel() }

    /// Runs `refresh` once the debounce window allows. With `immediately`,
    /// it runs now unless a refresh is already pending, which then covers it.
    func request(now: Date = Date(), immediately: Bool = false, refresh: @escaping @MainActor @Sendable () async -> Void) {
        guard pending == nil else { return }
        let delay = immediately ? 0 : (lastRunAt.map { max(0, debounce - now.timeIntervalSince($0)) } ?? 0)
        pending = Task { @MainActor [weak self] in
            if delay > 0 {
                do { try await Task.sleep(for: .seconds(delay)) }
                catch { self?.pending = nil; return }
            }
            guard !Task.isCancelled else { return }
            self?.pending = nil
            self?.lastRunAt = Date()
            await refresh()
        }
    }

}

/// Keeps a feature root current while it is on screen.
///
/// TabView keeps every visited tab alive, so four or more roots can carry this
/// modifier at once. Only the visible one polls and reloads on commits. A
/// hidden root notes that it missed something and refreshes once when it
/// comes back, so switching to it never waits on a reload it skipped.
private struct ProductionRefresh: ViewModifier {
    /// The poll interval while visible.
    static let pollSeconds: TimeInterval = 15

    let environment: AppEnvironment
    let refresh: @MainActor @Sendable () async -> Void
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var coordinator = ProductionRefreshCoordinator()
    @State private var isVisible = false
    @State private var missedUpdate = false
    /// The last time this root was known current: its first appearance or
    /// its latest refresh.
    @State private var currentAt: Date?

    private var isEnabled: Bool {
        environment.composition == .production || DebugLivePerformance.enabled
    }

    func body(content: Content) -> some View {
        content
            .onAppear {
                LooprPerformance.milestone("FirstTabRootAppear")
                LooprPerformance.tabRootDidAppear()
                isVisible = true
                becameVisible()
            }
            .onDisappear { isVisible = false }
            .task(id: PollKey(phase: scenePhase, visible: isVisible)) {
                guard isEnabled, scenePhase == .active, isVisible else { return }
                // Feature roots perform their initial load. Polling the revision
                // also catches background commits and local-midnight rollover.
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(Self.pollSeconds)) }
                    catch { return }
                    guard !Task.isCancelled else { return }
                    currentAt = Date()
                    await refresh()
                }
            }
            // A finished sync should not wait out the poll. The screen the
            // person is looking at reloads as soon as the commit lands.
            .onReceive(NotificationCenter.default.publisher(for: looprHealthHistoryCommitted)
                .receive(on: RunLoop.main)) { _ in
                updateArrived()
            }
            // The screen paints the last finished day at once and a background
            // pass catches it up. This is how the caught-up numbers arrive.
            // It goes through the same coalescer as a commit: during a history
            // offload every feature root on screen hears every pass, and an
            // immediate reload per pass is a full re-render of the tab tree for
            // numbers that have not moved.
            .onReceive(NotificationCenter.default.publisher(for: looprDerivedGenerationUpdated)
                .receive(on: RunLoop.main)) { _ in
                updateArrived()
            }
    }

    private func updateArrived() {
        guard isEnabled, scenePhase == .active else { return }
        guard isVisible else {
            missedUpdate = true
            return
        }
        coordinator.request { await runRefresh() }
    }

    private func becameVisible() {
        guard isEnabled else { return }
        guard let currentAt else {
            // First appearance: the root's own load is already running.
            self.currentAt = Date()
            return
        }
        let pollWasDue = Date().timeIntervalSince(currentAt) >= Self.pollSeconds
        guard missedUpdate || pollWasDue else { return }
        missedUpdate = false
        coordinator.request(immediately: true) { await runRefresh() }
    }

    private func runRefresh() async {
        currentAt = Date()
        await refresh()
    }

    private struct PollKey: Hashable {
        let phase: ScenePhase
        let visible: Bool
    }
}

extension View {
    func productionRefresh(environment: AppEnvironment, refresh: @escaping @MainActor @Sendable () async -> Void) -> some View {
        modifier(ProductionRefresh(environment: environment, refresh: refresh))
    }
}

extension Binding where Value == MainTab {
    /// The tab selection with a `TabSwitch` signpost opened on every change.
    /// The tab root closes it when it appears.
    func signpostingTabSwitch() -> Binding<MainTab> {
        Binding(
            get: { wrappedValue },
            set: { tab in
                if tab != wrappedValue { LooprPerformance.beginTabSwitch(to: tab.rawValue) }
                wrappedValue = tab
            }
        )
    }
}
