import FoodKit
import Foundation
import Testing

/// The status line under the hero and the finished day's summary (UX R2-DES-01, R1-NEW-04, R2-NEW-04).
struct FoodDayStatusTests {
    private let zone = "UTC"
    private let noon = Date(timeIntervalSince1970: 1_767_268_800)
    private var calendar: Calendar { Longevity.calendar(zone) }

    private func item(_ name: String, _ nutrients: [FoodNutrient: Double]) -> FoodItem {
        FoodItem(name: name, amount: 1, unit: .serving, nutrients: .init(nutrients), provenance: [.init(source: .typed, recordedAt: noon)])
    }

    private func day(_ items: [FoodItem], days: [FoodDayRecord] = [], drinks: [FoodDrink] = []) throws -> FoodDaySummary {
        let store = try LongevityStore()
        let meals = try items.isEmpty ? [] : [store.meal(at: noon, zone: zone, items: items)]
        return try FoodDaySummary(date: noon, calendar: calendar, data: .init(meals: meals, drinks: drinks, days: days, targets: []))
    }

    @Test func namesTheNutrientFurthestBehindByShareOfItsTarget() throws {
        // Protein 82 of 150 is 55%; fibre 17 of 35 is 49%.
        let summary = try day([item("Bowl", [.energy: 900, .protein: 82, .fibre: 17])])
        #expect(FoodDayStatus.gapLine(day: summary, proteinTarget: 150, fibreTarget: 35) == "Fibre is furthest behind at 17 of 35 g.")
        #expect(FoodDayStatus.gapLine(day: summary, proteinTarget: 200, fibreTarget: 35) == "Protein is furthest behind at 82 of 200 g.")
    }

    @Test func withOneTargetOrOneReachedItNamesTheOtherWithoutRanking() throws {
        let summary = try day([item("Bowl", [.energy: 900, .protein: 82, .fibre: 40])])
        #expect(FoodDayStatus.gapLine(day: summary, proteinTarget: 150, fibreTarget: nil) == "Protein is at 82 of 150 g.")
        #expect(FoodDayStatus.gapLine(day: summary, proteinTarget: 150, fibreTarget: 35) == "Protein is at 82 of 150 g.")
        #expect(FoodDayStatus.gapLine(day: summary, proteinTarget: 80, fibreTarget: 35) == "Protein and fibre have reached their targets.")
    }

    @Test func aTotalMissingSomeFoodsSaysKnown() throws {
        let summary = try day([item("Bowl", [.energy: 500, .protein: 30, .fibre: 10]), item("Toast", [.energy: 200])])
        #expect(FoodDayStatus.gapLine(day: summary, proteinTarget: 150, fibreTarget: 35) == "Protein is furthest behind with 30 of 150 g known.")
    }

    @Test func nothingLoggedOrNoTargetsGivesNoLine() throws {
        #expect(FoodDayStatus.gapLine(day: try day([]), proteinTarget: 150, fibreTarget: 35) == nil)
        let summary = try day([item("Bowl", [.energy: 500, .protein: 30])])
        #expect(FoodDayStatus.gapLine(day: summary, proteinTarget: nil, fibreTarget: nil) == nil)
        // Fibre not known at all, and no protein target: nothing to measure against.
        #expect(FoodDayStatus.gapLine(day: summary, proteinTarget: nil, fibreTarget: 35) == nil)
    }

    @Test func aFinishedDayReadsAsOneLineWithTheAlcoholAnswer() throws {
        let record = try FoodDayRecord(dayStart: noon, timeZoneIdentifier: zone, completedAt: noon, noAlcoholAt: noon)
        let summary = try day([item("Bowl", [.energy: 900, .protein: 82, .fibre: 18])], days: [record])
        #expect(FoodDayStatus.finishedSummary(day: summary, proteinTarget: 150, fibreTarget: nil) == "Protein 82 of 150 g · fibre 18 g · no alcohol")
        let wine = try FoodDrink(kind: .alcohol, name: "Wine", occurredAt: noon, timeZoneIdentifier: zone, alcoholUnits: 1.5, energy: 125, confirmedAt: noon)
        let open = try day([item("Bowl", [.energy: 900, .protein: 82, .fibre: 18])], drinks: [wine])
        #expect(FoodDayStatus.finishedSummary(day: open, proteinTarget: 150, fibreTarget: 35) == "Protein 82 of 150 g · fibre 18 of 35 g · 1.5 units of alcohol")
    }
}
