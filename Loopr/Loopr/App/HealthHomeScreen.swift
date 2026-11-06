import DataKit
import DesignSystem
import HealthKitBridge
import ProfileKit
import SettingsKit
import SwiftUI
import TrainKit

/// The Data tab's root (DEC-12.1, LV-08b step 1; rebuilt in the Data ICP rounds, docs/design/2026-11-04-data-tab).
/// Six area tiles lead (Sleep, Recovery, Strain, Stress, Body, Blood tests), each with the latest number against the
/// person's usual and a 30-day line. A new person sees the steps that fill the tab instead. Then the age ruler in a
/// compact card, this year against last, the markers as a star map by body system, and the tools: All metrics, Records,
/// How the numbers work, Your data and Publish a page.
///
/// The ruler draws its empty shape from the first frame and fills in as the loader's stages arrive. The screen keeps
/// the identifiers it had as the Health tab (`health-screen`, `health-explore-*`, `health-header-ask`): each area tile
/// carries its old Explore row's identifier.
struct HealthHomeScreen: View {
    @Environment(\.healthMetricPins) private var pins
    @Environment(\.looprDayNavigation) private var day
    @Environment(\.looprDaySelection) private var selection
    @Environment(\.metricHistoryProvider) private var provider
    @Environment(\.looprBandIndicator) private var band
    @Environment(\.looprBandLink) private var bandLink
    @Environment(\.profileAgeAction) private var profileAge
    @EnvironmentObject private var repositories: ProductRepositoryContainer
    @StateObject private var overview = DataOverviewLoader()
    @State private var destination: DataTabDestination?
    @State private var showsVO2MaxGuide = false
    @State private var entrance = false
    /// Counts Profile saves, so a birth year saved there reloads the ruler.
    @State private var profileGeneration = 0
    let open: (AppHealthRoute) -> Void

    var body: some View {
        LooprTabScaffold(header: .init(title: "Data", accent: .brand,
            dayPhrase: headerPhrase,
            freshness: meta != nil && headerPhrase == meta ? .hidden : .sync(lastSync: day?.lastSyncedAt, now: day?.now),
            control: day.map(LooprHeaderControl.day) ?? .none,
            // The Ask button keeps the identifier it had when this tab was called Health.
            secondaryAction: LooprHeaderAction(symbol: "sparkles", label: "Ask", identifier: "health-header-ask", run: {})),
            glow: .brand, field: .data, identifier: "health-screen") {
            VStack(alignment: .leading, spacing: LooprSpacing.lg) {
                // Data ICP round 1 (docs/design/2026-11-04-data-tab): the root answers "how am I doing" first. One tile
                // per area with the latest number against the person's usual, then the ages, the year, the markers, and
                // the tools. A new person gets the steps that fill the tab instead of empty tiles. The Explore list,
                // Pinned (Today keeps it) and the vault card left the root; the vault is all in Your data.
                if isNewPerson {
                    DataSetupCard(steps: setupSteps)
                } else {
                    DataAreaGrid(labReports: sourceFacts?.labReports ?? 0, labValues: sourceFacts?.labValues ?? 0,
                                 bloodMarkers: DataBloodMarkers(overview.trends?.starMap), open: open)
                }
                if showsAges {
                    VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                        LooprSectionHeader("Your ages", identifier: "data-ages-header")
                        LooprCard {
                            DataAgeSection(ruler: ruler, entrance: entrance, openPin: openPin, compact: true)
                        }
                        // The entrance is decided when the real ruler first appears, not on the loading shape.
                        .background {
                            if !ruler.isLoading {
                                Color.clear.looprEntrance(tab: LooprColorFieldTab.data.rawValue, animates: $entrance,
                                                          duration: DataAgeSection.entranceDuration)
                            }
                        }
                    }
                }
                if hasReadings {
                    if let trends = overview.trends {
                        DataYearSlopesSection(comparison: trends.slopes, openAll: { open(.allMetrics) }, openRow: { row in
                            open(DataRootRouting.slope(row.id))
                        })
                    } else {
                        LooprCard { StateMessage(.loading).padding(LooprSpacing.md) }
                            .accessibilityIdentifier("data-overview-loading")
                    }
                }
                // The star map lives in Blood tests now, with every marker's history one tap away (Data ICP R3).
                VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                  LooprSectionHeader("More", identifier: "data-more-header")
                  LooprCard {
                    VStack(spacing: 0) {
                        explore("All metrics", detail: "Every number Loopr keeps, \(pins?.metrics.count ?? 0) pinned to Today", symbol: "magnifyingglass", accent: .inkSecondary, id: "metrics", destination: .allMetrics)
                        LooprHairline()
                        explore("Records and streaks", detail: "Your bests and how many days in a row", symbol: "trophy.fill", accent: .brand, id: "records", destination: .recordsHome)
                        LooprHairline()
                        explore("How the numbers work", detail: "What goes into each number, and the paper behind it", symbol: "function", accent: .inkSecondary, id: "methods", destination: DataRootRouting.methods)
                        LooprHairline()
                        explore("Your data", detail: meta ?? "Storage, sources, export and backup", symbol: "externaldrive.fill", accent: .brand, id: "your-data", destination: .yourData)
                        LooprHairline()
                        explore("Publish a page", detail: "Pick numbers and save them as a web page", symbol: "doc.richtext", accent: .inkSecondary, id: "publish", destination: DataRootRouting.publish)
                    }
                  }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("data-vault")
            }
            .padding(.horizontal, LooprSpacing.screenGutter)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("data-screen")
        }
        // The entrance flag drops back once the pins have landed, so a view rebuilt later shows its final state.
        .task(id: entrance) {
            guard entrance else { return }
            try? await Task.sleep(for: .seconds(DataAgeSection.entranceDuration + 0.3))
            guard !Task.isCancelled else { return }
            entrance = false
        }
        .task(id: reloadKey) {
            await overview.load(sources: overviewSources, key: reloadKey, now: day?.now ?? Date(), calendar: .current)
        }
        .onReceive(NotificationCenter.default.publisher(for: looprProfileChanged)) { _ in
            profileGeneration += 1
        }
        .sheet(isPresented: $showsVO2MaxGuide) {
            VO2MaxReadingsGuide(progress: ruler.vo2MaxProgress, alsoNeeds: ruler.cardio.absence?.profileNeed)
        }
        .navigationDestination(item: $destination) { destination in
            switch destination {
            case .pin(let kind):
                if case .method(let id, let value) = ruler.opening(for: kind) { MethodRouteScreen(id: id, value: value) }
            case .looprAgePlan:
                DataLooprAgePlanPage()
            }
        }
    }

    // MARK: Overview

    /// Nothing measured and no blood test yet: the root shows the setup steps instead of tiles of "No reading".
    private var isNewPerson: Bool {
        guard overview.trends != nil else { return false }
        return !hasReadings && (sourceFacts?.labReports ?? 0) == 0
    }

    /// The ages card shows once a pin can sit on the ruler, and while the ruler loads.
    private var showsAges: Bool { ruler.isLoading || !ruler.pins.isEmpty }

    private var setupSteps: [DataSetupCard.Step] {
        var steps: [DataSetupCard.Step] = []
        let paired = bandFacts.name != nil
        steps.append(.init(id: "band", title: paired ? "Wear your band tonight" : "Pair your band",
                           detail: "Sleep, recovery and strain start after your first night.",
                           symbol: "sensor.tag.radiowaves.forward", action: { open(DataRootRouting.source(.band)) }))
        steps.append(.init(id: "whoop", title: "Bring your WHOOP history",
                           detail: "Import a WHOOP export and your past nights show here.",
                           symbol: "square.and.arrow.down", action: { open(DataRootRouting.source(.whoopExport)) }))
        steps.append(.init(id: "health", title: "Connect Apple Health", detail: "Adds VO₂max, weight and steps.",
                           symbol: "heart.text.square", action: { open(DataRootRouting.source(.appleHealth)) }))
        if ruler.birthYear == nil, let profileAge {
            steps.append(.init(id: "birth-year", title: "Add your birth year", detail: "Your real age goes on the age ruler.",
                               symbol: "person.crop.circle", action: { profileAge.open() }))
        }
        steps.append(.init(id: "blood", title: "Add a blood test", detail: "A blood test gives you a blood age.",
                           symbol: "drop.fill", action: { open(DataRootRouting.bloodTests) }))
        return steps
    }

    /// True once the year comparison has a row, which needs at least one stored reading. Before the trends load it
    /// stays true, so a person with data never sees the page jump.
    private var hasReadings: Bool {
        guard let trends = overview.trends else { return true }
        return !trends.slopes.rows.isEmpty
    }

    private var reloadKey: DataOverviewReloadKey {
        DataOverviewReloadKey(storageGeneration: repositories.storageGeneration,
                              day: Calendar.current.startOfDay(for: day?.now ?? Date()),
                              lastSync: band?.lastSyncedAt ?? day?.lastSyncedAt,
                              profileGeneration: profileGeneration)
    }

    private var ruler: DataAgeRuler { overview.core?.ruler ?? .loading }

    /// The vault facts once read; nil while reading or when they could not be read.
    private var vaultFacts: DataVaultFacts? { overview.vault ?? nil }

    private var sourceFacts: DataSourceFacts? {
        overview.trends.map { DataOverviewMapping.sources($0.sources, band: bandFacts, vault: vaultFacts) }
    }

    /// The header line: the day when the arrows have moved off today, so they show what they changed; otherwise the
    /// vault line, and the day until that is read.
    private var headerPhrase: String? {
        if let day, !day.isToday { return LooprHeaderMeta.dayPhrase(day) }
        return meta ?? day.map(LooprHeaderMeta.dayPhrase)
    }

    /// "412 days · 7 sources · all on this iPhone", once the vault and the sources are read.
    private var meta: String? {
        guard overview.vault != nil, let sourceFacts else { return nil }
        return DataVaultMeta.line(facts: vaultFacts, sources: sourceFacts)
    }

    /// Production reads the stored data. A fixture launch reads the Data fixture under `--loopr-data-fixture`, and
    /// otherwise only the fixture history and ledgers, so the rest shows its absent states.
    private var overviewSources: DataOverviewSources {
        let historyProvider = self.provider
        let history: @Sendable (MetricKey, Int, Date) async -> [MetricHistoryPoint] = { key, days, end in
            (try? await historyProvider.series(for: key, days: days, endingOn: end)) ?? []
        }
        #if DEBUG
        if repositories.isFixtureComposition {
            let now = day?.now ?? Date()
            if DataOverviewFixtures.isRequested() { return DataOverviewFixtures.sources(now: now, calendar: .current) }
            // Only the populated launch has stored days; the others show an empty vault, not the fixture's 29 days.
            let vault = repositories.environment.composition == .populated ? DataOverviewFixtures.vault : DataOverviewFixtures.emptyVault
            // Birth year, sex and VO₂max from `LooprAgeSource`, the source the Fitness Ages bar reads, so the two rulers
            // agree (R2-OPT-23) and a birth year typed in Profile places Real age (R2-UPG-2).
            let appleHealth: (@Sendable (AppleHealthSourceKind, Date, Date) async -> AppleHealthReadResult)? =
                LooprAgeSource.vo2Max(repositories).map { vo2 in
                    { kind, from, to in kind == .vo2Max ? await vo2(from, to) : .absent(.noSamples) }
                }
            return DataOverviewSources(profile: LooprAgeSource.dataProfile(repositories), appleHealth: appleHealth,
                                       metricHistory: history, vault: vault)
        }
        #endif
        guard let persistent = repositories.persistent else { return DataOverviewSources(metricHistory: history) }
        return .live(persistent, history: historyProvider)
    }

    private var bandFacts: DataBandFacts {
        let lastSync = band?.lastSyncedAt ?? day?.lastSyncedAt
        #if DEBUG
        if repositories.isFixtureComposition, DataOverviewFixtures.isRequested() {
            return DataBandFacts(name: DataOverviewFixtures.band.name, lastSync: lastSync)
        }
        #endif
        guard band?.link != .notPaired else { return DataBandFacts(name: nil, lastSync: nil) }
        let name = bandLink?.bandModelName ?? (band == nil ? nil : "WHOOP band")
        return DataBandFacts(name: name, lastSync: lastSync)
    }

    /// A pin opens its method page with the pin's value. Real age is a birth year, so it opens Profile, blood age
    /// without a usable report opens the blood tests, and Cardio Age without enough VO₂max readings opens how to get them.
    private func openPin(_ kind: DataAgePinKind) {
        switch ruler.opening(for: kind) {
        case .method: destination = .pin(kind)
        case .profile: profileAge?.open()
        case .bloodTests: open(DataRootRouting.bloodTests)
        case .vo2MaxGuide: showsVO2MaxGuide = true
        }
    }

    private func explore(_ title: String, detail: String, symbol: String, accent: LooprColorToken,
                         id: String, destination: AppHealthRoute) -> some View {
        Button { open(destination) } label: {
            LooprRow(title: title, subtitle: detail, symbol: symbol, accent: accent)
        }
        .buttonStyle(.looprPressableRow)
        .accessibilityIdentifier("health-explore-\(id)")
    }
}
