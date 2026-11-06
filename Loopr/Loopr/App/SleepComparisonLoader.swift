import DomainKit
import FoodKit
import Foundation
import JournalKit
import SleepKit
import TrainKit
import WorkoutKit

/// Reads the last 29 days from Food, Journal, Train, Sleep and the step history, then compares one night with the
/// 28 days before it. It runs on this phone and sends nothing. `SleepNightComparison` decides what differs.
@MainActor
struct SleepComparisonLoader {
    static let windowDays = SleepNightComparison.windowDays

    let environment: AppEnvironment
    let repositories: ProductRepositoryContainer?
    let history: any MetricHistoryProviding

    private var isFixture: Bool { repositories?.isFixtureComposition != false }

    /// The zone Food, Train and Journal record in. Fixtures live in Perth. Everything else uses the phone's zone.
    private var recordingZone: TimeZone {
        isFixture ? (TimeZone(identifier: "Australia/Perth") ?? .gmt) : environment.timeZoneProvider.timeZone
    }

    func load(night day: DayIdentity) async -> SleepNightComparison? {
        // The window needs the day before the night and the 28 days before that, one day each.
        let keys = (0...Self.windowDays).compactMap { offset in Self.key(day, minusDays: offset) }
        guard let first = keys.last, let last = keys.first else { return nil }
        let dinners = await dinnerMinutes(from: Self.key(day, minusDays: Self.windowDays + 1) ?? first, through: Self.key(day, minusDays: 1) ?? last)
        let alcohol = await alcoholAnswers()
        let trained = await trainedDays()
        let steps = await stepCounts(endingOn: day)
        var bedtimes: [String: Int] = [:]
        for key in keys {
            guard let identity = DayIdentity(habitKey: key), let minute = await bedtimeMinute(day: identity) else { continue }
            bedtimes[key] = minute
        }
        let hasTraining = !trained.isEmpty
        func facts(_ key: String) -> SleepComparisonDay {
            // The evening and the day before the night that ends on `key`.
            let before = Self.key(DayIdentity(habitKey: key) ?? day, minusDays: 1)
            return SleepComparisonDay(
                day: key, dinnerMinute: before.flatMap { dinners[$0] }, alcohol: before.flatMap { alcohol[$0] },
                trained: hasTraining ? before.map { trained.contains($0) } : nil,
                bedtimeMinute: bedtimes[key], steps: before.flatMap { steps[$0] })
        }
        let current = facts(keys[0])
        return SleepNightComparison.make(night: current, history: keys.dropFirst().map(facts))
    }

    // MARK: Food

    /// The start of the last dinner of each evening, by the day the dinner was on.
    private func dinnerMinutes(from first: String, through last: String) async -> [String: Int] {
        let repository: AppFoodRepository?
        if let persistent = repositories?.persistent { repository = AppFoodRepository(store: persistent.food, environment: environment) }
        else {
            #if DEBUG
            repository = repositories?.fixtureFoodRepository
            #else
            repository = nil
            #endif
        }
        guard let repository, let data = try? await repository.overview(from: first, through: last) else { return [:] }
        var result: [String: (at: Date, minute: Int)] = [:]
        for meal in data.meals where meal.slot == .dinner {
            let fact = TodayMealFact(meal)
            if let known = result[meal.localDay], known.at >= meal.occurredAt { continue }
            result[meal.localDay] = (meal.occurredAt, fact.minuteOfDay)
        }
        return result.mapValues(\.minute)
    }

    // MARK: Journal

    /// The alcohol question's answer by behaviour day. A skipped question is left out.
    private func alcoholAnswers() async -> [String: Bool] {
        let store: (any HabitStore)?
        if let persistent = repositories?.persistent { store = persistent.habits }
        else {
            #if DEBUG
            store = repositories?.fixtureHabitStore
            #else
            store = nil
            #endif
        }
        guard let store, let definitions = try? await store.definitions(includeArchived: true),
              let definition = definitions.first(where: { Self.isAlcohol($0) }),
              let records = try? await store.dayRecords() else { return [:] }
        var answers: [String: Bool] = [:]
        for record in records {
            guard let response = record.response(for: definition.id) else { continue }
            switch response.answer {
            case .yes: answers[record.behaviorDay.habitKey] = true
            case .no: answers[record.behaviorDay.habitKey] = false
            default: break
            }
        }
        return answers
    }

    static func isAlcohol(_ definition: HabitDefinition) -> Bool {
        if case .preset(let id) = definition.source, id == "alcohol" { return true }
        return definition.name.localizedCaseInsensitiveCompare("Alcohol") == .orderedSame
    }

    // MARK: Train

    private func trainedDays() async -> Set<String> {
        var days: Set<String> = []
        if let train = repositories?.makeTrainRepository(), let sessions = try? await train.recentSessions(limit: 500, status: .completed) {
            days.formUnion(sessions.map(\.localDay))
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = recordingZone
        if let store = repositories?.workoutStore {
            for workout in await store.all() where workout.state == .completed {
                guard let start = workout.startedAt else { continue }
                let parts = calendar.dateComponents([.year, .month, .day], from: start)
                days.insert(String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0))
            }
        }
        return days
    }

    // MARK: Sleep and steps

    private func bedtimeMinute(day: DayIdentity) async -> Int? {
        let repository = SleepNightDetails.repository(environment: environment, repositories: repositories)
        guard let night = try? await repository.readSleepDay(for: day)?.mainSleep, !night.isPartial, night.confidence >= 0.5,
              night.end > night.start else { return nil }
        let parts = SleepClock.calendar(environment: environment, repositories: repositories).dateComponents([.hour, .minute], from: night.start)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    private func stepCounts(endingOn day: DayIdentity) async -> [String: Double] {
        let calendar = SleepClock.calendar(environment: environment, repositories: repositories)
        guard let end = calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: 12)),
              let points = try? await history.series(for: .steps, days: Self.windowDays + 2, endingOn: end) else { return [:] }
        var result: [String: Double] = [:]
        for point in points {
            let parts = calendar.dateComponents([.year, .month, .day], from: point.day)
            result[String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)] = point.value
        }
        return result
    }

    // MARK: Day arithmetic

    /// `yyyy-MM-dd`, `days` before `day`. Pure string arithmetic on civil dates, so a clock change never shifts it.
    static func key(_ day: DayIdentity, minusDays days: Int) -> String? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: 12)),
              let shifted = calendar.date(byAdding: .day, value: -days, to: date) else { return nil }
        let parts = calendar.dateComponents([.year, .month, .day], from: shifted)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
