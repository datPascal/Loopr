import BodyKit
import DomainKit
import FoodKit
import Foundation
import HealthKitBridge
import HeartKit
import JournalKit
import RoutineKit
import SleepKit
import WorkoutKit

// Builds the per-source snapshots that RoutineKit's RuleEvaluator reads. This file maps what the app's repositories
// already hold onto the metric vocabulary and decides nothing: kept, missed, pending and unknown all come from
// RuleEvaluator. A value the repositories do not hold is left out of the snapshot, never filled with zero.

/// What Food holds for one day, as the Journal reads it plus the nutrient totals Food already computes.
nonisolated struct RoutineFoodDay: Sendable {
    /// Meals, drinks and the explicit "day complete" record, as `AppFoodJournalProvider` reads them.
    let intake: JournalFoodDay
    let energy: FoodNutrientTotal
    let protein: FoodNutrientTotal
    let fibre: FoodNutrientTotal
}

/// What the band's analytics hold for one rule day. The night is the one that starts on that day.
nonisolated struct RoutineBandDay: Sendable, Equatable {
    /// Minutes per heart-rate zone for the day, zones 1 to 5. Empty when the analytics have no zone data.
    var zoneMinutes: [BodyZoneMinutes]
    /// The main sleep of the night that starts on the rule day, from the next day's sleep snapshot.
    var night: SleepSessionSummary? = nil
    var sleepLatencyMinutes: Double? = nil
    var sleepingHeartRate: Double? = nil
}

/// The Food tab's stack on one local day: the supplement lanes and the medication lane, as `SupplementStore` reads them.
nonisolated struct RoutineStackDay: Sendable, Equatable {
    var supplements: StackDay
    var medication: StackDay
}

/// A source that is not wired in stays closed, so its rules are unknown.
nonisolated struct RoutineSourceProvider: Sendable {
    var readFood: (@Sendable (DayIdentity, String) async throws -> RoutineFoodDay)?
    /// The day's stack ticks, by local day key (`yyyy-MM-dd`). They are Food readings.
    var readStack: (@Sendable (String) async throws -> RoutineStackDay)? = nil
    var readTraining: (@Sendable () async throws -> [WorkoutRecord])?
    /// Day, time zone identifier and "now". Nil when no band data exists.
    var readBand: (@Sendable (DayIdentity, String, Date) async throws -> RoutineBandDay?)?
    var appleHealth: AppleHealthSources?

    /// Manual ticks are not here. `RoutineDayEvaluation` reads them from the stored checks.
    func snapshots(for day: DayIdentity, timeZoneID: String, now: Date) async throws -> RoutineSourceSnapshots {
        guard let zone = TimeZone(identifier: timeZoneID), let clock = RoutineDayClock(day: day, timeZone: zone) else {
            throw RoutineError.invalidCheck
        }
        let band = try await guarded(.band) {
            guard let readBand, let bandDay = try await readBand(day, timeZoneID, now) else { return nil }
            return RoutineSourceMapping.band(bandDay, clock: clock)
        }
        let meals: RoutineSourceSnapshot? = try await attempt { () async throws -> RoutineSourceSnapshot? in
            guard let readFood else { return nil }
            return RoutineSourceMapping.food(try await readFood(day, timeZoneID), clock: clock)
        }
        let stack: RoutineStackDay? = try await attempt { () async throws -> RoutineStackDay? in
            guard let readStack, let key = day.routineDayKey else { return nil }
            return try await readStack(key)
        }
        let food = RoutineSourceMapping.food(meals: meals, stack: stack)
        let fitness = try await guarded(.fitness) {
            guard let readTraining else { return nil }
            return RoutineSourceMapping.fitness(try await readTraining(), clock: clock)
        }
        return RoutineSourceSnapshots(band: band, food: food, fitness: fitness, appleHealth: await appleHealthSnapshot(clock: clock))
    }

    /// Nil when the read fails or is not wired in. Cancellation still ends the whole read.
    private func attempt<Value>(_ read: () async throws -> Value?) async throws -> Value? {
        do { return try await read() }
        catch is CancellationError { throw CancellationError() }
        catch { return nil }
    }

    /// A source that cannot be read, or is not wired in, is closed. Cancellation still ends the whole read.
    private func guarded(_ source: CheckSource, _ read: () async throws -> RoutineSourceSnapshot?) async throws -> RoutineSourceSnapshot {
        do { return try await read() ?? .closed(source) }
        catch is CancellationError { throw CancellationError() }
        catch { return .closed(source) }
    }

    private func appleHealthSnapshot(clock: RoutineDayClock) async -> RoutineSourceSnapshot {
        guard let appleHealth else { return .closed(.appleHealth) }
        var results: [AppleHealthSourceKind: AppleHealthReadResult] = [:]
        for kind in RoutineSourceMapping.appleHealthKinds.keys {
            results[kind] = await appleHealth.read(kind, from: clock.start, to: clock.end)
        }
        return RoutineSourceMapping.appleHealth(results, clock: clock)
    }
}

nonisolated enum RoutineSourceMapping {
    static let appleHealthKinds: [AppleHealthSourceKind: RoutineMetric] = [
        .steps: .steps, .daylight: .daylightMinutes, .vo2Max: .vo2max, .weight: .weightKg
    ]

    // MARK: Food

    /// The stack's metrics, which Food holds beside the meals.
    static let stackMetrics: [RoutineMetric] = [.supplementsAllTaken, .medicationAllTaken, .supplementAdherence]

    /// Meals and stack ticks are both Food readings but read separately. A part that could not be read blocks only its
    /// own metrics, and with neither the source is closed.
    static func food(meals: RoutineSourceSnapshot?, stack: RoutineStackDay?) -> RoutineSourceSnapshot {
        guard meals != nil || stack != nil else { return .closed(.food) }
        var readings = meals?.readings ?? [:]
        var blocked: [RoutineMetric: RoutineSourceAccess] = [:]
        var items: [RoutineItemMetric: MetricReading] = [:]
        if let stack {
            let ticks = SupplementRoutineFeed.snapshotReadings(supplements: stack.supplements, medication: stack.medication)
            readings.merge(ticks.readings) { _, tick in tick }
            items = ticks.items
        } else {
            for metric in stackMetrics { blocked[metric] = .unavailable }
        }
        if meals == nil {
            for metric in RoutineMetric.metrics(for: .food) where !stackMetrics.contains(metric) { blocked[metric] = .unavailable }
        }
        return RoutineSourceSnapshot(source: .food, blocked: blocked, readings: readings, itemReadings: items)
    }

    static func food(_ day: RoutineFoodDay, clock: RoutineDayClock) -> RoutineSourceSnapshot {
        var readings: [RoutineMetric: MetricReading] = [:]
        for (metric, total) in [(RoutineMetric.energyKcal, day.energy), (.proteinG, day.protein), (.fibreG, day.fibre)] {
            if let reading = MetricReading.quantity(known: total.knownValue, isComplete: total.isComplete) { readings[metric] = reading }
        }
        // Neighbouring dates are read for travel, so keep only what happened inside this day.
        let records = day.intake.records.filter { clock.contains($0.source.occurredAt) }
        let closed = day.intake.completion.map { clock.contains($0.occurredAt) } == true

        // Alcohol: a closed log with every record known gives the total, even zero. Without it, only drinks that were
        // logged count, as a total or as a floor when some records did not say.
        let alcohol = records.compactMap(\.alcoholUnits).filter { $0.isFinite && $0 >= 0 }
        let alcoholSum = alcohol.reduce(0, +)
        let alcoholKnown = alcohol.count == records.count
        if closed && alcoholKnown {
            readings[.alcoholDrinks] = .measured(alcoholSum)
        } else if alcoholSum > 0 {
            readings[.alcoholDrinks] = alcoholKnown ? .measured(alcoholSum) : .atLeast(alcoholSum)
        }

        // "None happened" is a reading only on a closed log that holds at least one entry. A closed log with nothing in
        // it says the person did not log that day, not that they had no coffee or no meal, so the rule stays not known
        // (ICP R1-VET-05).
        let noneHappenedIsKnown = closed && !records.isEmpty

        let caffeine = records.filter { ($0.caffeineMilligrams ?? 0) > 0 }
        let caffeineKnown = records.allSatisfy { $0.caffeineMilligrams.map { $0.isFinite && $0 >= 0 } == true }
        if let last = caffeine.map(\.source.occurredAt).max() {
            let minute = Double(clock.wholeMinute(of: last))
            readings[.lastCaffeineTime] = caffeineKnown ? .measured(minute) : .atLeast(minute)
        } else if noneHappenedIsKnown && caffeineKnown {
            readings[.lastCaffeineTime] = .noEvents
        }

        if let last = records.filter(\.isMeal).map(\.source.occurredAt).max() {
            readings[.lastMealTime] = .measured(Double(clock.wholeMinute(of: last)))
        } else if noneHappenedIsKnown {
            readings[.lastMealTime] = .noEvents
        }
        return RoutineSourceSnapshot(source: .food, readings: readings)
    }

    // MARK: Band

    /// Zone 2 is zone id 2 and the hard minutes are zones 4 and 5. A night counts when the Sleep screen would show it:
    /// complete, with confidence of at least 0.5, and starting on this day or in the next morning.
    static func band(_ day: RoutineBandDay, clock: RoutineDayClock) -> RoutineSourceSnapshot {
        var readings: [RoutineMetric: MetricReading] = [:]
        func minutes(_ ids: Set<Int>) -> MetricReading? {
            let zones = day.zoneMinutes.filter { ids.contains($0.id) }
            guard zones.count == ids.count, zones.allSatisfy({ $0.minutes.isFinite && $0.minutes >= 0 }) else { return nil }
            return .measured(zones.reduce(0) { $0 + $1.minutes })
        }
        if let zone2 = minutes([2]) { readings[.zone2Minutes] = zone2 }
        if let hard = minutes([4, 5]) { readings[.zone45Minutes] = hard }
        if let night = day.night, !night.isPartial, night.confidence >= 0.5, night.end > night.start,
           night.start >= clock.start, night.start < clock.end.addingTimeInterval(18 * 3_600) {
            readings[.inBedTime] = .measured(Double(clock.wholeMinute(of: night.start)))
            if let latency = day.sleepLatencyMinutes, latency.isFinite, latency >= 0 {
                readings[.sleepOnsetTime] = .measured(Double(clock.wholeMinute(of: night.start.addingTimeInterval(latency * 60))))
            }
            if let heartRate = day.sleepingHeartRate, heartRate.isFinite, heartRate > 0 { readings[.sleepHR] = .measured(heartRate) }
        }
        return RoutineSourceSnapshot(source: .band, readings: readings)
    }

    // MARK: Fitness

    /// Counts completed workouts that started on the day. No completed workout leaves the metrics out: a missing log is
    /// not a rest day, which is the same call the Journal makes for "trained today".
    static func fitness(_ workouts: [WorkoutRecord], clock: RoutineDayClock) -> RoutineSourceSnapshot {
        let finished = workouts.compactMap { workout -> (WorkoutRecord, TimeInterval)? in
            guard workout.state == .completed, let start = workout.startedAt, let end = workout.endedAt, end > start,
                  clock.contains(start) else { return nil }
            return (workout, end.timeIntervalSince(start))
        }
        var readings: [RoutineMetric: MetricReading] = [:]
        guard !finished.isEmpty else { return RoutineSourceSnapshot(source: .fitness, readings: readings) }
        readings[.workoutMinutes] = .measured(finished.reduce(0) { $0 + $1.1 } / 60)
        let strength = finished.filter { $0.0.activity == .strength }.count
        let mobility = finished.filter { $0.0.activity == .yoga }.count
        if strength > 0 { readings[.strengthSessions] = .measured(Double(strength)) }
        if mobility > 0 { readings[.mobilitySessions] = .measured(Double(mobility)) }
        return RoutineSourceSnapshot(source: .fitness, readings: readings)
    }

    // MARK: Apple Health

    /// A kind the person switched off or has not allowed blocks only its own metric. A read that found nothing leaves the
    /// metric out.
    static func appleHealth(_ results: [AppleHealthSourceKind: AppleHealthReadResult], clock: RoutineDayClock) -> RoutineSourceSnapshot {
        var readings: [RoutineMetric: MetricReading] = [:]
        var blocked: [RoutineMetric: RoutineSourceAccess] = [:]
        let dayKey = clock.day.routineDayKey
        for (kind, metric) in appleHealthKinds {
            switch results[kind] {
            case nil: blocked[metric] = .unavailable
            case .absent(.switchedOff)?: blocked[metric] = .switchedOff
            case .absent(.notAuthorized)?: blocked[metric] = .denied
            case .absent(.unavailable)?, .absent(.queryFailed)?: blocked[metric] = .unavailable
            case .absent(.noSamples)?: break
            case .values(let samples)?:
                let onDay = kind.isDailyAggregate
                    ? samples.filter { $0.localDay == dayKey }
                    : samples.filter { $0.end >= clock.start && $0.start < clock.end }
                guard let latest = onDay.max(by: { ($0.end, $0.start) < ($1.end, $1.start) }),
                      latest.value.isFinite, latest.value >= 0 else { continue }
                readings[metric] = .measured(latest.value)
            }
        }
        return RoutineSourceSnapshot(source: .appleHealth, blocked: blocked, readings: readings)
    }
}

// MARK: - Live readers

nonisolated extension RoutineSourceProvider {
    /// The app's repositories behind the provider. Pass nil for a source this build does not have.
    static func live(food: AppFoodRepository?, sleep: (any SleepRepository)?,
                     readTraining: (@Sendable () async throws -> [WorkoutRecord])?,
                     analytics: CanonicalDailyAnalytics?, appleHealth: AppleHealthSources?) -> RoutineSourceProvider {
        RoutineSourceProvider(
            readFood: food.map { repository in
                { @Sendable day, timeZoneID in
                    try await RoutineSourceProvider.foodDay(repository: repository, sleep: sleep, day: day, timeZoneID: timeZoneID)
                }
            },
            readStack: food.map { repository in
                { @Sendable localDay in try await repository.stackDays(localDay: localDay) }
            },
            readTraining: readTraining,
            readBand: analytics.map { analytics in
                { @Sendable day, timeZoneID, now in
                    try await RoutineSourceProvider.bandDay(analytics: analytics, day: day, timeZoneID: timeZoneID, now: now)
                }
            },
            appleHealth: appleHealth)
    }

    private static func foodDay(repository: AppFoodRepository, sleep: (any SleepRepository)?, day: DayIdentity,
                                timeZoneID: String) async throws -> RoutineFoodDay {
        guard let zone = TimeZone(identifier: timeZoneID), let clock = RoutineDayClock(day: day, timeZone: zone) else {
            throw FoodError.invalidRecord
        }
        let intake = try await AppFoodJournalProvider(repository: repository, sleep: sleep).foodDay(for: day, timeZoneID: timeZoneID)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let key = try FoodMeal.day(at: clock.start, timeZoneIdentifier: timeZoneID)
        let data = try await repository.overview(from: key, through: key)
        let summary = try FoodDaySummary(date: clock.start, calendar: calendar, data: data)
        return RoutineFoodDay(intake: intake, energy: summary.total(.energy), protein: summary.total(.protein),
                              fibre: summary.total(.fibre))
    }

    private static func bandDay(analytics: CanonicalDailyAnalytics, day: DayIdentity, timeZoneID: String,
                                now: Date) async throws -> RoutineBandDay? {
        guard let display = try await analytics.readDisplay(day: day) else { return nil }
        var result = RoutineBandDay(zoneMinutes: display.projection.body.zoneMinutes)
        // The night is scored in the next day's snapshot, so it exists once that day has started.
        guard let zone = TimeZone(identifier: timeZoneID), let clock = RoutineDayClock(day: day, timeZone: zone), clock.end <= now else {
            return result
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.year, .month, .day], from: clock.end)
        guard let year = parts.year, let month = parts.month, let next = parts.day,
              let following = try await analytics.readDisplay(day: DayIdentity(year: year, month: month, day: next)) else { return result }
        result.night = following.projection.sleep.mainSleep
        result.sleepLatencyMinutes = following.projection.sleep.metrics.first { $0.id == "latency" }?.numericValue
        result.sleepingHeartRate = following.projection.heart.metrics.first { $0.id == .sleepingHeartRate }?.numericValue
        return result
    }
}
