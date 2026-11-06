import DesignSystem
import Foundation

// MARK: - Centre

/// The morning centre: last night's time asleep, and the regularity line when it can be worked out.
public struct TodayDialAsleepCentre: Equatable, Sendable {
    public let minutes: Double
    public let hours: Int
    public let minutePart: Int
    /// "7 h 48 m"
    public let text: String
    /// "asleep · on time 6 nights running", or "asleep" while the streak cannot be worked out or is zero.
    public let caption: String
    /// Nights in a row, ending last night, whose bedtime was within half an hour of the reference bedtime. Nil while
    /// learning.
    public let onTimeNights: Int?
    public let provenance: TodayDialProvenance
}

/// The evening centre: time left until tonight's bedtime.
public struct TodayDialCountdown: Equatable, Sendable {
    public let bedtime: Date
    /// Real seconds between now and bedtime, never negative. Past bedtime it counts the time since.
    public let remaining: TimeInterval
    public let isPastBedtime: Bool
    /// "2:41"
    public let text: String
    /// "until bed at 22:30", or "past bed at 22:30".
    public let caption: String
    /// "22:30"
    public let bedtimeText: String
    public let provenance: TodayDialProvenance
    public let qualifier: String
}

public enum TodayDialCentre: Equatable, Sendable {
    case asleep(TodayDialAsleepCentre)
    case countdown(TodayDialCountdown)
    case absent(TodayDialAbsence)
}

// MARK: - Readouts

/// One of the three numbers under the dial.
public struct TodayDialReadout: Equatable, Sendable, Identifiable {
    public enum ID: String, Equatable, Sendable {
        case sleepHeartRate, regularity, recovery, lastMeal, zone2, steps
    }

    public enum Status: Equatable, Sendable {
        case measured
        /// Measured, or not yet measurable, with too few nights for a comparison.
        case learning(have: Int, need: Int)
        case absent(TodayDialGap)
    }

    public enum Tone: Equatable, Sendable {
        case neutral
        case good
        case recovery(LooprRecoveryBand)
    }

    public let id: ID
    public let title: String
    public let status: Status
    /// The number the readout counts up to. Nil for a clock time or when there is no value.
    public let number: Double?
    /// What it shows: "49", "18:20", "9,812". Nil when there is no value; the caption says why.
    public let text: String?
    public let caption: String?
    public let tone: Tone
    public let provenance: TodayDialProvenance
    /// The chip's qualifier, such as "last night".
    public let qualifier: String?
    /// Recovery opens "What shaped it" in one tap.
    public let opensWhatShapedIt: Bool

    init(id: ID, title: String, status: Status, number: Double? = nil, text: String? = nil, caption: String?,
         tone: Tone = .neutral, provenance: TodayDialProvenance, qualifier: String? = nil, opensWhatShapedIt: Bool = false) {
        self.id = id
        self.title = title
        self.status = status
        self.number = number
        self.text = text
        self.caption = caption
        self.tone = tone
        self.provenance = status.isAbsent ? .absent : provenance
        self.qualifier = qualifier
        self.opensWhatShapedIt = opensWhatShapedIt
    }
}

extension TodayDialReadout.Status {
    var isAbsent: Bool {
        if case .absent = self { true } else { false }
    }
}

/// The rules and words behind the centre and the readouts.
enum TodayDialReadoutRules {
    /// A bedtime within this many minutes of the reference counts as on time, the same half hour Sleep calls worth a
    /// line (`SleepConsistency.shiftWorthMentioning`).
    static let onTimeToleranceMinutes = 30.0

    // MARK: Centre

    static func asleep(minutes: Double, onTime: Int?, provenance: TodayDialProvenance) -> TodayDialAsleepCentre {
        let whole = Int(minutes.rounded())
        let caption = onTime.flatMap { $0 > 0 ? "asleep · \(onTimeStreak($0))" : nil } ?? "asleep"
        return TodayDialAsleepCentre(minutes: minutes, hours: whole / 60, minutePart: whole % 60,
                                     text: "\(whole / 60) h \(whole % 60) m", caption: caption, onTimeNights: onTime,
                                     provenance: provenance)
    }

    static func countdown(bedtime: TodayDialBedtime, now: Date, clock: TodayDialClock, locale: Locale) -> TodayDialCountdown {
        let seconds = bedtime.at.timeIntervalSince(now)
        let past = seconds < 0
        let bedText = TodayDialFormat.clock(bedtime.at, clock: clock, locale: locale)
        return TodayDialCountdown(bedtime: bedtime.at, remaining: abs(seconds), isPastBedtime: past,
                                  text: TodayDialFormat.hoursMinutes(abs(seconds)),
                                  caption: past ? "past bed at \(bedText)" : "until bed at \(bedText)", bedtimeText: bedText,
                                  provenance: bedtime.provenance, qualifier: bedtime.qualifier)
    }

    /// Nights in a row, ending with the newest, whose bedtime sits within half an hour of `reference`. Nil with fewer
    /// than `TodayDialRenderState.nightsNeeded` measured nights, or with no reference.
    ///
    /// The reference is the protocol's bedtime when there is one, otherwise the median bedtime of the nights given.
    static func onTimeNights(_ nights: [TodayDialNightTiming], ruleBedMinuteAfterNoon: Double?) -> Int? {
        let measured = nights.compactMap(\.bedMinuteAfterNoon).filter(\.isFinite)
        guard measured.count >= TodayDialRenderState.nightsNeeded,
              let reference = ruleBedMinuteAfterNoon ?? median(measured) else { return nil }
        var streak = 0
        for night in nights.reversed() {
            guard let bed = night.bedMinuteAfterNoon, bed.isFinite, abs(bed - reference) <= onTimeToleranceMinutes else { break }
            streak += 1
        }
        return streak
    }

    // MARK: Morning readouts

    static func sleepHeartRate(_ reading: TodayDialReading, before: [Double], locale: Locale) -> TodayDialReadout {
        let title = "Sleep heart rate"
        guard let value = reading.value else {
            return TodayDialReadout(id: .sleepHeartRate, title: title, status: .absent(reading.gap ?? .noData),
                                    caption: gapCaption(reading.gap ?? .noData), provenance: .absent)
        }
        let text = TodayDialFormat.integer(value, locale: locale)
        let prior = before.filter { $0.isFinite && $0 > 0 }
        let need = TodayDialRenderState.nightsNeeded
        guard prior.count >= need, let usual = median(prior) else {
            return TodayDialReadout(id: .sleepHeartRate, title: title, status: .learning(have: min(prior.count + 1, need), need: need),
                                    number: value, text: text, caption: "usual after \(need) nights",
                                    provenance: reading.provenance, qualifier: "last night")
        }
        let delta = Int((value - usual).rounded())
        let caption = delta < 0 ? "\(-delta) under usual" : delta > 0 ? "\(delta) over usual" : "at your usual"
        return TodayDialReadout(id: .sleepHeartRate, title: title, status: .measured, number: value, text: text, caption: caption,
                                tone: delta < 0 ? .good : .neutral, provenance: reading.provenance,
                                qualifier: "last night")
    }

    static func regularity(_ reading: TodayDialReading, nightsMeasured: Int, locale: Locale) -> TodayDialReadout {
        let title = "Regularity"
        let need = TodayDialRenderState.nightsNeeded
        guard let value = reading.value else {
            let gap = reading.gap ?? .noData
            if gap == .noData, nightsMeasured < need {
                return TodayDialReadout(id: .regularity, title: title, status: .learning(have: nightsMeasured, need: need),
                                        caption: "after \(need) nights", provenance: .absent)
            }
            return TodayDialReadout(id: .regularity, title: title, status: .absent(gap), caption: gapCaption(gap), provenance: .absent)
        }
        return TodayDialReadout(id: .regularity, title: title, status: .measured, number: value,
                                text: TodayDialFormat.integer(value, locale: locale), caption: "of 100",
                                provenance: reading.provenance, qualifier: "\(SleepWindow.nights) nights")
    }

    static func recovery(_ hero: TodayHeroState?, provenance: TodayDialProvenance) -> TodayDialReadout {
        let title = "Recovery"
        func reading(_ value: TodayRecoveryReading, caption: String, qualifier: String?) -> TodayDialReadout {
            TodayDialReadout(id: .recovery, title: title, status: .measured, number: value.score, text: value.text, caption: caption,
                             tone: .recovery(value.band), provenance: provenance, qualifier: qualifier, opensWhatShapedIt: true)
        }
        switch hero {
        case .scored(let value):
            return reading(value, caption: value.earlyEstimate != nil ? "early estimate" : value.band.verdict.lowercased(),
                           qualifier: nil)
        case .carried(let value, let dayLabel, _):
            return reading(value, caption: "from \(dayLabel)", qualifier: dayLabel)
        case .learning(let have, let need, _):
            return TodayDialReadout(id: .recovery, title: title, status: .learning(have: have, need: need),
                                    caption: "\(have) of \(need) nights", provenance: .absent, opensWhatShapedIt: true)
        case .calculating:
            return TodayDialReadout(id: .recovery, title: title, status: .absent(.noData), caption: "not in yet",
                                    provenance: .absent, opensWhatShapedIt: true)
        case .unavailable, nil:
            return TodayDialReadout(id: .recovery, title: title, status: .absent(.noData), caption: "no score",
                                    provenance: .absent)
        }
    }

    // MARK: Evening readouts

    static func lastMeal(_ meal: TodayDialMeal?, bedtime: TodayDialBedtime?, kitchenKept: Bool, clock: TodayDialClock,
                         locale: Locale) -> TodayDialReadout {
        let title = "Last meal"
        guard let meal else {
            return TodayDialReadout(id: .lastMeal, title: title, status: .absent(.noData), caption: "none logged", provenance: .absent)
        }
        var caption: String?
        if let bedtime {
            let gap = bedtime.at.timeIntervalSince(meal.at) / 60
            if gap >= 0, let text = LooprUnitFormatter.duration(minutes: gap) { caption = "\(text) to bed" }
        }
        return TodayDialReadout(id: .lastMeal, title: title, status: .measured,
                                text: TodayDialFormat.clock(meal.at, clock: clock, locale: locale), caption: caption,
                                tone: kitchenKept ? .good : .neutral, provenance: meal.provenance)
    }

    static func zone2(_ reading: TodayDialReading, target: Double?, locale: Locale) -> TodayDialReadout {
        let title = "Zone 2"
        guard let value = reading.value else {
            let gap = reading.gap ?? .noData
            return TodayDialReadout(id: .zone2, title: title, status: .absent(gap), caption: gapCaption(gap), provenance: .absent)
        }
        let caption = target.map { "of \(TodayDialFormat.integer($0, locale: locale)) min" } ?? "min today"
        let met = target.map { value >= $0 } ?? false
        return TodayDialReadout(id: .zone2, title: title, status: .measured, number: value,
                                text: TodayDialFormat.integer(value, locale: locale), caption: caption, tone: met ? .good : .neutral,
                                provenance: reading.provenance, qualifier: "today")
    }

    static func steps(_ reading: TodayDialReading, locale: Locale) -> TodayDialReadout {
        let title = "Steps"
        guard let value = reading.value else {
            let gap = reading.gap ?? .noData
            return TodayDialReadout(id: .steps, title: title, status: .absent(gap), caption: gapCaption(gap), provenance: .absent)
        }
        return TodayDialReadout(id: .steps, title: title, status: .measured, number: value,
                                text: TodayDialFormat.integer(value, locale: locale), caption: "today",
                                provenance: reading.provenance, qualifier: "today")
    }

    // MARK: Words

    static func gapCaption(_ gap: TodayDialGap) -> String {
        switch gap {
        case .noData: "not measured"
        case .switchedOff: "off in Settings"
        case .notAllowed: "not allowed in Apple Health"
        case .unavailable: "not available"
        }
    }

    static func nights(_ count: Int) -> String { count == 1 ? "1 night" : "\(count) nights" }

    /// "on time last night" or "on time 6 nights running": what the count counts is in the words (R1-OPT-19).
    static func onTimeStreak(_ count: Int) -> String { count == 1 ? "on time last night" : "on time \(count) nights running" }

    static func median(_ values: [Double]) -> Double? {
        let sorted = values.filter(\.isFinite).sorted()
        guard !sorted.isEmpty else { return nil }
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    /// The window regularity is read over, for its qualifier.
    enum SleepWindow {
        static let nights = 14
    }
}

/// Numbers and clock times as the dial writes them.
enum TodayDialFormat {
    /// Through the app's one number formatter, whatever the region, so steps read "9,812" beside Food's "1,240 kcal"
    /// (ICP R2-OPT-9). Clock times still follow the locale.
    static func integer(_ value: Double, locale: Locale) -> String {
        LooprUnitFormatter.number(value.rounded()) ?? String(Int(value.rounded()))
    }

    /// The wall-clock time of `date` in the dial's zone, following the locale: "22:30" or "10:30 PM".
    static func clock(_ date: Date, clock: TodayDialClock, locale: Locale) -> String {
        LooprClockFormat.text(minuteOfDay: clock.minuteOfDay(date), locale: locale)
    }

    static func clock(minuteOfDay: Int, locale: Locale) -> String {
        LooprClockFormat.text(minuteOfDay: minuteOfDay, locale: locale)
    }

    /// "2:41" for 2 hours 41 minutes, rounded down to the whole minute.
    static func hoursMinutes(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int((seconds / 60).rounded(.down)))
        let rest = minutes % 60
        return "\(minutes / 60):\(rest < 10 ? "0" : "")\(rest)"
    }
}
