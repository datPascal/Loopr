import DomainKit
import Foundation
import JournalKit

/// What the Patterns screen and the Today card read. Early patterns never appear here.
nonisolated struct PatternsSnapshot: Equatable, Sendable {
    /// Running tests, then finished ones, newest first.
    var tests: [PatternTest] = []
    /// Strong and clear patterns that are not dismissed, strongest first.
    var found: [FoundPattern] = []
    /// Early patterns that are not dismissed. Never shown as a pattern; the check-in counts the nights they still need
    /// (ICP R2-HAB-01).
    var early: [FoundPattern] = []
    var dismissed: [DismissedPattern] = []
    var review: WeeklyReview?
    var settings = PatternSettings()

    var running: [PatternTest] { tests.filter { $0.state == .running } }
}

nonisolated enum PatternsEngineError: Error, Equatable, LocalizedError, Sendable {
    case notAvailable
    case anotherTestRunning
    /// A protocol experiment is running. Two at once would mix their results (ICP R1-VET-10). Holds its title.
    case experimentRunning(String)
    case notFound

    var errorDescription: String? {
        switch self {
        case .notAvailable: "Loopr cannot test that pattern right now."
        case .anotherTestRunning: "One test runs at a time. Finish or stop the current one first."
        case .experimentRunning(let title): PatternsCopy.experimentBlocks(title)
        case .notFound: "That pattern is gone. Reopen Patterns to see the current list."
        }
    }
}

/// What happened when a test asked for its daily reminder.
nonisolated enum PatternReminderOutcome: Equatable, Sendable {
    case scheduled
    case notAllowed
    case full
    case familyOff
    case failed

    var problem: PatternReminderProblem? {
        switch self {
        case .scheduled: nil
        case .notAllowed: .notAllowed
        case .full: .full
        case .familyOff: .familyOff
        case .failed: .failed
        }
    }
}

/// Posted when deleting data changed what Patterns shows: patterns hidden, then the recount finished. The Patterns
/// screen reloads on it.
let looprPatternsChangedName = Notification.Name("com.loopr.patterns.changed")

nonisolated protocol PatternReminderScheduling: Sendable {
    /// Schedules one reminder that repeats daily until the test ends, through the notification layer. Asks for
    /// notification permission first when `askPermission` is true and it was never asked.
    func schedule(_ test: PatternTest, now: Date, askPermission: Bool) async -> PatternReminderOutcome
    func cancel(testID: UUID) async
    func cancelAll() async
}

extension PatternReminderScheduling {
    func schedule(_ test: PatternTest, now: Date) async -> PatternReminderOutcome {
        await schedule(test, now: now, askPermission: true)
    }
}

nonisolated struct NoPatternReminders: PatternReminderScheduling {
    func schedule(_ test: PatternTest, now: Date, askPermission: Bool) async -> PatternReminderOutcome { .failed }
    func cancel(testID: UUID) async {}
    func cancelAll() async {}
}

/// Runs everything Patterns does with stored data: tests, discovery, dismissals and the weekly review.
/// The statistics run on the device, off the main actor. Nothing here reaches the network.
actor PatternsEngine {
    let store: any PatternStore
    private let provider: any PatternExposureProvider
    private let reminders: any PatternReminderScheduling
    private let policy: PatternPolicy
    private let clock: @Sendable () -> Date
    private let zone: @Sendable () -> TimeZone
    /// Bumped when source data is deleted, so a discovery that started earlier cannot write stale results.
    private var generation = 0
    private var starting = Set<String>()
    /// How long after the last deletion Patterns counts again. Deletions inside the wait share one recount.
    private let recountDelay: Duration
    private var recountTask: Task<Void, Never>?
    /// The title of the protocol experiment running now, or nil. A test does not start beside one (ICP R1-VET-10).
    private let runningExperiment: @Sendable () async -> String?

    init(store: any PatternStore, provider: any PatternExposureProvider, reminders: any PatternReminderScheduling = NoPatternReminders(),
         policy: PatternPolicy = .default, now: @escaping @Sendable () -> Date = { Date() },
         timeZone: @escaping @Sendable () -> TimeZone = { .current }, recountDelay: Duration = .seconds(2),
         runningExperiment: @escaping @Sendable () async -> String? = { nil }) {
        self.store = store; self.provider = provider; self.reminders = reminders; self.policy = policy
        clock = now; zone = timeZone; self.recountDelay = recountDelay; self.runningExperiment = runningExperiment
    }

    // MARK: Snapshot

    func snapshot() async throws -> PatternsSnapshot {
        let now = clock()
        var tests = try await store.tests()
        for index in tests.indices {
            var test = tests[index]
            test.refreshState(at: now)
            if test != tests[index] {
                try await store.saveTest(test)
                await reminders.cancel(testID: test.id)
                tests[index] = test
            }
        }
        let ordered = tests.filter { $0.state != .stopped }.sorted { lhs, rhs in
            if (lhs.state == .running) != (rhs.state == .running) { return lhs.state == .running }
            return (lhs.startDay, lhs.id.uuidString) > (rhs.startDay, rhs.id.uuidString)
        }
        let visible = try await store.visibleFoundPatterns()
        return PatternsSnapshot(
            tests: ordered,
            found: visible.filter { $0.strength.isHeadlineWorthy },
            early: visible.filter { !$0.strength.isHeadlineWorthy },
            // A dismissal whose numbers a deletion made out of date stays in force and stays out of the list.
            dismissed: try await store.dismissedPatterns().filter { !$0.evidenceIsStale },
            review: try await store.reviews().first,
            settings: try await store.settings())
    }

    /// The verdict so far for one test, or nil when the engine could not run.
    func verdict(for test: PatternTest) async -> PatternTestVerdict? {
        try? await PatternTestEvaluator(policy: policy).evaluateInBackground(test, outcomes: provider, now: clock())
    }

    // MARK: Tests

    private func candidate(_ id: String) async -> PatternCandidate? {
        try? await provider.candidates().first { $0.id == id }
    }

    private func metric(_ raw: String?, for candidate: PatternCandidate) -> HabitOutcomeMetricID? {
        guard let raw else { return candidate.targetMetric }
        return HabitOutcomeMetricID(rawValue: raw).flatMap { candidate.targetMetrics.contains($0) ? $0 : nil }
    }

    /// The pattern's title when a test of it can start now.
    func testTitle(candidateID: String, metric raw: String?) async -> String? {
        guard let candidate = await candidate(candidateID), metric(raw, for: candidate) != nil,
              let tests = try? await store.tests() else { return nil }
        let running = tests.filter { $0.state == .running }
        guard running.allSatisfy({ $0.candidateID == candidateID }) else { return nil }
        if running.isEmpty, await runningExperiment() != nil { return nil }
        return candidate.title
    }

    /// Starts a 14-day test today. A second call for the same pattern returns the running test and changes nothing.
    @discardableResult
    func startTest(candidateID: String, metric raw: String?, reminderMinuteOfDay: Int?, at date: Date? = nil) async throws -> PatternTest {
        let now = date ?? clock()
        guard let candidate = await candidate(candidateID), let metric = metric(raw, for: candidate) else { throw PatternsEngineError.notAvailable }
        guard starting.insert(candidateID).inserted else {
            if let existing = try await store.tests().first(where: { $0.state == .running && $0.candidateID == candidateID }) { return existing }
            throw PatternsEngineError.anotherTestRunning
        }
        defer { starting.remove(candidateID) }
        let running = try await store.tests().filter { $0.state == .running }
        if let existing = running.first(where: { $0.candidateID == candidateID }) { return existing }
        guard running.isEmpty else { throw PatternsEngineError.anotherTestRunning }
        if let experiment = await runningExperiment() { throw PatternsEngineError.experimentRunning(experiment) }
        var test = try PatternTest.start(
            candidate: candidate, metric: metric, now: now, timeZone: zone(),
            reminder: reminderMinuteOfDay.map { PatternReminder(enabled: true, minuteOfDay: $0) }, policy: policy)
        if test.reminder != nil {
            let outcome = await reminders.schedule(test, now: now)
            // Nothing is dropped silently: the card says why there is no reminder.
            if let problem = outcome.problem { test.reminder = nil; test.reminderProblem = problem }
        }
        try await store.saveTest(test)
        return test
    }

    /// Schedules the reminder again for running tests whose reminders an earlier build scheduled one request per day.
    /// It never asks for permission. A test whose reminder cannot be set records why.
    func restoreReminders(testIDs: Set<UUID>) async {
        let now = clock()
        for id in testIDs {
            guard var test = try? await store.test(id: id), test.state == .running, test.reminder?.enabled == true else { continue }
            if let problem = await reminders.schedule(test, now: now, askPermission: false).problem {
                test.reminder = nil; test.reminderProblem = problem
                try? await store.saveTest(test)
            }
        }
    }

    /// The person cancelled this test's reminder from Settings. The test goes on without it, and its card says so.
    func reminderWasCancelled(testID: UUID) async {
        guard var test = try? await store.test(id: testID), test.reminder != nil else { return }
        test.reminder = nil; test.reminderProblem = .cancelled
        try? await store.saveTest(test)
    }

    /// Counts today for a running test.
    @discardableResult
    func keepToday(testID: UUID) async throws -> PatternTest {
        let now = clock()
        guard var test = try await store.test(id: testID) else { throw PatternsEngineError.notFound }
        guard let today = test.today(at: now) else { throw PatternTestError.invalidTimeZone }
        try test.keep(day: today, at: now)
        try await store.saveTest(test)
        return test
    }

    func stopTest(id: UUID) async throws {
        guard var test = try await store.test(id: id) else { throw PatternsEngineError.notFound }
        test.stop(at: clock())
        try await store.saveTest(test)
        await reminders.cancel(testID: id)
    }

    // MARK: Found patterns

    func dismiss(key: String) async throws {
        guard let pattern = try await store.foundPatterns().first(where: { $0.key == key }) else { throw PatternsEngineError.notFound }
        try await store.dismiss(pattern, at: clock())
    }

    @discardableResult
    func restore(key: String) async throws -> FoundPattern? { try await store.restore(key: key) }

    func setLookForNewPatterns(_ on: Bool) async throws {
        var settings = try await store.settings()
        guard settings.lookForNewPatterns != on else { return }
        settings.lookForNewPatterns = on
        try await store.saveSettings(settings)
    }

    /// Looks through the last 120 days. Without `force`, it runs only when the setting is on and the last
    /// run is a week old or more. Returns nil when it did not run.
    @discardableResult
    func discover(force: Bool = false) async throws -> PatternDiscoveryResult? {
        try await runDiscovery(requireSetting: !force, respectInterval: !force)
    }

    private func runDiscovery(requireSetting: Bool, respectInterval: Bool) async throws -> PatternDiscoveryResult? {
        let now = clock()
        guard let today = PatternDays.key(at: now, timeZoneID: zone().identifier) else { return nil }
        var settings = try await store.settings()
        if requireSetting { guard settings.lookForNewPatterns else { return nil } }
        if respectInterval, let last = settings.lastDiscoveryDay, let age = PatternDays.distance(from: last, to: today), age < 7 { return nil }
        let started = generation
        let result = try await PatternDiscoveryEngine(policy: policy)
            .discoverInBackground(provider: provider, endingOn: today, calculatedAt: now)
        guard started == generation else { return nil }
        try Task.checkCancellation()
        try await store.replaceFoundPatterns(result.patterns)
        settings = try await store.settings()
        settings.lastDiscoveryDay = today; settings.lastDiscoveryAt = now
        // This look counted what is left, so a recount that was waiting is done.
        settings.needsRecompute = false
        try await store.saveSettings(settings)
        NotificationCenter.default.post(name: looprPatternsChangedName, object: nil)
        return result
    }

    // MARK: Weekly review

    /// The Monday to Sunday week that ended on the latest Sunday up to `now`. On a Sunday that is the week ending today.
    static func reviewWeek(now: Date, timeZone: TimeZone) -> (start: String, end: String)? {
        guard let today = PatternDays.key(at: now, timeZoneID: timeZone.identifier),
              let monday = PatternDays.weekStart(containing: today),
              let sunday = PatternDays.add(6, to: monday),
              let previousSunday = PatternDays.add(-1, to: monday) else { return nil }
        let end = today >= sunday ? sunday : previousSunday
        guard let start = PatternDays.add(-6, to: end) else { return nil }
        return (start, end)
    }

    /// The review for the latest finished week, written from stored data on this device. A week with
    /// nothing to say gets no review.
    func ensureWeeklyReview() async throws -> WeeklyReview? {
        let now = clock()
        guard let week = Self.reviewWeek(now: now, timeZone: zone()) else { return nil }
        if let existing = try await store.review(weekStartDay: week.start) { return existing }
        let tests = try await store.tests()
        var verdicts: [UUID: PatternTestVerdict] = [:]
        for test in tests where test.state == .completed && test.endDay >= week.start && test.endDay <= week.end {
            if let verdict = await verdict(for: test) { verdicts[test.id] = verdict }
        }
        let review = WeeklyReviewBuilder().build(
            weekStartDay: week.start, found: try await store.foundPatterns(),
            dismissedKeys: Set(try await store.dismissedPatterns().map(\.key)),
            tests: tests, verdicts: verdicts, now: now)
        guard !review.patternKeys.isEmpty || !review.testIDs.isEmpty else { return nil }
        try await store.saveReview(review)
        return review
    }

    /// The facts a provider may see for the latest finished week. The caller says which patterns and tests may
    /// leave the phone. Nothing is saved. Nil when nothing allowed is left to say.
    func reviewFacts(patternAllowed: @Sendable (FoundPattern) -> Bool, testAllowed: @Sendable (PatternTest) -> Bool) async throws -> WeeklyReview? {
        let now = clock()
        guard let week = Self.reviewWeek(now: now, timeZone: zone()) else { return nil }
        let review = WeeklyReviewBuilder().build(
            weekStartDay: week.start, found: try await store.foundPatterns().filter(patternAllowed),
            dismissedKeys: Set(try await store.dismissedPatterns().map(\.key)),
            tests: try await store.tests().filter(testAllowed), now: now)
        return review.patternKeys.isEmpty && review.testIDs.isEmpty ? nil : review
    }

    // MARK: Deletion

    /// The person deleted source data: a workout, a habit answer, a day or a meal. Every found pattern that used
    /// it is hidden at once, and Patterns counts again once `recountDelay` has passed with no further deletion.
    /// The deletion's own transaction already hid the patterns, so this repeats the step for any caller without
    /// one. Tests keep running, and dismissals stay in force.
    func sourceDataDidChange(_ change: PatternSourceChange = .anything) async {
        // A look that started before the deletion would write numbers that counted it.
        generation += 1
        try? await store.hideFoundPatterns(affectedBy: change)
        NotificationCenter.default.post(name: looprPatternsChangedName, object: nil)
        recountTask?.cancel()
        let delay = recountDelay
        recountTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.recountAfterDeletion()
        }
    }

    /// Looks again at what is left, when "Look for new patterns" is on. The seven-day wait does not apply: the
    /// person's own deletion asked for it, and the delay keeps it to one look for a run of deletions. A look that
    /// fails leaves `needsRecompute` set, so the next foreground run tries again.
    func recountAfterDeletion() async {
        recountTask = nil
        guard let settings = try? await store.settings() else { return }
        guard settings.lookForNewPatterns else {
            if settings.needsRecompute { var value = settings; value.needsRecompute = false; try? await store.saveSettings(value) }
            return
        }
        _ = try? await runDiscovery(requireSetting: true, respectInterval: false)
    }

    /// The foreground catch-up for a recount that a quit interrupted.
    func recountIfNeeded() async {
        guard let settings = try? await store.settings(), settings.needsRecompute, recountTask == nil else { return }
        await recountAfterDeletion()
    }

    /// Source data was deleted, in part or whole. Found patterns and reviews came from it, so they go, and
    /// discovery runs again at once on what is left when the person has it switched on. Dismissals stay. Tests stay.
    func rebuildAfterSourceDeletion() async {
        generation += 1
        recountTask?.cancel(); recountTask = nil
        try? await store.clearDerived()
        if var settings = try? await store.settings() {
            settings.lastDiscoveryDay = nil; settings.lastDiscoveryAt = nil
            try? await store.saveSettings(settings)
        }
        _ = try? await discover(force: false)
        NotificationCenter.default.post(name: looprPatternsChangedName, object: nil)
    }

    /// Delete all data. The database rows are gone already. Stop reminders and drop anything in flight.
    func resetAfterDeletion() async {
        generation += 1
        recountTask?.cancel(); recountTask = nil
        await reminders.cancelAll()
        try? await store.deleteAll()
    }
}
