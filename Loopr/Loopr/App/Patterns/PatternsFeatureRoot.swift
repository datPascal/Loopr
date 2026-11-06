import AIKit
import DesignSystem
import DomainKit
import RoutineKit
import SwiftUI

/// The destination behind the `.patterns` route. It builds the model for the production database, or for the
/// DEBUG fixture, and shows the Patterns screen. Without the habit insights stage it shows nothing to open.
struct PatternsFeatureRoot: View {
    let environment: AppEnvironment
    @ObservedObject var repositories: ProductRepositoryContainer
    @State private var model: PatternsModel?
    @State private var unavailable = false

    var body: some View {
        Group {
            if let model {
                PatternsScreen(model: model)
            } else {
                ScrollView {
                    LooprCard {
                        LooprText(unavailable ? "Patterns are not available in this build yet." : PatternsCopy.loading,
                                  style: .prose, color: .inkSecondary)
                    }
                    .padding(LooprSpacing.screenGutter)
                    .accessibilityIdentifier(unavailable ? "patterns-unavailable" : "patterns-loading")
                }
                .background(Color.loopr(.background).ignoresSafeArea())
                .navigationTitle(PatternsCopy.title)
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .task(id: repositories.storageGeneration) { await build() }
        // A deletion hid patterns, or the recount after it finished.
        .onReceive(NotificationCenter.default.publisher(for: looprPatternsChangedName)) { _ in
            guard let model else { return }
            Task { await model.load() }
        }
    }

    private func build() async {
        guard LooprPatternsRuntime.isEnabled else { unavailable = true; return }
        if let persistent = repositories.persistent {
            guard let engine = try? LooprPatternsRuntime.shared.configure(persistent),
                  let coach = try? SQLiteCoachConversationRepository(database: persistent.database) else { unavailable = true; return }
            model = PatternsModel(engine: engine, coach: coach, makeConsentModel: { @MainActor in
                let consent = CoachChatViewModel(
                    repository: coach, context: LooprCoachContextBuilder(repositories: persistent), origin: nil,
                    agent: nil, sharingFilter: { @Sendable (sharing: CoachSharing) -> CoachSharing in AgentAccessGate.effective(sharing, defaults: .standard) })
                await consent.load()
                return consent
            }, runningExperiment: { [database = persistent.database, zone = environment.timeZoneProvider.timeZone] in
                let today = PatternsRunningExperiment.day(Date(), timeZone: zone)
                return (try? ExperimentStore(database: database).running()).map { PatternsRunningExperiment($0, today: today) }
            }, rules: { [database = persistent.database] in
                (try? RoutineStore(database: database).activeProtocol())?.latestVersion.rules ?? []
            })
            return
        }
        #if DEBUG
        if environment.composition != .production {
            let parts = await PatternsFixtures.shared()
            let stores = ProtocolTabFixture.stores(environment: environment)
            let experiments = stores?.experiments
            let routine = stores?.routine
            // Tonight's night on the launch's one clock, the night Today's strip and Experiments show.
            let clock = TodayDialFixtureClock.clock(environment: environment)
            let today = PatternsRunningExperiment.day(clock.now, timeZone: clock.calendar.timeZone)
            model = PatternsModel(engine: parts.engine, coach: parts.coach, makeConsentModel: parts.makeConsentModel,
                                  now: { PatternsFixtures.fixedNow },
                                  runningExperiment: { (try? experiments?.running()).map { PatternsRunningExperiment($0, today: today) } },
                                  rules: { (try? routine?.activeProtocol())?.latestVersion.rules ?? [] })
            return
        }
        #endif
        unavailable = true
    }
}
