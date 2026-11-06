import DomainKit
import Foundation

/// One yes or no answer for one local day.
public struct PatternExposureDay: Codable, Equatable, Hashable, Sendable {
    public let dayKey: String
    public let timeZoneID: String
    public let exposed: Bool
    /// When the answer was first recorded. Nil means "at the end of that local
    /// day", which is how derived exposures (food, workouts, steps) are stamped.
    public let answeredAt: Date?

    public init(dayKey: String, timeZoneID: String, exposed: Bool, answeredAt: Date? = nil) {
        self.dayKey = dayKey
        self.timeZoneID = timeZoneID
        self.exposed = exposed
        self.answeredAt = answeredAt
    }

    public init?(response: HabitResponse) {
        guard response.answer != .skipped else { return nil }
        self.init(dayKey: response.behaviorDay.habitKey, timeZoneID: response.behaviorTimeZoneID,
                  exposed: response.answer == .yes, answeredAt: response.firstAnsweredAt)
    }
}

/// All days the app can answer for one candidate. A day that is absent is
/// unknown, never `no`.
public struct PatternExposureSeries: Equatable, Sendable {
    public let candidateID: String
    public let days: [PatternExposureDay]

    public init(candidateID: String, days: [PatternExposureDay]) {
        self.candidateID = candidateID
        self.days = days
    }

    /// Journal answers for one habit, from stored day records.
    public static func journal(candidate: PatternCandidate, records: [HabitDayRecord]) -> PatternExposureSeries {
        .init(candidateID: candidate.id, days: records.compactMap { record in
            record.response(for: candidate.habitID).flatMap(PatternExposureDay.init(response:))
        })
    }
}

public struct PatternOutcomeSet: Equatable, Sendable {
    public let outcomes: [HabitOutcomeSnapshot]
    public let exclusions: [HabitOutcomeExclusionRecord]

    public init(outcomes: [HabitOutcomeSnapshot], exclusions: [HabitOutcomeExclusionRecord] = []) {
        self.outcomes = outcomes
        self.exclusions = exclusions
    }
}

/// The app resolves next-morning outcomes (sleep, HRV, recovery, mood) here.
public protocol PatternOutcomeProviding: Sendable {
    /// One outcome per record day where the app has one. The records carry the
    /// behavior day and time zone, like `AppHabitOutcomeResolver.resolve(record:)` takes.
    func outcomes(forRecords records: [HabitDayRecord]) async throws -> PatternOutcomeSet
}

/// The app supplies exposures; JournalKit owns the statistics.
public protocol PatternExposureProvider: PatternOutcomeProviding {
    /// The candidates to look at, normally from `PatternCandidate.catalog`.
    func candidates() async throws -> [PatternCandidate]
    /// Yes or no answers per candidate for the `windowDays` days up to and including `day`.
    func exposures(endingOn day: String, windowDays: Int) async throws -> [PatternExposureSeries]
}
