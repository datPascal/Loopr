import DesignSystem
import DomainKit
import SwiftUI
import TodayKit

/// The recovery and strain breakdown screens pushed from Today. They read the
/// same summary and context as Today, for the day the tabs show.
@MainActor
struct TodayBreakdownFeatureRoot: View {
    enum Kind { case recovery, strain }

    let kind: Kind
    let environment: AppEnvironment
    let repositories: ProductRepositoryContainer?
    let route: (TodayKit.TodayRoute) -> Void
    @Environment(\.looprDaySelection) private var daySelection
    @StateObject private var viewModel: TodayViewModel

    init(kind: Kind, environment: AppEnvironment, repositories: ProductRepositoryContainer?,
         route: @escaping (TodayKit.TodayRoute) -> Void) {
        self.kind = kind
        self.environment = environment
        self.repositories = repositories
        self.route = route
        _viewModel = StateObject(wrappedValue: ProductFeatureViewModelFactory.makeToday(
            environment: environment,
            repositories: repositories
        ))
    }

    var body: some View {
        Group {
            switch kind {
            case .recovery: TodayRecoveryBreakdownScreen(viewModel: viewModel, route: route)
            case .strain: TodayStrainBreakdownScreen(viewModel: viewModel, route: route)
            }
        }
        .looprHeaderInNavigationBar()
        .looprDayScopedLoad(enabled: repositories?.storageFailure == nil,
                            fallbackDay: environment.productDay(fixture: TodayFixtures.day),
                            swipes: false) { day in
            await viewModel.load(day: day)
        }
    }
}
