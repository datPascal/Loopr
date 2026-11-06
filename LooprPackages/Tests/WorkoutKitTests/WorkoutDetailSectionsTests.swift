import DomainKit
import XCTest
@testable import WorkoutKit

/// Fitness round 2: the workout detail's sources, heart rate, zone split, week line and dates.
final class WorkoutDetailSectionsTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_699_913_100) // Tue 14 Nov 2023, 06:05 in Perth
    private var perth: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Australia/Perth")!
        return calendar
    }
    /// Alex at 38 with the default zones: an estimated max of 181.4, zone 2 from 108.8 to 127 bpm.
    private let zones = HeartRateZoneSettings().resolved(age: 38)!

    /// A 52 minute ride as `HealthWorkoutMapping` stores one: 4 minutes in zone 1, then 48 in zone 2, every 10 seconds.
    private func ride(source: WorkoutSource = .healthKit, app: String = "Garmin Connect") -> WorkoutRecord {
        let samples = (0..<312).map { index in
            WorkoutSample(timestamp: start.addingTimeInterval(Double(index) * 10),
                          heartRate: index < 24 ? 98 + index % 4 : 117 + [0, 2, 4, 3, 1, -1, -2, 0][index % 8])
        } + [WorkoutSample(timestamp: start.addingTimeInterval(3_120), distanceMeters: 24_600)]
        return WorkoutRecord(id: UUID(), identity: WorkoutIdentity(canonicalKey: "source:healthkit:ride"), activity: .cycle,
                             source: source, state: .completed, createdAt: start, startedAt: start,
                             endedAt: start.addingTimeInterval(3_120), samples: samples,
                             importedSummary: source == .healthKit ? WorkoutImportedSummary(source: app, activityName: "Cycling", energyKcal: 512) : nil)
    }

    private func context(_ kind: WorkoutWeekSessionKind? = nil, band: Bool = false, thisWeek: Bool = true,
                         zones: HeartRateZones?? = .none) -> WorkoutDetailContext {
        WorkoutDetailContext(now: start.addingTimeInterval(14_400), calendar: perth, zones: zones ?? self.zones,
                             bandCoveredDay: band, sessionKind: kind, isThisWeek: thisWeek)
    }

    // MARK: Zone split

    func testTheZoneSplitUsesTheDosesMethod() throws {
        let summary = try XCTUnwrap(WorkoutHeartRateSummary.make(ride()))
        XCTAssertEqual(summary.points.count, 312)
        XCTAssertTrue(summary.hasChart)
        XCTAssertEqual(summary.maximum, 121)
        let split = try XCTUnwrap(WorkoutZoneSplit.make(summary.points, zones: zones))
        XCTAssertEqual(split.minutes, [4, 48, 0, 0, 0])
        XCTAssertEqual(split.zone2Minutes, 48)
        XCTAssertEqual(split.hardMinutes, 0)
        XCTAssertEqual(split.range(2), 109...126)
        XCTAssertEqual(split.methodLine,
                       "Zone 2 is 109 to 126 bpm. Max heart rate 181, estimated from your age. Your weekly minutes use the same zones.")
    }

    func testReadingsOutsideTheWorkoutAndRepeatsDoNotCount() throws {
        var record = ride()
        record.samples.append(WorkoutSample(timestamp: start.addingTimeInterval(-60), heartRate: 170))
        record.samples.append(WorkoutSample(timestamp: start, heartRate: 190))
        let summary = try XCTUnwrap(WorkoutHeartRateSummary.make(record))
        XCTAssertEqual(summary.points.count, 312)
        XCTAssertEqual(summary.maximum, 121)
    }

    func testAnImportWithoutReadingsKeepsItsAverageAndMaximumButHasNoChart() throws {
        var record = ride(app: "Apple Watch")
        record.samples = []
        record.importedSummary = WorkoutImportedSummary(source: "Apple Watch", averageHeartRate: 148, maximumHeartRate: 166)
        let summary = try XCTUnwrap(WorkoutHeartRateSummary.make(record))
        XCTAssertEqual(summary.average, 148)
        XCTAssertEqual(summary.maximum, 166)
        XCTAssertFalse(summary.hasChart)
        XCTAssertEqual(summary.source.label, "From Apple Watch")
        // A typed average is the person's, never a reading.
        var typed = record
        typed.source = .manual
        typed.importedSummary = nil
        typed.typedAverageHeartRate = 150
        XCTAssertNil(WorkoutHeartRateSummary.make(typed))
    }

    func testTheChartThinsALongSessionToItsLimit() throws {
        let summary = try XCTUnwrap(WorkoutHeartRateSummary.make(ride()))
        let points = summary.chartPoints(limit: 100)
        XCTAssertLessThanOrEqual(points.count, 100)
        XCTAssertEqual(points.first?.time, start)
    }

    // MARK: Sources

    func testEachRecordNamesOneSource() {
        XCTAssertEqual(ride().detailSourceLine, "Garmin Connect through Apple Health")
        XCTAssertEqual(ride(app: "").detailSourceLine, "From Apple Health")
        XCTAssertEqual(WorkoutFixtures.completedRun.detailSourceLine, "From the band")
        var typed = WorkoutFixtures.completedRun
        typed.source = .manual
        XCTAssertEqual(typed.detailSourceLine, "Typed by you, heart rate from the band")
        typed.samples = []
        XCTAssertEqual(typed.detailSourceLine, "Typed by you")
        var export = typed
        export.source = .imported
        export.importedSummary = WorkoutImportedSummary(source: "WHOOP")
        XCTAssertEqual(export.detailSourceLine, "From WHOOP")
    }

    func testABandRecordWhoseTimesChangedSaysEdited() {
        let end = start.addingTimeInterval(1_800)
        var detected = WorkoutRecord(id: UUID(), identity: .make(activity: .run, sourceKey: nil, startedAt: start, endedAt: end),
                                     activity: .run, source: .detected, state: .completed, createdAt: start,
                                     startedAt: start, endedAt: end, samples: [WorkoutSample(timestamp: start, heartRate: 120)])
        XCTAssertFalse(detected.bandTimesEdited)
        XCTAssertEqual(detected.detailSourceLine, "From the band")
        detected.endedAt = end.addingTimeInterval(600)
        XCTAssertTrue(detected.bandTimesEdited)
        XCTAssertEqual(detected.detailSourceLine, "From the band, edited by you")
        // A live record shortened past its readings.
        var live = WorkoutFixtures.completedRun
        live.endedAt = live.startedAt?.addingTimeInterval(600)
        XCTAssertEqual(live.measuredSource, .bandEdited)
    }

    func testRouteActionsOnlyWhereARouteCanExist() {
        XCTAssertTrue(WorkoutFixtures.completedRun.detailMayHaveRoute)
        XCTAssertFalse(ride().detailMayHaveRoute, "Apple Health imports bring no route")
        var typed = WorkoutFixtures.completedRun
        typed.source = .manual
        XCTAssertFalse(typed.detailMayHaveRoute, "A typed run with distance has no route")
    }

    func testAnImportedRideListsItsDistanceAndEnergyFromItsApp() {
        let rows = WorkoutDetailPresentation.rows(for: ride())
        XCTAssertEqual(rows.map(\.id), ["distance", "energy"])
        XCTAssertEqual(Set(rows.compactMap(\.source)), ["From Garmin Connect"])
    }

    // MARK: Week

    func testAnImportedRideOnADayWithoutTheBandAddsItsMinutes() throws {
        let record = ride()
        let summary = WorkoutHeartRateSummary.make(record)
        let split = summary.flatMap { WorkoutZoneSplit.make($0.points, zones: zones) }
        XCTAssertEqual(WorkoutWeekCount.line(for: record, context: context(), heartRate: summary, split: split),
                       "Added 48 Zone 2 minutes this week.")
        XCTAssertEqual(WorkoutWeekCount.line(for: record, context: context(band: true), heartRate: summary, split: split),
                       "The band covered that day, so its zone minutes count instead of this workout's.")
        XCTAssertEqual(WorkoutWeekCount.line(for: record, context: context(zones: .some(nil)), heartRate: summary, split: nil),
                       "Zone minutes need your birth year or a max heart rate in Heart.")
    }

    func testAStretchCountsAsAMobilitySession() {
        var stretch = WorkoutFixtures.completedRun
        stretch.source = .manual
        stretch.activity = .mobility
        stretch.samples = []
        XCTAssertEqual(WorkoutWeekCount.line(for: stretch, context: context(.mobility), heartRate: nil, split: nil),
                       "Counts as 1 mobility session this week.")
        XCTAssertEqual(WorkoutWeekCount.line(for: stretch, context: context(.mobility, thisWeek: false), heartRate: nil, split: nil),
                       "Counted as 1 mobility session that week.")
        XCTAssertEqual(WorkoutDetailContext.fallback(for: stretch).sessionKind, .mobility)
    }

    func testABandRecordAddsItsMinutesWhenTheBandCoveredTheDay() throws {
        var yoga = ride(source: .live)
        yoga.activity = .yoga
        let summary = WorkoutHeartRateSummary.make(yoga)
        let split = WorkoutZoneSplit(minutes: [10, 20, 0, 2, 1], zones: zones)
        XCTAssertEqual(WorkoutWeekCount.line(for: yoga, context: context(.mobility, band: true), heartRate: summary, split: split),
                       "Counts as 1 mobility session this week. Added 20 Zone 2 minutes and 3 hard minutes this week.")
        // Without the band's day the minutes are not claimed, and the line says when they will be.
        XCTAssertEqual(WorkoutWeekCount.line(for: yoga, context: context(.mobility), heartRate: summary, split: split),
                       "Counts as 1 mobility session this week. Not in this week's zone minutes yet. They arrive once the band has synced that day.")
    }

    func testATypedRunSaysWhyItAddsNothing() {
        var typed = WorkoutFixtures.completedRun
        typed.source = .manual
        typed.samples = []
        XCTAssertEqual(WorkoutWeekCount.line(for: typed, context: context(), heartRate: nil, split: nil),
                       "Adds nothing to this week's targets. Zone minutes need heart rate from the band or Apple Health.")
        typed.typedAverageHeartRate = 150
        XCTAssertEqual(WorkoutWeekCount.line(for: typed, context: context(), heartRate: nil, split: nil),
                       "Adds nothing to this week's targets. A typed heart rate adds no zone minutes.")
    }

    // MARK: Dates

    func testOneDateStyleWithTheYearOnlyForAPastYear() {
        let locale = Locale(identifier: "en_GB")
        let now = start.addingTimeInterval(86_400)
        XCTAssertEqual(WorkoutDetailDates.day(start, now: now, calendar: perth, locale: locale), "Tue 14 Nov")
        let lastYear = perth.date(byAdding: .year, value: -1, to: start)!
        XCTAssertEqual(WorkoutDetailDates.day(lastYear, now: now, calendar: perth, locale: locale), "Mon 14 Nov 2022")
        XCTAssertEqual(WorkoutDetailDates.whenLine(ride(), now: now, calendar: perth, locale: locale), "Tue 14 Nov, 06:05 to 06:57")
    }
}
