import Foundation
import DomainKit
import DesignSystem

public enum SleepFixtures {
    public static let day = DayIdentity(year: 2023, month: 11, day: 14)
    public static let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

    /// When the fixture night ends: 06:58 on the fixture day in the phone's
    /// time zone, so bedtime and wake time read like a real night wherever
    /// the fixture runs. It is always before the fixture clock (`baseDate`).
    public static var nightEnd: Date {
        Calendar.current.date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: 6, minute: 58))
            ?? baseDate
    }

    /// The fixture night from `LooprSampleNight`: in bed for 8 h 28 m, asleep
    /// 7 h 42 m, ending at `nightEnd`. Every number agrees with the metric
    /// pages' fixture history (`LooprFixtureMetrics`).
    static var timeInBedSeconds: TimeInterval { Double(LooprSampleNight.timeInBedMinutes) * 60 }
    public static var nightStart: Date { nightEnd.addingTimeInterval(-timeInBedSeconds) }

    static var stageMinutes: [SleepStage: Int] {
        LooprSampleNight.segments.reduce(into: [:]) { $0[$1.stage, default: 0] += $1.durationMinutes }
    }

    public static func snapshot(for state: MetricState) -> SleepDaySnapshot {
        let hasValue = state == .measuredZero || state == .partial || state == .lowConfidence || state == .settling || state == .stale
        // `.partial` is the state every normal production value carries, and
        // the populated app composition renders `snapshot(for: .partial)`, so
        // it is a finished night. Only `.settling` is still being recorded.
        let partial = state == .settling
        let zero = state == .measuredZero
        let asleep = LooprSampleNight.asleepMinutes
        let main: SleepSessionSummary? = hasValue ? SleepSessionSummary(id: "night", start: nightStart, end: nightEnd, durationMinutes: zero ? 0 : asleep, isMainSleep: true, isPartial: partial, confidence: state == .lowConfidence ? 0.25 : 0.9, state: state) : nil
        let confidence: String? = state == .lowConfidence ? "Low confidence" : nil
        func row(_ id: String, _ title: String, _ number: Double, _ text: String, _ unit: String, source: String, numericUnit: SleepMetricUnitID) -> SleepMetricValue {
            SleepMetricValue(id: id, title: title, value: hasValue ? (zero ? (id == "duration" ? "0:00" : "0") : text) : nil, unit: unit, state: state, confidence: hasValue ? confidence : nil, source: source, algorithmVersion: "sleep.v1", numericValue: hasValue ? (zero ? 0 : number) : nil, numericUnit: numericUnit)
        }
        let stages = stageMinutes
        let efficiency = LooprFixtureMetrics.today(LooprMetricLinkID.sleepEfficiency) ?? 0
        let regularity = LooprFixtureMetrics.today(LooprMetricLinkID.sleepConsistency) ?? 0
        let values = [
            row("duration", "Duration", Double(asleep), "\(asleep / 60):\(String(format: "%02d", asleep % 60))", "hours", source: "ANA-03.sleep", numericUnit: .minutes),
            row("efficiency", "Efficiency", efficiency, String(format: "%.0f", efficiency), "%", source: "ANA-03.accounting", numericUnit: .percentagePoints),
            row("deep", "Deep sleep", Double(stages[.deep] ?? 0), "\(stages[.deep] ?? 0)", "minutes", source: "ANA-03.staging", numericUnit: .minutes),
            row("rem", "REM sleep", Double(stages[.rem] ?? 0), "\(stages[.rem] ?? 0)", "minutes", source: "ANA-03.staging", numericUnit: .minutes),
            row("light", "Light sleep", Double(stages[.light] ?? 0), "\(stages[.light] ?? 0)", "minutes", source: "ANA-03.staging", numericUnit: .minutes),
            row("awake", "Awake", Double(stages[.awake] ?? 0), "\(stages[.awake] ?? 0)", "minutes", source: "ANA-03.staging", numericUnit: .minutes),
            row("latency", "Time to fall asleep", 12, "12", "minutes", source: "ANA-03.hypnogram", numericUnit: .minutes),
            row("disturbances", "Wake-ups", 3, "3", "times", source: "ANA-03.hypnogram", numericUnit: .unknown),
            row("regularity", "Sleep regularity", regularity, String(format: "%.0f", regularity), "points", source: "ANA-03.consistency", numericUnit: .scorePoints)
        ]
        let segments = hasValue && !zero ? LooprSampleNight.segments : []
        let ledger = LooprSampleNight.debtLedger(endingOn: fixtureNoon)
        let debtMinutes = max(0, -LooprDivergingBarsModel(bars: ledger).total)
        let trend = hasValue ? nights(state: state) : []
        return SleepDaySnapshot(day: day, state: state, mainSleep: main, metrics: values, hypnogram: segments, trend: trend, needHours: hasValue ? LooprFixtureMetrics.sleepNeedMinutes / 60 : nil, debtHours: hasValue ? (zero ? 0 : debtMinutes / 60) : nil, source: "ANA-03.canonical", algorithmVersion: "sleep.v1", coachLink: SleepCoachLink(title: "Sleep coach", detail: "See what the coach suggests for tonight.", state: state), suggestedAlarm: hasValue ? SleepSuggestedAlarm(localTime: "07:30", reason: "Protect the suggested sleep opportunity.", source: "ANA-08.coach", algorithmVersion: "sleep-alarm.v1") : nil)
    }

    /// Noon of the fixture day in the phone's time zone: the day every
    /// fixture history ends on.
    static var fixtureNoon: Date {
        Calendar.current.date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: 12)) ?? baseDate
    }

    /// Nights in the fixture trend: the fixture night and the 29 before it,
    /// as the derivation folds them (a night the history skips is left out).
    public static let trendNights = 30

    /// The fixture trend: 30 nights of duration, stages, efficiency,
    /// breathing rate, bedtime and wake time, from the shared fixture history.
    /// The last point is the fixture night itself.
    static func nights(state: MetricState) -> [SleepTrendPoint] {
        let calendar = Calendar.current
        let end = fixtureNoon
        func series(_ id: String) -> [Date: Double] {
            Dictionary(LooprFixtureMetrics.history(id, days: trendNights, endingOn: end, calendar: calendar)
                .map { (calendar.startOfDay(for: $0.date), $0.value) }, uniquingKeysWith: { first, _ in first })
        }
        let duration = series(LooprMetricLinkID.sleepDuration)
        let deep = series(LooprMetricLinkID.deepSleep)
        let rem = series(LooprMetricLinkID.remSleep)
        let efficiency = series(LooprMetricLinkID.sleepEfficiency)
        let breathing = series(LooprMetricLinkID.respiratoryRate)
        let last = calendar.startOfDay(for: end)
        return (0..<trendNights).reversed().compactMap { offset -> SleepTrendPoint? in
            guard let dayStart = calendar.date(byAdding: .day, value: -offset, to: last),
                  let asleep = duration[dayStart] else { return nil }
            let label = localDay(dayStart, calendar: calendar)
            if offset == 0 {
                let tonight = snapshotValues(state: state)
                return SleepTrendPoint(id: label, localDay: label, value: asleep / 60, state: state, unit: "hours",
                                       start: nightStart, end: nightEnd, values: tonight)
            }
            var generator = FixtureGenerator(seed: UInt64(offset) &* 2_654_435_761 &+ 97)
            let deepMinutes = deep[dayStart] ?? 78
            let remMinutes = rem[dayStart] ?? 94
            let eff = efficiency[dayStart] ?? 89
            let inBed = (asleep / (eff / 100)).rounded()
            let weekday = calendar.component(.weekday, from: dayStart)
            let weekend = weekday == 1 || weekday == 7
            // Wake near 06:55 on weekdays, later at weekends; bedtime follows
            // from the time in bed.
            let wakeMinute = 6 * 60 + 55 + (weekend ? 55 : 0) + Int(generator.signed() * 14)
            guard let wake = calendar.date(byAdding: .minute, value: wakeMinute, to: dayStart) else { return nil }
            let bed = wake.addingTimeInterval(-inBed * 60)
            var values: [String: Double] = [
                "deep": deepMinutes,
                "rem": remMinutes,
                "light": max(0, asleep - deepMinutes - remMinutes),
                "awake": max(0, inBed - asleep),
                "efficiency": eff,
                "disturbances": Double(2 + Int(generator.unit() * 4))
            ]
            if let rate = breathing[dayStart] { values[SleepTrendPoint.breathingRateID] = rate }
            return SleepTrendPoint(id: label, localDay: label, value: asleep / 60, state: state, unit: "hours",
                                   start: bed, end: wake, values: values)
        }
    }

    /// The fixture night's own per-night values, as the derivation would copy them.
    static func snapshotValues(state: MetricState) -> [String: Double] {
        let stages = stageMinutes
        var values: [String: Double] = [
            "deep": Double(stages[.deep] ?? 0),
            "rem": Double(stages[.rem] ?? 0),
            "light": Double(stages[.light] ?? 0),
            "awake": Double(stages[.awake] ?? 0),
            "efficiency": LooprFixtureMetrics.today(LooprMetricLinkID.sleepEfficiency) ?? 0,
            "disturbances": 3
        ]
        if let rate = LooprFixtureMetrics.today(LooprMetricLinkID.respiratoryRate) {
            values[SleepTrendPoint.breathingRateID] = rate
        }
        return values
    }

    /// `yyyy-MM-dd` for a date in `calendar`.
    static func localDay(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    public static var allStates: [(state: MetricState, snapshot: SleepDaySnapshot)] {
        MetricState.allCases.map { (state: $0, snapshot: snapshot(for: $0)) }
    }

    /// A night whose recording has not finished yet.
    public static var partialOvernight: SleepDaySnapshot {
        let base = snapshot(for: .partial)
        let main = base.mainSleep.map {
            SleepSessionSummary(id: $0.id, start: $0.start, end: $0.end, durationMinutes: $0.durationMinutes,
                                isMainSleep: true, isPartial: true, confidence: $0.confidence, state: .partial)
        }
        return SleepDaySnapshot(day: day, state: .partial, mainSleep: main, metrics: base.metrics, hypnogram: base.hypnogram,
                                trend: base.trend, needHours: base.needHours, debtHours: base.debtHours, source: base.source,
                                algorithmVersion: base.algorithmVersion, coachLink: base.coachLink, suggestedAlarm: base.suggestedAlarm)
    }

    public static var populated: SleepDaySnapshot {
        let complete = snapshot(for: .partial)
        return SleepDaySnapshot(day: day, state: .partial, mainSleep: SleepSessionSummary(id: "night", start: nightStart, end: nightEnd, durationMinutes: LooprSampleNight.asleepMinutes, isMainSleep: true, isPartial: false, confidence: 0.93, state: .partial), naps: [SleepSessionSummary(id: "nap", start: nightEnd.addingTimeInterval(7 * 3_600), end: nightEnd.addingTimeInterval(7 * 3_600 + 2_400), durationMinutes: 40, isMainSleep: false, isPartial: false, confidence: 0.86, state: .partial)], metrics: complete.metrics, hypnogram: complete.hypnogram, trend: complete.trend, needHours: complete.needHours, debtHours: complete.debtHours, source: "ANA-03.canonical", algorithmVersion: "sleep.v1", coachLink: complete.coachLink, suggestedAlarm: complete.suggestedAlarm)
    }

    /// One correction on the fixture night, so the populated app shows the
    /// Corrections row and its screen the way a corrected night does.
    public static var corrections: [SleepCorrection] {
        [SleepCorrection(id: UUID(uuidString: "5C1EE900-0000-4000-8000-000000000001")!, day: day, target: "Sleep start",
                         before: SleepClock.text(minutesAfterNoon: SleepClock.minutesAfterNoon(nightStart, timeZone: .current) - 14),
                         after: SleepClock.text(minutesAfterNoon: SleepClock.minutesAfterNoon(nightStart, timeZone: .current)),
                         reason: "Read in bed before falling asleep", algorithmVersion: "sleep.v1", createdAt: baseDate)]
    }

    /// Minute-by-minute heart rate for the fixture night, shaped by its
    /// stages: lowest in deep sleep, more varied in REM, up when awake, and
    /// drifting down over the night. Fixture and previews only.
    public static var overnightHeartRate: [SleepHeartRateMinute] {
        var generator = FixtureGenerator(seed: 0x51EE_9000)
        let rest = LooprFixtureMetrics.today(LooprMetricLinkID.restingHeartRate) ?? 51
        let spans = LooprStageSpan.spans(from: LooprSampleNight.segments, start: nightStart)
        let total = max(nightEnd.timeIntervalSince(nightStart), 1)
        var samples: [SleepHeartRateMinute] = []
        var drift = 0.0
        for span in spans {
            var minute = span.start
            while minute < span.end {
                let progress = minute.timeIntervalSince(nightStart) / total
                let base: Double = switch span.stage {
                case .deep: rest - 2
                case .light: rest + 2
                case .rem: rest + 6 + generator.signed() * 3
                case .awake: rest + 13 + generator.signed() * 4
                }
                drift = drift * 0.8 + generator.signed() * 0.6
                let bpm = base + 4 * (1 - progress) - 2 + drift
                samples.append(SleepHeartRateMinute(date: minute, bpm: (bpm * 10).rounded() / 10))
                minute = minute.addingTimeInterval(60)
            }
        }
        return samples
    }

    /// Detail for the in-memory fixture compositions: the fixture night's
    /// heart rate and no sleep goal.
    public struct DetailSource: SleepNightDetailSource {
        public init() {}
        public func overnightHeartRate(from start: Date, to end: Date) async -> [SleepHeartRateMinute] {
            let samples = SleepFixtures.overnightHeartRate
            guard let first = samples.first?.date, let last = samples.last?.date,
                  abs(first.timeIntervalSince(start)) < 3_600, abs(last.timeIntervalSince(end)) < 3_600 else { return [] }
            return samples.filter { $0.date >= start && $0.date <= end }
        }
        public func sleepGoalMinutes() async -> Double? { nil }
    }
}

/// A tiny deterministic generator for fixture noise.
struct FixtureGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }
    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    /// Roughly -1...1, centred.
    mutating func signed() -> Double { (unit() + unit() - 1) }
}
