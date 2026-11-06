import FoodKit
import Foundation
import Testing

private let referenceNow = Date(timeIntervalSince1970: 1_700_000_000)

@Suite struct FoodReferenceTests {
    let reference: FoodReference
    init() throws { reference = try #require(FoodReference.shared) }

    @Test func bundledTableLoadsWithItsEverydayNames() throws {
        #expect(reference.foods.count > 7_000)
        #expect(reference.everyday("eggs")?.name == "Egg, whole, cooked, hard-boiled")
        #expect(reference.everyday("Greek yoghurt")?.name == "Yogurt, Greek, plain, nonfat")
        #expect(reference.everyday("overnight oats with berries") == nil)
    }

    @Test(arguments: [
        ("eggs", "Egg, whole, cooked, hard-boiled"), ("chicken", "Chicken, broilers or fryers, breast, meat only, cooked, roasted"),
        ("beer", "Alcoholic beverage, beer, regular, all"), ("ban", "Bananas, raw"), ("eggplant", "Eggplant, raw"),
        ("whole wheat bread", "Bread, whole-wheat, commercially prepared"), ("kimchi", "Cabbage, kimchi"),
    ])
    func searchPutsTheFoodPeopleMeanFirst(query: String, expected: String) {
        #expect(reference.search(query).first?.name == expected)
    }

    @Test func searchNeedsEveryWordAndIgnoresFillers() {
        #expect(reference.search("a bowl of blueberries").first?.name == "Blueberries, raw")
        #expect(reference.search("zzzz banana").isEmpty)
        #expect(reference.search("  ").isEmpty)
    }

    @Test func gramsScaleThePer100gValues() throws {
        let typed = try #require(try FoodTextCapture.items("150 g chicken", source: .typed, at: referenceNow).first)
        let item = reference.resolved(typed, at: referenceNow)
        #expect(item.nutrients[.energy] == 165 * 1.5)
        #expect(item.name == "chicken")
        #expect(item.valueSource == .reference)
        let source = try #require(item.provenance.last?.reference)
        #expect(source.description == "Chicken, broilers or fryers, breast, meat only, cooked, roasted")
        #expect(source.portion == nil)
        #expect(item.provenance.first?.source == .typed)
        try item.validate()
    }

    @Test func aCountUsesTheHouseholdPortion() throws {
        let typed = try #require(try FoodTextCapture.items("2 bananas", source: .voice, at: referenceNow).first)
        let item = reference.resolved(typed, at: referenceNow)
        let source = try #require(item.provenance.last?.reference)
        #expect(source.portion?.hasPrefix("1 medium") == true)
        // 2 x 118 g at 89 kcal per 100 g.
        #expect(abs((item.nutrients[.energy] ?? 0) - 210.04) < 0.01)
    }

    @Test func anUnmatchedLineStaysUnknownNotZero() throws {
        let typed = try #require(try FoodTextCapture.items("grandma's stew", source: .typed, at: referenceNow).first)
        let item = reference.resolved(typed, at: referenceNow)
        #expect(item == typed)
        #expect(item.nutrients[.energy] == nil)
    }

    @Test func referenceProvenanceNeedsItsSource() {
        #expect(throws: FoodError.self) { try FoodProvenance(source: .reference, recordedAt: referenceNow).validate() }
        #expect(throws: FoodError.self) {
            try FoodProvenance(source: .typed, recordedAt: referenceNow, reference: .init(fdcID: 1, description: "x")).validate()
        }
    }

    @Test func mealsNameWhereTheirValuesCameFrom() throws {
        let banana = try reference.item(try #require(reference.everyday("banana")), amount: 1, unit: .serving, at: referenceNow)
        #expect([banana].sourceSummary == "USDA")
        var edited = banana
        try edited.changeAmount(to: 2, at: referenceNow)
        #expect([edited].sourceSummary == "USDA")
        let typed = FoodItem(name: "stew", amount: 1, unit: .serving, provenance: [.init(source: .typed, recordedAt: referenceNow)])
        #expect([banana, typed].sourceSummary == "Mixed sources")
    }
}

@Suite struct FoodReferencePortionTests {
    let reference: FoodReference
    init() throws { reference = try #require(FoodReference.shared) }

    /// R2-VET-01: "milk" was a quart and "coffee" one fluid ounce.
    @Test(arguments: [("milk", 244.0), ("coffee", 237.0), ("porridge", 234.0), ("egg", 50.0), ("oats", 40.0), ("protein shake", 28.7)])
    func everydayFoodsUseAnEverydayPortion(name: String, grams: Double) throws {
        let food = try #require(reference.everyday(name))
        let index = try #require(food.defaultPortion)
        #expect(food.portions[index].grams == grams)
    }

    @Test func noDefaultPortionIsAboveHalfAKilo() {
        let heavy = reference.foods.filter { food in food.defaultPortion.map { food.portions[$0].grams > 500 } ?? false }
        #expect(heavy.isEmpty, "\(heavy.prefix(5).map(\.name))")
    }

    @Test func aCupOfCoffeeCarriesItsCaffeine() throws {
        let item = try reference.item(try #require(reference.everyday("coffee")), amount: 1, unit: .serving, at: Date(timeIntervalSince1970: 0))
        #expect((item.nutrients[.caffeine] ?? 0) > 80)
    }

    @Test func matchesAreNamedSoAPersonKnowsThem() throws {
        #expect(reference.shortName(try #require(reference.everyday("chicken"))) == "Chicken, roasted")
        let sprouted = try #require(reference.search("sprouted lentils").first)
        #expect(reference.shortName(sprouted).count <= 40)
    }
}
