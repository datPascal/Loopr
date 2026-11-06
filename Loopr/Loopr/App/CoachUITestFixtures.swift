#if DEBUG
import AIKit
import Foundation

actor CoachFixtureCredentials: AICredentialStore {
    private var value: Data?
    func write(_ value: Data) { self.value = value }
    func read() -> Data? { value }
    func remove() { value = nil }
}
actor CoachFixtureRepository: CoachConversationRepository {
    private var chats: [UUID: CoachConversation] = [:]
    private var settings = CoachPreferences()
    private let delay: Duration?
    init(delay: Duration? = nil) { self.delay = delay }
    func conversations() async -> [CoachConversation] {
        if let delay { try? await Task.sleep(for: delay) }
        return chats.values.sorted { $0.updatedAt > $1.updatedAt }
    }
    func save(_ conversation: CoachConversation) { chats[conversation.id] = conversation }
    func delete(id: UUID) { chats[id] = nil }
    func preferences() -> CoachPreferences { settings }
    func savePreferences(_ preferences: CoachPreferences) { settings = preferences }
}
/// The chat store of a fixture launch without a database: chats stay until the app quits.
enum CoachLaunchChatStore {
    static let shared = CoachFixtureRepository()
}
struct CoachFixtureContext: LooprCoachContextSource {
    var hasData = true
    func summary(sharing: CoachSharing, at date: Date) async throws -> String {
        try await summaryResult(sharing: sharing, at: date).text
    }
    func summaryResult(sharing: CoachSharing, at date: Date) async throws -> LooprCoachSummary {
        let text = hasData ? """
        Synthetic test summary. No personal data.
        Health measurements shared: \(sharing.metrics ? "Yes" : "No")
        Journal entries shared: \(sharing.journal ? "Yes" : "No")
        Cycle records shared: \(sharing.cycle ? "Yes" : "No")
        Daily measurements for the last 14 calendar days, newest first:
        2026-10-09: sleep 7 h 40 m, recovery estimate 74%, strain 8.2.
        2026-10-08: sleep 6 h 55 m, recovery estimate 61%, strain 11.4.
        HRV 52 ms, resting heart rate 56 bpm. All values are fixtures.
        Averages over available measurements in the last 30 calendar days:
        Recovery %: 68.0, 24 days with data.
        Sleep hours: 7.1, 26 days with data.
        Recent completed workouts within that window:
        2026-10-07: running, 42 minutes, source fixture.
        """ : """
        Synthetic test summary. No personal data.
        Daily measurements for the last 14 calendar days, newest first:
        2026-10-09: no saved measurements.
        2026-10-08: no saved measurements.
        """
        return LooprCoachSummary(text: text, daysWithData: sharing.metrics ? (hasData ? 26 : 0) : nil)
    }
    func saveAdvice(message: CoachChatMessage, at date: Date) async throws -> UUID { message.id }
}
struct CoachFixtureTransport: CoachChatTransport {
    /// What the fake provider does when asked for a reply.
    enum Mode: Equatable {
        case reply
        /// Two chunks, then the connection drops.
        case interrupted
        /// Fails before any text.
        case fail(CoachProviderError)
        /// Fails with a raw URL error, to exercise the real error mapping.
        case url(URLError.Code)
    }
    var mode = Mode.reply
    func stream(_ request: CoachChatRequest, key: String) -> AsyncThrowingStream<CoachStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    switch mode {
                    case .fail(let error): try await Task.sleep(for: .milliseconds(300)); throw error
                    case .url(let code): try await Task.sleep(for: .milliseconds(300)); throw URLError(code)
                    default: break
                    }
                    let chunks = ["Your recent sleep gives you a useful base for today.\n\n", "**Start with an easy warm-up.** If your energy feels normal, a moderate session is reasonable.\n\n", "Keep room for recovery tonight. These fixture measurements are estimates, so how you feel still matters."]
                    for text in mode == .interrupted ? Array(chunks.prefix(2)) : chunks {
                        try await Task.sleep(for: .milliseconds(100))
                        continuation.yield(.text(text))
                    }
                    if mode == .interrupted { try await Task.sleep(for: .milliseconds(100)); throw URLError(.networkConnectionLost) }
                    continuation.yield(.completed); continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    func models(provider: CoachProvider, key: String) async throws -> [String] { provider.suggestedModels }
}
/// Launch arguments, all DEBUG only and read together with `--loopr-coach-fixture`:
/// `-no-provider` no key on the phone. `-failed` the next reply fails with a server error.
/// `-interrupted` the next reply drops after two chunks. `-fail=<offline|invalid-key|rate-limited|server|quota|secure|timeout>`.
/// `-seed` a consented chat with a long Markdown reply plus an older chat. `-consented` an empty chat that is already approved.
/// `-empty-data` the summary has no measurements. `-slow-load` the repository answers after 3 seconds.
/// `-dictation` the microphone button types a fixed sentence and needs no permission.
@MainActor
enum CoachUITestFixtures {
    static func model(arguments: [String] = ProcessInfo.processInfo.arguments, origin: AskOrigin? = nil,
                      repository suppliedRepository: (any CoachConversationRepository)? = nil) async throws -> CoachChatViewModel {
        func has(_ flag: String) -> Bool { arguments.contains("--loopr-coach-fixture-" + flag) }
        func value(_ name: String) -> String? {
            arguments.first { $0.hasPrefix("--loopr-coach-fixture-\(name)=") }.map { String($0.dropFirst("--loopr-coach-fixture-\(name)=".count)) }
        }
        var mode = CoachFixtureTransport.Mode.reply
        if has("interrupted") { mode = .interrupted }
        if has("failed") { mode = .fail(.server) }
        switch value("fail") {
        case "offline": mode = .url(.notConnectedToInternet)
        case "dropped": mode = .url(.networkConnectionLost)
        case "secure": mode = .url(.secureConnectionFailed)
        case "timeout": mode = .url(.timedOut)
        case "invalid-key": mode = .fail(.invalidKey)
        case "rate-limited": mode = .fail(.rateLimited)
        case "server": mode = .fail(.server)
        case "quota": mode = .fail(.quota)
        default: break
        }
        CoachDictation.fixtureTranscript = has("dictation") ? "Why did I sleep worse this week?" : nil
        let suite = "com.loopr.coach.ui-fixture"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let runtime = LooprAISettingsRuntime(defaults: defaults, stores: [.openAI: CoachFixtureCredentials(), .anthropic: CoachFixtureCredentials()], transport: CoachFixtureTransport(mode: mode))
        if !has("no-provider") {
            try await runtime.configure(provider: .openAI, model: CoachProvider.openAI.defaultModel, apiKey: "fixture-not-a-real-key")
        }
        let repository: any CoachConversationRepository = suppliedRepository ?? CoachFixtureRepository(delay: has("slow-load") ? .seconds(3) : nil)
        let context = CoachFixtureContext(hasData: !has("empty-data"))
        // Ask opened from a screen starts a new chat, so the fixture asks for the chat it just saved.
        var openID: UUID?
        if (has("seed") || has("consented")), let configuration = try await runtime.selectedConfiguration() {
            let summary = try await context.summary(sharing: .init(), at: Date())
            func chat(title: String, age: TimeInterval, messages: [CoachChatMessage]) -> CoachConversation {
                var value = CoachConversation(configuration: configuration, now: Date().addingTimeInterval(-age))
                value.title = title; value.messages = messages
                value.context = summary; value.consentedAt = value.createdAt
                return value
            }
            if has("seed") {
                try await repository.save(chat(title: "Why is my HRV low this week?", age: 3 * 86_400, messages: [
                    .init(role: .user, text: "Why is my HRV low this week?"),
                    .init(role: .assistant, text: "Short sleep and a hard session on Tuesday can both pull HRV down for a few days. One week is not a trend."),
                ]))
                let recent = chat(title: "How should I train today?", age: 60, messages: [
                    .init(role: .user, text: "How should I train today?"),
                    .init(role: .assistant, text: seedReply),
                ])
                try await repository.save(recent)
                openID = recent.id
            } else {
                let empty = chat(title: "New chat", age: 60, messages: [])
                try await repository.save(empty)
                openID = empty.id
            }
        }
        let model = CoachChatViewModel(repository: repository, context: context, runtime: runtime, origin: origin)
        if let openID { model.requestOpen(openID) }
        return model
    }
    private static let seedReply = """
    ## Today at a glance
    Your recovery estimate is **74%**, a little above your recent average of 68%.

    - Sleep: 7 h 40 m
      - Deep sleep ran short
    - HRV: 52 ms, close to your baseline
    - Resting heart rate: 56 bpm

    A reasonable plan:
    1. Warm up for 10 minutes.
    2. Keep the main set moderate.
    3. Take a short walk this evening.

    > These are estimates, not a diagnosis. How you feel still matters.

    ```
    easy zone: 128 to 142 bpm
    ```
    """
}
#endif
