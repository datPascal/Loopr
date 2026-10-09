import AnalyticsKit
import BodyKit
import DesignSystem
import DeviceCenterKit
import DomainKit
import Foundation
import JournalKit
import HeartKit
import SleepKit
import TodayKit

/// Reads everything around a day's Today summary: 60 days of history for the
/// "vs usual" comparisons, the recovery split, the resting heart-rate trend,
/// journal entries, tonight's inputs and the zone minutes.
///
/// One read per day change. Every store is read off the main actor, and a
/// store that fails leaves its part empty instead of failing Today.
nonisolated struct LooprTodayContextSource: TodayContextRepository {
    let history: any MetricHistoryProviding
    let timeZone: TimeZone
    let sleepDay: @Sendable (DayIdentity) async -> SleepDaySnapshot?
    let bodyDay: @Sendable (DayIdentity) async -> BodyDaySnapshot?
    let journalEntries: @Sendable ([String]) async -> [JournalEntry]
    let alarmMinute: @Sendable () async -> Int?
    var overnightAssessment: (@Sendable (DayIdentity) async -> OvernightVitalsAssessment?)? = nil

    var temperatureMissingReason: (@Sendable (DayIdentity) async -> String?)? = nil

    /// Nights the recovery score compares with, as in `priorDays(before:)`.
    static let baselineNights = 28

    func context(for day: DayIdentity, summary: TodaySummary?) async throws -> TodayDayContext? {
        let calendar = MetricHistoryDays.calendar(timeZone)
        guard let dayStart = calendar.date(from: DateComponents(era: day.era, year: day.year, month: day.month, day: day.day)) else {
            return nil
        }
        var series: [TodayTrackedMetric: [LooprChartPoint]] = [:]
        try await withThrowingTaskGroup(of: (TodayTrackedMetric, [LooprChartPoint]).self) { group in
            for metric in TodayDayContext.historyMetrics {
                guard let key = MetricKey(rawValue: metric.linkID) else { continue }
                group.addTask {
                    let points = (try? await history.series(for: key, days: TodayDayContext.historyDays, endingOn: dayStart)) ?? []
                    return (metric, points.map { LooprChartPoint(date: $0.day, value: $0.value) })
                }
            }
            for try await (metric, points) in group { series[metric] = points }
        }
        try Task.checkCancellation()

        async let loadHistory = MetricHistoryBodyProvider(provider: history, calendar: calendar).bodyHistory(anchor: day)
        async let sleep = sleepDay(day)
        async let body = bodyDay(day)
        async let alarm = alarmMinute()
        let previous = calendar.date(byAdding: .day, value: -1, to: dayStart) ?? dayStart
        async let journal = journalEntries([MetricHistoryDays.label(previous, calendar: calendar),
                                            MetricHistoryDays.label(dayStart, calendar: calendar)])

        let recovery = Self.recoveryBreakdown(summary: summary, history: series, dayStart: dayStart, calendar: calendar)
        let trend = Self.restingTrend(series[.restingHeartRate] ?? [], dayStart: dayStart, calendar: calendar)
        let sleepSnapshot = await sleep
        let tonight = TodayTonightInputs(
            needMinutes: summary?.sleepNeedMinutes,
            alarmMinute: await alarm,
            suggestedWakeMinute: sleepSnapshot?.suggestedAlarm.flatMap { Self.minute(of: $0.localTime) }
        )
        let zones = (await body)?.zoneMinutes.map { TodayZoneMinutes(id: $0.id, name: $0.name, minutes: $0.minutes) } ?? []
        let summaryRecovery = [TodayMetricID.recovery, .readiness].compactMap { id -> Double? in
            guard let metric = summary?.metric(id), metric.state != .absent,
                  metric.numericUnit == .scorePoints else { return nil }
            return metric.numericValue
        }.first
        // Body reads the recovery metric history for this same civil day.
        // Prefer it when present so both rings use one stored score.
        let recoveryScore = series[.recovery]?.last(where: { calendar.isDate($0.date, inSameDayAs: dayStart) })?.value
            ?? summaryRecovery
        let loadState = BodyTrainingLoad.compute(history: await loadHistory, endingOn: day.bodyAdding(days: -1))
        let load: TrainingLoad? = if case .ready(let ready) = loadState { ready.model } else { nil }
        return TodayDayContext(
            day: day,
            dayStart: dayStart,
            history: series,
            recovery: recovery,
            restingTrend: trend,
            journalFactors: Self.factors(await journal),
            suggestedStrainRange: StrainTarget(recovery: recoveryScore, trainingLoad: load)?.range,
            strainTarget: StrainTarget(recovery: recoveryScore, trainingLoad: load),
            zoneMinutes: zones,
            tonight: tonight,
            overnightAssessment: await overnightAssessment?(day),
            temperatureMissingReason: await temperatureMissingReason?(day)
        )
    }

    /// The recovery split, from the same formula and inputs the score uses:
    /// last night's HRV, resting heart rate and breathing rate against the
    /// 28 nights before.
    static func recoveryBreakdown(summary: TodaySummary?, history: [TodayTrackedMetric: [LooprChartPoint]],
                                  dayStart: Date, calendar: Calendar) -> TodayRecoveryBreakdown? {
        guard let floor = calendar.date(byAdding: .day, value: -baselineNights, to: dayStart) else { return nil }
        func dayValue(_ metric: TodayTrackedMetric) -> Double? {
            history[metric]?.last(where: { calendar.isDate($0.date, inSameDayAs: dayStart) })?.value
        }
        // The summary's HRV and resting heart rate fall back to quiet daytime
        // stretches when there is no night. They never go against nightly
        // baselines, so without a recorded sleep only the night history counts.
        let hasNight = summary.map { value in
            value.metric(.sleep).map { $0.state != .absent && $0.numericValue != nil } ?? false
        } ?? true
        func summaryValue(_ id: TodayMetricID, _ unit: TodayMetricUnitID) -> Double? {
            guard hasNight, let metric = summary?.metric(id), metric.state != .absent, metric.numericUnit == unit else { return nil }
            return metric.numericValue
        }
        func baseline(_ metric: TodayTrackedMetric) -> [Double] {
            (history[metric] ?? []).filter { $0.date >= floor && $0.date < dayStart }.map(\.value)
        }
        let readings = [
            RecoverySignalReading(signal: .hrv, value: summaryValue(.hrv, .milliseconds) ?? dayValue(.hrv), baseline: baseline(.hrv)),
            RecoverySignalReading(signal: .restingHeartRate,
                                  value: summaryValue(.restingHeartRate, .beatsPerMinute) ?? dayValue(.restingHeartRate),
                                  baseline: baseline(.restingHeartRate)),
            RecoverySignalReading(signal: .respiratoryRate, value: dayValue(.respiratoryRate), baseline: baseline(.respiratoryRate))
        ]
        guard readings.contains(where: { $0.value != nil }) else { return nil }
        return TodayRecoveryBreakdown(WellnessAnalytics.recoveryDecomposition(readings))
    }

    /// Whether resting heart rate has run above usual, from the illness CUSUM.
    static func restingTrend(_ points: [LooprChartPoint], dayStart: Date, calendar: Calendar) -> TodayRestingTrend {
        let byDay = Dictionary(points.map { (calendar.startOfDay(for: $0.date), $0.value) }, uniquingKeysWith: { _, last in last })
        let days = (0..<TodayDayContext.historyDays).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: dayStart) }
        let states = WellnessAnalytics.illnessCusum(
            dates: days.map { MetricHistoryDays.label($0, calendar: calendar) },
            restingHeartRate: days.map { byDay[calendar.startOfDay(for: $0)] }
        )
        switch states.last?.state {
        case .red: return .persistent
        case .yellow: return .elevated
        default: return .usual
        }
    }

    /// Journal behaviours and tags, most common first, in plain words.
    static func factors(_ entries: [JournalEntry]) -> [String] {
        var counts: [String: Int] = [:]
        for entry in entries {
            for tag in entry.behaviors.union(entry.tags) {
                let clean = tag.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
                guard !clean.isEmpty else { continue }
                counts[clean.lowercased(), default: 0] += 1
            }
        }
        return counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.map(\.key)
    }

    /// "07:30" as minutes after midnight.
    static func minute(of clock: String) -> Int? {
        let parts = clock.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, (0..<24).contains(parts[0]), (0..<60).contains(parts[1]) else { return nil }
        return parts[0] * 60 + parts[1]
    }
}

extension TodayRecoveryBreakdown {
    /// The TodayKit view of an AnalyticsKit split.
    nonisolated init(_ split: RecoveryDecomposition) {
        self.init(
            score: split.score,
            isSaturated: split.isSaturated,
            isMeaningful: split.isMeaningful,
            inputs: split.signals.map { share in
                let signal: TodayRecoveryBreakdown.Signal = switch share.signal {
                case .hrv: .hrv
                case .restingHeartRate: .restingHeartRate
                case .respiratoryRate: .respiratoryRate
                }
                let status: TodayRecoveryBreakdown.InputStatus = switch share.status {
                case .used: .used
                case .noReading: .noReading
                case .learning(let have, let need): .learning(have: have, need: need)
                case .flatBaseline: .flatBaseline
                }
                return TodayRecoveryBreakdown.Input(
                    signal: signal, status: status, value: share.value, usual: share.usual,
                    baselineNights: share.baselineNights, weight: share.nominalWeight,
                    contribution: share.contribution, points: share.points
                )
            },
            nightsNeeded: split.nightsNeeded
        )
    }
}

@MainActor
enum TodayContextSourceFactory {
    /// Production reads the stores; fixture launches read the coherent
    /// fixture history so the populated Today tells the same story as the
    /// metric pages.
    static func make(environment: AppEnvironment, repositories: ProductRepositoryContainer?) -> (any TodayContextRepository)? {
        #if DEBUG
        if DebugCaptureFixtures.siMorningMode != nil { return SIMorningContextRepository() }
        #endif
        let alarmController = WakeAlarmControllerFactory.make(repositories: repositories)
        let alarm: @Sendable () async -> Int? = { @Sendable [alarmController] in
            guard let alarmController else { return nil }
            let snapshot = await alarmController.snapshot()
            guard snapshot.isOn else { return nil }
            return snapshot.configuration?.guaranteedMinute
        }
        if let persistent = repositories?.persistent {
            let sleep = persistent.sleep
            let body = persistent.body
            let journal = persistent.journal
            let heart = persistent.heart
            return LooprTodayContextSource(
                history: LooprMetricHistory.shared,
                timeZone: environment.timeZoneProvider.timeZone,
                sleepDay: { @Sendable [sleep] day in try? await sleep.readSleepDay(for: day) },
                bodyDay: { @Sendable [body] day in try? await body.readBodyDay(for: day) },
                journalEntries: { @Sendable [journal] days in
                    var entries: [JournalEntry] = []
                    for day in days { entries += await journal.search(JournalSearchQuery(day: day)) }
                    return entries
                },
                alarmMinute: alarm,
                overnightAssessment: { @Sendable [heart] day in
                    try? await heart.readHeartDay(for: day)?.vitals?.assessment
                },
                temperatureMissingReason: { @Sendable [heart] day in
                    try? await heart.readHeartDay(for: day)?.vitals?.skinTemperature.missingReason
                }
            )
        }
        #if DEBUG
        guard repositories?.isFixtureComposition ?? (environment.composition != .production) else { return nil }
        let populated = environment.composition == .populated || environment.composition == .activeWorkout
            || environment.composition == .connectedMixedCapabilities
        guard populated else { return nil }
        if environment.composition == .populated { return SIMorningContextRepository(mode: "good") }
        return LooprTodayContextSource(
            history: FixtureMetricHistoryProvider(),
            timeZone: .current,
            sleepDay: { @Sendable _ in SleepFixtures.populated },
            bodyDay: { @Sendable _ in BodyFixtures.populated },
            journalEntries: { @Sendable _ in [] },
            alarmMinute: alarm,
            overnightAssessment: { @Sendable day in DebugCaptureFixtures.siVitalsAssessment(day: day) }
        )
        #else
        return nil
        #endif
    }
}
