import DesignSystem
import Foundation
import XCTest

final class RatingCalendarTests: XCTestCase {
    func testTwelveCivilWeeksKeepMissingAndInvalidRatingsAbsentAcrossDST() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Australia/Sydney")!
        let end = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 6)))
        let start = try XCTUnwrap(calendar.date(byAdding: .day, value: -83, to: end))
        let invalid = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: end))
        let model = LooprRatingCalendarModel(values: [start: 1, end: 5, invalid: 0], endingOn: end, calendar: calendar)
        XCTAssertEqual(model.days.count, 84)
        XCTAssertEqual(Set(model.days.map(\.date)).count, 84)
        XCTAssertEqual(model.recordedCount, 2)
        XCTAssertEqual(model.days.first?.value, 1)
        XCTAssertEqual(model.days.last?.value, 5)
        XCTAssertNil(model.days[82].value)
        XCTAssertEqual(end.timeIntervalSince(start), 83 * 86400 - 3600)
    }
}
