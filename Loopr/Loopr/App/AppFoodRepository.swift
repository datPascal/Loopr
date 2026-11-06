import DomainKit
import FoodKit
import JournalKit
import Foundation
import RoutineKit
import StorageKit

/// The actor keeps SQLite reads, image validation and fixture setup off the UI.
actor AppFoodRepository {
    private var food: FoodStore?
    private var productClient: FoodProductClient?
    private var fixtureDatabase: StorageDatabase?
    private var fixtureRoot: URL?
    private let environment: AppEnvironment
    init(store: FoodStore? = nil, environment: AppEnvironment, productClient: FoodProductClient? = nil) {
        food = store; self.environment = environment; self.productClient = productClient
    }
    deinit {
        try? fixtureDatabase?.databasePool.close()
        if let fixtureRoot { try? FileManager.default.removeItem(at: fixtureRoot) }
    }
    private func ready() throws -> FoodStore {
        if let food { return food }
        #if DEBUG
        guard environment.composition != .production else { throw FoodError.invalidRecord }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LooprFoodFixture-\(UUID().uuidString)")
        fixtureRoot = root
        let database = try StorageDatabase(url: root.appendingPathComponent("food.sqlite"), applicationVersion: "food-fixture")
        fixtureDatabase = database
        let store = FoodStore(database: database)
        if environment.composition != .empty && environment.composition != .onboarding {
            try AppFoodFixtures.seed(store, endingOn: environment.dateProvider.now())
            try AppFoodFixtures.seedLongevity(store, routine: RoutineStore(database: database), endingOn: environment.dateProvider.now())
        }
        food = store
        return store
        #else
        throw FoodError.invalidRecord
        #endif
    }
    func lookupBarcode(_ code: String, refresh: Bool = false) async throws -> FoodProductLookup {
        if productClient == nil {
            let store = try ready()
            let transport: any FoodProductTransport
            #if DEBUG
            transport = environment.composition == .production ? FoodProductURLSessionTransport() : AppFoodProductFixtureTransport()
            #else
            transport = FoodProductURLSessionTransport()
            #endif
            productClient = FoodProductClient(transport: transport, cache: store)
        }
        guard let productClient else { throw FoodBarcodeError.storage }
        return try await productClient.lookup(code, refresh: refresh)
    }
    func overview(from firstDay: String, through lastDay: String) throws -> FoodOverviewData { try ready().overview(from: firstDay, through: lastDay) }
    /// The store this repository reads, seeded first in a fixture launch, so a report file reads the same meals as the
    /// Food tab (ICP R3-UPG-7).
    func readingStore() throws -> FoodStore { try ready() }
    func photoBytes(ids: [UUID]) throws -> [UUID: Data] {
        let store = try ready()
        var values: [UUID: Data] = [:]
        for id in Set(ids) { values[id] = try store.photo(id: id)?.bytes }
        return values
    }
    func favorites() throws -> [FoodFavorite] { try ready().favorites() }
    func confirmFavorite(_ favorite: FoodFavorite) throws { try ready().confirmFavorite(favorite) }
    func deleteFavorite(id: UUID) throws { try ready().deleteFavorite(id: id) }
    func confirm(_ draft: FoodMealDraft, at date: Date) throws { try ready().confirm(draft, at: date) }
    func editDraft(id: UUID) throws -> FoodMealDraft { try ready().editDraft(id: id) }
    func confirmDrink(_ drink: FoodDrink) throws { try ready().confirmDrink(drink) }
    /// Deleting a meal or a drink hides the found patterns that counted its day, in the same save, as deleting a day does.
    func deleteMeal(id: UUID, expectedRevision: Int) throws {
        let day = try ready().deleteMeal(id: id, expectedRevision: expectedRevision) { db, day in
            try SQLitePatternStore.hideFoundPatterns(affectedBy: .day(day), in: db)
        }
        PatternSourceDeletions.committed(.day(day))
    }
    func deleteDrink(id: UUID) throws {
        let day = try ready().deleteDrink(id: id) { db, day in
            try SQLitePatternStore.hideFoundPatterns(affectedBy: .day(day), in: db)
        }
        if let day { PatternSourceDeletions.committed(.day(day)) }
    }
    func confirmTarget(_ target: FoodTargetSettings) throws { try ready().confirmTarget(target) }
    func confirmConfiguration(target: FoodTargetSettings, allowance: FoodTrainingAllowance?, on date: Date, zone: String) throws {
        try ready().confirmConfiguration(target: target, allowance: allowance, on: date, timeZoneIdentifier: zone)
    }
    func confirmAllowance(_ allowance: FoodTrainingAllowance?, on date: Date, zone: String) throws {
        try ready().confirmAllowance(allowance, on: date, timeZoneIdentifier: zone)
    }
    func complete(on date: Date, zone: String, at now: Date) throws {
        try ready().confirmDayComplete(on: date, timeZoneIdentifier: zone, at: now)
    }
    func reopen(_ day: String) throws { try ready().reopenDay(day) }
    func finishedDayCount(from firstDay: String, through lastDay: String) throws -> Int {
        try ready().finishedDayCount(from: firstDay, through: lastDay)
    }
    func setNoAlcohol(_ marked: Bool, on date: Date, zone: String, at now: Date) throws {
        try ready().setNoAlcohol(marked, on: date, timeZoneIdentifier: zone, at: now)
    }
    func weights(since: Date? = nil) throws -> [FoodWeightEntry] { try ready().weights(since: since) }
    func saveWeight(_ entry: FoodWeightEntry) throws { try ready().saveWeight(entry) }
    func deleteWeight(id: UUID) throws { try ready().deleteWeight(id: id) }

    // MARK: Longevity

    /// The week's plants, lens and stack, the protocol's food targets, and the week's meals for the plants screen, read
    /// together for the day at `date`. Each part that fails to read stays nil, so the others still draw.
    func longevity(date: Date, calendar: Calendar, bodyWeightKilograms: Double?) throws -> FoodLongevitySnapshot {
        let store = try ready()
        let week = try FoodISOWeek(containing: date, calendar: calendar)
        var earliest = week
        for _ in 0..<FoodLongevitySnapshot.earlierWeeks { earliest = earliest.previous }
        let data = try store.overview(from: earliest.firstDay, through: week.lastDay)
        let list = try? FoodPlantList.bundled()
        let plants = list.map { FoodPlantWeek(week: week, meals: data.meals, list: $0) }
        var earlier: [FoodPlantWeek] = []
        var cursor = week
        for _ in 0..<FoodLongevitySnapshot.earlierWeeks {
            cursor = cursor.previous
            if let list { earlier.append(FoodPlantWeek(week: cursor, meals: data.meals, list: list)) }
        }
        let hasEarlier = data.meals.contains { !week.contains(localDay: $0.localDay) }
        let localDay = try FoodMeal.day(at: date, timeZoneIdentifier: calendar.timeZone.identifier)
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date)) ?? date
        // The lens counts the week's finished days up to the shown day, the days Food's week chart counts
        // (`FoodWeekSoFar`), so both cards give one number on a past day too.
        let soFar = data.through(localDay: localDay)
        return FoodLongevitySnapshot(
            targets: (try? store.protocolTargets(at: end.addingTimeInterval(-1))) ?? .none,
            plants: plants, newPlants: plants?.newPlants(comparedWith: earlier) ?? [], hasEarlierWeeks: hasEarlier,
            lens: FoodLongevityLens(week: week, data: soFar, bodyWeightKilograms: bodyWeightKilograms),
            barcodedItems: FoodLensTiles.barcodedItems(week: week, data: soFar),
            stack: try? stackShelf(localDay: localDay),
            weekMeals: data.meals.filter { week.contains(localDay: $0.localDay) })
    }

    /// Both lanes of the stack on one local day, for Protocol checks.
    func stackDays(localDay: String) throws -> RoutineStackDay {
        let stack = try ready().supplementStore
        return RoutineStackDay(supplements: try stack.supplementDay(localDay), medication: try stack.medicationDay(localDay))
    }

    func stackShelf(localDay: String) throws -> FoodStackShelf {
        let stack = try ready().supplementStore
        return FoodStackShelf(supplements: try stack.supplementDay(localDay), medication: try stack.medicationDay(localDay),
                              items: try stack.supplements())
    }
    func supplements() throws -> [SupplementItem] { try ready().supplementStore.supplements() }
    func medication() throws -> [MedicationItem] { try ready().supplementStore.medication() }
    func uniqueStackKey(forName name: String, lane: StackLane) throws -> String {
        try ready().supplementStore.uniqueKey(forName: name, lane: lane)
    }
    func saveSupplement(_ item: SupplementItem) throws { try ready().supplementStore.save(item) }
    func saveMedication(_ item: MedicationItem) throws { try ready().supplementStore.save(item) }
    func setStackItemActive(_ active: Bool, id: UUID) throws { try ready().supplementStore.setActive(active, itemID: id) }
    func deleteStackItem(id: UUID) throws { try ready().supplementStore.deleteItem(id: id) }
    /// A tap on a capsule: a due dose becomes taken, a taken dose goes back to not recorded.
    func toggleDose(_ capsule: FoodCapsule, day: String, at date: Date) throws {
        let stack = try ready().supplementStore
        switch FoodStackTap.action(for: capsule.dose.state) {
        case .take: try stack.record(.taken, itemID: capsule.dose.itemID, day: day, slot: capsule.dose.slot, at: date)
        case .clear: try stack.clearTick(itemID: capsule.dose.itemID, day: day, slot: capsule.dose.slot)
        }
    }

    /// Takes a plant off every meal of the week that holds it, as the person's edit.
    func removePlant(key: String, week: FoodISOWeek, at date: Date) throws {
        let store = try ready()
        let list = try FoodPlantList.bundled()
        let meals = try store.overview(from: week.firstDay, through: week.lastDay).meals
        for meal in meals where meal.items.contains(where: { item in item.plants(in: list).contains { $0.key == key } }) {
            var draft = try store.editDraft(id: meal.id)
            for index in draft.items.indices where draft.items[index].plants(in: list).contains(where: { $0.key == key }) {
                try draft.items[index].removePlant(key: key, at: date)
            }
            try store.confirm(draft, at: date)
        }
    }

    /// Names a plant on the first item of one meal, as the person's edit.
    func addPlant(named name: String, toMeal id: UUID, at date: Date) throws {
        let store = try ready()
        var draft = try store.editDraft(id: id)
        guard !draft.items.isEmpty else { throw FoodError.missingMeal }
        try draft.items[0].addPlant(named: name, in: try FoodPlantList.bundled(), at: date)
        try store.confirm(draft, at: date)
    }
}

/// What `AppFoodRepository.longevity` reads in one call. Images are made on the main actor from it.
nonisolated struct FoodLongevitySnapshot: Sendable {
    /// Weeks before this one that decide which plants are new.
    static let earlierWeeks = 4
    let targets: FoodProtocolTargets
    let plants: FoodPlantWeek?
    let newPlants: [FoodWeekPlant]
    let hasEarlierWeeks: Bool
    let lens: FoodLongevityLens
    let barcodedItems: Int
    let stack: FoodStackShelf?
    let weekMeals: [FoodMeal]
}

#if DEBUG
nonisolated enum AppFoodFixtures {
    static func seed(_ store: FoodStore, endingOn anchor: Date) throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Australia/Perth")!
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = utc.dateComponents([.year, .month, .day], from: anchor)
        let today = calendar.date(from: parts)!
        if FoodAssociationFixtures.enabled { try FoodAssociationFixtures.seedHistory(store, today: today, calendar: calendar) }
        if AgentDayFixtures.isRequested { try AgentDayFixtures.seedLateDinners(store, today: today, calendar: calendar) }
        let first = calendar.date(byAdding: .day, value: -6, to: today)!
        try store.confirmTarget(.init(goal: .maintain, baseEnergy: 2_270, protein: 150, carbs: 280, fat: 80,
            waterMillilitres: 2_500, confirmedAt: first.addingTimeInterval(-86_400)))
        let list = try? FoodPlantList.bundled()
        /// The plants the person named on each dish, so the plants field has a week to show. Nutrients stay as typed.
        func plants(_ names: [String]) -> FoodPlantEdits? {
            guard let list else { return nil }
            return FoodPlantEdits(added: names.compactMap { list.reference(forName: $0) })
        }
        for index in 0..<7 {
            let day = calendar.date(byAdding: .day, value: index, to: first)!
            let source = FoodProvenance(source: .typed, recordedAt: day.addingTimeInterval(8 * 3_600))
            let breakfast = FoodItem(name: "Greek yogurt, berries, granola", amount: 1, unit: .serving,
                nutrients: .init([.energy: 520, .protein: 32, .carbs: 72, .fat: 15, .fibre: 8, .sugar: 22, .salt: 0.3, .caffeine: 0, .alcoholUnits: 0]), provenance: [source],
                plantEdits: plants(fixtureBreakfastPlants[index]))
            let lunch = FoodItem(name: "Chicken rice bowl, avocado", amount: 1, unit: .serving,
                nutrients: .init([.energy: 712, .protein: 50, .carbs: 68, .fat: 26, .fibre: 9, .sugar: 4, .salt: 1.1, .caffeine: 0, .alcoholUnits: 0]), provenance: [source],
                plantEdits: plants(fixtureLunchPlants[index]))
            for (slot, item, hour) in [(FoodMealSlot.breakfast, breakfast, 8.0), (.lunch, lunch, 12.5)] {
                let time = day.addingTimeInterval(hour * 3_600)
                // Breakfast is typed; only the photographed lunch carries the plate photo.
                let photos = slot == .lunch ? [try FoodCaptureFixtures.photo(at: time)] : []
                try store.confirm(.init(slot: slot, occurredAt: time, timeZoneIdentifier: calendar.timeZone.identifier, items: [item], photos: photos), at: time)
            }
            if index < 6 {
                let time = day.addingTimeInterval(19 * 3_600)
                let dinner = FoodItem(name: "Salmon, potatoes and greens", amount: 1, unit: .serving,
                    nutrients: .init([.energy: Double(780 + index * 45), .protein: 45, .carbs: 70, .fat: 24, .fibre: 10,
                        .sugar: 5, .salt: 1.2, .caffeine: 0, .alcoholUnits: 0]), provenance: [source],
                    plantEdits: plants(fixtureDinnerPlants[index]))
                try store.confirm(.init(slot: .dinner, occurredAt: time, timeZoneIdentifier: calendar.timeZone.identifier, items: [dinner]), at: time)
            }
            let waterTime = day.addingTimeInterval(11 * 3_600)
            try store.confirmDrink(.init(kind: .water, name: "Water", occurredAt: waterTime, timeZoneIdentifier: calendar.timeZone.identifier,
                waterMillilitres: index == 6 ? 1_200 : 2_500, caffeineMilligrams: 0, alcoholUnits: 0, energy: 0, confirmedAt: waterTime))
            for hour in [8.0, 10.25] {
                let time = day.addingTimeInterval(hour * 3_600)
                try store.confirmDrink(.init(kind: .caffeine, name: "Black coffee", occurredAt: time, timeZoneIdentifier: calendar.timeZone.identifier,
                    caffeineMilligrams: 95, alcoholUnits: 0, energy: 4,
                    additionalNutrients: .init([.protein: 0, .carbs: 0, .fat: 0, .fibre: 0, .sugar: 0, .salt: 0]), confirmedAt: time))
            }
            try store.confirmAllowance(.init(title: index == 6 ? "Upper A" : "Training", energy: 180,
                plannedStrain: .init(value: 12, scale: .daily21), confirmedAt: day), on: day, timeZoneIdentifier: calendar.timeZone.identifier)
            if index < 6 { try store.confirmDayComplete(on: day, timeZoneIdentifier: calendar.timeZone.identifier, at: day.addingTimeInterval(23.5 * 3_600)) }
        }
    }

    private static let fixtureBreakfastPlants: [[String]] = [
        ["blueberries", "oats", "walnuts"], ["raspberries", "oats", "chia seeds"], ["banana", "oats", "almonds"],
        ["strawberries", "buckwheat", "flaxseed"], ["blueberries", "oats", "cinnamon"], ["apple", "oats", "pumpkin seeds"],
        ["blackberries", "oats", "hemp seeds"],
    ]
    private static let fixtureLunchPlants: [[String]] = [
        ["avocado", "brown rice", "coriander"], ["avocado", "quinoa", "red pepper"], ["avocado", "chickpeas", "lemon"],
        ["avocado", "brown rice", "parsley"], ["avocado", "lentils", "carrot"], ["avocado", "black beans", "lime"],
        ["avocado", "brown rice", "shiitake", "fennel"],
    ]
    private static let fixtureDinnerPlants: [[String]] = [
        ["potato", "broccoli", "garlic"], ["sweet potato", "kale", "ginger"], ["potato", "green beans", "dill"],
        ["potato", "spinach", "onion"], ["courgette", "tomato", "basil"], ["potato", "peas", "mint"], [],
    ]

    /// The contract's stack (six of seven taken, magnesium still due tonight), a protocol whose kitchen closes at 18:30
    /// with a fibre target of 35 g, a snack of two scanned products yesterday and a weight reading, for the populated
    /// Food screen. Yesterday is the one finished day of today's week, so the lens has protein per kilogram and an
    /// ultra-processed share to show. Today's meals and totals stay as `seed` wrote them.
    static func seedLongevity(_ store: FoodStore, routine: RoutineStore, endingOn anchor: Date) throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Australia/Perth")!
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let today = calendar.date(from: utc.dateComponents([.year, .month, .day], from: anchor))!
        let created = calendar.date(byAdding: .day, value: -30, to: today)!
        let localDay = try FoodMeal.day(at: today, timeZoneIdentifier: calendar.timeZone.identifier)
        let startDay = try FoodMeal.day(at: created, timeZoneIdentifier: calendar.timeZone.identifier)
        let rows: [(String, Double, DoseUnit, StackSchedule, String, String)] = [
            ("D3", 2_000, .iu, .morning, "#E8C196", "#C2843A"), ("Omega-3", 1_000, .mg, .morning, "#F6B3C5", "#D6456C"),
            ("Creatine", 5, .g, .morning, "#EDE6DA", "#B3A898"), ("B12", 500, .mcg, .morning, "#A6E4D6", "#12927F"),
            ("Fibre", 5, .g, .morning, "#D9C49A", "#9A6526"), ("Glycine", 3, .g, .morning, "#CFA2EE", "#8E45B8"),
            ("Mg", 300, .mg, .evening, "#B7BDF6", "#5B63D6"),
        ]
        let stack = store.supplementStore
        for (index, row) in rows.enumerated() {
            let item = try SupplementItem(name: row.0, dose: DoseAmount(amount: row.1, unit: row.2), form: .capsule,
                colors: CapsuleColors(first: row.4, second: row.5), schedule: row.3, startDay: startDay, sortOrder: index,
                createdAt: created.addingTimeInterval(Double(index)))
            try stack.save(item)
            if row.3 == .morning {
                try stack.record(.taken, itemID: item.id, day: localDay, slot: .morning, at: today.addingTimeInterval(8 * 3_600 + Double(index) * 60))
            }
        }
        // Yesterday afternoon: a chocolate oat bar (group 4) and rolled oats (group 1), each with its ingredients.
        let snackTime = today.addingTimeInterval(-86_400 + 15.5 * 3_600)
        func scanned(_ name: String, _ code: String, grams: Double, nova: Int, tags: [String], _ values: [FoodNutrient: Double]) -> FoodItem {
            FoodItem(name: name, amount: grams, unit: .grams, nutrients: .init(values),
                     provenance: [FoodProvenance(source: .barcode, recordedAt: snackTime, barcode: code)], novaGroup: nova, ingredientTags: tags)
        }
        try store.confirm(.init(slot: .snack, occurredAt: snackTime, timeZoneIdentifier: calendar.timeZone.identifier, items: [
            scanned("Chocolate oat bar", "4000000000027", grams: 25, nova: 4, tags: ["en:oat-flakes", "en:sugar", "en:hazelnut", "en:cocoa-mass"],
                    [.energy: 110, .protein: 2, .carbs: 15, .fat: 5, .fibre: 2, .sugar: 8, .salt: 0.05, .caffeine: 0, .alcoholUnits: 0]),
            scanned("Rolled oats", "4000000000034", grams: 80, nova: 1, tags: ["en:oat-flakes"],
                    [.energy: 300, .protein: 10, .carbs: 48, .fat: 6, .fibre: 8, .sugar: 1, .salt: 0, .caffeine: 0, .alcoholUnits: 0]),
        ]), at: snackTime)
        // Saving a meal reopens its day, so yesterday is marked finished again, as `seed` left it.
        let yesterday = today.addingTimeInterval(-86_400)
        try store.confirmDayComplete(on: yesterday, timeZoneIdentifier: calendar.timeZone.identifier, at: yesterday.addingTimeInterval(23.5 * 3_600))
        // Nine days back, so a weight the planner logs today starts a fresh 7-day average.
        let weighed = today.addingTimeInterval(-9 * 86_400 + 7.5 * 3_600)
        try store.saveWeight(FoodWeightEntry(measuredAt: weighed, timeZoneIdentifier: calendar.timeZone.identifier, kilograms: 78.4))
        try routine.createProtocol(RoutineProtocol(name: "Food fixture", createdAt: created), rules: [
            ProtocolRule(key: "kitchen-closes", title: "Kitchen closes at 18:30", group: .food,
                         target: RuleTarget(kind: .atMost, metric: RoutineMetric.lastMealTime.rawValue, value: 1_110),
                         timeOfDayMinutes: 1_110, source: .food, isEvening: true),
            ProtocolRule(key: "fibre", title: "Fibre 35 g", group: .food,
                         target: RuleTarget(kind: .atLeast, metric: RoutineMetric.fibreG.rawValue, value: 35, unit: "g"), source: .food),
        ])
    }
}
#endif

#if DEBUG
/// Explicit in-process barcode stub for fixture and UI compositions.
nonisolated private struct AppFoodProductFixtureTransport: FoodProductTransport {
    func send(_ request: URLRequest) async throws -> FoodProductHTTPResponse {
        guard request.url?.lastPathComponent == "4000000000010.json" else { throw FoodBarcodeError.notFound }
        let text = #"{"status":"success","errors":[],"warnings":[],"product":{"code":"4000000000010","product_name":"Almond drink","brands":"Fixture","schema_version":1004,"nutrition":{"aggregated_set":{"preparation":"as_sold","per":"100ml","nutrients":{"energy-kcal":{"value":24,"unit":"kcal","source":"packaging"},"proteins":{"value":0.8,"unit":"g"},"carbohydrates":{"value":2.4,"unit":"g"},"fat":{"value":1.2,"unit":"g"}}}}}}"#
        return .init(status: 200, body: Data(text.utf8))
    }
}
#endif
