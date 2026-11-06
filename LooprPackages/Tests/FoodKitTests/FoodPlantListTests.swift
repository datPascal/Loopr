import FoodKit
import Foundation
import Testing

struct FoodPlantListTests {
    @Test func bundledListLoadsFromTheBundleWithBreadthAndStableKeys() throws {
        let list = try Longevity.list()
        #expect(list.plants.count >= 250)
        #expect(Set(list.plants.map(\.key)).count == list.plants.count)
        for category in FoodPlantCategory.allCases { #expect(list.plants.contains { $0.category == category }, "\(category)") }
        for key in ["spinach", "chickpea", "oats", "shiitake", "hemp-seed", "fennel", "basil", "cinnamon", "almond", "quinoa"] {
            #expect(list.plant(key: key) != nil, "\(key)")
        }
        // Herbs and spices count as plants (the "30 plants a week" counting).
        #expect(list.plant(key: "basil")?.category == .herb && list.plant(key: "cinnamon")?.category == .spice)
        #expect(list.plants.allSatisfy { !$0.name.isEmpty && $0.name.first?.isUppercase == true && !$0.name.contains("!") && !$0.name.contains("\u{2014}") })
        #expect(list.plants.allSatisfy { $0.offIds.allSatisfy { $0.contains(":") && $0 == $0.lowercased() } })
        let german = list.plants.filter { plant in plant.synonyms.contains { $0.contains("ü") || $0.contains("ö") || $0.contains("ä") || $0.contains("ß") } }
        #expect(german.count >= 20)
    }

    @Test func everyNameAndSynonymFindsItsOwnPlant() throws {
        let list = try Longevity.list()
        for plant in list.plants {
            for name in [plant.name] + plant.synonyms {
                guard case .listed(let found)? = list.match(name: name) else {
                    Issue.record("\(name) did not match"); continue
                }
                #expect(found.key == plant.key, "\(name) matched \(found.key) instead of \(plant.key)")
            }
        }
    }

    @Test func synonymsCoverGermanNamesPluralsCaseAndDiacritics() throws {
        let list = try Longevity.list()
        func key(_ name: String) -> String? {
            if case .listed(let plant)? = list.match(name: name) { return plant.key }
            return nil
        }
        #expect(key("Möhren") == "carrot" && key("mohren") == "carrot" && key("Karotte") == "carrot")
        #expect(key("Rote Bete") == "beetroot" && key("Spinat") == "spinach" && key("Haferflocken") == "oats")
        #expect(key("Weißkohl") == "cabbage" && key("weisskohl") == "cabbage")
        #expect(key("  CHICKPEAS ") == "chickpea" && key("chickpea") == "chickpea")
        #expect(key("blueberries") == "blueberry" && key("tomatoes") == "tomato" && key("Tomaten") == "tomato")
        #expect(key("zucchini") == "courgette" && key("Zucchini") == "courgette")
        #expect(key("Hanfsamen") == "hemp-seed" && key("hemp seeds") == "hemp-seed")
        #expect(key("Shiitake") == "shiitake" && key("Fenchel") == "fennel" && key("Pfifferlinge") == "chanterelle")
        #expect(key("Kreuzkümmel") == "cumin" && key("Kümmel") == "caraway")
    }

    @Test func refinedProductsNeverCountAndUnknownNamesBecomeTheirOwnPlant() throws {
        let list = try Longevity.list()
        for name in ["sugar", "Zucker", "olive oil", "Olivenöl", "white flour", "Weissmehl", "white rice", "coffee", "tea", "chocolate"] {
            #expect(list.match(name: name) == .excluded, "\(name)")
            #expect(list.reference(forName: name) == nil, "\(name)")
        }
        // The plant itself still counts: olives are a plant, olive oil is not.
        if case .listed(let olive)? = list.match(name: "olive") { #expect(olive.key == "olive") } else { Issue.record("olive") }
        #expect(list.match(name: "Dragonberry") == .custom(FoodPlantRef(key: "custom:dragonberry", name: "Dragonberry")))
        #expect(list.match(name: "   ") == nil && list.match(name: String(repeating: "a", count: 101)) == nil)
        #expect(list.reference(forName: "Kohlrabi")?.key == "kohlrabi")
        #expect(list.reference(forName: "Dragonberry")?.isCustom == true)
    }

    @Test func taxonomyIdsMatchAndGenericParentsAddNothing() throws {
        let list = try Longevity.list()
        func keys(_ tags: [String]) -> [String] { list.plants(fromOFFTags: tags).map(\.key) }
        #expect(keys(["en:spinach", "en:leaf-vegetable", "en:vegetable"]) == ["spinach"])
        #expect(keys(["en:chickpea", "en:legume"]) == ["chickpea"])
        #expect(keys(["en:rolled-oats"]) == ["oats"])
        #expect(keys([" EN:Spinach "]) == ["spinach"])
        // Refined products and generic parents. Open Food Facts lists en:wheat with en:wheat-flour.
        #expect(keys(["en:wheat-flour", "en:cereal-flour", "en:wheat", "en:cereal", "en:flour"]).isEmpty)
        #expect(keys(["en:sugar", "en:sunflower-oil", "en:vegetable-oil", "en:salt", "en:rice", "en:palm-oil", "en:water"]).isEmpty)
        #expect(keys(["en:whole-wheat-flour", "en:wheat-flour", "en:wheat"]) == ["whole-wheat"])
        // A parent is not counted on top of the specific plant: kale lists cabbage too.
        #expect(keys(["en:kale", "en:cabbage", "en:vegetable"]) == ["kale"])
        #expect(keys(["en:cabbage"]) == ["cabbage"])
        // A tag the taxonomy did not recognise, in another language, matches by name. English unknowns do not.
        #expect(keys(["de:dinkelvollkornmehl"]) == ["spelt"])
        #expect(keys(["de:rote-bete", "fr:xyz-unknown"]) == ["beetroot"])
        #expect(keys(["en:corn-starch", "en:corn"]).isEmpty)
        // Each plant once however many ids name it.
        #expect(keys(["en:oat", "en:oat-flakes", "en:rolled-oats"]) == ["oats"])
    }

    @Test func malformedListsAreRejected() throws {
        func data(_ json: String) -> Data { Data(json.utf8) }
        #expect(throws: FoodPlantListError.unsupportedVersion(2)) { try FoodPlantList(data: data(#"{"version":2,"plants":[]}"#)) }
        #expect(throws: FoodPlantListError.invalidEntry("a")) {
            try FoodPlantList(data: data(#"{"version":1,"plants":[{"key":"a","name":"A","category":"herb"},{"key":"a","name":"B","category":"herb"}]}"#))
        }
        #expect(throws: FoodPlantListError.invalidEntry("Bad Key")) {
            try FoodPlantList(data: data(#"{"version":1,"plants":[{"key":"Bad Key","name":"A","category":"herb"}]}"#))
        }
        #expect(throws: FoodPlantListError.duplicateName("Moehre")) {
            try FoodPlantList(data: data(#"{"version":1,"plants":[{"key":"a","name":"Moehre","category":"vegetable"},{"key":"b","name":"B","category":"vegetable","synonyms":["Moehre"]}]}"#))
        }
        let small = try FoodPlantList(data: data(#"{"version":1,"notPlants":["Sugar"],"plants":[{"key":"a","name":"Alpha","category":"fruit","synonyms":["Älpha"],"offIds":["en:alpha"]}]}"#))
        #expect(small.match(name: "alpha")?.isListed == true && small.match(name: "sugar") == .excluded)
        #expect(small.plants(fromOFFTags: ["en:alpha"]).map(\.key) == ["a"])
    }
}

private extension FoodPlantMatch {
    var isListed: Bool { if case .listed = self { true } else { false } }
}
