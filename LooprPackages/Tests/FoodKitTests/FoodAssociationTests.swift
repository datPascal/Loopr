import DomainKit
import FoodKit
import Foundation
import JournalKit
import StorageKit
import Testing

struct FoodAssociationTests {
    private var calendar: Calendar { var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(identifier: "Australia/Perth")!; return value }
    private var anchor: Date { calendar.date(from: .init(year: 2026, month: 9, day: 30, hour: 12))! }
    @Test func incompleteAndUnknownNutrientsDoNotBecomeNegativeAnswersOrZeroAverages() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FoodAssociationTests-" + UUID().uuidString)
        let database = try StorageDatabase(url: directory.appendingPathComponent("food.sqlite"))
        defer { try? database.databasePool.close(); try? FileManager.default.removeItem(at: directory) }
        let store = FoodStore(database: database)
        let day = calendar.startOfDay(for: anchor)
        try store.confirmTarget(.init(goal: .maintain, baseEnergy: 2000, protein: 150, carbs: 200, fat: 70, waterMillilitres: 2000, confirmedAt: day.addingTimeInterval(-1)))
        let item = FoodItem(name: "Dinner", amount: 1, unit: .serving, nutrients: .init(), provenance: [.init(source: .typed, recordedAt: day)])
        try store.confirm(.init(slot: .dinner, occurredAt: day.addingTimeInterval(22 * 3600), timeZoneIdentifier: calendar.timeZone.identifier, items: [item]), at: day.addingTimeInterval(22 * 3600))
        var data = try store.overview(from: "2026-09-01", through: "2026-09-30")
        let incomplete = try FoodAssociationInput(data: data, endingOn: anchor, calendar: calendar, trainingDays: [])
        #expect(incomplete.records.isEmpty && incomplete.days.isEmpty)
        try store.confirmDayComplete(on: day, timeZoneIdentifier: calendar.timeZone.identifier, at: day.addingTimeInterval(23 * 3600))
        data = try store.overview(from: "2026-09-01", through: "2026-09-30")
        let input = try FoodAssociationInput(data: data, endingOn: anchor, calendar: calendar, trainingDays: [])
        #expect(input.records[0].response(for: FoodAssociationKind.lateMeal.id)?.answer == .yes)
        #expect(input.records[0].response(for: FoodAssociationKind.proteinTarget.id) == nil)
        let report = try await input.analyze(outcomes: [], at: anchor)
        #expect(report.protein(training: false) == nil && report.fiber == nil && report.points.isEmpty)
    }
    /// A completed day answers alcohol and late caffeine from what was logged: any drink or item that reports some counts,
    /// and caffeine counts as late from 14:00.
    @Test func completedDaysAnswerAlcoholAndLateCaffeine() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FoodAssociationTests-" + UUID().uuidString)
        let database = try StorageDatabase(url: directory.appendingPathComponent("food.sqlite"))
        defer { try? database.databasePool.close(); try? FileManager.default.removeItem(at: directory) }
        let store = FoodStore(database: database)
        let zone = calendar.timeZone.identifier
        let end = calendar.startOfDay(for: anchor)
        func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: end)! }
        func meal(_ date: Date, _ nutrients: FoodNutrients = .init()) throws {
            let item = FoodItem(name: "Meal", amount: 1, unit: .serving, nutrients: nutrients, provenance: [.init(source: .typed, recordedAt: date)])
            try store.confirm(.init(slot: .dinner, occurredAt: date, timeZoneIdentifier: zone, items: [item]), at: date)
        }
        // Day -3: wine at dinner, a morning coffee. Day -2: a 15:00 coffee, nothing else. Day -1: a beer logged as food at 20:00
        // and cola with caffeine at 16:30. Day 0: dinner only.
        try meal(day(-3).addingTimeInterval(19 * 3600))
        try store.confirmDrink(FoodDrink(kind: .alcohol, name: "Wine", occurredAt: day(-3).addingTimeInterval(19 * 3600), timeZoneIdentifier: zone,
                                         alcoholUnits: 1.5, confirmedAt: day(-3).addingTimeInterval(19 * 3600)))
        try store.confirmDrink(FoodDrink(kind: .caffeine, name: "Coffee", occurredAt: day(-3).addingTimeInterval(8 * 3600), timeZoneIdentifier: zone,
                                         caffeineMilligrams: 90, confirmedAt: day(-3).addingTimeInterval(8 * 3600)))
        try store.confirmDrink(FoodDrink(kind: .caffeine, name: "Coffee", occurredAt: day(-2).addingTimeInterval(15 * 3600), timeZoneIdentifier: zone,
                                         caffeineMilligrams: 90, confirmedAt: day(-2).addingTimeInterval(15 * 3600)))
        try meal(day(-1).addingTimeInterval(20 * 3600), .init([.alcoholUnits: 1.8]))
        try meal(day(-1).addingTimeInterval(16.5 * 3600), .init([.caffeine: 35]))
        try meal(day(0).addingTimeInterval(19 * 3600))
        for offset in -3...0 { try store.confirmDayComplete(on: day(offset), timeZoneIdentifier: zone, at: day(offset).addingTimeInterval(23 * 3600)) }

        let input = try FoodAssociationInput(data: store.overview(from: "2026-09-01", through: "2026-09-30"), endingOn: anchor, calendar: calendar, trainingDays: nil)
        func answers(_ kind: FoodAssociationKind) -> [HabitAnswer?] {
            ["2026-09-27", "2026-09-28", "2026-09-29", "2026-09-30"].map { key in
                input.records.first { $0.behaviorDay.habitKey == key }?.response(for: kind.id)?.answer
            }
        }
        #expect(answers(.alcohol) == [.yes, .no, .yes, .no])
        #expect(answers(.lateCaffeine) == [.no, .yes, .yes, .no], "the 08:00 coffee is not late")
        #expect(FoodAssociationKind.alcohol.id.rawValue.uuidString == "FC100000-0000-4000-8000-000000000003")
        #expect(FoodAssociationKind.lateMeal.id.rawValue.uuidString == "FC100000-0000-4000-8000-000000000001", "stored ids never change")
        #expect(FoodAssociationKind.proteinTarget.id.rawValue.uuidString == "FC100000-0000-4000-8000-000000000002")
    }

    @Test func lateConfirmationRemainsIneligibleAndSourceRemovalRemovesTheAnswer() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FoodAssociationTests-" + UUID().uuidString)
        let database = try StorageDatabase(url: directory.appendingPathComponent("food.sqlite"))
        defer { try? database.databasePool.close(); try? FileManager.default.removeItem(at: directory) }
        let store = FoodStore(database: database)
        let day = calendar.startOfDay(for: anchor)
        let confirmed = day.addingTimeInterval(4 * 86400)
        let item = FoodItem(name: "Dinner", amount: 1, unit: .serving, nutrients: .init([.protein: 30]), provenance: [.init(source: .typed, recordedAt: confirmed)])
        let meal = try store.confirm(.init(slot: .dinner, occurredAt: day.addingTimeInterval(21 * 3600), timeZoneIdentifier: calendar.timeZone.identifier, items: [item]), at: confirmed)
        try store.confirmDayComplete(on: day, timeZoneIdentifier: calendar.timeZone.identifier, at: confirmed)
        let input = try FoodAssociationInput(data: store.overview(from: "2026-09-01", through: "2026-09-30"), endingOn: anchor, calendar: calendar, trainingDays: nil)
        let response = try #require(input.records.first?.responses.first)
        #expect(response.answer == .no && response.firstAnsweredAt == confirmed)
        #expect(HabitEligibility.exclusion(for: response) == .lateFirstEntry)
        try store.deleteMeal(id: meal.id, expectedRevision: meal.revision)
        let removed = try FoodAssociationInput(data: store.overview(from: "2026-09-01", through: "2026-09-30"), endingOn: anchor, calendar: calendar, trainingDays: nil)
        #expect(removed.records.isEmpty)
    }
    @Test func completedHistoryUsesTheHabitEngineAndKnownThirtyDayAverages() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FoodAssociationTests-" + UUID().uuidString)
        let database = try StorageDatabase(url: directory.appendingPathComponent("food.sqlite"))
        defer { try? database.databasePool.close(); try? FileManager.default.removeItem(at: directory) }
        let store = FoodStore(database: database)
        let end = calendar.startOfDay(for: anchor)
        let first = calendar.date(byAdding: .day, value: -59, to: end)!
        try store.confirmTarget(.init(goal: .maintain, baseEnergy: 2000, protein: 150, confirmedAt: first.addingTimeInterval(-1)))
        var outcomes: [HabitOutcomeSnapshot] = []
        var trained: Set<String> = []
        for index in 0..<60 {
            let day = calendar.date(byAdding: .day, value: index, to: first)!
            let late = index % 2 == 0
            let highProtein = index % 3 == 0
            let time = day.addingTimeInterval((late ? 22 : 20) * 3600)
            let item = FoodItem(name: "Dinner", amount: 1, unit: .serving,
                nutrients: .init([.protein: highProtein ? 160 : 120, .fibre: 24]),
                provenance: [.init(source: .typed, recordedAt: time)])
            let meal = try store.confirm(.init(slot: .dinner, occurredAt: time,
                timeZoneIdentifier: calendar.timeZone.identifier, items: [item]), at: time)
            try store.confirmDayComplete(on: day, timeZoneIdentifier: calendar.timeZone.identifier, at: time)
            let behavior = DayIdentity(habitKey: meal.localDay)!
            let next = calendar.date(byAdding: .day, value: 1, to: day)!
            let outcome = DayIdentity(habitKey: try FoodMeal.day(at: next, timeZoneIdentifier: calendar.timeZone.identifier))!
            if highProtein { trained.insert(meal.localDay) }
            outcomes.append(.init(behaviorDay: behavior, behaviorTimeZoneID: calendar.timeZone.identifier,
                sleepSessionID: meal.localDay, sleepStartedAt: day.addingTimeInterval(23 * 3600),
                sleepEndedAt: next.addingTimeInterval(7 * 3600), outcomeDay: outcome,
                metrics: [.deepSleepMinutes: (late ? 55 : 75) + Double(index % 7),
                          .recoveryScore: (highProtein ? 80 : 70) + Double(index % 5)],
                priorDayStrain: Double(5 + index % 9), sourceVersions: ["test": "1"], builtAt: next))
        }
        let input = try FoodAssociationInput(data: store.overview(from: "2026-01-01", through: "2026-09-30"),
            endingOn: anchor, calendar: calendar, trainingDays: trained)
        let report = try await input.analyze(outcomes: outcomes, at: anchor)
        let reference = InMemoryHabitStore(definitions: input.definitions, dayRecords: input.screenRecords, outcomes: outcomes)
        let expected = try await HabitInsightEngine().recalculateAll(store: reference, calculatedAt: anchor, endingOn: DayIdentity(habitKey: input.endDay))
        #expect(report.estimates == expected)
        #expect(report.recentDays.count == 30 && report.points.count == 30)
        #expect(report.protein(training: true) == 160 && report.protein(training: false) == 120)
        #expect(report.fiber == 24 && report.eatingWindowMinutes == 0)
        #expect(report.row(.lateMeal).sample?.yesCount == 30)
        #expect(report.row(.lateMeal).sample?.noCount == 30)
        #expect(report.row(.lateMeal).difference != nil)
        let future = calendar.date(byAdding: .day, value: 100, to: anchor)!
        let staleInput = try FoodAssociationInput(data: store.overview(from: "2026-01-01", through: "2027-12-31"),
            endingOn: future, calendar: calendar, trainingDays: trained)
        let staleReport = try await staleInput.analyze(outcomes: outcomes, at: future)
        #expect(staleReport.recentDays.isEmpty && staleReport.points.isEmpty)
        #expect(staleReport.row(.lateMeal).difference == nil)
        #expect(staleReport.row(.lateMeal).status == .unavailable)
        #expect(staleReport.estimates.allSatisfy { $0.eligibleDayCount == 0 })
    }

    @Test func mixedRecordedZonesAreExcludedInsteadOfUsingTheDisplayZone() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FoodAssociationTests-" + UUID().uuidString)
        let database = try StorageDatabase(url: directory.appendingPathComponent("food.sqlite"))
        defer { try? database.databasePool.close(); try? FileManager.default.removeItem(at: directory) }
        let store = FoodStore(database: database)
        let day = calendar.startOfDay(for: anchor)
        let time = day.addingTimeInterval(22 * 3600)
        let item = FoodItem(name: "Dinner", amount: 1, unit: .serving, nutrients: .init([.protein: 30]),
            provenance: [.init(source: .typed, recordedAt: time)])
        for zone in ["Australia/Perth", "Europe/London"] {
            try store.confirm(.init(slot: .dinner, occurredAt: time, timeZoneIdentifier: zone, items: [item]), at: time)
        }
        try store.confirmDayComplete(on: day, timeZoneIdentifier: calendar.timeZone.identifier, at: time)
        let input = try FoodAssociationInput(data: store.overview(from: "2026-09-01", through: "2026-09-30"),
            endingOn: anchor, calendar: calendar, trainingDays: nil)
        #expect(input.days.isEmpty && input.records.isEmpty)
    }

}
