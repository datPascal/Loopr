import AIKit
import DomainKit
import Foundation
import JournalKit
import NotificationKit
import StorageKit
import Testing
@testable import Loopr

private typealias F = PatternsFixtures4b

/// DEC-07 line 1. Reminders set from Ask and from a Patterns test go through the notification layer: one family, a
/// list in Settings, quiet-hours and permission handling the person can see, and a text check before anything
/// reaches the lock screen.
@Suite(.serialized)
struct UserReminderTests {
    private let suite = AgentFixtures.Suite()
    private var gate: AgentAccessGate { AgentAccessGate(consent: AgentFixtures.everything, defaults: suite.defaults) }

    // MARK: Lock-screen text

    @Test(arguments: [
        "Wind down", "Screens off at 20:15", "Be in bed by 22:00", "Stretch after dinner", "Take your vitamins",
        "Sleep at 22:30", "Heart rate zone talk at 8 pm", "Log your day", "Read 20 pages"
    ])
    func everydayWordsPass(_ text: String) {
        #expect(AgentReminderText.healthReading(in: text) == nil, "\(text)")
    }

    @Test(arguments: [
        "Your resting heart rate is 58 bpm", "HRV 42", "HRV: 42", "recovery score 71", "Slept 7.5 h", "7h of sleep", "Walk 8,000 steps",
        "Burn 500 kcal", "Weigh 82 kg", "SpO2 97%", "45 ms overnight", "Stress level 3", "Resting heart rate was 51",
        "Sleep 8", "Stretch for 10 min", "42 HRV", "Weight: 80.5"
    ])
    func healthReadingsAreCaught(_ text: String) {
        #expect(AgentReminderText.healthReading(in: text) != nil, "\(text)")
    }

    @Test func aReminderWithAReadingInItsTitleOrBodyIsRefusedAndTheModelIsToldWhy() async throws {
        let harness = try ProposalHarness.make(); defer { harness.cleanup() }
        let cases: [[String: Any]] = [
            ["title": "HRV 42 today", "time": "20:15"],
            ["title": "Wind down", "body": "Your resting heart rate was 58 bpm.", "time": "20:15"],
            ["title": "Sleep", "body": "You slept 6.5 h last night.", "time": "08:00"]
        ]
        for arguments in cases {
            let outcome = await harness.executor(gate: gate).execute(AgentFixtures.call(AgentToolName.proposeReminder, arguments))
            #expect(outcome.isError && !outcome.denied, "\(arguments)")
            #expect(outcome.content.contains("lock screen") && outcome.content.contains("bpm, ms, %, kg, kcal, h or min"), "\(outcome.content)")
        }
        #expect(await harness.center.ledger.proposals(conversationID: UUID()).isEmpty)
        #expect(harness.reminders.scheduled.isEmpty)
    }

    @Test func theApplierRefusesAStoredReminderWithAReadingToo() async throws {
        let reminders = SpyReminders()
        let applier = AgentProposalApplier(writes: SpyWriteStore(), reminders: reminders)
        await #expect(throws: AgentApplyError.self) {
            try await applier.apply(.reminder(title: "Recovery 71", body: "", minuteOfDay: 480, repeatsDaily: false), id: UUID())
        }
        #expect(reminders.scheduled.isEmpty)
    }

    // MARK: The card

    @Test func theReminderCardWarnsWhenTheTimeFallsInsideQuietHours() async throws {
        let harness = try ProposalHarness.make(); defer { harness.cleanup() }
        harness.reminders.quietMinutes = 22 * 60..<24 * 60
        let late = try await harness.maker().make(tool: AgentToolName.proposeReminder, args: ["title": "Stretch", "time": "23:30"])
        #expect(late.card.lines.last == AgentProposalCopy.quietHoursLine)
        let day = try await harness.maker().make(tool: AgentToolName.proposeReminder, args: ["title": "Stretch", "time": "09:00"])
        #expect(!day.card.lines.contains(AgentProposalCopy.quietHoursLine))
        #expect(day.card.lines.count == 2)
    }

    @Test func theReminderCardSaysWhenNotificationsAreRefused() async throws {
        let harness = try ProposalHarness.make(); defer { harness.cleanup() }
        harness.reminders.refused = true
        let made = try await harness.maker().make(tool: AgentToolName.proposeReminder, args: ["title": "Stretch", "time": "09:00"])
        #expect(made.card.lines.last == AgentProposalCopy.reminderNotificationsOffLine)
    }

    @Test func theTestCardWarnsAboutQuietHoursAndRefusedNotifications() async throws {
        let harness = try ProposalHarness.make(); defer { harness.cleanup() }
        harness.reminders.quietMinutes = 22 * 60..<24 * 60
        let quiet = try await harness.maker().make(tool: AgentToolName.proposeTest, args: ["candidateId": "food.lateMeal", "metric": "sleepScore", "reminderTime": "22:30"])
        #expect(quiet.card.lines.contains(AgentProposalCopy.quietHoursLine))
        harness.reminders.refused = true
        let refused = try await harness.maker().make(tool: AgentToolName.proposeTest, args: ["candidateId": "food.lateMeal", "metric": "sleepScore", "reminderTime": "20:00"])
        #expect(refused.card.lines.contains(AgentProposalCopy.testNotificationsOffLine))
        let none = try await harness.maker().make(tool: AgentToolName.proposeTest, args: ["candidateId": "food.lateMeal", "metric": "sleepScore"])
        #expect(!none.card.lines.contains(AgentProposalCopy.testNotificationsOffLine), "no reminder was asked for")
    }

    // MARK: Apply failures reach the card

    private struct RefusingReminders: AgentReminderScheduling {
        let error: AgentApplyError
        func schedule(id: UUID, title: String, body: String, minuteOfDay: Int, repeatsDaily: Bool) async throws { throw error }
    }

    @Test(arguments: [AgentProposalCopy.notificationsOffText, AgentProposalCopy.reminderLimitText, AgentProposalCopy.reminderFamilyOffText])
    func aRefusedReminderLeavesTheCardFailedWithTheReasonAndConfirmableAgain(_ reason: String) async throws {
        let (database, root) = try AgentFixtures.temporaryDatabase(); defer { try? FileManager.default.removeItem(at: root) }
        let applier = AgentProposalApplier(writes: SpyWriteStore(), reminders: RefusingReminders(error: AgentApplyError(reason)))
        let center = AgentProposalCenter(ledger: AIProposalLedger(persistence: try StorageDocumentProposalPersistence(database: database)), applier: applier)
        let id = UUID()
        try await center.create(StoredAIProposal(id: id, conversationID: UUID(),
                                                 proposal: .reminder(title: "Stretch", body: "", minuteOfDay: 540, repeatsDaily: true), createdAt: AgentFixtures.now))
        let result = await center.confirm(id: id, at: AgentFixtures.now)
        #expect(!result.applied && result.failure == reason)
        #expect(result.proposal?.state == .failed, "nothing is dropped silently, and Try again stays available")
    }

    @Test func theCopyIsPlainAndKeepsTheLimitInOnePlace() {
        let lines = [AgentProposalCopy.notificationsOffText, AgentProposalCopy.reminderLimitText, AgentProposalCopy.reminderFamilyOffText,
                     AgentProposalCopy.quietHoursLine, AgentProposalCopy.reminderNotificationsOffLine, AgentProposalCopy.testNotificationsOffLine,
                     UserReminderCopy.toggleSubtitle, UserReminderCopy.empty, UserReminderCopy.historyEmpty]
            + [ReminderHistoryEntry.Outcome.set, .alreadySet, .familyOff, .notAllowed, .full, .waitingForPermission, .failed].map(UserReminderCopy.outcome)
            + [PatternReminderProblem.notAllowed, .full, .familyOff, .failed, .cancelled].map(PatternsCopy.reminderProblem)
        for line in lines {
            #expect(!line.contains("\u{2014}") && !line.contains("\u{2013}") && !line.contains("!") && !line.contains(";"), "\(line)")
        }
        #expect(AgentProposalCopy.reminderLimitText.contains("\(NotificationFamily.userReminderLimit)"))
        #expect(NotificationFamily.userReminderLimit == 10)
    }

    // MARK: Settings rows

    @Test func aListRowReadsTimeRepeatAndSource() {
        let fire = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 20, minute: 15))!
        let ask = UserReminderRequestFactory.request(source: .ask, objectID: "ask.1", day: "recurring", fireDate: fire, title: "Wind down", detail: "", repeats: .daily)
        let test = UserReminderRequestFactory.request(source: .patternsTest, objectID: "patterns.1", day: "recurring", fireDate: fire, title: "Patterns test", detail: "", repeats: .daily)
        let once = UserReminderRequestFactory.request(source: .ask, objectID: "ask.2", day: "2026-10-20", fireDate: fire, title: "Call", detail: "")
        let clock = LooprClockFormatForTests.text(minuteOfDay: 20 * 60 + 15)
        #expect(UserReminderCopy.detail(ask) == "\(clock), Every day, Ask")
        #expect(UserReminderCopy.detail(test) == "\(clock), Every day", "the title already names the source")
        #expect(UserReminderCopy.detail(once) == "\(clock), Once, Ask")
    }

    // MARK: Patterns

    @Test func aRefusedTestReminderIsNotDroppedSilently() async throws {
        for (outcome, expected): (PatternReminderOutcome, PatternReminderProblem) in [(.notAllowed, .notAllowed), (.full, .full), (.familyOff, .familyOff), (.failed, .failed)] {
            let reminders = SpyPatternReminders(); reminders.allow = false; reminders.refusal = outcome
            let engine = F.engine(data: F.lateDinnerData(), reminders: reminders)
            let test = try await engine.startTest(candidateID: "training", metric: nil, reminderMinuteOfDay: 20 * 60)
            #expect(test.state == .running && test.reminder == nil && test.reminderProblem == expected)
            let stored = try #require(try await engine.snapshot().running.first)
            #expect(stored.reminderProblem == expected, "the problem is saved with the test")
            let progress = stored.progress(at: F.now)
            let status = PatternsCopy.status(test: stored, progress: progress, verdict: nil)
            #expect(status.contains(PatternsCopy.reminderProblem(expected)))
            #expect(!status.contains("A reminder comes at"))
        }
    }

    @Test func aTestWithItsReminderSetHasNoProblem() async throws {
        let reminders = SpyPatternReminders()
        let engine = F.engine(data: F.lateDinnerData(), reminders: reminders)
        let test = try await engine.startTest(candidateID: "training", metric: nil, reminderMinuteOfDay: 20 * 60)
        #expect(test.reminder?.enabled == true && test.reminderProblem == nil)
        #expect(reminders.askedPermission == [true], "permission is asked when the test starts")
    }

    @Test func cancellingTheReminderInSettingsIsNotedOnTheTest() async throws {
        let engine = F.engine(data: F.lateDinnerData(), reminders: SpyPatternReminders())
        let test = try await engine.startTest(candidateID: "training", metric: nil, reminderMinuteOfDay: 20 * 60)
        await engine.reminderWasCancelled(testID: test.id)
        let stored = try #require(try await engine.snapshot().running.first)
        #expect(stored.reminder == nil && stored.reminderProblem == .cancelled && stored.state == .running)
        let status = PatternsCopy.status(test: stored, progress: stored.progress(at: F.now), verdict: nil)
        #expect(status.contains(PatternsCopy.reminderProblem(.cancelled)))
    }

    @Test func restoringReminderAfterTheMigrationNeverAsksForPermission() async throws {
        let reminders = SpyPatternReminders()
        let engine = F.engine(data: F.lateDinnerData(), reminders: reminders)
        let test = try await engine.startTest(candidateID: "training", metric: nil, reminderMinuteOfDay: 20 * 60)
        await engine.restoreReminders(testIDs: [test.id, UUID()])
        #expect(reminders.scheduled == [test.id, test.id])
        #expect(reminders.askedPermission == [true, false])
    }

    @Test func stoppingATestCancelsItsReminderAndFinishingDoes() async throws {
        let reminders = SpyPatternReminders()
        let engine = F.engine(data: F.lateDinnerData(), reminders: reminders)
        let test = try await engine.startTest(candidateID: "training", metric: nil, reminderMinuteOfDay: 20 * 60)
        try await engine.stopTest(id: test.id)
        #expect(reminders.cancelled == [test.id])

        let later = SpyPatternReminders()
        let store = InMemoryPatternStore()
        let first = F.engine(store: store, data: F.lateDinnerData(), reminders: later)
        let ending = try await first.startTest(candidateID: "training", metric: nil, reminderMinuteOfDay: 20 * 60)
        let afterTheEnd = F.engine(store: store, data: F.lateDinnerData(), reminders: later, now: F.now.addingTimeInterval(15 * 86_400))
        _ = try await afterTheEnd.snapshot()
        #expect(later.cancelled == [ending.id], "a finished test cancels its reminder")
    }

    @Test func theTestReminderIsOneDailyReminderThatEndsWithTheTest() throws {
        let candidate = PatternCandidate.trainingDay
        let test = try PatternTest.start(candidate: candidate, metric: .sleepScore, now: F.now, timeZone: F.zone,
                                         reminder: PatternReminder(enabled: true, minuteOfDay: 20 * 60 + 15))
        let draft = try #require(LooprPatternReminderScheduler.draft(for: test, now: F.now))
        #expect(draft.source == .patternsTest && draft.repeatsDaily && draft.minuteOfDay == 20 * 60 + 15)
        #expect(draft.objectID == "patterns." + test.id.uuidString)
        #expect(LooprNotificationRuntime.patternTestID(from: draft.objectID) == test.id)
        #expect(draft.body.hasSuffix("Open Patterns and mark today if you kept it."))
        #expect(AgentReminderText.healthReading(in: draft.title + " " + draft.body) == nil, "the app's own lock-screen text passes the same check")
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = F.zone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: draft.firstFire)
        #expect(parts.hour == 20 && parts.minute == 15 && parts.day == 16, "the first reminder is tonight at the chosen time, in the test's zone")
        let end = try #require(PatternDays.endOfDay(test.endDay, timeZoneID: test.timeZoneID))
        #expect(draft.expiresAt == end, "the reminder stops with the test's last day")
        // Once the last day has passed there is nothing to schedule.
        #expect(LooprPatternReminderScheduler.draft(for: test, now: end) == nil)
        #expect(LooprPatternReminderScheduler.draft(for: PatternTest.noReminder(from: test), now: F.now) == nil)
    }

    // MARK: The next time

    @Test func theNextOccurrenceIsTheNextTimeItIsThatMinute() throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = F.zone
        let after = calendar.date(from: DateComponents(year: 2026, month: 10, day: 16, hour: 12))!
        let evening = try #require(LooprNotificationRuntime.nextOccurrence(ofMinute: 20 * 60, after: after, calendar: calendar))
        #expect(calendar.dateComponents([.day, .hour], from: evening).day == 16 && calendar.component(.hour, from: evening) == 20)
        let morning = try #require(LooprNotificationRuntime.nextOccurrence(ofMinute: 8 * 60, after: after, calendar: calendar))
        #expect(calendar.component(.day, from: morning) == 17 && calendar.component(.hour, from: morning) == 8)
    }

    // MARK: Migration

    private actor FakeLegacyCenter: LegacyReminderCenter {
        var items: [LegacyPendingReminder]
        private(set) var removed: [String] = []
        init(_ items: [LegacyPendingReminder]) { self.items = items }
        func pending() async -> [LegacyPendingReminder] { items }
        func remove(identifiers: [String]) async { removed += identifiers; items.removeAll { identifiers.contains($0.identifier) } }
    }

    private actor RecordingClient: NotificationSchedulingClient {
        private(set) var requests: [NotificationRequest] = []
        func schedule(_ request: NotificationRequest) async throws { requests.append(request) }
        func remove(identities: Set<NotificationIdentity>) async { requests.removeAll { identities.contains($0.identity) } }
        func pending(among identities: Set<NotificationIdentity>) async -> Set<NotificationIdentity>? { Set(requests.map(\.identity)).intersection(identities) }
    }

    @Test func migrationAdoptsAskRemindersAndRemovesEveryOldRequest() async throws {
        let daily = UUID(), once = UUID(), test = UUID()
        let soon = Date().addingTimeInterval(3_600)
        let center = FakeLegacyCenter([
            LegacyPendingReminder(identifier: "loopr.agent.reminder.\(daily.uuidString)", title: "Wind down", body: "Screens off.", minuteOfDay: 20 * 60 + 15, repeats: true, nextFire: soon),
            LegacyPendingReminder(identifier: "loopr.agent.reminder.\(once.uuidString)", title: "Call Sam", body: "", minuteOfDay: 9 * 60, repeats: false, nextFire: soon),
            LegacyPendingReminder(identifier: "loopr.pattern.test.\(test.uuidString).2026-10-17", title: "Day 2 of 14", body: "x", minuteOfDay: 20 * 60, repeats: false, nextFire: soon),
            LegacyPendingReminder(identifier: "loopr.pattern.test.\(test.uuidString).2026-10-18", title: "Day 3 of 14", body: "x", minuteOfDay: 20 * 60, repeats: false, nextFire: soon),
            LegacyPendingReminder(identifier: "loopr.agent.reminder.not-a-uuid", title: "Broken", body: "", minuteOfDay: 600, repeats: false, nextFire: soon)
        ])
        let client = RecordingClient()
        let policy = NotificationPolicy(client: client, claims: NotificationClaimLedger())
        await policy.setAuthorization(.authorized)

        let summary = await LegacyReminderMigration.run(center: center, policy: policy)

        #expect(summary.adopted == 2 && summary.removed == 3 && summary.complete)
        #expect(summary.patternTestIDs == [test])
        #expect(await center.items.isEmpty, "no old request keeps firing outside the list")
        let listed = try await policy.pendingReminders()
        #expect(Set(listed.map(\.identity.objectID)) == ["ask.\(daily.uuidString)", "ask.\(once.uuidString)"])
        let adopted = try #require(listed.first { $0.identity.objectID == "ask.\(daily.uuidString)" })
        #expect(adopted.repeats == .daily && adopted.reminderSource == .ask && adopted.title == "Wind down" && adopted.detail == "Screens off.")
        #expect(adopted.identity.day == UserReminderRequestFactory.recurringDay)
        #expect(adopted.deepLink == .ask("ask.\(daily.uuidString)"))
        let oneShot = try #require(listed.first { $0.identity.objectID == "ask.\(once.uuidString)" })
        #expect(oneShot.repeats == nil && oneShot.fireDate == soon)
    }

    @Test func migrationKeepsTenAndRemovesTheRest() async throws {
        let soon = Date().addingTimeInterval(3_600)
        let ids = (0..<12).map { _ in UUID() }
        let center = FakeLegacyCenter(ids.enumerated().map { index, id in
            LegacyPendingReminder(identifier: "loopr.agent.reminder.\(id.uuidString)", title: "R\(index)", body: "", minuteOfDay: 8 * 60 + index, repeats: true, nextFire: soon)
        })
        let policy = NotificationPolicy(client: RecordingClient(), claims: NotificationClaimLedger())
        await policy.setAuthorization(.authorized)
        let summary = await LegacyReminderMigration.run(center: center, policy: policy)
        #expect(summary.adopted == 10 && summary.removed == 2)
        #expect(try await policy.pendingReminders().count == 10)
        #expect(await center.items.isEmpty)
    }

    @Test func migrationWithTheFamilyOffRemovesTheOldRequestsAndAddsNothing() async throws {
        let id = UUID()
        let center = FakeLegacyCenter([LegacyPendingReminder(identifier: "loopr.agent.reminder.\(id.uuidString)", title: "R", body: "", minuteOfDay: 480, repeats: true, nextFire: Date().addingTimeInterval(60))])
        let policy = NotificationPolicy(client: RecordingClient(), claims: NotificationClaimLedger())
        await policy.setAuthorization(.authorized)
        try await policy.setEnabled(false, for: .userReminders)
        let summary = await LegacyReminderMigration.run(center: center, policy: policy)
        #expect(summary.adopted == 0 && summary.removed == 1)
        #expect(try await policy.pendingReminders().isEmpty)
        #expect(await center.items.isEmpty)
    }

    @Test func migrationWithNothingOldDoesNothing() async {
        let center = FakeLegacyCenter([])
        let policy = NotificationPolicy(client: RecordingClient(), claims: NotificationClaimLedger())
        let summary = await LegacyReminderMigration.run(center: center, policy: policy)
        #expect(summary == LegacyReminderMigration.Summary())
    }

    // MARK: Routing

    @Test func aTapOnAReminderOpensAskOrPatterns() {
        #expect(ShellDeepLink(notification: .ask("ask.1")) == .coach)
        #expect(ShellDeepLink(notification: .patterns("patterns.1")) == .patterns)
    }
}

private enum LooprClockFormatForTests {
    static func text(minuteOfDay: Int) -> String { PatternsCopy.clock(minuteOfDay) }
}

private extension PatternTest {
    /// The same test with no reminder.
    static func noReminder(from test: PatternTest) -> PatternTest {
        var copy = test; copy.reminder = nil; return copy
    }
}
