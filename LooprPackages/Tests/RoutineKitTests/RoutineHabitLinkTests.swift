import DomainKit
import Foundation
import RoutineKit
import StorageKit
import Testing

// ICP R1-UPG-1, R1-UPG-11, R1-UPG-13, R1-OPT-7, R1-OPT-9: a habit that became a rule lives in one place, the history of a
// moved protocol counts from its first answer, and every surface words and counts a rule the same way.

private final class LinkTestDatabase {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("RoutineHabitLinkTests-\(UUID().uuidString)")
    let database: StorageDatabase
    let store: RoutineStore
    init() throws {
        database = try StorageDatabase(url: root.appendingPathComponent("routine.sqlite"), applicationVersion: "routine-link-tests")
        store = RoutineStore(database: database)
    }
    deinit { try? database.databasePool.close(); try? FileManager.default.removeItem(at: root) }
}

private let now = Date(timeIntervalSince1970: 1_790_000_000)
private func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))! }
private let march = DayIdentity(year: 2026, month: 3, day: 12)
private let october = DayIdentity(year: 2026, month: 10, day: 14)

private let meditate = JournalHabit(id: id(1), title: "Meditate", period: .evening, sortOrder: 0, createdAt: now)
private let alcohol = JournalHabit(id: id(3), catalogID: "alcohol", title: "Alcohol", period: .evening, sortOrder: 1, createdAt: now)
private let sick = JournalHabit(id: id(5), catalogID: "feeling_sick", title: "Feeling sick", period: .today, sortOrder: 2, createdAt: now)

private func check(_ state: CheckState, source: CheckSource = .manual, person: Bool = false,
                   key: RuleKey = "habit.x") throws -> RuleCheck {
    try RuleCheck(ruleKey: key, day: october, version: 1, state: state, source: source, overriddenByPerson: person, recordedAt: now)
}

struct RoutineHabitLinkTests {
    // MARK: Which habit a rule came from

    @Test func aHabitRuleKeyLeadsBackToItsHabit() {
        let key = RoutineHabitMigration.ruleKey(forHabit: meditate.id)
        #expect(RoutineHabitMigration.habitID(forRuleKey: key) == meditate.id)
        #expect(RoutineHabitMigration.habitID(forRuleKey: "screens-off") == nil)
        #expect(RoutineHabitMigration.habitID(forRuleKey: "habit.not-a-uuid") == nil)
    }

    @Test func everyVersionsHabitRulesCountSoARemovedRuleDoesNotBringItsQuestionBack() throws {
        let context = try LinkTestDatabase()
        _ = try RoutineHabitMigration.run(database: context.database, habits: [meditate, alcohol, sick], responses: [], now: now)
        #expect(try RoutineHabitMigration.habitIDsWithRules(store: context.store) == [meditate.id, alcohol.id],
                "Feeling sick is about the day and stays a Journal question")
        let active = try #require(try context.store.activeProtocol())
        let kept = active.latestVersion.rules.filter { $0.key != RoutineHabitMigration.ruleKey(forHabit: meditate.id) }
        _ = try context.store.saveEdit(protocolID: active.routineProtocol.id, rules: kept, at: now.addingTimeInterval(60))
        #expect(try RoutineHabitMigration.habitIDsWithRules(store: context.store) == [meditate.id, alcohol.id])
    }

    // MARK: One answer, one meaning

    @Test func aKeptRuleIsYesForAHabitToDoAndNoForAHabitToAvoid() {
        #expect(RoutineHabitMigration.isWrittenAsAvoid(alcohol))
        #expect(!RoutineHabitMigration.isWrittenAsAvoid(meditate))
        #expect(RoutineHabitMigration.journalAnswer(kept: true, avoid: false) == .yes)
        #expect(RoutineHabitMigration.journalAnswer(kept: false, avoid: false) == .no)
        #expect(RoutineHabitMigration.journalAnswer(kept: true, avoid: true) == .no, "No alcohol kept means no drink")
        #expect(RoutineHabitMigration.journalAnswer(kept: false, avoid: true) == .yes)
    }

    @Test func aPersonsDecisionOnTheRuleBecomesTheirJournalAnswer() throws {
        #expect(RoutineHabitMigration.journalChange(after: try check(.kept), avoid: true, current: nil) == .set(.no))
        #expect(RoutineHabitMigration.journalChange(after: try check(.missed), avoid: false, current: nil) == .set(.no))
        // An override over Food is the person's too, and it replaces what the Journal filled in.
        #expect(RoutineHabitMigration.journalChange(after: try check(.missed, source: .manual, person: true), avoid: true,
                                                    current: (.no, .autoFill)) == .set(.yes))
        // The Journal already says it.
        #expect(RoutineHabitMigration.journalChange(after: try check(.kept), avoid: false, current: (.yes, .person)) == .keep)
    }

    @Test func undoTakesThePersonsAnswerAwayButLeavesSkipsAndAutoFill() throws {
        let pending = try check(.pending)
        #expect(RoutineHabitMigration.journalChange(after: pending, avoid: false, current: (.yes, .person)) == .clear)
        #expect(RoutineHabitMigration.journalChange(after: nil, avoid: false, current: (.no, .person)) == .clear)
        #expect(RoutineHabitMigration.journalChange(after: pending, avoid: false, current: (.skipped, .person)) == .keep)
        #expect(RoutineHabitMigration.journalChange(after: pending, avoid: false, current: (.yes, .autoFill)) == .keep)
        #expect(RoutineHabitMigration.journalChange(after: pending, avoid: false, current: nil) == .keep)
        // A source deciding the rule is not the person: the Journal's own auto-fill answers that day.
        let food = try check(.kept, source: .food)
        #expect(RoutineHabitMigration.journalChange(after: food, avoid: true, current: (.no, .autoFill)) == .keep)
    }

    @Test func movingAndAnsweringAgainKeepsEveryBuild21Answer() throws {
        let context = try LinkTestDatabase()
        let responses = [JournalHabitResponse(habitID: alcohol.id, day: march, answer: .yes, origin: .person, recordedAt: now),
                         JournalHabitResponse(habitID: alcohol.id, day: october, answer: .no, origin: .person, recordedAt: now)]
        _ = try RoutineHabitMigration.run(database: context.database, habits: [alcohol], responses: responses, now: now)
        let active = try #require(try context.store.activeProtocol())
        let key = RoutineHabitMigration.ruleKey(forHabit: alcohol.id)
        let history = try context.store.history(protocolID: active.routineProtocol.id, ruleKey: key)
        #expect(history.map(\.state) == [.missed, .kept], "Yes to alcohol is a slip of No alcohol, and no is kept")
        // The rule's answer, written back, means what the Journal answer meant.
        for item in history {
            let back = RoutineHabitMigration.journalAnswer(kept: item.state == .kept, avoid: RoutineHabitMigration.isWrittenAsAvoid(alcohol))
            #expect(back == responses.first { $0.day == item.day }?.answer)
        }
    }

    // MARK: History starts at the first answer

    @Test func theFirstCheckDayIsTheEarliestMovedAnswer() throws {
        let context = try LinkTestDatabase()
        let responses = [JournalHabitResponse(habitID: meditate.id, day: october, answer: .yes, origin: .person, recordedAt: now),
                         JournalHabitResponse(habitID: meditate.id, day: march, answer: .no, origin: .person, recordedAt: now)]
        _ = try RoutineHabitMigration.run(database: context.database, habits: [meditate], responses: responses, now: now)
        let active = try #require(try context.store.activeProtocol())
        #expect(try context.store.firstCheckDay(protocolID: active.routineProtocol.id) == march)
        #expect(try context.store.firstCheckDay(protocolID: ProtocolID()) == nil)
    }

    // MARK: Wording

    @Test func aRuleToAvoidIsAskedSoThatYesMeansKept() {
        let british = Locale(identifier: "en_GB")
        #expect(ProtocolRule(key: "a", title: "No alcohol").checkInQuestion(locale: british) == "Did you keep to no alcohol?")
        #expect(ProtocolRule(key: "b", title: "Screens off by 21:45").checkInQuestion(locale: british) == "Screens off by 21:45?")
        #expect(ProtocolRule(key: "c", title: "Magnesium?").checkInQuestion(locale: british) == "Magnesium?")
        #expect(ProtocolRule(key: "d", title: "Nothing after dinner").isWrittenAsAvoid == false, "Only the word No or Not counts")
        #expect(ProtocolRule(key: "e", title: "Not on the phone in bed").isWrittenAsAvoid)
    }

    @Test func theTitleShowsItsTimeInTheLocalesClock() {
        let rule = ProtocolRule(key: "a", title: "No caffeine after 14:00")
        #expect(rule.displayTitle(locale: Locale(identifier: "en_GB")) == "No caffeine after 14:00")
        let american = rule.displayTitle(locale: Locale(identifier: "en_US"))
        #expect(american.hasPrefix("No caffeine after 2:00"), "\(american)")
        #expect(!american.contains("14:00"))
    }

    @Test func theOneTimeInATitleMovesWithItsWheel() {
        #expect(RoutineRuleTitle.shiftingTime(in: "Screens off by 21:45", by: 15) == "Screens off by 22:00")
        #expect(RoutineRuleTitle.shiftingTime(in: "In bed by 23:30", by: 45) == "In bed by 00:15", "Wraps past midnight")
        #expect(RoutineRuleTitle.shiftingTime(in: "No caffeine after 14:00", by: -60) == "No caffeine after 13:00")
        #expect(RoutineRuleTitle.shiftingTime(in: "Stretch", by: 30) == "Stretch")
        #expect(RoutineRuleTitle.shiftingTime(in: "Between 21:00 and 22:00", by: 30) == "Between 21:00 and 22:00",
                "Two times: no telling which one moved")
    }

    @Test func theTitlesTimeStandsForTheTargetOrTheRulesOwnTime() {
        let bed = ProtocolRule(key: "bed", title: "In bed by 22:30",
                               target: RuleTarget(kind: .atMost, metric: RoutineMetric.inBedTime.rawValue, value: 1_350),
                               timeOfDayMinutes: 21 * 60 + 45, source: .band, isEvening: true)
        #expect(bed.titleMinute == 22 * 60 + 30)
        let screens = ProtocolRule(key: "screens", title: "Screens off by 21:45", timeOfDayMinutes: 21 * 60 + 45)
        #expect(screens.titleMinute == 21 * 60 + 45)
        #expect(ProtocolRule(key: "s", title: "Stretch").titleMinute == nil)
    }

    // MARK: Counting

    @Test func aDayCountsKeptRulesAndTheRulesThePersonStillAnswers() {
        let manual = ProtocolRule(key: "a", title: "Stretch")
        let evening = ProtocolRule(key: "b", title: "In bed", source: .band, isEvening: true)
        let food = ProtocolRule(key: "c", title: "No alcohol", source: .food)
        let count = RoutineDayCount.make([(manual, .pending), (evening, nil), (food, .pending), (manual, .kept), (manual, .unknown)])
        #expect(count.kept == 1)
        #expect(count.total == 5)
        #expect(count.toAnswer == 2, "Food's own rule is Food's to answer, and an unknown rule is not asked")
        #expect(count.keptText == "1 of 5 rules kept")
        #expect(count.toAnswerText == "2 rules left to answer")
        #expect(RoutineDayCount(kept: 0, total: 1, toAnswer: 0).toAnswerText == "All answered")
    }
}
