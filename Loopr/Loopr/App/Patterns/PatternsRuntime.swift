import AIKit
import DomainKit
import Foundation
import JournalKit
import NotificationKit
import RoutineKit
#if canImport(UserNotifications)
import UserNotifications
#endif

/// Starts a 14-day test from a confirmed `propose_test`. The agent layer calls it only after a Confirm tap.
nonisolated struct PatternTestStarter: AgentTestStarting {
    let engine: PatternsEngine

    func title(candidateID: String, metric: String?) async -> String? {
        await engine.testTitle(candidateID: candidateID, metric: metric)
    }

    func start(candidateID: String, metric: String?, reminderMinuteOfDay: Int?, at date: Date) async throws {
        do { try await engine.startTest(candidateID: candidateID, metric: metric, reminderMinuteOfDay: reminderMinuteOfDay, at: date) }
        catch let error as PatternsEngineError { throw AgentApplyError(error.localizedDescription) }
    }
}

/// Which pattern facts may leave the phone for a provider. A pattern needs its exposure domain and the
/// health measurements behind its outcome, and both must pass the same gate Ask uses.
nonisolated enum PatternAgentAccess {
    static func allows(_ pattern: FoundPattern, gate: AgentAccessGate) -> Bool {
        gate.isAllowed(.metrics) && gate.isAllowed(AgentPatternRow.domain(of: pattern.predicate))
    }
    static func allows(_ test: PatternTest, gate: AgentAccessGate) -> Bool {
        gate.isAllowed(.metrics) && gate.isAllowed(AgentPatternRow.domain(of: test.predicate))
    }
}

#if canImport(UserNotifications)
/// One reminder for a test, through the notification layer: it repeats every day at the time the person picked and
/// stops when the test ends. It is one of "Reminders you set", so Settings lists it and can cancel it.
nonisolated struct LooprPatternReminderScheduler: PatternReminderScheduling {
    /// The reminder for a test: first fire at the next time of day in the test's zone, repeating daily, ending with the
    /// test's last day. Nil when the test has no reminder, or ends before the next time it would fire.
    static func draft(for test: PatternTest, now: Date) -> UserReminderDraft? {
        guard let reminder = test.reminder, reminder.enabled, let zone = TimeZone(identifier: test.timeZoneID) else { return nil }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        guard let end = PatternDays.endOfDay(test.endDay, timeZoneID: test.timeZoneID),
              let first = calendar.nextDate(after: now, matching: DateComponents(hour: reminder.hour, minute: reminder.minute),
                                            matchingPolicy: .nextTime),
              first < end else { return nil }
        return UserReminderDraft(
            source: .patternsTest, objectID: LooprNotificationRuntime.patternObjectID(test.id),
            title: "Patterns test",
            body: "\(PatternsCopy.title(test)). Open Patterns and mark today if you kept it.",
            minuteOfDay: reminder.minuteOfDay, repeatsDaily: true, firstFire: first, expiresAt: end)
    }

    func schedule(_ test: PatternTest, now: Date, askPermission: Bool) async -> PatternReminderOutcome {
        guard test.reminder?.enabled == true, TimeZone(identifier: test.timeZoneID) != nil else { return .failed }
        // The test ends before the next time it would fire, so there is nothing left to remind.
        guard let draft = Self.draft(for: test, now: now) else { return .scheduled }
        switch await LooprNotificationRuntime.shared.scheduleUserReminder(draft, askPermission: askPermission) {
        case .set: return .scheduled
        case .notAllowed: return .notAllowed
        case .full: return .full
        case .familyOff: return .familyOff
        case .failed: return .failed
        }
    }

    func cancel(testID: UUID) async {
        await LooprNotificationRuntime.shared.cancelUserReminders(
            source: .patternsTest, objectID: LooprNotificationRuntime.patternObjectID(testID))
    }

    func cancelAll() async {
        await LooprNotificationRuntime.shared.cancelUserReminders(source: .patternsTest)
    }
}
#endif

/// The door from a deletion to Patterns. A repository calls `committed` after the transaction that deleted the data
/// and hid the patterns that counted it. Patterns then counts again after a short wait.
nonisolated enum PatternSourceDeletions {
    static func committed(_ change: PatternSourceChange) {
        Task { @MainActor in await LooprPatternsRuntime.shared.sourceDataDidChange(change) }
    }
}

/// Holds the production engine and wires it to the rest of the app: the Ask test starter, the briefing
/// runtime and deletion. Patterns follow `LooprHabitInsightsStage`, like habit insights.
@MainActor
final class LooprPatternsRuntime {
    static let shared = LooprPatternsRuntime()
    private(set) var engine: PatternsEngine?
    private var configuredFor: ObjectIdentifier?
    private var reminderObserver: Task<Void, Never>?

    init() {}

    /// Tests supply an engine on their own store.
    func install(_ engine: PatternsEngine) { self.engine = engine }

    /// Pascal owns the rollout. Release builds keep Patterns off until the stage is set.
    static var isEnabled: Bool { isEnabled(stage: AppHabitFeatureGate.currentStage) }
    static func isEnabled(stage: HabitFeatureStage) -> Bool { stage.exposesEntryPoints }

    @discardableResult
    func configure(_ persistent: PersistentProductRepositories, agent: LooprAgentRuntime = .shared) throws -> PatternsEngine {
        let database = ObjectIdentifier(persistent.database)
        if let engine, configuredFor == database { return engine }
        let store = try SQLitePatternStore(database: persistent.database)
        #if canImport(UserNotifications)
        let reminders: any PatternReminderScheduling = LooprPatternReminderScheduler()
        #else
        let reminders: any PatternReminderScheduling = NoPatternReminders()
        #endif
        let created = PatternsEngine(
            store: store,
            provider: LooprPatternExposureProvider(data: LooprPatternSourceData(persistent: persistent)),
            reminders: reminders,
            // One experiment at a time across the protocol and Patterns, so two results never mix (ICP R1-VET-10).
            runningExperiment: { [database = persistent.database] in (try? ExperimentStore(database: database).running())?.start.title })
        engine = created; configuredFor = database
        agent.testStarter.set(Self.isEnabled ? PatternTestStarter(engine: created) : nil)
        #if canImport(UserNotifications)
        watchReminders(of: created)
        #endif
        return created
    }

    #if canImport(UserNotifications)
    /// Tests that had reminders under the old scheme get one repeating reminder, and a reminder the person cancels
    /// in Settings is noted on its test.
    private func watchReminders(of engine: PatternsEngine) {
        let key = LegacyReminderMigration.patternsToRestoreKey
        let restore = Set((UserDefaults.standard.stringArray(forKey: key) ?? []).compactMap(UUID.init(uuidString:)))
        if !restore.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
            Task { await engine.restoreReminders(testIDs: restore) }
        }
        reminderObserver?.cancel()
        reminderObserver = Task { [weak self] in
            for await note in NotificationCenter.default.notifications(named: looprPatternReminderCancelledName) {
                guard let id = (note.userInfo?["testID"] as? String).flatMap(UUID.init(uuidString:)) else { continue }
                await self?.engine?.reminderWasCancelled(testID: id)
            }
        }
    }
    #endif

    /// Foreground catch-up: look for patterns when the setting is on and a week has passed, then write the
    /// review for the latest finished week. Returns that review.
    @discardableResult
    func refreshIfDue(now: Date = Date()) async -> WeeklyReview? {
        guard Self.isEnabled, let engine else { return nil }
        await engine.recountIfNeeded()
        _ = try? await engine.discover()
        return try? await engine.ensureWeeklyReview()
    }

    /// The review facts a provider may see, from the saved patterns and tests the gate allows.
    func reviewFacts(gate: AgentAccessGate) async -> WeeklyReview? {
        guard Self.isEnabled, let engine else { return nil }
        return try? await engine.reviewFacts(
            patternAllowed: { @Sendable pattern in PatternAgentAccess.allows(pattern, gate: gate) },
            testAllowed: { @Sendable test in PatternAgentAccess.allows(test, gate: gate) })
    }

    /// A source the person deleted in part. The patterns that used it are hidden now, and Patterns counts again
    /// after a short wait. The deleting transaction hid them already (`SQLitePatternStore.hideFoundPatterns`), so
    /// without an engine yet the hidden state and the `needsRecompute` flag are what the next launch finds.
    func sourceDataDidChange(_ change: PatternSourceChange = .anything) async { await engine?.sourceDataDidChange(change) }

    /// After Delete all data.
    func resetAfterDeletion() async {
        await engine?.resetAfterDeletion()
        LooprAgentRuntime.shared.testStarter.set(nil)
        engine = nil; configuredFor = nil
    }
}
