import DesignSystem
import FoodKit
import Foundation

extension MethodCatalog {
    static let foodEntries: [MethodEntry] = [proteinPerKilogram, fibre, ultraProcessedShare, plantsPerWeek]

    private static let lensFile = MethodPaths.food + "FoodLongevityLens.swift"
    private static let lensTests = MethodPaths.foodTests + "FoodLongevityLensTests.swift"
    private static let tilesTests = MethodPaths.foodTests + "Longevity/FoodLensTilesTests.swift"
    private static let dayTotal = MethodSourceFile(MethodPaths.food + "FoodOverview.swift", lines: 57...68,
                                                   symbol: "FoodDaySummary.total",
                                                   anchor: "return .init(values: readings.isEmpty && completed ? [0] : readings)")
    private static let completeDaysLimit = "Only days you mark complete count, because only a complete day says everything eaten was logged."

    static let proteinPerKilogram = MethodEntry(
        id: .proteinPerKilogram, group: .food, title: "Protein per kg",
        version: nil,
        summary: "Your average daily protein this week divided by your body weight, in grams per kilogram.",
        rule: [
            "Loopr adds up the protein of every food and drink on each day you marked complete this ISO week, then takes the mean of the days that reported protein.",
            "It divides that mean by your logged weight. A weight outside 20 to 400 kg, or no weight at all, leaves the value empty."
        ],
        formula: MethodFormula([
            LooprFormulaLine([fv("protein per kg"), fo("="), ff("mean"), fo("("), fv("daily protein"), fo(")"), fo("/"), fv("weight")])
        ], caption: "Daily protein is in grams, weight in kilograms."),
        inputs: [MethodInput("Protein", unit: "g", from: .foodLog, .openFoodFacts, .photoEstimate), MethodInput("Body weight", unit: "kg", from: .typed)],
        references: [
            MethodReference(.background, authors: "Bauer J et al.", year: 2013,
                            title: "Evidence-based recommendations for optimal dietary protein intake in older people: a position paper from the PROT-AGE Study Group",
                            venue: "Journal of the American Medical Directors Association 14(8):542-559",
                            use: "The protein target in the bundled protocol templates.")
        ],
        sources: [
            MethodSourceFile(lensFile, lines: 104...107, symbol: "FoodLongevityLens.proteinPerKilogram",
                             anchor: "proteinPerKilogram = .init(value: mean / weight, days: daily(.protein).count)"),
            dayTotal
        ],
        testSuites: [MethodTestSuite("FoodLongevityLensTests", in: lensTests), MethodTestSuite("FoodLensTilesTests", in: tilesTests)],
        limits: [completeDaysLimit, "Photo estimates of protein can be well off.", "An old weight skews it."],
        unit: "g/kg")

    static let fibre = MethodEntry(
        id: .fibre, group: .food, title: "Fibre",
        version: nil,
        summary: "Your average daily fibre this week, in grams.",
        rule: [
            "Loopr adds up the fibre of every food and drink on each day you marked complete this ISO week and takes the mean.",
            "A day where no item reported fibre does not count, so a week with no fibre values stays empty."
        ],
        inputs: [MethodInput("Fibre", unit: "g", from: .foodLog, .openFoodFacts, .photoEstimate)],
        references: [
            MethodReference(.background, authors: "EFSA Panel on Dietetic Products, Nutrition, and Allergies", year: 2010,
                            title: "Scientific opinion on dietary reference values for carbohydrates and dietary fibre",
                            venue: "EFSA Journal 8(3):1462", use: "The fibre target in the bundled protocol templates.")
        ],
        sources: [
            MethodSourceFile(lensFile, lines: 108...108, symbol: "FoodLongevityLens.fibrePerDay",
                             anchor: "if let mean = average(daily(.fibre)) { fibrePerDay = .init(value: mean, days: daily(.fibre).count) } else { fibrePerDay = nil }"),
            dayTotal
        ],
        testSuites: [MethodTestSuite("FoodLongevityLensTests", in: lensTests)],
        limits: [completeDaysLimit, "Many labels and photo estimates leave fibre out, which makes the week read low."],
        unit: "g")

    static let ultraProcessedShare = MethodEntry(
        id: .ultraProcessedShare, group: .food, title: "Ultra-processed share", methodName: "NOVA group 4",
        version: nil,
        summary: "The share of energy from barcoded foods that Open Food Facts puts in NOVA group 4, with how much of your week's energy that covers.",
        rule: [
            "Only barcoded items with a NOVA group from Open Food Facts are classified. Loopr adds no classification of its own (DEC-12.8).",
            "The share is group 4 energy divided by classified energy. Coverage is classified energy divided by all the energy you logged on complete days.",
            "Everything else counts as not classified. With no classified energy the share stays empty."
        ],
        formula: MethodFormula([
            LooprFormulaLine([fv("share"), fo("="), fv("energy in group 4"), fo("/"), fv("classified energy")]),
            LooprFormulaLine([fv("coverage"), fo("="), fv("classified energy"), fo("/"), fv("all energy")])
        ], caption: "Energy is in kcal, from complete days this ISO week."),
        inputs: [MethodInput("NOVA group", from: .openFoodFacts), MethodInput("Energy", unit: "kcal", from: .foodLog, .openFoodFacts)],
        references: [
            MethodReference(.data, authors: "Open Food Facts", year: nil, title: "nova_group",
                            venue: "Open Food Facts product data", link: "https://world.openfoodfacts.org/nova",
                            use: "The NOVA group Loopr reads for each barcoded item.")
        ],
        sources: [
            MethodSourceFile(lensFile, lines: 110...129, symbol: "FoodLongevityLens.ultraProcessed",
                             anchor: "if group == 4 { ultraProcessedEnergy += energy ?? 0 }"),
            MethodSourceFile(MethodPaths.food + "Longevity/FoodLensTiles.swift", lines: 47...120, symbol: "FoodLensTiles.tiles",
                             anchor: "let items = \"\\(share.classifiedItems) of \\(max(barcodedItems, share.classifiedItems)) barcoded items\"")
        ],
        testSuites: [MethodTestSuite("FoodLongevityLensTests", in: lensTests), MethodTestSuite("FoodLensTilesTests", in: tilesTests)],
        limits: [
            "Home cooking, photo estimates and typed foods are never classified, so the share describes only the barcoded part of your week. Check the coverage.",
            "NOVA groups describe processing, not nutrients."
        ],
        unit: "%")

    static let plantsPerWeek = MethodEntry(
        id: .plantsPerWeek, group: .food, title: "Plants per week",
        version: nil,
        summary: "How many different plants you ate this ISO week, Monday to Sunday.",
        rule: [
            "Plants come from three places: the photo estimate, Open Food Facts ingredients matched against Loopr's bundled plant list, and your own edits. Your edits win.",
            "Each plant counts once a week. A specific plant replaces a general one, and the list's refined products do not count. A name that is not on the list counts as its own plant.",
            "The goal line is \(FoodPlantWeek.weeklyGoal) a week."
        ],
        inputs: [MethodInput("Plants in a meal", from: .photoEstimate, .openFoodFacts, .typed)],
        references: [
            MethodReference(.data, authors: "Loopr", year: nil, title: "Bundled plant list",
                            venue: "LooprPackages/Sources/FoodKit/FoodPlants.json, file version 1",
                            use: "The plant names and Open Food Facts ingredient ids Loopr matches against.")
        ],
        sources: [
            MethodSourceFile(MethodPaths.food + "FoodPlantWeek.swift", lines: 123...144, symbol: "FoodPlantWeek.init",
                             anchor: "for plant in item.plants(in: list) {"),
            MethodSourceFile(MethodPaths.food + "FoodPlants.swift", lines: 220...242, symbol: "FoodItem.plants",
                             anchor: "for plant in list.plants(fromOFFTags: ingredientTags ?? []) where result[plant.key] == nil {")
        ],
        testSuites: [
            MethodTestSuite("FoodPlantWeekTests", in: MethodPaths.foodTests + "FoodPlantWeekTests.swift"),
            MethodTestSuite("FoodItemPlantTests", in: MethodPaths.foodTests + "FoodPlantWeekTests.swift"),
            MethodTestSuite("FoodISOWeekTests", in: MethodPaths.foodTests + "FoodPlantWeekTests.swift"),
            MethodTestSuite("FoodPlantListTests", in: MethodPaths.foodTests + "FoodPlantListTests.swift")
        ],
        limits: [
            "Herbs and spices count the same as a vegetable.",
            "A photo can miss what is mixed in. Edit the meal to add it."
        ])
}
