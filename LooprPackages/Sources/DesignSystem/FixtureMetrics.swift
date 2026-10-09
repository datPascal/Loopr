import Foundation

/// The single source of fixture truth: one believable person, one day, and
/// the history behind it.
///
/// The tab fixtures (`TodayFixtures`, `SleepFixtures`, `HeartFixtures`,
/// `BodyFixtures`), the app's `FixtureMetricHistoryProvider` (metric detail
/// pages in `--loopr-metric-history-fixture` runs), the component gallery and
/// the previews all read their numbers from here, so a value on a tab is the
/// value its detail page ends on, and the "vs usual" story is the same
/// everywhere.
///
/// The story for the fixture day: a good night (7 h 42 m against a 7 h 30 m
/// need), HRV above usual, resting heart rate a little below usual, breathing
/// rate usual, recovery 79 (high band), a light day so far (strain 8.6).
///
/// Never read this from a production code path. Absent is absent: real
/// screens show a gap, never these numbers.
public enum LooprFixtureMetrics {
    /// Sleep need on the fixture night, in minutes (7 h 30 m).
    public static let sleepNeedMinutes: Double = 450
    /// Days of history `history(_:days:endingOn:)` is tuned for. It will
    /// produce more if asked (the year view asks for 400).
    public static let historyDays = 60

    /// Metric ids with no history at all: Loopr does not calculate them, so
    /// their pages show the honest empty state.
    public static let emptyIDs: Set<String> = [LooprMetricLinkID.heartRateDip, LooprMetricLinkID.maxHeartRate]

    /// The fixture day's value for a metric id (`LooprMetricLinkID`), or nil
    /// when the metric has no value that day.
    public static func today(_ id: String) -> Double? {
        guard !emptyIDs.contains(id), let story = stories[id] else { return nil }
        return story.today ?? story.usual
    }

    /// The usual value the history is built around (before noise), for tests.
    public static func usual(_ id: String) -> Double? {
        guard !emptyIDs.contains(id) else { return nil }
        return stories[id]?.usual
    }

    /// The good day's earlier recovery inputs, shared with the morning
    /// captures. RHR stays below the 1 bpm spread gate and is not scored.
    /// The other two contributors produce a score that rounds to 79.
    public static func recoverySignalBaseline(_ id: String, offset: Int) -> Double? {
        guard [LooprMetricLinkID.rmssd, LooprMetricLinkID.restingHeartRate,
               LooprMetricLinkID.respiratoryRate].contains(id), let story = stories[id] else { return nil }
        return story.usual + story.noise * variation(seed: "si-morning", offset: offset) * 2
    }

    /// Deterministic daily history for `id`, oldest first, ending on the day
    /// of `endingOn` with exactly `today(id)`. A few nights are missing here
    /// and there, plus one five-day break about six weeks back, so gaps are
    /// covered too. The same id and day count always give the same values.
    public static func history(
        _ id: String,
        days: Int,
        endingOn: Date,
        calendar: Calendar = .current
    ) -> [LooprChartPoint] {
        guard !emptyIDs.contains(id), let story = stories[id], days > 0 else { return [] }
        let last = calendar.startOfDay(for: endingOn)
        let seed = UInt64(truncatingIfNeeded: stableHash(id)) &+ 17
        var result: [LooprChartPoint] = []
        for offset in stride(from: days - 1, through: 0, by: -1) {
            // One generator per day, seeded by the day's distance from the
            // end, so a day's value never depends on how many days were
            // asked for: the Today tab's 30 days and a detail page's 400
            // agree on every day they share.
            var generator = SeededGenerator(seed: seed &+ UInt64(offset) &* 0x9E37_79B9_7F4A_7C15)
            _ = generator.next()
            // Keep the established missing-day schedule when changing the noise.
            _ = generator.nextSigned()
            let noise = variation(seed: id, offset: offset) * 2.1
            let skip = generator.nextUnit()
            guard let day = calendar.date(byAdding: .day, value: -offset, to: last) else { continue }
            let value: Double
            if offset > 0, offset <= 28, let baseline = recoverySignalBaseline(id, offset: offset) {
                value = baseline
            } else if offset == 0 {
                value = story.today ?? story.round(story.usual)
            } else {
                if skip < 0.07 || (offset >= 38 && offset <= 42) { continue }
                let weekly = sin(Double(offset) / 7 * 2 * .pi) * story.weekly * story.coupling
                let drift = sin(Double(offset) / 23) * story.drift * story.coupling
                let raw = story.usual + weekly + drift + noise * story.noise
                value = story.round(min(max(raw, story.floor), story.ceiling))
            }
            let spread = story.noise * 1.4 + story.usual * 0.06
            result.append(LooprChartPoint(
                date: day,
                value: value,
                low: story.hasRange ? story.round(value - spread) : nil,
                high: story.hasRange ? story.round(value + spread * 1.8) : nil
            ))
        }
        return result
    }

    // MARK: Stories

    struct Story {
        let today: Double?
        let usual: Double
        let noise: Double
        let weekly: Double
        let drift: Double
        let floor: Double
        let ceiling: Double
        let digits: Int
        var hasRange = false
        /// +1 or -1. Every story shares one weekly rhythm and one slow drift;
        /// metrics that fall on good days (resting heart rate, stress, strain
        /// and the activity it comes from) run them the other way, so the
        /// fixture's metrics move together the way real ones do.
        var coupling: Double = 1

        func round(_ value: Double) -> Double {
            let scale = pow(10, Double(digits))
            return (value * scale).rounded() / scale
        }
    }

    static let stories: [String: Story] = [
        LooprMetricLinkID.restingHeartRate: Story(today: 51, usual: 55, noise: 2.3, weekly: 0.6, drift: 0.6, floor: 38, ceiling: 90, digits: 0, coupling: -1),
        LooprMetricLinkID.rmssd: Story(today: 61, usual: 50, noise: 6, weekly: 2, drift: 2, floor: 10, ceiling: 140, digits: 0),
        LooprMetricLinkID.sdnn: Story(today: 72, usual: 68, noise: 6, weekly: 3, drift: 3, floor: 20, ceiling: 180, digits: 0),
        LooprMetricLinkID.pNN50: Story(today: 26, usual: 22, noise: 3.5, weekly: 1.5, drift: 1.5, floor: 0, ceiling: 60, digits: 0),
        LooprMetricLinkID.respiratoryRate: Story(today: 14.7, usual: 14.8, noise: 0.25, weekly: 0.1, drift: 0.15, floor: 9, ceiling: 24, digits: 1, coupling: -1),
        LooprMetricLinkID.sleepingHeartRate: Story(today: 57, usual: 58, noise: 2, weekly: 1, drift: 1.5, floor: 40, ceiling: 95, digits: 0, hasRange: true, coupling: -1),
        LooprMetricLinkID.oxygenSaturation: Story(today: nil, usual: 96.2, noise: 0.6, weekly: 0.2, drift: 0.3, floor: 90, ceiling: 100, digits: 1),
        LooprMetricLinkID.skinTemperatureDeviation: Story(today: nil, usual: 0, noise: 0.18, weekly: 0.05, drift: 0.12, floor: -1.5, ceiling: 1.5, digits: 2),
        LooprMetricLinkID.recovery: Story(today: 79, usual: 62, noise: 11, weekly: 5, drift: 5, floor: 1, ceiling: 99, digits: 0),
        LooprMetricLinkID.strain: Story(today: 8.6, usual: 11.5, noise: 2.6, weekly: 1.8, drift: 1.2, floor: 0.5, ceiling: 21, digits: 1, coupling: -1),
        LooprMetricLinkID.stress: Story(today: 21, usual: 30, noise: 7, weekly: 3, drift: 3, floor: 0, ceiling: 100, digits: 0, coupling: -1),
        LooprMetricLinkID.sleepDuration: Story(today: 462, usual: 452, noise: 28, weekly: 16, drift: 8, floor: 200, ceiling: 620, digits: 0),
        LooprMetricLinkID.sleepEfficiency: Story(today: 91, usual: 89, noise: 2.4, weekly: 1, drift: 1, floor: 60, ceiling: 99, digits: 0),
        LooprMetricLinkID.deepSleep: Story(today: 82, usual: 78, noise: 11, weekly: 4, drift: 4, floor: 10, ceiling: 160, digits: 0),
        LooprMetricLinkID.remSleep: Story(today: 96, usual: 94, noise: 13, weekly: 5, drift: 5, floor: 15, ceiling: 180, digits: 0),
        LooprMetricLinkID.sleepConsistency: Story(today: 78, usual: 74, noise: 6, weekly: 3, drift: 3, floor: 10, ceiling: 99, digits: 0),
        LooprMetricLinkID.vo2Max: Story(today: nil, usual: 47.5, noise: 0.6, weekly: 0.1, drift: 1.2, floor: 30, ceiling: 65, digits: 1),
        LooprMetricLinkID.activeEnergy: Story(today: 612, usual: 640, noise: 150, weekly: 90, drift: 40, floor: 60, ceiling: 2_200, digits: 0, coupling: -1),
        LooprMetricLinkID.steps: Story(today: 8_240, usual: 8_400, noise: 1_900, weekly: 1_100, drift: 500, floor: 800, ceiling: 26_000, digits: 0, coupling: -1)
    ]

    // MARK: Randomness that never changes between launches

    /// Bounded, irregular variation with some carry-over from neighbouring days.
    /// Offsets are relative to the final day, so overlapping capture ranges agree.
    public static func variation(seed: String, offset: Int) -> Double {
        func noise(_ day: Int) -> Double {
            var generator = SeededGenerator(seed: UInt64(truncatingIfNeeded: stableHash(seed))
                &+ UInt64(truncatingIfNeeded: day) &* 0x9E37_79B9_7F4A_7C15)
            _ = generator.next()
            return generator.nextSigned() / 2.1
        }
        return 0.6 * noise(offset) + 0.25 * noise(offset + 1) + 0.15 * noise(offset - 1)
    }

    struct SeededGenerator {
        var state: UInt64

        init(seed: UInt64) { state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }

        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state
        }

        mutating func nextUnit() -> Double { Double(next() >> 11) / Double(1 << 53) }

        /// Roughly normal noise in about -2...2 (standard deviation 0.7).
        mutating func nextSigned() -> Double { (nextUnit() + nextUnit() + nextUnit() - 1.5) * 1.4 }
    }

    /// `hashValue` is randomised per launch; fixtures must not be.
    static func stableHash(_ text: String) -> Int {
        var hash = 5381
        for byte in text.utf8 { hash = (hash &* 33) &+ Int(byte) }
        return hash
    }
}

/// A realistic night and the charts built on the fixture history, for the
/// gallery, previews and the Sleep fixture.
public enum LooprSampleNight {
    /// 8 h 28 m in bed from the main sleep's start: 7 h 42 m asleep (Deep
    /// 1 h 22 m, REM 1 h 36 m, Light 4 h 44 m) and 46 min awake, in five
    /// cycles with deep sleep early and REM late, as a real night runs.
    public static let segments: [SleepSegment] = {
        let plan: [(SleepStage, Int)] = [
            (.awake, 12), (.light, 22), (.deep, 38), (.light, 12), (.rem, 10),
            (.light, 30), (.deep, 28), (.light, 14), (.rem, 20), (.awake, 4),
            (.light, 40), (.deep, 16), (.light, 18), (.rem, 26), (.awake, 6),
            (.light, 60), (.rem, 22), (.awake, 8), (.light, 48),
            (.light, 40), (.rem, 18), (.awake, 16)
        ]
        // Merge neighbours of the same stage so every segment is one run.
        var merged: [(SleepStage, Int)] = []
        for (stage, minutes) in plan {
            if merged.last?.0 == stage { merged[merged.count - 1].1 += minutes } else { merged.append((stage, minutes)) }
        }
        return merged.enumerated().map { SleepSegment(id: $0.offset, stage: $0.element.0, durationMinutes: $0.element.1) }
    }()

    /// Minutes in bed for `segments`.
    public static var timeInBedMinutes: Int { segments.reduce(0) { $0 + $1.durationMinutes } }

    /// Minutes asleep for `segments`.
    public static var asleepMinutes: Int { segments.filter { $0.stage != .awake }.reduce(0) { $0 + $1.durationMinutes } }

    /// The last 14 nights of sleep minus need, from the fixture history.
    public static func debtLedger(endingOn: Date, nights: Int = 14, calendar: Calendar = .current) -> [LooprDailyBar] {
        let history = LooprFixtureMetrics.history(LooprMetricLinkID.sleepDuration, days: nights, endingOn: endingOn, calendar: calendar)
        let byDay = Dictionary(uniqueKeysWithValues: history.map { (calendar.startOfDay(for: $0.date), $0.value) })
        let last = calendar.startOfDay(for: endingOn)
        return (0..<nights).reversed().compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: last).map { day in
                LooprDailyBar(date: day, value: byDay[day].map { $0 - LooprFixtureMetrics.sleepNeedMinutes })
            }
        }
    }

    /// The 7 days before the fixture day: each day's strain next to the
    /// recovery the following morning. Today is left out because its strain
    /// is still building.
    public static func strainRecoveryWeek(endingOn: Date, calendar: Calendar = .current) -> [LooprPairedBarDay] {
        let strain = LooprFixtureMetrics.history(LooprMetricLinkID.strain, days: 8, endingOn: endingOn, calendar: calendar)
        let recovery = LooprFixtureMetrics.history(LooprMetricLinkID.recovery, days: 8, endingOn: endingOn, calendar: calendar)
        let strainByDay = Dictionary(uniqueKeysWithValues: strain.map { (calendar.startOfDay(for: $0.date), $0.value) })
        let recoveryByDay = Dictionary(uniqueKeysWithValues: recovery.map { (calendar.startOfDay(for: $0.date), $0.value) })
        let last = calendar.startOfDay(for: endingOn)
        return (1...7).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: last),
                  let next = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
            return LooprPairedBarDay(date: day, first: strainByDay[day], second: recoveryByDay[next])
        }
    }
}
