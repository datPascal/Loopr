import DomainKit
import Foundation
import TrainKit

enum FitnessFixture {
    static func calendar(_ zone: String = "UTC") -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0, zone: String = "UTC") -> Date {
        calendar(zone).date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    static func day(_ year: Int, _ month: Int, _ day: Int) -> DayIdentity { DayIdentity(year: year, month: month, day: day) }

    static func zones(_ one: Double = 0, _ two: Double = 0, _ three: Double = 0, _ four: Double = 0, _ five: Double = 0) -> BandZoneMinutes {
        BandZoneMinutes(zones: [one, two, three, four, five])!
    }
}
