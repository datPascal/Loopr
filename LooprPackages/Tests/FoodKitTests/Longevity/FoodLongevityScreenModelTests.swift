import DomainKit
import FoodKit
import Foundation
import RoutineKit
import Testing

struct FoodMealRepeatTests {
    @Test func aRepeatedMealKeepsItsNovaGroupIngredientsAndPlants() throws {
        let context = try LongevityStore()
        let list = try Longevity.list()
        var scanned = Longevity.scannedItem("Oat bar", nova: 4, tags: ["en:oat-flakes", "en:hazelnut"], energy: 210)
        try scanned.addPlant(named: "fennel", in: list, at: Longevity.stamp)
        let photo = Longevity.photoItem("Salad", plants: ["spinach", "tomato"], nutrients: [.energy: 300])
        let meal = try context.meal(at: Longevity.instant(2026, 10, 20, 12), zone: Longevity.berlin, items: [scanned, photo])
        let later = Longevity.instant(2026, 10, 22, 13)
        let draft = FoodMealDraft.repeating(meal, at: later, timeZoneIdentifier: Longevity.berlin)

        #expect(draft.id != meal.id && draft.occurredAt == later && draft.slot == meal.slot && draft.expectedRevision == nil)
        #expect(draft.items.count == 2)
        #expect(Set(draft.items.map(\.id)).isDisjoint(with: meal.items.map(\.id)))
        #expect(draft.items[0].novaGroup == 4)
        #expect(draft.items[0].ingredientTags == ["en:oat-flakes", "en:hazelnut"])
        #expect(draft.items[0].plantEdits == scanned.plantEdits)
        #expect(draft.items[1].estimatedPlants == ["spinach", "tomato"])
        #expect(draft.items.map { $0.plants(in: list).map(\.key) } == meal.items.map { $0.plants(in: list).map(\.key) })
        // The repeat is recorded as an edit; the original sources stay.
        #expect(draft.items[0].provenance.first?.source == .barcode && draft.items[0].provenance.last?.source == .manualEdit)
        #expect(draft.items[0].provenance.last?.recordedAt == later)

        // Saved, it still counts for the week's plants and the ultra-processed share.
        let repeated = try context.store.confirm(draft, at: later)
        let week = FoodPlantWeek(week: try FoodISOWeek(containing: "2026-10-22"), meals: [meal, repeated], list: list)
        #expect(week.plants.first { $0.key == "fennel" }?.itemCount == 2)
        let lens = FoodLongevityLens(week: try FoodISOWeek(containing: "2026-10-22"), data: .init(meals: [repeated], drinks: [],
            days: [try Longevity.completeDay("2026-10-22")], targets: []))
        #expect(lens.ultraProcessed?.classifiedItems == 1)
    }
}

struct FoodProtocolTargetsTests {
    private func rule(_ key: RuleKey, _ metric: RoutineMetric, _ kind: RuleTargetKind, _ value: Double, source: CheckSource = .food) -> ProtocolRule {
        ProtocolRule(key: key, title: key.rawValue, group: .food, target: RuleTarget(kind: kind, metric: metric.rawValue, value: value), source: source)
    }

    @Test func foodRulesGiveTheKitchenTimeAndTheTargets() {
        let targets = FoodProtocolTargets(rules: [
            rule("kitchen", .lastMealTime, .atMost, 1_110), rule("kitchen-late", .lastMealTime, .atMost, 1_200),
            rule("fibre", .fibreG, .atLeast, 30), rule("fibre-more", .fibreG, .atLeast, 35), rule("protein", .proteinG, .atLeast, 130),
            // A manual rule never moves Food.
            rule("manual-kitchen", .lastMealTime, .atMost, 900, source: .manual),
        ])
        #expect(targets.kitchenClosesMinute == 1_110 && targets.fibreGrams == 35 && targets.proteinGrams == 130)
        #expect(FoodProtocolTargets(rules: []) == .none)
        #expect(FoodProtocolTargets(rules: [rule("odd", .lastMealTime, .atLeast, 1_110)]).kitchenClosesMinute == nil)
        #expect(FoodProtocolTargets(kitchenClosesMinute: 1_500, fibreGrams: -1, proteinGrams: .nan) == .none)
    }

    @Test func theKitchenPhraseCountsDownOnTodayOnly() {
        let calendar = Longevity.calendar(Longevity.berlin)
        let gb = Locale(identifier: "en_GB")
        func phrase(_ hour: Int, _ minute: Int, today: Bool = true, closes: Int? = 1_110) -> String? {
            FoodKitchenClock.phrase(closesAtMinute: closes, now: Longevity.instant(2026, 10, 23, hour, minute), isToday: today, calendar: calendar, locale: gb)
        }
        #expect(phrase(13, 4) == "Kitchen closes in 5 h 26 m")
        #expect(phrase(13, 30) == "Kitchen closes in 5 h")
        #expect(phrase(17, 50) == "Kitchen closes in 40 m")
        #expect(phrase(18, 30) == "Kitchen closed at 18:30")
        #expect(phrase(13, 4, today: false) == nil)
        #expect(phrase(13, 4, closes: nil) == nil)
    }

    @Test func theStoreReadsTheVersionInForce() throws {
        let context = try LongevityStore()
        #expect(try context.store.protocolTargets(at: Longevity.stamp) == .none)
        let routine = RoutineStore(database: context.database)
        let created = Longevity.instant(2026, 10, 1)
        let made = RoutineProtocol(name: "Mine", createdAt: created)
        try routine.createProtocol(made, rules: [rule("kitchen", .lastMealTime, .atMost, 1_110)])
        #expect(try context.store.protocolTargets(at: Longevity.instant(2026, 9, 30)) == .none)
        #expect(try context.store.protocolTargets(at: Longevity.instant(2026, 10, 2)).kitchenClosesMinute == 1_110)
    }
}

struct FoodRingDotsTests {
    @Test func anEmptyRingHasNoDots() {
        #expect(FoodRingDots.dots(fraction: 0, lineWidth: 18, weights: [1], seed: 1).isEmpty)
        #expect(FoodRingDots.dots(fraction: -1, lineWidth: 18, weights: [1], seed: 1).isEmpty)
        #expect(FoodRingDots.dots(fraction: .nan, lineWidth: 18, weights: [1], seed: 1).isEmpty)
    }

    @Test func dotsRestByTheRingsEndAndStayPut() {
        let seed = FoodRingDots.seed(localDay: "2026-10-23", ring: 0)
        let dots = FoodRingDots.dots(fraction: 0.48, lineWidth: 18, weights: [1], seed: seed)
        #expect(dots.count == 12)
        #expect(dots == FoodRingDots.dots(fraction: 0.48, lineWidth: 18, weights: [1], seed: seed))
        let end = 0.48 * 360
        #expect(dots.allSatisfy { $0.angle >= end - 30 && $0.angle <= end + 4 })
        #expect(dots.allSatisfy { abs($0.radialOffset) <= 16 && $0.diameter >= 2.4 && $0.diameter <= 6 })
        #expect(seed != FoodRingDots.seed(localDay: "2026-10-23", ring: 1))
        // A short arc keeps its dots on the arc's own stretch, and a full ring caps at the contract's sixteen.
        #expect(FoodRingDots.dots(fraction: 0.02, lineWidth: 13, weights: [1], seed: seed).allSatisfy { $0.angle >= 0 && $0.angle <= 0.02 * 360 + 4 })
        #expect(FoodRingDots.dots(fraction: 0.02, lineWidth: 13, weights: [1], seed: seed).count == 6)
        #expect(FoodRingDots.dots(fraction: 1.4, lineWidth: 13, weights: [1], seed: seed).count == FoodRingDots.maximum)
    }

    @Test func theCalorieRingDotsSplitByMacroEnergy() {
        // 60 g protein, 120 g carbs and 40 g fat: 240, 480 and 360 kcal.
        let dots = FoodRingDots.dots(fraction: 2.0 / 3, lineWidth: 18, weights: [240, 480, 360], seed: 9)
        #expect(dots.count == 16)
        let counts = Dictionary(grouping: dots, by: \.colorIndex).mapValues(\.count)
        #expect(counts[0] == 4 && counts[1] == 7 && counts[2] == 5)
        #expect(FoodRingDots.dots(fraction: 0.5, lineWidth: 18, weights: [0, 0, 0], seed: 9).allSatisfy { $0.colorIndex == 0 })
    }
}
