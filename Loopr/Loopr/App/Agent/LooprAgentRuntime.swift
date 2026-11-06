import AIKit
import Foundation
import JournalKit

/// What one answer returns to the chat.
nonisolated struct CoachAgentOutput: Equatable, Sendable {
    let text: String
    let artifacts: AgentTurnArtifacts
}

/// Tool mode for the chat view model. The model runs the tool loop through this, and reaches proposals
/// through `proposals`. Nothing else in the chat knows about tools.
nonisolated protocol CoachAgentRunning: Sendable {
    var proposals: AgentProposalCenter { get }
    /// `sharing` with every domain Your data has turned off turned off too. Read at call time.
    func effectiveSharing(_ sharing: CoachSharing) -> CoachSharing
    /// `conversation.messages` must end with the person's new question and hold no empty reply.
    func run(conversation: CoachConversation, assistantMessageID: UUID, origin: AskOrigin?) async throws -> CoachAgentOutput
}

nonisolated final class AgentTestStarterBox: AgentTestStarting, @unchecked Sendable {
    private let lock = NSLock()
    private var inner: (any AgentTestStarting)?
    var isSet: Bool { lock.withLock { inner != nil } }
    func set(_ starter: (any AgentTestStarting)?) { lock.withLock { inner = starter } }
    func title(candidateID: String, metric: String?) async -> String? {
        guard let inner = lock.withLock({ inner }) else { return nil }
        return await inner.title(candidateID: candidateID, metric: metric)
    }
    func start(candidateID: String, metric: String?, reminderMinuteOfDay: Int?, at date: Date) async throws {
        guard let inner = lock.withLock({ inner }) else { throw AgentApplyError("Tests are not available right now.") }
        try await inner.start(candidateID: candidateID, metric: metric, reminderMinuteOfDay: reminderMinuteOfDay, at: date)
    }
}

/// Runs one question through the model with the tools Your data allows.
/// `UserDefaults` is safe to use from any thread, so the struct is `@unchecked Sendable`.
nonisolated struct LooprAgentToolMode: CoachAgentRunning, @unchecked Sendable {
    let runtime: LooprAISettingsRuntime
    let source: any AgentDataSource
    let writes: any AgentWriteStore
    let tests: AgentTestStarterBox
    let listsPatterns: Bool
    let proposals: AgentProposalCenter
    /// Lets the reminder card warn about quiet hours and refused notifications.
    let reminders: (any AgentReminderScheduling)?
    let defaults: UserDefaults?
    let now: @Sendable () -> Date
    let timeZone: @Sendable () -> TimeZone

    init(runtime: LooprAISettingsRuntime = .shared, source: any AgentDataSource, writes: any AgentWriteStore,
         proposals: AgentProposalCenter, tests: AgentTestStarterBox = AgentTestStarterBox(), listsPatterns: Bool = false,
         reminders: (any AgentReminderScheduling)? = nil, defaults: UserDefaults? = .standard, now: @escaping @Sendable () -> Date = { Date() },
         timeZone: @escaping @Sendable () -> TimeZone = { .current }) {
        self.runtime = runtime; self.source = source; self.writes = writes; self.proposals = proposals; self.tests = tests
        self.listsPatterns = listsPatterns; self.reminders = reminders; self.defaults = defaults; self.now = now; self.timeZone = timeZone
    }

    func effectiveSharing(_ sharing: CoachSharing) -> CoachSharing { AgentAccessGate.effective(sharing, defaults: defaults) }

    func run(conversation: CoachConversation, assistantMessageID: UUID, origin: AskOrigin?) async throws -> CoachAgentOutput {
        let gate = AgentAccessGate(consent: conversation.sharing, defaults: defaults)
        let date = now(), zone = timeZone()
        let capabilities = AgentToolCapabilities(listsPatterns: listsPatterns, startsTests: tests.isSet, schedulesReminders: true)
        let tools = AgentToolRegistry.specs(allowed: gate.allowedDomains, capabilities: capabilities)
        let session = AgentToolSession()
        let today = AgentDays.string(date, in: zone)
        // Ask opened from a past day reads that day. Opened on today it keeps ending today.
        let selectedDay = origin.flatMap { $0.isPastDay && AgentDays.isValid($0.day) && $0.day < today ? $0.day : nil }
        let executor = AgentToolExecutor(
            readers: AgentReaders(gate: gate, source: source), proposals: proposals,
            maker: AgentProposalMaker(writes: writes, tests: tests.isSet ? tests : nil, provider: conversation.configuration.provider,
                                      model: conversation.configuration.model, now: date, timeZone: zone,
                                      reminders: reminders),
            session: session, conversationID: conversation.id, messageID: assistantMessageID, now: date, timeZone: zone,
            selectedDay: selectedDay)
        let context = gate.instructionNote(today: today, timeZone: zone, selectedDay: selectedDay)
            + (conversation.context.isEmpty ? "" : "\n" + conversation.context)
        let request = CoachAgentRequest(
            configuration: conversation.configuration, instructions: conversation.instructions, context: context,
            messages: conversation.messages, tools: tools,
            recording: AIRequestContext(purpose: .toolRound, conversationID: conversation.id, origin: origin.map { "\($0.screen), \($0.day)" }))
        let result = try await runtime.runAgent(request) { call in await executor.execute(call) }
        return CoachAgentOutput(text: result.text, artifacts: await session.artifacts)
    }
}

/// Builds the pieces once the product database is open, and holds the late-bound ones.
/// `configure` is safe to call again: it attaches the same log and keeps one proposal ledger.
nonisolated final class LooprAgentRuntime: @unchecked Sendable {
    static let shared = LooprAgentRuntime()
    private let lock = NSLock()
    private var mode: LooprAgentToolMode?
    private var log: (any AgentRequestLogStore)?
    private var configuredFor: ObjectIdentifier?
    /// W6 sets a starter so `propose_test` is offered and carried out. Nil keeps the tool off.
    let testStarter = AgentTestStarterBox()

    var requestLog: (any AgentRequestLogStore)? { lock.lock(); defer { lock.unlock() }; return log }
    var toolMode: LooprAgentToolMode? { lock.lock(); defer { lock.unlock() }; return mode }

    @discardableResult
    func configure(_ persistent: PersistentProductRepositories, runtime: LooprAISettingsRuntime = .shared) throws -> LooprAgentToolMode {
        let database = ObjectIdentifier(persistent.database)
        lock.lock()
        let existing: LooprAgentToolMode? = configuredFor == database ? mode : nil
        lock.unlock()
        if let existing { return existing }
        let newLog = try SQLiteAgentRequestLog(database: persistent.database)
        try? newLog.prune(now: Date())
        let writes = LooprAgentWriteStore(persistent: persistent)
        let patternStore = try? SQLitePatternStore(database: persistent.database)
        let reminders = LooprAgentReminderScheduler()
        let applier = AgentProposalApplier(writes: writes, reminders: reminders, tests: testStarter)
        let persistence = try StorageDocumentProposalPersistence(database: persistent.database)
        let center = AgentProposalCenter(ledger: AIProposalLedger(persistence: persistence), applier: applier)
        let created = LooprAgentToolMode(runtime: runtime, source: LooprAgentDataSource(persistent: persistent, patternStore: patternStore),
                                         writes: writes, proposals: center, tests: testStarter, listsPatterns: patternStore != nil,
                                         reminders: reminders)
        AgentRequestLogHub.shared.attach(newLog)
        lock.lock()
        log = newLog; mode = created; configuredFor = database
        lock.unlock()
        return created
    }

    /// After Delete all data: forget the proposals in memory and empty the log. The database rows are already gone.
    func resetAfterDeletion() async {
        let (currentMode, currentLog) = snapshot()
        await currentMode?.proposals.deleteAll()
        try? currentLog?.clear()
    }

    private func snapshot() -> (LooprAgentToolMode?, (any AgentRequestLogStore)?) {
        lock.lock(); defer { lock.unlock() }
        return (mode, log)
    }
}
