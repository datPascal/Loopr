import Foundation
import Testing
import DomainKit
import DesignSystem
import BluetoothKit
@testable import HeartKit

private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
}()

/// 2026-09-23 00:00 UTC.
private let dayStart = Date(timeIntervalSince1970: 1_790_121_600)
private let dayEnd = dayStart.addingTimeInterval(86_400)

private func seconds(from offset: Int, count: Int, bpm: (Int) -> Double) -> [HeartRateSample] {
    (0..<count).map { HeartRateSample(time: dayStart.timeIntervalSince1970 + Double(offset + $0), bpm: bpm($0)) }
}

@Suite("Day timeline bucketing")
struct HeartDayTimelineTests {
    @Test
    func emptyDayHasNoBucketsAndNoSummary() {
        let timeline = HeartTimelineBuilder.build(samples: [], dayStart: dayStart, dayEnd: dayEnd)
        #expect(timeline.isEmpty)
        #expect(timeline.summary == nil)
        #expect(timeline.segments.isEmpty)
        #expect(timeline.bucket(at: dayStart.addingTimeInterval(60)) == nil)
    }

    @Test
    func bucketsAlignToTheDayAndCarryLowestAverageHighest() {
        // 300 seconds from 00:05: 60, 61, 62 ... repeating 60 to 69.
        let samples = seconds(from: 300, count: 300) { Double(60 + $0 % 10) }
        let timeline = HeartTimelineBuilder.build(samples: samples, dayStart: dayStart, dayEnd: dayEnd)
        #expect(timeline.buckets.count == 1)
        let bucket = timeline.buckets[0]
        #expect(bucket.start == dayStart.addingTimeInterval(300))
        #expect(bucket.end == dayStart.addingTimeInterval(600))
        #expect(bucket.minimum == 60)
        #expect(bucket.maximum == 69)
        #expect(abs(bucket.average - 64.5) < 0.001)
        #expect(bucket.sampleCount == 300)
        #expect(timeline.bucketSeconds == 300)
    }

    @Test
    func aBucketWithLessThanAMinuteOfReadingsIsAGap() {
        let sparse = seconds(from: 0, count: HeartTimelineBuilder.minimumSamplesPerBucket - 1) { _ in 60 }
        let enough = seconds(from: 600, count: HeartTimelineBuilder.minimumSamplesPerBucket) { _ in 60 }
        let timeline = HeartTimelineBuilder.build(samples: sparse + enough, dayStart: dayStart, dayEnd: dayEnd)
        #expect(timeline.buckets.map(\.start) == [dayStart.addingTimeInterval(600)])
    }

    @Test
    func implausibleAndOutOfDayReadingsAreDropped() {
        var samples = seconds(from: 0, count: 300) { _ in 58 }
        samples += [HeartRateSample(time: dayStart.timeIntervalSince1970 + 10, bpm: 0),
                    HeartRateSample(time: dayStart.timeIntervalSince1970 + 11, bpm: 255),
                    HeartRateSample(time: dayStart.timeIntervalSince1970 + 12, bpm: .nan),
                    HeartRateSample(time: dayStart.timeIntervalSince1970 - 5, bpm: 90),
                    HeartRateSample(time: dayEnd.timeIntervalSince1970, bpm: 90)]
        let timeline = HeartTimelineBuilder.build(samples: samples, dayStart: dayStart, dayEnd: dayEnd)
        #expect(timeline.buckets.count == 1)
        #expect(timeline.buckets[0].minimum == 58)
        #expect(timeline.buckets[0].maximum == 58)
        #expect(timeline.buckets[0].sampleCount == 300)
    }

    @Test
    func segmentsBreakWhereABucketIsMissing() {
        let first = seconds(from: 0, count: 600) { _ in 60 }        // buckets 0, 1
        let second = seconds(from: 1_200, count: 300) { _ in 62 }   // bucket 4
        let timeline = HeartTimelineBuilder.build(samples: first + second, dayStart: dayStart, dayEnd: dayEnd)
        #expect(timeline.segments.map(\.count) == [2, 1])
        #expect(timeline.bucket(at: dayStart.addingTimeInterval(700)) == nil)
        #expect(timeline.bucket(at: dayStart.addingTimeInterval(1_300))?.average == 62)
        #expect(timeline.bucket(at: dayStart.addingTimeInterval(299))?.start == dayStart)
    }

    @Test
    func lowestAndHighestUseMinuteMediansSoOneSpikeDoesNotCount() {
        var samples = seconds(from: 0, count: 600) { _ in 60 }
        samples[100] = HeartRateSample(time: samples[100].time, bpm: 200)
        samples += seconds(from: 600, count: 120) { _ in 120 }
        let timeline = HeartTimelineBuilder.build(samples: samples, dayStart: dayStart, dayEnd: dayEnd)
        let summary = try? #require(timeline.summary)
        #expect(summary?.lowest == 60)
        #expect(summary?.highest == 120)
        #expect(summary?.measuredMinutes == 12)
        let total: Double = 599 * 60 + 200 + 120 * 120
        let mean = total / 720
        #expect(abs((summary?.average ?? 0) - mean) < 0.001)
        // The bucket still shows the spike: it is what the band recorded.
        #expect(timeline.buckets[0].maximum == 200)
    }

    @Test
    func sleepIsClippedToTheDayAndWorkoutsMergeAndWinOverSleep() {
        let samples = seconds(from: 0, count: 3_600) { _ in 55 }
        let night = DateInterval(start: dayStart.addingTimeInterval(-3_600), end: dayStart.addingTimeInterval(7 * 3_600))
        let evening = DateInterval(start: dayEnd.addingTimeInterval(-1_800), end: dayEnd.addingTimeInterval(6 * 3_600))
        let recorded = HeartTimelineWorkout(start: dayStart.addingTimeInterval(17 * 3_600), end: dayStart.addingTimeInterval(18 * 3_600), title: "Running")
        let detected = HeartTimelineWorkout(start: dayStart.addingTimeInterval(17.5 * 3_600), end: dayStart.addingTimeInterval(18.25 * 3_600), title: "Workout")
        let napInWorkout = DateInterval(start: dayStart.addingTimeInterval(17.2 * 3_600), end: dayStart.addingTimeInterval(17.3 * 3_600))
        let tiny = HeartTimelineWorkout(start: dayEnd.addingTimeInterval(-30), end: dayEnd.addingTimeInterval(600), title: "Walk")
        let timeline = HeartTimelineBuilder.build(samples: samples, dayStart: dayStart, dayEnd: dayEnd,
                                                  sleep: [evening, night, napInWorkout], workouts: [detected, recorded, tiny])
        #expect(timeline.sleep.map(\.start) == [dayStart, napInWorkout.start, evening.start])
        #expect(timeline.sleep.first?.end == night.end)
        #expect(timeline.sleep.last?.end == dayEnd)
        #expect(timeline.workouts.count == 1)
        #expect(timeline.workouts[0].start == recorded.start)
        #expect(timeline.workouts[0].end == detected.end)
        #expect(timeline.workouts[0].title == "Running")
        #expect(timeline.span(at: dayStart.addingTimeInterval(17.25 * 3_600))?.kind == .workout)
        #expect(timeline.span(at: dayStart.addingTimeInterval(3_600))?.kind == .sleep)
        #expect(timeline.span(at: dayStart.addingTimeInterval(12 * 3_600)) == nil)
    }

    @Test
    func peakIsTheHighestAverageInsideTheWorkout() {
        let rest = seconds(from: 0, count: 3_600) { _ in 60 }
        let run = seconds(from: 3_600, count: 1_800) { $0 < 900 ? 140 : 155 }
        let workout = HeartTimelineWorkout(start: dayStart.addingTimeInterval(3_600), end: dayStart.addingTimeInterval(5_400), title: "Run")
        let timeline = HeartTimelineBuilder.build(samples: rest + run, dayStart: dayStart, dayEnd: dayEnd, workouts: [workout])
        let peak = timeline.peak(in: timeline.workouts[0])
        #expect(peak?.average == 155)
    }

    @Test
    func yDomainIsPaddedRoundedAndNeverTooFlat() {
        let calm = HeartTimelineBuilder.build(samples: seconds(from: 0, count: 600) { _ in 60 }, dayStart: dayStart, dayEnd: dayEnd)
        let domain = calm.yDomain()
        #expect(domain.upperBound - domain.lowerBound >= 40)
        #expect(domain.contains(60))
        #expect(domain.lowerBound.truncatingRemainder(dividingBy: 10) == 0)
        let wide = HeartTimelineBuilder.build(samples: seconds(from: 0, count: 600) { $0 < 300 ? 48 : 171 }, dayStart: dayStart, dayEnd: dayEnd)
        #expect(wide.yDomain().lowerBound <= 44)
        #expect(wide.yDomain().upperBound >= 175)
    }

    private func still(_ second: Int) -> SIMD3<Double> { SIMD3(0.01 * Double(second % 2), 0, 1) }

    @Test
    func aRacingNumberOnAStillWristWithoutAgreeingBeatsIsUnconfirmed() {
        // 10:00 to 10:10: the band says 180 while the wrist is still and the
        // beats say 75 (800 ms). 10:10 to 10:20: 180 with beats agreeing.
        let artifact = seconds(from: 36_000, count: 600) { _ in 180 }.map {
            HeartRateSample(time: $0.time, bpm: $0.bpm, gravity: still(Int($0.time)), rrMilliseconds: [800 + Double(Int($0.time) % 5)])
        }
        let agreed = seconds(from: 36_600, count: 600) { _ in 180 }.map {
            HeartRateSample(time: $0.time, bpm: $0.bpm, gravity: still(Int($0.time)), rrMilliseconds: [333.3, 333.4 + Double(Int($0.time) % 3)])
        }
        let calm = seconds(from: 37_200, count: 600) { _ in 62 }.map {
            HeartRateSample(time: $0.time, bpm: $0.bpm, gravity: still(Int($0.time)))
        }
        let timeline = HeartTimelineBuilder.build(samples: artifact + agreed + calm, dayStart: dayStart, dayEnd: dayEnd)
        let flags = timeline.buckets.map(\.isUnconfirmed)
        #expect(flags == [true, true, false, false, false, false])
        #expect(timeline.hasUnconfirmed)
        #expect(timeline.segments.count == 2)
        #expect(timeline.summary?.highest == 180)   // the agreeing stretch
        #expect(timeline.summary?.lowest == 62)
        #expect(timeline.summary?.measuredMinutes == 30)
    }

    @Test
    func movementOrAWorkoutKeepsAHighNumberConfirmed() {
        // Moving wrist, no beats.
        let moving = seconds(from: 36_000, count: 600) { _ in 150 }.map {
            HeartRateSample(time: $0.time, bpm: $0.bpm, gravity: SIMD3(0.3 * Double(Int($0.time) % 2), 0, 1))
        }
        // Still wrist, no beats, but inside a recorded workout (a bike).
        let bike = seconds(from: 40_000, count: 600) { _ in 150 }.map {
            HeartRateSample(time: $0.time, bpm: $0.bpm, gravity: still(Int($0.time)))
        }
        let workout = HeartTimelineWorkout(start: dayStart.addingTimeInterval(40_000), end: dayStart.addingTimeInterval(40_600), title: "Cycling")
        // No gravity at all: never judged.
        let unknown = seconds(from: 50_000, count: 600) { _ in 150 }
        let timeline = HeartTimelineBuilder.build(samples: moving + bike + unknown, dayStart: dayStart, dayEnd: dayEnd, workouts: [workout])
        #expect(!timeline.hasUnconfirmed)
        #expect(timeline.summary?.highest == 150)
    }

    @Test
    func repeatedPlaceholderBeatsDoNotConfirmANumber() {
        // Beats of exactly 400 ms (150 bpm) repeated: a placeholder, not beats.
        let samples = seconds(from: 36_000, count: 300) { _ in 150 }.map {
            HeartRateSample(time: $0.time, bpm: $0.bpm, gravity: still(Int($0.time)), rrMilliseconds: [400, 400])
        }
        let timeline = HeartTimelineBuilder.build(samples: samples, dayStart: dayStart, dayEnd: dayEnd)
        #expect(timeline.buckets.first?.isUnconfirmed == true)
        #expect(timeline.summary == nil)
    }

    @Test
    func aDaylightSavingDayWithTwentyFiveHoursKeepsItsLastHour() {
        var berlin = Calendar(identifier: .gregorian)
        berlin.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let day = LooprDay(year: 2026, month: 10, day: 25)
        let start = day.start(in: berlin)!
        let end = day.adding(days: 1, calendar: berlin)!.start(in: berlin)!
        #expect(end.timeIntervalSince(start) == 25 * 3_600)
        let samples = (0..<(25 * 3_600)).map { HeartRateSample(time: start.timeIntervalSince1970 + Double($0), bpm: 60) }
        let timeline = HeartTimelineBuilder.build(samples: samples, dayStart: start, dayEnd: end)
        #expect(timeline.buckets.count == 300)
        #expect(timeline.buckets.last?.end == end)
    }
}

@Suite("Zones and live reading")
struct HeartLiveReadingTests {
    @Test
    func agePredictedMaximumAndZoneEdges() {
        let scale = try? #require(HeartZoneScale.agePredicted(age: 34))
        #expect(scale?.maxHeartRate == 184.2)
        #expect(scale?.zone(for: 118)?.number == 2)
        #expect(scale?.zone(for: 118)?.percentOfMax == 64)
        #expect(scale?.zone(for: 118)?.pillText == "Zone 2 · 64% of max")
        #expect(scale?.zone(for: 90)?.number == 0)
        #expect(scale?.zone(for: 90)?.title == "Below zone 1")
        #expect(scale?.zone(for: 92)?.number == 0)
        #expect(scale?.zone(for: 93)?.number == 1)          // first whole bpm at or above 50%
        #expect(scale?.zone(for: 166)?.number == 5)         // 90%
        #expect(scale?.zone(for: 200)?.number == 5)
        #expect(scale?.zone(for: 200)?.percentOfMax == 109)
        #expect(scale?.zone(for: 0) == nil)
        #expect(HeartZoneScale.agePredicted(age: nil) == nil)
        #expect(HeartZoneScale.agePredicted(age: 8) == nil)
        #expect(HeartZoneScale(maxHeartRate: 60) == nil)
        #expect(HeartZoneScale(maxHeartRate: .nan) == nil)
    }

    @Test
    func zoneColoursNeverUseTheWarningTokens() {
        let expectedText: [LooprColorToken] = [.ink, .sleepSweep, .brandInk, .strain, .strainSweep, .heartChip]
        for number in 0...5 {
            let token = HeartZone(number: number, percentOfMax: 50).token
            #expect(token != .critical && token != .warning && token != .caution)
            let text = HeartZone(number: number, percentOfMax: 50).textToken
            #expect(text != .critical && text != .warning && text != .caution)
            #expect(text == expectedText[number])
        }
        #expect(HeartZone(number: 9, percentOfMax: 120).number == 5)
    }

    private func sample(_ secondsAgo: TimeInterval, bpm: Double?, rr: Double? = nil, now: Date) -> HeartLiveSample {
        HeartLiveSample(kind: .compactHeartRateRR, heartRateBPM: bpm, rrMilliseconds: rr, receivedAt: now.addingTimeInterval(-secondsAgo))
    }

    @Test
    func aQuietStreamIsNotLive() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        #expect(HeartLiveReading.resolve(samples: [], now: now, zones: nil) == nil)
        #expect(HeartLiveReading.resolve(samples: [sample(11, bpm: 70, now: now)], now: now, zones: nil) == nil)
        #expect(HeartLiveReading.resolve(samples: [sample(9, bpm: 70, now: now)], now: now, zones: nil)?.bpm == 70)
    }

    @Test
    func theBandsNumberWinsAndBeatToBeatFillsInWhenItIsMissing() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let band = HeartLiveReading.resolve(samples: [sample(1, bpm: 72, rr: 1_000, now: now)], now: now, zones: nil)
        #expect(band?.bpm == 72)
        #expect(band?.fromBeatToBeat == false)
        let derived = HeartLiveReading.resolve(samples: [sample(1, bpm: nil, rr: 1_000, now: now)], now: now, zones: nil)
        #expect(derived?.bpm == 60)
        #expect(derived?.fromBeatToBeat == true)
        #expect(derived?.spokenText.contains("beat-to-beat") == true)
        let zero = HeartLiveReading.resolve(samples: [sample(1, bpm: 0, rr: 800, now: now)], now: now, zones: nil)
        #expect(zero?.bpm == 75)
        #expect(HeartLiveReading.resolve(samples: [sample(1, bpm: nil, rr: 90, now: now)], now: now, zones: nil) == nil)
    }

    @Test
    func theLineHoldsThreeMinutesOldestFirstAndCarriesTheZone() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let samples = stride(from: 240.0, through: 0, by: -1).map { sample($0, bpm: 100 + $0 / 10, now: now) }.shuffled()
        let reading = HeartLiveReading.resolve(samples: samples, now: now, zones: HeartZoneScale(maxHeartRate: 184))
        #expect(reading?.line.count == 181)
        #expect(reading?.line.first?.date == now.addingTimeInterval(-180))
        #expect(reading?.line.last?.date == now)
        #expect(reading?.bpm == 100)
        #expect(reading?.zone?.number == 1)
        let domain = reading?.lineDomain
        #expect((domain?.upperBound ?? 0) - (domain?.lowerBound ?? 0) >= 20)
    }

    @Test
    func lastReadingTextIncludesTimeAcrossDates() {
        let now = utc.date(from: DateComponents(year: 2026, month: 9, day: 24, hour: 9, minute: 41))!
        let today = HeartLastReading(bpm: 63.6, at: utc.date(from: DateComponents(year: 2026, month: 9, day: 24, hour: 8, minute: 2))!)
        let earlier = HeartLastReading(bpm: 72, at: utc.date(from: DateComponents(year: 2026, month: 9, day: 23, hour: 22, minute: 11))!)
        let old = HeartLastReading(bpm: 58, at: utc.date(from: DateComponents(year: 2026, month: 9, day: 14, hour: 7, minute: 0))!)
        #expect(today.text(now: now, calendar: utc) == "64 bpm · 08:02")
        #expect(earlier.text(now: now, calendar: utc) == "72 bpm · Wed 22:11")
        #expect(old.text(now: now, calendar: utc) == "58 bpm · 14 Sep 07:00")
        #expect(today.spokenText(now: now, calendar: utc) == "64 beats per minute, 08:02")
    }
}

@Suite("Resting heart rate and HRV cards")
struct HeartBaselineTrendTests {
    private let day = utc.date(from: DateComponents(year: 2026, month: 9, day: 23, hour: 12))!

    private func history(_ values: [(daysAgo: Int, value: Double)]) -> [LooprChartPoint] {
        values.map { LooprChartPoint(date: utc.date(byAdding: .day, value: -$0.daysAgo, to: utc.startOfDay(for: day))!, value: $0.value) }
    }

    @Test
    func learningProgressIncludesTheSelectedNight() {
        let trend = HeartBaselineTrend.make(metric: .restingHeartRate, history: history([(1, 57), (2, 59)]),
                                            day: day, dayValue: 58, calendar: utc)
        #expect(trend.measuredNights == 2)
        #expect(trend.state == .learning(measured: 3, needed: 14))
        #expect(trend.delta?.text == "Learning your usual · 3 of 14 nights")
        #expect(trend.band == nil)
        #expect(trend.usualText == nil)
        #expect(trend.points.count == 3)
        #expect(trend.valueText == "58")
    }

    @Test
    func oneEarlierReadingAndTheSelectedNightShowTwo() {
        let trend = HeartBaselineTrend.make(metric: .hrv, history: history([(1, 46)]),
                                            day: day, dayValue: 42, calendar: utc)
        #expect(trend.measuredNights == 1)
        #expect(trend.state == .learning(measured: 2, needed: 14))
        #expect(trend.delta?.text == "Learning your usual · 2 of 14 nights")
    }

    @Test
    func aLowerRestingHeartRateOutsideTheRangeIsGoodNewsNotAWarning() {
        let nights = (1...20).map { (daysAgo: $0, value: 54.0 + Double($0 % 3) - 1) }   // 53, 54, 55
        let trend = HeartBaselineTrend.make(metric: .restingHeartRate, history: history(nights), day: day, dayValue: 50, calendar: utc)
        #expect(trend.state == .ready)
        let delta = try? #require(trend.delta)
        #expect(delta?.tone == .good)
        #expect(delta?.text == "−4 bpm vs usual")
        #expect(LooprDeltaCaption.token(for: delta?.tone ?? .neutral, accent: .recovery) == LooprColorToken.recovery.textInk)
        #expect(trend.usualText?.hasPrefix("Usual 5") == true)
        #expect(trend.usualText?.contains(" to ") == true)
        let higher = HeartBaselineTrend.make(metric: .restingHeartRate, history: history(nights), day: day, dayValue: 60, calendar: utc)
        #expect(higher.delta?.tone == .caution)
        let usual = HeartBaselineTrend.make(metric: .restingHeartRate, history: history(nights), day: day, dayValue: 54, calendar: utc)
        #expect(usual.delta?.text == "Usual")
    }

    @Test
    func higherHRVIsTheGoodDirection() {
        let nights = (1...20).map { (daysAgo: $0, value: 50.0 + Double($0 % 5)) }
        let trend = HeartBaselineTrend.make(metric: .hrv, history: history(nights), day: day, dayValue: 66, calendar: utc)
        #expect(trend.delta?.tone == .good)
        #expect(trend.metric.title == "HRV")
        #expect(trend.metric.identifier == "heart-metric-rmssd")
    }

    @Test
    func theTabsValueWinsOverHistoryForTheSelectedDay() {
        let trend = HeartBaselineTrend.make(metric: .hrv, history: history([(0, 40), (1, 45)]), day: day, dayValue: 42, calendar: utc)
        #expect(trend.value == 42)
        #expect(trend.point(on: day, calendar: utc)?.value == 42)
        let fromHistory = HeartBaselineTrend.make(metric: .hrv, history: history([(0, 40), (1, 45)]), day: day, dayValue: nil, calendar: utc)
        #expect(fromHistory.value == 40)
        let none = HeartBaselineTrend.make(metric: .hrv, history: history([(1, 45)]), day: day, dayValue: nil, calendar: utc)
        #expect(none.state == .noReading)
        #expect(none.delta == nil)
        #expect(none.spokenSummary.contains("No reading"))
    }

    @Test
    func theSevenDayAverageNeedsThreeNightsInItsWindow() {
        let trend = HeartBaselineTrend.make(metric: .hrv, history: history([(10, 30), (9, 60), (4, 40), (2, 50)]),
                                            day: day, dayValue: 60, calendar: utc)
        // Day −10 and −9: fewer than three nights in their windows.
        #expect(trend.averagePoint(on: utc.date(byAdding: .day, value: -9, to: day)!, calendar: utc) == nil)
        // Day −4: −10 is outside its window (−10...−4 is seven days), so −10, −9, −4 → 43.3.
        let fourAgo = trend.averagePoint(on: utc.date(byAdding: .day, value: -4, to: day)!, calendar: utc)
        #expect(abs((fourAgo?.value ?? 0) - 130.0 / 3) < 0.001)
        // Today: −4, −2, 0 → 50.
        #expect(trend.averagePoint(on: day, calendar: utc)?.value == 50)
    }

    @Test
    func theChartShowsThirtyNightsAndTheBandUsesTheThirtyBefore() {
        let nights = (1...36).map { (daysAgo: $0, value: 55.0) }
        let trend = HeartBaselineTrend.make(metric: .restingHeartRate, history: history(nights), day: day, dayValue: 55, calendar: utc)
        #expect(trend.points.count == 30)
        #expect(trend.points.first?.date == utc.date(byAdding: .day, value: -29, to: utc.startOfDay(for: day)))
        #expect(trend.measuredNights == 30)
        #expect(trend.band?.measuredDays == 30)
        #expect(trend.windowEnd == utc.startOfDay(for: day).addingTimeInterval(86_400))
    }

    @Test
    func yDomainKeepsAMinimumSpan() {
        let trend = HeartBaselineTrend.make(metric: .restingHeartRate, history: history([(1, 55), (2, 55)]), day: day, dayValue: 55, calendar: utc)
        #expect(trend.yDomain.upperBound - trend.yDomain.lowerBound >= 10)
        #expect(trend.yDomain.contains(55))
    }

    @Test
    func chartGeometryMapsDatesAndValuesIntoThePlot() {
        let geometry = HeartChartGeometry(start: dayStart, end: dayEnd, domain: 40...120, size: CGSize(width: 240, height: 100))
        #expect(geometry.x(dayStart) == 0)
        #expect(geometry.x(dayStart.addingTimeInterval(43_200)) == 120)
        #expect(geometry.x(dayEnd.addingTimeInterval(3_600)) == 240)
        #expect(geometry.y(40) == 100)
        #expect(geometry.y(120) == 0)
        #expect(geometry.y(80) == 50)
        #expect(geometry.date(atX: 60) == dayStart.addingTimeInterval(21_600))
        #expect(geometry.date(atX: -10) == dayStart)
    }
}

@Suite("Heart tab model and layout")
@MainActor
struct HeartTabModelTests {
    private let day = LooprDay(year: 2026, month: 9, day: 23)

    private func snapshot(rhr: Double?, hrv: Double?) -> HeartDaySnapshot {
        HeartDaySnapshot(day: DayIdentity(year: 2026, month: 9, day: 23), state: .partial, metrics: [
            HeartMetricValue(id: .restingHeartRate, title: "Resting heart rate", value: rhr.map { "\(Int($0))" }, unit: "bpm", state: .partial, source: "test", numericValue: rhr),
            HeartMetricValue(id: .rmssd, title: "RMSSD", value: hrv.map { "\(Int($0))" }, unit: "ms", state: .partial, source: "test", numericValue: hrv),
            HeartMetricValue(id: .sdnn, title: "SDNN", value: "70", unit: "ms", state: .partial, source: "test", numericValue: 70),
            HeartMetricValue(id: .pNN50, title: "pNN50", value: nil, unit: "%", state: .absent, source: "test"),
            HeartMetricValue(id: .respiration, title: "Respiratory rate", value: "14.6", unit: "br/min", state: .partial, source: "test", numericValue: 14.6),
            HeartMetricValue(id: .heartRateDip, title: "Heart-rate dip", value: nil, unit: "%", state: .absent, source: "test")
        ], source: "test")
    }

    @Test
    func loadsHistoryTimelineAndLastReadingThroughTheServices() async {
        let requested = RequestLog()
        let dayStart = day.start(in: utc)!
        let services = HeartTabServices(
            history: { id, days, end in
                await requested.add("\(id):\(days)")
                return (1...3).map { LooprChartPoint(date: dayStart.addingTimeInterval(Double(-86_400 * $0)), value: id == LooprMetricLinkID.rmssd ? 40 : 58) }
            },
            timeline: { day in
                HeartTimelineBuilder.build(samples: [], dayStart: day.start(in: utc)!, dayEnd: day.start(in: utc)!.addingTimeInterval(86_400))
            },
            lastReading: { HeartLastReading(bpm: 64, at: dayStart) }
        )
        let model = HeartTabModel()
        await model.load(day: day, snapshot: snapshot(rhr: 57, hrv: 42), services: services, calendar: utc)
        #expect(model.resting?.value == 57)
        #expect(model.resting?.measuredNights == 3)
        #expect(model.hrv?.value == 42)
        if case .loaded(let timeline) = model.timeline { #expect(timeline?.dayStart == dayStart) } else { Issue.record("timeline not loaded") }
        #expect(model.lastReading?.bpm == 64)
        #expect(await requested.all.sorted() == ["resting_heart_rate:38", "rmssd:38"])

        // Same day, new snapshot: the cards follow the value at once, and a
        // reload reads history again so nights written since then appear.
        model.snapshotChanged(snapshot(rhr: 55, hrv: 44), calendar: utc)
        #expect(model.resting?.value == 55)
        await model.load(day: day, snapshot: snapshot(rhr: 55, hrv: 44), services: services, calendar: utc)
        #expect(await requested.all.count == 4)
        #expect(model.resting?.value == 55)
    }

    @Test
    func aSnapshotForAnotherDayIsNotShownUnderThisDay() async {
        let model = HeartTabModel()
        let other = HeartDaySnapshot(day: DayIdentity(year: 2026, month: 9, day: 22), state: .partial, metrics: snapshot(rhr: 57, hrv: 42).metrics, source: "test")
        await model.load(day: day, snapshot: other, services: nil, calendar: utc)
        #expect(model.resting?.value == nil)
        #expect(model.resting?.state == .noReading)
        #expect(model.timeline == .unavailable)
    }

    @Test
    func withoutServicesTheCardsLearnAndTheTimelineIsLeftOut() async {
        let model = HeartTabModel()
        await model.load(day: day, snapshot: snapshot(rhr: 57, hrv: 42), services: nil, calendar: utc)
        #expect(model.resting?.state == .learning(measured: 1, needed: 14))
        #expect(model.timeline == .unavailable)
        #expect(model.lastReading == nil)
    }

    @Test
    func advancedSkipsTheFourMainSignals() {
        let rows = HeartAdvancedSection.metricIDs.compactMap { snapshot(rhr: 57, hrv: 42).metric($0) }.map(\.id)
        #expect(rows == [.sdnn, .pNN50, .heartRateDip])
    }
}

private actor RequestLog {
    private(set) var all: [String] = []
    func add(_ value: String) { all.append(value) }
}

@Suite("Heart tab fixtures")
@MainActor
struct HeartTabFixtureTests {
    @Test
    func theFixtureDayHasTheSleepFixturesNightAndAnEveningRun() throws {
        let day = LooprDay(year: 2023, month: 11, day: 14)
        let timeline = try #require(HeartFixtures.dayTimeline(for: day, calendar: utc))
        let start = day.start(in: utc)!
        #expect(timeline.sleep.first?.start == start)
        #expect(timeline.sleep.first?.end == start.addingTimeInterval(Double(LooprSampleNight.timeInBedMinutes - 42) * 60))
        #expect(timeline.workouts.first?.title == "Run")
        let summary = try #require(timeline.summary)
        #expect(summary.lowest < 52)
        #expect(summary.highest > 140)
        #expect(timeline.buckets.last!.end <= start.addingTimeInterval(Double(HeartFixtures.fixtureRecordingEndMinute) * 60))
        #expect(HeartFixtures.dayTimeline(for: day, calendar: utc) == timeline)
    }

    @Test
    func fixtureCardsEndOnTheValuesTheRowsShow() async {
        let services = HeartFixtures.tabServices(calendar: utc)
        let model = HeartTabModel()
        let day = LooprDay(year: 2023, month: 11, day: 14)
        await model.load(day: day, snapshot: HeartFixtures.populated, services: services, calendar: utc)
        let resting = model.resting
        let hrv = model.hrv
        #expect(resting?.value == LooprFixtureMetrics.today(LooprMetricLinkID.restingHeartRate))
        #expect(hrv?.value == LooprFixtureMetrics.today(LooprMetricLinkID.rmssd))
        #expect(resting?.state == .ready)
        #expect(hrv?.state == .ready)
        #expect(services.zones?.maxHeartRate == 184.2)
    }
}
