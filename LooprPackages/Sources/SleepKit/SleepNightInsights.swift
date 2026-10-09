import Foundation
import DomainKit
import DesignSystem

/// One sleep stage on the tab: minutes, share and where it sits against the
/// usual range of recent nights.
public struct SleepStageSummary: Equatable, Sendable, Identifiable {
    public let stage: SleepStage
    public let minutes: Double
    /// Whole percent. Deep, REM and Light share the time asleep and add up to
    /// exactly 100; Awake is a share of the whole night.
    public let percent: Int
    public let usual: SleepUsual
    public var id: SleepStage { stage }

    /// More deep and REM sleep is the better direction, less awake time is;
    /// light sleep has no good direction.
    public var higherIsBetter: Bool? {
        switch stage {
        case .deep, .rem: true
        case .awake: false
        case .light: nil
        }
    }

    public var delta: LooprDelta? {
        usual.delta(for: minutes, higherIsBetter: higherIsBetter, format: .duration)
    }

    public var shareText: String { stage == .awake ? "\(percent)% of the night" : "\(percent)%" }

    /// "Usual 1 h 5 m to 1 h 20 m", or nil while learning.
    public var usualText: String? {
        guard let range = usual.range else { return nil }
        let low = LooprUnitFormatter.duration(minutes: range.lower) ?? ""
        let high = LooprUnitFormatter.duration(minutes: range.upper) ?? ""
        return low == high ? "Usual \(low)" : "Usual \(low) to \(high)"
    }

    public var accessibilitySummary: String {
        var parts = ["\(stage.title), \(LooprUnitFormatter.spokenDuration(minutes: minutes) ?? ""), \(percent) percent"]
        if let delta { parts.append(delta.spokenText) }
        return parts.joined(separator: ", ")
    }
}

/// One of the remaining rows (efficiency, wake-ups, breathing rate, cycles).
public struct SleepDetailRow: Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let value: Double?
    public let valueText: String?
    public let unit: String?
    public let usual: SleepUsual?
    public let higherIsBetter: Bool?
    public let format: LooprDeltaFormat
    /// The metric page the row opens, when there is one.
    public let metricLinkID: String?

    public var delta: LooprDelta? {
        usual?.delta(for: value, higherIsBetter: higherIsBetter, unit: unit ?? "", format: format, withinRange: .signed)
    }
}

/// A bedtime to aim for tonight.
public struct SleepTonightPlan: Equatable, Sendable {
    /// Minutes after noon (see `SleepClock`).
    public let bedtime: Double
    public let usualWake: Double
    public let sleepMinutes: Double
    public let extraMinutes: Double
    public let timeZone: TimeZone

    /// Needs three recent wake times.
    public static let minimumNights = 3

    /// Whether the wake time is the suggested alarm rather than your usual wake.
    public let wakeIsSuggestedAlarm: Bool

    /// - Parameter suggestedWake: The suggested alarm (`HH:mm`), when there
    ///   is one. The bedtime then counts back from it, so the bedtime and the
    ///   alarm card next to it tell the same story.
    public init?(consistency: SleepConsistency, target: SleepTarget, ledger: SleepDebtLedger, suggestedWake: String? = nil) {
        let wakes = consistency.measured.compactMap(\.wake)
        guard wakes.count >= Self.minimumNights else { return nil }
        let suggested = suggestedWake.flatMap(Self.minutesAfterNoon(clock:))
        guard let usualWake = suggested ?? SleepUsualRange.percentile(wakes, 50) else { return nil }
        wakeIsSuggestedAlarm = suggested != nil
        var extra = 0.0
        if case .behind(_, let perNight) = ledger.suggestion { extra = perNight }
        let sleep = target.minutes + extra
        let bedtime = usualWake - sleep
        guard bedtime > 0 else { return nil }
        self.bedtime = bedtime
        self.usualWake = usualWake
        sleepMinutes = sleep
        extraMinutes = extra
        timeZone = consistency.timeZone
    }

    /// "07:30" as minutes after noon, or nil for anything else.
    static func minutesAfterNoon(clock: String) -> Double? {
        let parts = clock.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, (0..<24).contains(parts[0]), (0..<60).contains(parts[1]) else { return nil }
        let minutes = Double(parts[0] * 60 + parts[1])
        return (minutes - 720 + SleepClock.minutesPerDay).truncatingRemainder(dividingBy: SleepClock.minutesPerDay)
    }

    public var bedtimeText: String { SleepClock.text(minutesAfterNoon: bedtime, timeZone: timeZone) }

    /// "Aim to be asleep by 23:05."
    public var headline: String { "Aim to be asleep by \(bedtimeText)" }

    /// "That gives 7 h 50 m before your usual 06:55 wake, with 20 min to make up."
    public var detail: String {
        let sleep = LooprUnitFormatter.duration(minutes: sleepMinutes) ?? ""
        let wake = SleepClock.text(minutesAfterNoon: usualWake, timeZone: timeZone)
        let base = wakeIsSuggestedAlarm
            ? "That gives \(sleep) before the suggested \(wake) alarm"
            : "That gives \(sleep) before your usual \(wake) wake"
        guard extraMinutes > 0, let extra = LooprUnitFormatter.duration(minutes: extraMinutes) else { return base + "." }
        return base + ", including \(extra) to make up."
    }
}

/// Everything the Sleep tab shows beyond the snapshot itself, worked out
/// once per loaded night (never while drawing).
public struct SleepNightInsights: Equatable, Sendable {
    /// Rows the tab never shows: they have their own sections, or the
    /// derivation cannot measure them yet (sleep QA on real nights: time to
    /// first REM is 0 on every night and time to fall asleep is measured from
    /// a stillness onset, so it reads 0 to 3 minutes).
    public static let hiddenRowIDs: Set<String> = [
        "duration", "deep", "rem", "light", "awake", "need", "debt", "regularity", "score",
        "latency", "remLatency"
    ]

    public let history: SleepNightHistory
    public let target: SleepTarget
    public let durationUsual: SleepUsual
    public let stages: [SleepStageSummary]
    public let ledger: SleepDebtLedger
    public let consistency: SleepConsistency
    public let rows: [SleepDetailRow]
    public let tonight: SleepTonightPlan?

    public init(snapshot: SleepDaySnapshot, goalMinutes: Double? = nil, calendar: Calendar = .current) {
        let history = SleepNightHistory(trend: snapshot.trend, day: snapshot.day)
        self.history = history
        let target = SleepTarget.resolve(needHours: snapshot.needHours, goalMinutes: goalMinutes, history: history)
        self.target = target
        durationUsual = SleepUsual.ofDuration(in: history)
        stages = Self.stages(snapshot: snapshot, history: history)
        let ledger = SleepDebtLedger(history: history, target: target, calendar: calendar)
        self.ledger = ledger
        let consistency = SleepConsistency(history: history, calendar: calendar)
        self.consistency = consistency
        rows = Self.rows(snapshot: snapshot, history: history)
        tonight = SleepTonightPlan(consistency: consistency, target: target, ledger: ledger,
                                   suggestedWake: snapshot.suggestedAlarm?.localTime)
    }

    /// One line for a section whose every row is still learning its usual
    /// range, so the rows need not repeat it. Nil when any row has a range.
    public static func learningNote(_ usuals: [SleepUsual]) -> String? {
        guard !usuals.isEmpty else { return nil }
        var measured = 0
        var needed = SleepUsualRange.minimumNights
        for usual in usuals {
            guard case .learning(let count, let required) = usual else { return nil }
            measured = max(measured, count)
            needed = required
        }
        let sofar = measured == 0 ? "None yet." : measured == 1 ? "You have 1 so far." : "You have \(measured) so far."
        return "Usual ranges appear after \(needed) nights. \(sofar)"
    }

    /// The stage minutes shown on the tab, for the timeline's readout.
    public var stageTotals: [SleepStage: Double] {
        Dictionary(stages.map { ($0.stage, $0.minutes) }, uniquingKeysWith: { first, _ in first })
    }

    /// Deep, REM, Light and Awake in the order a night is read. Minutes come
    /// from the night's stage totals, the same numbers the metric pages keep;
    /// the hypnogram fills in when a total is missing.
    static func stages(snapshot: SleepDaySnapshot, history: SleepNightHistory) -> [SleepStageSummary] {
        guard snapshot.mainSleep != nil else { return [] }
        var hypnogram: [SleepStage: Double] = [:]
        for segment in snapshot.hypnogram where segment.durationMinutes > 0 {
            hypnogram[segment.stage, default: 0] += Double(segment.durationMinutes)
        }
        let ids: [(SleepStage, String)] = [(.deep, "deep"), (.rem, "rem"), (.light, "light"), (.awake, "awake")]
        var minutes: [SleepStage: Double] = [:]
        for (stage, id) in ids {
            let metric = snapshot.metric(id)
            if let metric, metric.state != .absent, let value = metric.numericValue, value.isFinite, value >= 0 {
                minutes[stage] = value
            } else if let value = hypnogram[stage] {
                minutes[stage] = value
            }
        }
        guard minutes.values.contains(where: { $0 > 0 }) else { return [] }
        let asleepStages: [SleepStage] = [.deep, .rem, .light]
        let shares = largestRemainderPercents(asleepStages.map { minutes[$0] ?? 0 })
        let inBed = minutes.values.reduce(0, +)
        return ids.compactMap { stage, id in
            guard let value = minutes[stage] else { return nil }
            let percent: Int
            if let index = asleepStages.firstIndex(of: stage) {
                percent = shares[index]
            } else {
                percent = inBed > 0 ? Int((value / inBed * 100).rounded()) : 0
            }
            return SleepStageSummary(stage: stage, minutes: value, percent: percent, usual: SleepUsual.of(id, in: history))
        }
    }

    /// Whole percents that add up to exactly 100 (largest remainder method),
    /// or all zero when nothing was measured.
    public static func largestRemainderPercents(_ values: [Double]) -> [Int] {
        let clean = values.map { $0.isFinite && $0 > 0 ? $0 : 0 }
        let total = clean.reduce(0, +)
        guard total > 0 else { return clean.map { _ in 0 } }
        let exact = clean.map { $0 / total * 100 }
        var floors = exact.map { Int($0.rounded(.down)) }
        let order = exact.indices.sorted { (exact[$0] - Double(floors[$0])) > (exact[$1] - Double(floors[$1])) }
        for index in order.prefix(100 - floors.reduce(0, +)) { floors[index] += 1 }
        return floors
    }

    /// The remaining rows, in a fixed order, then anything the derivation
    /// adds later with its own title and unit.
    static func rows(snapshot: SleepDaySnapshot, history: SleepNightHistory) -> [SleepDetailRow] {
        guard snapshot.mainSleep != nil else { return [] }
        var rows: [SleepDetailRow] = []
        func metricRow(_ id: String, title: String, unit: String?, higherIsBetter: Bool?, digits: Int, link: String?) {
            guard let metric = snapshot.metric(id) else { return }
            let value = metric.state == .absent ? nil : metric.numericValue
            rows.append(SleepDetailRow(id: id, title: title, value: value,
                                       valueText: value.flatMap { LooprUnitFormatter.number($0, digits: digits) },
                                       unit: unit, usual: SleepUsual.of(id, in: history), higherIsBetter: higherIsBetter,
                                       format: .number(digits: digits), metricLinkID: link))
        }
        metricRow("efficiency", title: "Efficiency", unit: "%", higherIsBetter: true, digits: 0, link: LooprMetricLinkID.sleepEfficiency)
        metricRow("disturbances", title: "Wake-ups", unit: nil, higherIsBetter: false, digits: 0, link: nil)
        if let breathing = history.current?.value(SleepTrendPoint.breathingRateID) {
            rows.append(SleepDetailRow(id: SleepTrendPoint.breathingRateID, title: "Breathing rate", value: breathing,
                                       valueText: LooprUnitFormatter.number(breathing, digits: 1), unit: "br/min",
                                       usual: SleepUsual.of(SleepTrendPoint.breathingRateID, in: history), higherIsBetter: nil,
                                       format: .number(digits: 1), metricLinkID: LooprMetricLinkID.respiratoryRate))
        }
        metricRow("cycles", title: "Estimated cycles", unit: nil, higherIsBetter: nil, digits: 0, link: nil)
        let known: Set<String> = hiddenRowIDs.union(["efficiency", "disturbances", "cycles"])
        for metric in snapshot.metrics where !known.contains(metric.id) {
            let value = metric.state == .absent ? nil : metric.numericValue
            rows.append(SleepDetailRow(id: metric.id, title: metric.title, value: value, valueText: metric.value,
                                       unit: metric.unit.isEmpty ? nil : metric.unit, usual: nil, higherIsBetter: nil,
                                       format: .number(digits: 0), metricLinkID: nil))
        }
        return rows
    }
}
