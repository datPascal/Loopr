import DataKit
import DomainKit
import FoodKit
import RoutineKit
import StorageKit
import SwiftUI

/// Make a report file, wired to what this iPhone stores. The Data root's vault card opens it through
/// `AppHealthRoute.publish`.
struct PublishDashboardRoot: View {
    let environment: AppEnvironment
    @ObservedObject var repositories: ProductRepositoryContainer
    @Environment(\.metricHistoryProvider) private var history

    var body: some View {
        let loader = PublishDataLoader(history: history, stores: PublishDashboardRoot.stores(repositories),
                                       timeZone: environment.timeZoneProvider.timeZone,
                                       now: { [dates = environment.dateProvider] in dates.now() })
        PublishDashboardScreen(timeZone: loader.timeZone, now: loader.now,
                               loadCandidates: { await loader.candidates() },
                               loadSeries: { keys, period in await loader.series(keys: keys, period: period) })
    }

    /// The stores the Food tab, the Protocol tab and the blood test screens read. Production keeps all three on the
    /// products database. A fixture launch hands each tab a scratch store, and the report file reads those same ones,
    /// so it never greys out Food or Protocol while those tabs show data (ICP R3-UPG-7).
    static func stores(_ repositories: ProductRepositoryContainer) -> @Sendable () async -> PublishStores {
        if let database = repositories.persistent?.database {
            let stores = PublishStores(database: database)
            return { stores }
        }
        #if DEBUG
        if repositories.isFixtureComposition {
            let food = repositories.fixtureFoodRepository
            let routine = ProtocolTabFixture.stores(environment: repositories.environment)?.routine
            let labs = LabsServicesProvider.services(for: repositories)?.labs
            return { PublishStores(food: try? await food.readingStore(), routine: routine, labs: labs) }
        }
        #endif
        return { PublishStores() }
    }
}
