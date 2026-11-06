import DomainKit
import Foundation
import Testing
import TrainKit

/// R1-VET-02: the dose says who measured its zone minutes.
struct WeeklyDoseZoneSourceTests {
    typealias F = FitnessFixture

    private func dose(_ days: [DoseDay]) throws -> WeeklyDose {
        let week = try #require(ISOWeek(containing: F.date(2026, 10, 21), calendar: F.calendar()))
        return WeeklyDose.make(week: week, days: days, sessions: [])
    }

    @Test func aDayIsTheBandsUnlessSaidOtherwise() {
        #expect(DoseDay(day: F.day(2026, 10, 19), zones: F.zones(0, 10)).source == .band)
    }

    @Test func theLabelNamesEverySourceThatMeasuredADay() throws {
        let band = DoseDay(day: F.day(2026, 10, 19), zones: F.zones(0, 30, 0, 4), source: .band)
        let health = DoseDay(day: F.day(2026, 10, 20), zones: F.zones(4, 48), source: .appleHealth)
        let both = try dose([band, health])
        #expect(both.zoneMinutesSource == .bandAndAppleHealth && both.zoneMinutesSource?.label == "Band and Apple Health")
        #expect(both.zone2.minutes == 78 && both.hard.minutes == 4 && both.bandDaysWithData == 2)
        #expect(try dose([band]).zoneMinutesSource?.label == "Band")
        #expect(try dose([health]).zoneMinutesSource?.label == "Apple Health")
    }

    @Test func aDayWithoutMinutesNamesNoSource() throws {
        let empty = try dose([DoseDay(day: F.day(2026, 10, 20), zones: nil, source: .appleHealth),
                              DoseDay(day: F.day(2026, 10, 21), zones: nil)])
        #expect(empty.zoneMinutesSource == nil && empty.zone2.minutes == nil)
        // A day outside the week names nothing either.
        let outside = try dose([DoseDay(day: F.day(2026, 10, 26), zones: F.zones(0, 20), source: .appleHealth)])
        #expect(outside.zoneMinutesSource == nil)
    }
}
