import AnalyticsKit
import BodyKit
import DesignSystem
import DomainKit
import Foundation
import HeartKit
import SleepKit
import StorageKit
import TodayKit

/// Where the shared day selection learns which days hold data.
///
/// Every call runs off the main actor. `knowledge(today:)` only reads
/// indexes; `hasData(day:)` is the one call that may derive, and it derives
/// the same generation the screens would read anyway.
nonisolated protocol LooprDayDataSource: Sendable {
    func knowledge(today: DayIdentity) async -> LooprDayKnowledge
    /// Whether `day` has data, deriving it when it has never been derived.
    /// Nil when that could not be settled right now (storage error, or the
    /// derivation budget said no).
    func hasData(day: DayIdentity) async -> Bool?
    /// Whether a finished generation for `day` is already saved, so reading
    /// it costs a document read rather than a derivation.
    func isCached(day: DayIdentity) async -> Bool
}

/// The production source: the screen analytics engine and its history.
nonisolated struct AnalyticsDayDataSource: LooprDayDataSource {
    let analytics: CanonicalDailyAnalytics

    func knowledge(today: DayIdentity) async -> LooprDayKnowledge {
        (try? await analytics.dayKnowledge(today: today)) ?? LooprDayKnowledge()
    }

    func hasData(day: DayIdentity) async -> Bool? {
        try? await analytics.dayHasData(day: day)
    }

    func isCached(day: DayIdentity) async -> Bool {
        await analytics.hasSavedDisplay(day: day)
    }
}

/// Decides "has data" for one derived day. The same mapping writes the
/// metric history, so the in-memory answer and the stored index agree.
nonisolated enum LooprDayDataPolicy {
    static func hasData(_ display: CanonicalDayDisplay) -> Bool {
        BandMetricSeriesMapping.values(projection: display.projection, today: display.today)
            .contains { key, value in key != .maxHeartRate && value != nil }
    }
}

#if DEBUG
/// DEBUG fixture launches: a few days around the fixture day so day
/// navigation can be seen and tested without a database. Days carry the
/// fixture day's own numbers, moved to their date. Nothing here is reachable
/// from the production composition.
nonisolated enum FixtureDayHistory {
    /// Offsets from the fixture day that carry numbers. -2 is left empty on
    /// purpose, so the gap state shows too.
    static let offsetsWithData = [0, -1, -3]

    static func hasHistory(_ composition: AppEnvironment.Composition) -> Bool {
        composition == .populated
    }

    static func days(around fixtureDay: DayIdentity, composition: AppEnvironment.Composition,
                     calendar: Calendar) -> [DayIdentity] {
        guard hasHistory(composition) else { return [fixtureDay] }
        return offsetsWithData.compactMap { LooprDays.adding($0, to: fixtureDay, calendar: calendar) }
    }

    /// `value` keyed by every fixture day, each copy re-dated through its
    /// Codable `day` field.
    static func values<Value: Codable>(_ value: Value, fixtureDay: DayIdentity,
                                        composition: AppEnvironment.Composition) -> [DayIdentity: Value] {
        let calendar = LooprDays.calendar(TimeZone(secondsFromGMT: 0)!)
        var result: [DayIdentity: Value] = [:]
        for day in days(around: fixtureDay, composition: composition, calendar: calendar) {
            result[day] = day == fixtureDay ? value : redated(value, to: day)
        }
        return result
    }

    static func knowledge(fixtureDay: DayIdentity, composition: AppEnvironment.Composition,
                          hasData: Bool) -> LooprDayKnowledge {
        let calendar = LooprDays.calendar(TimeZone(secondsFromGMT: 0)!)
        let days = days(around: fixtureDay, composition: composition, calendar: calendar)
        var knowledge = LooprDayKnowledge()
        if hasData {
            knowledge.withData = Set(days)
            knowledge.recorded = Set(days)
            knowledge.earliestRecorded = days.min(by: LooprDays.isEarlier)
            knowledge.lastRecordAt = Date(timeIntervalSince1970: 1_700_000_000 - 120)
        }
        return knowledge
    }

    private static func redated<Value: Codable>(_ value: Value, to day: DayIdentity) -> Value? {
        guard let data = try? JSONEncoder().encode(value),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dayData = try? JSONEncoder().encode(day),
              let dayObject = try? JSONSerialization.jsonObject(with: dayData) else { return nil }
        object["day"] = dayObject
        guard let moved = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return try? JSONDecoder().decode(Value.self, from: moved)
    }
}

/// The fixture source answers from the fixed set above.
nonisolated struct FixtureDayDataSource: LooprDayDataSource {
    let knowledgeValue: LooprDayKnowledge

    func knowledge(today: DayIdentity) async -> LooprDayKnowledge { knowledgeValue }
    func hasData(day: DayIdentity) async -> Bool? { knowledgeValue.withData.contains(day) }
    func isCached(day: DayIdentity) async -> Bool { true }
}
#endif

extension ProductFixture {
    /// A fixture composition's in-memory values, keyed by day. DEBUG fixture
    /// launches with day history get a few days; everything else keeps the
    /// single fixture day.
    static func days<Value: Codable>(_ value: Value, day: DayIdentity,
                                     composition: AppEnvironment.Composition) -> [DayIdentity: Value] {
        #if DEBUG
        return FixtureDayHistory.values(value, fixtureDay: day, composition: composition)
        #else
        return [day: value]
        #endif
    }
}
