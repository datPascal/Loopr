import DomainKit
import Foundation
import JournalKit
import RoutineKit
import StorageKit
import Testing
@testable import Loopr

private let now = Date(timeIntervalSince1970: 1_790_000_000)
private let zoneID = "Australia/Perth"
private let day1 = DayIdentity(year: 2026, month: 10, day: 14)
private let day2 = DayIdentity(year: 2026, month: 10, day: 15)

private func hid(_ n: Int) -> HabitID { HabitID(rawValue: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!) }

private func preset(_ catalogID: String, _ n: Int, sortOrder: Int = 0, archived: Bool = false) -> HabitDefinition {
    let item = HabitCatalog.byID[catalogID]!
    return HabitDefinition(id: hid(n), source: .preset(catalogID: catalogID), name: item.name, question: item.question,
                           sortOrder: sortOrder, archivedAt: archived ? now : nil, createdAt: now)
}

private func custom(_ name: String, _ n: Int, sortOrder: Int = 0, period: HabitQuestionPeriod? = nil) -> HabitDefinition {
    HabitDefinition(id: hid(n), source: .custom, name: name, question: "\(name)?", sortOrder: sortOrder, createdAt: now,
                    questionPeriod: period)
}

private func response(_ habit: HabitDefinition, _ day: DayIdentity, _ answer: HabitAnswer, _ source: HabitResponseSource = .morningCheckIn) -> HabitResponse {
    var provenance: JournalAutoFillProvenance?
    if source == .autoFill, case .preset(let id) = habit.source, let question = JournalAutoFillQuestion(rawValue: id) {
        let record = JournalSourceRecord(id: question.domain == .train ? "workout:1" : "food-completion:1", domain: question.domain,
                                         title: "Source", occurredAt: now, updatedAt: now)
        provenance = JournalAutoFillProvenance(question: question, records: [record], summary: "Source")
    }
    return HabitResponse(habitID: habit.id, behaviorDay: day, behaviorTimeZoneID: zoneID, answer: answer, firstAnsweredAt: now,
                         updatedAt: now.addingTimeInterval(60), firstAnswerSource: source, lastUpdateSource: source, autoFillProvenance: provenance)
}

private final class MigrationRig {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("RoutineJournalMigration-\(UUID())")
    let database: StorageDatabase
    let habits: SQLiteHabitRepository
    let routine: RoutineStore
    init() throws {
        database = try StorageDatabase(url: root.appendingPathComponent("loopr.sqlite"), applicationVersion: "test")
        habits = try SQLiteHabitRepository(database: database)
        routine = RoutineStore(database: database)
    }
    deinit { try? database.databasePool.close(); try? FileManager.default.removeItem(at: root) }
}

@MainActor struct RoutineJournalMigrationTests {
    @Test func theMigrationTableCoversExactlyTheJournalCatalog() {
        #expect(RoutineHabitMigration.mappedCatalogIDs == Set(HabitCatalog.items.map(\.id)))
        for question in JournalAutoFillQuestion.allCases {
            let definition = preset(question.rawValue, 1)
            let habit = RoutineJournalMigration.habit(definition)
            #expect(habit.isAutoFilled && habit.catalogID == question.rawValue, "\(question)")
        }
    }

    @Test func aDefinitionMapsToTheMigrationsHabit() {
        let alcohol = RoutineJournalMigration.habit(preset("alcohol", 1, sortOrder: 3))
        #expect(alcohol.id == hid(1).rawValue && alcohol.catalogID == "alcohol" && alcohol.isAutoFilled)
        #expect(alcohol.period == .evening && alcohol.sortOrder == 3 && alcohol.isYesNo && !alcohol.isArchived)

        let caffeine = RoutineJournalMigration.habit(preset("late_caffeine", 2))
        #expect(caffeine.title == "Caffeine after 14:00", "the title the check-in shows")

        #expect(RoutineJournalMigration.habit(preset("trained_today", 3)).period == .today)
        #expect(RoutineJournalMigration.habit(preset("sauna", 4)).isAutoFilled == false)
        #expect(RoutineJournalMigration.habit(preset("sauna", 4, archived: true)).isArchived)

        var edited = preset("alcohol", 5)
        edited.question = "Had more than one drink?"
        let editedHabit = RoutineJournalMigration.habit(edited)
        #expect(editedHabit.catalogID == nil && !editedHabit.isAutoFilled, "an edited preset is treated as a custom habit")

        var moved = preset("alcohol", 6)
        moved.questionPeriod = .today
        let movedHabit = RoutineJournalMigration.habit(moved)
        #expect(movedHabit.catalogID == "alcohol" && !movedHabit.isAutoFilled && movedHabit.period == .today,
                "the Journal stops filling it in, so the rule stays manual")

        let own = RoutineJournalMigration.habit(custom("Walk", 7, period: .today))
        #expect(own.catalogID == nil && own.period == .today && own.title == "Walk")
    }

    @Test func answersKeepTheirOrigin() {
        let alcohol = preset("alcohol", 1)
        let record = HabitDayRecord(behaviorDay: day1, behaviorTimeZoneID: zoneID, responses: [
            response(alcohol, day1, .no, .autoFill)
        ], createdAt: now)
        let mapped = RoutineJournalMigration.responses([record])
        #expect(mapped == [JournalHabitResponse(habitID: hid(1).rawValue, day: day1, answer: .no, origin: .autoFill,
                                                recordedAt: now.addingTimeInterval(60))])
        let typed = HabitDayRecord(behaviorDay: day2, behaviorTimeZoneID: zoneID, responses: [
            response(alcohol, day2, .skipped), response(custom("Walk", 2), day2, .yes, .historyEdit)
        ], createdAt: now)
        #expect(RoutineJournalMigration.responses([typed]).map(\.origin) == [.person, .person])
        #expect(RoutineJournalMigration.responses([typed]).map(\.answer) == [.skipped, .yes])
    }

    @Test func theJournalMovesIntoVersionOneOnceAndStaysIntact() async throws {
        let rig = try MigrationRig()
        let alcohol = preset("alcohol", 1, sortOrder: 0), screens = preset("screens_in_bed", 2, sortOrder: 1)
        let walk = custom("Walk", 3, sortOrder: 2), sick = preset("feeling_sick", 4, sortOrder: 3)
        let old = preset("sauna", 5, sortOrder: 4, archived: true)
        for definition in [alcohol, screens, walk, sick, old] { try await rig.habits.saveDefinition(definition) }
        try await rig.habits.saveDayRecord(HabitDayRecord(behaviorDay: day1, behaviorTimeZoneID: zoneID, responses: [
            response(alcohol, day1, .no, .autoFill), response(screens, day1, .yes), response(walk, day1, .yes),
            response(sick, day1, .yes), response(old, day1, .yes)
        ], createdAt: now))
        let definitionsBefore = try await rig.habits.definitions(includeArchived: true)
        let recordsBefore = try await rig.habits.dayRecords()

        let outcome = try #require(await RoutineJournalMigration.runOnce(database: rig.database, habits: rig.habits, now: now))
        guard case .created(let protocolID, let rules, let checks, let skipped) = outcome else { Issue.record("not created: \(outcome)"); return }
        #expect(rules == 3 && checks == 3 && skipped.count == 2)

        let version = try #require(try rig.routine.latestVersion(protocolID: protocolID))
        #expect(version.rules.map(\.title) == ["No alcohol", "No screens in bed", "Walk"])
        #expect(version.rules.map(\.source) == [.food, .manual, .manual])
        let alcoholChecks = try rig.routine.history(protocolID: protocolID, ruleKey: RoutineHabitMigration.ruleKey(forHabit: alcohol.id.rawValue))
        #expect(alcoholChecks.map(\.state) == [.kept] && alcoholChecks.map(\.source) == [.food])
        let screenChecks = try rig.routine.history(protocolID: protocolID, ruleKey: RoutineHabitMigration.ruleKey(forHabit: screens.id.rawValue))
        #expect(screenChecks.map(\.state) == [.missed])

        #expect(try await rig.habits.definitions(includeArchived: true) == definitionsBefore)
        #expect(try await rig.habits.dayRecords() == recordsBefore, "the Journal keeps every answer")

        // A second launch changes nothing, even after the person archives a habit in the Journal.
        try await rig.habits.setArchived(true, habitID: walk.id, at: now)
        #expect(await RoutineJournalMigration.runOnce(database: rig.database, habits: rig.habits, now: now.addingTimeInterval(9)) == .alreadyDone)
        #expect(try rig.routine.latestVersion(protocolID: protocolID) == version)
        #expect(try rig.routine.protocols().count == 1)
    }

    @Test func withoutActiveHabitsTheMigrationWaitsAndAJournalWipeStartsItAgain() async throws {
        let rig = try MigrationRig()
        #expect(await RoutineJournalMigration.runOnce(database: rig.database, habits: rig.habits, now: now) == .nothingToMigrate)
        try await rig.habits.saveDefinition(custom("Walk", 1))
        guard case .created = try #require(await RoutineJournalMigration.runOnce(database: rig.database, habits: rig.habits, now: now)) else {
            Issue.record("a new habit should move"); return
        }
        try rig.database.deleteAllAccountData()
        #expect(try rig.routine.activeProtocol() == nil)
        #expect(await RoutineJournalMigration.runOnce(database: rig.database, habits: rig.habits, now: now) == .nothingToMigrate,
                "the wipe removed the Journal too, so there is nothing to move until a habit exists")
        #expect(try rig.routine.protocols().isEmpty)
    }
}
