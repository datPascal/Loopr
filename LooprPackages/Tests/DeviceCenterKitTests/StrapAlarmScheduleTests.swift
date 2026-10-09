import Foundation
import Testing
@testable import DeviceCenterKit

struct StrapAlarmScheduleTests {
    /// A fixed calendar keeps these expectations independent of the machine's
    /// locale, first weekday, and time zone.
    private static func calendar(_ identifier: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(identifier: identifier)!
        return calendar
    }

    private static func date(
        _ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int,
        in calendar: Calendar
    ) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    @Test
    func theNextOccurrenceIsLaterTodayWhenTheTimeHasNotPassed() {
        let calendar = Self.calendar("Europe/Berlin")
        // 2026-09-21 is a Monday.
        let now = Self.date(2026, 9, 21, 5, 0, in: calendar)
        let configuration = StrapAlarmConfiguration(
            isEnabled: true,
            startMinute: 7 * 60,
            endMinute: 7 * 60 + 30,
            weekdays: [.monday]
        )

        let fireDate = StrapAlarmSchedulePlanner.nextFireDate(
            for: configuration,
            after: now,
            calendar: calendar
        )

        #expect(fireDate == Self.date(2026, 9, 21, 7, 0, in: calendar))
    }

    @Test
    func aTimeThatHasPassedWrapsToTheNextChosenWeekday() {
        let calendar = Self.calendar("Europe/Berlin")
        let now = Self.date(2026, 9, 21, 9, 0, in: calendar)
        let configuration = StrapAlarmConfiguration(
            isEnabled: true,
            startMinute: 7 * 60,
            endMinute: 7 * 60 + 30,
            weekdays: [.monday]
        )

        let fireDate = StrapAlarmSchedulePlanner.nextFireDate(
            for: configuration,
            after: now,
            calendar: calendar
        )

        #expect(fireDate == Self.date(2026, 9, 28, 7, 0, in: calendar))
    }

    @Test
    func theEarliestChosenWeekdayWins() {
        let calendar = Self.calendar("Europe/Berlin")
        // Friday morning, after the alarm time.
        let now = Self.date(2026, 9, 25, 8, 0, in: calendar)
        let configuration = StrapAlarmConfiguration(
            isEnabled: true,
            startMinute: 6 * 60 + 45,
            endMinute: 7 * 60 + 15,
            weekdays: [.monday, .saturday, .sunday]
        )

        let fireDate = StrapAlarmSchedulePlanner.nextFireDate(
            for: configuration,
            after: now,
            calendar: calendar
        )

        // Saturday is the next of the three, not Monday.
        #expect(fireDate == Self.date(2026, 9, 26, 6, 45, in: calendar))
    }

    @Test
    func aDisabledOrIncompleteConfigurationHasNoOccurrence() {
        let calendar = Self.calendar("Europe/Berlin")
        let now = Self.date(2026, 9, 21, 5, 0, in: calendar)

        let disabled = StrapAlarmConfiguration(
            isEnabled: false,
            startMinute: 7 * 60,
            endMinute: 7 * 60 + 30,
            weekdays: [.monday]
        )
        let noWeekdays = StrapAlarmConfiguration(
            isEnabled: true,
            startMinute: 7 * 60,
            endMinute: 7 * 60 + 30,
            weekdays: []
        )
        let noTime = StrapAlarmConfiguration(
            isEnabled: true,
            startMinute: nil,
            endMinute: nil,
            weekdays: [.monday]
        )

        for configuration in [disabled, noWeekdays, noTime] {
            #expect(StrapAlarmSchedulePlanner.nextFireDate(
                for: configuration,
                after: now,
                calendar: calendar
            ) == nil)
        }
    }

    @Test
    func theAlarmKeepsItsWallClockTimeAcrossASpringForwardBoundary() {
        let calendar = Self.calendar("America/New_York")
        // 2026-03-08 is the US spring-forward Sunday; 02:30 does not exist.
        let now = Self.date(2026, 3, 6, 8, 0, in: calendar)
        let configuration = StrapAlarmConfiguration(
            isEnabled: true,
            startMinute: 6 * 60 + 30,
            endMinute: 7 * 60,
            weekdays: [.sunday]
        )

        let fireDate = StrapAlarmSchedulePlanner.nextFireDate(
            for: configuration,
            after: now,
            calendar: calendar
        )

        // Adding 24 hour multiples would land at 05:30 local. Calendar
        // matching keeps the alarm at the time the user set.
        #expect(fireDate == Self.date(2026, 3, 8, 6, 30, in: calendar))
        let components = calendar.dateComponents([.hour, .minute], from: fireDate!)
        #expect(components.hour == 6)
        #expect(components.minute == 30)
    }

    @Test
    func theResultIsAlwaysStrictlyAfterTheGivenMoment() {
        let calendar = Self.calendar("Europe/Berlin")
        let now = Self.date(2026, 9, 21, 7, 0, in: calendar)
        let configuration = StrapAlarmConfiguration(
            isEnabled: true,
            startMinute: 7 * 60,
            endMinute: 7 * 60 + 30,
            weekdays: [.monday]
        )

        let fireDate = StrapAlarmSchedulePlanner.nextFireDate(
            for: configuration,
            after: now,
            calendar: calendar
        )

        // Re-arming at the instant an alarm fires must move to next week, not
        // re-arm the moment that just passed.
        #expect(fireDate == Self.date(2026, 9, 28, 7, 0, in: calendar))
    }
}

struct StrapNameRulesTests {
    @Test
    func theBandNameKeepsTheWhoopPrefixAndTrimsTheUserPart() throws {
        #expect(try StrapNameRules.bandName(for: "  Bedroom  ") == "WHOOP Bedroom")
        #expect(try StrapNameRules.validatedUserName(" Bedroom ") == "Bedroom")
    }

    @Test
    func fourteenCharactersFitAndFifteenDoNot() throws {
        // The band takes 20 printable ASCII bytes and "WHOOP " costs six.
        #expect(StrapNameRules.maximumUserCharacters == 14)
        #expect(try StrapNameRules.bandName(for: "12345678901234").count == 20)
        #expect(throws: DeviceActionError.invalidArgument(.rename)) {
            _ = try StrapNameRules.validatedUserName("123456789012345")
        }
    }

    @Test
    func emptyAndNonAsciiNamesAreRejected() {
        for candidate in ["", "   ", "Schlafzimmer ü", "Bed\nroom", "strap 🎧"] {
            #expect(throws: DeviceActionError.invalidArgument(.rename)) {
                _ = try StrapNameRules.validatedUserName(candidate)
            }
        }
    }

    @Test
    func thePrefixIsStrippedWhenShowingTheNameBackToTheUser() {
        #expect(StrapNameRules.userName(fromBandName: "WHOOP Bedroom") == "Bedroom")
        // A name saved before this build carries no prefix and is shown as is.
        #expect(StrapNameRules.userName(fromBandName: "Training strap") == "Training strap")
    }
}
