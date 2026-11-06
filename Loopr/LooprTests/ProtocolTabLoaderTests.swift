import DomainKit
import Foundation
import JournalKit
import RoutineKit
import StorageKit
import Testing
@testable import Loopr

/// LV-07.1: the app's Protocol tab loader on a real `RoutineStore` with fake source snapshots, and the pattern lines.
@MainActor struct ProtocolTabLoaderTests {
    private let zone = TimeZone(identifier: "UTC")!
    /// Tue 14 Nov 2023, 22:13 UTC.
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private func day(_ value: Int) -> DayIdentity { DayIdentity(year: 2023, month: 11, day: value) }

    private let light = ProtocolRule(key: "light", title: "Morning light", timeOfDayMinutes: 8 * 60)
    private let meal = ProtocolRule(key: "meal", title: "Last meal by 19:00",
        target: RuleTarget(kind: .atMost, metric: RoutineMetric.lastMealTime.rawValue, value: 1_140),
        timeOfDayMinutes: 19 * 60, source: .food)
    private let bed = ProtocolRule(key: "bed", title: "In bed by 22:30",
        target: RuleTarget(kind: .atMost, metric: RoutineMetric.inBedTime.rawValue, value: 1_350),
        timeOfDayMinutes: 22 * 60 + 30, source: .band, isEvening: true)
    private var rules: [ProtocolRule] { [light, meal, bed] }

    private final class Context {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("protocol-tab-\(UUID().uuidString)")
        let database: StorageDatabase
        let store: RoutineStore
        init() throws {
            database = try StorageDatabase(url: root.appendingPathComponent("routine.sqlite"), applicationVersion: "protocol-tab-tests")
            store = RoutineStore(database: database)
        }
        deinit { try? FileManager.default.removeItem(at: root) }
    }

    /// Food logged a last meal at 18:20 on every day; the band has nothing yet.
    private actor SnapshotLog {
        private(set) var days: [String] = []
        func record(_ day: DayIdentity) { days.append(day.routineDayKey ?? "") }
    }

    private func loader(_ store: RoutineStore, log: SnapshotLog = SnapshotLog(),
                        prepare: (@Sendable (Date) async -> Void)? = nil, habits: (any HabitStore)? = nil) -> ProtocolTabLoader {
        let zone = zone
        var loader = ProtocolTabLoader(
            store: store, timeZone: { zone },
            snapshots: { day, _, _ in
                await log.record(day)
                return RoutineSourceSnapshots(band: RoutineSourceSnapshot(source: .band),
                                              food: RoutineSourceSnapshot(source: .food, readings: [.lastMealTime: .measured(1_100)]))
            },
            prepare: prepare, locale: Locale(identifier: "en_GB"))
        loader.habits = habits
        return loader
    }

    private func created(_ dayOfMonth: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        return calendar.date(from: DateComponents(year: 2023, month: 11, day: dayOfMonth, hour: 9))!
    }

    // MARK: Reads

    @Test func withoutAProtocolTheTabIsTheFirstRunAndPrepareCanMakeVersionOne() async throws {
        let context = try Context()
        #expect(await loader(context.store).load(now: now).routine == .noProtocol)

        let store = context.store
        let rules = rules
        let createdAt = created(14)
        let prepared = await loader(store, prepare: { _ in
            _ = try? store.createProtocol(RoutineProtocol(name: "My protocol", createdAt: createdAt), rules: rules)
        }).load(now: now)
        let data = try #require(prepared.routineData)
        #expect(data.protocolName == "My protocol")
        #expect(data.version == 1)
        #expect(data.dayNumber == 1)
        #expect(data.rules.map(\.key) == ["light", "meal", "bed"])
    }

    @Test func theWeekRunsMondayFirstWithTodayEvaluatedAndSettledDaysRead() async throws {
        let context = try Context()
        let routineProtocol = RoutineProtocol(name: "Sleep first", createdAt: created(1))
        try context.store.createProtocol(routineProtocol, rules: rules)
        try context.store.recordChecks([
            try RuleCheck(ruleKey: "light", day: day(13), version: 1, state: .kept, source: .manual, recordedAt: now),
            try RuleCheck(ruleKey: "meal", day: day(13), version: 1, state: .kept, source: .food, measuredValue: 1_090, recordedAt: now),
            try RuleCheck(ruleKey: "bed", day: day(13), version: 1, state: .missed, source: .band, measuredValue: 1_400, recordedAt: now),
            try RuleCheck(ruleKey: "bed", day: day(11), version: 1, state: .missed, source: .band, measuredValue: 1_410, recordedAt: now)
        ], protocolID: routineProtocol.id)
        let log = SnapshotLog()

        let data = try #require(await loader(context.store, log: log).load(now: now).routineData)

        #expect(data.week.map(\.day) == (13...19).map(day))
        #expect(data.week.map(\.phase) == [.past, .today, .future, .future, .future, .future, .future])
        #expect(data.today == day(14))
        #expect(data.nowMinute == 22 * 60 + 13)
        #expect(data.dayNumber == 14)
        let monday = data.week[0].rules.map(\.state)
        #expect(monday == [.kept, .kept, .missed])
        let today = Dictionary(uniqueKeysWithValues: data.week[1].rules.map { ($0.rule.key, $0.state) })
        #expect(today["meal"] == .kept, "Food's 18:20 meal keeps the 19:00 rule once 19:00 has passed")
        #expect(today["light"] == .pending)
        #expect(today["bed"] == .pending, "The band has not scored the night yet")
        #expect(data.week[2].rules.allSatisfy { $0.state == nil })
        #expect(await log.days == ["2023-11-14"], "A settled Monday is read, not evaluated again")

        #expect(data.lastWeek.map(\.day) == (6...12).map(day))
        #expect(data.lastWeek[5].rules.first { $0.rule.key == "bed" }?.state == .missed)
        #expect(data.lastWeek[0].rules.allSatisfy { $0.state == nil }, "A day with nothing stored stays empty")
    }

    @Test func daysBeforeTheProtocolDrawNothingAndThePastStillOpenIsEvaluated() async throws {
        let context = try Context()
        try context.store.createProtocol(RoutineProtocol(name: "My protocol", createdAt: created(14)), rules: rules)
        let data = try #require(await loader(context.store).load(now: now).routineData)
        #expect(data.week[0].phase == .beforeProtocol)
        #expect(data.week[0].rules.isEmpty)

        let older = try Context()
        let routineProtocol = RoutineProtocol(name: "My protocol", createdAt: created(10))
        try older.store.createProtocol(routineProtocol, rules: rules)
        let log = SnapshotLog()
        let evaluated = try #require(await loader(older.store, log: log).load(now: now).routineData)
        #expect(await log.days == ["2023-11-13", "2023-11-14"], "Monday had no checks, so it is evaluated")
        let monday = Dictionary(uniqueKeysWithValues: evaluated.week[0].rules.map { ($0.rule.key, $0.state) })
        #expect(monday["light"] == .unknown, "An unticked manual rule is unknown once the day is over, never missed")
        #expect(monday["meal"] == .kept)
    }

    /// ICP R1-UPG-11: a protocol moved over from the Journal counts its days from the first answer it holds, not from
    /// the launch that moved it.
    @Test func aMovedProtocolCountsItsDaysFromItsFirstAnswer() async throws {
        let context = try Context()
        let habit = UUID(uuidString: "00000000-0000-0000-0000-000000000042")!
        let moved = JournalHabit(id: habit, title: "Meditate", period: .evening, createdAt: created(1))
        let answers = [JournalHabitResponse(habitID: habit, day: day(6), answer: .yes, origin: .person, recordedAt: created(6))]
        _ = try RoutineHabitMigration.run(database: context.database, habits: [moved], responses: answers, now: created(14))
        let data = try #require(await loader(context.store).load(now: now).routineData)
        #expect(data.dayNumber == 9, "6 Nov is day 1, so Tuesday 14 Nov is day 9")
        #expect(data.habitRuleIDs == [habit])
        #expect(data.week[0].phase == .past, "Monday is inside the history now")
    }

    /// ICP R1-UPG-1: an answer on a rule that was a Journal habit is written back to the habit with the habit's meaning.
    @Test func anAnswerOnAMovedHabitIsWrittenBackToTheJournal() async throws {
        let context = try Context()
        // A manual habit: alcohol and late caffeine are checked by Food now, so the person cannot tick them.
        let item = try #require(HabitCatalog.byID["nicotine"])
        let definition = HabitDefinition(id: HabitID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000043")!),
                                         source: .preset(catalogID: "nicotine"), name: item.name, question: item.question,
                                         sortOrder: 0, createdAt: created(1), questionPeriod: .evening)
        let habits = InMemoryHabitStore(definitions: [definition])
        _ = try RoutineHabitMigration.run(database: context.database, habits: [definition.routineHabit], responses: [],
                                          now: created(1))
        let loader = loader(context.store, habits: habits)
        _ = await loader.load(now: now)
        let key = RoutineHabitMigration.ruleKey(forHabit: definition.id.rawValue)

        try await loader.tick(key, day: day(14), now: now)
        var record = await habits.dayRecord(for: day(14))
        #expect(record?.response(for: definition.id)?.answer == HabitAnswer.no, "Kept No nicotine is a no to the nicotine question")

        try await loader.clear(key, day: day(14), now: now)
        record = await habits.dayRecord(for: day(14))
        #expect(record?.response(for: definition.id) == nil, "Undo takes the Journal answer back too")
    }

    // MARK: Writes

    @Test func answersGoThroughTheDayEvaluation() async throws {
        let context = try Context()
        let routineProtocol = RoutineProtocol(name: "My protocol", createdAt: created(1))
        try context.store.createProtocol(routineProtocol, rules: rules)
        let loader = loader(context.store)
        _ = await loader.load(now: now)

        try await loader.tick("light", day: day(14), now: now)
        let ticked = try #require(try context.store.check(protocolID: routineProtocol.id, ruleKey: "light", day: day(14)))
        #expect(ticked.state == .kept)
        #expect(ticked.source == .manual)

        try await loader.override("bed", day: day(14), kept: false, now: now)
        let overridden = try #require(try context.store.check(protocolID: routineProtocol.id, ruleKey: "bed", day: day(14)))
        #expect(overridden.state == .missed)
        #expect(overridden.overriddenByPerson)

        try await loader.clear("bed", day: day(14), now: now)
        try await loader.clear("light", day: day(14), now: now)
        let reloaded = try #require(await loader.load(now: now).routineData)
        let today = Dictionary(uniqueKeysWithValues: reloaded.week[1].rules.map { ($0.rule.key, $0) })
        #expect(today["bed"]?.state == .pending, "Undo hands the rule back to its source")
        #expect(today["bed"]?.overriddenByPerson == false)
        #expect(today["light"]?.state == .pending)
    }

    @Test func aStoreThatCannotBeReadSaysSoInsteadOfShowingAnEmptyWeek() async {
        let content = await UnavailableProtocolSource().load(now: now)
        #expect(content.routine == .unavailable(ProtocolTabLoader.unavailableMessage))
        await #expect(throws: RoutineError.self) { try await UnavailableProtocolSource().tick("light", day: day(14), now: now) }
    }

    // MARK: Patterns

    private func pattern(_ id: String, _ title: String, _ metric: HabitOutcomeMetricID, _ strength: PatternStrength,
                         difference: Double, nights: Int) -> FoundPattern {
        FoundPattern(candidateID: id, habitID: HabitID(rawValue: UUID()), title: title, predicate: .journalAnswer(name: title),
                     metric: metric, strength: strength,
                     effect: PatternEffect(adjustedDifference: difference, rawDifference: difference, withMean: nil, withoutMean: nil,
                                           intervalLower: nil, intervalUpper: nil, pValue: 0.01, practicalThreshold: 1,
                                           unit: metric.unit),
                     nights: PatternNights(with: nights / 2, without: nights - nights / 2), windowEnd: "2023-11-13",
                     algorithmVersion: "test", foundAt: now)
    }

    @Test func patternLinesComeFromTheCoachWriterStrongestFirstAndNeverEarly() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let state = ProtocolTabPatterns.lines([
            pattern("late-dinner", "Late dinner", .recoveryScore, .clear, difference: -4, nights: 11),
            pattern("alcohol", "Alcohol", .hrvRMSSD, .strong, difference: -6, nights: 23),
            pattern("early", "Sauna", .deepSleepMinutes, .early, difference: 9, nights: 6),
            pattern("walk", "Evening walk", .sleepDuration, .clear, difference: 14, nights: 30)
        ], locale: Locale(identifier: "en_GB"), calendar: calendar)

        #expect(state.isAvailable)
        #expect(state.total == 3, "Early patterns are never counted or shown")
        #expect(state.lines.map(\.id) == ["alcohol.hrvRMSSD", "walk.sleepDuration", "late-dinner.recoveryScore"])
        #expect(state.lines.map(\.bars) == [3, 2, 2])
        let alcohol = state.lines[0]
        #expect(alcohol.title == "Alcohol")
        #expect(alcohol.outcome == "HRV", "Experiments names the pattern by what it links, \"Alcohol and HRV\" (ICP R1-VET-19)")
        #expect(alcohol.detail.hasPrefix("HRV 6"))
        #expect(alcohol.detail.hasSuffix("lower \u{00B7} 23 nights"))
        #expect(state.lines[2].detail == "Recovery 4 points lower \u{00B7} 11 nights")
        for line in state.lines {
            #expect(!line.text.lowercased().contains("cause"))
            #expect(!line.text.contains("!"))
        }
    }

    /// ICP R3-UPG-5: "Use my questions" on an empty tab makes version 1 from the questions, with their answers, and a
    /// tab that already has a protocol is left alone.
    @Test func useMyQuestionsStartsAProtocolFromTheQuestions() async throws {
        let context = try Context()
        let loader = loader(context.store)
        let alcohol = JournalHabit(id: UUID(), catalogID: "alcohol", title: "Alcohol", period: .today, createdAt: now)
        let nap = JournalHabit(id: UUID(), catalogID: "napped", title: "Napped", period: .today, createdAt: now)
        let answer = JournalHabitResponse(habitID: alcohol.id, day: day(13), answer: .no, origin: .person, recordedAt: now)
        try await loader.startFromQuestions([alcohol, nap], responses: [answer], now: now)
        let active = try #require(try context.store.activeProtocol())
        #expect(active.latestVersion.rules.map(\.title) == ["No alcohol"], "a question about the day becomes no rule")
        let key = RoutineHabitMigration.ruleKey(forHabit: alcohol.id)
        #expect(try context.store.check(protocolID: active.routineProtocol.id, ruleKey: key, day: day(13))?.state == .kept)
        await #expect(throws: (any Error).self) { try await loader.startFromQuestions([alcohol], responses: [], now: now) }
        #expect(try context.store.protocols().count == 1)

        let empty = try Context()
        await #expect(throws: ProtocolTabError.noRuleInQuestions) {
            try await self.loader(empty.store).startFromQuestions([nap], responses: [], now: now)
        }
    }
}
