import DomainKit
import Foundation

public enum PatternTestState: String, Codable, CaseIterable, Sendable {
    case running, completed, stopped

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .running
    }
}

public struct PatternReminder: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var minuteOfDay: Int
    public var hour: Int { minuteOfDay / 60 }
    public var minute: Int { minuteOfDay % 60 }

    public init(enabled: Bool = true, minuteOfDay: Int = PatternPolicy.default.defaultReminderMinuteOfDay) {
        self.enabled = enabled
        self.minuteOfDay = min(max(minuteOfDay, 0), 24 * 60 - 1)
    }

    private enum CodingKeys: String, CodingKey { case enabled, minuteOfDay }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(enabled: try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true,
                  minuteOfDay: try c.decodeIfPresent(Int.self, forKey: .minuteOfDay) ?? PatternPolicy.default.defaultReminderMinuteOfDay)
    }
}

/// Why a test runs without the reminder the person asked for. The test card says so, so nothing is dropped silently.
public enum PatternReminderProblem: String, Codable, Equatable, Sendable {
    /// iOS notifications are off for Loopr, or the person refused the prompt.
    case notAllowed
    /// Ten reminders are already waiting.
    case full
    /// "Reminders you set" is off in Settings.
    case familyOff
    /// The system would not take it.
    case failed
    /// The person cancelled it from Settings.
    case cancelled
}

public struct PatternKeptDay: Codable, Equatable, Sendable {
    public let dayKey: String
    public let recordedAt: Date
    public init(dayKey: String, recordedAt: Date) { self.dayKey = dayKey; self.recordedAt = recordedAt }

    private enum CodingKeys: String, CodingKey { case dayKey, recordedAt }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dayKey = try c.decode(String.self, forKey: .dayKey)
        recordedAt = try c.decodeIfPresent(Date.self, forKey: .recordedAt) ?? .distantPast
    }
}

public enum PatternTestDayStatus: String, Codable, Sendable {
    case kept
    /// A past test day with no kept answer. Counted as `.skipped`, never as `.no`.
    case missed
    /// Today, not kept yet.
    case pending
    case upcoming
}

public struct PatternTestProgress: Equatable, Sendable {
    public let totalDays: Int
    /// 1-based day of the test that today falls on, clamped to 1...totalDays.
    public let dayNumber: Int
    /// Test days from the start through today, inclusive, at most `totalDays`.
    public let elapsedDays: Int
    public let keptCount: Int
    public let missedCount: Int
    public let isOver: Bool
    public let days: [String: PatternTestDayStatus]

    /// "5 of 6 kept" for day 6 with five kept.
    public var keptSummary: String { "\(keptCount) of \(elapsedDays) kept" }
}

public enum PatternTestError: Error, Equatable, LocalizedError, Sendable {
    case notATestDay
    case futureDay
    case tooLate
    case notRunning
    case invalidTimeZone

    public var errorDescription: String? {
        switch self {
        case .notATestDay: "That day is outside this test."
        case .futureDay: "You can keep a night once the day has started."
        case .tooLate: "That night is more than 48 hours old, so Loopr leaves it out."
        case .notRunning: "This test is not running."
        case .invalidTimeZone: "This test has no valid time zone."
        }
    }
}

/// A 14-day test. The outcome metric is chosen at the start and never changes,
/// which is what keeps the verdict from being a metric picked after the fact.
public struct PatternTest: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let candidateID: String
    public let habitID: HabitID
    public let title: String
    public let predicate: PatternPredicate
    /// Fixed when the test starts.
    public let outcomeMetric: HabitOutcomeMetricID
    public let startDay: String
    public let timeZoneID: String
    public let testDays: Int
    public let baselineDays: Int
    public var reminder: PatternReminder?
    /// Set when a reminder was asked for and could not be scheduled, or was cancelled from Settings.
    public var reminderProblem: PatternReminderProblem?
    public private(set) var state: PatternTestState
    public private(set) var keptDays: [PatternKeptDay]
    public let createdAt: Date
    public private(set) var endedAt: Date?
    public let schemaVersion: Int

    public init(
        id: UUID = UUID(), candidateID: String, habitID: HabitID, title: String, predicate: PatternPredicate,
        outcomeMetric: HabitOutcomeMetricID, startDay: String, timeZoneID: String,
        testDays: Int = PatternPolicy.default.testDays, baselineDays: Int = PatternPolicy.default.baselineDays,
        reminder: PatternReminder? = nil, reminderProblem: PatternReminderProblem? = nil,
        state: PatternTestState = .running, keptDays: [PatternKeptDay] = [],
        createdAt: Date, endedAt: Date? = nil, schemaVersion: Int = 1
    ) {
        self.id = id; self.candidateID = candidateID; self.habitID = habitID; self.title = title
        self.predicate = predicate; self.outcomeMetric = outcomeMetric; self.startDay = startDay
        self.timeZoneID = timeZoneID; self.testDays = testDays; self.baselineDays = baselineDays
        self.reminder = reminder; self.reminderProblem = reminderProblem; self.state = state
        self.keptDays = keptDays.sorted { $0.dayKey < $1.dayKey }
        self.createdAt = createdAt; self.endedAt = endedAt; self.schemaVersion = schemaVersion
    }

    /// Starts today (in `timeZone`) as day 1.
    public static func start(
        candidate: PatternCandidate, metric: HabitOutcomeMetricID? = nil, now: Date, timeZone: TimeZone,
        reminder: PatternReminder? = nil, id: UUID = UUID(), policy: PatternPolicy = .default
    ) throws -> PatternTest {
        guard let day = PatternDays.key(at: now, timeZoneID: timeZone.identifier) else { throw PatternTestError.invalidTimeZone }
        return PatternTest(
            id: id, candidateID: candidate.id, habitID: candidate.habitID, title: candidate.title,
            predicate: candidate.predicate, outcomeMetric: metric ?? candidate.targetMetric, startDay: day,
            timeZoneID: timeZone.identifier, testDays: policy.testDays, baselineDays: policy.baselineDays,
            reminder: reminder, createdAt: now)
    }

    private enum CodingKeys: String, CodingKey {
        case id, candidateID, habitID, title, predicate, outcomeMetric, startDay, timeZoneID, testDays, baselineDays
        case reminder, reminderProblem, state, keptDays, createdAt, endedAt, schemaVersion
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let candidateID = try c.decodeIfPresent(String.self, forKey: .candidateID) ?? ""
        let title = try c.decodeIfPresent(String.self, forKey: .title) ?? candidateID
        self.init(
            id: try c.decode(UUID.self, forKey: .id),
            candidateID: candidateID,
            habitID: try c.decode(HabitID.self, forKey: .habitID),
            title: title,
            predicate: try c.decodeIfPresent(PatternPredicate.self, forKey: .predicate) ?? .journalAnswer(name: title),
            outcomeMetric: try c.decodeIfPresent(HabitOutcomeMetricID.self, forKey: .outcomeMetric) ?? .sleepScore,
            startDay: try c.decode(String.self, forKey: .startDay),
            timeZoneID: try c.decodeIfPresent(String.self, forKey: .timeZoneID) ?? TimeZone.current.identifier,
            testDays: try c.decodeIfPresent(Int.self, forKey: .testDays) ?? PatternPolicy.default.testDays,
            baselineDays: try c.decodeIfPresent(Int.self, forKey: .baselineDays) ?? PatternPolicy.default.baselineDays,
            reminder: try c.decodeIfPresent(PatternReminder.self, forKey: .reminder),
            reminderProblem: try c.decodeIfPresent(PatternReminderProblem.self, forKey: .reminderProblem),
            state: try c.decodeIfPresent(PatternTestState.self, forKey: .state) ?? .running,
            keptDays: try c.decodeIfPresent([PatternKeptDay].self, forKey: .keptDays) ?? [],
            createdAt: try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? .distantPast,
            endedAt: try c.decodeIfPresent(Date.self, forKey: .endedAt),
            schemaVersion: try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1)
    }

    // MARK: Days

    public var testDayKeys: [String] { PatternDays.range(from: startDay, count: testDays) }
    public var baselineDayKeys: [String] {
        guard let first = PatternDays.add(-baselineDays, to: startDay) else { return [] }
        return PatternDays.range(from: first, count: baselineDays)
    }
    public var endDay: String { testDayKeys.last ?? startDay }
    public var keptDayKeys: [String] { keptDays.map(\.dayKey) }

    public func today(at now: Date) -> String? { PatternDays.key(at: now, timeZoneID: timeZoneID) }

    /// Progress is computed from the stored day keys and the clock only.
    public func progress(at now: Date) -> PatternTestProgress {
        let today = today(at: now) ?? startDay
        let kept = Set(keptDayKeys)
        var statuses: [String: PatternTestDayStatus] = [:]
        var keptCount = 0, missed = 0, elapsed = 0
        for key in testDayKeys {
            if kept.contains(key) { statuses[key] = .kept; keptCount += 1; elapsed += key <= today ? 1 : 0 }
            else if key < today { statuses[key] = .missed; missed += 1; elapsed += 1 }
            else if key == today { statuses[key] = .pending; elapsed += 1 }
            else { statuses[key] = .upcoming }
        }
        let offset = PatternDays.distance(from: startDay, to: today) ?? 0
        return PatternTestProgress(
            totalDays: testDays, dayNumber: min(max(offset + 1, 1), testDays), elapsedDays: elapsed,
            keptCount: keptCount, missedCount: missed, isOver: today > endDay, days: statuses)
    }

    // MARK: Changes

    /// Records that the exposure happened on `day`. Allowed for a test day that
    /// has started, until 48 hours after it ends (the same rule the Journal uses).
    public mutating func keep(day: String, at now: Date) throws {
        guard state == .running || state == .completed else { throw PatternTestError.notRunning }
        guard testDayKeys.contains(day) else { throw PatternTestError.notATestDay }
        guard let today = today(at: now) else { throw PatternTestError.invalidTimeZone }
        guard day <= today else { throw PatternTestError.futureDay }
        guard let end = PatternDays.endOfDay(day, timeZoneID: timeZoneID),
              now <= end.addingTimeInterval(HabitEligibility.responseGracePeriod) else { throw PatternTestError.tooLate }
        guard !keptDayKeys.contains(day) else { return }
        keptDays.append(PatternKeptDay(dayKey: day, recordedAt: now))
        keptDays.sort { $0.dayKey < $1.dayKey }
    }

    /// Takes a kept night back. The day then counts as missed once it has passed.
    public mutating func unkeep(day: String) {
        keptDays.removeAll { $0.dayKey == day }
    }

    /// Moves a running test to `completed` once its last day has passed.
    public mutating func refreshState(at now: Date) {
        guard state == .running, progress(at: now).isOver else { return }
        state = .completed
        endedAt = endedAt ?? PatternDays.endOfDay(endDay, timeZoneID: timeZoneID)
    }

    public mutating func stop(at now: Date) {
        guard state == .running else { return }
        state = .stopped
        endedAt = now
    }

    // MARK: Engine input

    /// Baseline days are `.no`, kept test days `.yes`, missed test days `.skipped`.
    /// Today before it is kept, and future days, have no record.
    public func records(at now: Date) -> [HabitDayRecord] {
        let today = today(at: now) ?? startDay
        let kept = Dictionary(keptDays.map { ($0.dayKey, $0.recordedAt) }, uniquingKeysWith: { first, _ in first })
        var records: [HabitDayRecord] = []
        func add(_ key: String, _ answer: HabitAnswer, at answeredAt: Date?, source: HabitResponseSource) {
            guard let day = DayIdentity(habitKey: key),
                  let stamp = answeredAt ?? PatternDays.endOfDay(key, timeZoneID: timeZoneID) else { return }
            records.append(HabitDayRecord(
                behaviorDay: day, behaviorTimeZoneID: timeZoneID,
                responses: [HabitResponse(habitID: habitID, behaviorDay: day, behaviorTimeZoneID: timeZoneID,
                                          answer: answer, firstAnsweredAt: stamp, firstAnswerSource: source)],
                createdAt: stamp))
        }
        for key in baselineDayKeys { add(key, .no, at: nil, source: .autoFill) }
        for key in testDayKeys {
            if let recordedAt = kept[key] { add(key, .yes, at: recordedAt, source: .sameDay) }
            else if key < today { add(key, .skipped, at: nil, source: .autoFill) }
        }
        return records
    }

    var definition: HabitDefinition {
        HabitDefinition(id: habitID, source: .custom, name: title, question: predicate.question, sortOrder: 0, createdAt: createdAt)
    }
}
