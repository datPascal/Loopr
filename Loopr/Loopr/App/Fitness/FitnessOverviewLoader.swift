import AnalyticsKit
import BodyKit
import Combine
import DomainKit
import Foundation
import HealthKitBridge
import ProfileKit
import RoutineKit
import TrainKit
import WorkoutKit

// LV-06.2: builds what the Fitness tab's signature objects read from stored data. This file maps the
// app's repositories onto TrainKit's plain inputs and decides nothing: the dose, the gauge, Cardio Age
// and the capacity summaries come from TrainKit and AnalyticsKit. A source that is not wired in, or
// cannot be read, comes back absent and the screen says so. Nothing is ever filled with zero.

/// The profile fields Fitness reads.
nonisolated struct FitnessProfile: Equatable, Sendable {
    var birthYear: Int?
    var biologicalSex: BiologicalSex?
}

/// Capacity results and the goals for 85, as `CapacityStore` holds them.
nonisolated struct FitnessCapacityRecords: Sendable {
    var results: [CapacityResult] = []
    var goals: [CapacityTestKind: CapacityGoal] = [:]
}

/// Where capacity results and goals for 85 are kept: `CapacityStore` in the app's database, or memory
/// for fixture launches.
nonisolated protocol FitnessCapacityRecording: Sendable {
    func records() async -> FitnessCapacityRecords
    func save(_ results: [CapacityResult]) async throws
    func save(_ goal: CapacityGoal) async throws
}

/// The capacity tables in the app's database (`storage-020-capacity`). Reads and writes run off the main
/// actor.
nonisolated struct StoredCapacityRecorder: FitnessCapacityRecording {
    let store: CapacityStore

    @concurrent
    func records() async -> FitnessCapacityRecords {
        FitnessCapacityRecords(results: (try? store.allResults()) ?? [], goals: (try? store.goals()) ?? [:])
    }

    @concurrent
    func save(_ results: [CapacityResult]) async throws {
        for result in results { try store.save(result) }
    }

    @concurrent
    func save(_ goal: CapacityGoal) async throws {
        try store.save(goal)
    }
}

/// Posted after a capacity result or goal is saved, so the Fitness tab reads them again.
nonisolated let looprCapacityRecordsChanged = Notification.Name("com.loopr.fitness.capacity-changed")

/// Where each Fitness input comes from. A nil reader is a source this composition does not have.
nonisolated struct FitnessSources: Sendable {
    /// The band's zone minutes for one local day, zones 1 to 5. Nil when the band has no data that day.
    var bandDay: (@Sendable (DayIdentity) async -> [BodyZoneMinutes]?)?
    /// Apple Health VO₂max samples in a window, through `AppleHealthSources`.
    var vo2Max: (@Sendable (_ from: Date, _ to: Date) async -> AppleHealthReadResult)?
    var profile: (@Sendable () async -> FitnessProfile?)?
    /// The rules of the active protocol's newest version. Empty without a protocol.
    var rules: (@Sendable () async -> [ProtocolRule])?
    var capacity: (@Sendable () async -> FitnessCapacityRecords)?
    /// Where the capacity tests save. Nil when this composition cannot save, so the tests are read only.
    var recorder: (any FitnessCapacityRecording)?
    /// The Apple Health workout records (`WorkoutSource.healthKit`) that overlap a window, with their heart rate
    /// samples. Their heart rate fills the zone minutes of a day the band did not cover (R1-VET-02).
    var appleHealthWorkouts: (@Sendable (_ from: Date, _ to: Date) async -> [WorkoutRecord])?
    /// The person's heart rate zones on the day that starts at the date, resolved the way the band's day is. Nil
    /// without a maximum heart rate, so no zone minutes can be worked out.
    var heartRateZones: (@Sendable (_ dayStart: Date) async -> HeartRateZones?)?

    init(bandDay: (@Sendable (DayIdentity) async -> [BodyZoneMinutes]?)? = nil,
         vo2Max: (@Sendable (_ from: Date, _ to: Date) async -> AppleHealthReadResult)? = nil,
         profile: (@Sendable () async -> FitnessProfile?)? = nil,
         rules: (@Sendable () async -> [ProtocolRule])? = nil,
         capacity: (@Sendable () async -> FitnessCapacityRecords)? = nil,
         recorder: (any FitnessCapacityRecording)? = nil,
         appleHealthWorkouts: (@Sendable (_ from: Date, _ to: Date) async -> [WorkoutRecord])? = nil,
         heartRateZones: (@Sendable (_ dayStart: Date) async -> HeartRateZones?)? = nil) {
        self.bandDay = bandDay; self.vo2Max = vo2Max; self.profile = profile; self.rules = rules
        self.appleHealthWorkouts = appleHealthWorkouts; self.heartRateZones = heartRateZones
        if let capacity {
            self.capacity = capacity
        } else if let recorder {
            self.capacity = { @Sendable in await recorder.records() }
        } else {
            self.capacity = nil
        }
        self.recorder = recorder
    }
}

/// Pure mapping from the app's types onto TrainKit's inputs.
nonisolated enum FitnessInputMapping {
    /// Five zones, by zone id 1 to 5. Anything else, an empty list included, is no data: the day's
    /// analytics leave the zones out when nothing rose above zone 1 or no zones are set, and Loopr
    /// cannot tell those apart from a day the band did not measure.
    static func zones(_ minutes: [BodyZoneMinutes]?) -> BandZoneMinutes? {
        guard let minutes, !minutes.isEmpty else { return nil }
        let byID = Dictionary(minutes.map { ($0.id, $0.minutes) }, uniquingKeysWith: { first, _ in first })
        let values = (1...5).compactMap { byID[$0] }
        guard values.count == 5 else { return nil }
        return BandZoneMinutes(zones: values)
    }

    /// The days of the week up to and including today. Later days have not happened, so they are not read.
    static func daysToRead(week: ISOWeek, now: Date, calendar: Calendar) -> [DayIdentity] {
        let parts = calendar.dateComponents([.era, .year, .month, .day], from: now)
        let today = DayIdentity(era: parts.era ?? 1, year: parts.year ?? 0, month: parts.month ?? 0, day: parts.day ?? 0)
        guard let index = week.days.firstIndex(of: today) else { return [] }
        return Array(week.days.prefix(index + 1))
    }

    /// Completed gym sessions and completed workout records. A gym session shares its workout's id, so
    /// the two count once. An imported workout's own activity name counts when it names strength or
    /// mobility, as "Yoga" or "Functional Strength Training" do. A record that gives way to its Apple Health
    /// copy (`HealthWorkoutDeduplication`) does not count twice.
    static func sessions(train: [TrainSession], workouts: [WorkoutRecord]) -> [DoseSession] {
        let gym = train.compactMap(DoseSession.init(trainSession:))
        let recorded = HealthWorkoutDeduplication.visible(workouts).compactMap { record -> DoseSession? in
            guard record.state == .completed, let start = record.startedAt else { return nil }
            let imported = record.importedSummary?.activityName.flatMap { DoseSessionKind.classify(activity: $0) != nil ? $0 : nil }
            return DoseSession(id: record.id, activity: imported ?? record.activity.rawValue, date: start)
        }
        return gym + recorded
    }

    /// This week's finished sessions as the dose's day list names them (R2-VET-03). A gym session stands in for its
    /// workout record. An Apple Health workout with heart rate carries its own zone minutes.
    static func daySessions(train: [TrainSession], workouts: [WorkoutRecord], week: ISOWeek, zones: HeartRateZones?,
                            calendar: Calendar, withSamples: [WorkoutRecord] = []) -> [FitnessDaySession] {
        let sampled = Dictionary(withSamples.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard let first = week.days.first.flatMap({ interval(of: $0, calendar: calendar) }),
              let last = week.days.last.flatMap({ interval(of: $0, calendar: calendar) }) else { return [] }
        let span = DateInterval(start: first.start, end: last.end)
        let gym = train.filter { $0.status == .completed && span.contains($0.startedAt) }
        let gymIDs = Set(gym.compactMap(\.workoutID))
        var result = gym.map { session in
            FitnessDaySession(id: session.workoutID ?? session.id, date: session.startedAt, title: session.name,
                              activity: "strength",
                              minutes: session.endedAt.map { Int(($0.timeIntervalSince(session.startedAt) / 60).rounded(.down)) })
        }
        for record in HealthWorkoutDeduplication.visible(workouts) where record.state == .completed && !gymIDs.contains(record.id) {
            guard let start = record.startedAt, span.contains(start) else { continue }
            let imported = record.source == .healthKit
            let activity = record.importedSummary?.activityName.flatMap { DoseSessionKind.classify(activity: $0) != nil ? $0 : nil }
            var ownZones: BandZoneMinutes?
            if imported, let zones, let end = record.endedAt, start < end {
                let full = record.samples.isEmpty ? (sampled[record.id] ?? record) : record
                ownZones = appleHealthZones([full], day: DateInterval(start: start, end: end), zones: zones)
            }
            result.append(FitnessDaySession(
                id: record.id, date: start, title: TrainRowText.title(record), activity: activity ?? record.activity.rawValue,
                minutes: record.duration.map { Int(($0 / 60).rounded(.down)) },
                appName: imported ? record.importedSummary?.source : nil, zones: ownZones))
        }
        return result
    }

    /// Zone minutes for one day from the heart rate inside Apple Health workouts, with the zone method the band's
    /// day uses (`ActivityAnalytics.timeInZone` over the person's resolved zones). Readings outside the day or outside
    /// a workout do not count, and a reading two overlapping workouts share counts once. Nil when no workout that day
    /// has heart rate: a day no source covers stays empty.
    static func appleHealthZones(_ records: [WorkoutRecord], day: DateInterval, zones: HeartRateZones) -> BandZoneMinutes? {
        var byTime: [Date: Int] = [:]
        for record in records where record.source == .healthKit && record.state == .completed {
            guard let start = record.startedAt, let end = record.endedAt, start < end else { continue }
            for sample in record.samples {
                guard let bpm = sample.heartRate, sample.timestamp >= start, sample.timestamp <= end,
                      sample.timestamp >= day.start, sample.timestamp < day.end, byTime[sample.timestamp] == nil else { continue }
                byTime[sample.timestamp] = bpm
            }
        }
        guard !byTime.isEmpty else { return nil }
        let source: HRMaxSource = switch zones.source {
        case .manual: .manual
        case .observed: .measured
        case .estimated: .agePredicted
        }
        let samples = byTime.map { ActivityHeartRateSample(timestamp: $0.key.timeIntervalSince1970, bpm: Double($0.value)) }
        guard let zoneSet = ActivityAnalytics.zones(zones, source: source).value,
              let time = ActivityAnalytics.timeInZone(samples, zoneSet: zoneSet).value else { return nil }
        // Rounded per zone, as the band's day is (`CanonicalDailyAnalytics.zoneMinutes`).
        return BandZoneMinutes(zones: time.seconds.map { ($0 / 60).rounded() })
    }

    /// The local day `day` names, in the calendar's time zone.
    static func interval(of day: DayIdentity, calendar: Calendar) -> DateInterval? {
        calendar.date(from: DateComponents(era: day.era, year: day.year, month: day.month, day: day.day))
            .flatMap { calendar.dateInterval(of: .day, for: $0) }
    }

    /// One dose day. The band's minutes win. A day the band did not cover takes the heart rate of the day's Apple
    /// Health workouts, and a day neither covers has no minutes.
    static func doseDay(_ day: DayIdentity, band: [BodyZoneMinutes]?, appleHealth: [WorkoutRecord],
                        zones: HeartRateZones?, calendar: Calendar) -> DoseDay {
        if let measured = self.zones(band) { return DoseDay(day: day, zones: measured, source: .band) }
        if let zones, let interval = interval(of: day, calendar: calendar),
           let fromWorkouts = appleHealthZones(appleHealth, day: interval, zones: zones) {
            return DoseDay(day: day, zones: fromWorkouts, source: .appleHealth)
        }
        return DoseDay(day: day, zones: nil)
    }

    /// Apple Health's answer as the gauge's source. A read the person switched off says so; no samples,
    /// no permission or a failed query leave the gauge waiting for readings.
    static func vo2Max(_ result: AppleHealthReadResult?) -> FitnessVO2MaxSource {
        guard let result else { return .readings([]) }
        switch result {
        case .values(let samples): return .readings(samples.compactMap(reading))
        case .absent(.switchedOff): return .switchedOff
        case .absent(.unavailable): return .unavailable
        case .absent(.noSamples), .absent(.notAuthorized), .absent(.queryFailed): return .readings([])
        }
    }

    /// One VO₂max sample with its source. A value typed into Apple Health, as from a lab test, is not a
    /// wrist estimate; every other sample is treated as one, so the caveat shows when in doubt.
    static func reading(_ sample: AppleHealthSample) -> VO2MaxReading? {
        guard sample.kind == .vo2Max, sample.value.isFinite, sample.value > 0 else { return nil }
        let typedIn = sample.provenance.wasUserEntered == true
        let label = typedIn ? "Typed into Apple Health" : (sample.provenance.label ?? "Apple Health")
        return VO2MaxReading(value: sample.value, date: sample.end, sourceLabel: label, isConsumerEstimate: !typedIn)
    }

    /// The window that holds today's 42-day median and the one a year ago.
    static func vo2MaxWindow(now: Date, calendar: Calendar) -> (from: Date, to: Date) {
        let yearAgo = calendar.date(byAdding: .year, value: -1, to: now) ?? now.addingTimeInterval(-365 * 86_400)
        let from = yearAgo.addingTimeInterval(-Double(AppleHealthSources.cardioWindowDays + 1) * 86_400)
        return (from, now)
    }

    /// FRIEND publishes a female and a male curve. Any other answer, or none, picks no curve.
    static func referenceGroup(_ sex: BiologicalSex?) -> FriendReferenceGroup? {
        switch sex {
        case .female: .female
        case .male: .male
        case .intersex, .undisclosed, nil: nil
        }
    }

    /// Everything the overview reads, from the sources and the sessions Train already loaded.
    @concurrent
    static func input(sources: FitnessSources, now: Date, calendar: Calendar, train: [TrainSession],
                      workouts: [WorkoutRecord]) async -> FitnessOverviewInput {
        var input = FitnessOverviewInput(now: now, calendar: calendar)
        // Apple Health workouts with their samples. The list's records are listing rows without samples, so the day
        // list takes each imported workout's heart rate from here (R3-VET-01).
        var appleHealth: [WorkoutRecord] = []
        if let week = ISOWeek(containing: now, calendar: calendar), sources.bandDay != nil || sources.appleHealthWorkouts != nil {
            let readDays = daysToRead(week: week, now: now, calendar: calendar)
            if let read = sources.appleHealthWorkouts, let first = readDays.first.flatMap({ interval(of: $0, calendar: calendar) }) {
                appleHealth = await read(first.start, now)
            }
            var days: [DoseDay] = []
            for day in readDays {
                let band = await sources.bandDay?(day)
                var zones: HeartRateZones?
                if self.zones(band) == nil, !appleHealth.isEmpty, let start = interval(of: day, calendar: calendar)?.start {
                    zones = await sources.heartRateZones?(start)
                }
                days.append(doseDay(day, band: band, appleHealth: appleHealth, zones: zones, calendar: calendar))
            }
            input.doseDays = days
        }
        input.sessions = sessions(train: train, workouts: workouts)
        // The zone line and the day list read today's zones, the ones the band's day and the dose's minutes use
        // (R2-VET-02, R2-VET-03).
        if let todayStart = calendar.dateInterval(of: .day, for: now)?.start {
            input.heartRateZones = await sources.heartRateZones?(todayStart)
        }
        if let week = ISOWeek(containing: now, calendar: calendar) {
            input.daySessions = daySessions(train: train, workouts: workouts, week: week, zones: input.heartRateZones,
                                            calendar: calendar, withSamples: appleHealth)
        }
        if let read = sources.vo2Max {
            let window = vo2MaxWindow(now: now, calendar: calendar)
            input.vo2Max = vo2Max(await read(window.from, window.to))
        } else {
            input.vo2Max = vo2Max(nil)
        }
        if let profile = await sources.profile?() {
            input.birthYear = profile.birthYear
            input.referenceGroup = referenceGroup(profile.biologicalSex)
        }
        let rules = await sources.rules?() ?? []
        input.targets = DoseTargets(rules: rules)
        input.capacityCadences = CapacityCadence.cadences(from: rules)
        let fromWorkouts = heartRateRecoveries(workouts, timeZoneIdentifier: calendar.timeZone.identifier)
        let read = Set(fromWorkouts.map(\.id))
        if let records = await sources.capacity?() {
            // A workout's own recovery wins over a stored copy of the same workout.
            input.capacityResults = records.results.filter { !read.contains($0.id) }
            input.capacityGoals = records.goals
        }
        input.capacityResults += fromWorkouts
        return input
    }

    /// Heart rate recovery from completed workouts that already have a first-minute score
    /// (`loopr.workout-hrr.1`). The result shares the workout's id, as `HeartRateRecoveryReader` gives it.
    static func heartRateRecoveries(_ workouts: [WorkoutRecord], timeZoneIdentifier: String = TimeZone.current.identifier)
        -> [CapacityResult] {
        workouts.compactMap { record in
            guard record.state == .completed, let end = record.endedAt, let minute = record.heartRateRecovery?.firstMinute,
                  minute.dropBPM.isFinite, minute.dropBPM >= 0 else { return nil }
            return try? CapacityResult(id: record.id, kind: .heartRateRecovery, value: minute.dropBPM, recordedAt: end,
                                       timeZoneIdentifier: timeZoneIdentifier, source: .workout, workoutID: record.id,
                                       algorithmVersion: minute.algorithmVersion, createdAt: end)
        }
    }
}

extension FitnessSources {
    /// The app's stored data: the band's daily analytics, Apple Health through `AppleHealthSources`,
    /// the profile, the active protocol and the capacity tables. A read that fails is absent.
    @MainActor
    static func live(_ persistent: PersistentProductRepositories) -> FitnessSources {
        let analytics = persistent.analytics
        let appleHealth = persistent.healthSync.appleHealthSources()
        let profile = persistent.profile
        let database = persistent.database
        let workouts = persistent.workouts
        return FitnessSources(
            bandDay: { day in
                guard let display = try? await analytics.readDisplay(day: day, reason: "fitness") else { return nil }
                return display.projection.body.zoneMinutes
            },
            vo2Max: { from, to in await appleHealth.read(.vo2Max, from: from, to: to) },
            profile: {
                guard let value = try? await profile.readProfile() else { return nil }
                return FitnessProfile(birthYear: value.birthYear, biologicalSex: value.biologicalSex)
            },
            rules: { (try? RoutineStore(database: database).activeProtocol())?.latestVersion.rules ?? [] },
            recorder: StoredCapacityRecorder(store: CapacityStore(database: database)),
            appleHealthWorkouts: { from, to in await HealthWorkoutImport.storedRecords(workouts, from: from, to: to) },
            heartRateZones: { dayStart in
                let birthYear = (try? await profile.readProfile())?.birthYear
                return await liveHeartRateZones(dayStart: dayStart, birthYear: birthYear, history: LooprMetricHistory.shared)
            })
    }

    /// Adds the starter week to the active protocol as a new version (R2-NEW-06), or saves it as the first protocol
    /// when there is none. A metric the protocol already has a rule for keeps that rule.
    nonisolated static func addStarterWeek(_ persistent: PersistentProductRepositories, now: Date) throws {
        let store = RoutineStore(database: persistent.database)
        if let active = try store.activeProtocol() {
            let rules = DoseTargets.addingStarterWeek(to: active.latestVersion.rules)
            guard rules != active.latestVersion.rules else { return }
            try store.saveVersion(protocolID: active.routineProtocol.id, rules: rules, note: "Starter week from Fitness", at: now)
        } else {
            try store.createProtocol(RoutineProtocol(name: "My week", createdAt: now), rules: DoseTargets.starterRules,
                                     note: "Starter week from Fitness")
        }
    }

    /// The zones the band's day resolves (`CanonicalDailyAnalytics`): the shared zone settings, the age that day, and
    /// the median of the last 14 resting heart rates, here from the metric history, which holds the band's and Apple
    /// Health's.
    nonisolated static func liveHeartRateZones(dayStart: Date, birthYear: Int?,
                                               history: any MetricHistoryProviding) async -> HeartRateZones? {
        let settings = await HeartZonePreferences.shared.load()
        let year = Calendar(identifier: .gregorian).component(.year, from: dayStart)
        let resting = (try? await history.series(for: .restingHeartRate, days: 14, endingOn: dayStart))?.map(\.value) ?? []
        return settings.resolved(age: birthYear.map { year - $0 }, restingNights: resting)
    }
}

/// Loads the Fitness overview and keeps the last one. A load that a newer load overtook is dropped.
@MainActor
final class FitnessOverviewLoader: ObservableObject {
    @Published private(set) var overview: FitnessOverview?
    private var generation = 0

    func load(sources: FitnessSources, now: Date, calendar: Calendar, train: [TrainSession], workouts: [WorkoutRecord]) async {
        generation += 1
        let token = generation
        let input = await FitnessInputMapping.input(sources: sources, now: now, calendar: calendar, train: train, workouts: workouts)
        guard token == generation, !Task.isCancelled else { return }
        let next = FitnessOverview.make(input)
        if next != overview { overview = next }
    }
}
