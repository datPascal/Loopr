#if DEBUG
import DomainKit
import Foundation
import JournalKit

/// Source records only. Insights runs the production estimator on this history.
enum FiveTabJournalFixture {
    static var mode: String? {
        let prefix = "--loopr-journal-fixture="
        return ProcessInfo.processInfo.arguments.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
    }
    static let day = DayIdentity(year: 2023, month: 11, day: 14)
    static let zone = "Australia/Perth"
    static var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: zone)!
        return value
    }
    static let note = JournalEntry(id: UUID(uuidString: "00000000-0000-0000-0000-000000001400")!,
        day: "2023-11-14", tags: ["work", "knee"],
        note: "Big meeting at 14:00. Left knee a bit sore after squats.",
        createdAt: Date(timeIntervalSince1970: 1_700_000_000), updatedAt: Date(timeIntervalSince1970: 1_700_000_000))

    static func makeStore(insights: Bool) -> InMemoryHabitStore {
        let end = calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day))!
        let catalog = insights
            ? ["alcohol", "meal_within_two_hours", "read_before_bed", "late_caffeine", "sauna"]
            : ["alcohol", "late_caffeine", "meal_within_two_hours", "screens_in_bed", "read_before_bed", "feeling_sick"]
        let definitions = catalog.enumerated().map { index, id in
            let item = HabitCatalog.byID[id]!
            return HabitDefinition(id: .init(rawValue: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", 1401 + index))!),
                source: .preset(catalogID: id), name: item.name, question: item.question,
                sortOrder: index, createdAt: end.addingTimeInterval(-120 * 86400))
        }
        var records: [HabitDayRecord] = []
        var outcomes: [HabitOutcomeSnapshot] = []
        var random: UInt64 = 79
        var priorMood = JournalRating.four
        for index in 0...120 {
            let date = calendar.date(byAdding: .day, value: index - 120, to: end)!
            let behavior = identity(date)
            let answered = date.addingTimeInterval(21 * 3600)
            random = random &* 2_862_933_555_777_941_757 &+ 3_037_000_493
            let flags: [Bool] = (0..<definitions.count).map { offset in
                let shift = 12 + offset * 7
                return ((random >> shift) & UInt64(1)) == UInt64(1)
            }
            var responses: [HabitResponse] = []
            if index < 120 {
                responses = definitions.enumerated().compactMap { offset, definition -> HabitResponse? in
                    if catalog[offset] == "sauna", index < 109 { return nil }
                    if !insights && index == 119 { return nil }
                    let yes = catalog[offset] == "sauna" ? index < 117 : flags[offset]
                    return HabitResponse(habitID: definition.id, behaviorDay: behavior, behaviorTimeZoneID: zone,
                        answer: yes ? .yes : .no,
                        firstAnsweredAt: answered, firstAnswerSource: .sameDay)
                }
                if !insights && index == 119 {
                    let source = foodSnapshot(day: behavior, start: date)
                    responses = definitions.compactMap { definition -> HabitResponse? in
                        guard case .preset(let id) = definition.source,
                              let question = JournalAutoFillQuestion(rawValue: id), let answer = source.answers[question] else { return nil }
                        return HabitResponse(habitID: definition.id, behaviorDay: behavior, behaviorTimeZoneID: zone,
                            answer: answer.answer, firstAnsweredAt: date.addingTimeInterval(23.75 * 3600),
                            firstAnswerSource: .autoFill, autoFillProvenance: answer.provenance)
                    }
                }
                let effect = (flags[0] ? -14.0 : 0) + (flags[1] ? -9.0 : 0) + (flags[2] ? 6.0 : 0)
                let noise = Double((random >> 48) % 9) - 4
                outcomes.append(.init(behaviorDay: behavior, behaviorTimeZoneID: zone,
                    sleepSessionID: "journal-visual-night-\(index)", sleepStartedAt: date.addingTimeInterval(23 * 3600),
                    sleepEndedAt: date.addingTimeInterval(31 * 3600), outcomeDay: identity(date.addingTimeInterval(86400)),
                    metrics: [.recoveryScore: 79 + effect + noise, .hrvRMSSD: 61 + effect + noise,
                        .deepSleepMinutes: 100 + effect * 2 + noise, .restingHeartRate: 55 - effect / 3 + noise / 3],
                    priorDayStrain: 9 + Double(index % 5), sourceVersions: ["fixture": "journal-visual-v1"],
                    builtAt: end.addingTimeInterval(9 * 3600)))
            }
            let wellbeing = JournalWellbeing(mood: index == 120 ? .four : priorMood,
                energy: index == 120 ? .four : nil, stress: index == 120 ? .two : nil,
                soreness: index == 120 ? [.legs] : nil, firstAnsweredAt: ["Mood": date.addingTimeInterval(9 * 3600)])
            records.append(.init(behaviorDay: behavior, behaviorTimeZoneID: zone, responses: responses,
                createdAt: date, wellbeing: wellbeing))
            priorMood = JournalRating(rawValue: 2 + Int((random >> 40) % 4))!
        }
        return InMemoryHabitStore(definitions: definitions, dayRecords: records, outcomes: outcomes)
    }

    /// The launch's comparison run, started with the store.
    private static var comparisons: Task<Void, Never>?

    /// Works out the comparisons once, in the background at launch. A person who has used Loopr for months has them
    /// stored already, so Mood and habit links opens on numbers and not on the first long calculation (ICP R2-VET-13,
    /// R3-HAB-04). It runs at the user-initiated priority, since the screen waits for it.
    static func precomputeComparisons(_ store: InMemoryHabitStore) {
        let at = calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: 21)) ?? Date()
        comparisons = Task.detached(priority: .userInitiated) {
            _ = try? await HabitInsightEngine().recalculateAll(store: store, calculatedAt: at)
        }
    }

    /// The Journal's insight preparation on the fixture: waits for the launch's run instead of starting a second one
    /// beside it, so the stored comparisons show as soon as it is done.
    static func waitForComparisons() async {
        await comparisons?.value
    }

    private static func identity(_ date: Date) -> DayIdentity {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return .init(year: parts.year!, month: parts.month!, day: parts.day!)
    }

    private static func foodSnapshot(day: DayIdentity, start: Date) -> JournalAutoFillSnapshot {
        func source(_ id: String, _ title: String, _ hour: Double, domain: JournalAutoFillDomain = .food) -> JournalSourceRecord {
            let date = start.addingTimeInterval(hour * 3600)
            return .init(id: id, domain: domain, title: title, occurredAt: date, updatedAt: date)
        }
        let food = JournalFoodDay(records: [
            .init(source: source("coffee", "Coffee at 10:15", 10.25), alcoholUnits: 0, caffeineMilligrams: 80, isMeal: false),
            .init(source: source("dinner", "Dinner at 19:10", 19 + 1.0 / 6), alcoholUnits: 0, caffeineMilligrams: 0, isMeal: true)
        ], completion: source("completed-log", "Completed food log", 23.5),
           bedtime: source("bedtime", "Main sleep", 23, domain: .sleep))
        return try! JournalAutoFillProjection.snapshot(day: day, timeZoneID: zone, food: food)
    }
}
#endif
