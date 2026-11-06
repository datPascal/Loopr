import DomainKit
import Foundation
import RoutineKit
import StorageKit
import Testing

private final class MigrationTestDatabase {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("RoutineMigrationTests-\(UUID().uuidString)")
    let database: StorageDatabase
    let store: RoutineStore
    init() throws {
        database = try StorageDatabase(url: root.appendingPathComponent("routine.sqlite"), applicationVersion: "routine-migration-tests")
        store = RoutineStore(database: database)
    }
    deinit { try? database.databasePool.close(); try? FileManager.default.removeItem(at: root) }

    func count(_ table: String) throws -> Int64 { try database.tableRowCounts()[table] ?? -1 }
    func receipts() throws -> Int {
        try database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(StorageDocumentStore.documentTable) WHERE namespace = ? AND document_key = ?",
                             arguments: [RoutineHabitMigration.receiptNamespace, RoutineHabitMigration.receiptKey]) ?? 0
        }
    }
}

private let now = Date(timeIntervalSince1970: 1_790_000_000)
private func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))! }
private let day1 = DayIdentity(year: 2026, month: 10, day: 14)
private let day2 = DayIdentity(year: 2026, month: 10, day: 15)
private let day3 = DayIdentity(year: 2026, month: 10, day: 16)

private let meditate = JournalHabit(id: id(1), title: "Meditate", period: .evening, sortOrder: 0, createdAt: now)
private let screens = JournalHabit(id: id(2), catalogID: "screens_in_bed", title: "Screens in bed", period: .evening, sortOrder: 1, createdAt: now)
private let alcohol = JournalHabit(id: id(3), catalogID: "alcohol", isAutoFilled: true, title: "Alcohol", period: .evening, sortOrder: 2, createdAt: now)
private let trained = JournalHabit(id: id(4), catalogID: "trained_today", isAutoFilled: true, title: "Trained today", period: .today, sortOrder: 3, createdAt: now)
private let sick = JournalHabit(id: id(5), catalogID: "feeling_sick", title: "Feeling sick", period: .today, sortOrder: 4, createdAt: now)
private let oldHabit = JournalHabit(id: id(6), title: "Cold plunge", period: .evening, isArchived: true, sortOrder: 5, createdAt: now)
private let scale = JournalHabit(id: id(7), title: "Mood rating", period: .today, isYesNo: false, sortOrder: 6, createdAt: now)
private let allHabits = [meditate, screens, alcohol, trained, sick, oldHabit, scale]

private func answer(_ habit: JournalHabit, _ day: DayIdentity, _ answer: JournalHabitAnswer, _ origin: JournalAnswerOrigin = .person,
                    at seconds: TimeInterval = 100) -> JournalHabitResponse {
    JournalHabitResponse(habitID: habit.id, day: day, answer: answer, origin: origin, recordedAt: Date(timeIntervalSince1970: seconds))
}

private let history: [JournalHabitResponse] = [
    answer(meditate, day1, .yes), answer(meditate, day2, .no), answer(meditate, day3, .skipped),
    answer(screens, day1, .yes), answer(screens, day2, .no),
    answer(alcohol, day1, .no, .autoFill), answer(alcohol, day2, .yes),
    answer(trained, day1, .yes, .autoFill),
    answer(sick, day1, .yes), answer(oldHabit, day1, .yes), answer(scale, day1, .yes)
]

private func key(_ habit: JournalHabit) -> RuleKey { RoutineHabitMigration.ruleKey(forHabit: habit.id) }

struct RoutineHabitMigrationTests {
    @Test func activeHabitQuestionsBecomeVersionOneRulesInTheirJournalOrder() throws {
        let context = try MigrationTestDatabase()
        let outcome = try RoutineHabitMigration.run(database: context.database, habits: allHabits, responses: history, now: now)
        guard case .created(let protocolID, let rules, _, let skipped) = outcome else { Issue.record("not created: \(outcome)"); return }
        #expect(rules == 4)
        #expect(Set(skipped.map(\.reason)) == [.archived, .aboutTheDay, .notYesNo])

        let active = try #require(try context.store.activeProtocol())
        #expect(active.routineProtocol.id == protocolID && active.routineProtocol.name == "My protocol")
        #expect(active.routineProtocol.author == nil && active.routineProtocol.lineage == nil)
        let version = active.latestVersion
        #expect(version.number == 1 && version.createdAt == now && version.note == "Moved over from your Journal habits.")
        #expect(version.rules.map(\.key) == [key(meditate), key(screens), key(alcohol), key(trained)])
        #expect(version.rules.map(\.title) == ["Meditate", "No screens in bed", "No alcohol", "Trained today"])
        #expect(version.rules.map(\.source) == [.manual, .manual, .food, .fitness])
        #expect(version.rules.map(\.isEvening) == [true, true, true, false])
        #expect(version.rules.allSatisfy { $0.timeOfDayMinutes == nil })
        #expect(version.rules[0].target == RuleTarget(kind: .done, metric: "done"))
        #expect(try context.store.versions(protocolID: protocolID).count == 1)
        #expect(key(meditate).rawValue == "habit.00000000-0000-0000-0000-000000000001")
    }

    @Test func everyAnswerBecomesACheckOnItsRulesKeyAndDay() throws {
        let context = try MigrationTestDatabase()
        let outcome = try RoutineHabitMigration.run(database: context.database, habits: allHabits, responses: history, now: now)
        guard case .created(let protocolID, _, let checks, _) = outcome else { Issue.record("not created"); return }
        #expect(checks == 7, "seven answers on migrated rules; one was skipped")

        func rows(_ habit: JournalHabit) throws -> [RuleCheck] { try context.store.history(protocolID: protocolID, ruleKey: key(habit)) }
        let meditation = try rows(meditate)
        #expect(meditation.map(\.day) == [day1, day2] && meditation.map(\.state) == [.kept, .missed])
        #expect(meditation.map(\.source) == [.manual, .manual] && meditation.map(\.overriddenByPerson) == [false, true])
        #expect(meditation.allSatisfy { $0.version == 1 && $0.measuredValue == nil })

        let screen = try rows(screens)
        #expect(screen.map(\.state) == [.missed, .kept], "yes to \"Screens in bed\" breaks a rule that says no screens")
        #expect(screen.map(\.overriddenByPerson) == [true, false])

        let drink = try rows(alcohol)
        #expect(drink.map(\.state) == [.kept, .missed])
        #expect(drink.map(\.source) == [.food, .manual], "Food filled the first answer in; the person typed the second")
        #expect(drink.map(\.overriddenByPerson) == [false, true])

        let training = try rows(trained)
        #expect(training.map(\.state) == [.kept] && training.map(\.source) == [.fitness])

        #expect(try rows(sick).isEmpty && rows(oldHabit).isEmpty && rows(scale).isEmpty, "answers to skipped habits stay in the Journal only")
        #expect(try context.store.checks(protocolID: protocolID, day: day3).isEmpty, "a skipped answer makes no check")
        #expect(try context.store.checks(protocolID: protocolID, day: day1).count == 4)
    }

    @Test func noAnswerMeansNoCheckAndNoUnknownIsMade() throws {
        let context = try MigrationTestDatabase()
        let outcome = try RoutineHabitMigration.run(database: context.database, habits: [meditate, screens], responses: [answer(meditate, day1, .yes)], now: now)
        guard case .created(let protocolID, let rules, let checks, _) = outcome else { Issue.record("not created"); return }
        #expect(rules == 2 && checks == 1)
        #expect(try context.count("routine_check") == 1)
        #expect(try context.store.history(protocolID: protocolID, ruleKey: key(screens)).isEmpty)
    }

    @Test func aTwiceAnsweredDayKeepsOneCheck() throws {
        let plan = try RoutineHabitMigration.plan(habits: [meditate], responses: [answer(meditate, day1, .yes), answer(meditate, day1, .no)])
        #expect(plan.checks.count == 1)
    }

    // MARK: Auto-filled questions

    @Test func theFourAutoFilledQuestionsMapToTheirSourcesAndMetrics() throws {
        func rule(_ catalogID: String, title: String, period: JournalHabitPeriod, filled: Bool = true) throws -> ProtocolRule {
            let habit = JournalHabit(id: id(50), catalogID: catalogID, isAutoFilled: filled, title: title, period: period, createdAt: now)
            return try #require(try RoutineHabitMigration.plan(habits: [habit], responses: []).rules.first)
        }
        let alcohol = try rule("alcohol", title: "Alcohol", period: .evening)
        #expect(alcohol.source == .food && alcohol.group == .food && alcohol.title == "No alcohol")
        #expect(alcohol.target == RuleTarget(kind: .atMost, metric: "alcohol_drinks", value: 0, unit: "drinks"))

        let caffeine = try rule("late_caffeine", title: "Late caffeine", period: .evening)
        #expect(caffeine.source == .food && caffeine.title == "No caffeine after 14:00")
        #expect(caffeine.target == RuleTarget(kind: .atMost, metric: "last_caffeine_time", value: 839, unit: "min"))

        let training = try rule("trained_today", title: "Trained today", period: .today)
        #expect(training.source == .fitness && training.group == .fitness && training.title == "Trained today")
        #expect(training.target == RuleTarget(kind: .done, metric: "workout_minutes", unit: "min") && !training.isEvening)

        let meal = try rule("meal_within_two_hours", title: "Ate within 2 h of bed", period: .evening)
        #expect(meal.source == .manual && meal.title == "No meal in the last 2 hours before bed",
                "no metric holds the gap between the last meal and bed yet")

        // The same preset with the Journal's auto-fill off, for example after its question was edited, is a plain manual rule.
        let edited = try rule("alcohol", title: "Alcohol", period: .evening, filled: false)
        #expect(edited.source == .manual && edited.target == RuleTarget(kind: .done, metric: "done"))
    }

    @Test func theMappedTargetsGiveTheJournalsAnswerWhenEvaluated() throws {
        let zone = TimeZone(identifier: "Australia/Perth")!
        let clock = try #require(RoutineDayClock(day: day1, timeZone: zone))
        let habits = [alcohol, JournalHabit(id: id(8), catalogID: "late_caffeine", isAutoFilled: true, title: "Late caffeine", period: .evening, createdAt: now), trained]
        let planned = try RoutineHabitMigration.plan(habits: habits, responses: []).rules
        let byTitle = Dictionary(uniqueKeysWithValues: planned.map { ($0.title, $0) })
        let rules = [byTitle["No alcohol"]!, byTitle["No caffeine after 14:00"]!, byTitle["Trained today"]!]
        func outcome(_ rule: ProtocolRule, _ readings: [RoutineMetric: MetricReading]) throws -> CheckState {
            let sources = RoutineSourceSnapshots(food: RoutineSourceSnapshot(source: .food, readings: readings.filter { $0.key.source == .food }),
                                                 fitness: RoutineSourceSnapshot(source: .fitness, readings: readings.filter { $0.key.source == .fitness }))
            let context = try RoutineEvaluationContext(day: day1, now: clock.end, timeZone: zone)
            return RuleEvaluator.evaluate(rule, context: context, sources: sources).state
        }
        // Alcohol: any drink is a miss; a closed log with none is kept.
        #expect(try outcome(rules[0], [.alcoholDrinks: .measured(1)]) == .missed)
        #expect(try outcome(rules[0], [.alcoholDrinks: .measured(0)]) == .kept)
        // Late caffeine: the Journal counts 14:00 and later as late.
        #expect(try outcome(rules[1], [.lastCaffeineTime: .measured(839)]) == .kept)
        #expect(try outcome(rules[1], [.lastCaffeineTime: .measured(840)]) == .missed)
        #expect(try outcome(rules[1], [.lastCaffeineTime: .noEvents]) == .kept)
        // Trained today: a completed workout is a yes, and no workout is not a no.
        #expect(try outcome(rules[2], [.workoutMinutes: .measured(35)]) == .kept)
        #expect(try outcome(rules[2], [:]) == .unknown)
    }

    // MARK: Skips

    @Test func archivedContextAndNonYesNoHabitsAreLeftOut() throws {
        let plan = try RoutineHabitMigration.plan(habits: [oldHabit, sick, scale, meditate], responses: [answer(oldHabit, day1, .yes), answer(sick, day1, .no)])
        #expect(plan.rules.map(\.key) == [key(meditate)] && plan.checks.isEmpty)
        #expect(Dictionary(uniqueKeysWithValues: plan.skippedHabits.map { ($0.habitID, $0.reason) }) ==
                [oldHabit.id: .archived, sick.id: .aboutTheDay, scale.id: .notYesNo])
    }

    @Test func everyContextQuestionIsTheOnesAboutTheDayNotConduct() {
        #expect(RoutineHabitMigration.contextCatalogIDs ==
                ["feeling_sick", "warm_bedroom", "shared_bed", "away_from_home", "napped", "travel_day", "high_mental_stress"])
        #expect(RoutineHabitMigration.mappedCatalogIDs.count == 32)
    }

    // MARK: Once

    @Test func runningTwiceCreatesNothingNew() throws {
        let context = try MigrationTestDatabase()
        let first = try RoutineHabitMigration.run(database: context.database, habits: allHabits, responses: history, now: now)
        let counts = try context.database.tableRowCounts()
        let second = try RoutineHabitMigration.run(database: context.database, habits: allHabits, responses: history, now: now.addingTimeInterval(500))
        guard case .created = first else { Issue.record("first run did not create"); return }
        #expect(second == .alreadyDone)
        let after = try context.database.tableRowCounts()
        for table in RoutineStorageSchema.tableNames { #expect(after[table] == counts[table], "\(table)") }
        #expect(try context.receipts() == 1)
        #expect(try RoutineHabitMigration.isPending(database: context.database) == false)
    }

    @Test func aHabitArchivedOrAddedAfterwardsNeitherComesBackNorJoins() throws {
        let context = try MigrationTestDatabase()
        try RoutineHabitMigration.run(database: context.database, habits: [meditate, screens], responses: [], now: now)
        let archived = JournalHabit(id: meditate.id, title: "Meditate", period: .evening, isArchived: true, createdAt: now)
        let extra = JournalHabit(id: id(9), title: "Walk", period: .today, createdAt: now)
        #expect(try RoutineHabitMigration.run(database: context.database, habits: [archived, screens, extra], responses: [], now: now) == .alreadyDone)
        let rules = try #require(try context.store.activeProtocol()).latestVersion.rules
        #expect(rules.map(\.key) == [key(meditate), key(screens)], "the Journal archive is not a protocol edit, and nothing new is added")
    }

    @Test func aProtocolThatAlreadyExistsIsNotReplacedOrBroughtBackAfterADelete() throws {
        let context = try MigrationTestDatabase()
        let own = RoutineProtocol(name: "Sleep first", createdAt: now)
        try context.store.createProtocol(own, rules: [ProtocolRule(key: "walk", title: "Walk")])
        #expect(try RoutineHabitMigration.run(database: context.database, habits: allHabits, responses: history, now: now) == .protocolExists)
        #expect(try context.store.protocols().map(\.name) == ["Sleep first"])
        try context.store.deleteProtocol(id: own.id)
        #expect(try RoutineHabitMigration.run(database: context.database, habits: allHabits, responses: history, now: now) == .alreadyDone,
                "deleting a protocol on purpose is not a reason to build one from the Journal")
        #expect(try context.count("routine_protocol") == 0)
    }

    @Test func withNothingToMoveNothingIsRecordedAndALaterHabitStillMoves() throws {
        let context = try MigrationTestDatabase()
        #expect(try RoutineHabitMigration.run(database: context.database, habits: [], responses: [], now: now) == .nothingToMigrate)
        #expect(try RoutineHabitMigration.run(database: context.database, habits: [oldHabit, sick], responses: [], now: now) == .nothingToMigrate)
        #expect(try context.receipts() == 0 && context.count("routine_protocol") == 0 && RoutineHabitMigration.isPending(database: context.database))
        let outcome = try RoutineHabitMigration.run(database: context.database, habits: [meditate], responses: [], now: now)
        guard case .created(_, let rules, _, _) = outcome else { Issue.record("not created"); return }
        #expect(rules == 1)
    }

    @Test func aFailureMidwayLeavesNothingAndTheNextRunCompletes() throws {
        let context = try MigrationTestDatabase()
        try context.database.write { db in
            try db.execute(sql: "CREATE TRIGGER fail_check BEFORE INSERT ON routine_check BEGIN SELECT RAISE(ABORT, 'disk full'); END")
        }
        #expect(throws: (any Error).self) {
            try RoutineHabitMigration.run(database: context.database, habits: allHabits, responses: history, now: now)
        }
        for table in RoutineStorageSchema.tableNames { #expect(try context.count(table) == 0, "\(table) kept a partial version 1") }
        #expect(try context.receipts() == 0)
        try context.database.write { db in try db.execute(sql: "DROP TRIGGER fail_check") }
        let retry = try RoutineHabitMigration.run(database: context.database, habits: allHabits, responses: history, now: now)
        guard case .created(_, let rules, let checks, _) = retry else { Issue.record("retry did not create"); return }
        let receipts = try context.receipts()
        #expect(rules == 4 && checks == 7 && receipts == 1)
    }

    // MARK: Later

    @Test func aVersionBumpKeepsTheMigratedHistoryOnTheSameRuleKeys() throws {
        let context = try MigrationTestDatabase()
        let outcome = try RoutineHabitMigration.run(database: context.database, habits: allHabits, responses: history, now: now)
        guard case .created(let protocolID, _, _, _) = outcome else { Issue.record("not created"); return }
        let first = try #require(try context.store.version(protocolID: protocolID, number: 1))
        let renamed = first.rules.map { rule in
            rule.key == key(meditate)
                ? ProtocolRule(key: rule.key, title: "Meditate for ten minutes", group: rule.group, target: rule.target, source: rule.source, isEvening: true)
                : rule
        }
        let second = try context.store.saveVersion(protocolID: protocolID, rules: renamed + [ProtocolRule(key: "walk", title: "Walk")], at: now.addingTimeInterval(86_400))
        #expect(second.number == 2 && second.rule(for: key(meditate))?.title == "Meditate for ten minutes")
        let day4 = DayIdentity(year: 2026, month: 10, day: 17)
        try context.store.recordCheck(RuleCheck(ruleKey: key(meditate), day: day4, version: 2, state: .kept, source: .manual,
                                                recordedAt: now.addingTimeInterval(90_000)), protocolID: protocolID)
        let past = try context.store.history(protocolID: protocolID, ruleKey: key(meditate))
        #expect(past.map(\.day) == [day1, day2, day4] && past.map(\.version) == [1, 1, 2])
        #expect(try context.store.version(protocolID: protocolID, number: 1) == first, "version 1 is untouched")
    }

    @Test func deletingAllDataEmptiesTheRoutineTablesAndTheMigrationStartsFresh() throws {
        let context = try MigrationTestDatabase()
        try RoutineHabitMigration.run(database: context.database, habits: allHabits, responses: history, now: now)
        try context.database.deleteAllAccountData()
        let counts = try context.database.tableRowCounts()
        for table in RoutineStorageSchema.tableNames { #expect(counts[table] == 0, "\(table)") }
        #expect(try context.receipts() == 0 && RoutineHabitMigration.isPending(database: context.database))
        // The Journal is wiped too, so there is nothing to move until the person adds a habit.
        #expect(try RoutineHabitMigration.run(database: context.database, habits: [], responses: [], now: now) == .nothingToMigrate)
        #expect(try context.store.activeProtocol() == nil)
        let again = try RoutineHabitMigration.run(database: context.database, habits: [meditate], responses: [], now: now)
        guard case .created = again else { Issue.record("a new habit should move once"); return }
    }
}
