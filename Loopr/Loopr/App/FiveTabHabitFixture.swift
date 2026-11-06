#if DEBUG
import DomainKit
import Foundation
import JournalKit

/// Synthetic source answers and outcomes pass through the production estimator.
/// The fixture never supplies a precomputed association or changes the rollout gate.
enum FiveTabHabitFixture {
    static func makeStore(endingOn day: DayIdentity) async throws -> InMemoryHabitStore {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Australia/Perth")!
        let end = calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day))!
        let names = ["Alcohol", "Sleep over 7 h 30 m", "Dinner before 20:00"]
        let definitions = names.enumerated().map { index, name in
            HabitDefinition(id: HabitID(rawValue: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", 3001 + index))!),
                source: .custom, name: name, question: name + "?", sortOrder: index,
                createdAt: end.addingTimeInterval(-120 * 86_400))
        }
        var records: [HabitDayRecord] = []
        var outcomes: [HabitOutcomeSnapshot] = []
        var random: UInt64 = 41
        for index in 0..<120 {
            let date = calendar.date(byAdding: .day, value: index - 120, to: end)!
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            let behavior = DayIdentity(year: parts.year!, month: parts.month!, day: parts.day!)
            let next = calendar.dateComponents([.year, .month, .day], from: date.addingTimeInterval(86_400))
            random = random &* 2_862_933_555_777_941_757 &+ 3_037_000_493
            let flags = (0..<3).map { ((random >> (16 + $0 * 8)) & 1) == 1 }
            let answered = date.addingTimeInterval(21 * 3600)
            let responses = definitions.enumerated().map { offset, definition in
                HabitResponse(habitID: definition.id, behaviorDay: behavior, behaviorTimeZoneID: "Australia/Perth",
                    answer: flags[offset] ? .yes : .no, firstAnsweredAt: answered, firstAnswerSource: .sameDay)
            }
            records.append(HabitDayRecord(behaviorDay: behavior, behaviorTimeZoneID: "Australia/Perth",
                responses: responses, completedAt: answered, createdAt: answered))
            let effect = (flags[0] ? -10.0 : 0) + (flags[1] ? 7.0 : 0) + (flags[2] ? 5.0 : 0)
            let noise = Double((random >> 40) % 9) - 4
            outcomes.append(HabitOutcomeSnapshot(behaviorDay: behavior, behaviorTimeZoneID: "Australia/Perth",
                sleepSessionID: "five-tab-night-\(index)", sleepStartedAt: date.addingTimeInterval(23 * 3600),
                sleepEndedAt: date.addingTimeInterval(31 * 3600),
                outcomeDay: DayIdentity(year: next.year!, month: next.month!, day: next.day!),
                metrics: [.recoveryScore: 74 + effect + noise, .hrvRMSSD: 56 + effect + noise,
                          .sleepDuration: 450 + effect * 2 + noise, .restingHeartRate: 57 - effect / 4 + noise / 3],
                priorDayStrain: 9 + Double(index % 5), sourceVersions: ["fixture": "five-tabs-v1"], builtAt: end))
        }
        let store = InMemoryHabitStore(definitions: definitions, dayRecords: records, outcomes: outcomes)
        try await HabitInsightEngine().recalculateAll(store: store, calculatedAt: end)
        return store
    }
}
#endif
