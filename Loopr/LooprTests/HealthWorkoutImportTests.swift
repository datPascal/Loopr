import AnalyticsKit
import BodyKit
import DomainKit
import Foundation
import HealthKitBridge
import Testing
import TrainKit
import WorkoutKit
@testable import Loopr

// R1-VET-01 and R1-VET-02: Apple Health workouts become records with their source, give way to or win over Loopr's
// own records, and fill the zone minutes of days the band did not cover. Every test uses fakes.

private let perth = "Australia/Perth"
private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: perth)!
    return calendar
}
/// Tuesday 2023-11-14, 10:00 in Perth.
private let now = Date(timeIntervalSince1970: 1_699_927_200)

private func perthDate(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    calendar.date(from: DateComponents(year: 2023, month: 11, day: day, hour: hour, minute: minute))!
}

private func id(_ value: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", value))! }

private let garmin = AppleHealthProvenance(sourceName: "Garmin Connect", sourceBundleIdentifier: "com.garmin.connect.mobile")
private let watch = AppleHealthProvenance(sourceName: "Dev's Apple Watch", sourceBundleIdentifier: "com.apple.health.1234",
                                          deviceName: "Apple Watch")

private func healthWorkout(_ number: Int, _ activity: AppleHealthWorkoutActivity = .cycle, start: Date, minutes: Double,
                           provenance: AppleHealthProvenance = garmin, average: Double? = nil) -> AppleHealthWorkout {
    AppleHealthWorkout(id: id(number), activity: activity, activityName: "Cycling", start: start,
                       end: start.addingTimeInterval(minutes * 60), distanceMeters: 20_000, energyKcal: 400,
                       averageHeartRate: average, provenance: provenance)
}

private func native(_ number: Int, _ activity: ActivityType, _ source: WorkoutSource, start: Date, minutes: Double) -> WorkoutRecord {
    WorkoutRecord(id: id(number), identity: WorkoutIdentity(canonicalKey: "native-\(number)"), activity: activity, source: source,
                  state: .completed, createdAt: start, startedAt: start, endedAt: start.addingTimeInterval(minutes * 60),
                  finalizationStage: .activeStateCleared)
}

/// Hands out a fixed answer and, for heart rate, a reading every 10 seconds at a fixed bpm.
private actor FakeWorkoutReader: AppleHealthWorkoutReading {
    var result: AppleHealthWorkoutReadResult
    var bpm: Double? = 120
    private(set) var heartRateReads: [UUID] = []

    init(_ result: AppleHealthWorkoutReadResult) { self.result = result }
    func set(_ result: AppleHealthWorkoutReadResult) { self.result = result }

    func read(from start: Date, to end: Date) async -> AppleHealthWorkoutReadResult { result }

    func withHeartRate(_ workout: AppleHealthWorkout) async -> AppleHealthWorkout {
        heartRateReads.append(workout.id)
        guard let bpm else { return workout }
        var filled = workout
        filled.heartRate = stride(from: 0, to: workout.end.timeIntervalSince(workout.start), by: 10).map {
            AppleHealthHeartRateSample(time: workout.start.addingTimeInterval($0), bpm: bpm)
        }
        filled.averageHeartRate = workout.averageHeartRate ?? bpm
        return filled
    }
}

private actor Switch {
    var on = true
    func set(_ value: Bool) { on = value }
}

struct HealthWorkoutImportTests {
    // MARK: Mapping

    @Test func aWorkoutKeepsItsSourceValuesAndHeartRate() {
        var workout = healthWorkout(1, .crossfit, start: perthDate(14, 6), minutes: 30, average: 141)
        workout.maximumHeartRate = 172
        workout.heartRate = [AppleHealthHeartRateSample(time: perthDate(14, 6, 1), bpm: 139.6)]
        let record = HealthWorkoutMapping.record(workout)
        #expect(record.id == id(1) && record.source == .healthKit && record.state == .completed)
        #expect(record.activity == .crossfit)
        #expect(record.identity.canonicalKey == "source:healthkit:\(id(1).uuidString)")
        #expect(record.importedSummary?.source == "Garmin Connect")
        #expect(record.importedSummary?.activityName == "Cycling")
        #expect(record.importedSummary?.energyKcal == 400)
        #expect(record.importedSummary?.averageHeartRate == 141 && record.importedSummary?.maximumHeartRate == 172)
        #expect(record.samples.first?.heartRate == 140)
        // The distance is one sample at the end, the one a list row keeps.
        #expect(record.listingRow.samples.map(\.distanceMeters) == [20_000])
        #expect(abs((record.duration ?? 0) - 30 * 60) < 0.001)
        #expect(HealthWorkoutMapping.record(healthWorkout(2, start: perthDate(14, 6), minutes: 30, provenance: watch))
            .importedSummary?.source == "Apple Watch")
    }

    @Test func everyAppleHealthActivityHasAWorkoutKitHome() {
        for activity in AppleHealthWorkoutActivity.allCases {
            #expect(HealthWorkoutMapping.activity(activity).rawValue == activity.rawValue)
        }
    }

    @Test func importedRecordsAreNeverExportedBackToAppleHealth() {
        let record = HealthWorkoutMapping.record(healthWorkout(1, start: perthDate(13, 6), minutes: 30))
        #expect(LooprHealthSyncRuntime.workoutSample(record, before: now, timeZone: perth) == nil)
    }

    // MARK: Import

    @Test func aRefreshStoresNewWorkoutsWithHeartRate() async {
        let store = InMemoryWorkoutStore()
        let reader = FakeWorkoutReader(.workouts([healthWorkout(1, start: perthDate(14, 6), minutes: 52),
                                                  healthWorkout(2, .run, start: perthDate(13, 6), minutes: 35, provenance: watch)]))
        let importer = HealthWorkoutImporter(reader: reader, store: store, mayRead: { true })
        let report = await importer.refresh(now: now, calendar: calendar)
        #expect(report.saved == 2 && report.removed == 0 && report.changed)
        let ride = await store.workout(id: id(1))
        #expect(ride?.samples.contains { $0.heartRate == 120 } == true)
        // A second refresh with the same workouts reads no heart rate again and changes nothing.
        let again = await importer.refresh(now: now, calendar: calendar)
        #expect(!again.changed)
        let reads = await reader.heartRateReads
        #expect(reads.count == 2)
    }

    @Test func aWorkoutDeletedInAppleHealthLeavesOnTheNextRefresh() async {
        let store = InMemoryWorkoutStore()
        let reader = FakeWorkoutReader(.workouts([healthWorkout(1, start: perthDate(14, 6), minutes: 52),
                                                  healthWorkout(2, .run, start: perthDate(13, 6), minutes: 35)]))
        let importer = HealthWorkoutImporter(reader: reader, store: store, mayRead: { true })
        _ = await importer.refresh(now: now, calendar: calendar)
        await reader.set(.workouts([healthWorkout(2, .run, start: perthDate(13, 6), minutes: 35)]))
        let report = await importer.refresh(now: now, calendar: calendar)
        #expect(report.removed == 1)
        let deleted = await store.workout(id: id(1))
        let kept = await store.workout(id: id(2))
        #expect(deleted == nil && kept != nil)
    }

    @Test func aDeclinedReadOrASwitchedOffReadRemovesEveryImport() async {
        for declined in [AppleHealthWorkoutReadResult.absent(.noSamples), .absent(.notAuthorized), .absent(.unavailable)] {
            let store = InMemoryWorkoutStore()
            let reader = FakeWorkoutReader(.workouts([healthWorkout(1, start: perthDate(14, 6), minutes: 52)]))
            let importer = HealthWorkoutImporter(reader: reader, store: store, mayRead: { true })
            _ = await importer.refresh(now: now, calendar: calendar)
            // A month-old workout outside the eight weeks goes too: nothing may stay once access is gone.
            await store.save(HealthWorkoutMapping.record(healthWorkout(9, start: perthDate(14, 6).addingTimeInterval(-70 * 86_400),
                                                                       minutes: 30)))
            await reader.set(declined)
            let report = await importer.refresh(now: now, calendar: calendar)
            let left = await store.all()
            #expect(report.removed == 2 && left.isEmpty)
        }
        let store = InMemoryWorkoutStore()
        let toggle = Switch()
        let importer = HealthWorkoutImporter(reader: FakeWorkoutReader(.workouts([healthWorkout(1, start: perthDate(14, 6), minutes: 52)])),
                                             store: store, mayRead: { await toggle.on })
        _ = await importer.refresh(now: now, calendar: calendar)
        await toggle.set(false)
        _ = await importer.refresh(now: now, calendar: calendar)
        let left = await store.all()
        #expect(left.isEmpty)
    }

    @Test func aFailedQueryKeepsWhatWasReadAndOldImportsStay() async {
        let store = InMemoryWorkoutStore()
        let reader = FakeWorkoutReader(.workouts([healthWorkout(1, start: perthDate(14, 6), minutes: 52)]))
        let importer = HealthWorkoutImporter(reader: reader, store: store, mayRead: { true })
        _ = await importer.refresh(now: now, calendar: calendar)
        let old = HealthWorkoutMapping.record(healthWorkout(9, start: perthDate(14, 6).addingTimeInterval(-70 * 86_400), minutes: 30))
        await store.save(old)
        await reader.set(.absent(.queryFailed("locked")))
        let failed = await importer.refresh(now: now, calendar: calendar)
        #expect(!failed.changed)
        await reader.set(.workouts([healthWorkout(1, start: perthDate(14, 6), minutes: 52)]))
        _ = await importer.refresh(now: now, calendar: calendar)
        let all = await store.all()
        #expect(all.count == 2, "a workout older than the window is not read, so it is not removed")
    }

    @Test func looprsOwnRecordOfTheSameSessionWins() async {
        let live = native(50, .cycle, .live, start: perthDate(14, 6, 2), minutes: 50)
        let store = InMemoryWorkoutStore(workouts: [live])
        let importer = HealthWorkoutImporter(
            reader: FakeWorkoutReader(.workouts([healthWorkout(1, start: perthDate(14, 6), minutes: 52)])),
            store: store, mayRead: { true })
        let report = await importer.refresh(now: now, calendar: calendar)
        let all = await store.all()
        #expect(report.saved == 0 && all.map(\.id) == [live.id])
    }

    // MARK: Dedupe

    @Test func aTypedInRideGivesWayToTheGarminCopyWithHeartRate() {
        let typed = native(50, .cycle, .manual, start: perthDate(14, 6), minutes: 50)
        var garmin = HealthWorkoutMapping.record(healthWorkout(1, start: perthDate(14, 6, 1), minutes: 52, average: 121))
        #expect(HealthWorkoutDeduplication.importsToKeep([garmin], natives: [typed]).map(\.id) == [id(1)])
        #expect(HealthWorkoutDeduplication.visible([typed, garmin]).map(\.id) == [id(1)])
        // Without heart rate the Garmin copy still wins over a typed one: a device measured it.
        garmin.importedSummary = WorkoutImportedSummary(source: "Garmin Connect")
        #expect(HealthWorkoutDeduplication.visible([typed, garmin]).map(\.id) == [id(1)])
    }

    @Test func aTieGoesToLooprsRecord() {
        var whoop = native(50, .cycle, .imported, start: perthDate(14, 6), minutes: 50)
        whoop.importedSummary = WorkoutImportedSummary(source: "Account export", averageHeartRate: 125)
        let garmin = HealthWorkoutMapping.record(healthWorkout(1, start: perthDate(14, 6), minutes: 52, average: 121))
        #expect(HealthWorkoutDeduplication.importsToKeep([garmin], natives: [whoop]).isEmpty)
        #expect(HealthWorkoutDeduplication.visible([whoop, garmin]).count == 2, "visible never hides an import")
    }

    @Test func onlyTheSameFamilyAndMoreThanHalfOverlapIsOneSession() {
        let run = native(50, .run, .manual, start: perthDate(14, 6), minutes: 60)
        let ride = HealthWorkoutMapping.record(healthWorkout(1, start: perthDate(14, 6), minutes: 60, average: 121))
        #expect(HealthWorkoutDeduplication.visible([run, ride]).count == 2, "a run and a ride are two sessions")
        let walk = HealthWorkoutMapping.record(healthWorkout(2, .walk, start: perthDate(14, 6, 31), minutes: 60, average: 110))
        #expect(HealthWorkoutDeduplication.visible([run, walk]).count == 2, "29 of 60 minutes is not more than half")
        let hike = HealthWorkoutMapping.record(healthWorkout(3, .hike, start: perthDate(14, 6, 29), minutes: 60, average: 110))
        #expect(HealthWorkoutDeduplication.visible([run, hike]).map(\.id) == [id(3)])
        let other = HealthWorkoutMapping.record(healthWorkout(4, .other, start: perthDate(14, 6), minutes: 60, average: 110))
        #expect(HealthWorkoutDeduplication.visible([run, other]).map(\.id) == [id(4)], "Other matches every family")
    }

    @Test func twoAppleHealthCopiesOfOneRideKeepTheRicherOne() {
        let watchCopy = HealthWorkoutMapping.record(healthWorkout(2, start: perthDate(14, 6), minutes: 52, provenance: watch))
        let garminCopy = HealthWorkoutMapping.record(healthWorkout(1, start: perthDate(14, 6, 1), minutes: 51, average: 121))
        #expect(HealthWorkoutDeduplication.importsToKeep([watchCopy, garminCopy], natives: []).map(\.id) == [id(1)])
        #expect(HealthWorkoutDeduplication.importsToKeep([garminCopy, watchCopy], natives: []).map(\.id) == [id(1)])
        // Equal rank: the longer wins, whatever the order.
        let longer = HealthWorkoutMapping.record(healthWorkout(3, start: perthDate(14, 6), minutes: 55))
        #expect(HealthWorkoutDeduplication.importsToKeep([watchCopy, longer], natives: []).map(\.id) == [id(3)])
    }

    @Test func aBandDetectionDuringAnImportedWorkoutIsAnswered() {
        let ride = HealthWorkoutMapping.record(healthWorkout(1, start: perthDate(14, 6), minutes: 52, average: 121))
        let detection = WorkoutFixtures.detectedRun
        var overlapping = ride
        overlapping.startedAt = detection.startedAt
        overlapping.endedAt = detection.endedAt
        #expect(WorkoutDetectionDeduplication.overlapsSavedWorkout(detection, workouts: [overlapping]))
    }

    // MARK: Zone minutes

    private var zones: HeartRateZones { HeartRateZoneSettings().resolved(age: 38)! }

    @Test func importedHeartRateGivesZoneMinutesWithTheBandsMethod() throws {
        let day = try #require(FitnessInputMapping.interval(of: DayIdentity(year: 2023, month: 11, day: 14), calendar: calendar))
        let ride = HealthWorkoutFixtures.records.first { $0.id == HealthWorkoutFixtures.rideID }!
        let minutes = try #require(FitnessInputMapping.appleHealthZones([ride], day: day, zones: zones))
        #expect(minutes.zones == [4, 48, 0, 0, 0])
        // Monday holds none of the ride.
        let monday = try #require(FitnessInputMapping.interval(of: DayIdentity(year: 2023, month: 11, day: 13), calendar: calendar))
        #expect(FitnessInputMapping.appleHealthZones([ride], day: monday, zones: zones) == nil)
    }

    @Test func aWorkoutWithoutHeartRateFillsNothing() throws {
        let day = try #require(FitnessInputMapping.interval(of: DayIdentity(year: 2023, month: 11, day: 13), calendar: calendar))
        let run = HealthWorkoutFixtures.records.first { $0.id == HealthWorkoutFixtures.runID }!
        #expect(FitnessInputMapping.appleHealthZones([run], day: day, zones: zones) == nil)
        let doseDay = FitnessInputMapping.doseDay(DayIdentity(year: 2023, month: 11, day: 13), band: nil, appleHealth: [run],
                                                  zones: zones, calendar: calendar)
        #expect(doseDay.zones == nil)
    }

    @Test func aSharedReadingCountsOnceAndLooprsOwnRecordsAreIgnored() throws {
        let day = try #require(FitnessInputMapping.interval(of: DayIdentity(year: 2023, month: 11, day: 14), calendar: calendar))
        let ride = HealthWorkoutFixtures.records.first { $0.id == HealthWorkoutFixtures.rideID }!
        let copy = WorkoutRecord(id: id(77), identity: WorkoutIdentity(canonicalKey: "copy"), activity: .cycle, source: .healthKit,
                             state: .completed, createdAt: ride.createdAt, startedAt: ride.startedAt, endedAt: ride.endedAt,
                             samples: ride.samples)
        var live = ride
        live.source = .live
        let minutes = try #require(FitnessInputMapping.appleHealthZones([ride, copy, live], day: day, zones: zones))
        #expect(minutes.zones == [4, 48, 0, 0, 0])
    }

    @Test func theBandWinsADayItCovered() {
        let ride = HealthWorkoutFixtures.records.first { $0.id == HealthWorkoutFixtures.rideID }!
        let band = (1...5).map { BodyZoneMinutes(id: $0, name: "Zone \($0)", minutes: Double($0)) }
        let day = FitnessInputMapping.doseDay(DayIdentity(year: 2023, month: 11, day: 14), band: band, appleHealth: [ride],
                                              zones: zones, calendar: calendar)
        #expect(day.source == .band && day.zones?.zone2 == 2)
        let filled = FitnessInputMapping.doseDay(DayIdentity(year: 2023, month: 11, day: 14), band: nil, appleHealth: [ride],
                                                 zones: zones, calendar: calendar)
        #expect(filled.source == .appleHealth && filled.zones?.zone2 == 48)
        // Without a maximum heart rate there are no zones, so the day stays empty.
        let noZones = FitnessInputMapping.doseDay(DayIdentity(year: 2023, month: 11, day: 14), band: nil, appleHealth: [ride],
                                                  zones: nil, calendar: calendar)
        #expect(noZones.zones == nil)
    }

    @Test func theWeekWithoutABandReadsAppleHealthOnly() async throws {
        let sources = FitnessSources(appleHealthWorkouts: { _, _ in HealthWorkoutFixtures.records },
                                     heartRateZones: { _ in HeartRateZoneSettings().resolved(age: 38) })
        let input = await FitnessInputMapping.input(sources: sources, now: now, calendar: calendar, train: [], workouts: [])
        let overview = try #require(FitnessOverview.make(input))
        #expect(overview.dose.zone2.minutes == 48)
        #expect(input.doseDays.map(\.source) == [.band, .appleHealth])
        #expect(input.doseDays.first?.zones == nil, "Monday's run has no heart rate, so Monday has no minutes")
        let dose = WeeklyDose.make(week: try #require(ISOWeek(containing: now, calendar: calendar)), days: input.doseDays, sessions: [])
        #expect(dose.zoneMinutesSource == .appleHealth)
    }

    @Test func theFixtureWeekIsLabelledBandAndAppleHealth() async throws {
        let input = await FitnessInputMapping.input(sources: FitnessFixtures.sources, now: AppTrainFixtures.now,
                                                    calendar: AppTrainFixtures.calendar, train: [], workouts: [])
        let dose = WeeklyDose.make(week: try #require(ISOWeek(containing: AppTrainFixtures.now, calendar: AppTrainFixtures.calendar)),
                                   days: input.doseDays, sessions: [])
        #expect(dose.zoneMinutesSource?.label == "Band and Apple Health")
        #expect(dose.zone2.minutes == 112 && dose.hard.minutes == 16)
        #expect(AppTrainFixtures.workoutRecords.filter { $0.source == .healthKit }.map(\.importedSummary?.source)
                == ["Garmin Connect", "Apple Watch"])
    }
}
