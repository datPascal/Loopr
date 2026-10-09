import DesignSystem
import DomainKit
import Combine
import Foundation
import SwiftUI

// MARK: Shell

/// Attaches the shared day selection to the tab shell: puts it in the
/// environment, connects it to storage once storage opens, and asks it to
/// re-resolve when the day could have changed (coming back on screen, a
/// finished sync, a newly derived generation, midnight).
struct LooprDaySelectionDriver: ViewModifier {
    let selection: LooprDaySelection
    let repositories: ProductRepositoryContainer
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .environment(\.looprDaySelection, selection)
            .task(id: repositories.storageGeneration) {
                guard let analytics = repositories.persistent?.analytics else { return }
                selection.attach(AnalyticsDayDataSource(analytics: analytics))
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active: selection.sceneDidBecomeActive()
                case .background: selection.sceneDidEnterBackground()
                default: break
                }
            }
            // A sync that lands the night moves a default selection from
            // yesterday to today. The coalescer in the refresh keeps a
            // backlog offload to one pass at a time.
            .onReceive(NotificationCenter.default.publisher(for: looprHealthHistoryCommitted)
                .debounce(for: .seconds(8), scheduler: RunLoop.main)) { _ in
                guard scenePhase == .active else { return }
                selection.requestRefresh()
            }
            .onReceive(NotificationCenter.default.publisher(for: looprDerivedGenerationUpdated)
                .debounce(for: .seconds(2), scheduler: RunLoop.main)) { _ in
                guard scenePhase == .active else { return }
                selection.requestRefresh()
            }
            .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged).receive(on: RunLoop.main)) { _ in
                if selection.rollOverIfNeeded() { selection.requestRefresh() }
            }
    }
}

// MARK: Feature roots

/// Loads one feature root for the shared day and hands its screen the
/// navigation value.
///
/// - The day's saved generation loads at once; a day that has never been
///   derived waits `derivationDelay` of rest first, so flicking back through
///   ten days derives one day, not ten.
/// - Nothing loads while the launch resolution is still deciding the day.
/// - Without a shell selection (a screen pushed outside the tab shell) the
///   root loads `fallbackDay` exactly as it did before day selection existed.
struct LooprDayScopedLoad: ViewModifier {
    /// How long a not-yet-derived day must stay selected before it is
    /// derived.
    static let derivationDelay: Duration = .milliseconds(350)

    @Environment(\.looprDaySelection) private var selection
    let isEnabled: Bool
    let fallbackDay: DayIdentity
    let swipes: Bool
    let load: @MainActor (DayIdentity) async -> Void

    func body(content: Content) -> some View {
        content
            .environment(\.looprDayNavigation, selection?.navigation)
            .looprDaySwipe(swipes ? selection?.navigation : nil)
            .task(id: LoadKey(day: selection?.day ?? fallbackDay, resolving: selection?.isResolving ?? false)) {
                guard isEnabled else { return }
                guard let selection else {
                    await load(fallbackDay)
                    return
                }
                guard !selection.isResolving else { return }
                let day = selection.day
                if await !selection.isCached(day) {
                    do { try await Task.sleep(for: Self.derivationDelay) } catch { return }
                }
                guard !Task.isCancelled, selection.day == day else { return }
                await load(day)
                guard !Task.isCancelled else { return }
                selection.noteDisplayed(day)
            }
    }

    private struct LoadKey: Hashable {
        let day: DayIdentity
        let resolving: Bool
    }
}

extension View {
    /// Loads this root for the shared day. See `LooprDayScopedLoad`.
    func looprDayScopedLoad(
        enabled: Bool,
        fallbackDay: DayIdentity,
        swipes: Bool = true,
        load: @escaping @MainActor (DayIdentity) async -> Void
    ) -> some View {
        modifier(LooprDayScopedLoad(isEnabled: enabled, fallbackDay: fallbackDay, swipes: swipes, load: load))
    }
}

/// The day a root reloads on a refresh: the shared day, or the fallback
/// outside the shell.
@MainActor
func looprCurrentDay(_ selection: LooprDaySelection?, fallback: DayIdentity) -> DayIdentity {
    selection?.day ?? fallback
}
