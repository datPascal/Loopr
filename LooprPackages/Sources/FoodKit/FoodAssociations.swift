import DomainKit
import Foundation
import JournalKit

/// Food-derived answers use the same eligibility and comparison engine as Journal.
public enum FoodAssociationKind: Int, CaseIterable, Sendable, Hashable {
    case lateMeal, proteinTarget, alcohol, lateCaffeine
    /// The two the Food tab's association screen draws. Patterns reads every kind.
    public static let foodScreenKinds: [Self] = [.lateMeal, .proteinTarget]
    /// Caffeine at or after this local hour counts as late, as in Journal's "Had caffeine after 2 p.m.?".
    public static let lateCaffeineHour = 14
    public var id: HabitID {
        HabitID(rawValue: UUID(uuidString: String(format: "FC100000-0000-4000-8000-%012d", rawValue + 1))!)
    }
    public var title: String {
        switch self {
        case .lateMeal: "Late dinner and deep sleep"
        case .proteinTarget: "Protein and next-day recovery"
        case .alcohol: "Alcohol and next-day recovery"
        case .lateCaffeine: "Late caffeine and sleep"
        }
    }
    public var target: JournalInsightTarget {
        switch self {
        case .lateMeal, .lateCaffeine: .deepSleep
        case .proteinTarget, .alcohol: .recovery
        }
    }
    public func definition(at date: Date) -> HabitDefinition {
        let (name, question): (String, String) = switch self {
        case .lateMeal: ("Last meal after 21:00", "Was your last meal after 21:00?")
        case .proteinTarget: ("Protein target met", "Did you meet your protein target?")
        case .alcohol: ("Alcohol", "Did you drink alcohol?")
        case .lateCaffeine: ("Caffeine after 14:00", "Did you have caffeine after 14:00?")
        }
        return .init(id: id, source: .custom, name: name, question: question, sortOrder: rawValue, createdAt: date)
    }
}

public struct FoodSleepPoint: Identifiable, Sendable {
    public let day: String
    public let lastMealHour: Double
    public let deepSleepMinutes: Double
    public var id: String { day }
}

public struct FoodAssociationInput: Sendable {
    public let days: [FoodDaySummary]
    public let trainingDays: Set<String>?
    public let records: [HabitDayRecord]
    public let definitions: [HabitDefinition]
    public let endDay: String
    public let recentStartDay: String
    public init(data: FoodOverviewData, endingOn date: Date, calendar: Calendar, trainingDays: Set<String>?) throws {
        endDay = try FoodMeal.day(at: date, timeZoneIdentifier: calendar.timeZone.identifier)
        self.trainingDays = trainingDays
        // The Food tab analyses the kinds it draws. Patterns reads every kind's answers from `records`.
        definitions = FoodAssociationKind.foodScreenKinds.map { $0.definition(at: date) }
        var summaries: [FoodDaySummary] = []
        var records: [HabitDayRecord] = []
        guard let start = calendar.date(byAdding: .day, value: -119, to: date),
              let recentStart = calendar.date(byAdding: .day, value: -29, to: date),
              Set(data.days.map(\.localDay)).count == data.days.count else { throw FoodError.invalidRecord }
        recentStartDay = try FoodMeal.day(at: recentStart, timeZoneIdentifier: calendar.timeZone.identifier)
        let startDay = try FoodMeal.day(at: start, timeZoneIdentifier: calendar.timeZone.identifier)
        for record in data.days where record.localDay >= startDay && record.localDay <= endDay {
            guard let zone = TimeZone(identifier: record.timeZoneIdentifier), let completed = record.completedAt,
                  let day = DayIdentity(habitKey: record.localDay) else { continue }
            var local = Calendar(identifier: .gregorian); local.timeZone = zone
            let summary = try FoodDaySummary(date: record.dayStart, calendar: local, data: data)
            // A date with conflicting recorded zones cannot establish one local cutoff.
            guard summary.meals.allSatisfy({ $0.timeZoneIdentifier == record.timeZoneIdentifier }),
                  summary.drinks.allSatisfy({ $0.timeZoneIdentifier == record.timeZoneIdentifier }) else { continue }
            summaries.append(summary)
            let confirmed = (summary.meals.map(\.confirmedAt) + summary.drinks.map(\.confirmedAt)).reduce(completed, max)
            var answers: [HabitResponse] = []
            func append(_ kind: FoodAssociationKind, _ yes: Bool) {
                answers.append(.init(habitID: kind.id, behaviorDay: day, behaviorTimeZoneID: zone.identifier,
                    answer: yes ? .yes : .no, firstAnsweredAt: confirmed, firstAnswerSource: .autoFill))
            }
            if let last = summary.meals.map(\.occurredAt).max() {
                let components = local.dateComponents([.hour, .minute, .second], from: last)
                let seconds = (components.hour ?? 0) * 3600 + (components.minute ?? 0) * 60 + (components.second ?? 0)
                append(.lateMeal, seconds > 21 * 3600)
            }
            let protein = summary.total(.protein)
            if protein.isComplete, let value = protein.knownValue, let target = summary.settings?.protein {
                append(.proteinTarget, value >= target)
            }
            // The day is marked complete, so everything drunk was logged. A drink or item that reports alcohol or caffeine
            // counts; one that reports nothing does not.
            func positive(_ value: Double?) -> Bool { value.map { $0.isFinite && $0 > 0 } ?? false }
            let alcohol = summary.drinks.contains { positive($0.alcoholUnits) } || summary.items.contains { positive($0.nutrients[.alcoholUnits]) }
            append(.alcohol, alcohol)
            func isLate(_ date: Date) -> Bool { local.component(.hour, from: date) >= FoodAssociationKind.lateCaffeineHour }
            let lateCaffeine = summary.drinks.contains { isLate($0.occurredAt) && positive($0.caffeineMilligrams) }
                || summary.meals.contains { meal in isLate(meal.occurredAt) && meal.items.contains { positive($0.nutrients[.caffeine]) } }
            append(.lateCaffeine, lateCaffeine)
            records.append(.init(behaviorDay: day, behaviorTimeZoneID: zone.identifier, responses: answers,
                completedAt: completed, createdAt: confirmed))
        }
        self.days = summaries.sorted { $0.localDay < $1.localDay }
        self.records = records
    }
    /// The day records with only the answers the Food tab analyses. The 2,000-replicate estimator runs once per kind,
    /// so analysing kinds the screen never draws only made it slower.
    public var screenRecords: [HabitDayRecord] {
        let shown = Set(definitions.map(\.id))
        return records.compactMap { record in
            var record = record
            record.responses = record.responses.filter { shown.contains($0.habitID) }
            return record.responses.isEmpty ? nil : record
        }
    }
    public func analyze(outcomes: [HabitOutcomeSnapshot], exclusions: [HabitOutcomeExclusionRecord] = [], at now: Date) async throws -> FoodAssociationReport {
        let store = InMemoryHabitStore(definitions: definitions, dayRecords: screenRecords, outcomes: outcomes)
        for value in exclusions { await store.saveOutcomeExclusion(value) }
        let estimates = try await HabitInsightEngine().recalculateAll(store: store, calculatedAt: now, endingOn: DayIdentity(habitKey: endDay))
        return .init(input: self, outcomes: outcomes, estimates: estimates)
    }
}

public struct FoodAssociationReport: Sendable {
    public let input: FoodAssociationInput
    public let estimates: [HabitImpactEstimate]
    public let points: [FoodSleepPoint]
    public let recentDays: [FoodDaySummary]
    init(input: FoodAssociationInput, outcomes: [HabitOutcomeSnapshot], estimates: [HabitImpactEstimate]) {
        self.input = input; self.estimates = estimates
        recentDays = input.days.filter { $0.localDay >= input.recentStartDay }
        points = recentDays.compactMap { day in
            guard let response = input.records.first(where: { $0.behaviorDay.habitKey == day.localDay })?.response(for: FoodAssociationKind.lateMeal.id),
                  HabitEligibility.isEligible(response),
                  let outcome = outcomes.first(where: { $0.behaviorDay.habitKey == day.localDay }),
                  outcome.behaviorTimeZoneID == response.behaviorTimeZoneID,
                  let deep = outcome.metrics[.deepSleepMinutes], deep.isFinite, deep >= 0,
                  let sleepStart = outcome.sleepStartedAt, let sleepEnd = outcome.sleepEndedAt,
                  deep <= sleepEnd.timeIntervalSince(sleepStart) / 60,
                  let last = day.meals.map(\.occurredAt).max(), let zone = TimeZone(identifier: response.behaviorTimeZoneID) else { return nil }
            var local = Calendar(identifier: .gregorian); local.timeZone = zone
            let parts = local.dateComponents([.hour, .minute], from: last)
            return FoodSleepPoint(day: day.localDay, lastMealHour: Double(parts.hour ?? 0) + Double(parts.minute ?? 0) / 60, deepSleepMinutes: deep)
        }
    }
    public func row(_ kind: FoodAssociationKind) -> JournalInsightRow {
        .init(definition: kind.definition(at: .distantPast), target: kind.target,
              estimate: estimates.first { $0.habitID == kind.id })
    }
    public func protein(training: Bool) -> Double? {
        guard let trainingDays = input.trainingDays else { return nil }
        return Self.mean(recentDays.filter { trainingDays.contains($0.localDay) == training }.compactMap { day in
            let total = day.total(.protein); return total.isComplete ? total.knownValue : nil
        })
    }
    public var fiberValues: [Double] { recentDays.compactMap { day in let total = day.total(.fibre); return total.isComplete ? total.knownValue : nil } }
    public var fiber: Double? { Self.mean(fiberValues) }
    public var eatingWindowMinutes: Double? {
        Self.mean(recentDays.compactMap { day in
            guard let first = day.meals.map(\.occurredAt).min(), let last = day.meals.map(\.occurredAt).max() else { return nil }
            return last.timeIntervalSince(first) / 60
        })
    }
    private static func mean(_ values: [Double]) -> Double? { values.isEmpty ? nil : values.reduce(0, +) / Double(values.count) }
}
