import AnalyticsKit
import DesignSystem
import DomainKit
import Foundation
import TrainKit

extension MethodCatalog {
    static let activityEntries: [MethodEntry] = [strain, trainingLoad, heartRateRecovery, activeEnergy, steps, vo2MaxGauge,
                                                 weeklyDose, capacityTests]

    private static let activityFile = MethodPaths.analytics + "Activity/ActivityAnalytics.swift"
    private static let activityTests = MethodPaths.analyticsTests + "ActivityAnalyticsTests.swift"

    static let banister = MethodReference(
        authors: "Morton RH, Fitz-Clarke JR, Banister EW", year: 1990, title: "Modeling human performance in running",
        venue: "Journal of Applied Physiology", use: "The training impulse (TRIMP) that strain and training load are built on.")

    static let strain = MethodEntry(
        id: .strain, group: .activity, title: "Strain",
        version: MethodVersion(ActivityAlgorithm.version, symbol: "ActivityAlgorithm.version", file: activityFile),
        summary: "How hard your heart worked across the waking day, on a scale from 0 to 21.",
        rule: [
            "Each heart rate reading is placed between your resting and maximum heart rate, from 0 to 1.",
            "Each minute adds Banister's training impulse for that intensity, with k 0.64 and b 1.92, or 0.86 and 1.67 for the female profile. Your main sleep is left out.",
            "The score is ln(TRIMP + 1) / ln 1.5, capped at 21. It needs at least 60 minutes of wear. Your maximum heart rate comes from your zone settings: your own value, or 208 − 0.7 × age."
        ],
        formula: MethodFormula([
            LooprFormulaLine([fv("x"), fo("="), fo("("), fv("HR"), fo("−"), fv("HR rest"), fo(")"), fo("/"), fo("("), fv("HR max"),
                              fo("−"), fv("HR rest"), fo(")")]),
            LooprFormulaLine([fv("TRIMP"), fo("="), ff("Σ"), fv("minutes"), fo("·"), fv("x"), fo("·"), fv("k"), fo("·"), ff("exp"),
                              fo("("), fv("b"), fo("·"), fv("x"), fo(")")]),
            LooprFormulaLine([fv("Strain"), fo("="), ff("min"), fo("("), fn("21"), fo(","), ff("ln"), fo("("), fv("TRIMP"), fo("+"),
                              fn("1"), fo(")"), fo("/"), ff("ln"), fn("1.5"), fo(")")])
        ], caption: "x is held between 0 and 1. k and b are Banister's constants."),
        inputs: [MethodInput("Heart rate", unit: "bpm", from: .band), MethodInput("Resting heart rate", unit: "bpm", from: .band),
                 MethodInput("Maximum heart rate", unit: "bpm", from: .typed, .computed("Age")),
                 MethodInput("Sex for the reference constants", from: .typed)],
        references: [
            banister,
            MethodReference(authors: "Tanaka H, Monahan KD, Seals DR", year: 2001, title: "Age-predicted maximal heart rate revisited",
                            venue: "Journal of the American College of Cardiology 37(1):153-156",
                            use: "The 208 − 0.7 × age estimate used when you have not set your own maximum.")
        ],
        sources: [
            MethodSourceFile(activityFile, lines: 614...641, symbol: "ActivityAnalytics.strain",
                             anchor: "public static func strain(hr: [Double], timestamps: [TimeInterval], restingHR: Double?, maxHR: Double?, source: HRMaxSource, method: String = \"edwards\", sex: ActivitySex = .male) -> AnalyticsMetric<StrainValue> {"),
            MethodSourceFile(activityFile, lines: 604...607, symbol: "ActivityAnalytics.strainScore",
                             anchor: "public static func strainScore(_ trimp: Double) -> Double {")
        ],
        testSuites: [
            MethodTestSuite("ActivityAnalyticsTests", in: activityTests),
            MethodTestSuite("StrainAbstentionTests", in: activityTests),
            MethodTestSuite("StrainParityTests", in: activityTests),
            MethodTestSuite("StrainIdempotenceTests", in: activityTests)
        ],
        limits: [
            "It counts heart rate only. Lifting heavy in short sets moves heart rate less than the effort feels.",
            "An age-based maximum heart rate can be well off for one person, and that shifts every score. Set your own maximum in zone settings if you know it.",
            "It is not WHOOP's strain, and the two do not compare."
        ],
        metricKeys: ["strain"])

    static let trainingLoad = MethodEntry(
        id: .trainingLoad, group: .activity, title: "Training load", methodName: "Fitness, fatigue and form",
        version: MethodVersion(TrainingLoad.algorithmVersion, symbol: "TrainingLoad.algorithmVersion",
                               file: "LooprPackages/Sources/DomainKit/TrainingLoad.swift"),
        summary: "Your daily strain averaged over 42 days, called fitness, and over 7 days, called fatigue. Form is fitness minus fatigue.",
        rule: [
            "Loopr reads your stored daily strain. A missing day ends the run, and a recorded 0 counts as rest.",
            "The first 7 days set the starting value. Each day after, fitness moves 1 − e^(−1/42) of the way to that day's strain, and fatigue 1 − e^(−1/7).",
            "It needs 14 days in a row and counts as established after 42. It never feeds the recovery score."
        ],
        formula: MethodFormula([
            LooprFormulaLine([fv("fitness"), fo("="), fv("fitness"), fo("+"), fv("α42"), fo("·"), fo("("), fv("strain"), fo("−"),
                              fv("fitness"), fo(")")]),
            LooprFormulaLine([fv("α42"), fo("="), fn("1"), fo("−"), ff("exp"), fo("("), fo("−"), fn("1"), fo("/"), fn("42"), fo(")")]),
            LooprFormulaLine([fv("form"), fo("="), fv("fitness"), fo("−"), fv("fatigue")])
        ], caption: "Fatigue follows the same rule with 7 days in place of 42."),
        inputs: [MethodInput("Daily strain", unit: "0 to 21", from: .computed("Strain"))],
        references: [
            MethodReference(.implementation, authors: "OpenStrap", year: nil, title: "clinical/load_trimp.dart",
                            venue: "OpenStrap analytics, MIT licence", link: openStrapAnalytics,
                            use: "Loopr follows its Banister model, with missing days ending the run instead of counting as zero."),
            banister
        ],
        sources: [
            MethodSourceFile("LooprPackages/Sources/DomainKit/TrainingLoad.swift", lines: 35...45, symbol: "TrainingLoad.compute",
                             anchor: "public static func compute(dailyStrain: [Double?]) -> TrainingLoad? {")
        ],
        testSuites: [MethodTestSuite("BodyTrainingLoadTests", in: "LooprPackages/Tests/BodyKitTests/BodyInsightsTests.swift")],
        limits: [
            "It describes recent training. It does not predict performance or injury.",
            "A week without the band starts it again.",
            "Strain counts heart rate only, so load does too."
        ])

    static let heartRateRecovery = MethodEntry(
        id: .heartRateRecovery, group: .activity, title: "Heart rate recovery",
        version: MethodVersion(TimedHeartRateRecovery.algorithmVersion, symbol: "TimedHeartRateRecovery.algorithmVersion",
                               file: MethodPaths.analytics + "Workout/TimedHeartRateRecovery.swift"),
        summary: "How many beats per minute your heart rate drops in the first and second minute after a workout ends.",
        rule: [
            "A workout qualifies when its last 5 minutes hold at least 2 minutes in a row at 70% of your maximum heart rate or more.",
            "Peak is the highest reading in the last 30 seconds. The value 60 and 120 seconds after the end is the median within 3 seconds of that point. A gap of more than 30 seconds leaves the value empty.",
            "The drop is peak minus that value. Loopr puts no label on it."
        ],
        formula: MethodFormula([
            LooprFormulaLine([fv("drop"), fo("="), fv("peak"), fo("−"), ff("median"), fo("("), fv("HR at end + 60 s"), fo(")")])
        ], caption: "The second-minute drop uses the reading at 120 seconds."),
        inputs: [MethodInput("Heart rate around the workout's end", unit: "bpm", from: .band),
                 MethodInput("Maximum heart rate", unit: "bpm", from: .typed, .computed("Age"))],
        references: [
            MethodReference(.implementation, authors: "OpenStrap", year: nil, title: "workout/hr_recovery.dart",
                            venue: "OpenStrap analytics, MIT licence", link: openStrapAnalytics,
                            use: "Loopr measures the same drop on clock time instead of sample positions.")
        ],
        sources: [
            MethodSourceFile(MethodPaths.analytics + "Workout/TimedHeartRateRecovery.swift", lines: 20...65,
                             symbol: "WorkoutAnalytics.timedHeartRateRecovery",
                             anchor: "public static func timedHeartRateRecovery(samples: [WorkoutHRPoint], start: TimeInterval,")
        ],
        testSuites: [
            MethodTestSuite("SIBodyAnalyticsTests", in: MethodPaths.analyticsTests + "SIBodyAnalyticsTests.swift"),
            MethodTestSuite("HeartRateRecoveryReaderTests", in: MethodPaths.trainTests + "HeartRateRecoveryReaderTests.swift")
        ],
        limits: [
            "Keep the band on and stay still after you finish. Walking on, or stopping before the end, changes it.",
            "How hard the last minutes were sets the peak, and so the drop.",
            "Compare workouts of the same kind."
        ])

    static let activeEnergy = MethodEntry(
        id: .activeEnergy, group: .activity, title: "Active energy",
        version: MethodVersion(WorkoutAlgorithm.version, symbol: "WorkoutAlgorithm.version",
                               file: MethodPaths.analytics + "Workout/WorkoutAnalytics.swift"),
        summary: "Calories your heart rate says you burned above resting across the waking day.",
        rule: [
            "Resting burn comes from the Mifflin-St Jeor equation with your weight, height, age and sex.",
            "A minute counts as active when heart rate is above a flex point: resting heart rate plus 30% of the way to your maximum. Each active minute adds the Keytel equation's calories for that heart rate, minus the resting share of the minute.",
            "Minutes with the band off add nothing."
        ],
        inputs: [MethodInput("Heart rate, per minute", unit: "bpm", from: .band), MethodInput("Resting heart rate", unit: "bpm", from: .band),
                 MethodInput("Weight, height, age and sex", from: .typed)],
        references: [
            MethodReference(authors: "Keytel LR et al.", year: 2005,
                            title: "Prediction of energy expenditure from heart rate monitoring during submaximal exercise",
                            venue: "Journal of Sports Sciences 23(3):289-297", use: "The heart rate equation for active minutes."),
            MethodReference(authors: "Mifflin MD, St Jeor ST et al.", year: 1990,
                            title: "A new predictive equation for resting energy expenditure in healthy individuals",
                            venue: "American Journal of Clinical Nutrition 51(2):241-247", use: "Your resting burn.")
        ],
        sources: [
            MethodSourceFile(MethodPaths.analytics + "Workout/WorkoutAnalytics.swift", lines: 291...320, symbol: "WorkoutAnalytics.dailyEnergy",
                             anchor: "public static func dailyEnergy(")
        ],
        testSuites: [
            MethodTestSuite("WorkoutParityTests", in: MethodPaths.analyticsTests + "WorkoutAnalyticsTests.swift"),
            MethodTestSuite("PartialDayMetricTests", in: MethodPaths.analyticsTests + "PartialDayMetricTests.swift")
        ],
        limits: [
            "Keytel's equation was built from exercise. Outside exercise it is a rough guide.",
            "Heat and stress raise heart rate without burning more.",
            "Your typed weight and age set the resting part, so an old weight skews it."
        ],
        metricKeys: ["active_energy"], unit: "kcal")

    static let steps = MethodEntry(
        id: .steps, group: .activity, title: "Steps",
        version: MethodVersion(ActivityAlgorithm.version, symbol: "ActivityAlgorithm.version", file: activityFile),
        summary: "An estimate of your steps from minutes that look like walking. The band does not count steps itself.",
        rule: [
            "A minute looks like walking when wrist movement is above your own floor but under three times it, and heart rate is at least 8 bpm above resting. The floor is the median of at least 5 days of your 90th-percentile movement.",
            "Walking minutes count in bouts of 3 minutes or more. Each one counts 115 steps, the middle of 100 to 130, or the measured cadence within 10%."
        ],
        inputs: [MethodInput("Wrist movement", unit: "g", from: .band), MethodInput("Heart rate", unit: "bpm", from: .band),
                 MethodInput("Resting heart rate", unit: "bpm", from: .band)],
        sources: [
            MethodSourceFile(activityFile, lines: 754...793, symbol: "ActivityAnalytics.dailyStepEstimate",
                             anchor: "public static func dailyStepEstimate(")
        ],
        testSuites: [
            MethodTestSuite("ActivityAnalyticsTests", in: activityTests),
            MethodTestSuite("ActivityAndWellnessFixTests", in: MethodPaths.analyticsTests + "ActivityAndWellnessFixTests.swift")
        ],
        limits: [
            "Running and hard minutes fall outside the walking band and are missed.",
            "Pushing a pram or a trolley keeps the wrist still, so those steps are missed too.",
            "Step counts from a phone or watch in Apple Health are a separate number."
        ],
        metricKeys: ["steps"])

    static let vo2MaxGauge = MethodEntry(
        id: .vo2MaxGauge, group: .activity, title: "VO₂max", methodName: "FRIEND percentiles",
        version: nil,
        summary: "Where your VO₂max sits among people of your age and reference group in the FRIEND treadmill study.",
        rule: [
            "The value is the same 42-day median of Apple Health samples that Cardio age uses: at least 3 samples on 3 days, spanning 14 days.",
            "Loopr reads the FRIEND 10th, 25th, 50th and 75th percentiles for your decade of age and reference group. Your value falls in one of five bands: bottom tenth, bottom quarter, lower half, top half or top quarter. A value on a boundary goes to the band above.",
            "Last year is the same median a year earlier."
        ],
        inputs: [MethodInput("VO₂max", unit: "mL/kg/min", from: .appleHealth), MethodInput("Age", unit: "years", from: .typed),
                 MethodInput("Reference group", from: .typed)],
        references: [friend],
        sources: [
            MethodSourceFile(MethodPaths.train + "VO2MaxGauge.swift", lines: 107...125, symbol: "VO2MaxGauge.make",
                             anchor: "guard let row = table.rows.first(where: { $0.group == group && ($0.ageLower...$0.ageUpper).contains(age) }) else {"),
            MethodSourceFile(MethodPaths.train + "VO2MaxGauge.swift", lines: 136...144, symbol: "VO2MaxGauge.bands",
                             anchor: "VO2MaxBand(id: .p50ToP75, label: \"top half\", lowerBound: row.p50, upperBound: row.p75),"),
            MethodSourceFile(MethodPaths.analytics + "Vitals/CardioFitness.swift", lines: 90...103, symbol: "CardioFitnessLevelTable.friend2015",
                             anchor: "public static let friend2015")
        ],
        testSuites: [
            MethodTestSuite("VO2MaxGaugeTests", in: MethodPaths.trainTests + "VO2MaxGaugeTests.swift"),
            MethodTestSuite("CardioFitnessTests", in: MethodPaths.analyticsTests + "VitalsAnalyticsTests.swift")
        ],
        limits: [
            VO2MaxGauge.consumerEstimateCaveat,
            "FRIEND has no reference outside ages 20 to 79.",
            "A band says where you sit in one US treadmill study, not how healthy you are."
        ],
        metricKeys: ["vo2_max"], unit: "mL/kg/min")

    static let weeklyDose = MethodEntry(
        id: .weeklyDose, group: .activity, title: "Weekly dose",
        version: nil,
        summary: "This week's zone 2 minutes, minutes in zones 4 and 5, strength sessions and mobility sessions, against your protocol's targets.",
        rule: [
            "Zone minutes come from the band in any activity, not only workouts. Zone 2 is the second of five heart rate zones. Hard minutes are zones 4 and 5.",
            "Strength and mobility count sessions: workouts by their activity type, and sessions you completed in Fitness. Each session counts once.",
            "Targets come from your protocol's rules. A day without band data has no minutes, which is not the same as zero."
        ],
        inputs: [MethodInput("Minutes in each heart rate zone", unit: "min", from: .band),
                 MethodInput("Workouts and Fitness sessions", from: .appleHealth, .computed("Fitness")),
                 MethodInput("Weekly targets", from: .protocolRules)],
        references: [
            MethodReference(.background, authors: "Bull FC et al.", year: 2020,
                            title: "World Health Organization 2020 guidelines on physical activity and sedentary behaviour",
                            venue: "British Journal of Sports Medicine 54:1451-1462",
                            use: "The weekly minutes in the Fitness for the long run template."),
            MethodReference(.background, authors: "Garber CE et al.", year: 2011,
                            title: "Quantity and quality of exercise for developing and maintaining cardiorespiratory, musculoskeletal, and neuromotor fitness in apparently healthy adults",
                            venue: "Medicine and Science in Sports and Exercise 43:1334-1359",
                            use: "The strength and mobility sessions in the same template.")
        ],
        sources: [
            MethodSourceFile(MethodPaths.train + "WeeklyDose.swift", lines: 211...236, symbol: "WeeklyDose.make",
                             anchor: "let zone2 = measured.isEmpty ? nil : measured.reduce(0) { $0 + $1.zone2 }"),
            MethodSourceFile(MethodPaths.train + "WeeklyDose.swift", lines: 9...22, symbol: "BandZoneMinutes",
                             anchor: "public var hard: Double { zones[3] + zones[4] }")
        ],
        testSuites: [MethodTestSuite("WeeklyDoseTests", in: MethodPaths.trainTests + "WeeklyDoseTests.swift")],
        limits: [
            "Zones come from your maximum heart rate. An age-based maximum shifts every zone.",
            "When the band was off for part of the week, the minutes are a floor.",
            "Mobility counts only workouts with a mobility type, such as yoga or stretching."
        ])

    static let capacityTests = MethodEntry(
        id: .capacityTests, group: .activity, title: "Capacity tests",
        version: nil,
        summary: "Grip strength, dead hang, sit to stand and one-leg balance with eyes closed, as you measured them.",
        rule: [
            "Grip is typed in from a dynamometer in kilograms, per hand. Dead hang and one-leg balance are timed on this iPhone, balance per leg. Sit to stand is scored from 0 to 10 in half points.",
            "The headline is the best result on your most recent test day.",
            "Loopr keeps the values as you entered them and does not grade them against norms. Heart rate recovery after workouts has its own page."
        ],
        inputs: [MethodInput("Grip", unit: "kg", from: .typed), MethodInput("Dead hang", unit: "s", from: .phoneTimer),
                 MethodInput("Sit to stand", unit: "points", from: .typed), MethodInput("One-leg balance", unit: "s", from: .phoneTimer)],
        references: [
            MethodReference(authors: "Brito LBB et al.", year: 2014,
                            title: "Ability to sit and rise from the floor as a predictor of all-cause mortality",
                            venue: "European Journal of Preventive Cardiology",
                            use: "The sitting-rising test and its 0 to 10 score."),
            MethodReference(.background, authors: "Leong DP et al.", year: 2015,
                            title: "Prognostic value of grip strength: findings from the Prospective Urban Rural Epidemiology (PURE) study",
                            venue: "The Lancet 386:266-273", link: "https://doi.org/10.1016/S0140-6736(14)62000-6",
                            use: "Why grip is worth tracking over time."),
            MethodReference(.background, authors: "Araujo CG et al.", year: 2022,
                            title: "Successful 10-second one-legged stance performance predicts survival in middle-aged and older individuals",
                            venue: "British Journal of Sports Medicine 56:975-980",
                            use: "Why one-leg balance is worth tracking over time.")
        ],
        sources: [
            MethodSourceFile(MethodPaths.train + "CapacityModels.swift", lines: 54...72, symbol: "CapacityTestKind.validate",
                             anchor: "if let step, (value / step).rounded() * step != value { throw CapacityError.notInSteps(self) }"),
            MethodSourceFile(MethodPaths.train + "CapacityModels.swift", lines: 201...204, symbol: "CapacityHistory.headline",
                             anchor: "return results.filter { $0.localDayKey == latest.localDayKey }.map(\\.value).max()")
        ],
        testSuites: [
            MethodTestSuite("CapacityModelTests", in: MethodPaths.trainTests + "CapacityModelTests.swift"),
            MethodTestSuite("CapacityStoreTests", in: MethodPaths.trainTests + "CapacityStoreTests.swift")
        ],
        limits: [
            "A grip number depends on the dynamometer and its handle setting. Compare like with like.",
            "Balance and hang times change with shoes, floor and how you count the start.",
            "These are your own records. Loopr does not say what a good result is."
        ])
}
