import Foundation

/// Everything a metric detail page says in words.
///
/// Rules for anyone editing this file:
/// - "How Loopr calculates it" must match the code. The references in the
///   comments point at the implementation; update both together.
/// - Facts and numbers come from primary sources (with DOIs) cited in
///   `sources`. Do not add a number without one.
/// - Wellness wording only. `MetricContentCatalogTests` rejects the banned
///   terms from the night-build brief and em dashes.
nonisolated struct MetricContent: Sendable {
    /// "What it is".
    let definition: [String]
    /// "How Loopr calculates it".
    let calculation: [String]
    /// "What moves it": things that tend to push the value up.
    let raises: [String]
    /// Things that tend to push the value down.
    let lowers: [String]
    /// "Good to know": 2 to 4 facts.
    let facts: [String]
    /// Short citations for the facts, shown in small type.
    let sources: [String]
    /// Where the numbers come from and where they go.
    let provenance: String
}

nonisolated enum MetricContentCatalog {
    static func content(for key: MetricKey) -> MetricContent {
        switch key {
        case .restingHeartRate: restingHeartRate
        case .rmssd: rmssd
        case .sdnn: sdnn
        case .pNN50: pNN50
        case .respiratoryRate: respiratoryRate
        case .sleepingHeartRate: sleepingHeartRate
        case .heartRateDip: heartRateDip
        case .oxygenSaturation: oxygenSaturation
        case .skinTemperatureDeviation: skinTemperatureDeviation
        case .recovery: recovery
        case .strain: strain
        case .stress: stress
        case .sleepDuration: sleepDuration
        case .sleepEfficiency: sleepEfficiency
        case .deepSleep: deepSleep
        case .remSleep: remSleep
        case .sleepConsistency: sleepConsistency
        case .vo2Max: vo2Max
        case .maxHeartRate: maxHeartRate
        case .activeEnergy: activeEnergy
        case .steps: steps
        }
    }

    // MARK: - Heart

    // CanonicalDailyAnalytics.swift:1132-1156, AnalyticsKit/Clinical/Nocturnal.swift:79-107
    static let restingHeartRate = MetricContent(
        definition: [
            "How many times your heart beats in a minute when your body is fully at rest. Loopr calculates it from readings taken while you sleep."
        ],
        calculation: [
            "Your band reports your heart rate once a second. Loopr lines those readings up across your main sleep and slides a 30-minute window through the night.",
            "Your resting heart rate is the lowest 30-minute average it finds. A window only counts if at least 90% of its seconds have a reading, so a gap or a loose band cannot create a low number. Missing seconds stay empty and are never filled in.",
            "Readings below 25 bpm or above 230 bpm are dropped first. If Loopr found no sleep that day, it runs the same search over the whole day and marks the result as low confidence."
        ],
        raises: [
            "Getting sick",
            "Alcohol in the evening",
            "The second half of the menstrual cycle",
            "Winter. In data from 92,457 Fitbit users, resting heart rate peaked in January and was lowest in July"
        ],
        lowers: [
            "Better aerobic fitness, built over weeks",
            "Sleeping about 7 to 7.5 hours, where resting heart rate was lowest in the same Fitbit data"
        ],
        facts: [
            "The American Heart Association puts most adults between 60 and 100 bpm. Endurance athletes can sit near 40.",
            "People differ a lot. Among 92,457 Fitbit users, 95% of men fell between 50 and 80 bpm and 95% of women between 53 and 82. Your own number is far steadier than that spread, which is why Loopr compares you with yourself.",
            "One morning can differ from your usual pattern. Look for a change that lasts several days."
        ],
        sources: [
            "American Heart Association",
            "Quer et al. 2020, PLOS ONE",
            "Buchheit 2014, Frontiers in Physiology"
        ],
        provenance: "Calculated on your iPhone from band readings during your main sleep. Complete, confident nights go to Apple Health as resting heart rate."
    )

    // AnalyticsKit/Clinical/HRV.swift:99-172, CanonicalDailyAnalytics.swift:1114-1131
    static let rmssd = MetricContent(
        definition: [
            "Heart rate variability, or HRV, is how much the gap between one heartbeat and the next changes from beat to beat.",
            "Loopr calculates it as RMSSD, short for root mean square of successive differences. Higher values usually mean the rest-and-digest side of your nervous system is more active."
        ],
        calculation: [
            "Loopr takes the beat-to-beat intervals your band reports during your main sleep and cuts the night into 5-minute blocks, starting when you fell asleep.",
            "It keeps intervals between 300 and 2,000 ms and drops any beat more than 20% away from the median of its neighbours. For each block it squares the difference between consecutive beats, averages those squares and takes the square root. The number you see is the average of all the blocks.",
            "The band times each beat with its optical sensor, not an ECG, and its packets carry whole-second timestamps. That makes RMSSD sensitive to small timing errors, so read the weekly trend rather than one night.",
            "Without a sleep window, Loopr uses the day's quiet stretches instead and marks the value as low confidence."
        ],
        raises: [
            "More daily activity, kept up over weeks",
            "Easy days after hard training",
            "Slow, deep breathing, although that changes the number more than your recovery"
        ],
        lowers: [
            "Stress",
            "Alcohol. The more you drink, the bigger the drop",
            "Hard training. It can take 24 to 48 hours or more to come back after intense sessions",
            "Getting sick",
            "Age"
        ],
        facts: [
            "RMSSD falls with age. In 5-minute ECG recordings of healthy adults it averaged about 40 ms at ages 25 to 34 and about 20 ms at 55 to 64. Those were short daytime tests, so they are rough context for an overnight value, not a target.",
            "Single nights jump around. Sports scientists follow the 7-day average of the logarithm of RMSSD and want at least 3 measured nights in a week before reading a direction.",
            "Men and women had similar values within each age group in the same study."
        ],
        sources: [
            "Shaffer and Ginsberg 2017, Frontiers in Public Health",
            "Voss et al. 2015, PLOS ONE",
            "Plews et al. 2012 and 2014",
            "Stanley et al. 2013, Sports Medicine",
            "Natarajan et al. 2020, Lancet Digital Health"
        ],
        provenance: "Calculated on your iPhone from band readings during your main sleep. Apple Health has no RMSSD type, so it stays on your phone."
    )

    // AnalyticsKit/Clinical/HRV.swift:14-57, AnalyticsKit/Foundations/RRQuality.swift:64-236
    static let sdnn = MetricContent(
        definition: [
            "The standard deviation of all your beat-to-beat intervals over a period. It captures total heart rate variability, fast changes and slow ones together."
        ],
        calculation: [
            "Loopr cleans the night's beat-to-beat intervals first. A beat is flagged if it is shorter than 300 ms, longer than 2,000 ms, or jumps too far from the beats around it. A single flagged beat is replaced with a smooth estimate. Two or more in a row are removed.",
            "SDNN is the standard deviation of every clean interval across your whole main sleep. Loopr shows a number only with at least 30 clean beats and when at least half of the night's beats pass cleaning.",
            "Because it covers the whole night, this is not the same as a 5-minute SDNN. Longer recordings give higher values."
        ],
        raises: [
            "More daily activity, kept up over weeks",
            "Easy days after hard training"
        ],
        lowers: [
            "Stress",
            "Alcohol",
            "Hard training in the last day or two",
            "Getting sick",
            "Age"
        ],
        facts: [
            "SDNN depends on how long the recording is. A 5-minute value, an overnight value and a 24-hour value cannot be compared with each other.",
            "Apple Health's heart rate variability is SDNN, not RMSSD. This is the number Loopr sends there.",
            "Published cut-offs such as \"under 50 ms\" come from 24-hour recordings. They do not apply to an overnight value.",
            "In 5-minute ECG recordings, SDNN averaged about 49 to 50 ms at ages 25 to 34 and 31 to 33 ms at 55 to 64."
        ],
        sources: [
            "Shaffer and Ginsberg 2017, Frontiers in Public Health",
            "Voss et al. 2015, PLOS ONE"
        ],
        provenance: "Calculated on your iPhone from band readings during your main sleep. Complete, confident nights go to Apple Health as heart rate variability (SDNN)."
    )

    // AnalyticsKit/Clinical/HRV.swift:14-57
    static let pNN50 = MetricContent(
        definition: [
            "The percentage of consecutive heartbeats whose intervals differ by more than 50 ms. Like RMSSD, it follows the fast, breath-by-breath changes driven by the rest-and-digest side of your nervous system."
        ],
        calculation: [
            "Loopr uses the same cleaned overnight intervals as SDNN.",
            "It compares every pair of consecutive beats, counts the pairs that differ by more than 50 ms and divides by the number of pairs. Pairs that span a gap in the recording are skipped.",
            "The band's beat timing comes from an optical sensor with whole-second timestamps, so a few milliseconds of error can push a pair over or under the 50 ms line. RMSSD is the steadier number to follow."
        ],
        raises: [
            "The same things that raise RMSSD: easy days, and more daily activity over weeks"
        ],
        lowers: [
            "A faster heart rate. At high heart rates pNN50 sits near zero",
            "Age",
            "Stress, alcohol, hard training and illness, as with RMSSD"
        ],
        facts: [
            "pNN50 drops steeply with age. In 5-minute ECG recordings it averaged about 20 to 23% at ages 25 to 34 and 4 to 5% at 55 to 64.",
            "It rises and falls closely with RMSSD, so the two usually tell the same story.",
            "Values near zero are common at older ages and at higher heart rates."
        ],
        sources: [
            "Voss et al. 2015, PLOS ONE",
            "Shaffer and Ginsberg 2017, Frontiers in Public Health"
        ],
        provenance: "Calculated on your iPhone from band readings during your main sleep. Apple Health has no pNN50 type, so it stays on your phone."
    )

    // AnalyticsKit/Respiration/Respiration.swift:34-70, CanonicalDailyAnalytics.swift:1109-1113
    static let respiratoryRate = MetricContent(
        definition: [
            "How many breaths you take per minute while you sleep. Loopr reads it from your heart rhythm, which speeds up a little as you breathe in and slows as you breathe out."
        ],
        calculation: [
            "Loopr takes the cleaned beat-to-beat intervals from your main sleep and looks for the regular rise and fall that breathing causes. It uses a frequency analysis called a Lomb-Scargle spectrum, limited to 9 to 24 breaths a minute.",
            "It runs the analysis at three resolutions and reports a rate only when at least two of them agree within 3 breaths a minute. The night needs at least 20 clean beats, with no more than 30% rejected.",
            "A rate below 9 or above 24 breaths a minute is outside what this method can see."
        ],
        raises: [
            "Getting sick",
            "The second half of the menstrual cycle"
        ],
        lowers: [
            "Little moves it down. It is one of the steadiest numbers you have, so a rise stands out more than a fall"
        ],
        facts: [
            "In healthy adults, 90% sleep with a rate between 11.8 and 19.2 breaths a minute. The average is 15.4.",
            "It barely changes from night to night. Over 14 days, young adults varied by only 2 to 9%.",
            "Loopr estimates breathing rate from beat timing. Look at several nights before reading a change into it."
        ],
        sources: [
            "Natarajan et al. 2021, npj Digital Medicine"
        ],
        provenance: "Estimated on your iPhone from band readings during your main sleep. Complete, confident nights go to Apple Health as respiratory rate."
    )

    // CanonicalDailyAnalytics averages valid main-sleep readings.
    static let sleepingHeartRate = MetricContent(
        definition: [
            "Your average heart rate across your main sleep. Resting heart rate uses only the lowest 30-minute stretch of the night."
        ],
        calculation: [
            "Loopr averages valid heart rate readings during your main sleep. It needs at least 300 valid seconds.",
            "If another source supplies this history, it appears here with its source named."
        ],
        raises: [
            "Alcohol in the evening",
            "Getting sick",
            "The second half of the menstrual cycle"
        ],
        lowers: [
            "Better aerobic fitness, built over weeks",
            "The same habits that lower your resting heart rate"
        ],
        facts: [
            "Your heart usually beats slowest in deep sleep and speeds up during REM sleep.",
            "Heart rates are personal. Among 92,457 Fitbit users, people's usual resting rates differed by up to 70 bpm."
        ],
        sources: [
            "Somers et al. 1993, New England Journal of Medicine",
            "Quer et al. 2020, PLOS ONE"
        ],
        provenance: "Derived from your main sleep. Needs at least 300 valid seconds."
    )

    // AnalyticsKit/Clinical/Nocturnal.swift owns the day/night ratio.
    static let heartRateDip = MetricContent(
        definition: [
            "How much your heart rate falls during sleep compared with the day. The dip depends on daytime activity as well as sleep."
        ],
        calculation: [
            "Loopr compares your main sleep with the waking part of the same day.",
            "The formula takes your daytime average heart rate, subtracts your night-time average and divides by the daytime average. Each average needs at least 300 valid seconds of readings."
        ],
        raises: [
            "Anything that lowers your heart rate at night, such as skipping alcohol in the evening",
            "A more active day, which lifts your daytime average"
        ],
        lowers: [
            "Alcohol or illness keeping your night-time heart rate up",
            "A mostly still day, which keeps your daytime average low"
        ],
        facts: [
            "Heart rate normally falls during non-REM sleep and rises again during REM.",
            "The dip depends on both halves of the day. A busy day and a calm night both make it bigger, so compare it with your own history rather than with other people."
        ],
        sources: [
            "Somers et al. 1993, New England Journal of Medicine"
        ],
        provenance: "Derived from your main sleep and waking heart rate. A usual range appears after 14 nights with both readings."
    )

    // StorageKit/LedgerSchema.swift:236-247 stores raw red/IR counts only; AnalyticsCore.swift:125-126.
    static let oxygenSaturation = MetricContent(
        definition: ["Blood oxygen is the share of oxygen-carrying haemoglobin in your blood, as a percentage."],
        calculation: ["This band doesn't report blood oxygen. Imported readings appear when available, with their source."],
        raises: [], lowers: [],
        facts: ["The band's light channels move together, so they cannot provide an oxygen reading."],
        sources: ["Loopr product decisions, DEC-05"],
        provenance: "Imported values only. No oxygen value is calculated from this band."
    )

    static let skinTemperatureDeviation = MetricContent(
        definition: ["The change in your wrist's skin temperature during sleep compared with your own recent nights. Alcohol, late meals, a hot room, hard training, travel, illness and your cycle can move it. It is different from body temperature."],
        calculation: [
            "Loopr takes the middle temperature from settled, worn seconds in your main sleep. Cold contact readings and warm-up after putting the band on are left out.",
            "Your change appears after 4 nights with a settled reading. After 14 nights, your usual range compares this night with the previous 30 calendar days. The wrist value is approximate."
        ],
        raises: ["A hot room or heavier bedding", "Alcohol, late meals, illness or cycle changes"],
        lowers: ["A cooler room or lighter bedding", "Changes in circulation or band fit"],
        facts: ["Your personal change matters more than the wrist value.", "Two or more overnight signals outside their usual ranges trigger a heads-up. One reading alone does not."],
        sources: ["Loopr product decisions, DEC-05", "Smarr et al. 2020, Scientific Reports"],
        provenance: "Derived from the band's overnight temperature. Relative to your own nights, with an approximate wrist value."
    )

    // MARK: - Scores

    // AnalyticsKit/Wellness/WellnessAnalytics.swift:28-38, 263, 286-338; CanonicalDailyAnalytics.swift:750-776, 968-1001
    static let recovery = MetricContent(
        definition: [
            "A daily score from 0 to 100 for how your heart looks this morning compared with your recent nights. 50 is a typical morning for you. Higher means your overnight numbers look more rested than usual."
        ],
        calculation: [
            "Loopr compares three overnight numbers with your own history: heart rate variability (RMSSD, on a log scale), resting heart rate and respiratory rate.",
            "For each one it measures how far last night sits from the median of up to 28 earlier nights with a complete main sleep. It scales that distance by a robust spread, 1.4826 times the median absolute deviation, so one odd night does not skew it.",
            "Heart rate variability, resting heart rate and respiratory rate are weighted 4 to 3 to 2. Higher variability, a lower resting heart rate and slower breathing count as more rested. If one input is missing, the others share its weight. A logistic curve turns the result into 0 to 100.",
            "You need at least 3 earlier nights before a score appears. If your recent nights are nearly identical, Loopr holds the score back rather than blow up tiny differences."
        ],
        raises: [
            "A full night of sleep after an easy day",
            "Rest days after hard training",
            "No alcohol in the evening"
        ],
        lowers: [
            "Alcohol",
            "Hard training in the last day or two",
            "Getting sick",
            "Stress"
        ],
        facts: [
            "The score is relative to you. A 70 for one person and a 70 for another describe different hearts.",
            "A recovery score combines several inputs. If one is missing, Loopr leaves the score unavailable.",
            "We found no peer-reviewed validation of any consumer recovery score, this one included. Read it as a summary of your own numbers, not a verdict."
        ],
        sources: [
            "Loopr recovery calculation"
        ],
        provenance: "Calculated on your phone from band data. It is not sent to Apple Health."
    )

    // AnalyticsKit/Activity/ActivityAnalytics.swift:585-622, 912-922; CanonicalDailyAnalytics.swift:1245-1253
    static let strain = MetricContent(
        definition: [
            "How much work your heart did while you were awake today, on a scale from 0 to 21. The scale is logarithmic, so each extra point takes more effort than the one before."
        ],
        calculation: [
            "Loopr takes your heart rate for the day and leaves out your main sleep.",
            "Each minute counts by how far your heart rate sits between your resting heart rate and your estimated maximum, which is 208 minus 0.7 times your age. Loopr adds the minutes up with Banister's training impulse formula, which gives hard minutes much more weight than easy ones. It uses different constants for women and men, and the men's constants if you have not set a sex.",
            "The total goes onto the 0 to 21 scale with a logarithm and stops at 21. Loopr needs your birth year and a resting heart rate. Any minute above resting adds a little, so a busy day on your feet counts too.",
            "The suggested range uses that morning's recovery score. Recovery 0 to 33 suggests strain 4 to 10; 34 to 66 suggests 10 to 14; 67 to 100 suggests 14 to 18. These bands stay fixed."
        ],
        raises: [
            "Workouts, especially long or intense ones",
            "A physically busy day"
        ],
        lowers: [
            "Rest days",
            "Long stretches of sitting"
        ],
        facts: [
            "The training impulse behind this score comes from the fitness and fatigue model used in sports science.",
            "Age formulas for maximum heart rate can miss a person's real maximum by about 11 bpm either way, which shifts the score.",
            "WHOOP's strain also runs from 0 to 21 on a logarithmic scale, but its formula is not published, so the two numbers are not interchangeable."
        ],
        sources: [
            "Morton, Fitz-Clarke and Banister 1990, Journal of Applied Physiology",
            "Tanaka et al. 2001, Journal of the American College of Cardiology",
            "Nes et al. 2013, Scandinavian Journal of Medicine and Science in Sports"
        ],
        provenance: "Calculated on your phone from band data. It is not sent to Apple Health."
    )

    // AnalyticsKit/Wellness/WellnessAnalytics.swift:280-284, 366-394, 594-612
    static let stress = MetricContent(
        definition: [
            "How tense your nervous system looked while you rested, on a scale from 0 to 100. It reads the pattern of your heartbeats, not your mood."
        ],
        calculation: [
            "Loopr uses the cleaned beat-to-beat intervals from your main sleep, or from the quiet stretches of your day if you did not sleep.",
            "It applies Baevsky's stress index to windows of 256 beats. The index looks at how tightly your intervals bunch together. A narrow, peaked spread means the fight-or-flight side is in charge. Loopr takes the median across all windows.",
            "The index goes onto a log scale where 20 is 0 and 600 is 100. Loopr needs at least 30 clean beats."
        ],
        raises: [
            "Mental and physical stress",
            "Alcohol",
            "Hard training",
            "Getting sick"
        ],
        lowers: [
            "Nights when your heart rate variability is high",
            "Rest and easy days"
        ],
        facts: [
            "There is no standard formula for stress from heart data. Every wearable uses its own, so scores do not compare across devices.",
            "Talking and moving change your heart rhythm, so stress readings mean most from still periods. That is why Loopr uses your sleep.",
            "Under stress, the rest-and-digest part of heart rate variability tends to drop."
        ],
        sources: [
            "Kim et al. 2018, Psychiatry Investigation",
            "Castaldo et al. 2015, Biomedical Signal Processing and Control"
        ],
        provenance: "Calculated on your phone from band data. It is not sent to Apple Health."
    )

    // MARK: - Sleep

    // AnalyticsKit/Sleep/SleepAdvancedDetector.swift:9-118, SleepAnalytics.swift:506-513, 670; SleepHRFallback.swift:19-80
    static let sleepDuration = MetricContent(
        definition: [
            "The time you spent asleep during your main sleep. Time awake in the middle of the night does not count."
        ],
        calculation: [
            "Loopr finds sleep from stillness first. Your band's motion sensor has to show almost no movement for most of a 15-minute stretch, and your heart rate has to settle below your evening level. A main sleep lasts at least 3 hours. Shorter sleeps count as naps.",
            "Inside that window, Loopr scores every 30 seconds as awake, light, deep or REM from your movement and heart rhythm. Duration adds up the time scored as asleep.",
            "If your band recorded too little movement, Loopr can find the night from heart rate alone. It marks those nights as partial and says so on the Sleep screen."
        ],
        raises: [
            "An earlier bedtime or a later alarm",
            "Fewer wake-ups during the night"
        ],
        lowers: [
            "Late nights and early starts",
            "Long wake-ups in the night, since that time is left out"
        ],
        facts: [
            "The American Academy of Sleep Medicine and the Sleep Research Society recommend at least 7 hours a night for adults.",
            "A shorter night can still have a high efficiency score, because efficiency measures the share of time in bed spent asleep.",
            "Sleep duration and regularity describe different parts of a night. Loopr shows both."
        ],
        sources: [
            "Watson et al. 2015, Journal of Clinical Sleep Medicine"
        ],
        provenance: "Estimated on your iPhone from band readings. Sleep stages for complete, confident nights go to Apple Health."
    )

    // AnalyticsKit/Sleep/SleepAnalytics.swift:678
    static let sleepEfficiency = MetricContent(
        definition: [
            "The share of your main sleep window that you actually spent asleep."
        ],
        calculation: [
            "Loopr divides the time scored as asleep by the length of your sleep window and multiplies by 100.",
            "The window starts when your band sees you settle and ends when you get up. It is not the time you got into bed, so reading or scrolling in bed before you lie still is left out. That tends to make this number higher than a sleep lab's."
        ],
        raises: [
            "Falling asleep soon after you lie still",
            "Fewer and shorter wake-ups"
        ],
        lowers: [
            "Waking often or lying awake for long stretches",
            "Age. Efficiency tends to fall as people get older"
        ],
        facts: [
            "Efficiency is the share of time in bed that Loopr scores as asleep.",
            "In a sleep-lab study of healthy people, median efficiency was 87% at age 30 or younger and 80% over 60."
        ],
        sources: [
            "Mitterling et al. 2015, Sleep"
        ],
        provenance: "Estimated on your iPhone from band readings."
    )

    // AnalyticsKit/Sleep/SleepCardioStaging.swift:75-296
    static let deepSleep = MetricContent(
        definition: [
            "Time in the deepest stage of non-REM sleep, also called slow-wave sleep. It is the stage you are hardest to wake from."
        ],
        calculation: [
            "Loopr scores every 30 seconds of your main sleep. A stretch counts as deep when you are still and your heart rate is low and very steady, with a heart rhythm pattern that points to strong rest-and-digest activity. Deep sleep has to last at least 3 minutes in a row to count.",
            "This is an estimate from heart rhythm and movement, not from brain waves, so read single nights loosely."
        ],
        raises: [
            "Catching up after short nights. The body puts deep sleep first when it is short of sleep"
        ],
        lowers: [
            "Age",
            "Waking often in the first half of the night, when most deep sleep happens"
        ],
        facts: [
            "Most deep sleep happens in the first half of the night.",
            "Deep sleep shrinks with age. In healthy adults it was a median 21% of sleep at age 30 or younger and 15% over 60.",
            "Wrist staging agrees with a sleep lab only part of the time. An earlier WHOOP band matched lab stages 60% of the time."
        ],
        sources: [
            "Mitterling et al. 2015, Sleep",
            "Miller et al. 2022, Sensors"
        ],
        provenance: "Estimated on your iPhone from band readings. Sleep stages for complete, confident nights go to Apple Health."
    )

    // AnalyticsKit/Sleep/SleepCardioStaging.swift:75-296
    static let remSleep = MetricContent(
        definition: [
            "The sleep stage when most vivid dreaming happens. Your brain is busy, your heart rate rises and varies more, and most of your muscles are relaxed."
        ],
        calculation: [
            "Loopr scores every 30 seconds of your main sleep. A stretch counts as REM when your heart rate and its short-term variability rise compared with the rest of your night while your body stays still.",
            "Very short stages are smoothed away, so each stage lasts at least 5 minutes. This is an estimate from heart rhythm and movement, not from brain waves."
        ],
        raises: [
            "A full night. Most REM comes in the second half, so a long sleep gets more of it"
        ],
        lowers: [
            "Cutting the night short with an early alarm",
            "Age"
        ],
        facts: [
            "REM sleep fills more of the second half of the night.",
            "In a sleep-lab study, REM was a median 15.5% of sleep at age 30 or younger and 10.3% over 60.",
            "Wrist staging agrees with a sleep lab only part of the time. An earlier WHOOP band matched lab stages 60% of the time."
        ],
        sources: [
            "Mitterling et al. 2015, Sleep",
            "Miller et al. 2022, Sensors"
        ],
        provenance: "Estimated on your iPhone from band readings. Sleep stages for complete, confident nights go to Apple Health."
    )

    // CanonicalDailyAnalytics.swift:818-867, AnalyticsKit/Sleep/SleepAnalytics.swift:792-802
    static let sleepConsistency = MetricContent(
        definition: [
            "How closely your sleep and wake times match from one day to the next. Loopr uses the Sleep Regularity Index. 100 means you slept at exactly the same times every day. Around 0 means no pattern at all."
        ],
        calculation: [
            "Loopr marks every minute of each day as asleep or awake, using your main sleep window. It then checks minute by minute whether you were in the same state at the same time 24 hours later.",
            "The index is 200 times the share of matching minutes, minus 100. It looks back over up to 29 nights in a row that have a main sleep and needs at least 2. Naps are left out, and short wake-ups inside your main sleep count as asleep.",
            "Loopr calls 80 or more very regular, 60 or more regular and 40 or more somewhat irregular."
        ],
        raises: [
            "Going to bed and getting up at the same times, weekends included"
        ],
        lowers: [
            "Late weekend nights and lie-ins",
            "Shift work and travel across time zones"
        ],
        facts: [
            "A regular bedtime and a regular wake time both affect this index.",
            "The index counts matching minutes, so a one-hour shift in bedtime costs as much as a one-hour shift in wake time."
        ],
        sources: [
            "Loopr sleep regularity calculation"
        ],
        provenance: "Estimated on your iPhone from band readings."
    )

    // MARK: - Fitness and activity

    // AnalyticsKit/Vitals/CardioFitness.swift; CanonicalVitalsDerivation.swift cardioFitness.
    static let vo2Max = MetricContent(
        definition: [
            "The most oxygen your body can use per minute during hard exercise, per kilogram of body weight. It is the standard measure of aerobic fitness."
        ],
        calculation: [
            "Loopr does not estimate VO2 max from resting heart rate. That method has not passed Loopr's validation gate.",
            "If you allow Apple Health access, Loopr can show a VO2 max reading stored there with its source named."
        ],
        raises: [
            "Regular aerobic training"
        ],
        lowers: [
            "Age. It falls about 10% per decade",
            "Long breaks from training"
        ],
        facts: [
            "In a large US fitness registry, the median for people in their 20s was 48.0 for men and 37.6 for women. In their 70s it was 24.4 and 18.3.",
            "Readings from different sources can use different methods. Keep the source in view when comparing them."
        ],
        sources: [
            "Kaminsky et al. 2015, Mayo Clinic Proceedings"
        ],
        provenance: "Loopr does not calculate this from band data. Readings shown here come from Apple Health."
    )

    // CanonicalDailyAnalytics derives an observed peak separately from zone settings.
    static let maxHeartRate = MetricContent(
        definition: ["Your highest recorded heart rate today. This is an observed peak, not the highest rate your heart can reach."],
        calculation: ["Loopr takes the highest valid heart rate reading in your local day. Missing readings stay missing."],
        raises: ["Harder efforts"],
        lowers: ["A quieter day", "Time with the band off can miss your highest effort"],
        facts: ["Your recorded peak depends on what you did and when you wore the band.",
                "Loopr keeps the maximum used for your heart rate zones separate from this daily peak."],
        sources: ["Loopr · band heart rate records"],
        provenance: "Recorded by your band."
    )

    static let activeEnergy = MetricContent(
        definition: [
            "Calories you burned through movement and exercise, on top of what your body burns at rest."
        ],
        calculation: [
            "For every waking minute where your heart rate is at least 30% of the way from resting to your estimated maximum, Loopr estimates calories with the Keytel heart rate equation and subtracts your resting burn from the Mifflin-St Jeor equation. Minutes below that line add nothing.",
            "Loopr needs your age, height and weight. Minutes with no heart rate reading add nothing, so time with the band off lowers the total."
        ],
        raises: [
            "Workouts",
            "An active day on your feet"
        ],
        lowers: [
            "Rest days",
            "Taking the band off"
        ],
        facts: [
            "Calorie estimates depend on the heart rate and movement the band records. Treat them as a rough guide.",
            "The Keytel equation was built for exercise, not rest, which is why Loopr ignores easy minutes.",
            "Guidelines suggest 150 minutes a week of moderate activity or 75 of vigorous activity."
        ],
        sources: [
            "Keytel et al. 2005, Journal of Sports Sciences",
            "Shcherbina et al. 2017, Journal of Personalized Medicine",
            "Garber et al. 2011, ACSM position stand"
        ],
        provenance: "Calculated on your phone from band data. Sent to Apple Health as active energy."
    )

    // AnalyticsKit/Activity/ActivityAnalytics.swift:641-645, 727-781, 929-936
    static let steps = MetricContent(
        definition: [
            "An estimate of how many steps you took today."
        ],
        calculation: [
            "The WHOOP 4.0 band does not count steps, so Loopr estimates them from wrist motion. It first learns your personal movement level from the previous 7 days, which takes at least 5 days with an hour of wear each.",
            "A minute counts as walking when your motion sits above that level but below 3 times it, and your heart rate is at least 8 bpm above resting. Only runs of 3 or more such minutes count. Each walking minute is worth 115 steps, the middle of a typical 100 to 130 steps a minute.",
            "Running and other hard minutes sit above the walking band and are left out, so a run adds little here."
        ],
        raises: [
            "Walking, errands and taking the stairs"
        ],
        lowers: [
            "Long stretches of sitting",
            "Running and cycling, which this estimate leaves out"
        ],
        facts: [
            "Loopr estimates steps from wrist motion, so its count can miss running and other hard minutes.",
            "A step goal is a personal target, not a health threshold."
        ],
        sources: [
            "Loopr step estimation method"
        ],
        provenance: "Estimated on your phone from band motion. Sent to Apple Health as steps."
    )
}
