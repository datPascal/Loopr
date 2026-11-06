import DesignSystem
import Foundation

// Fitness round 1 (R1-NEW-02, R1-DES-05, R1-VET-07): the quick log. A session logged after the fact carries
// what the person knows about it: a type, a day, a duration, and optionally a title, effort, distance, a typed
// average heart rate and notes. Typed values are labelled as typed and never become zone minutes.

extension LooprColorToken {
    /// The Fitness accent for every WorkoutKit flow (R1-DES-08). The same token as TrainKit's `fitnessTab`.
    static let workoutAccent: LooprColorToken = .strain
}

public extension ActivityType {
    /// Every type the quick log offers, in its default order. Gym opens the set log and WOD opens the WOD log.
    static let loggable: [ActivityType] = [.strength, .run, .walk, .cycle, .yoga, .pilates, .mobility, .crossfit,
                                           .hiit, .swim, .rowing, .hike, .climbing, .sport, .dance, .cardio, .other]

    /// Types whose name alone says little, so the title field comes first: "Bouldering", "Salsa".
    var asksForTitleUpFront: Bool { [.sport, .dance, .climbing, .other].contains(self) }

    /// Types where a typed distance means something.
    var logsDistance: Bool { [.run, .cycle, .walk, .hike, .swim, .rowing].contains(self) }

    /// False for mind and body and skill types, where a heart rate target does not fit (R1-NEW-08, R1-WOD-14).
    var offersHeartRateTarget: Bool { ![.yoga, .pilates, .mobility, .climbing, .dance, .other].contains(self) }

    /// True for the types the weekly dose counts as a mobility session.
    var countsAsMobility: Bool { [.yoga, .pilates, .mobility].contains(self) }

    /// An example title for the field.
    var titleExample: String {
        switch self {
        case .sport: "Five-a-side football"
        case .dance: "Salsa class"
        case .climbing: "Bouldering"
        case .other: "Spin class"
        case .yoga: "Vinyasa flow"
        case .pilates: "Reformer class"
        case .mobility: "Hips and shoulders"
        case .run: "Easy loop"
        case .cycle: "Commute"
        case .walk: "Lunch walk"
        case .hike: "Bluff Knoll"
        case .swim: "Pool, 50 m lanes"
        case .rowing: "2 km test"
        case .hiit: "Bootcamp"
        case .cardio: "Elliptical"
        case .crossfit: "Fran"
        case .strength: "Upper body"
        }
    }

    /// `loggable` with the most recently logged types first, each once.
    static func recentFirst(_ records: [WorkoutRecord]) -> [ActivityType] {
        let recent = recentActivities(records)
        return recent + loggable.filter { !recent.contains($0) }
    }

    /// Up to `limit` types from the newest records, newest first.
    static func recentActivities(_ records: [WorkoutRecord], limit: Int = 4) -> [ActivityType] {
        var seen: [ActivityType] = []
        for record in records.sorted(by: { ($0.startedAt ?? $0.createdAt) > ($1.startedAt ?? $1.createdAt) })
        where record.state == .completed && loggable.contains(record.activity) && !seen.contains(record.activity) {
            seen.append(record.activity)
            if seen.count == limit { break }
        }
        return seen
    }

    /// Up to `limit` titles used before with this type, newest first, each once.
    func recentTitles(_ records: [WorkoutRecord], limit: Int = 3) -> [String] {
        var seen: [String] = []
        for record in records.sorted(by: { ($0.startedAt ?? $0.createdAt) > ($1.startedAt ?? $1.createdAt) })
        where record.activity == self {
            guard let title = WorkoutLogEntry.cleaned(record.title),
                  !seen.contains(where: { $0.caseInsensitiveCompare(title) == .orderedSame }) else { continue }
            seen.append(title)
            if seen.count == limit { break }
        }
        return seen
    }
}

/// Why a typed session cannot be saved.
public enum WorkoutLogError: Error, Equatable, Sendable, LocalizedError {
    case endsInFuture
    case tooShort
    case effortOutOfRange
    case heartRateOutOfRange
    case distanceOutOfRange

    public var errorDescription: String? {
        switch self {
        case .endsInFuture: "That end time hasn't happened yet. Pick an earlier time."
        case .tooShort: "Make it at least 1 minute."
        case .effortOutOfRange: "Effort goes from 1 to 10."
        case .heartRateOutOfRange: "Average heart rate goes from 30 to 230 bpm."
        case .distanceOutOfRange: "Distance goes up to 1,000 km."
        }
    }
}

/// One session as the person typed it, before it is saved.
public struct WorkoutLogEntry: Equatable, Sendable {
    public static let effortRange = 1...10
    public static let heartRateRange = 30...230
    public static let maximumDistanceMeters = 1_000_000.0

    public var activity: ActivityType
    public var startedAt: Date
    public var endedAt: Date
    public var title: String?
    public var effort: Int?
    public var distanceMeters: Double?
    public var typedAverageHeartRate: Int?
    public var notes: String?
    public var wod: WODResult?
    public var lengths: Int?
    public var poolLengthMeters: Int?
    public var calories: Int?

    public init(activity: ActivityType, startedAt: Date, endedAt: Date, title: String? = nil, effort: Int? = nil,
                distanceMeters: Double? = nil, typedAverageHeartRate: Int? = nil, notes: String? = nil,
                wod: WODResult? = nil, lengths: Int? = nil, poolLengthMeters: Int? = nil, calories: Int? = nil) {
        self.lengths = lengths; self.poolLengthMeters = poolLengthMeters; self.calories = calories
        self.activity = activity; self.startedAt = startedAt; self.endedAt = endedAt; self.title = title
        self.effort = effort; self.distanceMeters = distanceMeters; self.typedAverageHeartRate = typedAverageHeartRate
        self.notes = notes; self.wod = wod
    }

    /// What a saved record holds, so an edit starts from it.
    public init?(record: WorkoutRecord) {
        guard let start = record.startedAt, let end = record.endedAt else { return nil }
        self.init(activity: record.activity, startedAt: start, endedAt: end, title: record.title, effort: record.effort,
                  distanceMeters: record.loggedDistanceMeters, typedAverageHeartRate: record.typedAverageHeartRate,
                  notes: record.notes, wod: record.wod, lengths: record.lengths,
                  poolLengthMeters: record.poolLengthMeters, calories: record.loggedCalories)
    }

    /// Trimmed text, nil when empty.
    public static func cleaned(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    /// The entry with empty text as nil, checked. `now` bounds the end time: a minute of clock drift is allowed.
    public func validated(now: Date = Date(), allowingFuture: Bool = false) throws -> WorkoutLogEntry {
        guard endedAt.timeIntervalSince(startedAt) >= 60 else { throw WorkoutLogError.tooShort }
        guard allowingFuture || endedAt <= now.addingTimeInterval(60) else { throw WorkoutLogError.endsInFuture }
        if let effort, !Self.effortRange.contains(effort) { throw WorkoutLogError.effortOutOfRange }
        if let typedAverageHeartRate, !Self.heartRateRange.contains(typedAverageHeartRate) {
            throw WorkoutLogError.heartRateOutOfRange
        }
        if let distanceMeters, !(distanceMeters > 0 && distanceMeters <= Self.maximumDistanceMeters) {
            throw WorkoutLogError.distanceOutOfRange
        }
        var entry = self
        entry.title = Self.cleaned(title)
        entry.notes = Self.cleaned(notes)
        entry.wod = wod?.cleaned
        // Distance only belongs to the types that cover one.
        if !activity.logsDistance { entry.distanceMeters = nil }
        if !activity.takesLengths { entry.lengths = nil; entry.poolLengthMeters = nil }
        if !activity.takesCalories { entry.calories = nil }
        entry.lengths = entry.lengths.flatMap { $0 > 0 ? $0 : nil }
        entry.poolLengthMeters = entry.poolLengthMeters.flatMap { $0 > 0 ? $0 : nil }
        entry.calories = entry.calories.flatMap { $0 > 0 ? $0 : nil }
        return entry
    }

    /// Writes the typed details onto a record. Activity and times are the caller's.
    func apply(to row: inout WorkoutRecord) {
        row.title = title
        row.effort = effort
        row.loggedDistanceMeters = distanceMeters
        row.typedAverageHeartRate = typedAverageHeartRate
        row.notes = notes
        row.wod = activity == .crossfit ? wod : nil
        row.lengths = lengths
        row.poolLengthMeters = poolLengthMeters
        row.loggedCalories = calories
    }
}

/// Which day a quick log is for.
public enum WorkoutLogDay: String, CaseIterable, Sendable {
    case today, yesterday, pick

    public var title: String {
        switch self {
        case .today: "Today"
        case .yesterday: "Yesterday"
        case .pick: "Pick"
        }
    }
}

/// The start and end a quick log saves, from its day, end time and duration.
public enum WorkoutLogTiming {
    /// Duration chips, in minutes.
    public static let durationChips = [10, 20, 30, 45, 60]
    /// The stepper's step, in minutes.
    public static let durationStep = 5
    public static let durationRange = 1...600

    /// `endsNow` ends the session at `now` on Today, or at the same clock time on another day. Otherwise the
    /// session ends at the clock time of `endTime` on the chosen day. `pickedDay` is any moment of the picked day.
    public static func interval(day: WorkoutLogDay, pickedDay: Date, endsNow: Bool, endTime: Date,
                                durationMinutes: Int, now: Date, calendar: Calendar) -> (start: Date, end: Date) {
        let base: Date
        switch day {
        case .today: base = now
        case .yesterday: base = calendar.date(byAdding: .day, value: -1, to: now) ?? now
        case .pick: base = pickedDay
        }
        let clock = calendar.dateComponents([.hour, .minute], from: endsNow ? now : endTime)
        let end: Date
        if endsNow, day == .today {
            end = now
        } else {
            end = calendar.date(bySettingHour: clock.hour ?? 0, minute: clock.minute ?? 0, second: 0, of: base) ?? base
        }
        let minutes = min(max(durationMinutes, durationRange.lowerBound), durationRange.upperBound)
        return (end.addingTimeInterval(-Double(minutes) * 60), end)
    }

    /// The day chip for a saved end time.
    public static func day(for end: Date, now: Date, calendar: Calendar) -> WorkoutLogDay {
        if calendar.isDate(end, inSameDayAs: now) { return .today }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(end, inSameDayAs: yesterday) {
            return .yesterday
        }
        return .pick
    }

    /// The next stepper value: down to the step below, up to the step above, inside `durationRange`.
    public static func stepped(_ minutes: Int, direction: Int) -> Int {
        let step = durationStep
        let next = direction > 0 ? (minutes / step + 1) * step : ((minutes - 1) / step) * step
        return min(max(next, durationRange.lowerBound), durationRange.upperBound)
    }
}

public extension WorkoutRecord {
    /// Where this record came from, for its chip (R1-DES-13).
    var sourceLabel: String {
        switch source {
        case .live: "Recorded"
        case .manual: "Logged by you"
        case .detected: "Band"
        case .healthKit: "Apple Health"
        case .imported: importedSummary?.source ?? "Imported"
        }
    }

    var sourceSymbol: String {
        switch source {
        case .live: "record.circle"
        case .manual: "pencil"
        case .detected: "sensor.tag.radiowaves.forward"
        case .healthKit: "heart.text.square"
        case .imported: "square.and.arrow.down"
        }
    }

    /// The name a row and the detail lead with: the title, the WOD's name, the import's activity, or the type.
    var displayTitle: String {
        WorkoutLogEntry.cleaned(title) ?? WorkoutLogEntry.cleaned(wod?.name) ?? importedSummary?.activityName
            ?? activity.displayName
    }

    /// The average of the heart rate samples the band measured. Nil without any.
    var measuredAverageHeartRate: Int? {
        let values = samples.compactMap(\.heartRate).filter { $0 > 0 }
        guard !values.isEmpty else { return nil }
        return Int((Double(values.reduce(0, +)) / Double(values.count)).rounded())
    }

    var measuredMaximumHeartRate: Int? { samples.compactMap(\.heartRate).filter { $0 > 0 }.max() }

    /// True when a GPS route may sit behind this record: an outdoor type recorded live or imported with distance
    /// samples. A typed session has none.
    var mayHaveRoute: Bool {
        guard [.run, .cycle, .walk, .hike].contains(activity) else { return false }
        return source == .live || source == .healthKit || latestDistanceSample != nil
    }
}
