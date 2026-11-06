import DesignSystem
import Foundation
import WorkoutKit
import XCTest

/// The quick log, the WOD log, their records and the typed detail (Fitness round 1).
final class WorkoutLogTests: XCTestCase {
    private let reference = Date(timeIntervalSince1970: 1_699_927_200) // Tue 14 Nov 2023, 10:00 in Perth

    private var perth: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Australia/Perth")!
        return calendar
    }

    private func controller() -> WorkoutSessionController {
        let now = reference
        return WorkoutSessionController(store: InMemoryWorkoutStore(), now: { now })
    }

    // MARK: Records

    /// A record saved before round 1, as the app's database holds it.
    private let oldPayload = """
    {"id":"00000000-0000-0000-0000-000000000701","identity":{"canonicalKey":"source:fixture-run"},"activity":"run",
     "source":"manual","state":"completed","createdAt":721692800,"startedAt":721692800,"endedAt":721694600,
     "samples":[{"timestamp":721692860,"heartRate":142,"distanceMeters":250}],"checkpointNumber":2,
     "finalizationStage":"activeStateCleared"}
    """

    func testAnOldPayloadDecodesUnchangedWithNoLoggedDetails() throws {
        let data = Data(oldPayload.utf8)
        let record = try JSONDecoder().decode(WorkoutRecord.self, from: data)
        XCTAssertEqual(record.activity, .run)
        XCTAssertEqual(record.duration, 1_800)
        XCTAssertEqual(record.samples.count, 1)
        XCTAssertNil(record.title); XCTAssertNil(record.effort); XCTAssertNil(record.loggedDistanceMeters)
        XCTAssertNil(record.typedAverageHeartRate); XCTAssertNil(record.notes); XCTAssertNil(record.wod)
        let row = try JSONDecoder().decode(WorkoutListingRowDocument.self, from: data).row
        XCTAssertEqual(row, record.listingRow)
    }

    func testLoggedDetailsSurviveEncodingAndTheListingRow() throws {
        var record = WorkoutFixtures.completedRun
        record.title = "Easy loop"; record.effort = 4; record.loggedDistanceMeters = 5_000
        record.typedAverageHeartRate = 141; record.notes = "Windy"
        record.activity = .crossfit
        record.wod = WODResult(format: .amrap, name: "Cindy", movements: ["5 pull-ups"], timeCapSeconds: 1_200,
                               score: .roundsAndReps(rounds: 18, reps: 7), scaling: .scaled, scalingNote: "Banded pull-ups")
        let data = try JSONEncoder().encode(record)
        XCTAssertEqual(try JSONDecoder().decode(WorkoutRecord.self, from: data), record)
        let row = try JSONDecoder().decode(WorkoutListingRowDocument.self, from: data).row
        XCTAssertEqual(row, record.listingRow)
        XCTAssertEqual(row.wod?.score, .roundsAndReps(rounds: 18, reps: 7))
        XCTAssertEqual(row.title, "Easy loop")
    }

    func testLogManualSavesTheTypedDetailsAsAManualRecord() async throws {
        let start = reference.addingTimeInterval(-3_600)
        let entry = WorkoutLogEntry(activity: .run, startedAt: start, endedAt: start.addingTimeInterval(1_800),
                                    title: "  Easy loop ", effort: 4, distanceMeters: 5_200, typedAverageHeartRate: 142,
                                    notes: "")
        let record = try await controller().logManual(entry)
        XCTAssertEqual(record.source, .manual)
        XCTAssertEqual(record.state, .completed)
        XCTAssertEqual(record.title, "Easy loop")
        XCTAssertEqual(record.effort, 4)
        XCTAssertEqual(record.loggedDistanceMeters, 5_200)
        XCTAssertEqual(record.typedAverageHeartRate, 142)
        XCTAssertNil(record.notes, "Empty notes are not saved")
        XCTAssertNil(record.wod)
    }

    func testEditReplacesTheDetailsAndKeepsTheSamples() async throws {
        let controller = controller()
        let start = reference.addingTimeInterval(-3_600)
        let saved = try await controller.logManual(WorkoutLogEntry(activity: .other, startedAt: start,
                                                                   endedAt: start.addingTimeInterval(1_200)))
        var entry = try XCTUnwrap(WorkoutLogEntry(record: saved))
        entry.activity = .climbing
        entry.title = "Bouldering"
        entry.effort = 6
        let edited = try await controller.edit(id: saved.id, entry: entry)
        XCTAssertEqual(edited.activity, .climbing)
        XCTAssertEqual(edited.title, "Bouldering")
        XCTAssertEqual(edited.effort, 6)
        XCTAssertEqual(edited.startedAt, start)
        let reread = await controller.workout(id: saved.id)
        XCTAssertEqual(reread?.title, "Bouldering")
    }

    func testValidationRejectsWhatCannotBeTrue() {
        let start = reference.addingTimeInterval(-1_800)
        let base = WorkoutLogEntry(activity: .run, startedAt: start, endedAt: reference)
        XCTAssertNoThrow(try base.validated(now: reference))
        var future = base; future.endedAt = reference.addingTimeInterval(3_600)
        XCTAssertThrowsError(try future.validated(now: reference)) { XCTAssertEqual($0 as? WorkoutLogError, .endsInFuture) }
        XCTAssertNoThrow(try future.validated(now: reference, allowingFuture: true))
        var short = base; short.startedAt = reference.addingTimeInterval(-30)
        XCTAssertThrowsError(try short.validated(now: reference)) { XCTAssertEqual($0 as? WorkoutLogError, .tooShort) }
        var effort = base; effort.effort = 11
        XCTAssertThrowsError(try effort.validated(now: reference)) { XCTAssertEqual($0 as? WorkoutLogError, .effortOutOfRange) }
        var heart = base; heart.typedAverageHeartRate = 20
        XCTAssertThrowsError(try heart.validated(now: reference)) { XCTAssertEqual($0 as? WorkoutLogError, .heartRateOutOfRange) }
        var distance = base; distance.distanceMeters = 0
        XCTAssertThrowsError(try distance.validated(now: reference)) { XCTAssertEqual($0 as? WorkoutLogError, .distanceOutOfRange) }
    }

    func testDistanceIsDroppedForTypesThatCoverNone() throws {
        let entry = WorkoutLogEntry(activity: .yoga, startedAt: reference.addingTimeInterval(-1_800), endedAt: reference,
                                    distanceMeters: 2_000)
        XCTAssertNil(try entry.validated(now: reference).distanceMeters)
    }

    func testADetectedSessionKeepsItsTitle() throws {
        let record = try DetectedWorkoutCandidate.record(from: WorkoutFixtures.detectedRun, activity: .crossfit,
                                                         title: " Open 24.1 ")
        XCTAssertEqual(record.activity, .crossfit)
        XCTAssertEqual(record.title, "Open 24.1")
    }

    // MARK: Quick log rules

    func testTimingEndsNowOnTodayAndAtTheSameClockTimeYesterday() {
        let today = WorkoutLogTiming.interval(day: .today, pickedDay: reference, endsNow: true, endTime: reference,
                                              durationMinutes: 45, now: reference, calendar: perth)
        XCTAssertEqual(today.end, reference)
        XCTAssertEqual(today.start, reference.addingTimeInterval(-45 * 60))
        let yesterday = WorkoutLogTiming.interval(day: .yesterday, pickedDay: reference, endsNow: true, endTime: reference,
                                                  durationMinutes: 30, now: reference, calendar: perth)
        XCTAssertEqual(yesterday.end, reference.addingTimeInterval(-86_400))
        // A picked day with a changed end time: Sunday 12 November at 18:30 in Perth.
        let sunday = reference.addingTimeInterval(-2 * 86_400)
        let evening = perth.date(bySettingHour: 18, minute: 30, second: 0, of: reference)!
        let picked = WorkoutLogTiming.interval(day: .pick, pickedDay: sunday, endsNow: false, endTime: evening,
                                               durationMinutes: 60, now: reference, calendar: perth)
        XCTAssertEqual(picked.end, perth.date(bySettingHour: 18, minute: 30, second: 0, of: sunday))
        XCTAssertEqual(picked.end.timeIntervalSince(picked.start), 3_600)
    }

    func testDurationStepsFiveMinutesAndTheDayChipFollowsTheEnd() {
        XCTAssertEqual(WorkoutLogTiming.stepped(30, direction: 1), 35)
        XCTAssertEqual(WorkoutLogTiming.stepped(32, direction: 1), 35)
        XCTAssertEqual(WorkoutLogTiming.stepped(32, direction: -1), 30)
        XCTAssertEqual(WorkoutLogTiming.stepped(5, direction: -1), 1)
        XCTAssertEqual(WorkoutLogTiming.day(for: reference.addingTimeInterval(-3_600), now: reference, calendar: perth), .today)
        XCTAssertEqual(WorkoutLogTiming.day(for: reference.addingTimeInterval(-86_400), now: reference, calendar: perth), .yesterday)
        XCTAssertEqual(WorkoutLogTiming.day(for: reference.addingTimeInterval(-5 * 86_400), now: reference, calendar: perth), .pick)
    }

    func testRecentTypesComeFirstAndTitlesAreRemembered() {
        func record(_ activity: ActivityType, _ hoursAgo: Double, title: String? = nil) -> WorkoutRecord {
            let start = reference.addingTimeInterval(-hoursAgo * 3_600)
            return WorkoutRecord(id: UUID(), identity: .init(canonicalKey: UUID().uuidString), activity: activity, source: .manual,
                                 state: .completed, createdAt: start, startedAt: start, endedAt: start.addingTimeInterval(600),
                                 title: title)
        }
        let records = [record(.yoga, 50), record(.climbing, 2, title: "Bouldering"), record(.climbing, 30, title: "bouldering"),
                       record(.climbing, 40, title: "Top rope"), record(.run, 10)]
        let order = ActivityType.recentFirst(records)
        XCTAssertEqual(Array(order.prefix(3)), [.climbing, .run, .yoga])
        XCTAssertEqual(Set(order), Set(ActivityType.loggable))
        XCTAssertEqual(order.count, ActivityType.loggable.count)
        XCTAssertEqual(ActivityType.climbing.recentTitles(records), ["Bouldering", "Top rope"])
    }

    func testTypeRulesForTitlesDistanceAndTargets() {
        XCTAssertTrue(ActivityType.sport.asksForTitleUpFront)
        XCTAssertFalse(ActivityType.run.asksForTitleUpFront)
        XCTAssertTrue(ActivityType.rowing.logsDistance)
        XCTAssertFalse(ActivityType.pilates.logsDistance)
        for activity in [ActivityType.yoga, .pilates, .mobility, .climbing, .dance, .other] {
            XCTAssertFalse(activity.offersHeartRateTarget, "\(activity)")
        }
        XCTAssertTrue(ActivityType.run.offersHeartRateTarget)
        XCTAssertTrue(ActivityType.crossfit.offersHeartRateTarget)
    }

    // MARK: Detail

    func testTheDetailListsTypedValuesAsTypedAndMeasuredOnesAsMeasured() {
        var typed = WorkoutFixtures.completedRun
        typed.source = .manual
        typed.samples = []
        typed.loggedDistanceMeters = 5_000
        typed.typedAverageHeartRate = 150
        typed.effort = 7
        let rows = WorkoutDetailPresentation.rows(for: typed)
        XCTAssertEqual(rows.map(\.id), ["distance", "effort", "heart-rate"])
        XCTAssertEqual(rows.first?.source, "Typed by you")
        XCTAssertEqual(rows.last?.source, "Typed by you, adds no zone minutes")

        // A recorded session's distance is GPS; its heart rate has its own section, so no typed row competes.
        var measured = WorkoutFixtures.completedRun
        measured.typedAverageHeartRate = 150
        let measuredRows = WorkoutDetailPresentation.rows(for: measured)
        XCTAssertEqual(measuredRows.first { $0.id == "distance" }?.source, "From GPS")
        XCTAssertNil(measuredRows.first { $0.id == "heart-rate" })
        XCTAssertEqual(WorkoutHeartRateSummary.make(measured)?.average, 147)
    }

    func testRouteAndSourceFollowTheRecord() {
        XCTAssertTrue(WorkoutFixtures.completedRun.mayHaveRoute)
        var gym = WorkoutFixtures.completedRun
        gym.activity = .strength
        gym.source = .live
        XCTAssertFalse(gym.mayHaveRoute)
        var logged = WorkoutFixtures.completedRun
        logged.source = .manual
        logged.samples = []
        XCTAssertFalse(logged.mayHaveRoute, "A typed run has no route")
        XCTAssertEqual(logged.sourceLabel, "Logged by you")
        XCTAssertEqual(gym.sourceLabel, "Recorded")
        var band = logged; band.source = .detected
        XCTAssertEqual(band.sourceLabel, "Band")
        var health = logged; health.source = .healthKit
        XCTAssertEqual(health.sourceLabel, "Apple Health")
        var wod = logged
        wod.wod = WODResult(format: .forTime, name: "Fran")
        XCTAssertEqual(wod.displayTitle, "Fran")
        wod.title = "Fran at the Open"
        XCTAssertEqual(wod.displayTitle, "Fran at the Open")
    }

    // MARK: Interval timer

    func testIntervalSteppersMoveFiveSecondsBelowAMinuteAndFifteenAbove() {
        let range = 5...3600
        XCTAssertEqual(IntervalConfiguration.steppedSeconds(30, direction: 1, range: range), 35)
        XCTAssertEqual(IntervalConfiguration.steppedSeconds(55, direction: 1, range: range), 60)
        XCTAssertEqual(IntervalConfiguration.steppedSeconds(60, direction: 1, range: range), 75)
        XCTAssertEqual(IntervalConfiguration.steppedSeconds(240, direction: -1, range: range), 225)
        XCTAssertEqual(IntervalConfiguration.steppedSeconds(75, direction: -1, range: range), 60)
        XCTAssertEqual(IntervalConfiguration.steppedSeconds(60, direction: -1, range: range), 55)
        XCTAssertEqual(IntervalConfiguration.steppedSeconds(5, direction: -1, range: range), 5)
        XCTAssertEqual(IntervalConfiguration.steppedSeconds(0, direction: -1, range: 0...3600), 0)
        XCTAssertEqual(IntervalConfiguration.steppedSeconds(3, direction: 1, range: 0...3600), 5)
    }

    func testPresetsAndTheSavedTitle() {
        XCTAssertEqual(IntervalPreset.all.map(\.name), ["Norwegian 4x4", "EMOM 10 min", "Tabata", "30/30"])
        // Four 4 minute intervals and the three recoveries between them.
        XCTAssertEqual(IntervalConfiguration.norwegianFourByFour.duration, (4 * 4 + 3 * 3) * 60)
        XCTAssertTrue(IntervalConfiguration.emomTen.isValid)
        XCTAssertEqual(IntervalPreset.workoutTitle(for: .norwegianFourByFour), "Norwegian 4x4")
        XCTAssertEqual(IntervalPreset.workoutTitle(for: .init(workSeconds: 40, restSeconds: 20, rounds: 8)),
                       "Intervals 40 s on, 20 s off, 8 rounds")
        XCTAssertEqual(IntervalPreset.workoutTitle(for: .init(workSeconds: 120, restSeconds: 0, rounds: 5)),
                       "Intervals 2 min, 5 rounds")
    }
}
