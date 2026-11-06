import DomainKit
import Foundation
import JournalKit
import NotificationKit
import RoutineKit
import SettingsKit
import StorageKit
#if canImport(UserNotifications)
import UserNotifications
#endif

#if canImport(UserNotifications)
/// The Protocol tab's rule reminders through NotificationKit's "Reminders you set" (DEC-07.1). A reminder exists only
/// for a rule the person turned it on for; an evening rule's reminder quotes the person's rebuttal (DEC-12.18). Which
/// days it fires on is `ProtocolRuleReminderPlanning`'s job.
nonisolated struct ProtocolRuleNotificationReminders: ProtocolRuleReminding {
    func waiting() async -> [RuleKey: Int] {
        await LooprNotificationRuntime.shared.protocolRuleReminderMinutes(calendar: .current)
    }

    func set(_ rule: ProtocolRule) async -> String? {
        Self.message(await ProtocolRuleReminderPlanning.shared.set(rule))
    }

    func remove(_ key: RuleKey) async {
        await ProtocolRuleReminderPlanning.shared.remove(key)
    }

    static func message(_ outcome: UserReminderOutcome) -> String? {
        switch outcome {
        case .set: nil
        case .notAllowed: "Notifications are off for Loopr. Turn them on in the Settings app to get this reminder."
        case .full: "Ten reminders are already waiting. Remove one in Settings, under Reminders you set."
        case .familyOff: "Reminders you set is off in Loopr's settings. Turn it on to get this reminder."
        case .failed: "Loopr could not set this reminder."
        }
    }
}

extension LooprNotificationRuntime {
    /// The rules whose reminder is on, by rule key, as minutes after midnight on `calendar`'s clock. A rule with nothing
    /// waiting this week, such as one whose count is met, is still on. A reminder set before Loopr kept that list is read
    /// from its waiting request.
    func protocolRuleReminderMinutes(calendar: Calendar) async -> [RuleKey: Int] {
        var result: [RuleKey: Int] = [:]
        for request in await userReminders() where ProtocolRuleReminder.isRuleReminder(request) {
            guard let key = ProtocolRuleReminder.ruleKey(from: request.identity.objectID) else { continue }
            result[RuleKey(rawValue: key)] = request.minuteOfDay(calendar: calendar)
        }
        for (object, minute) in await policy.standingReminders() {
            guard let key = ProtocolRuleReminder.ruleKey(from: object) else { continue }
            result[RuleKey(rawValue: key)] = minute
        }
        return result
    }

    /// Puts one rule's reminder on `plan` at the rule's time, with its current words, and keeps it on. Requests that
    /// already match the plan stay as they are, so planning again changes nothing until a day, a time or a word changes.
    /// - Parameter asksPermission: true on the person's save in the rule editor, the only time Loopr asks for
    ///   notifications here. A plan Loopr makes by itself never asks, and writes nothing to the reminder history.
    func applyProtocolRuleReminder(_ rule: ProtocolRule, plan: RuleReminderPlan, calendar: Calendar, now: Date,
                                   asksPermission: Bool) async -> UserReminderOutcome {
        guard let minute = rule.timeOfDayMinutes else { return .failed }
        switch await refreshAuthorization() {
        case .authorized: break
        case .notDetermined:
            guard asksPermission, await requestPermission() == .available else { return .notAllowed }
        case .denied: return .notAllowed
        }
        guard await policy.isEnabled(.userReminders) else { return .familyOff }
        let object = ProtocolRuleReminder.objectID(ruleKey: rule.key.rawValue)
        let pending = await userReminders()
        let outcome = ProtocolRuleReminder.build(ruleKey: rule.key.rawValue, title: rule.displayTitle(), rebuttal: rule.rebuttal,
                                                 isEvening: rule.isEvening, minuteOfDay: minute, schedule: Self.schedule(plan),
                                                 answerable: RuleReminderPlan.takesAnswers(rule), now: now, calendar: calendar,
                                                 pending: pending, standing: Set(await policy.standingReminders().keys))
        switch outcome {
        case .refused(.full): return .full
        case .refused(.invalidTime): return .failed
        case .request, .weekdays, .dated: break
        }
        await policy.setStanding(object, minuteOfDay: minute)
        let waiting = pending.filter { $0.identity.objectID == object }
        if ProtocolRuleReminder.isUnchanged(waiting, planned: outcome.requests, calendar: calendar) { return .set }
        // Every request of the rule goes first, so a change of days leaves no reminder on a day that is now off.
        if !waiting.isEmpty { try? await policy.remove(family: .userReminders, objectID: object) }
        for (index, request) in outcome.requests.enumerated() {
            do {
                switch try await policy.schedule(request, recordsHistory: asksPermission && index == 0) {
                case .scheduled, .deferred, .duplicate: continue
                case .disabled: return .familyOff
                case .denied, .queued: return .notAllowed
                case .limitReached: return .full
                case .quietHours, .expired: return .failed
                }
            } catch { return .failed }
        }
        return .set
    }

    /// The plan in NotificationKit's terms: weekdays as `Calendar` numbers (Sunday is 1), days as dates.
    nonisolated static func schedule(_ plan: RuleReminderPlan) -> ProtocolRuleReminder.Schedule {
        switch plan {
        case .repeating(let days): .repeating(weekdays: Set(days.map { $0.isoNumber % 7 + 1 }))
        case .days(let days): .days(days.map { DateComponents(year: $0.year, month: $0.month, day: $0.day) })
        }
    }

    /// Turns the rule's reminder off: nothing waits and nothing is planned again.
    func cancelProtocolRuleReminder(_ key: RuleKey) async {
        let object = ProtocolRuleReminder.objectID(ruleKey: key.rawValue)
        await policy.setStanding(object, minuteOfDay: nil)
        try? await policy.remove(family: .userReminders, objectID: object)
    }

    /// Takes the rule's reminders off the lock screen and out of Notification Center once the rule has an answer, so a
    /// reminder already answered does not wait to be pressed again (ICP round 4, HAB).
    nonisolated func clearDeliveredProtocolRuleReminders(_ key: RuleKey) async {
        let object = ProtocolRuleReminder.objectID(ruleKey: key.rawValue)
        let center = UNUserNotificationCenter.current()
        let identifiers = await center.deliveredNotifications()
            .filter { ($0.request.content.userInfo[NotificationResponsePayload.objectKey] as? String) == object }
            .map(\.request.identifier)
        if !identifiers.isEmpty { center.removeDeliveredNotifications(withIdentifiers: identifiers) }
    }
}

/// Decides which days each rule reminder fires on and keeps the waiting requests in step (ICP round 4, Q1b and Q5).
/// `RuleReminderPlan` decides; this reads what it needs from the production database and hands the plan to the
/// notification layer. It plans again when the app comes to the front, when it first gets the app's source readings,
/// and after every answer from the deck, the day sheet, Today or a reminder, so a week whose count is met goes quiet
/// and a running test's off night gets no reminder. Steps run one after another, never interleaved. Fixture launches
/// have no production database, so nothing here schedules anything for them.
actor ProtocolRuleReminderPlanning {
    static let shared = ProtocolRuleReminderPlanning()
    typealias Snapshots = @Sendable (DayIdentity, TimeZone, Date) async throws -> RoutineSourceSnapshots

    /// What Food, Fitness, the band and Apple Health hold for a day, once a screen has wired them. Until then, and in a
    /// launch with no screen, only what is stored counts.
    private var snapshots: Snapshots?
    private var tail: Task<Void, Never>?

    /// Hands over the app's live source readings. The first time, the reminders are planned again with them, so a week
    /// a source already filled goes quiet at launch.
    func attach(_ snapshots: @escaping Snapshots) {
        let first = self.snapshots == nil
        self.snapshots = snapshots
        if first { Task { await self.replan() } }
    }

    /// Plans every rule reminder that is on again. A rule that is gone, or lost its time, loses its reminder.
    func replan(now: Date = Date()) async {
        await serially { await self.replanAll(now: now) }
    }

    /// Turns the rule's reminder on, or moves it, on the person's save. May ask for notifications.
    func set(_ rule: ProtocolRule, now: Date = Date()) async -> UserReminderOutcome {
        await serially { await self.setOne(rule, now: now) }
    }

    func remove(_ key: RuleKey) async {
        await serially { await LooprNotificationRuntime.shared.cancelProtocolRuleReminder(key) }
    }

    /// After an answer to `key`, wherever it was given: its delivered reminders clear and every reminder is planned again.
    func answered(_ key: RuleKey, now: Date = Date()) async {
        await LooprNotificationRuntime.shared.clearDeliveredProtocolRuleReminders(key)
        await replan(now: now)
    }

    /// Runs `work` once every earlier step has finished, so two plans never mix their removals and additions.
    private func serially<T: Sendable>(_ work: @escaping @Sendable () async -> T) async -> T {
        let previous = tail
        let task = Task<T, Never> {
            await previous?.value
            return await work()
        }
        tail = Task { _ = await task.value }
        return await task.value
    }

    private func setOne(_ rule: ProtocolRule, now: Date) async -> UserReminderOutcome {
        let planned = await planner()?.plans(for: [rule], now: now)[rule.key]
        return await LooprNotificationRuntime.shared.applyProtocolRuleReminder(rule, plan: planned ?? Self.fallback(rule),
                                                                               calendar: .current, now: now, asksPermission: true)
    }

    private func replanAll(now: Date) async {
        let runtime = LooprNotificationRuntime.shared
        let on = await runtime.protocolRuleReminderMinutes(calendar: .current)
        guard !on.isEmpty, let planner = await planner(), let rules = planner.rules() else { return }
        let byKey = Dictionary(rules.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        for key in on.keys where byKey[key]?.timeOfDayMinutes == nil {
            await runtime.cancelProtocolRuleReminder(key)
        }
        let kept = on.keys.sorted().compactMap { byKey[$0] }.filter { $0.timeOfDayMinutes != nil }
        let plans = await planner.plans(for: kept, now: now)
        for rule in kept {
            _ = await runtime.applyProtocolRuleReminder(rule, plan: plans[rule.key] ?? Self.fallback(rule), calendar: .current,
                                                        now: now, asksPermission: false)
        }
    }

    /// The rule's own repeat, for when nothing else can be read.
    private static func fallback(_ rule: ProtocolRule) -> RuleReminderPlan {
        guard let cadence = rule.cadence, cadence.isDaily else { return .repeating([]) }
        return .repeating(cadence.days)
    }

    /// The production database's stores, opened the way the app opens them. Nil in a fixture launch.
    private func planner() async -> ProtocolRuleReminderPlanner? {
        let target = await MainActor.run { () -> (url: URL, version: String)? in
            let environment = AppEnvironment.make()
            guard environment.composition == .production, let url = environment.storageURL else { return nil }
            return (url, environment.applicationVersion)
        }
        guard let storageURL = target?.url, let version = target?.version else { return nil }
        guard let database = try? await Task.detached(operation: {
            try LooprProductionDatabases.shared.database(at: storageURL, applicationVersion: version)
        }).value else { return nil }
        return ProtocolRuleReminderPlanner(store: RoutineStore(database: database), experiments: ExperimentStore(database: database),
                                           timeZone: .current, snapshots: snapshots ?? { _, _, _ in RoutineSourceSnapshots() })
    }
}

/// Reads one plan per rule: this week's progress, with the sources' readings where the app has them, and the running
/// tests of the protocol.
nonisolated struct ProtocolRuleReminderPlanner: Sendable {
    let store: RoutineStore
    let experiments: ExperimentStore
    let timeZone: TimeZone
    let snapshots: ProtocolRuleReminderPlanning.Snapshots

    /// The newest version's rules. Empty without a protocol, nil when the store cannot be read.
    func rules() -> [ProtocolRule]? {
        do { return try store.activeProtocol()?.latestVersion.rules ?? [] } catch { return nil }
    }

    func plans(for rules: [ProtocolRule], now: Date) async -> [RuleKey: RuleReminderPlan] {
        guard !rules.isEmpty, let active = try? store.activeProtocol() else { return [:] }
        let protocolID = active.routineProtocol.id
        let week = ProtocolWeekCalendar(timeZone: timeZone, locale: .current)
        let today = week.day(now)
        let progress = await ProtocolRuleProgressLoader.progress(store: store, protocolID: protocolID, rules: rules,
                                                                 week: week.week(containing: today), today: today,
                                                                 timeZone: timeZone, now: now, snapshots: snapshots)
        let tests = ((try? experiments.experiments()) ?? []).filter { $0.status == .running && $0.start.protocolID == protocolID }
        return Dictionary(rules.map { rule in
            (rule.key, RuleReminderPlan.plan(for: rule, today: today, progress: progress[rule.key],
                                             tests: tests.filter { $0.start.ruleKey == rule.key }.map(\.schedule)))
        }, uniquingKeysWith: { first, _ in first })
    }
}

/// Answers "Done" and "Skip today" on a rule reminder without opening Loopr (ICP R3-HAB-02). iOS may run this in a
/// launch with no scene, so it opens the product database the way the app does (`LooprProductionDatabases`, which
/// shares one open file per process) and writes through `ProtocolTabLoader`, the deck's own path: a tick or a skip
/// through `RoutineDayEvaluation`, marked as answered from the reminder, with the Journal copy of a habit rule kept in
/// step. The answer is for the day the reminder came on. A rule a source checks, or a running test's off night, takes
/// nothing (ICP round 4, VET and Q1b). Afterwards the rule's delivered reminders clear and the reminders are planned
/// again, and Today and the Protocol tab read the day again when they hear `answered`.
enum ProtocolRuleReminderResponder {
    static let answered = Notification.Name("com.loopr.protocol.rule-answered-from-reminder")

    /// Writes the answer, then posts `answered`. Fixture launches never write: they have no production database.
    static func handle(_ answer: ProtocolRuleReminder.Answer, deliveredAt: Date) async {
        let environment = AppEnvironment.make()
        guard environment.composition == .production, let storageURL = environment.storageURL else { return }
        let version = environment.applicationVersion
        guard let database = try? await Task.detached(operation: {
            try LooprProductionDatabases.shared.database(at: storageURL, applicationVersion: version)
        }).value else { return }
        let zone = TimeZone.current
        let store = RoutineStore(database: database)
        let loader = ProtocolTabLoader(store: store, timeZone: { zone },
                                       snapshots: { _, _, _ in RoutineSourceSnapshots() },
                                       habits: try? SQLiteHabitRepository(database: database), answeredFrom: .reminder)
        let day = ProtocolWeekCalendar(timeZone: zone, locale: .current).day(deliveredAt)
        let key = RuleKey(rawValue: answer.ruleKey)
        do {
            if let active = try store.activeProtocol() {
                let tests = ((try? ExperimentStore(database: database).experiments()) ?? [])
                    .filter { $0.status == .running && $0.start.protocolID == active.routineProtocol.id }
                let outcome = try await ProtocolRuleReminderAnswer.save(
                    choice(answer.action), key: key, day: day, rules: active.latestVersion.rules,
                    offNightTest: ProtocolTabLoader.offNightTest(for: key, on: day, tests: tests), to: loader, now: Date())
                if outcome == .saved {
                    NotificationCenter.default.post(name: answered, object: nil)
                    // The bedtime Live Activity lists the same rules as steps.
                    await BedtimeActivityRuntime.shared.reconcile()
                }
            }
        } catch {
            // Nothing was written. The rule stays open on the deck, where the person can answer it.
        }
        await ProtocolRuleReminderPlanning.shared.answered(key)
    }

    nonisolated static func choice(_ action: ProtocolRuleReminder.Action) -> ProtocolDeckChoice {
        switch action {
        case .done: .yes
        case .skipToday: .skip
        }
    }
}
#endif

#if DEBUG
/// The DEBUG fixture's rule reminders, kept in memory for the launch, so a tour sees the editor's "Remind me" switch
/// and the bell on a row without asking for notification permission (ICP R1-HAB-03). Two start on, at their rules'
/// times: magnesium at 21:30 and screens off at 21:45. Nothing is scheduled.
nonisolated final class ProtocolRuleFixtureReminders: ProtocolRuleReminding, @unchecked Sendable {
    static let shared = ProtocolRuleFixtureReminders()
    private let lock = NSLock()
    private var minutes: [RuleKey: Int] = ["magnesium": 21 * 60 + 30, "screens-off": 21 * 60 + 45]

    func waiting() async -> [RuleKey: Int] { lock.withLock { minutes } }

    func set(_ rule: ProtocolRule) async -> String? {
        guard let minute = rule.timeOfDayMinutes else { return "Give the rule a time to get a reminder." }
        lock.withLock { minutes[rule.key] = minute }
        return nil
    }

    func remove(_ key: RuleKey) async { _ = lock.withLock { minutes.removeValue(forKey: key) } }
}
#endif
