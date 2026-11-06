import DesignSystem
import DomainKit
import Foundation

// The plain values the day dial is built from. The app reads Sleep, Food, Fitness, Apple Health, the protocol and the
// wake alarm and fills these in without deciding anything; `TodayDialModel` makes every decision. A value the app
// could not read stays missing, with the reason, and is never filled with zero.

/// Why a value is missing. None of these is zero.
public enum TodayDialGap: String, Equatable, Sendable {
    /// The source holds nothing for this day yet.
    case noData
    /// The person switched this read off in Loopr.
    case switchedOff
    /// Apple Health has not allowed the read.
    case notAllowed
    /// The source is not on this iPhone, or the read failed.
    case unavailable
}

/// One number and where it came from, or why there is none.
public enum TodayDialReading: Equatable, Sendable {
    case value(Double, TodayDialProvenance)
    case missing(TodayDialGap)

    /// A finite value, or nil.
    public var value: Double? {
        guard case .value(let value, _) = self, value.isFinite else { return nil }
        return value
    }

    public var provenance: TodayDialProvenance {
        guard case .value(_, let provenance) = self, value != nil else { return .absent }
        return provenance
    }

    public var gap: TodayDialGap? {
        switch self {
        case .missing(let gap): gap
        case .value: value == nil ? .noData : nil
        }
    }
}

/// Last night's main sleep: the stage spans with clock times and the bounds of the night.
public struct TodayDialNightInput: Equatable, Sendable {
    public var spans: [LooprStageSpan]
    public var start: Date
    public var end: Date
    /// Minutes asleep as the derivation counted them. Nil falls back to the spans.
    public var asleepMinutes: Double?
    /// The band lost contact for part of the night.
    public var isPartial: Bool
    public var provenance: TodayDialProvenance

    public init(spans: [LooprStageSpan], start: Date, end: Date, asleepMinutes: Double? = nil, isPartial: Bool = false,
                provenance: TodayDialProvenance) {
        self.spans = spans
        self.start = start
        self.end = end
        self.asleepMinutes = asleepMinutes
        self.isPartial = isPartial
        self.provenance = provenance
    }
}

/// One of the recent nights, oldest first, for regularity: the bedtime as minutes after noon (Sleep's noon-based
/// clock, so 22:30 is 630 and 00:30 is 750), nil for a night with no main sleep.
public struct TodayDialNightTiming: Equatable, Sendable {
    public var day: DayIdentity
    public var bedMinuteAfterNoon: Double?

    public init(day: DayIdentity, bedMinuteAfterNoon: Double?) {
        self.day = day
        self.bedMinuteAfterNoon = bedMinuteAfterNoon
    }
}

/// Sleep's plan for tonight (`SleepTonightPlan`), as wall-clock minutes after midnight.
public struct TodayDialTonightInput: Equatable, Sendable {
    public var bedtimeMinuteOfDay: Int
    public var wakeMinuteOfDay: Int?
    public var sleepMinutes: Double?

    public init(bedtimeMinuteOfDay: Int, wakeMinuteOfDay: Int?, sleepMinutes: Double?) {
        self.bedtimeMinuteOfDay = bedtimeMinuteOfDay
        self.wakeMinuteOfDay = wakeMinuteOfDay
        self.sleepMinutes = sleepMinutes
    }
}

/// The photo a meal sticker shows: a Food photo reference the app resolves to an image.
public struct TodayDialSticker: Equatable, Sendable {
    public var photoID: UUID
    public var fileName: String

    public init(photoID: UUID, fileName: String) {
        self.photoID = photoID
        self.fileName = fileName
    }
}

/// What a meal holds, for the card a tapped sticker opens. A total is nil when no food in the meal has that value.
public struct TodayDialMealNutrition: Equatable, Sendable {
    public var energyKcal: Double?
    public var proteinGrams: Double?
    public var carbsGrams: Double?
    public var fatGrams: Double?
    public var fibreGrams: Double?
    /// The foods in the meal, in the order Food lists them.
    public var items: [String]
    /// Some foods have no values, so the totals count only the ones that do.
    public var isPartial: Bool

    public init(energyKcal: Double?, proteinGrams: Double?, carbsGrams: Double?, fatGrams: Double?, fibreGrams: Double?,
                items: [String], isPartial: Bool = false) {
        self.energyKcal = energyKcal
        self.proteinGrams = proteinGrams
        self.carbsGrams = carbsGrams
        self.fatGrams = fatGrams
        self.fibreGrams = fibreGrams
        self.items = items
        self.isPartial = isPartial
    }
}

public struct TodayDialMealInput: Equatable, Sendable {
    public var id: String
    public var title: String
    public var at: Date
    public var sticker: TodayDialSticker?
    public var provenance: TodayDialProvenance
    /// Nil when the app did not read what is in the meal. The meal card then shows the photo and the time only.
    public var nutrition: TodayDialMealNutrition?

    public init(id: String, title: String, at: Date, sticker: TodayDialSticker? = nil, provenance: TodayDialProvenance,
                nutrition: TodayDialMealNutrition? = nil) {
        self.id = id
        self.title = title
        self.at = at
        self.sticker = sticker
        self.provenance = provenance
        self.nutrition = nutrition
    }
}

public struct TodayDialWorkoutInput: Equatable, Sendable {
    public var id: String
    public var title: String
    public var start: Date
    /// Nil while the workout is still going.
    public var end: Date?
    public var provenance: TodayDialProvenance

    public init(id: String, title: String, start: Date, end: Date?, provenance: TodayDialProvenance) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.provenance = provenance
    }
}

/// A session Fitness planned for today at a set time.
public struct TodayDialPlannedSessionInput: Equatable, Sendable {
    public var id: String
    public var title: String
    public var startMinuteOfDay: Int
    /// Nil when the plan gives no length; the block is then drawn as a point.
    public var durationMinutes: Double?

    public init(id: String, title: String, startMinuteOfDay: Int, durationMinutes: Double?) {
        self.id = id
        self.title = title
        self.startMinuteOfDay = startMinuteOfDay
        self.durationMinutes = durationMinutes
    }
}

/// Time in daylight. Apple Health hands over one total per day, so `dailyTotal` is the usual case. `intervals` is
/// for a source that knows when the daylight happened.
public enum TodayDialDaylightInput: Equatable, Sendable {
    case dailyTotal(minutes: Double, provenance: TodayDialProvenance)
    case intervals([DateInterval], provenance: TodayDialProvenance)
    case missing(TodayDialGap)
}

/// How a protocol rule is checked.
public enum TodayDialRuleSource: String, Equatable, Sendable {
    case band, food, fitness, appleHealth, manual
}

/// A rule's state for the day, as RoutineKit's evaluator decided it.
public enum TodayDialRuleState: String, Equatable, Sendable {
    case kept, missed, pending, unknown
}

/// One rule of the active protocol version with today's check.
public struct TodayDialRuleInput: Equatable, Sendable {
    public var key: String
    public var title: String
    /// RoutineKit's metric name, such as `last_meal_time` or `in_bed_time`. Nil for a plain tick.
    public var metric: String?
    /// The reminder time, minutes after midnight.
    public var timeOfDayMinutes: Int?
    /// The target. For a time-of-day metric this is the limit in minutes after midnight ("last meal by 18:30").
    public var targetValue: Double?
    public var isEvening: Bool
    public var source: TodayDialRuleSource
    public var state: TodayDialRuleState

    public init(key: String, title: String, metric: String? = nil, timeOfDayMinutes: Int? = nil, targetValue: Double? = nil,
                isEvening: Bool = false, source: TodayDialRuleSource = .manual, state: TodayDialRuleState) {
        self.key = key
        self.title = title
        self.metric = metric
        self.timeOfDayMinutes = timeOfDayMinutes
        self.targetValue = targetValue
        self.isEvening = isEvening
        self.source = source
        self.state = state
    }
}

/// The wake alarm, only while it is on.
public struct TodayDialAlarmInput: Equatable, Sendable {
    public var wakeMinuteOfDay: Int
    /// Zero for an alarm with no smart window.
    public var smartWindowMinutes: Int
    public var ringsToday: Bool
    public var ringsTomorrow: Bool

    public init(wakeMinuteOfDay: Int, smartWindowMinutes: Int = 0, ringsToday: Bool, ringsTomorrow: Bool) {
        self.wakeMinuteOfDay = wakeMinuteOfDay
        self.smartWindowMinutes = max(0, smartWindowMinutes)
        self.ringsToday = ringsToday
        self.ringsTomorrow = ringsTomorrow
    }
}

/// Everything the dial for one local day is built from.
public struct TodayDialInputs: Equatable, Sendable {
    public var day: DayIdentity
    public var now: Date
    /// Its time zone is the dial's zone.
    public var calendar: Calendar
    public var locale: Locale

    public var lastNight: TodayDialNightInput?
    /// Up to 14 nights ending with last night, oldest first.
    public var recentNights: [TodayDialNightTiming]
    public var tonight: TodayDialTonightInput?
    public var meals: [TodayDialMealInput]
    public var workouts: [TodayDialWorkoutInput]
    public var plannedSessions: [TodayDialPlannedSessionInput]
    public var daylight: TodayDialDaylightInput
    public var rules: [TodayDialRuleInput]
    public var alarm: TodayDialAlarmInput?

    /// Last night's sleeping heart rate.
    public var sleepHeartRate: TodayDialReading
    /// Sleeping heart rate on the nights before last night, for the usual.
    public var sleepHeartRateBefore: [Double]
    /// Sleep regularity, 0 to 100.
    public var regularity: TodayDialReading
    /// Today's recovery hero, as `TodayDashboard` worked it out. Nil when Today has none.
    public var recovery: TodayHeroState?
    public var recoveryProvenance: TodayDialProvenance
    public var zone2Minutes: TodayDialReading
    public var steps: TodayDialReading

    public init(day: DayIdentity, now: Date, calendar: Calendar, locale: Locale = .current,
                lastNight: TodayDialNightInput? = nil, recentNights: [TodayDialNightTiming] = [],
                tonight: TodayDialTonightInput? = nil, meals: [TodayDialMealInput] = [],
                workouts: [TodayDialWorkoutInput] = [], plannedSessions: [TodayDialPlannedSessionInput] = [],
                daylight: TodayDialDaylightInput = .missing(.noData), rules: [TodayDialRuleInput] = [],
                alarm: TodayDialAlarmInput? = nil, sleepHeartRate: TodayDialReading = .missing(.noData),
                sleepHeartRateBefore: [Double] = [], regularity: TodayDialReading = .missing(.noData),
                recovery: TodayHeroState? = nil, recoveryProvenance: TodayDialProvenance = .onThisPhone,
                zone2Minutes: TodayDialReading = .missing(.noData), steps: TodayDialReading = .missing(.noData)) {
        self.day = day
        self.now = now
        self.calendar = calendar
        self.locale = locale
        self.lastNight = lastNight
        self.recentNights = recentNights
        self.tonight = tonight
        self.meals = meals
        self.workouts = workouts
        self.plannedSessions = plannedSessions
        self.daylight = daylight
        self.rules = rules
        self.alarm = alarm
        self.sleepHeartRate = sleepHeartRate
        self.sleepHeartRateBefore = sleepHeartRateBefore
        self.regularity = regularity
        self.recovery = recovery
        self.recoveryProvenance = recoveryProvenance
        self.zone2Minutes = zone2Minutes
        self.steps = steps
    }
}
