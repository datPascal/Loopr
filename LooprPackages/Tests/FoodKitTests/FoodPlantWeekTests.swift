import FoodKit
import Foundation
import Testing

struct FoodISOWeekTests {
    @Test func weeksStartOnMondayAndNumberLikeISO8601() throws {
        let cases: [(String, Int, Int)] = [
            ("2026-10-18", 2026, 42), ("2026-10-19", 2026, 43), ("2026-10-25", 2026, 43), ("2026-10-26", 2026, 44),
            ("2026-01-01", 2026, 1), ("2025-12-29", 2026, 1),
        ]
        for (day, year, week) in cases {
            let value = try FoodISOWeek(containing: day)
            #expect(value.year == year && value.week == week, "\(day)")
        }
        let week = try FoodISOWeek(containing: "2026-10-22")
        #expect(week.days == ["2026-10-19", "2026-10-20", "2026-10-21", "2026-10-22", "2026-10-23", "2026-10-24", "2026-10-25"])
        #expect(week.firstDay == "2026-10-19" && week.lastDay == "2026-10-25" && week.id == "2026-W43")
        #expect(week.previous.id == "2026-W42" && week.next.id == "2026-W44" && week.previous < week)
    }

    @Test func week53BelongsToTheOldYearAndWeek1CanStartInDecember() throws {
        // 2026 starts on a Thursday, so it has 53 weeks and 2027-01-03 is still in 2026-W53.
        for day in ["2026-12-28", "2026-12-31", "2027-01-01", "2027-01-03"] {
            let value = try FoodISOWeek(containing: day)
            #expect(value.id == "2026-W53", "\(day)")
        }
        #expect(try FoodISOWeek(containing: "2027-01-04").id == "2027-W01")
        #expect(try FoodISOWeek(containing: "2026-12-27").id == "2026-W52")
        #expect(try FoodISOWeek(containing: "2024-12-30").id == "2025-W01")
        #expect(try FoodISOWeek(containing: "2020-12-28").id == "2020-W53")
        #expect(try FoodISOWeek(containing: "2021-01-03").id == "2020-W53")
        #expect(try FoodISOWeek(containing: "2021-01-04").id == "2021-W01")
        let last = try FoodISOWeek(containing: "2026-12-30")
        #expect(last.days.last == "2027-01-03" && last.next.id == "2027-W01" && last.contains(localDay: "2027-01-03"))
        #expect(!last.contains(localDay: "2027-01-04") && !last.contains(localDay: "2026-12-27"))
    }

    @Test func sundayNightAndMondayMorningAreDifferentWeeksAndCalendarFirstWeekdayDoesNotMatter() throws {
        for firstWeekday in [1, 2, 7] {
            let calendar = Longevity.calendar(Longevity.berlin, firstWeekday: firstWeekday)
            let sunday = try FoodISOWeek(containing: Longevity.instant(2026, 10, 25, 23, 59), calendar: calendar)
            let monday = try FoodISOWeek(containing: Longevity.instant(2026, 10, 26, 0, 1), calendar: calendar)
            #expect(sunday.id == "2026-W43" && monday.id == "2026-W44", "first weekday \(firstWeekday)")
        }
    }

    @Test func theCallingCalendarsTimeZoneDecidesTheLocalDayOfAnInstant() throws {
        // Sunday 22:00 in New York is Monday 03:00 or 04:00 in Berlin.
        let instant = Longevity.instant(2026, 10, 25, 22, zone: Longevity.newYork)
        #expect(try FoodISOWeek(containing: instant, calendar: Longevity.calendar(Longevity.newYork)).id == "2026-W43")
        #expect(try FoodISOWeek(containing: instant, calendar: Longevity.calendar(Longevity.berlin)).id == "2026-W44")
    }

    @Test func invalidDaysAreRejected() {
        for day in ["", "2026-13-01", "2026-02-29", "2026-1-1", "26-01-01", "2026/01/01", "0000-01-01"] {
            #expect(throws: FoodError.invalidRecord, "\(day)") { try FoodISOWeek(containing: day) }
        }
        #expect((try? FoodISOWeek(containing: "2028-02-29")) != nil)
    }
}

struct FoodItemPlantTests {
    private let when = Date(timeIntervalSince1970: 1_700_000_100)

    @Test func plantsComeFromThePhotoEstimateAndFromOpenFoodFactsWithTheirSource() throws {
        let list = try Longevity.list()
        let photo = Longevity.photoItem(plants: ["Spinat", "chickpeas", "Dragonberry", "sugar"])
        let found = photo.plants(in: list)
        #expect(found.map(\.key) == ["chickpea", "custom:dragonberry", "spinach"])
        #expect(found.allSatisfy { $0.source == .photoEstimate })
        #expect(found.first { $0.key == "spinach" }?.name == "Spinach" && found.first { $0.key == "spinach" }?.category == .vegetable)
        #expect(found.first { $0.key == "custom:dragonberry" }?.category == nil)

        let scanned = Longevity.scannedItem(tags: ["en:oat", "en:sugar", "en:wheat-flour", "en:wheat", "en:almond"])
        #expect(scanned.plants(in: list).map(\.key) == ["almond", "oats"])
        #expect(scanned.plants(in: list).allSatisfy { $0.source == .openFoodFacts })
        #expect(Longevity.typedItem().plants(in: list).isEmpty)
        #expect(Longevity.scannedItem(tags: nil).plants(in: list).isEmpty)
    }

    @Test func aPersonsEditWinsOverBothAutomaticSources() throws {
        let list = try Longevity.list()
        var photo = Longevity.photoItem(plants: ["spinach", "fennel"])
        try photo.removePlant(key: "spinach", at: when)
        #expect(photo.plants(in: list).map(\.key) == ["fennel"])
        try photo.addPlant(named: "Shiitake", in: list, at: when)
        #expect(photo.plants(in: list).map(\.key) == ["fennel", "shiitake"])
        #expect(photo.plants(in: list).first { $0.key == "shiitake" }?.source == .edit)
        // Adding back what a photo found makes it the person's own.
        try photo.addPlant(named: "spinach", in: list, at: when)
        #expect(photo.plants(in: list).first { $0.key == "spinach" }?.source == .edit)
        #expect(photo.plantEdits?.removed.isEmpty == true)

        var scanned = Longevity.scannedItem(tags: ["en:chickpea", "en:spinach"])
        try scanned.removePlant(key: "chickpea", at: when)
        #expect(scanned.plants(in: list).map(\.key) == ["spinach"])
        try scanned.addPlant(named: "Chickpeas", in: list, at: when)
        #expect(scanned.plants(in: list).first { $0.key == "chickpea" }?.source == .edit)
        try scanned.removePlant(key: "chickpea", at: when)
        #expect(scanned.plantEdits?.added.isEmpty == true && scanned.plants(in: list).map(\.key) == ["spinach"])

        // A plant nothing found counts when the person adds it, also a custom one.
        var typed = Longevity.typedItem()
        try typed.addPlant(named: "Dragonberry", in: list, at: when)
        try typed.addPlant(named: "dragonberry", in: list, at: when)
        #expect(typed.plants(in: list).map(\.key) == ["custom:dragonberry"] && typed.plantEdits?.added.count == 1)
        // The edit is in the item's history and the item stays valid.
        #expect(typed.provenance.last?.source == .manualEdit)
        try typed.validate(); try photo.validate(); try scanned.validate()
    }

    @Test func refinedProductsCannotBeAddedAsPlants() throws {
        let list = try Longevity.list()
        var item = Longevity.typedItem()
        #expect(throws: FoodError.invalidRecord) { try item.addPlant(named: "white flour", in: list, at: when) }
        #expect(throws: FoodError.invalidRecord) { try item.addPlant(named: "   ", in: list, at: when) }
        #expect(item.plantEdits == nil && item.provenance.count == 1)
    }

    @Test func plantFieldsValidateAndSurviveEncodingWhileOlderRecordsStillDecode() throws {
        let list = try Longevity.list()
        var item = Longevity.photoItem(plants: ["spinach"])
        try item.addPlant(named: "fennel", in: list, at: when)
        let decoded = try JSONDecoder().decode(FoodItem.self, from: JSONEncoder().encode(item))
        #expect(decoded == item && decoded.estimatedPlants == ["spinach"] && decoded.plantEdits?.added.map(\.key) == ["fennel"])

        // A record saved before these fields existed has none of their keys.
        let plain = Longevity.typedItem("Rice", nutrients: [.energy: 200])
        let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(plain)) as? [String: Any])
        for key in ["novaGroup", "ingredientTags", "estimatedPlants", "plantEdits"] { #expect(encoded[key] == nil, "\(key)") }
        let old = try JSONDecoder().decode(FoodItem.self, from: JSONSerialization.data(withJSONObject: encoded))
        #expect(old == plain && old.novaGroup == nil && old.ingredientTags == nil && old.estimatedPlants == nil && old.plantEdits == nil)

        // Fields that do not belong to the item's sources are refused.
        var typed = Longevity.typedItem()
        typed.novaGroup = 4
        #expect(throws: FoodError.invalidRecord) { try typed.validate() }
        typed.novaGroup = nil; typed.estimatedPlants = ["spinach"]
        #expect(throws: FoodError.invalidRecord) { try typed.validate() }
        typed.estimatedPlants = nil; typed.ingredientTags = ["en:spinach"]
        #expect(throws: FoodError.invalidRecord) { try typed.validate() }
        var scanned = Longevity.scannedItem(nova: 4, tags: ["en:spinach"])
        try scanned.validate()
        scanned.novaGroup = 5
        #expect(throws: FoodError.invalidRecord) { try scanned.validate() }
        scanned.novaGroup = 0
        #expect(throws: FoodError.invalidRecord) { try scanned.validate() }
        scanned.novaGroup = nil; scanned.ingredientTags = [""]
        #expect(throws: FoodError.invalidRecord) { try scanned.validate() }
        var photo = Longevity.photoItem(plants: ["  "])
        #expect(throws: FoodError.invalidRecord) { try photo.validate() }
        photo.estimatedPlants = [String(repeating: "x", count: 101)]
        #expect(throws: FoodError.invalidRecord) { try photo.validate() }
        photo.plantEdits = .init(added: [FoodPlantRef(key: "fennel", name: "Fennel")], removed: ["fennel"])
        photo.estimatedPlants = ["spinach"]
        #expect(throws: FoodError.invalidRecord) { try photo.validate() }
    }

    @Test func duplicatingAnItemKeepsItsClassificationAndPlantsWithAFreshId() throws {
        let list = try Longevity.list()
        var scanned = Longevity.scannedItem(nova: 4, tags: ["en:almond"], energy: 300)
        try scanned.addPlant(named: "fennel", in: list, at: when)
        let copy = scanned.duplicated(addingEditAt: when)
        #expect(copy.id != scanned.id && copy.novaGroup == 4 && copy.ingredientTags == ["en:almond"] && copy.plantEdits == scanned.plantEdits)
        #expect(copy.plants(in: list).map(\.key) == scanned.plants(in: list).map(\.key))
        #expect(copy.provenance.count == scanned.provenance.count + 1)
        #expect(scanned.duplicated().provenance == scanned.provenance)
        try copy.validate()
        let favourite = FoodFavorite(name: "Snack", items: [scanned], note: "", confirmedAt: when)
        let draft = try favourite.draft(slot: .snack, at: when, timeZoneIdentifier: Longevity.berlin)
        #expect(draft.items[0].novaGroup == 4 && draft.items[0].plantEdits == scanned.plantEdits && draft.items[0].id != scanned.id)
    }
}

struct FoodPlantWeekTests {
    @Test func plantsCountOncePerWeekFromAllThreeSourcesWithTheirSources() throws {
        let list = try Longevity.list()
        let context = try LongevityStore()
        var typed = Longevity.typedItem()
        try typed.addPlant(named: "shiitake", in: list, at: Longevity.stamp)
        let meals = [
            try context.meal(at: Longevity.instant(2026, 10, 19, 8), zone: Longevity.berlin,
                items: [Longevity.photoItem(plants: ["spinach", "Tomaten"])]),
            try context.meal(at: Longevity.instant(2026, 10, 21, 13), zone: Longevity.berlin,
                items: [Longevity.scannedItem(tags: ["en:chickpea", "en:spinach", "en:sugar", "en:vegetable"]), typed]),
            try context.meal(at: Longevity.instant(2026, 10, 25, 19), zone: Longevity.berlin,
                items: [Longevity.photoItem(plants: ["spinach"])]),
        ]
        let week = FoodPlantWeek(week: try FoodISOWeek(containing: "2026-10-22"), meals: meals, list: list)
        #expect(week.plants.map(\.key) == ["chickpea", "shiitake", "spinach", "tomato"])
        #expect(week.count == 4 && week.remainingToGoal == 26)
        let spinach = try #require(week.plants.first { $0.key == "spinach" })
        #expect(spinach.sources == [.openFoodFacts, .photoEstimate] && spinach.itemCount == 3 && spinach.firstLocalDay == "2026-10-19")
        #expect(week.plants.first { $0.key == "shiitake" }?.sources == [.edit])
        #expect(week.plants.first { $0.key == "chickpea" }?.sources == [.openFoodFacts])
        #expect(week.plants.first { $0.key == "tomato" }?.name == "Tomato")
    }

    @Test func removingAPlantOnAnItemTakesItOutOfTheWeekUnlessAnotherItemHasIt() throws {
        let list = try Longevity.list()
        let context = try LongevityStore()
        var first = Longevity.photoItem(plants: ["spinach", "fennel"])
        try first.removePlant(key: "spinach", at: Longevity.stamp)
        let second = Longevity.scannedItem(tags: ["en:spinach"])
        let monday = try context.meal(at: Longevity.instant(2026, 10, 19, 8), zone: Longevity.berlin, items: [first])
        let week = try FoodISOWeek(containing: "2026-10-19")
        #expect(FoodPlantWeek(week: week, meals: [monday], list: list).plants.map(\.key) == ["fennel"])
        let tuesday = try context.meal(at: Longevity.instant(2026, 10, 20, 8), zone: Longevity.berlin, items: [second])
        #expect(FoodPlantWeek(week: week, meals: [monday, tuesday], list: list).plants.map(\.key) == ["fennel", "spinach"])
    }

    @Test func sundayNightStaysInItsWeekAndMondayStartsTheNext() throws {
        let list = try Longevity.list()
        let context = try LongevityStore()
        let sunday = try context.meal(at: Longevity.instant(2026, 10, 25, 23, 30), zone: Longevity.berlin, items: [Longevity.photoItem(plants: ["kale"])])
        let monday = try context.meal(at: Longevity.instant(2026, 10, 26, 0, 10), zone: Longevity.berlin, items: [Longevity.photoItem(plants: ["leek"])])
        #expect(sunday.localDay == "2026-10-25" && monday.localDay == "2026-10-26")
        let weeks = FoodPlantWeek.weeks(meals: [sunday, monday], list: list)
        #expect(weeks.count == 2)
        let sundayWeek = try FoodISOWeek(containing: "2026-10-25"), mondayWeek = try FoodISOWeek(containing: "2026-10-26")
        #expect(weeks[sundayWeek]?.plants.map(\.key) == ["kale"])
        #expect(weeks[mondayWeek]?.plants.map(\.key) == ["leek"])
    }

    @Test func week53HoldsDaysFromBothCalendarYears() throws {
        let list = try Longevity.list()
        let context = try LongevityStore()
        let december = try context.meal(at: Longevity.instant(2026, 12, 31, 12), zone: Longevity.berlin, items: [Longevity.photoItem(plants: ["kale"])])
        let january = try context.meal(at: Longevity.instant(2027, 1, 2, 12), zone: Longevity.berlin, items: [Longevity.photoItem(plants: ["leek"])])
        let next = try context.meal(at: Longevity.instant(2027, 1, 4, 12), zone: Longevity.berlin, items: [Longevity.photoItem(plants: ["fennel"])])
        let week53 = try FoodISOWeek(containing: "2026-12-30")
        let counted = FoodPlantWeek(week: week53, meals: [december, january, next], list: list)
        #expect(counted.week.id == "2026-W53" && counted.plants.map(\.key) == ["kale", "leek"])
        #expect(FoodPlantWeek(week: week53.next, meals: [december, january, next], list: list).plants.map(\.key) == ["fennel"])
    }

    @Test func aMealStaysInTheWeekOfItsOwnLocalDayAfterATimeZoneChange() throws {
        let list = try Longevity.list()
        let context = try LongevityStore()
        // Eaten Sunday 22:00 in New York, which is already Monday in Berlin.
        let instant = Longevity.instant(2026, 10, 25, 22, zone: Longevity.newYork)
        let meal = try context.meal(at: instant, zone: Longevity.newYork, items: [Longevity.photoItem(plants: ["kale"])])
        #expect(meal.localDay == "2026-10-25")
        let berlin = Longevity.calendar(Longevity.berlin)
        // The phone is in Berlin now and asks for the week of this instant. That is Monday's week, which holds no meal...
        let thisWeek = try FoodPlantWeek(containing: instant, calendar: berlin, meals: [meal], list: list)
        #expect(thisWeek.week.id == "2026-W44" && thisWeek.count == 0)
        // ...because the meal belongs to the week of the day it was eaten.
        let eaten = try FoodPlantWeek(containing: instant, calendar: Longevity.calendar(Longevity.newYork), meals: [meal], list: list)
        #expect(eaten.week.id == "2026-W43" && eaten.plants.map(\.key) == ["kale"])
        #expect(FoodPlantWeek(week: thisWeek.week.previous, meals: [meal], list: list).plants.map(\.key) == ["kale"])
    }

    @Test func newPlantsAreThoseNoEarlierWeekHeldAndTheGoalCountsDown() throws {
        let list = try Longevity.list()
        let context = try LongevityStore()
        let earlier = try context.meal(at: Longevity.instant(2026, 10, 14, 12), zone: Longevity.berlin,
            items: [Longevity.photoItem(plants: ["spinach", "fennel"])])
        let current = try context.meal(at: Longevity.instant(2026, 10, 21, 12), zone: Longevity.berlin,
            items: [Longevity.photoItem(plants: ["spinach", "shiitake", "hemp seeds", "fennel"])])
        let later = try context.meal(at: Longevity.instant(2026, 10, 28, 12), zone: Longevity.berlin,
            items: [Longevity.photoItem(plants: ["shiitake", "hemp seeds"])])
        let all = [earlier, current, later]
        let weeks = FoodPlantWeek.weeks(meals: all, list: list)
        let currentKey = try FoodISOWeek(containing: "2026-10-21"), previousKey = try FoodISOWeek(containing: "2026-10-14")
        let followingKey = try FoodISOWeek(containing: "2026-10-28")
        let week = try #require(weeks[currentKey])
        let previous = try #require(weeks[previousKey])
        let following = try #require(weeks[followingKey])
        // Spinach and fennel were eaten the week before. A later week never makes a plant "not new".
        #expect(week.newPlants(comparedWith: [previous, following]).map(\.key) == ["hemp-seed", "shiitake"])
        #expect(week.newPlants(comparedWith: []).count == 4)
        #expect(following.newPlants(comparedWith: [previous, week]).isEmpty)
        #expect(week.count == 4 && week.remainingToGoal == FoodPlantWeek.weeklyGoal - 4 && FoodPlantWeek.weeklyGoal == 30)
        let empty = FoodPlantWeek(week: week.week.next.next.next, meals: all, list: list)
        #expect(empty.count == 0 && empty.remainingToGoal == 30 && empty.plants.isEmpty)
    }
}
