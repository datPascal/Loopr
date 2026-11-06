import Foundation
import NotificationKit
import XCTest

/// ICP R1-SEN-04: the evening check-in reminder offered on the "Your list is ready" card.
final class ProtocolCheckInReminderTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }

    /// Tue 3 Nov 2026, 21:00 in Berlin, after today's 20:30.
    private var evening: Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 21))! }

    func testItRepeatsDailyAtTheChosenTimeAndNamesNoRule() throws {
        guard case .request(let request, let replaces) = ProtocolCheckInReminder.build(minuteOfDay: 20 * 60 + 30, now: evening,
                                                                                     calendar: calendar, pending: []) else {
            return XCTFail("expected a request")
        }
        XCTAssertFalse(replaces)
        XCTAssertEqual(request.identity, NotificationIdentity(family: .userReminders, objectID: "protocol.checkin", day: "recurring"))
        XCTAssertEqual(request.title, "Evening check-in")
        XCTAssertEqual(request.repeats, .daily)
        XCTAssertEqual(request.quietHoursBehavior, .deliver)
        let parts = calendar.dateComponents([.day, .hour, .minute], from: request.fireDate)
        XCTAssertEqual([parts.day, parts.hour, parts.minute], [4, 20, 30], "20:30 has passed today, so it starts tomorrow")
        XCTAssertTrue(ProtocolCheckInReminder.isCheckInReminder(request))
        XCTAssertFalse(ProtocolRuleReminder.isRuleReminder(request), "saving rules never touches it")
    }

    func testItReplacesItselfAndKeepsToTheSharedCap() throws {
        guard case .request(let first, _) = ProtocolCheckInReminder.build(minuteOfDay: 20 * 60, now: evening, calendar: calendar,
                                                                         pending: []) else { return XCTFail("expected a request") }
        guard case .request(_, let replaces) = ProtocolCheckInReminder.build(minuteOfDay: 19 * 60, now: evening, calendar: calendar,
                                                                            pending: [first]) else { return XCTFail("expected a request") }
        XCTAssertTrue(replaces)
        let others = (0..<NotificationFamily.userReminderLimit).map { index in
            NotificationRequest(identity: NotificationIdentity(family: .userReminders, objectID: "ask.\(index)", day: "recurring"),
                                fireDate: evening, title: "Other", detail: "Other", sensitivity: .userRequestedAlert, deepLink: .ask("\(index)"))
        }
        XCTAssertEqual(ProtocolCheckInReminder.build(minuteOfDay: 20 * 60, now: evening, calendar: calendar, pending: others),
                       .refused(.full(limit: NotificationFamily.userReminderLimit)))
        XCTAssertEqual(ProtocolCheckInReminder.build(minuteOfDay: 1_440, now: evening, calendar: calendar, pending: []),
                       .refused(.invalidTime))
    }
}
