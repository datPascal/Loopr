import DomainKit
import Foundation

/// Joins a recorded mood to the previous civil day's behavior. A mood-only
/// outcome has no sleep session; it never manufactures band measurements.
public enum JournalMoodOutcomes {
    public static func merge(records: [HabitDayRecord], outcomes: [HabitOutcomeSnapshot],
                             builtAt: Date) -> [HabitOutcomeSnapshot] {
        let recordsByDay = Dictionary(uniqueKeysWithValues: records.map { ($0.behaviorDay, $0) })
        var result = Dictionary(uniqueKeysWithValues: outcomes.compactMap { outcome -> (DayIdentity, HabitOutcomeSnapshot)? in
            let metrics = outcome.metrics.filter { $0.key != .mood }
            guard !metrics.isEmpty else { return nil }
            return (outcome.behaviorDay, copy(outcome, metrics: metrics, builtAt: builtAt))
        })
        for record in records {
            guard let mood = record.wellbeing?.mood,
                  let answered = record.wellbeing?.firstAnsweredAt?[JournalFeeling.mood.rawValue],
                  answered.timeIntervalSince1970.isFinite, answered <= builtAt,
                  let zone = TimeZone(identifier: record.behaviorTimeZoneID) else { continue }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            let day = record.behaviorDay
            guard let date = calendar.date(from: DateComponents(era: day.era, year: day.year, month: day.month, day: day.day)),
                  answered >= date,
                  let deadline = HabitEligibility.deadline(for: day, timeZoneID: record.behaviorTimeZoneID), answered <= deadline,
                  let previous = calendar.date(byAdding: .day, value: -1, to: date) else { continue }
            let parts = calendar.dateComponents([.era, .year, .month, .day], from: previous)
            guard let year = parts.year, let month = parts.month, let day = parts.day else { continue }
            let behaviorDay = DayIdentity(era: parts.era ?? 1, year: year, month: month, day: day)
            if let behavior = recordsByDay[behaviorDay], behavior.behaviorTimeZoneID != record.behaviorTimeZoneID { continue }
            if let old = result[behaviorDay], old.behaviorTimeZoneID != record.behaviorTimeZoneID { continue }
            let old = result[behaviorDay]
            var metrics = old?.metrics ?? [:]
            metrics[.mood] = Double(mood.rawValue)
            var versions = old?.sourceVersions ?? [:]
            versions["journal.mood"] = "rating.v1"
            result[behaviorDay] = HabitOutcomeSnapshot(behaviorDay: behaviorDay,
                behaviorTimeZoneID: record.behaviorTimeZoneID,
                sleepSessionID: old?.sleepSessionID, sleepStartedAt: old?.sleepStartedAt, sleepEndedAt: old?.sleepEndedAt,
                outcomeDay: record.behaviorDay, metrics: metrics, priorDayStrain: old?.priorDayStrain,
                sourceVersions: versions, builtAt: builtAt)
        }
        return result.values.sorted { $0.behaviorDay.habitKey < $1.behaviorDay.habitKey }
    }

    private static func copy(_ outcome: HabitOutcomeSnapshot, metrics: [HabitOutcomeMetricID: Double], builtAt: Date) -> HabitOutcomeSnapshot {
        HabitOutcomeSnapshot(behaviorDay: outcome.behaviorDay, behaviorTimeZoneID: outcome.behaviorTimeZoneID,
            sleepSessionID: outcome.sleepSessionID, sleepStartedAt: outcome.sleepStartedAt, sleepEndedAt: outcome.sleepEndedAt,
            outcomeDay: outcome.outcomeDay, metrics: metrics, priorDayStrain: outcome.priorDayStrain,
            sourceVersions: outcome.sourceVersions.filter { $0.key != "journal.mood" }, builtAt: builtAt)
    }
}
