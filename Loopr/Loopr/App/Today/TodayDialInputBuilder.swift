import BodyKit
import DesignSystem
import DeviceCenterKit
import DomainKit
import FoodKit
import Foundation
import HealthKitBridge
import RoutineKit
import SleepKit
import TodayKit
import WorkoutKit

// What the app puts into Today's day dial. TodayKit decides every layer, state and word; this file reads Sleep, Food,
// Fitness, Apple Health, the protocol and the wake alarm and maps them onto `TodayDialInputs`. A store that is not
// wired in, or fails to read, leaves its value missing with the reason. Nothing here fills in a zero.

/// The active protocol's rules with today's checks.
nonisolated struct TodayDialProtocolDay: Sendable, Equatable {
    var rules: [ProtocolRule]
    var checks: [RuleCheck]
}

/// One reader per store. Nil means this build or composition has no such store, and its layer stays missing.
nonisolated struct TodayDialSources: Sendable {
    var readSleep: (@Sendable (DayIdentity) async throws -> SleepDaySnapshot?)?
    /// The saved sleep need, for Sleep's plan for tonight.
    var readSleepGoalMinutes: (@Sendable () async -> Double?)?
    /// Daily history: metric, days, ending on.
    var readHistory: (@Sendable (MetricKey, Int, Date) async throws -> [MetricHistoryPoint])?
    /// Meals logged from the first to the last `YYYY-MM-DD` day key.
    var readMeals: (@Sendable (String, String) async throws -> [FoodMeal])?
    var readWorkouts: (@Sendable () async -> [WorkoutRecord])?
    var readAppleHealth: (@Sendable (AppleHealthSourceKind, Date, Date) async -> AppleHealthReadResult)?
    /// Minutes per heart-rate zone for the day from the band's analytics. Nil when there is no band day.
    var readZoneMinutes: (@Sendable (DayIdentity) async throws -> [BodyZoneMinutes]?)?
    /// Day, now and time zone. Nil when no protocol is active.
    var readProtocol: (@Sendable (DayIdentity, Date, TimeZone) async throws -> TodayDialProtocolDay?)?
    /// The wake alarm while it is on, nil when it is off.
    var readAlarm: (@Sendable () async -> WakeAlarmPlan?)?
    /// The band's name for provenance chips. Empty shows "Band".
    var bandName = ""

    /// Days of sleeping heart rate read for the usual, the window `LooprBaselineBand` uses.
    static let heartRateHistoryDays = 30

    /// - Parameter recovery: Today's recovery hero from `TodayDashboard`, which the Today view model already holds.
    func inputs(day: DayIdentity, now: Date, calendar: Calendar, recovery: TodayHeroState?,
                locale: Locale = .current) async -> TodayDialInputs? {
        guard let clock = TodayDialClock(day: day, calendar: calendar) else { return nil }
        let band = TodayDialProvenance.band(device: bandName)
        // Recovery is scored from the band's nights, so its chip names the band like sleep and sleeping heart rate do.
        var inputs = TodayDialInputs(day: day, now: now, calendar: calendar, locale: locale, recovery: recovery,
                                     recoveryProvenance: band)
        let isToday = clock.contains(now)

        if let readSleep, let snapshot = try? await readSleep(day) {
            inputs.lastNight = TodayDialInputMapping.night(snapshot, provenance: band)
            let goal = await readSleepGoalMinutes?()
            let insights = SleepNightInsights(snapshot: snapshot, goalMinutes: goal, calendar: calendar)
            inputs.recentNights = TodayDialInputMapping.nights(insights.consistency)
            if isToday { inputs.tonight = TodayDialInputMapping.tonight(insights.tonight) }
        }

        if let readHistory {
            let noon = clock.start.addingTimeInterval(12 * 3_600)
            if let points = try? await readHistory(.sleepingHeartRate, Self.heartRateHistoryDays, noon) {
                let heart = TodayDialInputMapping.sleepHeartRate(points, clock: clock, bandName: bandName)
                inputs.sleepHeartRate = heart.reading
                inputs.sleepHeartRateBefore = heart.before
            }
            if let points = try? await readHistory(.sleepConsistency, 1, noon) {
                inputs.regularity = TodayDialInputMapping.today(points, clock: clock, bandName: bandName)
            }
        }

        // Neighbouring days are read too, so a meal logged in another time zone still lands on this dial.
        if let readMeals, let first = Self.dayKey(clock.start.addingTimeInterval(-86_400), calendar: calendar),
           let last = Self.dayKey(clock.end, calendar: calendar), let meals = try? await readMeals(first, last) {
            inputs.meals = TodayDialInputMapping.meals(meals)
        }

        if let readWorkouts {
            let records = await readWorkouts()
            inputs.workouts = TodayDialInputMapping.workouts(records, bandName: bandName)
        }

        let dayKey = Self.dayKey(day)
        if let readAppleHealth {
            let daylight = await readAppleHealth(.daylight, clock.start, clock.end)
            let steps = await readAppleHealth(.steps, clock.start, clock.end)
            inputs.daylight = TodayDialInputMapping.daylight(daylight, dayKey: dayKey)
            inputs.steps = TodayDialInputMapping.dailyTotal(steps, dayKey: dayKey)
        } else {
            inputs.daylight = .missing(.unavailable)
            inputs.steps = .missing(.unavailable)
        }

        if let readZoneMinutes {
            let zones = try? await readZoneMinutes(day)
            inputs.zone2Minutes = TodayDialInputMapping.zone2(zones, bandName: bandName)
        }

        if let readProtocol, let protocolDay = try? await readProtocol(day, now, calendar.timeZone) {
            inputs.rules = TodayDialInputMapping.rules(protocolDay)
        }

        if isToday, let readAlarm {
            let plan = await readAlarm()
            inputs.alarm = TodayDialInputMapping.alarm(plan, weekday: calendar.component(.weekday, from: now))
        }
        return inputs
    }

    func model(day: DayIdentity, now: Date, calendar: Calendar, recovery: TodayHeroState?,
               locale: Locale = .current) async -> TodayDialModel? {
        guard let inputs = await inputs(day: day, now: now, calendar: calendar, recovery: recovery, locale: locale) else { return nil }
        return TodayDialModel(inputs)
    }

    static func dayKey(_ day: DayIdentity) -> String {
        String(format: "%04d-%02d-%02d", day.year, day.month, day.day)
    }

    static func dayKey(_ date: Date, calendar: Calendar) -> String? {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return nil }
        return dayKey(DayIdentity(year: year, month: month, day: day))
    }
}

// MARK: - Mapping

/// Turns each store's records into the dial's plain inputs. No decisions: which layer, state and words they become is
/// `TodayDialModel`'s call.
nonisolated enum TodayDialInputMapping {
    /// Last night's main sleep with its stage spans laid end to end from its start, as the Sleep tab draws them.
    static func night(_ snapshot: SleepDaySnapshot, provenance: TodayDialProvenance) -> TodayDialNightInput? {
        guard let main = snapshot.mainSleep, main.end > main.start else { return nil }
        return TodayDialNightInput(spans: LooprStageSpan.spans(from: snapshot.hypnogram, start: main.start), start: main.start,
                                   end: main.end, asleepMinutes: main.durationMinutes > 0 ? Double(main.durationMinutes) : nil,
                                   isPartial: main.isPartial, provenance: provenance)
    }

    /// Sleep's 14 nights, with each bedtime on Sleep's noon-based clock.
    static func nights(_ consistency: SleepConsistency) -> [TodayDialNightTiming] {
        consistency.nights.map { night in
            TodayDialNightTiming(day: DayIdentity(year: night.day.year, month: night.day.month, day: night.day.day),
                                 bedMinuteAfterNoon: night.bed)
        }
    }

    /// Sleep's plan, moved from its noon-based clock to minutes after midnight.
    static func tonight(_ plan: SleepTonightPlan?) -> TodayDialTonightInput? {
        guard let plan else { return nil }
        func minuteOfDay(_ minutesAfterNoon: Double) -> Int { ((Int(minutesAfterNoon.rounded()) + 720) % 1_440 + 1_440) % 1_440 }
        return TodayDialTonightInput(bedtimeMinuteOfDay: minuteOfDay(plan.bedtime), wakeMinuteOfDay: minuteOfDay(plan.usualWake),
                                     sleepMinutes: plan.sleepMinutes)
    }

    static func meals(_ meals: [FoodMeal]) -> [TodayDialMealInput] {
        meals.map { meal in
            self.meal(id: meal.id, slot: meal.slot, at: meal.occurredAt,
                      photo: meal.photos.first.map { (id: $0.id, fileName: $0.fileName) }, items: meal.items)
        }
    }

    /// One meal. Its sticker is the meal's first photo, the one Food shows on the meal card.
    static func meal(id: UUID, slot: FoodMealSlot, at: Date, photo: (id: UUID, fileName: String)?,
                     items: [FoodItem]) -> TodayDialMealInput {
        TodayDialMealInput(id: id.uuidString.lowercased(), title: slot.title, at: at,
                           sticker: photo.map { TodayDialSticker(photoID: $0.id, fileName: $0.fileName) },
                           provenance: .food(foodSource(items)), nutrition: nutrition(items))
    }

    /// The meal's totals as Food's review shows them: each counts only the foods that have the value.
    static func nutrition(_ items: [FoodItem]) -> TodayDialMealNutrition? {
        guard !items.isEmpty else { return nil }
        let nutrients: [FoodNutrient] = [.energy, .protein, .carbs, .fat, .fibre]
        let totals = Dictionary(uniqueKeysWithValues: nutrients.map { ($0, FoodNutrientTotal($0, items: items)) })
        let hasValues = items.contains { !$0.nutrients.values.isEmpty }
        return TodayDialMealNutrition(energyKcal: totals[.energy]?.knownValue, proteinGrams: totals[.protein]?.knownValue,
                                      carbsGrams: totals[.carbs]?.knownValue, fatGrams: totals[.fat]?.knownValue,
                                      fibreGrams: totals[.fibre]?.knownValue, items: items.map(\.name),
                                      isPartial: hasValues && totals.values.contains { !$0.isComplete })
    }

    /// A meal with any estimated item reads as a photo estimate, then a barcode, otherwise as logged.
    static func foodSource(_ items: [FoodItem]) -> TodayDialProvenance.Food {
        if items.contains(where: \.isEstimated) { return .photoEstimate }
        if items.contains(where: { $0.provenance.contains { $0.source == .barcode } }) { return .barcode }
        return .logged
    }

    /// Finished workouts, and one still going. Discarded, interrupted and not yet started workouts stay off the dial.
    static func workouts(_ records: [WorkoutRecord], bandName: String) -> [TodayDialWorkoutInput] {
        records.compactMap { record in
            guard let start = record.startedAt else { return nil }
            switch record.state {
            case .completed:
                guard let end = record.endedAt, end > start else { return nil }
                return TodayDialWorkoutInput(id: record.id.uuidString.lowercased(), title: record.activity.displayName, start: start,
                                             end: end, provenance: provenance(record.source, bandName: bandName))
            case .active, .paused, .finishing:
                return TodayDialWorkoutInput(id: record.id.uuidString.lowercased(), title: record.activity.displayName, start: start,
                                             end: nil, provenance: provenance(record.source, bandName: bandName))
            case .selectedActivity, .preparing, .interruptedAndRecoverable, .discarded:
                return nil
            }
        }
    }

    static func provenance(_ source: WorkoutSource, bandName: String) -> TodayDialProvenance {
        switch source {
        case .live, .detected: .band(device: bandName)
        case .imported: .band(device: "WHOOP")
        case .manual: .typedIn
        case .healthKit: .appleHealth(source: "")
        }
    }

    static func provenance(_ source: MetricSampleSource, bandName: String) -> TodayDialProvenance {
        switch source {
        case .band: .band(device: bandName)
        case .appleHealth: .appleHealth(source: "")
        case .whoopExport: .band(device: "WHOOP")
        }
    }

    /// Apple Health's daily total of time in daylight. It carries no times, so the dial spreads it.
    static func daylight(_ result: AppleHealthReadResult, dayKey: String) -> TodayDialDaylightInput {
        switch dailyTotal(result, dayKey: dayKey) {
        case .value(let minutes, let provenance): .dailyTotal(minutes: minutes, provenance: provenance)
        case .missing(let gap): .missing(gap)
        }
    }

    /// The day's total from a daily-aggregate kind (steps, daylight), with the writing source.
    static func dailyTotal(_ result: AppleHealthReadResult, dayKey: String) -> TodayDialReading {
        switch result {
        case .absent(let reason): return .missing(gap(reason))
        case .values(let samples):
            guard let sample = samples.filter({ $0.localDay == dayKey }).max(by: { ($0.end, $0.start) < ($1.end, $1.start) }),
                  sample.value.isFinite, sample.value >= 0 else { return .missing(.noData) }
            return .value(sample.value, .appleHealth(source: sample.provenance.label ?? ""))
        }
    }

    static func gap(_ absence: AppleHealthAbsence) -> TodayDialGap {
        switch absence {
        case .noSamples: .noData
        case .notAuthorized: .notAllowed
        case .switchedOff: .switchedOff
        case .unavailable, .queryFailed: .unavailable
        }
    }

    /// Zone 2 is zone id 2, as the protocol's band check reads it (`RoutineSourceMapping.band`).
    static func zone2(_ zones: [BodyZoneMinutes]?, bandName: String) -> TodayDialReading {
        guard let zone = zones?.first(where: { $0.id == 2 }), zone.minutes.isFinite, zone.minutes >= 0 else { return .missing(.noData) }
        return .value(zone.minutes, .band(device: bandName))
    }

    /// Last night's value (the point on the dial's day) and the values of the nights before it.
    static func sleepHeartRate(_ points: [MetricHistoryPoint], clock: TodayDialClock,
                               bandName: String) -> (reading: TodayDialReading, before: [Double]) {
        let before = points.filter { $0.day < clock.start && $0.value.isFinite && $0.value > 0 }.map(\.value)
        return (today(points, clock: clock, bandName: bandName), before)
    }

    static func today(_ points: [MetricHistoryPoint], clock: TodayDialClock, bandName: String) -> TodayDialReading {
        guard let point = points.last(where: { clock.contains($0.day) }), point.value.isFinite else { return .missing(.noData) }
        return .value(point.value, provenance(point.source, bandName: bandName))
    }

    /// Every rule of the version with its stored check. A rule with no check yet is unknown, never missed.
    static func rules(_ day: TodayDialProtocolDay) -> [TodayDialRuleInput] {
        let checks = Dictionary(day.checks.map { ($0.ruleKey, $0) }, uniquingKeysWith: { _, newer in newer })
        return day.rules.map { rule in
            TodayDialRuleInput(key: rule.key.rawValue, title: rule.title, metric: rule.target.metric,
                               timeOfDayMinutes: rule.timeOfDayMinutes, targetValue: rule.target.value, isEvening: rule.isEvening,
                               source: source(rule.source), state: state(checks[rule.key]?.state))
        }
    }

    static func source(_ source: CheckSource) -> TodayDialRuleSource {
        switch source {
        case .band: .band
        case .food: .food
        case .fitness: .fitness
        case .appleHealth: .appleHealth
        case .manual: .manual
        }
    }

    static func state(_ state: CheckState?) -> TodayDialRuleState {
        switch state {
        case .kept?: .kept
        case .missed?: .missed
        case .pending?: .pending
        // A skipped rule is neither kept nor missed; the dial has no mark for it, so it reads as not checked.
        case .unknown?, .skipped?, nil: .unknown
        }
    }

    /// The alarm while it is on, with the days it rings, as Today's timeline reads it. `weekday` is Foundation's.
    static func alarm(_ plan: WakeAlarmPlan?, weekday: Int) -> TodayDialAlarmInput? {
        guard let fact = TodayAgentSlotBuilder.alarm(plan, weekday: weekday) else { return nil }
        return TodayDialAlarmInput(wakeMinuteOfDay: fact.wakeMinute, smartWindowMinutes: fact.windowMinutes,
                                   ringsToday: fact.ringsToday, ringsTomorrow: fact.ringsTomorrow)
    }
}

// MARK: - Live readers

extension TodayDialSources {
    /// The app's stores behind the dial. Fixture compositions read the fixture stores the other Today sections use.
    @MainActor
    static func live(environment: AppEnvironment, repositories: ProductRepositoryContainer?, history: any MetricHistoryProviding,
                     bandName: String = "") -> TodayDialSources {
        let sleep = SleepNightDetails.repository(environment: environment, repositories: repositories)
        let detail = SleepNightDetails.detailSource(environment: environment, repositories: repositories)
        let persistent = repositories?.persistent
        var food: AppFoodRepository?
        if let persistent { food = AppFoodRepository(store: persistent.food, environment: environment) }
        #if DEBUG
        if food == nil { food = repositories?.fixtureFoodRepository }
        #endif
        let workouts = repositories?.workoutStore
        let appleHealth = persistent?.healthSync.appleHealthSources()
        let analytics = persistent?.analytics
        let routine = persistent.map { RoutineStore(database: $0.database) }
        let readTraining: (@Sendable () async throws -> [WorkoutRecord])? = workouts.map { store in { @Sendable in await store.all() } }
        let provider = RoutineSourceProvider.live(food: food, sleep: sleep, readTraining: readTraining, analytics: analytics,
                                                  appleHealth: appleHealth)
        let alarm = WakeAlarmControllerFactory.make(repositories: repositories)

        let readSleepGoal: (@Sendable () async -> Double?)? = detail.map { source in { @Sendable in await source.sleepGoalMinutes() } }
        let readMeals: (@Sendable (String, String) async throws -> [FoodMeal])? = food.map { repository in
            { @Sendable first, last in try await repository.overview(from: first, through: last).meals }
        }
        let readWorkouts: (@Sendable () async -> [WorkoutRecord])? = workouts.map { store in { @Sendable in await store.all() } }
        let readAppleHealth: (@Sendable (AppleHealthSourceKind, Date, Date) async -> AppleHealthReadResult)? = appleHealth.map { sources in
            { @Sendable kind, start, end in await sources.read(kind, from: start, to: end) }
        }
        let readZones: (@Sendable (DayIdentity) async throws -> [BodyZoneMinutes]?)? = analytics.map { analytics in
            { @Sendable day in try await analytics.readDisplay(day: day)?.projection.body.zoneMinutes }
        }
        // Evaluating stores today's checks, the same way the Protocol tab does, so the beads show current states.
        let readProtocol: (@Sendable (DayIdentity, Date, TimeZone) async throws -> TodayDialProtocolDay?)? = routine.map { store in
            { @Sendable day, now, zone in
                guard let active = try store.activeProtocol() else { return nil }
                let sources = try await provider.snapshots(for: day, timeZoneID: zone.identifier, now: now)
                let result = try RoutineDayEvaluation(store: store).evaluate(day: day, now: now, timeZone: zone, sources: sources)
                return TodayDialProtocolDay(rules: active.latestVersion.rules, checks: result?.checks ?? [])
            }
        }
        let readAlarm: (@Sendable () async -> WakeAlarmPlan?)? = alarm.map { controller in
            { @Sendable in
                let snapshot = await controller.snapshot()
                return snapshot.isOn ? WakeAlarmPlan(configuration: snapshot.configuration) : nil
            }
        }

        return TodayDialSources(
            readSleep: { day in try await sleep.readSleepDay(for: day) },
            readSleepGoalMinutes: readSleepGoal,
            readHistory: { key, days, end in try await history.series(for: key, days: days, endingOn: end) },
            readMeals: readMeals, readWorkouts: readWorkouts, readAppleHealth: readAppleHealth, readZoneMinutes: readZones,
            readProtocol: readProtocol, readAlarm: readAlarm, bandName: bandName)
    }
}
