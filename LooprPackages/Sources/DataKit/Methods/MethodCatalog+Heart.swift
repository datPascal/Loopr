import AnalyticsKit
import DesignSystem
import Foundation

extension MethodCatalog {
    static let heartEntries: [MethodEntry] = [recovery, hrv, restingHeartRate, maxHeartRate, respiration, skinTemperature,
                                              oxygen, stress, hourlyStress, overnightCheck]

    private static let wellness = MethodPaths.analytics + "Wellness/WellnessAnalytics.swift"
    private static let wellnessTests = MethodPaths.analyticsTests + "WellnessAnalyticsTests.swift"
    private static let core = MethodPaths.analytics + "Core/AnalyticsCore.swift"
    private static let ana02Tests = MethodPaths.analyticsTests + "ANA02AnalyticsTests.swift"
    private static let vitalsTests = MethodPaths.analyticsTests + "VitalsAnalyticsTests.swift"

    static let openStrapAnalytics = "https://github.com/OpenStrap/analytics"

    static let recovery = MethodEntry(
        id: .recovery, group: .heart, title: "Recovery",
        version: MethodVersion(WellnessAlgorithm.readinessVersion, symbol: "WellnessAlgorithm.readinessVersion", file: wellness),
        summary: "A score from 0 to 100 for how last night's heart rate variability, resting heart rate and breathing rate compare with your own recent nights. 50 is a usual morning for you.",
        rule: [
            "Each signal is compared with the median of up to 28 earlier nights with a complete main sleep. The distance is divided by the largest of three spreads: 1.4826 times the median absolute deviation, the standard deviation, or a small floor. With fewer than 14 earlier nights the distance is shrunk, so a short history cannot swing the score.",
            "Heart rate variability counts 0.40, resting heart rate 0.30 and breathing rate 0.20. Higher variability, a lower resting heart rate and slower breathing count as more rested. A logistic curve turns the weighted mean into 0 to 100.",
            "A score needs at least two of the three signals, each with 3 earlier nights. Loopr holds the score back when the combined distance is past 5, because the recent nights are then too alike to compare with."
        ],
        formula: MethodFormula([
            LooprFormulaLine([fv("z"), fo("="), fo("("), fv("tonight"), fo("−"), ff("median"), fo(")"), fo("/"), fv("spread")]),
            LooprFormulaLine([fv("Z"), fo("="), fo("("), fn("0.40"), fo("·"), fv("z HRV"), fo("+"), fn("0.30"), fo("·"),
                              fv("z RHR"), fo("+"), fn("0.20"), fo("·"), fv("z RR"), fo(")"), fo("/"), ff("Σ"), fv("weights")]),
            LooprFormulaLine([fv("Recovery"), fo("="), fn("100"), fo("/"), fo("("), fn("1"), fo("+"), ff("exp"), fo("("),
                              fo("−"), fv("Z"), fo(")"), fo(")")])
        ], caption: "Each z is signed so that positive means more rested. Resting heart rate and breathing rate count the other way round. HRV is compared on a log scale."),
        inputs: [
            MethodInput("Heart rate variability (RMSSD)", unit: "ms", from: .band),
            MethodInput("Resting heart rate", unit: "bpm", from: .band),
            MethodInput("Breathing rate", unit: "breaths a minute", from: .band),
            MethodInput("Earlier nights", unit: "up to 28", from: .computed("Your history"))
        ],
        references: [
            MethodReference(.implementation, authors: "OpenStrap", year: nil, title: "readiness_composite.dart",
                            venue: "OpenStrap analytics at commit 27b0ba486234, MIT licence", link: openStrapAnalytics,
                            use: "Loopr follows its readiness contract, written again in Swift.")
        ],
        sources: [
            MethodSourceFile(wellness, lines: 287...340, symbol: "WellnessAnalytics.readinessComposite",
                             anchor: "public static func readinessComposite("),
            MethodSourceFile(wellness, lines: 617...630, symbol: "WellnessAnalytics.readinessZ",
                             anchor: "static func readinessZ(_ input: ReadinessInput) -> Double? {"),
            MethodSourceFile(MethodPaths.analytics + "Wellness/RecoveryDecomposition.swift", lines: 121...189,
                             symbol: "WellnessAnalytics.recoveryDecomposition",
                             anchor: "public static func recoveryDecomposition(_ readings: [RecoverySignalReading],")
        ],
        testSuites: [
            MethodTestSuite("RecoveryDecompositionTests", in: MethodPaths.analyticsTests + "RecoveryDecompositionTests.swift"),
            MethodTestSuite("RecoveryHonestyTests", in: MethodPaths.analyticsTests + "RecoveryHonestyTests.swift"),
            MethodTestSuite("WellnessAnalyticsTests", in: wellnessTests),
            MethodTestSuite("ReadinessAbstentionTests", in: wellnessTests),
            MethodTestSuite("ReadinessIdempotenceTests", in: wellnessTests),
            MethodTestSuite("ReadinessParityTests", in: wellnessTests)
        ],
        limits: [
            "It compares you with yourself. A 70 for one person and a 70 for another describe different nights.",
            "No peer-reviewed study has validated this score, or any other consumer recovery score.",
            "Alcohol, illness, a late meal or a hot room move the same signals, and the score cannot tell them apart.",
            "A loose band or a short night gives fewer clean beats and a noisier score."
        ],
        showsMedicalLine: true, metricKeys: ["recovery"])

    static let hrv = MethodEntry(
        id: .hrv, group: .heart, title: "Heart rate variability", methodName: "RMSSD and SDNN",
        version: MethodVersion(AnalyticsAlgorithmVersion.hrv, symbol: "AnalyticsAlgorithmVersion.hrv", file: core),
        summary: "How much the time between heartbeats changes from beat to beat during your main sleep, in milliseconds.",
        rule: [
            "Loopr keeps beat-to-beat intervals between 300 and 2,000 ms and corrects or drops beats that do not fit their neighbours. A night needs at least 30 clean beats, and at least half of all beats clean.",
            "RMSSD: the main sleep is cut into 5-minute blocks. For each block Loopr takes the square root of the mean squared difference between consecutive beats. The value is the mean of the blocks.",
            "SDNN is the standard deviation of every clean interval in the night. pNN50 is the share of consecutive beats that differ by more than 50 ms."
        ],
        formula: MethodFormula([
            LooprFormulaLine([fv("RMSSD"), fo("="), ff("√"), fo("("), ff("mean"), fo("("), fv("RRᵢ₊₁"), fo("−"), fv("RRᵢ"), fo(")²"), fo(")")]),
            LooprFormulaLine([fv("SDNN"), fo("="), ff("sd"), fo("("), fv("RR"), fo(")")])
        ], caption: "RR is the time between two heartbeats in milliseconds. RMSSD is worked out per 5-minute block and then averaged."),
        inputs: [MethodInput("Beat-to-beat intervals", unit: "ms", from: .band), MethodInput("Main sleep window", from: .band)],
        references: [
            MethodReference(authors: "Shaffer F, Ginsberg JP", year: 2017, title: "An overview of heart rate variability metrics and norms",
                            venue: "Frontiers in Public Health 5:258", link: "https://doi.org/10.3389/fpubh.2017.00258",
                            use: "Defines RMSSD, SDNN and pNN50, and warns that norms depend on the length of the recording.")
        ],
        sources: [
            MethodSourceFile(MethodPaths.analytics + "Clinical/HRV.swift", lines: 99...136, symbol: "HRVTime.sleepSessionWindowedRMSSD",
                             anchor: "public static func sleepSessionWindowedRMSSD("),
            MethodSourceFile(MethodPaths.analytics + "Clinical/HRV.swift", lines: 14...57, symbol: "HRVTime.derive",
                             anchor: "public static func derive(_ intervals: [Double], beatTimesMilliseconds: [Double]? = nil) -> AnalyticsMetric<HRVTimeValue> {"),
            MethodSourceFile(MethodPaths.analytics + "Foundations/RRQuality.swift", lines: 71...105, symbol: "RRQuality.gated",
                             anchor: "public static func gated(")
        ],
        testSuites: [
            MethodTestSuite("HRVTimeParityTests", in: ana02Tests),
            MethodTestSuite("RRQualityParityTests", in: ana02Tests),
            MethodTestSuite("HRVAbstentionTests", in: ana02Tests),
            MethodTestSuite("HRVIdempotenceTests", in: ana02Tests),
            MethodTestSuite("BeatToBeatAnalyticsTests", in: vitalsTests)
        ],
        limits: [
            "The band times beats with a light sensor, not an ECG, and its packets carry whole-second timestamps. RMSSD and pNN50 are sensitive to small timing errors, so read the weekly trend.",
            "An overnight SDNN cannot be compared with a 5-minute or 24-hour SDNN from another device.",
            "Without a sleep window Loopr uses the whole day and marks the value as low confidence.",
            "Apple Health receives SDNN only. RMSSD stays on your iPhone."
        ],
        metricKeys: ["rmssd", "sdnn", "pnn50"], unit: "ms")

    static let restingHeartRate = MethodEntry(
        id: .restingHeartRate, group: .heart, title: "Resting heart rate",
        version: MethodVersion(AnalyticsAlgorithmVersion.nocturnal, symbol: "AnalyticsAlgorithmVersion.nocturnal", file: core),
        summary: "Your lowest steady heart rate during your main sleep, in beats per minute.",
        rule: [
            "Loopr slides a 30-minute window through the main sleep and takes the lowest average. A window counts only when at least 90% of its seconds have a reading, so a gap cannot create a low number. Readings below 25 or above 230 bpm are dropped first.",
            "Sleeping heart rate is the mean over the main sleep. The dip compares it with your waking mean. Each side needs at least 300 readings.",
            "Without a sleep window the same search runs over the whole day, and the value is marked low confidence."
        ],
        formula: MethodFormula([
            LooprFormulaLine([fv("RHR"), fo("="), ff("min"), fo("("), ff("mean"), fo("("), fv("HR over 30 min"), fo(")"), fo(")")]),
            LooprFormulaLine([fv("dip"), fo("="), fn("100"), fo("·"), fo("("), fv("day"), fo("−"), fv("night"), fo(")"), fo("/"), fv("day")])
        ], caption: "Day and night are mean heart rates while awake and during the main sleep."),
        inputs: [MethodInput("Heart rate, once a second", unit: "bpm", from: .band), MethodInput("Main sleep window", from: .band)],
        sources: [
            MethodSourceFile(MethodPaths.analytics + "Clinical/Nocturnal.swift", lines: 79...107, symbol: "NocturnalMetrics.restingHeartRate",
                             anchor: "public static func restingHeartRate(_ samples: [Double], windowSamples: Int = 1_800, minimumCoverage: Double = 0.9) -> AnalyticsMetric<NocturnalRHRValue> {"),
            MethodSourceFile(MethodPaths.analytics + "Clinical/Nocturnal.swift", lines: 109...124, symbol: "NocturnalMetrics.heartRateDip",
                             anchor: "let dip = (dayMean - nightMean) / dayMean * 100"),
            MethodSourceFile(MethodPaths.daily, lines: 1294...1332, symbol: "CanonicalDailyAnalytics, sleeping heart rate",
                             anchor: "let sleepingMean = sleepingHR.count >= NocturnalMetrics.minimumDipSamples ? AnalyticsMath.mean(sleepingHR) : nil")
        ],
        testSuites: [
            MethodTestSuite("NocturnalParityTests", in: ana02Tests),
            MethodTestSuite("HRVAbstentionTests", in: ana02Tests)
        ],
        limits: [
            "Illness, alcohol, a hot room and the second half of the menstrual cycle can all raise it. One night cannot tell them apart.",
            "A night with many gaps in the readings can have no value at all.",
            "The dip depends on your day as much as your night."
        ],
        showsMedicalLine: true, metricKeys: ["resting_heart_rate", "sleeping_heart_rate", "heart_rate_dip"], unit: "bpm")

    static let maxHeartRate = MethodEntry(
        id: .maxHeartRate, group: .heart, title: "Highest heart rate",
        version: MethodVersion(AnalyticsAlgorithmVersion.nocturnal, symbol: "AnalyticsAlgorithmVersion.nocturnal", file: core),
        summary: "The highest heart rate the band recorded during the day while it touched your skin.",
        rule: ["Loopr takes the maximum of the day's heart rate readings that came with skin contact. Nothing is smoothed or filled in."],
        inputs: [MethodInput("Heart rate, once a second", unit: "bpm", from: .band)],
        sources: [
            MethodSourceFile(MethodPaths.daily, lines: 1294...1332, symbol: "CanonicalDailyAnalytics, observed maximum",
                             anchor: "let observedMax = dayRecords.filter { $0.skinContact != 0 }.compactMap(hr).max()")
        ],
        testSuites: [MethodTestSuite("MetricHistoryTests", in: "Loopr/LooprTests/MetricHistoryTests.swift")],
        limits: [
            "It is the peak the band saw, not the highest rate your heart can reach.",
            "Efforts with the band off or loose are missed.",
            "A reading taken while the band slips during hard movement can be wrong."
        ],
        metricKeys: ["max_heart_rate"], unit: "bpm")

    static let respiration = MethodEntry(
        id: .respiration, group: .heart, title: "Breathing rate",
        version: MethodVersion(AnalyticsAlgorithmVersion.respiration, symbol: "AnalyticsAlgorithmVersion.respiration", file: core),
        summary: "Breaths per minute during your main sleep, read from the way your heart rate rises and falls with each breath.",
        rule: [
            "Your heart speeds up a little as you breathe in and slows as you breathe out. Loopr looks for that rhythm in the clean beat-to-beat intervals with a Lomb-Scargle periodogram between 0.15 and 0.4 Hz, which is 9 to 24 breaths a minute.",
            "It runs the search at three resolutions and needs at least two peaks within 3 breaths a minute of each other. It reports the peak closest to their middle. It needs at least 20 beats, with no more than 30% rejected."
        ],
        formula: MethodFormula([
            LooprFormulaLine([fv("rate"), fo("="), fn("60"), fo("·"), fv("f peak")])
        ], caption: "f peak is the strongest rhythm in the heartbeat intervals between 0.15 and 0.4 Hz."),
        inputs: [MethodInput("Beat-to-beat intervals", unit: "ms", from: .band), MethodInput("Main sleep window", from: .band)],
        sources: [
            MethodSourceFile(MethodPaths.analytics + "Respiration/Respiration.swift", lines: 34...70, symbol: "Respiration.rsaRate",
                             anchor: "public static func rsaRate(intervals: [Double], beatTimesMilliseconds times: [Double], artifactFraction: Double, agreementBPM: Double = 3, maximumArtifactFraction: Double = 0.3) -> AnalyticsMetric<RespiratoryEstimate> {")
        ],
        testSuites: [MethodTestSuite("RespirationParityTests", in: ana02Tests)],
        limits: [
            "Rates under 9 or over 24 breaths a minute are outside what the method can see.",
            "Irregular beats and movement blur the rhythm. Look at several nights, not one."
        ],
        metricKeys: ["respiratory_rate"], unit: "br/min")

    static let skinTemperature = MethodEntry(
        id: .skinTemperature, group: .heart, title: "Skin temperature change",
        version: MethodVersion(VitalsAlgorithmVersion.skinTemperature, symbol: "VitalsAlgorithmVersion.skinTemperature",
                               file: MethodPaths.analytics + "Vitals/SkinTemperature.swift"),
        summary: "How far tonight's settled wrist temperature sits from your usual, in degrees Celsius.",
        rule: [
            "Loopr waits for the sensor to settle: at least 10 minutes in, then five 1-minute medians that agree within 0.3 °C. A drop of more than 0.5 °C starts the wait again.",
            "The night's value is the median of the settled readings. It needs 300 readings, 80% of them settled, covering at least half the sleep.",
            "The change is tonight minus the median of up to 30 earlier nights. It shows after 4 earlier nights, and the usual range needs 14. A change of more than 2 °C is treated as the band sitting differently and is not stored."
        ],
        formula: MethodFormula([
            LooprFormulaLine([fv("change"), fo("="), fv("tonight"), fo("−"), ff("median"), fo("("), fv("earlier nights"), fo(")")])
        ], caption: "Tonight is the median of the settled readings during the main sleep."),
        inputs: [MethodInput("Wrist skin temperature", unit: "°C", from: .band), MethodInput("Heart rate", unit: "bpm", from: .band),
                 MethodInput("Main sleep window", from: .band)],
        sources: [
            MethodSourceFile(MethodPaths.analytics + "Vitals/SkinTemperature.swift", lines: 85...153, symbol: "SkinTemperatureAnalytics.nightly",
                             anchor: "public static func nightly(_ samples: [SkinTemperatureSample], sleepWindows: [VitalsWindow],"),
            MethodSourceFile(MethodPaths.analytics + "Vitals/SkinTemperature.swift", lines: 157...178, symbol: "SkinTemperatureAnalytics.deviation",
                             anchor: "public static func deviation(tonightCelsius: Double?, priorNightsOldestFirst: [Double?]) -> SkinTemperatureDeviation {")
        ],
        testSuites: [MethodTestSuite("SkinTemperatureAnalyticsTests", in: vitalsTests)],
        limits: [
            "Wrist skin temperature is not body temperature. A warm room or a heavy duvet moves it too.",
            "Only the change from your own nights carries meaning. The absolute number is approximate.",
            "It cannot say why the temperature changed."
        ],
        showsMedicalLine: true, metricKeys: ["skin_temperature_deviation"], unit: "°C")

    static let oxygen = MethodEntry(
        id: .oxygen, group: .heart, title: "Blood oxygen",
        version: nil,
        summary: "Blood oxygen values come from Apple Health or a WHOOP export. Loopr does not calculate one from the band.",
        rule: [
            "The band's light channels carry no calibrated oxygen reading, so Loopr shows only values another device measured (DEC-05.2).",
            "Loopr checks the band's red and infrared channels for signal quality and never turns them into a percentage."
        ],
        inputs: [MethodInput("Oxygen saturation", unit: "%", from: .appleHealth, .computed("WHOOP export"))],
        sources: [
            MethodSourceFile(MethodPaths.app + "CanonicalVitalsDerivation.swift", lines: 49...52, symbol: "CanonicalVitalsDerivation, oxygen",
                             anchor: "let oxygenVital = HeartOxygenVital(assessment: oxygenAssessment, nightlyRatio: nil, deviation: .noReading)")
        ],
        testSuites: [MethodTestSuite("OvernightOxygenAnalyticsTests", in: vitalsTests)],
        limits: [
            "The value is only as good as the device that measured it.",
            "Loopr does not interpret oxygen values."
        ],
        showsMedicalLine: true, metricKeys: ["oxygen_saturation"], unit: "%")

    static let stress = MethodEntry(
        id: .stress, group: .heart, title: "Stress", methodName: "Baevsky stress index",
        version: MethodVersion(WellnessAlgorithm.version, symbol: "WellnessAlgorithm.version", file: wellness),
        summary: "How tense your resting nervous system looks, from 0 to 100, read from the spread of your beat-to-beat intervals.",
        rule: [
            "Loopr takes clean beat-to-beat intervals between 300 and 2,000 ms, at least 30 of them, in windows of 256 beats.",
            "For each window it sorts the intervals into 50 ms bins. Mo is the most common interval, AMo the share of beats in that bin, and MxDMn the range, at least 20 ms. The index is AMo divided by 2 · Mo · MxDMn, and Loopr takes the median of the windows.",
            "The score maps an index of 20 to 600 onto 0 to 100 on a log scale."
        ],
        formula: MethodFormula([
            LooprFormulaLine([fv("SI"), fo("="), fv("AMo"), fo("/"), fo("("), fn("2"), fo("·"), fv("Mo"), fo("·"), fv("MxDMn"), fo(")")]),
            LooprFormulaLine([fv("Stress"), fo("="), fn("100"), fo("·"), fo("("), ff("ln"), fv("SI"), fo("−"), ff("ln"), fn("20"),
                              fo(")"), fo("/"), fo("("), ff("ln"), fn("600"), fo("−"), ff("ln"), fn("20"), fo(")")])
        ], caption: "The score is held between 0 and 100."),
        inputs: [MethodInput("Beat-to-beat intervals", unit: "ms", from: .band)],
        sources: [
            MethodSourceFile(wellness, lines: 368...396, symbol: "WellnessAnalytics.baevskyStressIndex",
                             anchor: "public static func baevskyStressIndex(_ nnMilliseconds: [Double], minRangeMilliseconds: Double = 20) -> AnalyticsMetric<StressIndex> {"),
            MethodSourceFile(wellness, lines: 281...285, symbol: "WellnessAnalytics.stressScore", anchor: "let lower = log(20.0), upper = log(600.0)")
        ],
        testSuites: [
            MethodTestSuite("StressParityTests", in: wellnessTests),
            MethodTestSuite("WellnessAnalyticsTests", in: wellnessTests),
            MethodTestSuite("ActivityAndWellnessFixTests", in: MethodPaths.analyticsTests + "ActivityAndWellnessFixTests.swift")
        ],
        limits: [
            "It reads your heart rhythm, not how you feel.",
            "There is no standard version of this score, so numbers from other devices do not compare.",
            "Anything that changes your heart rhythm moves it, including movement and recent exercise."
        ],
        showsMedicalLine: true, metricKeys: ["stress"])

    static let hourlyStress = MethodEntry(
        id: .hourlyStress, group: .heart, title: "Stress by hour",
        version: MethodVersion(HourlyStress.version, symbol: "HourlyStress.version", file: MethodPaths.analytics + "Wellness/HourlyStress.swift"),
        summary: "How each hour of your day compares with the same hour on your earlier days. 50 is usual.",
        rule: [
            "Loopr reads calm 5-minute windows: no sleep, no workout, wrist movement under 0.06 g and heart rate under 60% of your reserve. A window needs 120 seconds of heart rate and 120 clean beats.",
            "Each hour is compared with the same clock hour on at least 14 of the last 28 days. A higher heart rate and a lower log RMSSD both push the score up, with equal weight.",
            "65 or more reads as high and 35 or less as low. These are display lines, not medical cut-offs."
        ],
        formula: MethodFormula([
            LooprFormulaLine([fv("z"), fo("="), fo("("), fv("z HR"), fo("−"), fv("z ln RMSSD"), fo(")"), fo("/"), fn("2")]),
            LooprFormulaLine([fv("score"), fo("="), fn("50"), fo("+"), fn("15"), fo("·"), fv("z")])
        ], caption: "Each z compares the hour with the same hour on your earlier days."),
        inputs: [MethodInput("Heart rate", unit: "bpm", from: .band), MethodInput("Beat-to-beat intervals", unit: "ms", from: .band),
                 MethodInput("Wrist movement", unit: "g", from: .band)],
        sources: [
            MethodSourceFile(MethodPaths.analytics + "Wellness/HourlyStress.swift", lines: 128...156, symbol: "HourlyStress.resolve",
                             anchor: "let z = (deviation(hr, rates, floor: 5) - deviation(log(rmssd), logs, floor: 0.15)) / 2")
        ],
        testSuites: [
            MethodTestSuite("HourlyStressTests", in: MethodPaths.analyticsTests + "HourlyStressTests.swift"),
            MethodTestSuite("HourlyStressChartModelTests", in: "LooprPackages/Tests/StressKitTests/HourlyStressChartModelTests.swift")
        ],
        limits: [
            "It needs 14 days of history before the first hour shows.",
            "Hours with movement, sleep or a workout have no value.",
            "It compares you with yourself and cannot say what made an hour differ."
        ])

    static let overnightCheck = MethodEntry(
        id: .overnightCheck, group: .heart, title: "Overnight check",
        version: MethodVersion(OvernightVitalsCheck.algorithmVersion, symbol: "OvernightVitalsCheck.algorithmVersion",
                               file: MethodPaths.analytics + "Monitors/OvernightVitalsCheck.swift"),
        summary: "Whether two or more of last night's signals sat outside their usual range: resting heart rate, HRV, breathing rate and skin temperature.",
        rule: [
            "Each signal has a usual range from your last 30 nights. It needs at least 14 nights, tonight included.",
            "The range is the median plus or minus the largest of 2.5 robust spreads and a minimum width: 3 bpm, 1 breath a minute, 0.3 °C, and 15% of the median for HRV.",
            "A night is flagged when at least two signals are outside, and at least one of them is not skin temperature. Loopr tells you on the second flagged night in a row, once."
        ],
        formula: MethodFormula([
            LooprFormulaLine([fv("range"), fo("="), ff("median"), fo("±"), ff("max"), fo("("), fn("2.5"), fo("·"), fn("1.4826"),
                              fo("·"), ff("MAD"), fo(","), fv("minimum"), fo(")")])
        ], caption: "MAD is the median absolute deviation of your last 30 nights."),
        inputs: [MethodInput("Resting heart rate", unit: "bpm", from: .band), MethodInput("HRV (RMSSD)", unit: "ms", from: .band),
                 MethodInput("Breathing rate", unit: "breaths a minute", from: .band), MethodInput("Skin temperature", unit: "°C", from: .band)],
        sources: [
            MethodSourceFile(MethodPaths.analytics + "Monitors/OvernightVitalsCheck.swift", lines: 137...168, symbol: "OvernightVitalsCheck.assessment",
                             anchor: "public static func assessment(nights: [OvernightVitalsNight], calendar: Calendar,"),
            MethodSourceFile(MethodPaths.analytics + "Monitors/OvernightVitalsCheck.swift", lines: 126...135, symbol: "OvernightVitalsCheck.typicalRange",
                             anchor: "public static func typicalRange(metric: OvernightVitalMetric, values: [Double],")
        ],
        testSuites: [MethodTestSuite("OvernightVitalsCheckTests", in: MethodPaths.analyticsTests + "OvernightVitalsCheckTests.swift")],
        limits: [
            "It says your numbers differed from your usual. It cannot say why.",
            "Alcohol, a late workout, travel or a hot room can flag a night as well as illness can.",
            "With fewer than 14 nights it stays quiet."
        ],
        showsMedicalLine: true)
}
