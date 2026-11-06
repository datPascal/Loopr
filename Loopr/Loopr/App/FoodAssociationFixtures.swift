#if DEBUG
import DomainKit
import FoodKit
import Foundation
import JournalKit
import WorkoutKit

/// Synthetic source records for visual review. Statistics are calculated by the production engine.
nonisolated enum FoodAssociationFixtures {
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("--loopr-food-associations-fixture") }
    static func workouts(endingOn anchor: Date) -> [WorkoutRecord] {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Australia/Perth")!
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let today = calendar.date(from: utc.dateComponents([.year, .month, .day], from: anchor))!
        return (-119..<0).filter { ($0 + 120) % 3 == 0 }.map { offset in
            let day = calendar.date(byAdding: .day, value: offset, to: today)!
            let start = day.addingTimeInterval(17 * 3600), end = start.addingTimeInterval(3600)
            return WorkoutRecord(id: UUID(uuidString: String(format: "FC300000-0000-4000-8000-%012d", offset + 120))!,
                identity: .make(activity: .strength, sourceKey: "food-visual-workout", startedAt: start, endedAt: end),
                activity: .strength, source: .manual, state: .completed, createdAt: start, startedAt: start,
                endedAt: end, finalizationStage: .activeStateCleared)
        }
    }
    static func seedHistory(_ store: FoodStore, today: Date, calendar: Calendar) throws {
        let first = calendar.date(byAdding: .day, value: -120, to: today)!
        try store.confirmTarget(.init(goal: .maintain, baseEnergy: 2270, protein: 150, carbs: 280, fat: 80,
                                     waterMillilitres: 2500, confirmedAt: first))
        for offset in -119..<(-6) {
            let day = calendar.date(byAdding: .day, value: offset, to: today)!
            let highProtein = (offset + 120) % 3 == 0
            let late = (offset + 120) % 4 >= 2
            let dinnerHour = late ? 21.3 + Double((offset + 120) % 5) / 5 : 18.7 + Double((offset + 120) % 5) / 5
            for (slot, hour, protein) in [(FoodMealSlot.breakfast, 8.0, 30.0), (.lunch, 12.5, 45.0), (.dinner, dinnerHour, highProtein ? 85.0 : 45.0)] {
                let time = day.addingTimeInterval(hour * 3600)
                let item = FoodItem(name: slot == .breakfast ? "Oats and yogurt" : slot == .lunch ? "Chicken and rice" : "Fish and vegetables",
                    amount: 1, unit: .serving, nutrients: .init([.energy: 650, .protein: protein, .carbs: 70, .fat: 22,
                        .fibre: Double(6 + (offset + 120) % 5), .sugar: 5, .salt: 1, .caffeine: 0, .alcoholUnits: 0]),
                    provenance: [.init(source: .typed, recordedAt: time)])
                try store.confirm(.init(slot: slot, occurredAt: time, timeZoneIdentifier: calendar.timeZone.identifier, items: [item]), at: time)
            }
            try store.confirmDayComplete(on: day, timeZoneIdentifier: calendar.timeZone.identifier, at: day.addingTimeInterval(23.5 * 3600))
        }
    }
    static func outcomes(input: FoodAssociationInput) -> [HabitOutcomeSnapshot] {
        input.records.enumerated().compactMap { index, record in
            guard let zone = TimeZone(identifier: record.behaviorTimeZoneID),
                  let summary = input.days.first(where: { $0.localDay == record.behaviorDay.habitKey }) else { return nil }
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
            let next = calendar.date(byAdding: .day, value: 1, to: summary.date)!
            let parts = calendar.dateComponents([.year, .month, .day], from: next)
            let highProtein = record.response(for: FoodAssociationKind.proteinTarget.id)?.answer == .yes
            let late = record.response(for: FoodAssociationKind.lateMeal.id)?.answer == .yes
            let noise = Double((index * 17) % 11 - 5)
            let sleepStart = summary.date.addingTimeInterval(23 * 3600)
            return .init(behaviorDay: record.behaviorDay, behaviorTimeZoneID: zone.identifier,
                sleepSessionID: "food-fixture-" + record.behaviorDay.habitKey, sleepStartedAt: sleepStart,
                sleepEndedAt: sleepStart.addingTimeInterval(8 * 3600),
                outcomeDay: .init(year: parts.year!, month: parts.month!, day: parts.day!),
                metrics: [.deepSleepMinutes: (late ? 56 : 73) + noise, .recoveryScore: 70 + (highProtein ? 5 : 0) + noise],
                priorDayStrain: Double(8 + index % 5), sourceVersions: ["sleep": "synthetic-food-visual.v1", "today": "synthetic-food-visual.v1"],
                builtAt: sleepStart.addingTimeInterval(9 * 3600))
        }
    }
}
#endif
