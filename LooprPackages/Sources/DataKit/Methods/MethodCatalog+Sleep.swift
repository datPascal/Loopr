import AnalyticsKit
import DesignSystem
import Foundation

extension MethodCatalog {
    static let sleepEntries: [MethodEntry] = [sleepStages, sleepNeed, sleepRegularity]

    private static let sleepFile = MethodPaths.analytics + "Sleep/SleepAnalytics.swift"
    private static let sleepTests = MethodPaths.analyticsTests + "SleepAnalyticsTests.swift"
    private static let sleepVersion = MethodVersion(SleepAlgorithm.version, symbol: "SleepAlgorithm.version", file: sleepFile)

    static let sleepStages = MethodEntry(
        id: .sleepStages, group: .sleep, title: "Sleep time and stages",
        version: sleepVersion,
        summary: "How long you slept and how the night splits into light, deep and REM sleep, estimated from your heart rhythm and wrist movement.",
        rule: [
            "Loopr finds the main sleep from stillness: wrist movement under 0.01 g for most of a 15-minute window, confirmed by a lower heart rate. A main sleep lasts at least 3 hours. Anything shorter is a nap.",
            "The night is cut into 30-second epochs. Each epoch gets a REM score and a deep score from heart rate, beat-to-beat variability and movement, and counts as wake when heart rate jumps or the wrist moves a lot. Each stage then lasts at least 5 minutes, and deep runs under 3 minutes are dropped.",
            "Time asleep is light plus deep plus REM. Efficiency is time asleep divided by the time from settling to waking."
        ],
        formula: MethodFormula([
            LooprFormulaLine([fv("asleep"), fo("="), fv("light"), fo("+"), fv("deep"), fo("+"), fv("REM")]),
            LooprFormulaLine([fv("efficiency"), fo("="), fn("100"), fo("·"), fv("asleep"), fo("/"), fv("window")])
        ], caption: "The window runs from when you settled to when you woke."),
        inputs: [MethodInput("Wrist movement", unit: "g", from: .band), MethodInput("Heart rate", unit: "bpm", from: .band),
                 MethodInput("Beat-to-beat intervals", unit: "ms", from: .band)],
        references: [
            MethodReference(.implementation, authors: "OpenStrap", year: nil, title: "AdvancedSleepStager",
                            venue: "OpenStrap Edge, MIT licence", link: "https://github.com/OpenStrap/edge",
                            use: "Loopr's sleep window detection is ported from it.")
        ],
        sources: [
            MethodSourceFile(MethodPaths.analytics + "Sleep/SleepAdvancedDetector.swift", lines: 41...118,
                             symbol: "SleepAdvancedWindowDetector.detect", anchor: "public static func detect("),
            MethodSourceFile(MethodPaths.analytics + "Sleep/SleepCardioStaging.swift", lines: 75...166,
                             symbol: "SleepCardioStager.stage", anchor: "public static func stage("),
            MethodSourceFile(sleepFile, lines: 662...692, symbol: "SleepAnalytics.makeSegmentation",
                             anchor: "efficiencyPercent: labels.isEmpty ? nil : 100 * Double(tst) / Double(labels.count),")
        ],
        testSuites: [
            MethodTestSuite("SleepAnalyticsTests", in: sleepTests),
            MethodTestSuite("SleepStagingParityTests", in: sleepTests),
            MethodTestSuite("SleepAccountingParityTests", in: sleepTests),
            MethodTestSuite("HypnogramParityTests", in: sleepTests),
            MethodTestSuite("SleepDeepAccountingTests", in: MethodPaths.analyticsTests + "SleepDeepAccountingTests.swift"),
            MethodTestSuite("SleepPipelineFixTests", in: MethodPaths.analyticsTests + "SleepPipelineFixTests.swift")
        ],
        limits: [
            "This is an estimate from heart rhythm and movement. A sleep lab reads brain waves, and stages from the wrist agree with it only part of the time.",
            "Lying still while awake can count as sleep, and restless sleep can count as wake.",
            "Efficiency starts when you settle, not when you get into bed, so it reads higher than a lab's.",
            "A night found from heart rate alone is marked partial."
        ],
        metricKeys: ["sleep_duration", "sleep_efficiency", "deep_sleep", "rem_sleep"])

    static let sleepNeed = MethodEntry(
        id: .sleepNeed, group: .sleep, title: "Sleep performance and debt",
        version: sleepVersion,
        summary: "How much of your estimated sleep need you met last night, and how far your usual night falls short of that need.",
        rule: [
            "Sleep need is the 75th percentile of your main-sleep hours on Saturday and Sunday nights among the last 28 nights. Weekend nights stand in for nights without an alarm.",
            "Debt is that need minus the median of your recent nights. It needs at least 3 nights. When your usual night is longer than the need, there is no debt to show.",
            "Sleep performance is last night's time asleep divided by the need, times 100."
        ],
        formula: MethodFormula([
            LooprFormulaLine([fv("need"), fo("="), ff("p75"), fo("("), fv("weekend nights"), fo(")")]),
            LooprFormulaLine([fv("debt"), fo("="), fv("need"), fo("−"), ff("median"), fo("("), fv("recent nights"), fo(")")]),
            LooprFormulaLine([fv("performance"), fo("="), fn("100"), fo("·"), fv("asleep"), fo("/"), fv("need")])
        ], caption: "p75 is the 75th percentile: three in four weekend nights were this long or shorter."),
        inputs: [MethodInput("Main-sleep hours", unit: "h", from: .band), MethodInput("Day of the week", from: .computed("Calendar"))],
        sources: [
            MethodSourceFile(sleepFile, lines: 813...821, symbol: "SleepAnalytics.sleepDebt",
                             anchor: "guard !freeNightSleepHours.isEmpty, let optimal = AnalyticsMath.percentile(freeNightSleepHours, 75) else {"),
            MethodSourceFile(MethodPaths.app + "MetricHistory/BandMetricSeriesMapping.swift", lines: 82...88,
                             symbol: "BandMetricSeriesMapping, sleep performance",
                             anchor: "duration.flatMap { $0 >= 0 ? number($0 / need * 100) : nil }")
        ],
        testSuites: [MethodTestSuite("MetricHistoryTests", in: "Loopr/LooprTests/MetricHistoryTests.swift")],
        limits: [
            "If you set an alarm at the weekend or work shifts, weekend nights do not show your real need.",
            "The need changes as new nights arrive, so the percentage can move when your sleep did not.",
            "Debt is a typical nightly shortfall, not a running total of every missed minute."
        ],
        metricKeys: ["sleep_performance", "sleep_debt"])

    static let sleepRegularity = MethodEntry(
        id: .sleepRegularity, group: .sleep, title: "Sleep regularity", methodName: "Sleep Regularity Index",
        version: sleepVersion,
        summary: "How alike your sleep and wake times are from one day to the next, on a scale up to 100.",
        rule: [
            "Each day from noon to noon becomes 1,440 minutes, each marked asleep or awake from your main sleep.",
            "Loopr compares every minute with the same minute 24 hours later. The index is 200 times the share of matching pairs, minus 100. Identical days score 100.",
            "It walks back up to 29 days in a row that each have a main sleep and stops at the first gap. It needs at least 2 days. Naps are left out."
        ],
        formula: MethodFormula([
            LooprFormulaLine([fv("SRI"), fo("="), fn("200"), fo("·"), fv("matching pairs"), fo("/"), fv("pairs"), fo("−"), fn("100")])
        ], caption: "A pair is the same minute on two days in a row. It matches when you were asleep in both, or awake in both."),
        inputs: [MethodInput("Main sleep start and end", from: .band)],
        references: [
            MethodReference(authors: "Phillips AJK et al.", year: 2017,
                            title: "Irregular sleep/wake patterns are associated with poorer academic performance and delayed circadian and sleep/wake timing",
                            venue: "Scientific Reports 7:3216", link: "https://doi.org/10.1038/s41598-017-03171-4",
                            use: "Defines the Sleep Regularity Index that Loopr computes.")
        ],
        sources: [
            MethodSourceFile(sleepFile, lines: 801...811, symbol: "SleepAnalytics.sleepRegularityIndex",
                             anchor: "let score = 200 * Double(agreement) / Double(pairs) - 100"),
            MethodSourceFile(MethodPaths.app + "SleepRegularitySeries.swift", lines: 21...36, symbol: "SleepRegularitySeries.regularityMinutes",
                             anchor: "nonisolated static func regularityMinutes(_ nights: [RegularityNight], calendar: Calendar) -> [Bool] {")
        ],
        testSuites: [
            MethodTestSuite("SleepAnalyticsTests", in: sleepTests),
            MethodTestSuite("SleepParityTests", in: sleepTests),
            MethodTestSuite("SleepRegularitySeriesTests", in: "Loopr/LooprTests/SleepRegularitySeriesTests.swift")
        ],
        limits: [
            "A one-hour shift at bedtime costs as much as a one-hour shift at wake time.",
            "A night without the band breaks the run, so it shortens the window instead of counting as awake.",
            "It describes timing only. It says nothing about how long or how well you slept."
        ],
        metricKeys: ["sleep_consistency"])
}
