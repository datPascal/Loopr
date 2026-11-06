import AIKit
import CycleKit
import DomainKit
import FoodKit
import Foundation
import StorageKit
import Testing
@testable import Loopr

private actor BriefingRepository: CoachConversationRepository {
    var rows: [UUID: CoachConversation] = [:]
    var prefs = CoachPreferences()
    func conversations() -> [CoachConversation] { rows.values.sorted { $0.updatedAt > $1.updatedAt } }
    func save(_ conversation: CoachConversation) { rows[conversation.id] = conversation }
    func delete(id: UUID) { rows[id] = nil }
    func preferences() -> CoachPreferences { prefs }
    func savePreferences(_ preferences: CoachPreferences) { prefs = preferences }
}

private actor BriefingContext: LooprCoachContextSource {
    private(set) var sharings: [CoachSharing] = []
    func summary(sharing: CoachSharing, at date: Date) -> String { summaryResult(sharing: sharing, at: date).text }
    func summaryResult(sharing: CoachSharing, at date: Date) -> LooprCoachSummary {
        sharings.append(sharing)
        return LooprCoachSummary(text: "Briefing summary. notes=\(sharing.journalNotes) cycle=\(sharing.cycle)", daysWithData: 3)
    }
    func saveAdvice(message: CoachChatMessage, at date: Date) -> UUID { message.id }
}

private final class CapturingChatTransport: CoachChatTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [CoachChatRequest] = []
    var requests: [CoachChatRequest] { lock.withLock { seen } }
    func stream(_ request: CoachChatRequest, key: String) -> AsyncThrowingStream<CoachStreamEvent, Error> {
        lock.withLock { seen.append(request) }
        return AsyncThrowingStream { continuation in
            continuation.yield(.text("Take it easy today.")); continuation.yield(.completed); continuation.finish()
        }
    }
    func models(provider: CoachProvider, key: String) async throws -> [String] { [] }
}

/// A morning briefing is approved once and runs for weeks. Your data is read when it runs, so a switch turned off since
/// approval holds back that domain.
@MainActor
@Suite(.serialized)
struct AgentBriefingGateTests {
    private struct Rig {
        let scheduler: CoachBriefingRuntime
        let repository: BriefingRepository
        let context: BriefingContext
        let transport: CapturingChatTransport
        let suite: AgentFixtures.Suite
    }

    private func makeRig(approved: CoachSharing, suite: AgentFixtures.Suite) async throws -> Rig {
        let transport = CapturingChatTransport()
        let runtime = LooprAISettingsRuntime(defaults: suite.defaults, credentials: AgentTestCredentials(), transport: transport)
        try await runtime.configure(provider: .anthropic, model: "claude-haiku-5-5", apiKey: "test-key")
        let repository = BriefingRepository(), context = BriefingContext()
        var preferences = CoachPreferences()
        preferences.morningEnabled = true; preferences.morningHour = 0
        preferences.morningConfiguration = try await runtime.selectedConfiguration()
        preferences.morningConsentAt = AgentFixtures.now; preferences.morningSharing = approved
        await repository.savePreferences(preferences)
        let scheduler = CoachBriefingRuntime(repository: repository, context: context, runtime: runtime, accessDefaults: suite.defaults, notify: { _, _ in })
        return Rig(scheduler: scheduler, repository: repository, context: context, transport: transport, suite: suite)
    }

    @Test func theBriefingSharesOnlyWhatYourDataAllowsWhenItRuns() async throws {
        let suite = AgentFixtures.Suite(); suite.setOnly([.metrics, .food, .training, .journalAnswers])   // notes and cycle off
        let rig = try await makeRig(approved: CoachSharing(metrics: true, journal: true, cycle: true), suite: suite)
        await rig.scheduler.runIfDue(now: AgentFixtures.now)

        let asked = try #require(await rig.context.sharings.first)
        #expect(asked.metrics && asked.journalAnswers)
        #expect(!asked.journalNotes && !asked.cycle, "approved earlier, off now: not shared")
        let chat = try #require(await rig.repository.conversations().first)
        #expect(chat.isBriefing && !chat.sharing.journalNotes && !chat.sharing.cycle)
        #expect(chat.context == "Briefing summary. notes=false cycle=false")
        let sent = try #require(rig.transport.requests.first)
        #expect(sent.context == chat.context)
        #expect(!sent.context.contains("notes=true"))
        #expect(sent.recording.purpose == .briefing && sent.recording.conversationID == chat.id)
        // What the person approved is not rewritten. Turning the switch back on restores it.
        #expect(await rig.repository.preferences().morningSharing.cycle == true)
    }

    @Test func aSwitchTurnedOffAfterTheFirstBriefingHoldsBackTheNextOne() async throws {
        let suite = AgentFixtures.Suite(); suite.setOnly(Set(AgentDataDomain.allCases))
        let rig = try await makeRig(approved: CoachSharing(metrics: true, journal: true, cycle: true), suite: suite)
        await rig.scheduler.runIfDue(now: AgentFixtures.now)
        #expect(await rig.context.sharings.first?.cycle == true && rig.transport.requests.first?.context.contains("cycle=true") == true)

        suite.set(.cycle, false)
        await rig.scheduler.runIfDue(now: AgentFixtures.now.addingTimeInterval(86_400))
        let sharings = await rig.context.sharings
        #expect(sharings.count == 2 && sharings[1].cycle == false && sharings[1].journalNotes)
        #expect(rig.transport.requests.last?.context.contains("cycle=false") == true)
    }

    @Test func withEverythingOnTheBriefingIsUnchanged() async throws {
        let suite = AgentFixtures.Suite(); suite.setOnly(Set(AgentDataDomain.allCases))
        let approved = CoachSharing(metrics: true, journal: false, cycle: false)
        let rig = try await makeRig(approved: approved, suite: suite)
        await rig.scheduler.runIfDue(now: AgentFixtures.now)
        #expect(await rig.context.sharings.first == approved)
        #expect(await rig.repository.conversations().first?.sharing == approved)
    }

    // MARK: The real summary builder

    private func makeBuilder(_ suite: AgentFixtures.Suite) throws -> (LooprCoachContextBuilder, PersistentProductRepositories, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-briefing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Loopr"), withIntermediateDirectories: true)
        let environment = AppEnvironment(composition: .production, root: .main, storageURL: root.appendingPathComponent("Loopr.sqlite"),
            applicationVersion: "agent-gate", dateProvider: SystemDateProvider(), calendarProvider: SystemCalendarProvider(),
            timeZoneProvider: SystemTimeZoneProvider(), uuidProvider: SystemUUIDProvider(), scheduler: SystemScheduler())
        let repositories = try PersistentProductRepositories(environment: environment, defaults: suite.defaults)
        return (LooprCoachContextBuilder(repositories: repositories, accessDefaults: suite.defaults), repositories, root)
    }

    @Test func theSummaryNeverHoldsADomainThatIsOffEvenWhenAskedFor() async throws {
        let suite = AgentFixtures.Suite(); suite.setOnly([.metrics, .food, .training, .journalAnswers])
        let (builder, repositories, root) = try makeBuilder(suite); defer { try? FileManager.default.removeItem(at: root) }
        let day = LooprCoachContextBuilder.dayString(Date())
        _ = try await repositories.journal.create(day: day, behaviors: ["Stretched"], tags: ["calm"], note: "Alex wrote a private note about the week.", now: Date())
        try await repositories.cycle.optIn()
        _ = try await repositories.cycle.log(CycleEntryFixture.entry(day: day))

        let asked = CoachSharing(metrics: true, journal: true, cycle: true)
        let blocked = try await builder.summaryResult(sharing: asked, at: Date()).text
        #expect(!blocked.contains("private note"), "notes are off in Your data")
        #expect(!blocked.contains("Cycle records explicitly shared"), "cycle is off in Your data")
        #expect(blocked.contains("behaviors Stretched") && blocked.contains("tags calm"), "answers are on")

        suite.set(.journalNotes, true); suite.set(.cycle, true)
        let open = try await builder.summaryResult(sharing: asked, at: Date()).text
        #expect(open.contains("private note") && open.contains("Cycle records explicitly shared"))

        suite.set(.journalAnswers, false)
        let notesOnly = try await builder.summaryResult(sharing: asked, at: Date()).text
        #expect(notesOnly.contains("note: Alex wrote a private note") && !notesOnly.contains("behaviors Stretched") && !notesOnly.contains("tags calm"))
    }

    @Test func workoutsFollowTheTrainingSwitchAndGoalsFollowMetrics() async throws {
        let suite = AgentFixtures.Suite(); suite.setOnly(Set(AgentDataDomain.allCases))
        let (builder, _, root) = try makeBuilder(suite); defer { try? FileManager.default.removeItem(at: root) }
        let both = try await builder.summaryResult(sharing: .init(), at: Date()).text
        #expect(both.contains("Recent completed workouts within that window:"))
        #expect(both.contains("Daily measurements for the last 14 calendar days"))

        suite.set(.training, false)
        let noTraining = try await builder.summaryResult(sharing: .init(), at: Date()).text
        #expect(!noTraining.contains("Recent completed workouts"))
        #expect(noTraining.contains("Daily measurements for the last 14 calendar days"))

        suite.set(.training, true); suite.set(.metrics, false)
        let noMetrics = try await builder.summaryResult(sharing: .init(), at: Date()).text
        #expect(noMetrics.contains("Health metrics were not shared.") && !noMetrics.contains("Daily measurements"))
        #expect(noMetrics.contains("Recent completed workouts within that window:"))
    }

    // MARK: Production data source

    @Test func theProductionSourceReadsTheStoresTheToolsNeed() async throws {
        let suite = AgentFixtures.Suite(); suite.setOnly(Set(AgentDataDomain.allCases))
        let (_, repositories, root) = try makeBuilder(suite); defer { try? FileManager.default.removeItem(at: root) }
        let source = LooprAgentDataSource(persistent: repositories, history: EmptyMetricHistoryProvider(), timeZone: AgentFixtures.zone)
        _ = try await repositories.journal.create(day: "2026-10-15", behaviors: ["Stretched"], tags: ["calm"], note: "Quiet evening.", now: AgentFixtures.now)
        let meal = FoodMealDraft(slot: .dinner, occurredAt: AgentFixtures.now.addingTimeInterval(-86_400), timeZoneIdentifier: "Australia/Perth",
            items: [FoodItemFixture.item(name: "Pasta", energy: 820)])
        try repositories.food.confirm(meal, at: AgentFixtures.now)

        let food = try await source.foodDays(from: "2026-10-10", to: "2026-10-16")
        #expect(food.count == 1 && food[0].day == "2026-10-15" && food[0].energy == 820 && food[0].meals[0].items[0].name == "Pasta")
        let notes = try await source.journalNotes(from: "2026-10-10", to: "2026-10-16")
        #expect(notes.map(\.text) == ["Quiet evening."])
        let days = try await source.journalDays(from: "2026-10-10", to: "2026-10-16")
        #expect(days.first?.behaviors == ["Stretched"] && days.first?.tags == ["calm"])
        #expect(try await source.metricSeries(.rmssd, from: "2026-10-10", to: "2026-10-16").isEmpty)
        #expect(try await source.trainingEntries(from: "2026-10-10", to: "2026-10-16").isEmpty)
        #expect(try await source.visiblePatterns().isEmpty)
    }

    /// Ask reads a day the way the Food screen shows it: drinks count toward macros, caffeine from food and drinks adds
    /// up, and the targets in effect that day come along.
    @Test func theProductionSourceTotalsADayLikeTheFoodScreenAndCarriesItsTargets() async throws {
        let suite = AgentFixtures.Suite(); suite.setOnly(Set(AgentDataDomain.allCases))
        let (_, repositories, root) = try makeBuilder(suite); defer { try? FileManager.default.removeItem(at: root) }
        let source = LooprAgentDataSource(persistent: repositories, history: EmptyMetricHistoryProvider(), timeZone: AgentFixtures.zone)
        let yesterday = AgentFixtures.now.addingTimeInterval(-86_400)
        try repositories.food.confirmTarget(FoodTargetSettings(goal: .build, baseEnergy: 2600, protein: 160, carbs: 300, fat: 80,
                                                                waterMillilitres: 2500, confirmedAt: yesterday.addingTimeInterval(-86_400)))
        let chocolate = FoodItem(name: "Dark chocolate", amount: 1, unit: .serving,
            nutrients: FoodNutrients([.energy: 200, .protein: 3, .caffeine: 40, .fibre: 4, .sugar: 10, .salt: 0.1]),
            provenance: [FoodProvenance(source: .typed, recordedAt: AgentFixtures.now)])
        try repositories.food.confirm(FoodMealDraft(slot: .snack, occurredAt: yesterday, timeZoneIdentifier: "Australia/Perth", items: [chocolate]),
                                      at: AgentFixtures.now)
        try repositories.food.confirmDrink(FoodDrink(kind: .caffeine, name: "Protein latte", occurredAt: yesterday.addingTimeInterval(600),
            timeZoneIdentifier: "Australia/Perth", caffeineMilligrams: 120, energy: 180, additionalNutrients: FoodNutrients([.protein: 25]),
            confirmedAt: AgentFixtures.now))

        let day = try #require(try await source.foodDays(from: "2026-10-15", to: "2026-10-15").first)
        #expect(day.energy == 380 && day.energyComplete)
        #expect(day.protein == 28, "the latte's protein counts, as it does on the Food screen")
        #expect(day.caffeineMilligrams == 160, "caffeine from food and drinks adds up")
        #expect(day.fibre == 4 && day.sugar == 10 && day.salt == 0.1)
        #expect(!day.completed)
        let targets = try #require(day.targets)
        #expect(targets.goal == "build" && targets.energy == 2600 && targets.protein == 160 && targets.carbs == 300 && targets.fat == 80)
        #expect(targets.waterMillilitres == 2500 && !targets.reason.isEmpty)
    }
}

/// CoachSharing grew from three flags to six. Chats and preferences saved before that keep meaning what they meant.
struct CoachSharingCompatibilityTests {
    @Test func aChatSavedWithTheOldFlagsDecodesToTheSameChoices() throws {
        let sharing = try JSONDecoder().decode(CoachSharing.self, from: Data(#"{"metrics":true,"journal":true,"cycle":false}"#.utf8))
        #expect(sharing.metrics && sharing.journalAnswers && sharing.journalNotes && sharing.journal && !sharing.cycle)
        #expect(!sharing.food, "old chats never shared food")
        #expect(sharing.training, "workouts used to travel with health measurements")
    }

    @Test func oldFlagsOffStayOffAndTrainingFollowsMetrics() throws {
        let sharing = try JSONDecoder().decode(CoachSharing.self, from: Data(#"{"metrics":false,"journal":false,"cycle":true}"#.utf8))
        #expect(!sharing.metrics && !sharing.training && !sharing.journalAnswers && !sharing.journalNotes && sharing.cycle)
        let empty = try JSONDecoder().decode(CoachSharing.self, from: Data("{}".utf8))
        #expect(empty.metrics && empty.training && !empty.food && !empty.journal && !empty.cycle)
    }

    @Test func theNewFlagsRoundTrip() throws {
        let sharing = CoachSharing(metrics: true, journal: false, cycle: true, food: false, training: true, journalAnswers: true, journalNotes: false)
        let again = try JSONDecoder().decode(CoachSharing.self, from: JSONEncoder().encode(sharing))
        #expect(again == sharing)
        #expect(!again.journal, "the old single flag reads true only when answers and notes are both shared")
        var both = again; both.journal = true
        #expect(both.journalAnswers && both.journalNotes && both.journal)
        both.journal = false
        #expect(!both.journalAnswers && !both.journalNotes)
    }

    @Test func preferencesAndConversationsWithTheOldShapeStillDecode() throws {
        let old = #"{"instructions":"","morningEnabled":true,"morningHour":7,"morningSharing":{"metrics":true,"journal":true,"cycle":true}}"#
        let preferences = try JSONDecoder().decode(CoachPreferences.self, from: Data(old.utf8))
        #expect(preferences.morningSharing.journalAnswers && preferences.morningSharing.journalNotes && preferences.morningSharing.cycle)
        #expect(!preferences.morningSharing.food)
    }

    @Test func aNewChatSharesMeasurementsFoodAndTrainingAndKeepsPrivateThingsOff() {
        let sharing = CoachSharing()
        #expect(sharing.metrics && sharing.food && sharing.training)
        #expect(!sharing.journalAnswers && !sharing.journalNotes && !sharing.cycle)
        #expect(sharing == CoachSharing(metrics: true, journal: false, cycle: false))
    }
}
