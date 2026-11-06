import AnalyticsKit
import Foundation
import Testing
import TrainKit

struct VO2MaxReadingProgressTests {
    typealias F = FitnessFixture
    let now = F.date(2026, 10, 24)
    let calendar = F.calendar()

    func reading(_ value: Double, daysAgo: Double) -> VO2MaxReading {
        VO2MaxReading(value: value, date: now.addingTimeInterval(-daysAgo * 86_400), sourceLabel: "Apple Watch",
                      isConsumerEstimate: true)
    }

    func progress(_ readings: [VO2MaxReading]) -> VO2MaxReadingProgress {
        VO2MaxReadingProgress.make(readings: readings, asOf: now, calendar: calendar)
    }

    @Test func noReadingsNeedsThree() {
        let none = progress([])
        #expect(none.stillNeeded == 3)
        #expect(none.lastOneFrom == nil)
        #expect(none.headline == "0 of 3 readings")
    }

    @Test func oneReadingNeedsTwoMoreWithTheLastTwoWeeksAfterIt() throws {
        let one = progress([reading(44, daysAgo: 3)])
        #expect(one.stillNeeded == 2)
        #expect(one.headline == "1 of 3 readings")
        let from = try #require(one.lastOneFrom)
        // 14 days after a reading 3 days ago is 11 days from now, rounded up to a whole day.
        #expect(from > now.addingTimeInterval(10 * 86_400))
        #expect(from <= now.addingTimeInterval(12 * 86_400))
        #expect(calendar.startOfDay(for: from) == from)
    }

    @Test func readingsOnOneDayCountOnce() {
        let same = progress([reading(44, daysAgo: 20), reading(45, daysAgo: 20)])
        #expect(same.days.count == 1)
        #expect(same.stillNeeded == 2)
    }

    @Test func threeDaysTooCloseTogetherNeedOneLaterReading() {
        let close = progress([reading(44, daysAgo: 10), reading(45, daysAgo: 6), reading(46, daysAgo: 0)])
        #expect(close.stillNeeded == 1)
        #expect(close.lastOneFrom != nil)
        #expect(close.headline == "3 readings, all within 2 weeks")
    }

    @Test func aSpanThatCouldAlreadyBeMetNeedsNoDate() {
        // 20 days since the first: any new day completes the span, only the count is short.
        let two = progress([reading(44, daysAgo: 20), reading(45, daysAgo: 19)])
        #expect(two.stillNeeded == 1)
        #expect(two.lastOneFrom == nil)
        #expect(two.nextStep == "1 more reading on a new day.")
    }

    @Test func readingsOlderThanSixWeeksDropOut() {
        let old = progress([reading(44, daysAgo: 43), reading(45, daysAgo: 2)])
        #expect(old.days.count == 1)
    }

    @Test func completeExactlyWhenTheMedianExists() {
        let sets: [[VO2MaxReading]] = [
            [],
            [reading(44, daysAgo: 28), reading(45, daysAgo: 14), reading(46, daysAgo: 0)],
            [reading(44, daysAgo: 14), reading(45, daysAgo: 6), reading(46, daysAgo: 0)],
            [reading(44, daysAgo: 13), reading(45, daysAgo: 6), reading(46, daysAgo: 0)],
            [reading(44, daysAgo: 20), reading(45, daysAgo: 20), reading(46, daysAgo: 2)],
            [reading(44, daysAgo: 41), reading(45, daysAgo: 30), reading(46, daysAgo: 25), reading(47, daysAgo: 1)],
        ]
        for readings in sets {
            let median = VO2MaxMedian.make(readings: readings, asOf: now, calendar: calendar)
            #expect(progress(readings).isComplete == (median != nil))
        }
    }

    @Test func theFitnessOverviewCarriesProgressOnlyWhileTheGaugeIsShort() throws {
        func overview(_ source: FitnessVO2MaxSource) throws -> FitnessOverview {
            try #require(FitnessOverview.make(FitnessOverviewInput(now: now, calendar: calendar, vo2Max: source)))
        }
        #expect(try overview(.readings([reading(44, daysAgo: 3)])).vo2MaxProgress?.stillNeeded == 2)
        #expect(try overview(.readings([reading(44, daysAgo: 28), reading(45, daysAgo: 14), reading(46, daysAgo: 0)])).vo2MaxProgress == nil)
        #expect(try overview(.switchedOff).vo2MaxProgress == nil)
    }
}
