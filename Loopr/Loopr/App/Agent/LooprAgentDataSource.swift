import AIKit
import BodyKit
import CycleKit
import FoodKit
import Foundation
import JournalKit
import TrainKit
import WorkoutKit

/// Reads Loopr's saved data for the Ask tools. Nothing here checks Your data. `AgentReaders` does
/// that before it hands any of these methods to a tool.
nonisolated struct LooprAgentDataSource: AgentDataSource {
    private let foodStore: FoodStore
    private let trainStore: TrainStore
    private let workouts: SQLiteWorkoutStore
    private let habits: SQLiteHabitRepository
    private let journal: SQLiteJournalRepository
    private let cycle: SQLiteCycleRepository
    private let body: (any BodyRepository)?
    private let history: any MetricHistoryProviding
    private let patternStore: (any PatternStore)?
    private let timeZone: TimeZone
    /// Protocol, supplements, blood tests, capacity and ages (LV-09).
    private let longevity: LooprLongevityAgentReader

    init(persistent: PersistentProductRepositories, history: any MetricHistoryProviding = LooprMetricHistory.shared,
         patternStore: (any PatternStore)? = nil, timeZone: TimeZone = .current) {
        foodStore = persistent.food; trainStore = persistent.train; workouts = persistent.workouts
        habits = persistent.habits; journal = persistent.journal; cycle = persistent.cycle; body = persistent.body
        self.history = history; self.patternStore = patternStore; self.timeZone = timeZone
        let records = persistent.workouts
        longevity = LooprLongevityAgentReader(database: persistent.database, train: persistent.train,
                                              workoutRecords: { await records.all() }, body: persistent.body,
                                              history: history, timeZone: timeZone)
    }

    private func dayString(_ date: Date) -> String { AgentDays.string(date, in: timeZone) }

    /// The food and training stores read SQLite synchronously. Run those reads off the main actor, which
    /// is where a nonisolated async function would otherwise start.
    private func offMain<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated) { try work() }.value
    }

    // MARK: Metrics

    func metricSeries(_ key: MetricKey, from: String, to: String) async throws -> [AgentMetricPoint] {
        guard let last = AgentDays.noon(of: to, in: timeZone), let count = AgentDays.count(from: from, to: to) else { return [] }
        let points = try await history.series(for: key, days: count, endingOn: last)
        return points.map { AgentMetricPoint(day: dayString($0.day), value: $0.value) }
            .filter { $0.day >= from && $0.day <= to }
            .sorted { $0.day < $1.day }
    }

    // MARK: Food

    func foodDays(from: String, to: String) async throws -> [AgentFoodDay] {
        let store = foodStore
        let data = try await offMain { try store.overview(from: from, through: to) }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        var rows: [AgentFoodDay] = []
        for day in AgentDays.days(from: from, to: to) {
            guard let noon = AgentDays.noon(of: day, in: timeZone) else { continue }
            // The same summary the Food screen draws, so Ask's totals and targets match what the person sees.
            let base = try FoodDaySummary(date: noon, calendar: calendar, data: data)
            guard !base.meals.isEmpty || !base.drinks.isEmpty || base.isCompleted else { continue }
            rows.append(Self.row(try await FoodOverviewModel.summary(date: noon, calendar: calendar, data: data, body: body).summary))
        }
        return rows
    }

    static func row(_ summary: FoodDaySummary) -> AgentFoodDay {
        let mealRows = summary.meals.map { meal in
            AgentFoodMealRow(id: meal.id.uuidString, slot: meal.slot.rawValue, time: AgentDays.clock(meal.occurredAt, zoneID: meal.timeZoneIdentifier),
                items: meal.items.map { AgentFoodItemRow(name: $0.name, amount: $0.amount, unit: $0.unit.rawValue,
                                                         energy: $0.nutrients[.energy], estimated: $0.isEstimated) })
        }
        let energy = summary.total(.energy)
        let targets = summary.settings.map { settings in
            AgentFoodTargets(goal: settings.goal.rawValue, energy: summary.target.energy, protein: settings.protein, carbs: settings.carbs,
                             fat: settings.fat, waterMillilitres: settings.waterMillilitres, reason: summary.target.reason)
        }
        return AgentFoodDay(day: summary.localDay, meals: mealRows, energy: energy.knownValue, energyComplete: energy.isComplete,
            protein: summary.total(.protein).knownValue, carbs: summary.total(.carbs).knownValue, fat: summary.total(.fat).knownValue,
            waterMillilitres: summary.water, caffeineMilligrams: summary.total(.caffeine).knownValue,
            alcoholUnits: summary.total(.alcoholUnits).knownValue, fibre: summary.total(.fibre).knownValue,
            sugar: summary.total(.sugar).knownValue, salt: summary.total(.salt).knownValue,
            completed: summary.isCompleted, targets: targets)
    }

    func weightReadings(from: String, to: String) async throws -> [AgentWeightReading] {
        let store = foodStore
        return try await offMain { try store.weights() }
            .filter { $0.localDay >= from && $0.localDay <= to }
            .map { AgentWeightReading(day: $0.localDay, time: AgentDays.clock($0.measuredAt, zoneID: $0.timeZoneIdentifier), kilograms: $0.kilograms) }
    }

    func goalPlan() async throws -> AgentGoalPlan? {
        let store = foodStore
        guard let settings = try await offMain({ try store.targetSettings() }), let plan = settings.plan else { return nil }
        return AgentGoalPlan(goal: settings.goal.rawValue, startWeightKg: plan.startWeightKg, goalWeightKg: plan.goalWeightKg,
                             paceKgPerWeek: plan.paceKgPerWeek, activity: plan.activity.rawValue,
                             savedOn: dayString(settings.confirmedAt))
    }

    // MARK: Training

    func trainingEntries(from: String, to: String) async throws -> [AgentTrainingEntry] {
        let store = trainStore
        let sessions = try await offMain { try store.sessions().filter { $0.status == .completed && $0.localDay >= from && $0.localDay <= to } }
        let linked = Set(sessions.compactMap(\.workoutID))
        var rows = sessions.map { session in
            AgentTrainingEntry(id: session.id.uuidString, day: session.localDay, kind: "strength", name: session.name,
                minutes: session.endedAt.map { max(0, Int($0.timeIntervalSince(session.startedAt) / 60)) },
                sets: session.countedSets.count, volumeKg: session.tonnageKg > 0 ? session.tonnageKg : nil,
                exercises: session.exercises.compactMap { line in
                    let sets = line.sets.filter { !$0.skipped && $0.reps > 0 }
                    guard !sets.isEmpty else { return nil }
                    return AgentTrainingExercise(name: line.exercise.name,
                        sets: sets.map { .init(loadKg: $0.loadKg, reps: $0.reps, rpe: $0.rpe) },
                        estimatedOneRepMaxKg: sets.compactMap(PersonalBestEvaluator.values(of:)).map(\.estimatedOneRepMax).max())
                })
        }
        for workout in await workouts.all() where !workout.isActive && !linked.contains(workout.id) {
            guard let start = workout.startedAt else { continue }
            let day = dayString(start)
            guard day >= from, day <= to else { continue }
            rows.append(AgentTrainingEntry(id: workout.id.uuidString, day: day, kind: "workout", name: workout.activity.rawValue,
                minutes: workout.duration.map { Int($0 / 60) }, sets: nil, volumeKg: nil))
        }
        return rows.sorted { ($0.day, $0.id) < ($1.day, $1.id) }
    }

    func trainingTemplates() async throws -> [AgentTemplateRow] {
        let store = trainStore
        return try await offMain { try store.templates() }.map { template in
            AgentTemplateRow(id: template.id.uuidString, name: template.name, revision: template.revision, kind: template.kind.rawValue,
                exercises: template.exercises.enumerated().map { index, exercise in
                    .init(index: index, name: exercise.exercise.name, sets: exercise.sets, repsMin: exercise.repsMin, repsMax: exercise.repsMax,
                          loadKg: exercise.loadKg, restSeconds: exercise.restSeconds)
                })
        }
    }

    // MARK: Journal

    func journalDays(from: String, to: String) async throws -> [AgentJournalDay] {
        let definitions = Dictionary(uniqueKeysWithValues: try await habits.definitions(includeArchived: true).map { ($0.id, $0.name) })
        var byDay: [String: (answers: [AgentJournalDay.Answer], behaviors: [String], tags: [String])] = [:]
        for record in try await habits.dayRecords() {
            let day = record.behaviorDay.habitKey
            guard day >= from, day <= to else { continue }
            let answers = record.responses.compactMap { response -> AgentJournalDay.Answer? in
                definitions[response.habitID].map { .init(name: $0, answer: response.answer.rawValue) }
            }.sorted { $0.name < $1.name }
            if !answers.isEmpty { byDay[day, default: ([], [], [])].answers = answers }
        }
        for entry in await journal.history() where entry.day >= from && entry.day <= to {
            var value = byDay[entry.day, default: ([], [], [])]
            value.behaviors = entry.behaviors.sorted(); value.tags = entry.tags.sorted()
            if !value.behaviors.isEmpty || !value.tags.isEmpty { byDay[entry.day] = value }
        }
        return byDay.map { AgentJournalDay(day: $0.key, answers: $0.value.answers, behaviors: $0.value.behaviors, tags: $0.value.tags) }
            .sorted { $0.day < $1.day }
    }

    func journalNotes(from: String, to: String) async throws -> [AgentJournalNote] {
        await journal.history().compactMap { entry in
            guard entry.day >= from, entry.day <= to, let note = entry.note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty else { return nil }
            return AgentJournalNote(id: entry.id.uuidString, day: entry.day, text: String(note.prefix(1000)))
        }.sorted { ($0.day, $0.id) < ($1.day, $1.id) }
    }

    // MARK: Cycle

    func cycleRows(from: String, to: String) async throws -> [AgentCycleRow] {
        try await cycle.history().filter { $0.day >= from && $0.day <= to }.map {
            AgentCycleRow(id: $0.id.uuidString, day: $0.day, kind: $0.kind.rawValue, flow: $0.flow?.rawValue,
                          symptoms: $0.symptoms.sorted(), note: $0.note.map { String($0.prefix(500)) })
        }
    }

    // MARK: Longevity (LV-09)

    func activeProtocol() async throws -> AgentProtocolRow? { try await longevity.activeProtocol() }
    func adherence(from: String, to: String, today: String) async throws -> AgentAdherenceData? {
        try await longevity.adherence(from: from, to: to, today: today)
    }
    func experiments(from: String, to: String, today: String, withResults: Bool) async throws -> [AgentExperimentRow] {
        try await longevity.experiments(from: from, to: to, today: today, withResults: withResults)
    }
    func stackDoses(from: String, to: String) async throws -> AgentStackData { try await longevity.stackDoses(from: from, to: to) }
    func labs(from: String, to: String) async throws -> AgentLabsData { try await longevity.labs(from: from, to: to) }
    func capacity(from: String, to: String, today: String, withBandMinutes: Bool, withTargets: Bool) async throws -> AgentCapacityData {
        try await longevity.capacity(from: from, to: to, today: today, withBandMinutes: withBandMinutes, withTargets: withTargets)
    }
    func cardioAge(today: String) async throws -> AgentCardioAgeRow? { try await longevity.cardioAge(today: today) }
    func bloodAge() async throws -> AgentBloodAgeRow? { try await longevity.bloodAge() }

    // MARK: Patterns

    func visiblePatterns() async throws -> [AgentPatternRow] {
        guard let patternStore else { return [] }
        return try await patternStore.visibleFoundPatterns().filter { $0.strength.isHeadlineWorthy }.map { pattern in
            AgentPatternRow(candidateID: pattern.candidateID, title: pattern.title, metric: pattern.metric.rawValue,
                strength: pattern.strength.rawValue, difference: pattern.effect.difference, unit: pattern.effect.unit.rawValue,
                nightsWith: pattern.nights.with, nightsWithout: pattern.nights.without, windowEnd: pattern.windowEnd,
                exposureDomain: AgentPatternRow.domain(of: pattern.predicate))
        }
    }
}

nonisolated extension AgentPatternRow {
    static func domain(of predicate: PatternPredicate) -> AgentDataDomain {
        switch predicate {
        case .journalAnswer: .journalAnswers
        case .food: .food
        case .trainingDay, .legDay: .training
        case .stepsOver: .metrics
        }
    }
}

/// Day strings are `yyyy-MM-dd` in the person's time zone. These helpers do the arithmetic on the
/// strings so a daylight-saving change never shifts a day.
nonisolated enum AgentDays {
    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    static func parse(_ day: String) -> Date? {
        let parts = day.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let dayNumber = Int(parts[2]),
              let date = utc.date(from: DateComponents(year: year, month: month, day: dayNumber, hour: 12)) else { return nil }
        let back = utc.dateComponents([.year, .month, .day], from: date)
        return back.year == year && back.month == month && back.day == dayNumber ? date : nil
    }
    static func isValid(_ day: String) -> Bool { parse(day) != nil }
    static func format(_ date: Date) -> String {
        let c = utc.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
    static func add(_ days: Int, to day: String) -> String? {
        parse(day).flatMap { utc.date(byAdding: .day, value: days, to: $0) }.map(format)
    }
    /// Days from `from` through `to`, inclusive. Nil when the order is wrong.
    static func count(from: String, to: String) -> Int? {
        guard let a = parse(from), let b = parse(to), a <= b else { return nil }
        return (utc.dateComponents([.day], from: a, to: b).day ?? 0) + 1
    }
    static func days(from: String, to: String) -> [String] {
        guard let n = count(from: from, to: to) else { return [] }
        return (0..<n).compactMap { add($0, to: from) }
    }
    static func string(_ date: Date, in zone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
    /// A moment near the middle of that local day, safe from edge effects at midnight.
    static func noon(of day: String, in zone: TimeZone) -> Date? {
        guard let parsed = parse(day) else { return nil }
        let c = utc.dateComponents([.year, .month, .day], from: parsed)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        return calendar.date(from: DateComponents(year: c.year, month: c.month, day: c.day, hour: 12))
    }
    static func clock(_ date: Date, zoneID: String) -> String {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: zoneID) ?? .current
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }
}
