import CoachKit
import DataKit
import DomainKit
import Foundation
import HealthKitBridge
import JournalKit
import NotificationKit
import RoutineKit
import StorageKit
import Testing
import TodayKit
@testable import Loopr

/// LV-10 integration: the weekly review is reachable. Today's card shows from Sunday 17:00 to Monday 12:00 once per ISO
/// week, the proposal starts one experiment through RoutineKit, Not now records the decline, the reads come from the
/// stores, and the reminder is a weekly "Reminders you set" request.
@MainActor
struct WeeklyReviewTests {
    static let berlin: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }()

    static func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        berlin.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    static func defaults() -> UserDefaults {
        let name = "loopr.tests.weekly.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    // MARK: When Today shows the card

    @Test func theWeekIsTheISOWeekWithItsMondayAndKey() throws {
        let week = try #require(WeeklyReviewSchedule.week(containing: Self.at(2026, 10, 21, 9), calendar: Self.berlin))
        #expect(week.monday == DayIdentity(year: 2026, month: 10, day: 19))
        #expect(week.isoKey == "2026-W43")
        #expect(week.days.count == 7)
        #expect(week.sunday == DayIdentity(year: 2026, month: 10, day: 25))
        // Across the new year the ISO year is the week's, not the calendar's.
        let boundary = try #require(WeeklyReviewSchedule.week(containing: Self.at(2027, 1, 3, 18), calendar: Self.berlin))
        #expect(boundary.isoKey == "2026-W53")
        #expect(boundary.monday == DayIdentity(year: 2026, month: 12, day: 28))
    }

    @Test func theCardShowsFromSundayFiveToMondayNoon() throws {
        let never: (String) -> Bool = { _ in false }
        func shows(_ date: Date) -> Bool {
            guard let window = WeeklyReviewSchedule.todayWindow(at: date, calendar: Self.berlin, hasSeen: never) else { return false }
            return window.contains(date)
        }
        #expect(!shows(Self.at(2026, 10, 25, 16, 59)))
        #expect(shows(Self.at(2026, 10, 25, 17, 0)))
        #expect(shows(Self.at(2026, 10, 25, 23, 30)))
        #expect(shows(Self.at(2026, 10, 26, 7, 0)))
        #expect(shows(Self.at(2026, 10, 26, 11, 59)))
        #expect(!shows(Self.at(2026, 10, 26, 12, 0)))
        #expect(!shows(Self.at(2026, 10, 21, 18, 0)))
        // Sunday evening and Monday morning offer the same week.
        let sunday = try #require(WeeklyReviewSchedule.todayWindow(at: Self.at(2026, 10, 25, 18), calendar: Self.berlin, hasSeen: never))
        let monday = try #require(WeeklyReviewSchedule.todayWindow(at: Self.at(2026, 10, 26, 8), calendar: Self.berlin, hasSeen: never))
        #expect(sunday == monday)
        #expect(sunday.week.isoKey == "2026-W43")
    }

    @Test func aSeenWeekHidesTheCardUntilTheNextWeek() {
        let store = WeeklyReviewSeenStore(defaults: Self.defaults())
        #expect(WeeklyReviewSchedule.todayWindow(at: Self.at(2026, 10, 25, 18), calendar: Self.berlin, hasSeen: store.hasSeen) != nil)
        store.markSeen("2026-W43")
        store.markSeen("2026-W43")
        #expect(store.seenWeeks == ["2026-W43"])
        #expect(WeeklyReviewSchedule.todayWindow(at: Self.at(2026, 10, 25, 18), calendar: Self.berlin, hasSeen: store.hasSeen) == nil)
        #expect(WeeklyReviewSchedule.todayWindow(at: Self.at(2026, 10, 26, 9), calendar: Self.berlin, hasSeen: store.hasSeen) == nil)
        // The next Sunday is a new week.
        let next = WeeklyReviewSchedule.todayWindow(at: Self.at(2026, 11, 1, 18), calendar: Self.berlin, hasSeen: store.hasSeen)
        #expect(next?.week.isoKey == "2026-W44")
        #expect(next?.contains(Self.at(2026, 11, 1, 18)) == true)
    }

    @Test func theSeenListStaysShort() {
        let store = WeeklyReviewSeenStore(defaults: Self.defaults())
        for week in 1...20 { store.markSeen(String(format: "2026-W%02d", week)) }
        #expect(store.seenWeeks.count == WeeklyReviewSeenStore.capacity)
        #expect(store.seenWeeks.last == "2026-W20")
        #expect(!store.hasSeen("2026-W01"))
    }

    @Test func todayDrawsTheCardOnlyInsideTheWindowOnToday() throws {
        let window = try #require(WeeklyReviewSchedule.todayWindow(at: Self.at(2026, 10, 25, 12), calendar: Self.berlin,
                                                                   hasSeen: { _ in false }))
        let offer = TodayWeekReviewOffer(weekKey: window.week.isoKey, opens: window.opens, closes: window.closes,
                                         title: WeeklyReviewCopy.todayTitle, detail: WeeklyReviewCopy.todayDetail)
        var content = TodayCompanionContent(now: Self.at(2026, 10, 25, 12), calendar: Self.berlin)
        content.weekReview = offer
        #expect(!content.showsWeekReview(at: Self.at(2026, 10, 25, 12)))
        #expect(content.showsWeekReview(at: Self.at(2026, 10, 25, 17)))
        #expect(content.showsWeekReview(at: Self.at(2026, 10, 26, 11, 59)))
        #expect(!content.showsWeekReview(at: Self.at(2026, 10, 26, 12)))
        content.isToday = false
        #expect(!content.showsWeekReview(at: Self.at(2026, 10, 25, 18)))
        content.isToday = true
        content.weekReview = nil
        #expect(!content.showsWeekReview(at: Self.at(2026, 10, 25, 18)))
    }

    @Test func protocolAndTheReminderOpenTheNewestOpenedWeek() {
        #expect(WeeklyReviewSchedule.reviewWeek(at: Self.at(2026, 10, 21, 9), calendar: Self.berlin)?.isoKey == "2026-W42")
        #expect(WeeklyReviewSchedule.reviewWeek(at: Self.at(2026, 10, 25, 16, 59), calendar: Self.berlin)?.isoKey == "2026-W42")
        #expect(WeeklyReviewSchedule.reviewWeek(at: Self.at(2026, 10, 25, 17), calendar: Self.berlin)?.isoKey == "2026-W43")
        #expect(WeeklyReviewSchedule.reviewWeek(at: Self.at(2026, 10, 26, 9), calendar: Self.berlin)?.isoKey == "2026-W43")
    }

    // MARK: The proposal

    private struct Graph {
        let root: URL
        let routine: RoutineStore
        let experiments: ExperimentStore
        let protocolID: ProtocolID
    }

    private static let kitchen = ProtocolRule(key: RuleKey(rawValue: "kitchen"), title: "Kitchen closes", timeOfDayMinutes: 18 * 60 + 30)
    private static let screens = ProtocolRule(key: RuleKey(rawValue: "screens"), title: "Screens off", timeOfDayMinutes: 21 * 60 + 45)

    private static func graph(createdAt: Date? = nil) throws -> Graph {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loopr-weekly-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let database = try StorageDatabase(url: root.appendingPathComponent("product.sqlite"), applicationVersion: "1.0 (1)")
        let routine = RoutineStore(database: database)
        let created = RoutineProtocol(name: "Sleep first", createdAt: createdAt ?? at(2026, 8, 1, 9))
        try routine.createProtocol(created, rules: [kitchen, screens])
        return Graph(root: root, routine: routine, experiments: ExperimentStore(database: database), protocolID: created.id)
    }

    private static func environment(_ graph: Graph?, decisions: any WeeklyProposalDecisionStoring,
                                    started: @escaping () -> Void = {}) -> WeeklyReviewEnvironment {
        WeeklyReviewEnvironment(
            now: { at(2026, 10, 25, 19) }, calendar: berlin, locale: Locale(identifier: "en_GB"),
            sources: WeeklyReviewSources(routine: graph?.routine, experiments: graph?.experiments),
            seen: WeeklyReviewSeenStore(defaults: defaults()), decisions: decisions,
            startExperiment: { proposal, now in
                started()
                guard let graph else { return }
                try WeeklyReviewExperimentStart.start(proposal, routine: graph.routine, experiments: graph.experiments,
                                                      now: now, timeZone: berlin.timeZone)
            })
    }

    private static func controller(_ presenter: WeeklyReviewPresenter) throws -> WeeklyStoryController {
        guard case .story(let controller)? = presenter.sheet?.content else {
            Issue.record("expected a story")
            throw CancellationError()
        }
        return controller
    }

    @Test func startTheExperimentStartsOneExperimentWithTheProposedDesign() throws {
        let graph = try Self.graph()
        defer { try? FileManager.default.removeItem(at: graph.root) }
        var starts = 0
        let decisions = UserDefaultsWeeklyProposalDecisionStore(defaults: Self.defaults())
        let presenter = WeeklyReviewPresenter()
        let story = try #require(WeeklyReviewFixture.result(calendar: Self.berlin, locale: Locale(identifier: "en_GB")).story)
        let proposal = try #require(story.proposal)
        #expect(story.pages.count == 5)
        presenter.present(.story(story), week: WeeklyReviewFixture.week,
                          environment: Self.environment(graph, decisions: decisions, started: { starts += 1 }))
        let controller = try Self.controller(presenter)
        // Building and paging write nothing.
        controller.next(); controller.next(); controller.next()
        #expect(try graph.experiments.experiments().isEmpty)

        controller.startExperiment()
        controller.startExperiment()
        controller.notNow()
        #expect(starts == 1)
        #expect(decisions.decisions().isEmpty)
        #expect(presenter.message == nil)
        let all = try graph.experiments.experiments()
        #expect(all.count == 1)
        let running = try #require(try graph.experiments.running())
        #expect(running.start.ruleKey == proposal.ruleKey)
        #expect(running.start.title == "Kitchen closes at 18:30 on weekends too")
        #expect(running.start.outcome == .sleepHeartRate)
        #expect(running.start.plannedNights == 14)
        #expect(running.start.design == .beforeAndAfter(baselineNights: 7))
        #expect(running.start.startDay == DayIdentity(year: 2026, month: 10, day: 25))
        #expect(running.start.protocolID == graph.protocolID)
        // The version the person follows stays until they keep a result.
        #expect(try graph.routine.activeProtocol()?.latestVersion.number == 1)
        // A second start is refused by the store, so a repeated tap elsewhere starts nothing more.
        #expect(throws: (any Error).self) {
            try WeeklyReviewExperimentStart.start(proposal, routine: graph.routine, experiments: graph.experiments,
                                                  now: Self.at(2026, 10, 25, 19), timeZone: Self.berlin.timeZone)
        }
        #expect(try graph.experiments.experiments().count == 1)
    }

    @Test func aRefusedStartSaysSo() throws {
        let graph = try Self.graph()
        defer { try? FileManager.default.removeItem(at: graph.root) }
        let story = try #require(WeeklyReviewFixture.result(calendar: Self.berlin).story)
        let proposal = try #require(story.proposal)
        try WeeklyReviewExperimentStart.start(proposal, routine: graph.routine, experiments: graph.experiments,
                                              now: Self.at(2026, 10, 20, 19), timeZone: Self.berlin.timeZone)
        let presenter = WeeklyReviewPresenter()
        presenter.present(.story(story), week: nil,
                          environment: Self.environment(graph, decisions: UserDefaultsWeeklyProposalDecisionStore(defaults: Self.defaults())))
        try Self.controller(presenter).startExperiment()
        #expect(presenter.message?.hasPrefix("Loopr could not start the experiment.") == true)
        #expect(try graph.experiments.experiments().count == 1)
    }

    @Test func notNowRecordsTheDeclineAndStartsNothing() throws {
        let graph = try Self.graph()
        defer { try? FileManager.default.removeItem(at: graph.root) }
        var starts = 0
        let decisions = UserDefaultsWeeklyProposalDecisionStore(defaults: Self.defaults())
        let presenter = WeeklyReviewPresenter()
        let story = try #require(WeeklyReviewFixture.result(calendar: Self.berlin).story)
        presenter.present(.story(story), week: WeeklyReviewFixture.week,
                          environment: Self.environment(graph, decisions: decisions, started: { starts += 1 }))
        let controller = try Self.controller(presenter)
        controller.go(to: 3)
        controller.notNow()
        controller.notNow()
        controller.startExperiment()
        #expect(starts == 0)
        #expect(try graph.experiments.experiments().isEmpty)
        let recorded = decisions.decisions()
        #expect(recorded.count == 1)
        #expect(recorded.first?.ruleKey == RuleKey(rawValue: "kitchen"))
        #expect(recorded.first?.outcome == .sleepHeartRate)
        #expect(recorded.first?.weekKey == "2026-10-19")
        presenter.close()
        #expect(presenter.sheet == nil)
    }

    @Test func theProposedDesignAndOutcomeMapOntoRoutineKit() {
        #expect(WeeklyReviewExperimentStart.design(.alternatingDays, nights: 14) == .alternatingDays)
        #expect(WeeklyReviewExperimentStart.design(.blocks, nights: 14) == .blocks(length: 7))
        #expect(WeeklyReviewExperimentStart.design(.beforeAndAfter, nights: 14) == .beforeAndAfter(baselineNights: 7))
        #expect(WeeklyReviewExperimentStart.metric(.sleepHeartRate) == .sleepHeartRate)
        #expect(WeeklyReviewExperimentStart.metric(.hrv) == .hrv)
        #expect(WeeklyReviewExperimentStart.metric(.restingHeartRate) == nil)
        for outcome in [NoteOutcomeKind.sleepHeartRate, .hrv, .deepSleep, .timeToFallAsleep] {
            #expect(WeeklyReviewExperimentStart.metric(outcome).flatMap(WeeklyReviewExperimentStart.outcome) == outcome)
        }
    }

    // MARK: Reads

    @Test func theInputReadsTheWeeksChecksTheNightsAndTheSlips() async throws {
        let graph = try Self.graph()
        defer { try? FileManager.default.removeItem(at: graph.root) }
        let week = try #require(WeeklyReviewSchedule.week(containing: Self.at(2026, 10, 25, 18), calendar: Self.berlin))
        var checks: [RuleCheck] = []
        for offset in -40...6 {
            let day = try #require(week.monday.adding(days: offset))
            let missed = offset >= 5 || (offset < 0 && offset % 4 == 0)
            checks.append(try RuleCheck(ruleKey: Self.kitchen.key, day: day, version: 1, state: missed ? .missed : .kept,
                                        source: .manual, recordedAt: Self.at(2026, 10, 25, 9)))
            checks.append(try RuleCheck(ruleKey: Self.screens.key, day: day, version: 1, state: .kept, source: .manual,
                                        recordedAt: Self.at(2026, 10, 25, 9)))
        }
        try graph.routine.recordChecks(checks, protocolID: graph.protocolID)
        let calendar = Self.berlin
        // Sleep heart rate 50 after a kept night and 55 after a missed one, on the day the person woke.
        let missedDays = Set(checks.filter { $0.state == .missed }.map(\.day))
        let history: @Sendable (MetricKey, Int, Date) async -> [MetricHistoryPoint] = { key, _, _ in
            guard key == .sleepingHeartRate else { return [] }
            // Up to Saturday's night: Sunday's has not happened at 19:00.
            return (-40...5).compactMap { offset -> MetricHistoryPoint? in
                guard let night = week.monday.adding(days: offset), let woke = night.adding(days: 1),
                      let date = calendar.date(from: DateComponents(year: woke.year, month: woke.month, day: woke.day)) else { return nil }
                return MetricHistoryPoint(day: date, value: missedDays.contains(night) ? 55 : 50, source: .band)
            }
        }
        let decision = WeeklyProposalDecision(weekKey: "2026-10-12", ruleKey: Self.kitchen.key, outcome: .hrv, missedNights: 3, gap: 2)
        let input = try await WeeklyReviewInputs.read(
            week: week, now: Self.at(2026, 10, 25, 19), calendar: calendar,
            sources: WeeklyReviewSources(routine: graph.routine, experiments: graph.experiments, history: history,
                                         declined: { [decision] }))
        #expect(input.days == week.days)
        #expect(input.versionNumber == 1)
        #expect(input.protocolName == "Sleep first")
        let kitchenWeek = try #require(input.rules.first { $0.rule.key == Self.kitchen.key })
        #expect(kitchenWeek.days.count == 7)
        #expect(kitchenWeek.days.filter { $0.state == .missed }.map(\.day) == [week.monday.adding(days: 5)!, week.sunday])
        let heart = try #require(input.outcomes.first { $0.kind == .sleepHeartRate })
        #expect(heart.nights == 6)
        #expect(heart.usual?.nights == 30)
        #expect(!input.outcomes.contains { $0.kind == .hrv })
        // Screens off was never missed this week, so only Kitchen closes is a slip.
        #expect(Set(input.slips.map(\.rule.key)) == [Self.kitchen.key])
        let slip = try #require(input.slips.first { $0.outcome == .sleepHeartRate })
        #expect(slip.history.filter(\.missed).allSatisfy { $0.outcome == nil || $0.outcome == 55 })
        #expect(slip.history.filter { !$0.missed }.allSatisfy { $0.outcome == nil || $0.outcome == 50 })
        #expect(input.declined == [decision])
        #expect(input.runningExperiment == nil)
        // The writer turns it into a story with a proposal for the next version.
        let story = try #require(WeeklyStoryWriter(context: NoteContext(locale: Locale(identifier: "en_GB"), calendar: calendar))
            .write(input).story)
        #expect(story.proposal?.ruleKey == Self.kitchen.key)
        #expect(story.proposal?.toVersion == 2)
    }

    /// ICP R2-DES-04, R2-VET-02: the review reads the week as the check-in does. A protocol made on Wednesday covers 5
    /// days, a skipped check is left out, and the share is the hero's.
    @Test func theReviewCountsTheWeekAsTheCheckInDoes() async throws {
        let graph = try Self.graph(createdAt: Self.at(2026, 10, 21, 9))
        defer { try? FileManager.default.removeItem(at: graph.root) }
        let week = try #require(WeeklyReviewSchedule.week(containing: Self.at(2026, 10, 25, 18), calendar: Self.berlin))
        var checks: [RuleCheck] = []
        for offset in 2...6 {
            let day = try #require(week.monday.adding(days: offset))
            checks.append(try RuleCheck(ruleKey: Self.kitchen.key, day: day, version: 1, state: offset == 3 ? .skipped : .kept,
                                        source: .manual, recordedAt: Self.at(2026, 10, 25, 9)))
            checks.append(try RuleCheck(ruleKey: Self.screens.key, day: day, version: 1, state: offset == 6 ? .missed : .kept,
                                        source: .manual, recordedAt: Self.at(2026, 10, 25, 9)))
        }
        try graph.routine.recordChecks(checks, protocolID: graph.protocolID)
        let input = try await WeeklyReviewInputs.read(week: week, now: Self.at(2026, 10, 25, 19), calendar: Self.berlin,
                                                      sources: WeeklyReviewSources(routine: graph.routine, experiments: graph.experiments))
        #expect(input.startDay == week.monday.adding(days: 2))
        let story = try #require(WeeklyStoryWriter(context: NoteContext(locale: Locale(identifier: "en_GB"), calendar: Self.berlin))
            .write(input).story)
        let page = try #require(story.pages.first)
        guard case .kept(let kept) = page.detail else { Issue.record("expected the kept page"); return }
        #expect(page.kicker.hasPrefix("Week of 19 to 25 Oct"))
        #expect(kept.dayCount == 5)
        #expect(kept.skippedRuleDays == 1)
        #expect(kept.keptRuleDays == 8 && kept.decidedRuleDays == 9)
        #expect(kept.share.displayed == "89%")
        #expect(RoutineWeekCount(kept: 8, missed: 1).percent == 89, "The hero's function gives the same share")
    }

    @Test func withoutAProtocolTheReviewIsAbsentWithItsReason() async throws {
        let week = try #require(WeeklyReviewSchedule.week(containing: Self.at(2026, 10, 25, 18), calendar: Self.berlin))
        let input = try await WeeklyReviewInputs.read(week: week, now: Self.at(2026, 10, 25, 19), calendar: Self.berlin,
                                                      sources: WeeklyReviewSources())
        let result = WeeklyStoryWriter().write(input)
        #expect(result == .absent(.noRules))
        let presenter = WeeklyReviewPresenter()
        presenter.present(result, week: week, environment: Self.environment(nil, decisions: InMemoryWeeklyProposalDecisionStore()))
        guard case .absent(let reason)? = presenter.sheet?.content else {
            Issue.record("expected the absent sheet")
            return
        }
        #expect(reason == WeeklyStoryAbsence.noRules.reason)
    }

    @Test func openingMarksTheWeekSeen() async throws {
        let graph = try Self.graph()
        defer { try? FileManager.default.removeItem(at: graph.root) }
        let seen = WeeklyReviewSeenStore(defaults: Self.defaults())
        var environment = Self.environment(graph, decisions: InMemoryWeeklyProposalDecisionStore())
        environment.seen = seen
        let presenter = WeeklyReviewPresenter()
        await presenter.open(environment)
        #expect(seen.hasSeen("2026-W43"))
        #expect(presenter.sheet?.week?.isoKey == "2026-W43")
        // Too few checks this week, so the sheet says why.
        guard case .absent? = presenter.sheet?.content else {
            Issue.record("expected the absent sheet")
            return
        }
    }

    // MARK: Reminder

    @Test func theReminderIsAWeeklyUserReminderOnSundayEvening() throws {
        let now = Self.at(2026, 10, 21, 9)
        guard case .request(let request, let replaces) = WeeklyReviewReminder.build(now: now, calendar: Self.berlin, pending: []) else {
            Issue.record("expected a request")
            return
        }
        #expect(!replaces)
        #expect(request.identity.family == .userReminders)
        #expect(request.identity.objectID == WeeklyReviewReminder.objectID)
        #expect(request.repeats == .weekly)
        #expect(request.fireDate == Self.at(2026, 10, 25, 18))
        #expect(request.deepLink == .weeklyReview(WeeklyReviewReminder.objectID))
        #expect(request.lockScreenBody == "Your week is ready to read.")
        #expect(request.nextFireDate(after: Self.at(2026, 10, 25, 19), calendar: Self.berlin) == Self.at(2026, 11, 1, 18))
        #expect(ShellDeepLink(notification: request.deepLink) == .weeklyReview)
        #expect(UserReminderCopy.detail(request, calendar: Self.berlin).contains("Every "))
        // It counts toward the shared cap of ten.
        let full = (0..<NotificationFamily.userReminderLimit).map { index in
            UserReminderRequestFactory.request(source: .ask, objectID: "ask.\(index)", day: "recurring", fireDate: now,
                                               title: "Reminder", detail: "Text", repeats: .daily)
        }
        #expect(WeeklyReviewReminder.build(now: now, calendar: Self.berlin, pending: full)
            == .refused(.full(limit: NotificationFamily.userReminderLimit)))
    }
}

/// LV-10 integration: where the note's chips and the experiment strip go.
@MainActor
struct TodayCompanionRoutingTests {
    @Test func whyOpensTheMethodPageOnDataAndAllNightsOpensSleep() {
        let method = MethodMetricText.methodID(for: .sleepingHeartRate)
        #expect(method == .restingHeartRate)
        #expect(TodayCompanionRouting.route(for: .explainOutcome) == .destination(.method(.restingHeartRate)))
        #expect(TodayCompanionRouting.dataPath(for: .method(.restingHeartRate)) == [.method(.restingHeartRate)])
        #expect(TodayCompanionRouting.route(for: .showNights) == .today(.sleep))
        #expect(TodayCompanionRouting.route(for: .ask) == .today(.coach))
        #expect(TodayCompanionRouting.route(for: .startWindDown) == .startWindDown)
    }

    @Test func theStripOpensProtocolOnExperiments() {
        #expect(TodayCompanionRouting.experimentStrip == .protocolSegment(.experiments))
        #expect(TodayCompanionRouting.dataPath(for: TodayCompanionRouting.experimentStrip) == nil)
        #expect(ShellDeepLink.parse(arguments: ["--loopr-deep-link=protocol/experiments"]) == .protocolSegment(.experiments))
        #expect(ShellDeepLink.parse(arguments: ["--loopr-deep-link=weekly-review"]) == .weeklyReview)
        // Two requests for the same segment are different requests, so a second tap switches again.
        #expect(ProtocolSegmentRequest(segment: .experiments) != ProtocolSegmentRequest(segment: .experiments))
    }
}

/// LV-10 integration: the Apple Health source row reads the source summary.
@MainActor
struct AppleHealthSourceRowTests {
    static let end = Date(timeIntervalSince1970: 1_790_000_000)

    static func sample(_ kind: AppleHealthSourceKind, _ value: Double, source: String) -> AppleHealthSample {
        AppleHealthSample(kind: kind, value: value, original: AppleHealthOriginalReading(value: value, unit: kind.storeUnit),
                          start: end, end: end,
                          provenance: AppleHealthProvenance(sourceName: source, sourceBundleIdentifier: "com.example.\(kind.rawValue)"))
    }

    @Test func theRowListsTheKindsWithDataAndTheirSourceApps() {
        // A stubbed summary: VO₂max and daylight from Apple Watch, weight from Withings, the other kinds empty.
        let latest: [AppleHealthSourceKind: AppleHealthSample] = [
            .vo2Max: Self.sample(.vo2Max, 44, source: "Apple Watch"),
            .daylight: Self.sample(.daylight, 35, source: "Apple Watch"),
            .weight: Self.sample(.weight, 80, source: "Withings")
        ]
        let kinds = AppleHealthSourceKind.allCases.map { kind in
            AppleHealthKindSummary(kind: kind, isEnabled: true, latest: latest[kind], absence: latest[kind] == nil ? .noSamples : nil)
        }
        let summary = AppleHealthSourceSummary(kinds: kinds, sources: [
            AppleHealthSourceLine(label: "Apple Watch", kinds: [.vo2Max, .daylight], lastSeen: Self.end),
            AppleHealthSourceLine(label: "Withings", kinds: [.weight], lastSeen: Self.end)
        ])
        let facts = DataOverviewMapping.sourceFacts(summary: summary, band: DataBandFacts(), draws: nil, vault: nil)
        let row = DataSourceRow.rows(facts, now: Self.end).first { $0.kind == .appleHealth }
        #expect(row?.kind.identifier == "data-source-apple-health")
        #expect(row?.text == "Apple Health · VO₂max, daylight and weight from Apple Watch and Withings")

        let off = AppleHealthSourceSummary(kinds: AppleHealthSourceKind.allCases.map {
            AppleHealthKindSummary(kind: $0, isEnabled: false, latest: nil, absence: .switchedOff)
        }, sources: [])
        let offRow = DataSourceRow.rows(DataOverviewMapping.sourceFacts(summary: off, band: DataBandFacts(), draws: nil, vault: nil),
                                        now: Self.end).first { $0.kind == .appleHealth }
        #expect(offRow?.text == "Apple Health · reads switched off")
    }
}
