import DataKit
import NotificationKit
import RoutineKit
import XCTest

final class LabTestReminderTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }()
    /// 20 October 2026, 10:00 in Berlin.
    private let now = Date(timeIntervalSince1970: 1_792_483_200)

    private func test(_ key: String, _ title: String, last: Date?) -> LabTestDue {
        let rule = ProtocolRule(key: RuleKey(rawValue: key), title: title, group: .tests,
                                cadence: RuleCadence(unit: .month, every: 3))
        let inputs = LabTestsDueInputs(rules: [rule], latestReportDate: last)
        return LabTestsDueBuilder.make(inputs, now: now, calendar: calendar).all[0]
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 9))!
    }

    private func pending(_ count: Int) -> [NotificationRequest] {
        (0..<count).map {
            UserReminderRequestFactory.request(source: .ask, objectID: "ask.\($0)", day: UserReminderRequestFactory.recurringDay,
                                               fireDate: now.addingTimeInterval(3_600), title: "T", detail: "D", repeats: .daily)
        }
    }

    func testTheTextNamesTheTestAndNothingElse() {
        let blood = test("blood-test", "Blood test every 3 months", last: date(2026, 7, 10))
        XCTAssertEqual(LabTestReminder.title(for: blood), "Blood test due")
        XCTAssertEqual(LabTestReminder.detail, "Open Loopr to log it.")
        XCTAssertEqual(LabTestReminder.title(for: test("dentist", "Dentist check", last: nil)), "Dentist check due")
        XCTAssertEqual(LabTestReminder.title(for: test("sauna", "Descale the sauna", last: nil)), "Descale the sauna due")
        let long = test("custom", String(repeating: "x", count: 80), last: nil)
        XCTAssertEqual(LabTestReminder.title(for: long).count, LabTestReminder.longestTitle + " due".count)
    }

    func testTheRequestIsAOneTimeUserReminderAtNineOnTheDueDay() throws {
        let due = test("blood-test", "Blood test", last: date(2026, 7, 28))
        guard case .request(let request, let replaces) = LabTestReminder.build(test: due, now: now, calendar: calendar, pending: []) else {
            return XCTFail("Expected a request")
        }
        XCTAssertFalse(replaces)
        XCTAssertEqual(request.identity.family, .userReminders)
        XCTAssertEqual(request.identity.objectID, "tests.blood-test")
        XCTAssertEqual(request.title, "Blood test due")
        XCTAssertNil(request.repeats)
        XCTAssertEqual(request.quietHoursBehavior, .deliver)
        XCTAssertEqual(request.sensitivity, .userRequestedAlert)
        // Due 28 October, so it fires that morning at 09:00.
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: request.fireDate)
        XCTAssertEqual(parts, DateComponents(year: 2026, month: 10, day: 28, hour: 9, minute: 0))
        XCTAssertEqual(request.identity.day, "2026-10-28")
    }

    func testADueOrUndatedTestRemindsAtTheNextNineAndNeverInThePast() throws {
        let overdue = test("blood-test", "Blood test", last: date(2026, 1, 5))
        let fire = try XCTUnwrap(LabTestReminder.fireDate(for: overdue, now: now, calendar: calendar))
        XCTAssertGreaterThan(fire, now)
        XCTAssertEqual(calendar.dateComponents([.day, .hour], from: fire), DateComponents(day: 21, hour: 9))
        let early = calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 7))!
        XCTAssertEqual(calendar.dateComponents([.day, .hour], from: try XCTUnwrap(LabTestReminder.fireDate(for: overdue, now: early, calendar: calendar))),
                       DateComponents(day: 20, hour: 9))
        let undated = test("blood-test", "Blood test", last: nil)
        XCTAssertGreaterThan(try XCTUnwrap(LabTestReminder.fireDate(for: undated, now: now, calendar: calendar)), now)
    }

    func testTheCapOfTenIsRespectedAcrossEverySource() {
        let due = test("blood-test", "Blood test", last: nil)
        XCTAssertEqual(LabTestReminder.build(test: due, now: now, calendar: calendar, pending: pending(10)),
                       .refused(.full(limit: NotificationFamily.userReminderLimit)))
        guard case .request(_, let replaces) = LabTestReminder.build(test: due, now: now, calendar: calendar, pending: pending(9)) else {
            return XCTFail("Nine waiting leaves room for one more")
        }
        XCTAssertFalse(replaces)
    }

    func testAWaitingReminderForTheSameTestIsReplacedNotCounted() {
        let due = test("blood-test", "Blood test", last: nil)
        let existing = UserReminderRequestFactory.request(source: .ask, objectID: LabTestReminder.objectID("blood-test"), day: "2026-11-01",
                                                          fireDate: now.addingTimeInterval(86_400), title: "Blood test due", detail: "x")
        guard case .request(_, let replaces) = LabTestReminder.build(test: due, now: now, calendar: calendar, pending: pending(9) + [existing]) else {
            return XCTFail("A reminder for the same test is replaced even at the cap")
        }
        XCTAssertTrue(replaces)
        XCTAssertTrue(LabTestReminder.isTestReminder(existing))
        XCTAssertFalse(LabTestReminder.isTestReminder(pending(1)[0]))
    }

    func testNoReminderTextCarriesAHealthValue() {
        let due = test("blood-test", "Blood test", last: date(2026, 7, 28))
        let text = [LabTestReminder.title(for: due), LabTestReminder.detail].joined(separator: " ")
        XCTAssertNil(text.range(of: #"\d"#, options: .regularExpression))
        XCTAssertFalse(text.contains("!"))
        XCTAssertFalse(text.contains("—"))
    }
}
