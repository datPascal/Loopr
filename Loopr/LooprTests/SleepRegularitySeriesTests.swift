import XCTest
import Foundation
import AnalyticsKit
import DomainKit
@testable import Loopr

final class SleepRegularitySeriesTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Australia/Perth")!
        return calendar
    }

    private func night(endingOn day: Int, bedtime: (Int, Int), wake: (Int, Int)) -> CanonicalDailyAnalytics.RegularityNight {
        let wakeDate = calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: wake.0, minute: wake.1))!
        let bedDay = bedtime.0 >= 12 ? day - 1 : day
        let bedDate = calendar.date(from: DateComponents(year: 2026, month: 9, day: bedDay, hour: bedtime.0, minute: bedtime.1))!
        return .init(day: DayIdentity(year: 2026, month: 9, day: day),
                     start: bedDate.timeIntervalSince1970, end: wakeDate.timeIntervalSince1970)
    }

    private func score(_ nights: [CanonicalDailyAnalytics.RegularityNight]) throws -> Double {
        let minutes = CanonicalDailyAnalytics.regularityMinutes(nights, calendar: calendar)
        XCTAssertEqual(minutes.count, nights.count * 1_440)
        return try XCTUnwrap(SleepAnalytics.sleepRegularityIndex(minutes, epochsPerDay: 1_440).value).score
    }

    /// The newest day's evening has not happened yet. It must not be read as
    /// a night spent awake against the previous evening's bedtime.
    func testIdenticalNightsScoreAsPerfectlyRegular() throws {
        let nights = [night(endingOn: 22, bedtime: (22, 0), wake: (6, 0)),
                      night(endingOn: 23, bedtime: (22, 0), wake: (6, 0))]
        XCTAssertEqual(try score(nights), 100, accuracy: 1e-9)
    }

    /// A bedtime 38 minutes later and a wake 3 minutes later is 41 minutes
    /// of disagreement out of 1,440, which is what the two real nights in the
    /// night-build snapshot differ by.
    func testShiftedBedtimeCostsExactlyTheShiftedMinutes() throws {
        let nights = [night(endingOn: 22, bedtime: (22, 47), wake: (7, 13)),
                      night(endingOn: 23, bedtime: (23, 25), wake: (7, 16))]
        XCTAssertEqual(try score(nights), 200 * Double(1_440 - 41) / 1_440 - 100, accuracy: 1e-9)
    }

    /// A bedtime after midnight still falls inside its own day's block.
    func testAfterMidnightBedtimeStaysWithItsDay() throws {
        let nights = [night(endingOn: 22, bedtime: (0, 30), wake: (8, 0)),
                      night(endingOn: 23, bedtime: (0, 30), wake: (8, 0))]
        XCTAssertEqual(try score(nights), 100, accuracy: 1e-9)
    }
}
