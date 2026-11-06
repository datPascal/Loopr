import DomainKit
import Foundation
import FoodKit
import JournalKit
import SleepKit
import WorkoutKit

nonisolated struct AppJournalAutoFillProvider: JournalAutoFillProviding {
    let readTraining: @Sendable () async throws -> [WorkoutRecord]
    var readFood: (@Sendable (DayIdentity, String) async throws -> JournalFoodDay)? = nil

    func snapshot(for day: DayIdentity, timeZoneID: String) async throws -> JournalAutoFillSnapshot {
        let workouts = try await readTraining()
        let records = workouts.compactMap { workout -> JournalSourceRecord? in
            guard workout.state == .completed, let start = workout.startedAt,
                  let end = workout.endedAt, end > start else { return nil }
            return .init(id: "workout:\(workout.id.uuidString)", domain: .train,
                title: workout.activity.displayName, occurredAt: start, updatedAt: workout.lastCheckpointAt ?? end)
        }
        let food = try await readFood?(day, timeZoneID)
        return try JournalAutoFillProjection.snapshot(day: day, timeZoneID: timeZoneID, food: food, training: records)
    }
}

nonisolated struct AppFoodJournalProvider: Sendable {
    let repository: AppFoodRepository
    let sleep: (any SleepRepository)?

    func foodDay(for day: DayIdentity, timeZoneID: String) async throws -> JournalFoodDay {
        guard let zone = TimeZone(identifier: timeZoneID) else { throw FoodError.invalidRecord }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        guard let date = calendar.date(from: .init(era: day.era, year: day.year, month: day.month, day: day.day)),
              let next = calendar.date(byAdding: .day, value: 1, to: date) else { throw FoodError.invalidRecord }
        let key = try FoodMeal.day(at: date, timeZoneIdentifier: timeZoneID)
        // Stored civil dates use the entry's original time zone. Read enough
        // neighbouring dates for travel; the projection filters absolute time.
        guard let first = calendar.date(byAdding: .day, value: -2, to: date),
              let last = calendar.date(byAdding: .day, value: 3, to: date) else { throw FoodError.invalidRecord }
        let data = try await repository.overview(
            from: FoodMeal.day(at: first, timeZoneIdentifier: timeZoneID),
            through: FoodMeal.day(at: last, timeZoneIdentifier: timeZoneID))
        var records = data.meals.map { meal in
            func nutrient(_ nutrient: FoodNutrient) -> Double? {
                let total = FoodNutrientTotal(nutrient, items: meal.items)
                return total.isComplete || (total.knownValue ?? 0) > 0 ? total.knownValue : nil
            }
            return JournalIntakeRecord(source: .init(id: "food-meal:\(meal.id.uuidString)", domain: .food,
                title: meal.items.map(\.name).joined(separator: ", "), occurredAt: meal.occurredAt, updatedAt: meal.confirmedAt),
                alcoholUnits: nutrient(.alcoholUnits), caffeineMilligrams: nutrient(.caffeine), isMeal: true)
        }
        records += data.drinks.map { drink in
            .init(source: .init(id: "food-drink:\(drink.id.uuidString)", domain: .food, title: drink.name,
                occurredAt: drink.occurredAt, updatedAt: drink.confirmedAt), alcoholUnits: drink.knownAlcoholUnits,
                caffeineMilligrams: drink.knownCaffeineMilligrams, isMeal: false)
        }
        let completed = data.days.first { $0.localDay == key && $0.timeZoneIdentifier == timeZoneID }.flatMap { day -> JournalSourceRecord? in
            day.completedAt.map { .init(id: "food-completion:\(key)", domain: .food, title: "Completed food log",
                occurredAt: day.dayStart, updatedAt: $0) }
        }
        var bedtime: JournalSourceRecord?
        if let sleep {
            let parts = calendar.dateComponents([.era, .year, .month, .day], from: next)
            let identity = DayIdentity(era: parts.era ?? 1, year: parts.year!, month: parts.month!, day: parts.day!)
            if let night = try await sleep.readSleepDay(for: identity)?.mainSleep,
               !night.isPartial, night.confidence >= 0.5, night.end > night.start {
                bedtime = .init(id: "sleep:\(night.id)", domain: .sleep, title: "Main sleep",
                    occurredAt: night.start, updatedAt: night.end)
            }
        }
        return .init(records: records, completion: completed, bedtime: bedtime)
    }
}
