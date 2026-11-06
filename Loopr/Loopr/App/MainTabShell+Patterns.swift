import SwiftUI

/// Patterns lives behind one route, `AppTodayRoute.patterns`, pushed on the Today stack.
///
/// W7: the Today "Pattern this week" card opens it with `todayNavigation.path.append(.patterns)`, or by
/// calling `apply(.patterns)`. Show the card only when `LooprPatternsRuntime.isEnabled`. The top pattern and the
/// running test come from `LooprPatternsRuntime.shared.engine?.snapshot()`.
extension MainTabShell {
    @ViewBuilder
    func patternsDestination(repositories: ProductRepositoryContainer) -> some View {
        PatternsFeatureRoot(environment: environment, repositories: repositories)
    }
}
