import DataKit
import Foundation

/// Screens the Data root pushes on its own stack, beside `AppHealthRoute`.
enum DataTabDestination: Hashable, Identifiable {
    /// The real method page behind one pin on the age ruler. It carries the pin, not a value, so the page shows the
    /// ruler's current number when it draws.
    case pin(DataAgePinKind)
    /// The validation plan Loopr Age has to pass, from docs/LOOPR_AGE.md. The Loopr age method page says the same in
    /// three paragraphs and has no stage list, so the plan keeps its own page.
    case looprAgePlan

    var id: String {
        switch self {
        case .pin(let kind): "pin-\(kind.rawValue)"
        case .looprAgePlan: "loopr-age-plan"
        }
    }
}

/// When the Data root reloads its overview: storage reopened, a new day, or a band sync in a new quarter hour. The
/// sync time is bucketed so a sync clock that moves often cannot keep restarting the load; the source row itself
/// redraws from the loaded facts on every sync.
nonisolated struct DataOverviewReloadKey: Hashable, Sendable {
    var storageGeneration: UInt64
    var day: Date
    var syncQuarterHour: Int?
    /// Bumped by a Profile save, so a new birth year reloads the ruler (R2-UPG-2).
    var profileGeneration: Int

    static let bucket: TimeInterval = 15 * 60

    init(storageGeneration: UInt64, day: Date, lastSync: Date?, profileGeneration: Int = 0) {
        self.storageGeneration = storageGeneration
        self.day = day
        self.profileGeneration = profileGeneration
        syncQuarterHour = lastSync.map { Int(($0.timeIntervalSince1970 / Self.bucket).rounded(.down)) }
    }
}

/// The metric history the Data tab reads: the one Today reads, so a day shows the same recovery, sleep, strain and HRV
/// on both tabs. Production hands back the app's history. The populated fixture used to leave Data on the empty app
/// history while Today read the fixture series, so Data said "No records yet" on a day Today showed recovery 79
/// (ICP R1-OPT-2). Both now go through `TodayFixtureHistorySeam`.
enum DataTabHistory {
    static func provider(environment: AppEnvironment, repositories: ProductRepositoryContainer?,
                         fallback: any MetricHistoryProviding,
                         arguments: [String] = ProcessInfo.processInfo.arguments) -> any MetricHistoryProviding {
        #if DEBUG
        // The absent Data fixture has no stored days, so the day tiles and pins have none either: the header's
        // "No data yet" and the cards read one story (ICP R2-LAB-22).
        if environment.composition != .production, DataOverviewFixtures.isAbsentRequested(arguments: arguments) {
            return EmptyMetricHistoryProvider()
        }
        if let fixture = TodayFixtureHistorySeam.history(environment: environment, repositories: repositories) { return fixture }
        #endif
        return fallback
    }
}
