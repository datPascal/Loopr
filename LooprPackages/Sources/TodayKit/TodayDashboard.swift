import Foundation
import AnalyticsKit
import DomainKit
import DesignSystem

// MARK: - Presentation models

/// A recovery score ready to draw: the band, the one-word verdict and the
/// sentence that names the biggest driver.
public struct TodayRecoveryReading: Equatable, Sendable {
    public let score: Double
    public let band: LooprRecoveryBand
    /// "HRV is 12% above your usual.", or "Your overnight signals are close
    /// to your usual." when nothing stands out.
    public let driver: String
    /// "A good day to push." Nil on a past day.
    public let guidance: String?
    public let earlyEstimate: String?

    public init(score: Double, band: LooprRecoveryBand, driver: String, guidance: String?, earlyEstimate: String? = nil) {
        self.score = score
        self.band = band
        self.driver = driver
        self.guidance = guidance
        self.earlyEstimate = earlyEstimate
    }

    /// "HRV is 12% above your usual. A good day to push."
    public var sentence: String { [driver, guidance].compactMap { $0 }.joined(separator: " ") }

    public var text: String { String(format: "%.0f", score) }
}

/// What the recovery hero shows.
public enum TodayHeroState: Equatable, Sendable {
    /// The day's own score.
    case scored(TodayRecoveryReading)
    /// Today has no score yet, so the latest earlier score is shown, stamped
    /// with its day. Strain and sleep never carry.
    case carried(TodayRecoveryReading, dayLabel: String, reason: String)
    /// Today has data but last night has not arrived yet.
    case calculating(title: String, detail: String)
    /// Not enough earlier nights to compare with.
    case learning(have: Int, need: Int, detail: String)
    /// No score for a reason the person can read.
    case unavailable(title: String, detail: String)

    public var reading: TodayRecoveryReading? {
        switch self {
        case .scored(let reading), .carried(let reading, _, _): reading
        default: nil
        }
    }
}

extension LooprDelta {
    /// Rings and tiles stay quiet while a usual range is still building; the
    /// hero explains recovery learning once.
    var unlessLearning: LooprDelta? {
        if case .learning = kind { return nil }
        return self
    }
}

/// One of the three secondary rings.
public struct TodayRingItem: Equatable, Sendable, Identifiable {
    public let id: TodayMetricID
    public let caption: String
    public let text: String
    let reading: TodayRingReading
    public let accent: LooprColorToken
    public let delta: LooprDelta?
    public let needsAge: Bool
    /// Strain and Stress while the day has too little wear for a number, as
    /// "23 of 60 min worn". Nil once the ring has a reading.
    public let settlingCaption: String?
    /// Strain only: the range that suits today's recovery, on the 0 to 21 scale.
    public let suggestedRange: ClosedRange<Double>?
}

/// A pinned "Your numbers" tile.
public struct TodayNumberTile: Equatable, Sendable, Identifiable {
    public let metric: TodayTrackedMetric
    public let value: String?
    public let unit: String?
    public let delta: LooprDelta?
    public let detail: String?

    public var id: String { metric.rawValue }
}

/// The card that appears when two or more overnight signals sit outside the
/// usual range in the unwanted direction.
public struct TodayHeadsUp: Equatable, Sendable {
    public struct Signal: Equatable, Sendable, Identifiable {
        public let metric: OvernightVitalMetric
        /// "Resting HR +6 bpm"
        public let text: String
        public let spoken: String
        public var id: String { metric.rawValue }
    }

    public let title: String
    public let detail: String
    public let signals: [Signal]
    /// Journal entries from the evening before and the day.
    public let factors: [String]
}

/// Tonight's bedtime line.
public struct TodayTonightPlan: Equatable, Sendable {
    /// "Asleep by 23:10"
    public let title: String
    /// "That gives you the 7 h 50 m you need before your 07:00 alarm."
    public let detail: String
}

/// The coach line, only when the coach has something to say.
public struct TodayCoachLine: Equatable, Sendable {
    public let title: String
    public let detail: String
}

/// Everything the Today screen draws for one day, built once per change of
/// summary, context or pinned metrics. All the rules live here so they can be
/// tested without a view.
public struct TodayDashboard: Equatable, Sendable {
    public let hero: TodayHeroState
    public let rings: [TodayRingItem]
    public let headsUp: TodayHeadsUp?
    public let tiles: [TodayNumberTile]
    public let tonight: TodayTonightPlan?
    public let coach: TodayCoachLine?
    public let contributors: [TodayMorningContributor]
    public let morningSignals: TodayMorningSignals
    public let morningSignalsSubtitle: String?

    public init(
        summary: TodaySummary,
        context: TodayDayContext?,
        pinned: [TodayTrackedMetric],
        isToday: Bool,
        headsUpDismissed: Bool = false,
        dayLabel: (Date) -> String = TodayDashboard.shortDayLabel,
        calendar: Calendar = .current
    ) {
        let values = TodayValues(summary: summary, context: context, calendar: calendar)
        hero = TodayHeroRules.hero(summary: summary, context: context, values: values, isToday: isToday,
                                   dayLabel: dayLabel, calendar: calendar)
        rings = TodayDashboard.rings(summary: summary, values: values, context: context)
        headsUp = headsUpDismissed ? nil : TodayHeadsUpRules.evaluate(values: values, context: context)
        tiles = pinned.map { metric in
            let value = values.value(metric)
            let formatted = value.map(metric.formatted)
            return TodayNumberTile(metric: metric, value: formatted?.value, unit: formatted?.unit,
                                   delta: values.delta(metric, withinRange: .word),
                                   detail: value == nil ? "Sync your band to see this reading." : nil)
        }
        tonight = isToday ? TodayTonightRules.plan(TodayTonightInputs(
            needMinutes: TodaySleepNeed.minutes(from: summary.goals),
            alarmMinute: context?.tonight?.alarmMinute,
            suggestedWakeMinute: context?.tonight?.suggestedWakeMinute)) : nil
        coach = nil
        contributors = TodayDashboard.contributors(values: values, context: context, calendar: calendar)
        morningSignals = TodayMorningSignals(rows: contributors,
            stale: TodayHeroRules.staleDays(values: values, context: context, isToday: isToday, calendar: calendar) != nil)
        morningSignalsSubtitle = morningSignals.subtitle(hasRecovery: hero.reading != nil)
    }

    /// "Wed 23 Sep"
    public static func shortDayLabel(_ date: Date) -> String {
        var style = Date.FormatStyle().weekday(.abbreviated).day(.defaultDigits).month(.abbreviated)
        style.locale = Locale(identifier: "en_GB")
        return date.formatted(style).replacingOccurrences(of: ",", with: "")
    }

    static func coachLine(_ slot: TodayCoachPlanSlot) -> TodayCoachLine? {
        guard case .plan(let plan) = slot, plan.recommendationCount > 0,
              plan.state != .absent, plan.state != .noRecords,
              !plan.title.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return TodayCoachLine(title: plan.title, detail: plan.detail)
    }

    /// The settling caption as VoiceOver should say it.
    static func spokenSettling(_ caption: String) -> String {
        caption.replacingOccurrences(of: " min worn", with: " minutes worn")
    }

    static func missingRingCaption(_ id: TodayMetricID, metric: TodayMetricValue?) -> String {
        if let caption = metric?.confidence?.trimmingCharacters(in: .whitespacesAndNewlines), !caption.isEmpty { return caption }
        switch id {
        case .stress: return "No clean heart data today"
        case .strain: return "Wear your band for 60 minutes today"
        case .sleep: return "Sync after your next night"
        default: return "Sync your band to see this reading"
        }
    }

    static func rings(summary: TodaySummary, values: TodayValues, context: TodayDayContext?) -> [TodayRingItem] {
        let specs: [(TodayMetricID, String, LooprColorToken, TodayTrackedMetric)] = [
            (.sleep, "Sleep", .sleep, .sleep),
            (.strain, "Strain", .strain, .strain),
            (.stress, "Stress", .stress, .stress)
        ]
        return specs.map { id, caption, accent, tracked in
            let metric = summary.metric(id)
            let reading = TodayRingReading.reading(for: id, metric: metric, summary: summary)
            let text: String = {
                guard let value = reading.value else { return "—" }
                switch id {
                case .sleep: return LooprRingNumberFormat.hoursMinutes.text(for: value)
                case .strain: return String(format: "%.1f", value)
                default: return String(format: "%.0f", value)
                }
            }()
            return TodayRingItem(
                id: id, caption: caption, text: text, reading: reading, accent: accent,
                delta: reading.value.flatMap { value in
                    if id == .sleep {
                        let difference = value - TodayRingReading.sleepReference(in: summary).minutes
                        return LooprDelta(kind: .change(difference), isOutsideUsual: difference < -60,
                                          higherIsBetter: true, format: .duration, reference: "need")
                    }
                    return values.delta(tracked, withinRange: .word)
                },
                needsAge: id == .strain && reading.value == nil
                    && metric?.confidence?.localizedCaseInsensitiveContains("add your age") == true,
                settlingCaption: reading.value == nil ? missingRingCaption(id, metric: metric) : nil,
                suggestedRange: id == .strain ? context?.suggestedStrainRange : nil
            )
        }
    }
}

// MARK: - Values and "vs usual"

/// The day's numbers, from the summary first and the history second, and the
/// usual range for each.
struct TodayValues {
    let summary: TodaySummary
    let context: TodayDayContext?
    let calendar: Calendar

    var recoveryMetric: TodayMetricValue? {
        [TodayMetricID.recovery, .readiness].compactMap { summary.metric($0) }.first {
            $0.state != .absent && $0.state != .noRecords && $0.numericUnit == .scorePoints && $0.numericValue != nil
        }
    }

    func value(_ metric: TodayTrackedMetric) -> Double? {
        if let assessment = vital(metric) { return assessment.value }
        if let fromSummary = summaryValue(metric) { return fromSummary }
        return context?.value(metric, calendar: calendar)
    }

    private func summaryValue(_ metric: TodayTrackedMetric) -> Double? {
        func number(_ ids: [TodayMetricID], _ unit: TodayMetricUnitID) -> Double? {
            for id in ids {
                guard let value = summary.metric(id), value.state != .absent, value.state != .noRecords,
                      value.numericUnit == unit, let number = value.numericValue else { continue }
                return number
            }
            return nil
        }
        switch metric {
        case .hrv: return number([.hrv], .milliseconds)
        case .restingHeartRate: return number([.restingHeartRate, .heart], .beatsPerMinute)
        case .sleep: return number([.sleep], .minutes)
        case .recovery: return recoveryMetric?.numericValue
        case .strain: return number([.strain], .strainScore)
        case .stress: return number([.stress], .scorePoints)
        case .steps: return number([.steps], .count)
        case .activeEnergy: return number([.calories], .kilocalories)
        case .respiratoryRate, .sleepEfficiency, .deepSleep, .remSleep: return nil
        }
    }

    func vital(_ metric: TodayTrackedMetric) -> OvernightVitalAssessment? {
        let id: OvernightVitalMetric? = switch metric {
        case .hrv: .heartRateVariability
        case .restingHeartRate: .restingHeartRate
        case .respiratoryRate: .respiratoryRate
        default: nil
        }
        return context?.overnightAssessment?.signals.first { $0.metric == id }
    }

    func usual(_ metric: TodayTrackedMetric) -> LooprBaselineBand? {
        if let assessment = vital(metric) {
            return assessment.usualRange.map { LooprBaselineBand(center: $0.median, lower: $0.low, upper: $0.high, measuredDays: $0.nights) }
        }
        return context?.usual(metric, calendar: calendar)
    }

    func delta(_ metric: TodayTrackedMetric, withinRange: LooprDelta.WithinRange) -> LooprDelta? {
        guard let value = value(metric) else { return nil }
        if let assessment = vital(metric) {
            if let change = assessment.delta {
                return LooprDelta(kind: .change(change), isOutsideUsual: assessment.outlier != nil,
                    higherIsBetter: metric.higherIsBetter, unit: metric.unit ?? "", format: metric.deltaFormat)
            }
            return .learning(assessment.scorableNights, of: assessment.requiredNights, noun: metric.learningNoun)
        }
        let learning = context.map { ($0.measuredDaysBefore(metric, calendar: calendar) + 1, LooprBaselineBand.minimumDays) }
        return LooprDelta.compare(value, usual: usual(metric), higherIsBetter: metric.higherIsBetter,
                                  unit: metric.unit ?? "", format: metric.deltaFormat, withinRange: withinRange,
                                  learning: learning, learningNoun: metric.learningNoun)
    }

}

// MARK: - Hero rules

enum TodayHeroRules {
    static let carryWindowDays = 3

    static func staleDays(values: TodayValues, context: TodayDayContext?, isToday: Bool, calendar: Calendar) -> Int? {
        guard isToday, values.value(.sleep) == nil, let context,
              let latest = context.history[.sleep]?.last(where: { $0.date < context.dayStart }) else { return nil }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: latest.date), to: context.dayStart).day ?? 0
        return days > carryWindowDays ? days : nil
    }

    static func hero(summary: TodaySummary, context: TodayDayContext?, values: TodayValues, isToday: Bool,
                     dayLabel: (Date) -> String, calendar: Calendar) -> TodayHeroState {
        let recovery = values.value(.recovery)
        let breakdown = context?.recovery
        if let recovery, let band = LooprRecoveryBand(score: recovery) {
            let generated = TodayRecoverySentence.make(band: band, score: recovery, breakdown: breakdown,
                                                   values: values, isToday: isToday)
            let imported = values.recoveryMetric?.source == "Account export"
            let driver = imported ? "From your account export" : context == nil ? summary.headline ?? generated : generated
            let count = breakdown?.inputs.filter { $0.status == .used }.map { $0.baselineNights + 1 }.min()
            let early = count.flatMap { $0 < 14 ? "Early estimate · " + LooprLearningText.progress(have: $0, need: 14) : nil }
                ?? summary.metric(.recovery)?.confidence.flatMap { $0.hasPrefix("Early estimate") ? $0 : nil }
            let target = context?.strainTarget ?? StrainTarget(recovery: recovery)
            return .scored(TodayRecoveryReading(score: recovery, band: band, driver: driver,
                guidance: isToday ? TodayMorningSentence.plan(range: context?.suggestedStrainRange ?? target?.range,
                    adjustment: target?.adjustment) : nil, earlyEstimate: imported ? nil : early))
        }
        let hasNight = values.value(.sleep) != nil
        if isToday, !hasNight {
            if let days = staleDays(values: values, context: context, isToday: isToday, calendar: calendar) {
                return .unavailable(title: "Waiting for a new night", detail: LooprLearningText.stale(days: days) + " Check the connection, then sync your band.")
            }
            if let context, let carried = context.latestBefore(.recovery, withinDays: carryWindowDays, calendar: calendar),
               let band = LooprRecoveryBand(score: carried.value) {
                let label = TodayHeroRules.relativeLabel(carried.date, dayStart: context.dayStart, calendar: calendar, fallback: dayLabel)
                return .carried(
                    TodayRecoveryReading(score: carried.value, band: band, driver: band.guidance, guidance: nil),
                    dayLabel: label,
                    reason: label == "Yesterday"
                        ? "Last night hasn't synced yet, so this is yesterday's score."
                        : "Last night hasn't synced yet, so this is the score from \(label)."
                )
            }
            return .calculating(
                title: "Waiting for last night",
                detail: "Recovery appears once your band syncs last night's sleep."
            )
        }
        if let learning = learningState(summary: summary, breakdown: breakdown) {
            let nights = LooprLearningText.remaining(have: learning.have, need: learning.need)
            let reason = stuckReason(context: context, calendar: calendar)
                ?? "\(nights) before recovery can start. It needs at least two usable heart readings and compares them with your own nights."
            return .learning(have: learning.have, need: learning.need, detail: reason)
        }
        if breakdown?.isSaturated == true || summaryIsSaturated(summary) {
            return .unavailable(
                title: "Waiting for more history",
                detail: "This night is too far from your recent readings to score reliably. Sync after another night."
            )
        }
        if !hasNight {
            return .unavailable(
                title: "No sleep recorded",
                detail: "Recovery needs a night with the band on. There is no sleep for this day."
            )
        }
        if values.value(.hrv) == nil {
            return .unavailable(
                title: "No HRV last night",
                detail: "Recovery needs at least two usable overnight heart readings. A snug fit tonight helps the band read them."
            )
        }
        return .unavailable(title: "Not enough overnight readings", detail: "Recovery needs at least two usable heart readings with three earlier nights each. Sync after your next night.")
    }

    /// Prefer the structured split; old summaries keep their saved countdown.
    static func learningState(summary: TodaySummary, breakdown: TodayRecoveryBreakdown?) -> (have: Int, need: Int)? {
        let need = breakdown?.nightsNeeded ?? 3
        if let breakdown, breakdown.score == nil, !breakdown.isSaturated,
           breakdown.inputs.contains(where: { if case .learning = $0.status { true } else { false } }),
           breakdown.inputs.filter({ $0.status == .used }).count < 2 {
            return (min(breakdown.nightsSoFar + 1, need + 1), need + 1)
        }
        let metric = summary.metric(.recovery) ?? summary.metric(.readiness)
        if let text = metric?.confidence {
            let parts = text.split(separator: " ")
            if parts.count >= 4, parts[1] == "of", parts[3].hasPrefix("nights"),
               let have = Int(parts[0]), let need = Int(parts[2]), have >= 0, need > have {
                return (have, need)
            }
        }
        if let text = metric?.confidence, let remaining = remainingNights(in: text) {
            return (max(0, need - remaining), need)
        }
        return nil
    }

    /// Reads "2 more nights and this is ready" / "One more night and this is ready".
    static func remainingNights(in text: String) -> Int? {
        let lower = text.lowercased()
        guard lower.contains("more night") else { return nil }
        if lower.hasPrefix("one more night") { return 1 }
        let digits = lower.prefix { $0.isNumber }
        return Int(digits)
    }

    static func summaryIsSaturated(_ summary: TodaySummary) -> Bool {
        let metric = summary.metric(.recovery) ?? summary.metric(.readiness)
        let text = metric?.confidence?.lowercased() ?? ""
        return text.contains("too alike") || text.contains("too far from your recent readings")
    }

    /// Why the count is not moving: recent nights with sleep but no HRV.
    static func stuckReason(context: TodayDayContext?, calendar: Calendar) -> String? {
        guard let context,
              let start = calendar.date(byAdding: .day, value: -7, to: context.dayStart) else { return nil }
        func days(_ metric: TodayTrackedMetric) -> Set<Date> {
            Set((context.history[metric] ?? []).filter { $0.date >= start && $0.date <= context.dayStart }
                .map { calendar.startOfDay(for: $0.date) })
        }
        let sleepNights = days(.sleep)
        let missing = sleepNights.subtracting(days(.hrv)).count
        guard sleepNights.count >= 2, missing >= 2 else { return nil }
        return "\(missing) of your last \(sleepNights.count) nights had sleep but no HRV reading. A snug fit overnight lets the band read it."
    }

    static func relativeLabel(_ date: Date, dayStart: Date, calendar: Calendar, fallback: (Date) -> String) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: dayStart).day ?? 0
        return days == 1 ? "Yesterday" : fallback(date)
    }
}

// MARK: - The driver sentence

/// One deterministic sentence that names the biggest driver of the score,
/// then the band's guidance: "HRV is 12% above your usual. A good day to push."
enum TodayRecoverySentence {
    /// The driver clause alone; the band's guidance is added by the reading.
    static func make(band: LooprRecoveryBand, score: Double, breakdown: TodayRecoveryBreakdown?,
                     values: TodayValues, isToday: Bool) -> String {
        let exact = breakdown.flatMap { $0.explains(score) && $0.isMeaningful ? $0 : nil }
        let drivers = (exact?.inputs ?? []).compactMap { input -> TodayMorningSentence.Driver? in
            let metric = input.signal.metric
            guard input.status == .used, let contribution = input.contribution,
                  let printed = values.value(metric), let source = input.value,
                  abs(printed - source) < 0.01 else { return nil }
            let assessment = values.context?.overnightAssessment?.signals.first {
                switch input.signal {
                case .hrv: $0.metric == .heartRateVariability
                case .restingHeartRate: $0.metric == .restingHeartRate
                case .respiratoryRate: $0.metric == .respiratoryRate
                }
            }
            let change = assessment?.delta ?? (values.usual(metric)?.center ?? input.usual).map { printed - $0 }
            guard let change else { return nil }
            let signal: TodayMorningSentence.Signal = switch input.signal {
            case .hrv: .hrv
            case .restingHeartRate: .restingHeartRate
            case .respiratoryRate: .breathing
            }
            return .init(signal: signal, change: change, contribution: contribution)
        }
        return TodayMorningSentence.make(score: score, drivers: drivers,
            sleepMinutes: values.value(.sleep), sleepNeed: values.summary.sleepNeedMinutes)
    }

}

// MARK: - Heads-up

enum TodayHeadsUpRules {
    static func evaluate(values: TodayValues, context: TodayDayContext?) -> TodayHeadsUp? {
        guard let assessment = context?.overnightAssessment, assessment.isFlagged else { return nil }
        let signals = assessment.outliers.map { outlier in
            let metric = outlier.metric
            let digits = metric == .respiratoryRate || metric == .skinTemperatureDeviation ? 1 : 0
            let unit: String = switch metric {
            case .restingHeartRate: "bpm"
            case .heartRateVariability: "ms"
            case .respiratoryRate: "br/min"
            case .skinTemperatureDeviation: "°C"
            case .oxygenSaturation: "%"
            }
            let delta = outlier.value - outlier.range.median
            let direction = outlier.direction == .higher ? "above" : "below"
            return TodayHeadsUp.Signal(metric: metric,
                text: "\(metric.name) \(LooprUnitFormatter.signed(delta, digits: digits) ?? "") \(unit)",
                spoken: "\(metric.name) \(LooprUnitFormatter.number(abs(delta), digits: digits) ?? "") \(unit) \(direction) your usual")
        }
        let factors = (context?.journalFactors ?? []).prefix(4).map { $0.prefix(1).uppercased() + $0.dropFirst() }
        return TodayHeadsUp(title: LooprSignalFormatting.outsideRangeHeadline(count: signals.count),
            detail: "Alcohol, late meals, a hot room, hard training or travel can move these readings. Illness can too. Take it easy and see how tonight compares.",
            signals: signals, factors: Array(factors))
    }
}

// MARK: - Tonight

enum TodayTonightRules {
    static func plan(_ inputs: TodayTonightInputs) -> TodayTonightPlan? {
        guard let need = inputs.needMinutes, need.isFinite, need > 0,
              let wake = inputs.alarmMinute ?? inputs.suggestedWakeMinute else { return nil }
        // Round to five minutes: nobody plans a bedtime of 23:07.
        let raw = Double(wake) - need
        let rounded = Int((raw / 5).rounded()) * 5
        let bed = ((rounded % 1_440) + 1_440) % 1_440
        let needText = LooprUnitFormatter.duration(minutes: need) ?? ""
        let wakeText = clock(wake)
        let ending = inputs.alarmMinute != nil
            ? "before your \(wakeText) alarm."
            : "before \(wakeText), when you usually wake."
        return TodayTonightPlan(title: "Asleep by \(clock(bed))",
                                detail: "That gives you the \(needText) you need \(ending)")
    }

    static func clock(_ minute: Int) -> String {
        let value = ((minute % 1_440) + 1_440) % 1_440
        return String(format: "%02d:%02d", value / 60, value % 60)
    }
}
