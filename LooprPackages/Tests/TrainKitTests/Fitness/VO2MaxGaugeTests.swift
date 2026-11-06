import AnalyticsKit
import Foundation
import Testing
import TrainKit

struct VO2MaxGaugeTests {
    typealias F = FitnessFixture
    let now = F.date(2026, 10, 24)
    let calendar = F.calendar()

    func ago(_ days: Double, hours: Double = 0) -> Date { now.addingTimeInterval(-(days * 86_400) - hours * 3_600) }

    func reading(_ value: Double, daysAgo: Double, source: String = "Apple Watch", estimate: Bool = true) -> VO2MaxReading {
        VO2MaxReading(value: value, date: ago(daysAgo), sourceLabel: source, isConsumerEstimate: estimate)
    }

    /// Three readings whose median is `value`, spread over four weeks.
    func readings(median value: Double, endingDaysAgo end: Double = 0) -> [VO2MaxReading] {
        [reading(value - 0.3, daysAgo: end + 28), reading(value, daysAgo: end + 14), reading(value + 0.3, daysAgo: end)]
    }

    func gauge(_ readings: [VO2MaxReading], age: Int? = 38, group: FriendReferenceGroup? = .male) -> VO2MaxGauge.Outcome {
        VO2MaxGauge.make(readings: readings, now: now, age: age, group: group, calendar: calendar)
    }

    // MARK: The 42-day rule

    @Test func theMedianNeedsThreeSamplesOnThreeDaysSpanningTwoWeeks() {
        func median(_ readings: [VO2MaxReading]) -> Double? { VO2MaxMedian.make(readings: readings, asOf: now, calendar: calendar)?.value }
        #expect(median(readings(median: 44.1)) == 44.1)
        // Two samples.
        #expect(median([reading(44, daysAgo: 20), reading(45, daysAgo: 2)]) == nil)
        // Three samples on two days.
        #expect(median([reading(44, daysAgo: 20), reading(45, daysAgo: 20), reading(46, daysAgo: 2)]) == nil)
        // Three days, but only 13 days between the first and the last.
        #expect(median([reading(44, daysAgo: 13), reading(45, daysAgo: 6), reading(46, daysAgo: 0)]) == nil)
        // Exactly 14 days between them.
        #expect(median([reading(44, daysAgo: 14), reading(45, daysAgo: 6), reading(46, daysAgo: 0)]) == 45)
    }

    @Test func aSampleExactlyFortyTwoDaysOldCountsAndOneSecondOlderDoesNot() {
        let edge = [reading(40, daysAgo: 42), reading(44, daysAgo: 20), reading(46, daysAgo: 0)]
        #expect(VO2MaxMedian.make(readings: edge, asOf: now, calendar: calendar)?.value == 44)
        let past = [VO2MaxReading(value: 40, date: ago(42).addingTimeInterval(-1), sourceLabel: "Apple Watch"), edge[1], edge[2]]
        #expect(VO2MaxMedian.make(readings: past, asOf: now, calendar: calendar) == nil)
    }

    @Test func aSampleAfterTheDateIsNotUsed() {
        let future = [reading(44, daysAgo: 20), reading(45, daysAgo: 10), reading(46, daysAgo: -1)]
        #expect(VO2MaxMedian.make(readings: future, asOf: now, calendar: calendar) == nil)
    }

    @Test func theMedianOfAnEvenCountIsTheMeanOfTheMiddleTwo() {
        let four = [reading(40, daysAgo: 30), reading(42, daysAgo: 20), reading(46, daysAgo: 10), reading(60, daysAgo: 1)]
        #expect(VO2MaxMedian.make(readings: four, asOf: now, calendar: calendar)?.value == 44)
    }

    @Test func readingsThatAreNotPositiveNumbersAreIgnored() {
        let mixed = readings(median: 44) + [reading(.nan, daysAgo: 5), reading(0, daysAgo: 5), reading(-3, daysAgo: 5)]
        #expect(VO2MaxMedian.make(readings: mixed, asOf: now, calendar: calendar)?.value == 44)
    }

    @Test func distinctDaysFollowTheCalendarsZone() {
        // 15:30 and 16:30 UTC are one day in UTC but either side of midnight in Perth.
        let late = F.date(2026, 10, 10, 15, 30), later = F.date(2026, 10, 10, 16, 30)
        let samples = [VO2MaxReading(value: 44, date: F.date(2026, 9, 20), sourceLabel: "W"),
                       VO2MaxReading(value: 45, date: late, sourceLabel: "W"), VO2MaxReading(value: 46, date: later, sourceLabel: "W")]
        #expect(VO2MaxMedian.make(readings: samples, asOf: now, calendar: F.calendar("UTC")) == nil)
        #expect(VO2MaxMedian.make(readings: samples, asOf: now, calendar: F.calendar("Australia/Perth"))?.value == 45)
    }

    @Test func theGaugeAgreesWithTheRuleCardioAgeUses() {
        func healthKit(_ readings: [VO2MaxReading]) -> [HealthKitVO2MaxSample] {
            readings.map { HealthKitVO2MaxSample(vo2max: $0.value, sampledAt: $0.date, sourceIdentifier: "w", testType: .predictionSubMaxExercise) }
        }
        let cases: [[VO2MaxReading]] = [
            readings(median: 44.1),
            [reading(44, daysAgo: 42), reading(45, daysAgo: 20), reading(46, daysAgo: 0)],
            [reading(44, daysAgo: 43), reading(45, daysAgo: 20), reading(46, daysAgo: 0)],
            [reading(44, daysAgo: 14), reading(45, daysAgo: 6), reading(46, daysAgo: 0)],
            [reading(44, daysAgo: 13), reading(45, daysAgo: 6), reading(46, daysAgo: 0)],
            [reading(44, daysAgo: 20), reading(45, daysAgo: 20), reading(46, daysAgo: 0)],
            [reading(44, daysAgo: 20), reading(45, daysAgo: 0)]
        ]
        for samples in cases {
            let selection = VO2MaxSourceSelector().select(now: now, measuredCPET: [], healthKit: healthKit(samples),
                                                          timeZone: calendar.timeZone)
            #expect(VO2MaxMedian.make(readings: samples, asOf: now, calendar: calendar)?.value == selection.value)
        }
    }

    // MARK: The gauge

    @Test func theContractGaugeReadsTopHalfAndUpTwoPointSixInTwelveMonths() throws {
        let all = readings(median: 44.1) + readings(median: 41.5, endingDaysAgo: 365)
        let result = try #require(gauge(all).gauge)
        #expect(result.value == 44.1)
        #expect(result.band.id == .p50ToP75 && result.band.label == "top half")
        #expect(result.lastYearValue == 41.5)
        #expect(abs(try #require(result.changeOverTwelveMonths) - 2.6) < 1e-9)
        #expect(result.showsConsumerEstimateCaveat)
        #expect(result.sourceLabels == ["Apple Watch"] && result.sampleDates.count == 3)
    }

    @Test func theBandsAreTheFriendPercentilesForTheAgeDecadeAndGroup() throws {
        let male = try #require(gauge(readings(median: 44.1), age: 38, group: .male).gauge)
        #expect(male.percentiles == FriendPercentileRow(ageLower: 30, ageUpper: 39, group: .male, p10: 30.2, p25: 35.9, p50: 42.4, p75: 49.2))
        #expect(male.bands.map(\.id) == VO2MaxBandID.allCases)
        #expect(male.bands.map(\.lowerBound) == [nil, 30.2, 35.9, 42.4, 49.2])
        #expect(male.bands.map(\.upperBound) == [30.2, 35.9, 42.4, 49.2, nil])
        #expect(male.bands.map(\.label) == ["bottom tenth", "bottom quarter", "lower half", "top half", "top quarter"])
        let female = try #require(gauge(readings(median: 44.1), age: 38, group: .female).gauge)
        #expect(female.percentiles.p50 == 30.2 && female.band.id == .aboveP75)
    }

    @Test func aValueOnABoundaryBelongsToTheBandAbove() throws {
        func band(_ value: Double) -> VO2MaxBandID? {
            let flat = [reading(value, daysAgo: 28), reading(value, daysAgo: 14), reading(value, daysAgo: 0)]
            return gauge(flat).gauge?.band.id
        }
        #expect(band(30.1) == .belowP10 && band(30.2) == .p10ToP25)
        #expect(band(35.8) == .p10ToP25 && band(35.9) == .p25ToP50)
        #expect(band(42.3) == .p25ToP50 && band(42.4) == .p50ToP75)
        #expect(band(49.1) == .p50ToP75 && band(49.2) == .aboveP75)
        #expect(band(80) == .aboveP75 && band(5) == .belowP10)
    }

    @Test func theBandsAgreeWithTheCardioFitnessLevelTableAtTheMedianAndTopQuartile() throws {
        let table = CardioFitnessLevelTable.friend2015
        let thresholds = try #require(table.thresholds(age: 38, group: .male))
        #expect(thresholds.median == 42.4 && thresholds.upperQuartile == 49.2)
        let result = try #require(gauge(readings(median: 42.4)).gauge)
        #expect(result.band.lowerBound == thresholds.median && result.band.upperBound == thresholds.upperQuartile)
    }

    @Test func everySupportedAgeFindsItsRowAndTheEdgesOfTheTableAreExact() {
        for age in [20, 29, 30, 79] { #expect(gauge(readings(median: 40), age: age).gauge != nil, "\(age)") }
        for age in [19, 80, 0, -1] { #expect(gauge(readings(median: 40), age: age) == .absent(.unsupportedAge), "\(age)") }
    }

    @Test func theGaugeIsAbsentWithoutAnAgeAReferenceGroupOrEnoughSamples() {
        #expect(gauge(readings(median: 44), age: nil) == .absent(.needsAge))
        #expect(gauge(readings(median: 44), group: nil) == .absent(.needsReferenceGroup))
        #expect(gauge([reading(44, daysAgo: 20), reading(45, daysAgo: 0)]) == .absent(.notEnoughSamples))
        #expect(gauge([]) == .absent(.notEnoughSamples))
        #expect(gauge(readings(median: 44), age: nil).gauge == nil)
    }

    @Test func lastYearIsAbsentWhenThatWindowHasTooFewSamples() throws {
        let one = readings(median: 44) + [reading(41, daysAgo: 365)]
        let result = try #require(gauge(one).gauge)
        #expect(result.lastYearValue == nil && result.changeOverTwelveMonths == nil)
        let none = try #require(gauge(readings(median: 44)).gauge)
        #expect(none.lastYearValue == nil && none.changeOverTwelveMonths == nil)
    }

    @Test func lastYearUsesTheWindowThatEndedOneYearAgo() throws {
        // A reading from 300 days ago is outside both windows and changes neither value.
        let all = readings(median: 44.1) + readings(median: 41.5, endingDaysAgo: 365) + [reading(99, daysAgo: 300)]
        let result = try #require(gauge(all).gauge)
        #expect(result.value == 44.1 && result.lastYearValue == 41.5)
        // A fall shows as a negative change.
        let fall = try #require(gauge(readings(median: 40) + readings(median: 43, endingDaysAgo: 365)).gauge)
        #expect(abs(try #require(fall.changeOverTwelveMonths) + 3) < 1e-9)
    }

    // MARK: Provenance and the caveat

    @Test func theCaveatShowsOnlyWhenAConsumerEstimateIsPartOfTheValue() throws {
        let lab = (0..<3).map { reading(44 + Double($0) * 0.1, daysAgo: Double($0) * 14, source: "Lab test", estimate: false) }
        #expect(try #require(gauge(lab).gauge).showsConsumerEstimateCaveat == false)
        let mixed = lab + [reading(44.5, daysAgo: 7)]
        let result = try #require(gauge(mixed).gauge)
        #expect(result.showsConsumerEstimateCaveat)
        #expect(result.sourceLabels == ["Apple Watch", "Lab test"])
        #expect(VO2MaxGauge.consumerEstimateCaveat.contains("13 to 15%"))
    }

    @Test func aHealthKitSampleNeedsTheSameEligibilityCardioAgeAsks() throws {
        func make(authorized: Bool = true, compatible: Bool = true, valid: Bool = true, type: HealthKitVO2MaxTestType? = .predictionSubMaxExercise) -> VO2MaxReading? {
            VO2MaxReading(healthKit: HealthKitVO2MaxSample(vo2max: 44, sampledAt: now, sourceIdentifier: "com.apple.health", authorized: authorized,
                compatibleSource: compatible, isValid: valid, testType: type))
        }
        #expect(make() != nil)
        #expect(make(authorized: false) == nil && make(compatible: false) == nil && make(valid: false) == nil)
        #expect(make(type: nil) == nil && make(type: .predictionNonExercise) == nil && make(type: .predictionStepTest) == nil)
        #expect(make()?.isConsumerEstimate == true)
        #expect(make(type: .maxExercise)?.isConsumerEstimate == false)
        let named = VO2MaxReading(healthKit: HealthKitVO2MaxSample(vo2max: 44, sampledAt: now, sourceIdentifier: "id", testType: .maxExercise), sourceLabel: "Apple Watch")
        #expect(named?.sourceLabel == "Apple Watch")
    }
}
