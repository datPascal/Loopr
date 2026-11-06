import AnalyticsKit
import DesignSystem
import Foundation

extension MethodCatalog {
    static let ageEntries: [MethodEntry] = [cardioAge, phenoAge, looprAge]

    private static let ageTests = MethodPaths.analyticsTests + "AgeAnalyticsTests.swift"
    private static let compositeTests = MethodPaths.analyticsTests + "CompositeAgeTests.swift"
    private static let phenoAgeFile = MethodPaths.analytics + "Age/PhenoAge.swift"
    private static let coefficientsFile = MethodPaths.analytics + "Age/PhenoAgeCoefficients.swift"

    static let friend = MethodReference(
        authors: "Kaminsky LA, Arena R, Myers J", year: 2015,
        title: "Reference standards for cardiorespiratory fitness measured with CPET: data from FRIEND",
        venue: "Mayo Clinic Proceedings 90(11), table 3, treadmill", link: "https://doi.org/10.1016/j.mayocp.2015.07.026",
        use: "The treadmill VO₂max medians and percentiles by age and reference group.")

    /// The FRIEND curve's version as the catalog shows it, read from `FriendReferenceCurve.version1`.
    public static let cardioAgeVersion = "FRIEND reference \(FriendReferenceCurve.version1.referenceVersion)"

    static let cardioAge = MethodEntry(
        id: .cardioAge, group: .age, title: "Cardio age",
        version: MethodVersion(cardioAgeVersion, symbol: "FriendReferenceCurve.version1.referenceVersion",
                               file: MethodPaths.analytics + "Age/AgeReference.swift"),
        summary: "The age at which a typical person in your reference group in the FRIEND study has your VO₂max.",
        rule: [
            "VO₂max is a supervised exercise test you typed in, used for 180 days, or the median of Apple Health samples from the last 42 days. Apple Health needs at least 3 samples on 3 different days, spanning at least 14 days.",
            "Loopr reads the FRIEND treadmill medians for your reference group at ages 25, 35, 45, 55, 65 and 75, and draws a straight line between the two medians on either side of your value.",
            "Above the age-25 median it shows 25 or younger, and below the age-75 median 75 or older. Loopr never estimates VO₂max from resting heart rate."
        ],
        formula: MethodFormula([
            LooprFormulaLine([fv("Cardio age"), fo("="), fv("a₁"), fo("+"), fo("("), fv("M₁"), fo("−"), fv("v"), fo(")"), fo("/"),
                              fo("("), fv("M₁"), fo("−"), fv("M₂"), fo(")"), fo("·"), fo("("), fv("a₂"), fo("−"), fv("a₁"), fo(")")])
        ], caption: "v is your VO₂max. M₁ and M₂ are the FRIEND medians at ages a₁ and a₂ on either side of it."),
        inputs: [MethodInput("VO₂max", unit: "mL/kg/min", from: .appleHealth, .typed), MethodInput("Reference group", from: .typed),
                 MethodInput("Age", unit: "years", from: .typed)],
        references: [friend],
        sources: [
            MethodSourceFile(MethodPaths.analytics + "Age/AgeCalculation.swift", lines: 70...150, symbol: "CardioAgeCalculator.calculate",
                             anchor: "let fraction = (upper.median - vo2max) / (upper.median - lower.median)"),
            MethodSourceFile(MethodPaths.analytics + "Age/AgeReference.swift", lines: 51...61, symbol: "FriendReferenceCurve.version1",
                             anchor: "FriendReferencePoint(calculationAge: 25, femaleMedian: 37.6, maleMedian: 48.0),"),
            MethodSourceFile(MethodPaths.analytics + "Age/AgeReference.swift", lines: 221...261, symbol: "VO2MaxSourceSelector.select",
                             anchor: "let median = Self.median(candidates.map(\\.vo2max))")
        ],
        testSuites: [
            MethodTestSuite("FriendReferenceFixtureTests", in: ageTests),
            MethodTestSuite("CardioAgeInterpolationTests", in: ageTests),
            MethodTestSuite("VO2maxSourceSelectionTests", in: ageTests),
            MethodTestSuite("NoHeuristicFitnessAgeTests", in: ageTests)
        ],
        limits: [
            "Studies of exercise-based watch estimates found errors of up to about 10 mL/kg/min against a lab test, and Cardio age moves with them.",
            "FRIEND is a treadmill study of US adults aged 20 to 79. Outside that group there is no reference.",
            "You choose the reference group. Loopr does not infer it.",
            "It is about fitness only. It is not heart age, and it says nothing about how long you will live."
        ],
        showsMedicalLine: true, unit: "years")

    // MARK: PhenoAge

    /// A constant as formula tokens, with a typographic minus.
    static func constant(_ value: Double) -> [LooprFormulaToken] {
        value < 0 ? [fo("−"), fn(String(-value))] : [fn(String(value))]
    }

    static func signed(_ value: Double) -> String {
        value < 0 ? "−" + String(-value) : String(value)
    }

    /// The three PhenoAge lines, built from the coefficients the engine uses so the page cannot drift from the code.
    static func phenoAgeFormula(_ c: PhenoAgeCoefficients) -> MethodFormula {
        let weights = PhenoAge.inputMarkers.compactMap { key in
            c.markerCoefficients[key].map { "\(key.marker.displayName.lowercased()) \(signed($0))" }
        }
        return MethodFormula([
            LooprFormulaLine([fv("xb"), fo("=")] + constant(c.intercept) + [fo("+"), ff("Σ"), fv("βᵢ"), fo("·"), fv("xᵢ"), fo("+")]
                             + constant(c.ageCoefficient) + [fo("·"), fv("age")]),
            LooprFormulaLine([fv("M"), fo("="), fn("1"), fo("−"), ff("exp"), fo("("), fo("−"), ff("exp"), fo("("), fv("xb"), fo(")"),
                              fo("·"), fo("("), ff("exp"), fo("("), fn(String(Int(c.horizonMonths))), fo("·")] + constant(c.gamma)
                             + [fo(")"), fo("−"), fn("1"), fo(")"), fo("/")] + constant(c.gamma) + [fo(")")]),
            LooprFormulaLine([fv("PhenoAge"), fo("=")] + constant(c.offsetYears) + [fo("+"), ff("ln"), fo("(")] + constant(-c.scale)
                             + [fo("·"), ff("ln"), fo("("), fn("1"), fo("−"), fv("M"), fo(")"), fo(")"), fo("/")] + constant(c.divisor))
        ], caption: "M is the 10-year mortality score from a Gompertz model. xᵢ are the 9 markers in the paper's units, with CRP as its natural log. The weights βᵢ are from Table S1 of Supplement 1: \(weights.joined(separator: ", ")).")
    }

    static let phenoAgeInputs: [MethodInput] = PhenoAge.inputMarkers.map { key in
        MethodInput(key == .crp ? "C-reactive protein, natural log" : key.marker.displayName,
                    unit: LabUnitConverter.phenoAgeUnit(for: key), from: .labReport, .typed)
    } + [MethodInput("Age at the blood draw", unit: "years", from: .computed("From your birth year"))]

    static let phenoAge = MethodEntry(
        id: .phenoAge, group: .age, title: "Blood age", methodName: "PhenoAge",
        version: MethodVersion(PhenoAge.version, symbol: "PhenoAge.version", file: phenoAgeFile),
        summary: "From 9 blood values and your age. Built by Levine and colleagues in 2018 to predict mortality in US survey data. An estimate, not a diagnosis.",
        rule: [
            "Loopr needs all 9 values from one report, which is one blood draw, and converts each to the unit the paper used. It computes nothing when a value is missing from that report, appears twice in it, cannot be converted or sits outside the range pyaging registers for it. Two reports are never combined. Blood age uses the newest report that holds all 9, and of two such reports from one day, the one saved last.",
            "A weighted sum of the 9 values and your age gives a 10-year mortality score. Blood age is the age at which that score would be typical in the paper's data.",
            "The weights are from Table S1 of the paper's Supplement 1, checked against pyaging 0.5.7 and BioAge. Where another source prints a different value, the paper wins and the difference is recorded."
        ],
        formula: phenoAgeFormula(.published),
        inputs: phenoAgeInputs,
        references: [
            MethodReference(authors: "Levine ME et al.", year: 2018, title: "An epigenetic biomarker of aging for lifespan and healthspan",
                            venue: "Aging (Albany NY) 10(4):573-591, Supplement 1",
                            link: "https://pmc.ncbi.nlm.nih.gov/articles/PMC5940111",
                            use: "Table S1 gives the weights. The conversion section gives 141.50225, 0.00553 and 0.090165."),
            MethodReference(.data, authors: "Liu Z et al.", year: 2018,
                            title: "A new aging measure captures morbidity and mortality risk across diverse subpopulations from NHANES IV",
                            venue: "PLoS Medicine 15(12):e1002718, S1 Table", link: "https://doi.org/10.1371/journal.pmed.1002718",
                            use: "The averages the What moved it chart compares your values with, from 11,432 US adults aged 20 to 84, NHANES IV, 1999 to 2010. The table labels albumin mg/dL and CRP g/L, but its numbers fit g/L and mg/dL."),
            MethodReference(.implementation, authors: "pyaging", year: nil, title: "clocks/notebooks/phenoage.ipynb",
                            venue: "pyaging 0.5.7, commit c15cf28347f5b7a984646a16f5f01b95a1e15c20",
                            use: "Checked value by value against the paper, and the source of the registered input ranges."),
            MethodReference(.implementation, authors: "BioAge", year: nil, title: "R/phenoage_calc.R",
                            venue: "BioAge, commit b1f9fc02f086cd4aa74185f2335ab1366082e7fe",
                            use: "Checked value by value against the paper.")
        ],
        sources: [
            MethodSourceFile(phenoAgeFile, lines: 191...219, symbol: "PhenoAge.evaluate",
                             anchor: "let x = input.marker == .crp ? log(input.value) : input.value"),
            MethodSourceFile(phenoAgeFile, lines: 223...227, symbol: "PhenoAge.phenotypicAge",
                             anchor: "let logScale = log(c.scale * expm1(c.horizonMonths * c.gamma) / c.gamma)"),
            MethodSourceFile(phenoAgeFile, lines: 135...188, symbol: "PhenoAge.calculate",
                             anchor: "guard coefficients.isVerified else { return .unavailable(.coefficientsUnverified) }"),
            MethodSourceFile(coefficientsFile, lines: 89...105, symbol: "PhenoAgeCoefficients.published", anchor: "intercept: -19.9067,")
        ],
        testSuites: [
            MethodTestSuite("PhenoAgeEngineTests", in: MethodPaths.analyticsTests + "Labs/PhenoAgeTests.swift"),
            MethodTestSuite("LabUnitConverterTests", in: MethodPaths.analyticsTests + "Labs/LabUnitConverterTests.swift")
        ],
        limits: [
            "One blood draw is one reading. Differences between labs and between days move it.",
            "Loopr holds no published figure for how far blood age moves between two draws of the same person a few weeks apart, so read a change of a year or so with care.",
            "Your age counts from 1 July of your birth year, so it can be off by up to six months, and blood age moves with it by a little less.",
            "The What moved it chart compares your values with averages of US adults. Averages are not targets.",
            "An infection or an injury can raise CRP for weeks, and blood age with it.",
            "A result printed as a limit, such as CRP <0.3 mg/L below the lab's detection limit, is not an exact number. Loopr does not put the limit in its place, so that draw gives no blood age until the exact value is typed in.",
            "It was built on US survey data and may fit other groups less well.",
            "It estimates risk across a population. It cannot say what will happen to you."
        ],
        showsMedicalLine: true, unit: "years")

    static let looprAge = MethodEntry(
        id: .looprAge, group: .age, title: "Loopr age",
        version: nil,
        summary: "A planned fitness age from cardio fitness, resting heart rate, movement, training, sleep and body composition. It stays locked until a validated model exists.",
        rule: [
            "Loopr age will appear only after a model is fitted on a long-term study with a declared health outcome, checked on data it was not fitted on, and published with its model card (DEC-02.12).",
            "Until then the app shows a locked tile and computes nothing. There is no stand-in formula.",
            "The plan, the inputs and every gate are written out in docs/LOOPR_AGE.md."
        ],
        inputs: [
            MethodInput("Cardio fitness", unit: "mL/kg/min", from: .appleHealth),
            MethodInput("Resting heart rate", unit: "bpm", from: .band),
            MethodInput("Daily movement and zone minutes", from: .band),
            MethodInput("Strength sessions", from: .computed("Fitness")),
            MethodInput("Sleep duration and regularity", from: .band),
            MethodInput("Body composition", from: .appleHealth, .typed)
        ],
        sources: [
            MethodSourceFile(MethodPaths.analytics + "Age/AgeComposite.swift", lines: 135...137, symbol: "BundledModelCard.current",
                             anchor: "public static var current: ModelCard? { nil }"),
            MethodSourceFile(MethodPaths.analytics + "Age/AgeComposite.swift", lines: 292...320, symbol: "CompositeRiskModel.evaluate",
                             anchor: "guard let modelCard = modelCard ?? BundledModelCard.current else {"),
            MethodSourceFile("docs/LOOPR_AGE.md", lines: 143...181, symbol: "Calibrated composite and age conversion",
                             anchor: "### 4. Calibrated Composite")
        ],
        testSuites: [
            MethodTestSuite("CompositeGateTests", in: compositeTests),
            MethodTestSuite("NoHeuristicFallbackTests", in: compositeTests),
            MethodTestSuite("LooprAgeCompositeUnavailableTests", in: compositeTests),
            MethodTestSuite("CompositeUnavailableInANA07ATests", in: ageTests)
        ],
        limits: [
            "When it ships it will be a fitness age. It will not be biological age, heart age or a lifespan.",
            "It will move at most once a week, never from one night."
        ],
        showsMedicalLine: true, unit: "years")
}
