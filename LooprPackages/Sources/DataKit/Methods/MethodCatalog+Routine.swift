import AnalyticsKit
import DesignSystem
import Foundation
import JournalKit
import RoutineKit

extension MethodCatalog {
    static let routineEntries: [MethodEntry] = [protocolKeptShare, experimentResult, patternStrength]
    static let labEntries: [MethodEntry] = [labUnitConversion, labRanges]

    private static let experiments = MethodPaths.routine + "Experiments/"
    private static let experimentTests = MethodPaths.routineTests + "Experiments/"

    static let protocolKeptShare = MethodEntry(
        id: .protocolKeptShare, group: .routine, title: "Kept share",
        version: nil,
        summary: "The share of your protocol's decided rules that you kept: kept divided by kept plus missed.",
        rule: [
            "Each rule checks itself from its source: the band, Food, Fitness, Apple Health or your own tick. A rule can be kept, missed, pending or unknown.",
            "Pending and unknown rules are left out, so a day of unknowns never reads as 0%. With nothing decided the share stays empty.",
            "Each day is scored against the protocol version in force that day."
        ],
        formula: MethodFormula([
            LooprFormulaLine([fv("kept share"), fo("="), fv("kept"), fo("/"), fo("("), fv("kept"), fo("+"), fv("missed"), fo(")")])
        ], caption: "Counts of rules for the day or the week."),
        inputs: [MethodInput("Rule checks", from: .band, .foodLog, .appleHealth, .typed), MethodInput("Rules", from: .protocolRules)],
        sources: [
            MethodSourceFile(MethodPaths.routine + "RoutineDayEvaluation.swift", lines: 5...27, symbol: "RoutineDaySummary.keptShare",
                             anchor: "public var keptShare: Double? { decided == 0 ? nil : Double(kept) / Double(decided) }")
        ],
        testSuites: [
            MethodTestSuite("RoutineDayEvaluationTests", in: MethodPaths.routineTests + "RoutineDayEvaluationTests.swift"),
            MethodTestSuite("WeeklyStoryWriterTests", in: "LooprPackages/Tests/CoachKitTests/WeeklyReview/WeeklyStoryWriterTests.swift")
        ],
        limits: [
            "A rule whose source has no data that day counts as unknown, not missed.",
            "It counts rules, not how much each one matters to you."
        ],
        unit: "%")

    static let experimentResult = MethodEntry(
        id: .experimentResult, group: .routine, title: "Experiment result", methodName: "Noise band",
        version: MethodVersion(ExperimentPolicy.standard.version, symbol: "ExperimentPolicy.version",
                               file: experiments + "ExperimentStatistics.swift"),
        summary: "Whether your outcome on the on nights differed from the off nights by more than your own night-to-night spread.",
        rule: [
            "Your spread comes from the 28 nights before day 1: the median absolute deviation of the change from one night to the next, times 1.4826, divided by √2. It needs 10 nights and 6 pairs of back-to-back nights.",
            "The likely range of the difference comes from 2,000 bootstrap resamples and is 95% wide. Washout nights, nights you did not keep the rule and nights without an outcome are left out.",
            "No change means the whole range sits inside your spread. Clear means it sits wholly outside. Strong is clear with the near end at least twice your spread away, and twice the minimum nights on each side. Early means the experiment stopped early or the range still reaches into the spread."
        ],
        formula: MethodFormula([
            LooprFormulaLine([fv("spread"), fo("="), fn("1.4826"), fo("·"), ff("MAD"), fo("("), fv("night-to-night change"), fo(")"),
                              fo("/"), ff("√"), fn("2")]),
            LooprFormulaLine([fv("difference"), fo("="), ff("mean"), fo("("), fv("on nights"), fo(")"), fo("−"), ff("mean"), fo("("),
                              fv("off nights"), fo(")")])
        ], caption: "MAD is the median absolute deviation. Dividing by √2 turns the spread of a change between two nights into the spread of one night."),
        inputs: [MethodInput("Outcome each night", from: .band), MethodInput("Whether you kept the rule", from: .protocolRules, .typed),
                 MethodInput("Design, washout and minimum nights", from: .typed)],
        sources: [
            MethodSourceFile(experiments + "ExperimentStatistics.swift", lines: 107...114, symbol: "ExperimentStatistics.nightToNightSpread",
                             anchor: "let normal = 1.4826 / 2.0.squareRoot()"),
            MethodSourceFile(experiments + "ExperimentAnalysis.swift", lines: 118...129, symbol: "ExperimentAnalyzer.call",
                             anchor: "if range.lowerBound >= -spread, range.upperBound <= spread { return .noChange }"),
            MethodSourceFile(experiments + "ExperimentStatistics.swift", lines: 144...165, symbol: "ExperimentStatistics.bootstrapInterval",
                             anchor: "let tail = (1 - min(max(confidence, 0), 1)) / 2")
        ],
        testSuites: [
            MethodTestSuite("ExperimentAnalysisTests", in: experimentTests + "ExperimentAnalysisTests.swift"),
            MethodTestSuite("ExperimentNoiseBandTests", in: experimentTests + "ExperimentNoiseBandTests.swift"),
            MethodTestSuite("ExperimentScheduleTests", in: experimentTests + "ExperimentScheduleTests.swift")
        ],
        limits: [
            "These compare your own nights. They do not show cause.",
            "With few nights the range comes out a little narrow, which is one reason Strong asks for twice the minimum nights.",
            "Anything else that changed on the on nights, such as travel or illness, moves the result too."
        ])

    static let patternStrength = MethodEntry(
        id: .patternStrength, group: .routine, title: "Pattern strength", methodName: "Strong, Clear and Early",
        version: MethodVersion(PatternPolicy.default.algorithmVersion, symbol: "PatternPolicy.algorithmVersion",
                               file: MethodPaths.journal + "Patterns/PatternPolicy.swift"),
        summary: "How Loopr labels a difference between days with a habit and days without it: Strong, Clear or Early.",
        rule: [
            "For each habit and outcome, Loopr compares days with the habit and days without it over the last 90 days. It adjusts for the weekday, the previous day's strain and your other habits with a ridge regression.",
            "Clear needs at least 10 days on each side, 30 eligible days, a difference at least as big as the outcome's practical threshold and a Holm-adjusted p below 0.05. Strong needs twice the threshold and p below 0.01. Early is a first look, with at least 5 days on each side.",
            "Early never appears in lists, on Today or in coach notes (DEC-06.4)."
        ],
        inputs: [MethodInput("Yes or no for the habit each day", from: .typed, .foodLog, .band),
                 MethodInput("Outcome each day", from: .band, .typed)],
        sources: [
            MethodSourceFile(MethodPaths.journal + "Patterns/FoundPattern.swift", lines: 24...41, symbol: "PatternStrength.classify",
                             anchor: "if abs(adjusted) >= policy.strongEffectMultiple * threshold, let p, p < policy.strongPValue {"),
            MethodSourceFile(MethodPaths.journal + "Habits/HabitInsightEngine.swift", lines: 273...317, symbol: "HabitInsightEngine.withClassification",
                             anchor: "clear = mature && enoughAdjustedRows && practical && (adjustedPValue ?? 1) < 0.05"),
            MethodSourceFile(MethodPaths.analytics + "Association/BinaryExposureAnalyzer.swift", lines: 98...173,
                             symbol: "BinaryExposureAnalyzer.analyze", anchor: "return min(1, 2 * min(atOrBelowZero, atOrAboveZero))")
        ],
        testSuites: [
            MethodTestSuite("PatternDiscoveryTests", in: MethodPaths.journalTests + "PatternDiscoveryTests.swift"),
            MethodTestSuite("PatternTestBaselineTests", in: MethodPaths.journalTests + "PatternTestBaselineTests.swift"),
            MethodTestSuite("BinaryExposureAnalyzerTests", in: MethodPaths.analyticsTests + "BinaryExposureAnalyzerTests.swift"),
            MethodTestSuite("BinaryExposureReferenceTests", in: MethodPaths.analyticsTests + "BinaryExposureReferenceTests.swift")
        ],
        limits: [
            "A pattern says your numbers differed on those days. It does not say the habit caused it.",
            "Habits that always happen together cannot be told apart, and Loopr does not list them.",
            "With many habits and outcomes, some differences turn up by chance. The Holm adjustment lowers that risk but does not remove it."
        ])

    static let labUnitConversion = MethodEntry(
        id: .labUnitConversion, group: .labs, title: "Lab unit conversion",
        version: nil,
        summary: "How Loopr converts a lab value from the unit on your report to the unit a calculation needs.",
        rule: [
            "Each marker has one canonical unit. A value goes from the report's unit to the canonical unit and on to the target, with a cited factor at each step. Creatinine in mg/dL times 88.4 gives µmol/L, for example.",
            "When no cited factor exists, or the two units measure different things, Loopr refuses and says why. It never guesses a unit that is not printed.",
            "Full precision is kept. Rounding happens only on screen."
        ],
        formula: MethodFormula([
            LooprFormulaLine([fv("value"), fo("="), fv("canonical value"), fo("·"), fv("numerator"), fo("/"), fv("denominator"), fo("+"),
                              fv("offset")])
        ], caption: "The offset is zero for every marker except HbA1c, where the two units are on different scales."),
        inputs: [MethodInput("Lab value and its printed unit", from: .labReport, .typed)],
        references: [
            MethodReference(.data, authors: "Labcorp", year: nil, title: "SI unit conversion table", venue: "labcorp.com",
                            link: "https://www.labcorp.com/resource/si-unit-conversion-table", use: "Conversion factors."),
            MethodReference(.data, authors: "Mayo Clinic Laboratories", year: nil, title: "SI unit conversion", venue: "mayocliniclabs.com",
                            link: "https://www.mayocliniclabs.com/order-tests/si-unit-conversion.html", use: "Conversion factors."),
            MethodReference(.data, authors: "Hoelzel W et al.", year: 2004, title: "IFCC reference system for measurement of hemoglobin A1c in human blood and the national standardization schemes in the United States, Japan, and Sweden: a method-comparison study",
                            venue: "Clinical Chemistry 50(1):166-174", use: "The HbA1c conversion between percent and mmol/mol.")
        ],
        sources: [
            MethodSourceFile("LooprPackages/Sources/AnalyticsKit/Labs/LabUnitConverter.swift", lines: 130...167, symbol: "LabUnitConverter.path",
                             anchor: "if from == to { return Route(steps: [], citations: []) }"),
            MethodSourceFile("LooprPackages/Sources/AnalyticsKit/Labs/LabUnitFactors.swift", lines: 18...26, symbol: "LabUnitRelation",
                             anchor: "func fromCanonical(_ value: Decimal) -> Decimal { value * numerator / denominator + offset }")
        ],
        testSuites: [
            MethodTestSuite("LabUnitConverterTests", in: MethodPaths.analyticsTests + "Labs/LabUnitConverterTests.swift"),
            MethodTestSuite("LabUnitTextTests", in: MethodPaths.analyticsTests + "Labs/LabUnitConverterTests.swift")
        ],
        limits: [
            "A conversion is exact arithmetic on a factor. It cannot fix a value the lab or the scan got wrong.",
            "Your lab's own reference range stays with the value. Loopr never judges a value against it."
        ],
        showsMedicalLine: true)
}
