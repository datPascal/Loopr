#if DEBUG
import BodyKit
import CoachKit
import DesignSystem
import DomainKit
import Foundation
import HealthKitBridge
import RoutineKit
import StorageKit
import TodayKit

/// DEBUG launch fixture for Today's note, rail and experiment strip in the populated composition. The rail and the
/// strip read the populated fixture's one protocol store (`ProtocolTabFixture`), the same file and the same ten rules
/// the Protocol tab shows, so a tick on either tab shows on the other and both count alike (ICP R2-UPG-4). They run on
/// the real `RoutineStore`, `RoutineDayEvaluation` and `ExperimentStore`. Nothing here is reachable in a release build.
///
/// On the fixture day, at the pinned clock (`--loopr-today-clock=morning` is 07:12, `evening` is 19:49):
/// - Chip: Morning light (ticked).
/// - Rows: Protein 130 g (Food, 38 g so far), No alcohol (Food), No caffeine after 14:00 (Food, kept), Zone 2, 45 min
///   (the band, kept at 48 min), Kitchen closes by 18:30 (Food: pending in the morning, kept at 18:20 in the evening),
///   Magnesium, 300 mg (21:30), Screens off by 21:45 and Read before bed (22:00) to tick, and In bed by 22:30 (the band).
/// - Magnesium glycinate is running, night 9 of 14, and tonight is a magnesium night.
/// - The morning note compares the dial's sleeping heart rate nights by the time from the last meal to bed.
@MainActor
enum TodayNoteRailFixture {
    typealias Stores = ProtocolTabFixture.Stores

    /// Minutes in zone 2 on the fixture day: the rail's Zone 2 rule and the dial's readout read this one number.
    nonisolated static let zone2Minutes = ProtocolTabFixture.zone2Minutes

    /// The band's minutes in zones 1 to 5 on a fixture day: the 48 zone 2 minutes the rail's Zone 2 rule and the dial
    /// read, with the other zones around them. The fixture's empty day has none. Today's dial and Fitness's weekly dose
    /// both read this, so one day tells one story on both tabs (R2-UPG-1). On the fixture day itself the zone 2 minutes
    /// count only once the 17:30 session is over, as the rail's Zone 2 rule does (R2-OPT-3).
    nonisolated static func zoneMinutes(on day: DayIdentity, fixtureDay: DayIdentity, now: Date,
                                        timeZone: TimeZone) -> [BodyZoneMinutes]? {
        guard !isEmptyFixtureDay(day, fixtureDay: fixtureDay) else { return nil }
        let names = ["Recovery", "Aerobic", "Tempo", "Threshold", "Peak"]
        let minuteOfDay = RoutineDayClock(day: day, timeZone: timeZone)?.minutes(of: now) ?? 0
        let sessionPending = day == fixtureDay && minuteOfDay < Double(ProtocolTabFixture.zone2SessionEndMinute)
        let minutes = [38, sessionPending ? 0 : zone2Minutes, 22, 5, 2]
        return minutes.enumerated().map { BodyZoneMinutes(id: $0.offset + 1, name: names[$0.offset], minutes: $0.element) }
    }

    /// The fixture's sources, or nil when the store cannot be made.
    static func sources(environment: AppEnvironment, repositories: ProductRepositoryContainer?, history: any MetricHistoryProviding,
                        bandName: String) -> TodayNoteRailSources? {
        guard let stores = ProtocolTabFixture.stores(environment: environment) else { return nil }
        let routine = stores.routine, experiments = stores.experiments
        return TodayNoteRailSources(
            readProtocol: { day, now, zone in
                try await TodayNoteRailReaders.protocolDay(store: routine, day: day, now: now, zone: zone) { day, zone, now in
                    ProtocolTabFixture.snapshots(day: day, timeZone: zone, now: now)
                }
            },
            tick: { key, day, now in try RoutineDayEvaluation(store: routine).tickOnce(ruleKey: key, day: day, at: now) != nil },
            untick: { key, day, now, zone in
                _ = try RoutineDayEvaluation(store: routine).untick(ruleKey: key, day: day, now: now, timeZone: zone,
                                                                     sources: ProtocolTabFixture.snapshots(day: day, timeZone: zone, now: now))
            },
            readExperiment: { try? experiments.running() },
            readMorning: { day, calendar in await morning(day: day, calendar: calendar, history: history) },
            rewriter: CoachRewriter(model: UnavailableCoachRewordingModel()),
            bedtimeEnabled: { await BedtimeActivityPreference.isEnabled() },
            firstEveningDismissed: { TodayFirstEveningStore.isDismissedThisLaunch },
            bandName: bandName)
    }

    /// The fixture's day without band data or logs (`FixtureDayHistory`: two days back).
    nonisolated static func isEmptyFixtureDay(_ day: DayIdentity, fixtureDay: DayIdentity) -> Bool {
        ProtocolTabFixture.isEmptyFixtureDay(day, fixtureDay: fixtureDay)
    }

    // MARK: Morning note

    /// The dial's own sleeping heart rate nights, so the note and the readout say the same numbers. The fixture has no
    /// meal and sleep times for thirty nights, so the factor is laid over them: the lowest seven in ten nights had dinner
    /// four hours or more before bed. Without enough fixture nights it uses the contract's illustrative 30 nights.
    nonisolated static func morning(day: DayIdentity, calendar: Calendar, history: any MetricHistoryProviding) async -> MorningNoteInput {
        var outcomes: [DayIdentity: Double] = [:]
        if let clock = TodayDialClock(day: day, calendar: calendar),
           let points = try? await history.series(for: .sleepingHeartRate, days: TodayDialSources.heartRateHistoryDays,
                                                  endingOn: clock.start.addingTimeInterval(12 * 3_600)) {
            for point in points where point.value.isFinite && point.value > 0 {
                outcomes[TodayNoteRailMapping.day(point.day, calendar: calendar)] = point.value
            }
        }
        if TodayLearningFixture.isRequested() { return TodayLearningFixture.morningInput(today: day) }
        return morningInput(today: day, outcomes: outcomes)
    }

    nonisolated static func morningInput(today: DayIdentity, outcomes given: [DayIdentity: Double]) -> MorningNoteInput {
        var outcomes = given
        let todayKey = today.routineDayKey ?? ""
        var prior = outcomes.filter { ($0.key.routineDayKey ?? "") < todayKey }
        // Only a launch with no history at all falls back to the illustrative month. A day the fixture has no night
        // for keeps its gap, so its note is absent like its readout.
        if outcomes.isEmpty {
            outcomes = illustrative(today: today)
            prior = outcomes.filter { ($0.key.routineDayKey ?? "") < todayKey }
        }
        // The highest three in ten nights are the late dinners.
        let ranked = prior.sorted { $0.value == $1.value ? ($0.key.routineDayKey ?? "") < ($1.key.routineDayKey ?? "") : $0.value > $1.value }
        let late = Set(ranked.prefix(Int((Double(prior.count) * 0.3).rounded(.up))).map(\.key))
        let usual = TodayNoteRailMapping.median(Array(prior.values)).map { NoteUsual(median: $0, nights: prior.count, windowDays: 30) }
        let history = outcomes.keys.sorted { ($0.routineDayKey ?? "") < ($1.routineDayKey ?? "") }.compactMap { day -> NoteFactorNight? in
            guard let value = outcomes[day] else { return nil }
            return NoteFactorNight(day: day, groupID: late.contains(day) ? TodayNoteRailMapping.lessGroup.id : TodayNoteRailMapping.fourHoursGroup.id,
                                   outcome: value)
        }
        let factor = NightFactor(id: TodayNoteRailMapping.mealToBedFactorID, name: "Last meal to bed",
                                 statement: "You stopped eating {value} before bed.", lastNightValue: .duration(minutes: 244),
                                 lastNightGroupID: TodayNoteRailMapping.fourHoursGroup.id,
                                 groups: [TodayNoteRailMapping.fourHoursGroup, TodayNoteRailMapping.lessGroup], history: history)
        return MorningNoteInput(lastNight: outcomes[today].map { NightOutcome(kind: .sleepHeartRate, value: $0, day: today) },
                                usual: usual, factors: [factor])
    }

    /// Last night at 49 and the nights before it in the last 30 days, the contract's illustrative month. Sun 12 Nov,
    /// two days back, is the fixture's day without band data (`FixtureDayHistory`), so it has no night here either and
    /// the series holds 29 nights: 9 late dinners at 56 bpm and 19 earlier ones, 12 at 49 to 51, 4 at 53 and 3 at 54.
    /// The usual (the median of the 28 nights before last night) is 53, so last night reads 4 under it, and the 20 nights
    /// with 4 h or more average 5 bpm under the 9 with less.
    nonisolated static func illustrative(today: DayIdentity) -> [DayIdentity: Double] {
        var values: [DayIdentity: Double] = [today: 49]
        let late: Set<Int> = [1, 4, 7, 10, 13, 16, 19, 22, 25]
        let high: [Double] = [53, 54, 53, 54, 53, 54, 53]
        var early = 0
        for index in 0..<29 {
            let offset = index - 29
            if (-3...0).contains(offset), !FixtureDayHistory.offsetsWithData.contains(offset) { continue }
            guard let day = today.adding(days: offset) else { continue }
            if late.contains(index) {
                values[day] = 55 + Double(index % 3)
            } else {
                values[day] = early < 12 ? 49 + Double(early % 3) : high[early - 12]
                early += 1
            }
        }
        return values
    }
}

/// The populated fixture's Apple Health for Today: time in daylight (22 minutes, the same 22 the rail's Morning light
/// rule reads) and steps, as daily totals from an Apple Watch, on the fixture days that carry data. The day without band
/// data has none either.
nonisolated enum TodayFixtureAppleHealth {
    static let daylightMinutes = 22.0
    static let steps = 9_812.0
    static let watch = AppleHealthProvenance(sourceName: "Apple Watch", sourceBundleIdentifier: "com.apple.health.fixture",
                                             deviceName: "Apple Watch", deviceModel: "Watch")

    static func read(_ kind: AppleHealthSourceKind, dayStart: Date, fixtureDay: DayIdentity, calendar: Calendar) -> AppleHealthReadResult {
        let day = TodayNoteRailMapping.day(dayStart, calendar: calendar)
        guard let offset = fixtureDay.days(until: day), FixtureDayHistory.offsetsWithData.contains(offset),
              let key = day.routineDayKey else { return .absent(.noSamples) }
        let value: Double
        switch kind {
        case .daylight: value = daylightMinutes
        case .steps: value = steps
        default: return .absent(.noSamples)
        }
        let end = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        return .values([AppleHealthSample(kind: kind, value: value, original: AppleHealthOriginalReading(value: value, unit: kind.storeUnit),
                                          start: dayStart, end: end, localDay: key, provenance: watch)])
    }
}

/// Where Today picks its fixture history: the populated fixture composition only. Production and the other fixtures keep
/// the environment's provider.
@MainActor
enum TodayFixtureHistorySeam {
    static func history(environment: AppEnvironment, repositories: ProductRepositoryContainer?) -> (any MetricHistoryProviding)? {
        guard repositories?.isFixtureComposition != false, environment.composition == .populated else { return nil }
        let clock = TodayDialLoader(environment: environment, repositories: repositories, history: EmptyMetricHistoryProvider())
            .clock(for: environment.productDay(fixture: TodayFixtures.day))
        return TodayFixtureMetricHistory(day: environment.productDay(fixture: TodayFixtures.day), calendar: clock.calendar)
    }
}

/// The populated fixture's metric history for Today (DEBUG only). Sleeping heart rate is the morning note's nights,
/// so the dial's readout, its usual and the note's receipt read the same series; every other metric comes from
/// `FixtureMetricHistoryProvider`, the series `--loopr-metric-history-fixture` gives the metric pages. Today hands it to
/// its loaders through the same `MetricHistoryProviding` seam the production path fills with `LooprMetricHistory`.
nonisolated struct TodayFixtureMetricHistory: MetricHistoryProviding {
    /// The fixture day the series ends on.
    let day: DayIdentity
    /// Its time zone decides where each night's day starts, as the dial's clock does.
    let calendar: Calendar

    func series(for key: MetricKey, days: Int, endingOn: Date) async throws -> [MetricHistoryPoint] {
        guard key == .sleepingHeartRate else {
            // The fixture's empty day (`FixtureDayHistory`) has no band data, so no metric has a point on it. Without
            // this a past day said "Nothing recorded" above a Regularity of 78 (R1-NEW-4).
            return try await FixtureMetricHistoryProvider(calendar: calendar).series(for: key, days: days, endingOn: endingOn)
                .filter { !TodayNoteRailFixture.isEmptyFixtureDay(TodayNoteRailMapping.day($0.day, calendar: calendar), fixtureDay: day) }
        }
        let end = TodayNoteRailMapping.day(endingOn, calendar: calendar)
        guard let firstKey = end.adding(days: -(max(days, 1) - 1))?.routineDayKey, let lastKey = end.routineDayKey else { return [] }
        return TodayNoteRailFixture.illustrative(today: day)
            .filter { entry in
                guard let key = entry.key.routineDayKey else { return false }
                return key >= firstKey && key <= lastKey
            }
            .compactMap { entry -> MetricHistoryPoint? in
                guard let start = calendar.date(from: DateComponents(year: entry.key.year, month: entry.key.month,
                                                                     day: entry.key.day)) else { return nil }
                return MetricHistoryPoint(day: start, value: entry.value, source: .band)
            }
            .sorted { $0.day < $1.day }
    }
}

/// DEBUG launch fixture `--loopr-today-fixture=learning`: Today with three nights behind it, for the visual lane. The
/// morning note is in its learning state, the dial has no usual and no regularity yet, and last night's sleeping heart
/// rate shows as a number that waits for its usual. Pair it with `--loopr-si-morning-fixture=first-night` so the recovery
/// readout learns too. Nothing here is reachable in a release build.
nonisolated enum TodayLearningFixture {
    static let argument = "--loopr-today-fixture=learning"
    static let nights = 3

    static func isRequested(arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool { arguments.contains(argument) }

    static func morningInput(today: DayIdentity) -> MorningNoteInput {
        MorningNoteInput(lastNight: NightOutcome(kind: .sleepHeartRate, value: 49, day: today),
                         usual: NoteUsual(median: 50.5, nights: nights, windowDays: 30))
    }

    static func limit(_ inputs: inout TodayDialInputs, bandName: String) {
        inputs.recentNights = Array(inputs.recentNights.suffix(nights))
        inputs.sleepHeartRate = .value(49, .band(device: bandName))
        inputs.sleepHeartRateBefore = [51, 50]
        inputs.regularity = .missing(.noData)
    }
}

#endif
