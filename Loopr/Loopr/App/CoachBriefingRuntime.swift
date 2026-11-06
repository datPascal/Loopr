import AIKit
import BackgroundTasks
import Foundation
import JournalKit
import NotificationKit

@MainActor
final class CoachBriefingRuntime {
    static let shared = CoachBriefingRuntime()
    nonisolated static let taskIdentifier = "com.loopr.coach.morning"
    private var repository: (any CoachConversationRepository)?
    private var context: (any LooprCoachContextSource)?
    private let providerRuntime: LooprAISettingsRuntime
    private let notify: @Sendable (UUID, String) async throws -> Void
    private var operation: Task<Void, Never>?
    private var generation = UUID()
    /// Where Your data keeps its switches. A briefing shares only what they allow when it runs, whatever was approved earlier.
    private let accessDefaults: UserDefaults?
    /// Writes the weekly review's facts. The review is also a briefing, so it shares this runtime's gate and consent.
    private let patterns: LooprPatternsRuntime

    init(repository: (any CoachConversationRepository)? = nil, context: (any LooprCoachContextSource)? = nil,
         runtime: LooprAISettingsRuntime = .shared, accessDefaults: UserDefaults? = .standard,
         patterns: LooprPatternsRuntime? = nil,
         notify: @escaping @Sendable (UUID, String) async throws -> Void = { id, day in
             _ = await LooprNotificationRuntime.shared.refreshAuthorization()
             try await LooprNotificationRuntime.shared.events.briefingReady(id: id.uuidString, day: day)
         }) {
        self.repository = repository; self.context = context; self.providerRuntime = runtime; self.notify = notify
        self.accessDefaults = accessDefaults
        self.patterns = patterns ?? .shared
    }

    func configure(_ repositories: PersistentProductRepositories) throws {
        repository = try SQLiteCoachConversationRepository(database: repositories.database)
        context = LooprCoachContextBuilder(repositories: repositories, accessDefaults: accessDefaults)
        // The request log and the Ask tools attach here, once the product database is open.
        _ = try? LooprAgentRuntime.shared.configure(repositories)
        // Patterns attach after the agent runtime, because they hand it the starter for `propose_test`.
        _ = try? patterns.configure(repositories)
    }
    func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.taskIdentifier, using: .main) { task in
            Task { @MainActor in
                guard let task = task as? BGAppRefreshTask else { task.setTaskCompleted(success: false); return }
                let work = Task { @MainActor in
                    do {
                        if self.repository == nil {
                            let environment = AppEnvironment.make()
                            guard environment.composition == .production else { task.setTaskCompleted(success: false); return }
                            try self.configure(PersistentProductRepositories(environment: environment))
                        }
                        await self.runIfDue()
                        await self.schedule()
                        task.setTaskCompleted(success: !Task.isCancelled)
                    } catch { task.setTaskCompleted(success: false) }
                }
                task.expirationHandler = {
                    work.cancel()
                    Task { @MainActor in await self.cancel() }
                }
            }
        }
    }
    func schedule() async {
        guard let repository else { return }
        do {
            let prefs = try await repository.preferences()
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskIdentifier)
            guard prefs.morningEnabled, prefs.morningConsentAt != nil else { return }
            let now = Date()
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .current
            let date = calendar.nextDate(after: now, matching: DateComponents(hour: prefs.morningHour), matchingPolicy: .nextTime)!
            let request = BGAppRefreshTaskRequest(identifier: Self.taskIdentifier)
            request.earliestBeginDate = date
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Foreground catch-up remains available when iOS declines a background slot.
        }
    }
    func cancel() async {
        let id = UUID(); generation = id
        let task = operation
        task?.cancel()
        await task?.value
        guard generation == id else { return }
        operation = nil
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskIdentifier)
    }
    func runIfDue(now: Date = Date()) async {
        guard operation == nil, let repository, let context else { return }
        let id = UUID(); generation = id
        let task = Task { @MainActor in
            do {
                try Task.checkCancellation()
                var prefs = try await repository.preferences()
                let day = LooprCoachContextBuilder.dayString(now)
                let hour = Calendar.current.component(.hour, from: now)
                guard prefs.morningEnabled, prefs.morningConsentAt != nil, hour >= prefs.morningHour,
                      prefs.lastAttemptDay != day, let config = prefs.morningConfiguration else { return }
                guard try await providerRuntime.configurations().contains(config) else {
                    prefs.morningEnabled = false
                    prefs.lastBriefingError = "Provider settings changed. Review morning briefing consent to enable it again."
                    try await repository.savePreferences(prefs); return
                }
                // Keys are unavailable until the first unlock after a restart. Keep foreground catch-up eligible.
                guard await providerRuntime.credentialAvailable(config) else { return }
                // Your data is read now, not when the briefing was approved.
                let sharing = accessDefaults.map { AgentAccessGate.effective(prefs.morningSharing, defaults: $0) } ?? prefs.morningSharing
                let summary = try await context.summary(sharing: sharing, at: now)
                try Task.checkCancellation()
                let current = try await repository.preferences()
                guard generation == id, current.morningEnabled, current.morningConfiguration == config,
                      current.morningConsentAt == prefs.morningConsentAt, current.morningSharing == prefs.morningSharing else { return }
                prefs = current
                prefs.lastAttemptDay = day; prefs.lastBriefingError = nil
                try await repository.savePreferences(prefs)
                try Task.checkCancellation()
                var chat = CoachConversation(configuration: config, instructions: prefs.instructions, now: now)
                chat.title = "Morning briefing · \(day)"; chat.isBriefing = true
                chat.context = summary; chat.sharing = sharing; chat.consentedAt = prefs.morningConsentAt
                chat.messages = [.init(role: .user, text: "Give me my morning briefing. Explain what my recent sleep, recovery, and training suggest for today. Mention missing or uncertain data, and suggest a practical plan.")]
                var text = ""; var completed = false
                var request = chat.request
                request.recording = AIRequestContext(purpose: .briefing, conversationID: chat.id)
                for try await event in try await providerRuntime.stream(request) {
                    try Task.checkCancellation()
                    switch event { case .text(let value): text += value; case .completed: completed = true }
                }
                let latest = try await repository.preferences()
                guard generation == id, latest.morningEnabled, latest.morningConfiguration == config,
                      latest.morningConsentAt == prefs.morningConsentAt, completed, !text.isEmpty else { return }
                try Task.checkCancellation()
                chat.messages.append(.init(role: .assistant, text: text)); chat.updatedAt = Date()
                try await repository.save(chat)
                try Task.checkCancellation()
                var finished = latest; finished.lastBriefingDay = day; finished.lastBriefingError = nil
                try await repository.savePreferences(finished)
                try Task.checkCancellation()
                try await notify(chat.id, day)
            } catch {
                guard !Task.isCancelled, generation == id, var prefs = try? await repository.preferences() else { return }
                prefs.lastBriefingError = CoachProviderError.normalize(error).localizedDescription
                try? await repository.savePreferences(prefs)
            }
        }
        operation = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        if generation == id { operation = nil }
        await runWeeklyReviewIfDue(now: now)
    }

    /// The weekly review. Patterns and the review text are written on this iPhone every time. A provider writes
    /// the wording only with briefing consent and a key, and sees only what Your data allows.
    func runWeeklyReviewIfDue(now: Date = Date()) async {
        guard LooprPatternsRuntime.isEnabled, let repository, let context else { return }
        guard let review = await patterns.refreshIfDue(now: now),
              var prefs = try? await repository.preferences(), prefs.lastWeeklyReviewWeek != review.weekStartDay else { return }
        guard prefs.morningEnabled, prefs.morningConsentAt != nil, let config = prefs.morningConfiguration,
              (try? await providerRuntime.configurations().contains(config)) == true,
              await providerRuntime.credentialAvailable(config) else { return }
        let sharing = accessDefaults.map { AgentAccessGate.effective(prefs.morningSharing, defaults: $0) } ?? prefs.morningSharing
        // One attempt for each week, so a failed request does not repeat on every launch.
        prefs.lastWeeklyReviewWeek = review.weekStartDay
        guard (try? await repository.savePreferences(prefs)) != nil else { return }
        let gate = AgentAccessGate(consent: sharing, defaults: accessDefaults)
        guard let facts = await patterns.reviewFacts(gate: gate),
              let summary = try? await context.summary(sharing: sharing, at: now) else { return }
        var chat = CoachConversation(configuration: config, instructions: prefs.instructions, now: now)
        chat.kind = .weeklyReview
        chat.title = "Weekly review · \(PatternsCopy.reviewDate(facts))"
        chat.sharing = sharing; chat.consentedAt = prefs.morningConsentAt
        chat.context = summary + "\n\nPattern facts for the week \(facts.weekStartDay) to \(facts.weekEndDay), written on this iPhone:\n" + facts.text
        chat.messages = [.init(role: .user, text: "Write my weekly review in two short paragraphs from the summary and pattern facts. Say what differed between my nights. Never say what caused a difference. Keep every number as written.")]
        var request = chat.request
        request.recording = AIRequestContext(purpose: .weeklyReview, conversationID: chat.id)
        do {
            var text = "", completed = false
            for try await event in try await providerRuntime.stream(request) {
                try Task.checkCancellation()
                switch event { case .text(let value): text += value; case .completed: completed = true }
            }
            guard completed, !text.isEmpty else { return }
            chat.messages.append(.init(role: .assistant, text: text)); chat.updatedAt = Date()
            try await repository.save(chat)
        } catch {
            // The local review is already saved. The wording from a provider is optional.
        }
    }
}
