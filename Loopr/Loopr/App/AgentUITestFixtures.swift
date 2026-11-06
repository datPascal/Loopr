#if DEBUG
import AIKit
import FoodKit
import Foundation
import JournalKit
import TrainKit

/// The scripted Ask for UI tests and the visual lane. No Loopr server and no provider are involved:
/// a `CoachAgentTransport` answers from a fixed script, and the tools read a fixed week for Alex in
/// Australia/Perth. Today is Fri 16 Oct 2026, 12:00.
///
/// Launch arguments, all DEBUG only, on a fixture composition:
/// - `--loopr-agent-fixture` opens Ask on this model. The question can be anything. The script reads
///   deep sleep (10 to 16 Oct), the food log and the pattern list, then shows the sleep chart and
///   prepares a 14-day test. The answer comes with a chart, three sources and a confirmation card.
/// - `--loopr-agent-fixture-seed` also saves a finished chat in that shape (mockup 16: deep sleep
///   72, 70, 69, 58, 51, 47, 56 with the three nights after a late dinner highlighted, sources for
///   sleep, food and journal, and a pending test card) and opens it. W7 extends this for the visual lane.
///
/// The script has no network and ignores the question, so a test needs no stub.
@MainActor
enum AgentUITestFixtures {
    static let now = ISO8601DateFormatter().date(from: "2026-10-16T04:00:00Z")!
    static let zone = TimeZone(identifier: "Australia/Perth")!
    static let deepSleepChartID = "metric.deep_sleep.2026-10-10.2026-10-16"
    static let candidateID = "food.lateMeal"
    /// Deep sleep minutes for 10 to 16 Oct, and the nights that followed a dinner after 21:00.
    static let deepSleep: [(day: String, minutes: Double)] = [
        ("2026-10-10", 72), ("2026-10-11", 70), ("2026-10-12", 69), ("2026-10-13", 58),
        ("2026-10-14", 51), ("2026-10-15", 47), ("2026-10-16", 56),
    ]
    static let lateDinnerDays = ["2026-10-13", "2026-10-14", "2026-10-15"]

    static func model(arguments: [String] = ProcessInfo.processInfo.arguments, origin: AskOrigin? = nil) async throws -> CoachChatViewModel {
        let suite = "com.loopr.agent.ui-fixture"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let runtime = LooprAISettingsRuntime(
            defaults: defaults,
            stores: [.openAI: CoachFixtureCredentials(), .anthropic: CoachFixtureCredentials()],
            transport: CoachFixtureTransport(), agentTransport: AgentFixtureTransport())
        try await runtime.configure(provider: .anthropic, model: CoachProvider.anthropic.defaultModel, apiKey: "fixture-not-a-real-key")

        let starter = AgentTestStarterBox()
        starter.set(AgentFixtureTestStarter())
        let writes = AgentFixtureWrites()
        let center = AgentProposalCenter(
            ledger: AIProposalLedger(),
            applier: AgentProposalApplier(writes: writes, reminders: AgentFixtureReminders(), tests: starter, now: { now }, timeZone: { zone }))
        let mode = LooprAgentToolMode(runtime: runtime, source: AgentFixtureSource(), writes: writes, proposals: center, tests: starter,
                                      listsPatterns: true, defaults: defaults, now: { now }, timeZone: { zone })
        let repository = CoachFixtureRepository()
        let model = CoachChatViewModel(repository: repository, context: CoachFixtureContext(), runtime: runtime, origin: origin, agent: mode)
        if arguments.contains("--loopr-agent-fixture-seed"), let configuration = try await runtime.selectedConfiguration() {
            let chat = await seededChat(configuration: configuration, center: center)
            try await repository.save(chat)
            model.requestOpen(chat.id)
        }
        return model
    }

    /// The finished answer from mockup 16, with its attachments saved and its card pending.
    private static func seededChat(configuration: CoachProviderConfiguration, center: AgentProposalCenter) async -> CoachConversation {
        var chat = CoachConversation(configuration: configuration, now: now.addingTimeInterval(-90))
        chat.title = "Why did I sleep worse this week?"
        chat.context = "Synthetic test summary. No personal data."; chat.consentedAt = chat.createdAt
        let reply = CoachChatMessage(role: .assistant, text: seedReply, createdAt: now.addingTimeInterval(-60), attachments: [])
        let proposalID = UUID(uuidString: "00000000-0000-0000-0000-000000000F16")!
        try? await center.create(StoredAIProposal(
            id: proposalID, conversationID: chat.id, proposal: .test(candidateID: candidateID, metric: "deep_sleep", reminderMinuteOfDay: nil),
            messageID: reply.id,
            card: AIProposalCard(title: "Want to test it?", lines: ["Kitchen closed at 20:30 for 14 days, then I compare deep sleep with the last 30 days."],
                                 confirmTitle: "Start the test", doneText: "Test started."),
            createdAt: now.addingTimeInterval(-59)))
        var message = reply
        message.attachments = [.chart(deepSleepChart(highlighted: true)), .sources(seedSources), .proposal(proposalID)]
        chat.messages = [CoachChatMessage(role: .user, text: "Why did I sleep worse this week?", createdAt: now.addingTimeInterval(-90)), message]
        return chat
    }

    static func deepSleepChart(highlighted: Bool) -> AgentChartSnapshot {
        AgentChartSnapshot(id: deepSleepChartID, title: "Deep sleep, minutes", unit: "min", domain: .metrics,
                           points: deepSleep.map { AgentChartPoint(day: $0.day, value: $0.minutes) }, kind: .bars,
                           highlightedDays: highlighted ? lateDinnerDays : [], caption: highlighted ? "Brighter bars had dinner after 21:00" : nil)
    }

    static let seedSources = [
        AgentSource(id: "metrics.deep_sleep.2026-10-03.2026-10-16", domain: .metrics, label: "Sleep", count: 14,
                    range: AgentDayRange(from: "2026-10-03", to: "2026-10-16"), recordIDs: [], link: .sleep(day: "2026-10-16")),
        AgentSource(id: "food.2026-10-10.2026-10-16", domain: .food, label: "Food", count: 5,
                    range: AgentDayRange(from: "2026-10-10", to: "2026-10-16"), recordIDs: [], link: .foodDay(day: "2026-10-15")),
        AgentSource(id: "journal.2026-10-10.2026-10-16", domain: .journalAnswers, label: "Journal", count: 7,
                    range: AgentDayRange(from: "2026-10-10", to: "2026-10-16"), recordIDs: [], link: .habitHistory),
    ]

    private static let seedReply = """
    Three things lined up. You went to bed 48 minutes later on average. Dinner was after 21:00 on 3 of 5 nights. And you had drinks on Friday.

    Deep sleep fell from 71 to 54 minutes a night.
    """
}

/// Reads the script's data. Fixed values, no storage.
nonisolated struct AgentFixtureSource: AgentDataSource {
    func metricSeries(_ key: MetricKey, from: String, to: String) async throws -> [AgentMetricPoint] {
        guard key == .deepSleep else { return [] }
        return AgentUITestFixtures.deepSleep.filter { $0.day >= from && $0.day <= to }.map { AgentMetricPoint(day: $0.day, value: $0.minutes) }
    }
    func foodDays(from: String, to: String) async throws -> [AgentFoodDay] {
        let dinners: [(String, String, Double)] = [("2026-10-12", "19:40", 780), ("2026-10-13", "21:30", 910), ("2026-10-14", "21:45", 860),
                                                   ("2026-10-15", "21:10", 940), ("2026-10-16", "12:15", 620)]
        return dinners.filter { $0.0 >= from && $0.0 <= to }.map { day, time, kcal in
            AgentFoodDay(day: day, meals: [AgentFoodMealRow(id: "meal-\(day)", slot: "dinner", time: time,
                items: [AgentFoodItemRow(name: "Dinner", amount: 1, unit: "serving", energy: kcal, estimated: false)])],
                energy: kcal, energyComplete: true, protein: nil, carbs: nil, fat: nil, waterMillilitres: nil, caffeineMilligrams: nil, alcoholUnits: nil)
        }
    }
    func trainingEntries(from: String, to: String) async throws -> [AgentTrainingEntry] { [] }
    func trainingTemplates() async throws -> [AgentTemplateRow] { [] }
    func journalDays(from: String, to: String) async throws -> [AgentJournalDay] { [] }
    func journalNotes(from: String, to: String) async throws -> [AgentJournalNote] { [] }
    func cycleRows(from: String, to: String) async throws -> [AgentCycleRow] { [] }
    func visiblePatterns() async throws -> [AgentPatternRow] {
        [AgentPatternRow(candidateID: AgentUITestFixtures.candidateID, title: "Late dinner", metric: "deep_sleep", strength: "clear", difference: -17,
                         unit: "min", nightsWith: 9, nightsWithout: 21, windowEnd: "2026-10-15", exposureDomain: .food)]
    }
}

/// The three-step script: read, then show the chart and prepare the test, then answer. It looks only at
/// how many rounds the request already holds, so it keeps no state and ignores the question.
struct AgentFixtureTransport: CoachAgentTransport {
    func turn(_ request: CoachAgentRequest, key: String) async throws -> AgentTurn {
        func call(_ id: String, _ name: String, _ arguments: String) -> AgentToolCall { AgentToolCall(id: id, name: name, arguments: arguments) }
        switch request.rounds.count {
        case 0:
            return .toolCalls([
                call("r1", AgentToolName.getSleep, #"{"metrics":["deep_sleep"],"from":"2026-10-10","to":"2026-10-16"}"#),
                call("r2", AgentToolName.getFood, #"{"from":"2026-10-10","to":"2026-10-16"}"#),
                call("r3", AgentToolName.listPatterns, "{}"),
            ])
        case 1:
            return .toolCalls([
                call("s1", AgentToolName.showChart, #"{"chartId":"\#(AgentUITestFixtures.deepSleepChartID)"}"#),
                call("s2", AgentToolName.proposeTest, #"{"candidateId":"\#(AgentUITestFixtures.candidateID)","metric":"deep_sleep"}"#),
            ])
        default:
            return .final("Deep sleep was shortest on the three nights after a late dinner. I read your sleep, food and patterns for this.\n\nWant to test it? I prepared a 14-day test, and nothing starts until you confirm.")
        }
    }
}

nonisolated struct AgentFixtureTestStarter: AgentTestStarting {
    func title(candidateID: String, metric: String?) async -> String? { candidateID == AgentUITestFixtures.candidateID ? "Kitchen closed at 20:30" : nil }
    func start(candidateID: String, metric: String?, reminderMinuteOfDay: Int?, at date: Date) async throws {}
}

nonisolated struct AgentFixtureReminders: AgentReminderScheduling {
    func schedule(id: UUID, title: String, body: String, minuteOfDay: Int, repeatsDaily: Bool) async throws {}
}

/// Confirmed proposals write nowhere in a fixture run.
nonisolated struct AgentFixtureWrites: AgentWriteStore {
    func mealExists(id: UUID) async throws -> Bool { false }
    func confirmMeal(_ draft: FoodMealDraft, at date: Date) async throws {}
    func habitDefinitions() async throws -> [HabitDefinition] { [] }
    func saveHabitDefinition(_ definition: HabitDefinition) async throws {}
    func template(id: UUID) async throws -> WorkoutTemplate? { nil }
    func saveTemplate(_ template: WorkoutTemplate, at date: Date) async throws {}
    func checkProgramDraft(json: String, defaultStartDay: String) async throws {}
    func saveProgramDraft(json: String, defaultStartDay: String, proposalID: UUID, at date: Date) async throws {}
}
#endif
