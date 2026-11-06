import DomainKit
import Foundation

// The metric vocabulary. `RuleTarget.metric` holds one of these raw values, and a source snapshot holds one reading per
// metric it could measure. Templates, Today's rail and Fitness all use these names, so a name never changes once a
// release ships. A metric belongs to one check source, and a rule may only name a metric of its own source.
//
// Times of day are whole minutes after local midnight of the rule's day. A night that starts after midnight is past
// 1440: 00:30 the next morning is 1470, so "in bed by 22:30" (1350) compares correctly against it.

/// What a metric counts, so a screen can write "130 g" or "22:30" without guessing.
public enum RoutineMetricUnit: String, Codable, CaseIterable, Sendable {
    case grams, kilocalories, drinks, minutes, sessions, steps, mlPerKgPerMin, kilograms, beatsPerMinute
    /// Whole minutes after local midnight of the rule's day.
    case minutesAfterMidnight
    case tick
    /// A share from 0 to 1, such as taken doses over due doses.
    case fraction
}

/// How a metric moves through the day. This decides when a reading is final.
public enum RoutineMetricNature: String, Codable, Sendable {
    /// Only grows as the day goes on: grams eaten, minutes in a zone, the time of the last meal. A reading is not
    /// final until the day ends, except that a limit already crossed stays crossed.
    case accumulating
    /// One measurement per day: the night's onset, sleeping heart rate, a weigh-in. The reading decides the rule when it
    /// arrives.
    case settled
    /// A tick from the person.
    case tick
}

public enum RoutineMetric: String, Codable, CaseIterable, Sendable {
    // Food
    case proteinG = "protein_g"
    case fibreG = "fibre_g"
    case energyKcal = "energy_kcal"
    /// Time of the last meal. Drinks do not count as meals.
    case lastMealTime = "last_meal_time"
    /// Alcohol units (10 g of pure alcohol) logged on the day.
    case alcoholDrinks = "alcohol_drinks"
    /// Time of the last item that held caffeine.
    case lastCaffeineTime = "last_caffeine_time"
    /// 1 when every supplement dose due that day was ticked taken on the Food tab's stack, 0 when any was skipped. A
    /// dose with no tick gives no reading, so the rule stays unknown and is never missed. One item is
    /// `supplement_taken:<itemKey>` (`RoutineItemMetric`).
    case supplementsAllTaken = "supplements_all_taken"
    /// The same for the medication lane, which is never mixed into the supplements.
    case medicationAllTaken = "medication_all_taken"
    /// Taken supplement doses over due doses, only once every due dose has a tick. Experiments read it as adherence.
    case supplementAdherence = "supplement_adherence"
    // Band. Sleep metrics describe the night that starts on the rule's day.
    /// When the person fell asleep: the start of the main sleep plus the time to fall asleep.
    case sleepOnsetTime = "sleep_onset_time"
    /// The start of the main sleep period, which the Sleep screen shows as bedtime.
    case inBedTime = "in_bed_time"
    case zone2Minutes = "zone2_minutes"
    /// Minutes in heart-rate zones 4 and 5 together.
    case zone45Minutes = "zone45_minutes"
    case sleepHR = "sleep_hr"
    // Fitness
    case strengthSessions = "strength_sessions"
    /// Yoga sessions. Fitness has no separate mobility type yet.
    case mobilitySessions = "mobility_sessions"
    /// Minutes of completed workouts.
    case workoutMinutes = "workout_minutes"
    // Apple Health
    case steps
    case daylightMinutes = "daylight_minutes"
    case vo2max
    case weightKg = "weight_kg"
    // Manual
    case done

    public var source: CheckSource {
        switch self {
        case .proteinG, .fibreG, .energyKcal, .lastMealTime, .alcoholDrinks, .lastCaffeineTime,
             .supplementsAllTaken, .medicationAllTaken, .supplementAdherence: .food
        case .sleepOnsetTime, .inBedTime, .zone2Minutes, .zone45Minutes, .sleepHR: .band
        case .strengthSessions, .mobilitySessions, .workoutMinutes: .fitness
        case .steps, .daylightMinutes, .vo2max, .weightKg: .appleHealth
        case .done: .manual
        }
    }

    public var unit: RoutineMetricUnit {
        switch self {
        case .proteinG, .fibreG: .grams
        case .energyKcal: .kilocalories
        case .alcoholDrinks: .drinks
        case .lastMealTime, .lastCaffeineTime, .sleepOnsetTime, .inBedTime: .minutesAfterMidnight
        case .zone2Minutes, .zone45Minutes, .workoutMinutes, .daylightMinutes: .minutes
        case .sleepHR: .beatsPerMinute
        case .strengthSessions, .mobilitySessions: .sessions
        case .steps: .steps
        case .vo2max: .mlPerKgPerMin
        case .weightKg: .kilograms
        case .done, .supplementsAllTaken, .medicationAllTaken: .tick
        case .supplementAdherence: .fraction
        }
    }

    public var nature: RoutineMetricNature {
        switch self {
        // A stack reading exists only once the day's ticks decide it, so it settles the rule when it arrives.
        case .sleepOnsetTime, .inBedTime, .sleepHR, .vo2max, .weightKg, .supplementsAllTaken, .medicationAllTaken, .supplementAdherence: .settled
        case .done: .tick
        default: .accumulating
        }
    }

    public var isTimeOfDay: Bool { unit == .minutesAfterMidnight }

    /// True for the times of the latest event. "None happened" is a real answer for these (`MetricReading.noEvents`).
    public var isEventTime: Bool { self == .lastMealTime || self == .lastCaffeineTime }

    /// "By 21:45" for the night means before that minute. Every other time limit is at or before.
    var atMostIsStrict: Bool { self == .sleepOnsetTime || self == .inBedTime }

    /// Minutes after the end of the day that a reading can still arrive. The band scores a night in the morning after.
    public var settleDelayMinutes: Double {
        switch self {
        case .sleepOnsetTime, .inBedTime, .sleepHR: 720
        default: 0
        }
    }

    public static func metrics(for source: CheckSource) -> [RoutineMetric] { allCases.filter { $0.source == source } }
}

/// A metric about one named item of the Food tab's stack: `supplement_taken:<itemKey>` or `medication_taken:<itemKey>`.
/// The prefix is the vocabulary and the key is the item's stable key, which does not change when the item is renamed.
/// The reading is 1 when every dose of that item due on the day was ticked taken and 0 when any was skipped. Doses with
/// no tick give no reading, so the rule is unknown, never missed. The source is always Food.
public struct RoutineItemMetric: Hashable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case supplementTaken = "supplement_taken"
        case medicationTaken = "medication_taken"

        /// The lane-wide metric whose access an item metric shares.
        public var lane: RoutineMetric { self == .supplementTaken ? .supplementsAllTaken : .medicationAllTaken }
    }

    public static let separator: Character = ":"
    public static let maximumKeyLength = 48

    public let kind: Kind
    public let itemKey: String

    /// Nil for a key outside 1 to 48 characters of `a` to `z`, `0` to `9` and `-`, the stack's own key rule.
    public init?(kind: Kind, itemKey: String) {
        guard Self.isValidItemKey(itemKey) else { return nil }
        self.kind = kind; self.itemKey = itemKey
    }

    /// Parses `supplement_taken:vitamin-d3`. Nil for any other name.
    public init?(rawValue: String) {
        guard let colon = rawValue.firstIndex(of: Self.separator), let kind = Kind(rawValue: String(rawValue[..<colon])) else { return nil }
        self.init(kind: kind, itemKey: String(rawValue[rawValue.index(after: colon)...]))
    }

    public var rawValue: String { kind.rawValue + String(Self.separator) + itemKey }
    public var source: CheckSource { .food }
    public var unit: RoutineMetricUnit { .tick }
    public var nature: RoutineMetricNature { .settled }

    public static func isValidItemKey(_ key: String) -> Bool {
        !key.isEmpty && key.count <= maximumKeyLength
            && key.utf8.allSatisfy { ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 45 }
    }
}

/// Every metric name a rule may carry: the fixed `RoutineMetric` names and the item names of `RoutineItemMetric`.
/// Validators of stored and imported protocols read names through here.
public enum RoutineMetricVocabulary {
    /// The source that measures `name`, or nil when the name is not in the vocabulary.
    public static func source(ofMetric name: String) -> CheckSource? {
        RoutineMetric(rawValue: name)?.source ?? RoutineItemMetric(rawValue: name)?.source
    }

    public static func isKnown(_ name: String) -> Bool { source(ofMetric: name) != nil }
}

/// What a source knows about one metric on one day. A metric with no reading is unknown, which is not zero.
public enum MetricReading: Equatable, Sendable {
    /// Everything the source holds is counted: 38 g of protein, or 0 drinks on a day the person closed the log.
    case measured(Double)
    /// A floor. Some items did not report this value, so the true figure is this or more.
    case atLeast(Double)
    /// An event metric (`isEventTime`) for which the source knows nothing happened, such as no meal on a day the
    /// person closed the log.
    case noEvents

    /// A quantity read from a total. Nil when nothing reported; a floor when only some items did.
    public static func quantity(known: Double?, isComplete: Bool) -> MetricReading? {
        guard let known, known.isFinite, known >= 0 else { return nil }
        return isComplete ? .measured(known) : .atLeast(known)
    }

    var amount: Double? {
        switch self {
        case .measured(let value), .atLeast(let value): value.isFinite && value >= 0 ? value : nil
        case .noEvents: nil
        }
    }
}

/// Why a source cannot answer. Each one makes a rule unknown, never missed.
public enum RoutineSourceAccess: String, Codable, Sendable {
    case available
    /// The person turned this source off in Loopr.
    case switchedOff
    /// The person has not allowed Loopr to read it, or the system refused.
    case denied
    /// The source does not exist here: no band paired, no Apple Health on the device, or the read failed.
    case unavailable
}

/// What one source measured on one day. The app fills it from its repositories, with no decisions of its own.
public struct RoutineSourceSnapshot: Equatable, Sendable {
    public let source: CheckSource
    public let access: RoutineSourceAccess
    /// Metrics blocked on their own while the source as a whole is available, such as one Apple Health kind switched off.
    public let blocked: [RoutineMetric: RoutineSourceAccess]
    public let readings: [RoutineMetric: MetricReading]
    /// Readings of item metrics such as `supplement_taken:vitamin-d3`. An item metric shares the access of its lane's
    /// metric (`RoutineItemMetric.Kind.lane`).
    public let itemReadings: [RoutineItemMetric: MetricReading]

    public init(source: CheckSource, access: RoutineSourceAccess = .available,
                blocked: [RoutineMetric: RoutineSourceAccess] = [:], readings: [RoutineMetric: MetricReading] = [:],
                itemReadings: [RoutineItemMetric: MetricReading] = [:]) {
        self.source = source; self.access = access; self.blocked = blocked; self.readings = readings
        self.itemReadings = itemReadings
    }

    /// A source that cannot answer.
    public static func closed(_ source: CheckSource, _ access: RoutineSourceAccess = .unavailable) -> RoutineSourceSnapshot {
        RoutineSourceSnapshot(source: source, access: access)
    }

    func access(for metric: RoutineMetric) -> RoutineSourceAccess { blocked[metric] ?? access }
}

/// The person's ticks for the day, by rule key. `values` holds an amount the person typed with a tick, such as minutes.
public struct RoutineManualSnapshot: Equatable, Sendable {
    public let ticked: Set<RuleKey>
    public let values: [RuleKey: Double]
    public init(ticked: Set<RuleKey> = [], values: [RuleKey: Double] = [:]) { self.ticked = ticked; self.values = values }
}

/// One day's snapshot of every source.
public struct RoutineSourceSnapshots: Equatable, Sendable {
    public let band: RoutineSourceSnapshot
    public let food: RoutineSourceSnapshot
    public let fitness: RoutineSourceSnapshot
    public let appleHealth: RoutineSourceSnapshot
    public let manual: RoutineManualSnapshot

    public init(band: RoutineSourceSnapshot = .closed(.band), food: RoutineSourceSnapshot = .closed(.food),
                fitness: RoutineSourceSnapshot = .closed(.fitness),
                appleHealth: RoutineSourceSnapshot = .closed(.appleHealth),
                manual: RoutineManualSnapshot = RoutineManualSnapshot()) {
        self.band = band; self.food = food; self.fitness = fitness; self.appleHealth = appleHealth; self.manual = manual
    }

    /// The snapshot for an automatic source. Manual ticks live in `manual`.
    func snapshot(for source: CheckSource) -> RoutineSourceSnapshot? {
        switch source {
        case .band: band
        case .food: food
        case .fitness: fitness
        case .appleHealth: appleHealth
        case .manual: nil
        }
    }

    func replacingManual(_ manual: RoutineManualSnapshot) -> RoutineSourceSnapshots {
        RoutineSourceSnapshots(band: band, food: food, fitness: fitness, appleHealth: appleHealth, manual: manual)
    }
}

/// The local calendar day a rule is checked for. Providers use it to keep records to the day and to turn instants into
/// the minutes after midnight that time metrics hold.
public struct RoutineDayClock: Sendable {
    public let day: DayIdentity
    public let timeZone: TimeZone
    public let start: Date
    public let end: Date
    private let calendar: Calendar

    public init?(day: DayIdentity, timeZone: TimeZone) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard day.routineDayKey != nil,
              let start = calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day)),
              let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
        self.day = day; self.timeZone = timeZone; self.start = start; self.end = end; self.calendar = calendar
    }

    public func contains(_ date: Date) -> Bool { date >= start && date < end }

    /// Wall-clock minutes after local midnight of the rule's day, with seconds as a fraction. Negative before the day
    /// starts and 1440 or more after it ends.
    public func minutes(of date: Date) -> Double {
        let offset = calendar.dateComponents([.day], from: start, to: calendar.startOfDay(for: date)).day ?? 0
        let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
        // Split up: one expression with the three optionals timed out the type checker on the CI runner.
        let hour: Int = parts.hour ?? 0, minute: Int = parts.minute ?? 0, second: Int = parts.second ?? 0
        let wholeMinutes: Int = offset * 1_440 + hour * 60 + minute
        return Double(wholeMinutes) + Double(second) / 60
    }

    /// The whole minute `date` falls in, which is what a time metric stores.
    public func wholeMinute(of date: Date) -> Int { Int(minutes(of: date).rounded(.down)) }
}
