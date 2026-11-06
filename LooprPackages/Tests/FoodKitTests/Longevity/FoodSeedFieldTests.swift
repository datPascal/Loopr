import FoodKit
import Foundation
import Testing

struct FoodSeedFieldTests {
    private static let old = ["blueberries", "oats", "walnuts", "raspberries", "chia seeds", "banana", "almonds", "strawberries",
                              "buckwheat", "flaxseed", "apple", "cinnamon", "blackberries", "pumpkin seeds", "avocado", "brown rice",
                              "quinoa", "chickpeas", "spinach", "lemon", "lentils"]
    private static let more = ["kale", "ginger", "dill", "onion", "courgette", "tomato", "basil", "peas", "mint", "garlic", "broccoli",
                               "potato", "carrot", "parsley", "lime", "black beans"]

    private func item(_ names: [String], list: FoodPlantList) -> FoodItem {
        FoodItem(name: "Bowl", amount: 1, unit: .serving, provenance: [.init(source: .typed, recordedAt: Longevity.stamp)],
                 plantEdits: FoodPlantEdits(added: names.compactMap { list.reference(forName: $0) }))
    }

    /// The contract week: 21 plants on Monday that last week also had, then fennel, hemp seeds and shiitake, one a day.
    private func contractWeek(_ context: LongevityStore, extra: [String] = []) throws -> (FoodPlantWeek, [FoodWeekPlant]) {
        let list = try Longevity.list()
        let meals = try [
            context.meal(at: Longevity.instant(2026, 10, 13), zone: Longevity.berlin, items: [item(Self.old, list: list)]),
            context.meal(at: Longevity.instant(2026, 10, 19), zone: Longevity.berlin, items: [item(Self.old + extra, list: list)]),
            context.meal(at: Longevity.instant(2026, 10, 20), zone: Longevity.berlin, items: [item(["fennel"], list: list)]),
            context.meal(at: Longevity.instant(2026, 10, 21), zone: Longevity.berlin, items: [item(["hemp seeds"], list: list)]),
            context.meal(at: Longevity.instant(2026, 10, 22), zone: Longevity.berlin, items: [item(["shiitake"], list: list)]),
        ]
        let week = FoodPlantWeek(week: try FoodISOWeek(containing: "2026-10-22"), meals: meals, list: list)
        let earlier = FoodPlantWeek(week: try FoodISOWeek(containing: "2026-10-13"), meals: meals, list: list)
        return (week, week.newPlants(comparedWith: [earlier]))
    }

    @Test func thirtySlotsFillInTheOrderPlantsWereFirstEatenWithTheNewOnesMarked() throws {
        let context = try LongevityStore()
        let (week, new) = try contractWeek(context)
        let field = FoodSeedField(week: week, new: new)
        #expect(field.count == 24 && field.remaining == 6)
        #expect(field.seeds.count == 30)
        #expect(field.seeds.filter { $0.plant != nil }.count == 24)
        #expect(field.seeds[24...].allSatisfy { $0.plant == nil && !$0.isNew && $0.colorHex == nil })
        let newKeys = field.seeds[21...23].map { $0.plant?.key }
        #expect(newKeys == ["fennel", "hemp-seed", "shiitake"])
        #expect(field.seeds[21...23].allSatisfy { $0.isNew })
        #expect(field.seeds[..<21].allSatisfy { !$0.isNew })
        #expect(Set(field.seeds.map(\.id)).count == 30)
    }

    @Test func eachCategoryHasItsSeedShapeAndAStableColour() throws {
        let context = try LongevityStore()
        let (week, new) = try contractWeek(context)
        let field = FoodSeedField(week: week, new: new)
        func seed(_ key: String) -> FoodSeed? { field.seeds.first { $0.plant?.key == key } }
        #expect(seed("shiitake")?.shape == .cap)
        #expect(seed("fennel")?.shape == .round)
        #expect(seed("hemp-seed")?.shape == .almond)
        #expect(seed("walnut")?.shape == .almond)
        #expect(seed("oats")?.shape == .grain)
        #expect(seed("chickpea")?.shape == .bean)
        #expect(seed("cinnamon")?.shape == .leaf)
        #expect(seed("apple")?.shape == .berry)
        #expect(FoodSeedShape(nil) == .round)
        let again = FoodSeedField(week: week, new: new)
        #expect(field.seeds.map(\.colorHex) == again.seeds.map(\.colorHex))
        #expect(field.seeds.compactMap(\.colorHex).allSatisfy { $0.count == 7 && $0.hasPrefix("#") })
    }

    @Test func theSentenceNamesTheNewestAndCountsToThirtyWhileTheWeekHasDaysLeft() throws {
        let context = try LongevityStore()
        let (week, new) = try contractWeek(context)
        let field = FoodSeedField(week: week, new: new)
        #expect(field.sentence(today: "2026-10-22") == "New this week: shiitake, hemp seeds and fennel. Six more by Sunday.")
        // On Sunday there is no day left to count toward.
        #expect(field.sentence(today: "2026-10-25") == "New this week: shiitake, hemp seeds and fennel.")
        // With no earlier week to compare, nothing is called new.
        #expect(field.sentence(today: "2026-10-22", comparedWithEarlierWeeks: false) == "Latest: shiitake, hemp seeds and fennel. Six more by Sunday.")
    }

    @Test func largerCountsAreDigitsAndAFullWeekSaysSo() throws {
        let list = try Longevity.list()
        let context = try LongevityStore()
        let week = try FoodISOWeek(containing: "2026-10-22")
        let eighteen = try context.meal(at: Longevity.instant(2026, 10, 20), zone: Longevity.berlin, items: [item(Array(Self.old.prefix(18)), list: list)])
        let short = FoodSeedField(week: FoodPlantWeek(week: week, meals: [eighteen], list: list), new: [])
        #expect(short.sentence(today: "2026-10-22") == "12 more by Sunday.")

        let thirty = try context.meal(at: Longevity.instant(2026, 10, 21), zone: Longevity.berlin, items: [item(Self.old + Array(Self.more.prefix(9)), list: list)])
        let full = FoodSeedField(week: FoodPlantWeek(week: week, meals: [thirty], list: list), new: [])
        #expect(full.count == 30 && full.remaining == 0)
        #expect(full.sentence(today: "2026-10-22") == "That makes 30 this week.")
    }

    @Test func aWeekPastThirtyAddsARowSoEveryPlantKeepsItsSeed() throws {
        let list = try Longevity.list()
        let context = try LongevityStore()
        let meal = try context.meal(at: Longevity.instant(2026, 10, 21), zone: Longevity.berlin, items: [item(Self.old + Array(Self.more.prefix(13)), list: list)])
        let field = FoodSeedField(week: FoodPlantWeek(week: try FoodISOWeek(containing: "2026-10-22"), meals: [meal], list: list), new: [])
        #expect(field.count == 34)
        #expect(field.seeds.count == 40)
        #expect(field.seeds.filter { $0.plant != nil }.count == 34)
    }

    @Test func anEmptyWeekDrawsThirtyEmptySlotsAndSaysHowTheyFill() throws {
        let week = FoodPlantWeek(week: try FoodISOWeek(containing: "2026-10-22"), meals: [], list: try Longevity.list())
        let field = FoodSeedField(week: week, new: [])
        #expect(field.seeds.count == 30 && field.seeds.allSatisfy { $0.plant == nil })
        #expect(field.sentence(today: "2026-10-22") == "No plants counted yet this week. Photos, barcodes and your edits add them.")
    }
}
