import AnalyticsKit
import DataKit
import DomainKit
import NotificationKit
import RoutineKit
import StorageKit
import TrainKit
import XCTest

final class LabTestsDueTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }()
    /// 20 October 2026, 10:00 in Berlin.
    private let now = Date(timeIntervalSince1970: 1_792_483_200)

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 9))!
    }

    private func rule(_ key: String, _ title: String, every: Int, _ unit: RuleCadence.Unit, group: RuleGroup = .tests,
                      metric: String? = nil) -> ProtocolRule {
        ProtocolRule(key: RuleKey(rawValue: key), title: title, group: group,
                     target: RuleTarget(kind: .done, metric: metric), cadence: RuleCadence(unit: unit, every: every))
    }

    private var rules: [ProtocolRule] {
        [rule("blood-test", "Blood test every 3 months", every: 3, .month),
         rule("grip-retest", "Grip strength retest", every: 1, .month),
         rule("balance-retest", "One-leg balance retest", every: 1, .month),
         rule("dentist", "Dentist check", every: 6, .month),
         rule("skin", "Skin check", every: 1, .month, metric: nil),
         rule("sauna-clean", "Descale the sauna", every: 2, .week),
         ProtocolRule(key: "no-cadence", title: "Weigh in", group: .tests),
         rule("zone2", "Zone 2", every: 1, .week, group: .fitness)]
    }

    func testOnlyTestsGroupRulesWithACadenceCount() {
        let summary = LabTestsDueBuilder.make(LabTestsDueInputs(rules: rules), now: now, calendar: calendar)
        XCTAssertEqual(Set(summary.all.map(\.ruleKey.rawValue)),
                       ["blood-test", "grip-retest", "balance-retest", "dentist", "skin", "sauna-clean"])
    }

    func testRulesAreReadByKeyTitleAndMetric() {
        XCTAssertEqual(LabTestKind.classify(rule("blood-test", "x", every: 1, .month)), .bloodTest)
        XCTAssertEqual(LabTestKind.classify(rule("a", "Blood test every 6 months", every: 1, .month)), .bloodTest)
        XCTAssertEqual(LabTestKind.classify(rule("a", "Blood pressure", every: 1, .week)), .custom)
        XCTAssertEqual(LabTestKind.classify(rule("a", "Check", every: 1, .month, metric: "capacity_grip")), .grip)
        XCTAssertEqual(LabTestKind.classify(rule("a", "Check", every: 1, .month, metric: "capacity_one_leg_balance")), .balance)
        XCTAssertEqual(LabTestKind.classify(rule("a", "Dentist visit", every: 6, .month)), .dentist)
        XCTAssertEqual(LabTestKind.classify(rule("a", "Skin check", every: 6, .month)), .skin)
        XCTAssertEqual(LabTestKind.classify(rule("a", "Sauna", every: 6, .month)), .custom)
    }

    func testTheBloodTestIsDueFromTheLastLabReportPlusTheCadence() {
        let inputs = LabTestsDueInputs(rules: [rules[0]], latestReportDate: date(2026, 7, 10))
        let test = LabTestsDueBuilder.make(inputs, now: now, calendar: calendar).all[0]
        XCTAssertEqual(test.lastDone, date(2026, 7, 10))
        XCTAssertEqual(test.lastDoneSource, .labReport)
        XCTAssertEqual(calendar.dateComponents([.year, .month, .day], from: test.nextDue!), DateComponents(year: 2026, month: 10, day: 10))
        XCTAssertEqual(test.status, .due)
        XCTAssertEqual(test.title, "Blood test")
        XCTAssertEqual(test.cadenceText, "Every 3 months")
    }

    func testAReportThisWeekPushesTheNextBloodTestOutOfTheDueList() {
        let inputs = LabTestsDueInputs(rules: [rules[0]], latestReportDate: date(2026, 10, 15))
        let summary = LabTestsDueBuilder.make(inputs, now: now, calendar: calendar)
        XCTAssertTrue(summary.due.isEmpty)
        XCTAssertEqual(summary.upcoming.map(\.status), [.upcoming])
        XCTAssertEqual(calendar.dateComponents([.year, .month, .day], from: summary.upcoming[0].nextDue!),
                       DateComponents(year: 2027, month: 1, day: 15))
    }

    func testGripAndBalanceReadTheirCapacityResults() {
        let inputs = LabTestsDueInputs(rules: [rules[1], rules[2]], latestGripDate: date(2026, 9, 1), latestBalanceDate: date(2026, 10, 12))
        let summary = LabTestsDueBuilder.make(inputs, now: now, calendar: calendar)
        XCTAssertEqual(summary.due.map(\.ruleKey.rawValue), ["grip-retest"])
        XCTAssertEqual(summary.due[0].lastDoneSource, .capacityResult)
        XCTAssertEqual(summary.upcoming.map(\.ruleKey.rawValue), ["balance-retest"])
        XCTAssertEqual(summary.upcoming[0].title, "Balance test")
    }

    func testDentistSkinAndCustomTestsUseTheTick() {
        let inputs = LabTestsDueInputs(rules: [rules[3], rules[4], rules[5]], ticks: [
            "dentist": date(2026, 3, 1), "skin": date(2026, 10, 1)])
        let summary = LabTestsDueBuilder.make(inputs, now: now, calendar: calendar)
        XCTAssertEqual(summary.due.map(\.ruleKey.rawValue), ["dentist", "sauna-clean"])
        XCTAssertEqual(summary.due[0].lastDoneSource, .protocolTick)
        XCTAssertEqual(summary.due[0].status, .due)
        XCTAssertEqual(summary.due[1].status, .notDoneYet)
        XCTAssertNil(summary.due[1].nextDue)
        XCTAssertEqual(summary.upcoming.map(\.ruleKey.rawValue), ["skin"])
        XCTAssertEqual(summary.due[1].title, "Descale the sauna")
    }

    func testATickNewerThanTheSourceWinsAndAnOlderOneDoesNot() {
        let rule = rules[0]
        let newer = LabTestsDueBuilder.make(LabTestsDueInputs(rules: [rule], latestReportDate: date(2026, 1, 5), ticks: ["blood-test": date(2026, 10, 1)]),
                                            now: now, calendar: calendar).all[0]
        XCTAssertEqual(newer.lastDoneSource, .protocolTick)
        let older = LabTestsDueBuilder.make(LabTestsDueInputs(rules: [rule], latestReportDate: date(2026, 10, 1), ticks: ["blood-test": date(2026, 1, 5)]),
                                            now: now, calendar: calendar).all[0]
        XCTAssertEqual(older.lastDoneSource, .labReport)
    }

    func testATestWithNoResultYetIsDueWithoutADate() {
        let test = LabTestsDueBuilder.make(LabTestsDueInputs(rules: [rules[0]]), now: now, calendar: calendar).all[0]
        XCTAssertEqual(test.status, .notDoneYet)
        XCTAssertNil(test.lastDone)
        XCTAssertNil(test.lastDoneSource)
        XCTAssertNil(test.nextDue)
    }

    func testATestDueTodayIsDueAndDueTestsAreOrderedByDate() {
        let today = LabTestsDueBuilder.make(LabTestsDueInputs(rules: [rules[0]], latestReportDate: date(2026, 7, 20)), now: now, calendar: calendar)
        XCTAssertEqual(today.due.count, 1)
        let both = LabTestsDueBuilder.make(LabTestsDueInputs(rules: [rules[0], rules[1]], latestReportDate: date(2026, 5, 1),
                                                             latestGripDate: date(2026, 9, 1)), now: now, calendar: calendar)
        XCTAssertEqual(both.due.map(\.ruleKey.rawValue), ["blood-test", "grip-retest"])
    }

    func testCadenceTextHandlesEveryUnitAndCount() {
        XCTAssertEqual(LabTestDue.cadenceText(RuleCadence(unit: .month, every: 1)), "Every month")
        XCTAssertEqual(LabTestDue.cadenceText(RuleCadence(unit: .week, every: 2)), "Every 2 weeks")
        XCTAssertEqual(LabTestDue.cadenceText(RuleCadence(unit: .day, every: 10)), "Every 10 days")
        let next = LabTestsDueBuilder.next(after: date(2026, 1, 31), cadence: RuleCadence(unit: .month, every: 1), calendar: calendar)
        XCTAssertEqual(calendar.dateComponents([.month, .day], from: next!), DateComponents(month: 2, day: 28))
    }

    // MARK: Stores

    func testLoadReadsLabReportsCapacityResultsAndTicksFromTheStores() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LabTestsDueTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try StorageDatabase(url: root.appendingPathComponent("tests.sqlite"), applicationVersion: "lab-due-tests")
        defer { try? database.databasePool.close() }
        let routine = RoutineStore(database: database)
        let labs = LabStore(database: database)
        let capacity = CapacityStore(database: database)
        let created = date(2026, 1, 1)

        XCTAssertEqual(try LabTestsDueBuilder.load(routine: routine, labs: labs, capacity: capacity, now: now, calendar: calendar), .empty)

        let routineProtocol = RoutineProtocol(name: "Fitness for the long run", createdAt: created)
        try routine.createProtocol(routineProtocol, rules: rules)
        let report = LabReport(collectedAt: date(2026, 7, 10), timeZoneIdentifier: "Europe/Berlin", labName: "Lab", source: .typed, createdAt: created)
        try labs.saveReport(report, values: [])
        try capacity.save(try CapacityResult(kind: .grip, value: 40, side: .left, recordedAt: date(2026, 10, 1),
                                             timeZoneIdentifier: "Europe/Berlin"))
        try LabTestsDueBuilder.markDone(ruleKey: "dentist", routine: routine, now: date(2026, 5, 2), calendar: calendar)

        let summary = try LabTestsDueBuilder.load(routine: routine, labs: labs, capacity: capacity, now: now, calendar: calendar)
        let byKey = Dictionary(uniqueKeysWithValues: summary.all.map { ($0.ruleKey.rawValue, $0) })
        XCTAssertEqual(Set(byKey.keys), ["blood-test", "grip-retest", "balance-retest", "dentist", "skin", "sauna-clean"])
        XCTAssertEqual(byKey["blood-test"]?.lastDoneSource, .labReport)
        XCTAssertEqual(byKey["blood-test"]?.status, .due)
        XCTAssertEqual(byKey["grip-retest"]?.lastDoneSource, .capacityResult)
        XCTAssertEqual(byKey["grip-retest"]?.status, .upcoming)
        XCTAssertEqual(byKey["balance-retest"]?.status, .notDoneYet)
        XCTAssertEqual(byKey["dentist"]?.lastDoneSource, .protocolTick)
        XCTAssertEqual(byKey["dentist"]?.status, .upcoming)
        XCTAssertEqual(byKey["skin"]?.status, .notDoneYet)

        // Ticking the skin check today moves it out of the due list.
        try LabTestsDueBuilder.markDone(ruleKey: "skin", routine: routine, now: now, calendar: calendar)
        let after = try LabTestsDueBuilder.load(routine: routine, labs: labs, capacity: capacity, now: now, calendar: calendar)
        XCTAssertEqual(after.upcoming.first { $0.ruleKey == "skin" }?.status, .upcoming)
        XCTAssertNil(after.due.first { $0.ruleKey == "skin" })
    }

    func testMarkDoneWithoutAnActiveProtocolFails() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LabTestsDueTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try StorageDatabase(url: root.appendingPathComponent("tests.sqlite"), applicationVersion: "lab-due-tests")
        defer { try? database.databasePool.close() }
        XCTAssertThrowsError(try LabTestsDueBuilder.markDone(ruleKey: "dentist", routine: RoutineStore(database: database), now: now, calendar: calendar))
    }
}
