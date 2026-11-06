import DomainKit
import FoodKit
import Foundation
import JournalKit
import TrainKit
import WorkoutKit

/// Days on which the person trained, from Train sessions and recorded workouts.
nonisolated struct PatternTrainingInput: Equatable, Sendable {
    /// Days with a completed strength session or a finished workout.
    var trainedDays: Set<String> = []
    /// Days whose strength work was mostly lower body.
    var legDays: Set<String> = []
    /// The first day any training was recorded. Days before it are unknown, not "no".
    var earliestDay: String?
}

/// Everything the app reads to answer the pattern engine's questions. The production type reads the
/// product database. Tests supply their own.
nonisolated protocol PatternSourceData: Sendable {
    func journalDefinitions() async throws -> [HabitDefinition]
    func journalRecords() async throws -> [HabitDayRecord]
    /// Food-derived yes or no answers for the last 120 days up to `day`, by kind.
    func foodAnswers(endingOn day: String) async throws -> [FoodAssociationKind: [PatternExposureDay]]
    func training(from firstDay: String, to lastDay: String) async throws -> PatternTrainingInput
    func steps(from firstDay: String, to lastDay: String) async throws -> [String: Double]
    func outcomes(forRecords records: [HabitDayRecord]) async throws -> PatternOutcomeSet
}

/// The rules that turn stored days into exposure answers. Pure, so they are tested without a database.
nonisolated enum PatternExposureRules {
    /// Muscles that make a set count toward a leg day.
    static let lowerBody: Set<String> = ["quadriceps", "hamstrings", "glutes", "calves", "adductors", "abductors"]

    /// A leg session has at least three counted sets and at least half of them train a lower-body muscle.
    static func isLegSession(setsByExercise: [(muscles: [String], sets: Int)]) -> Bool {
        let total = setsByExercise.reduce(0) { $0 + $1.sets }
        let lower = setsByExercise.filter { !lowerBody.isDisjoint(with: $0.muscles) }.reduce(0) { $0 + $1.sets }
        return total >= 3 && lower * 2 >= total
    }

    /// One answer per day from `earliestDay` through `lastDay`, and none before it.
    static func trainingDays(_ input: PatternTrainingInput, from firstDay: String, to lastDay: String,
                             zoneID: String, leg: Bool) -> [PatternExposureDay] {
        guard let earliest = input.earliestDay else { return [] }
        let start = max(firstDay, earliest)
        guard start <= lastDay, let count = PatternDays.distance(from: start, to: lastDay) else { return [] }
        let source = leg ? input.legDays : input.trainedDays
        return PatternDays.range(from: start, count: count + 1).map {
            PatternExposureDay(dayKey: $0, timeZoneID: zoneID, exposed: source.contains($0))
        }
    }

    /// A day with a step count is answered. A day without one is unknown.
    static func stepDays(_ steps: [String: Double], over threshold: Int, zoneID: String) -> [PatternExposureDay] {
        steps.keys.sorted().compactMap { day in
            guard let value = steps[day], value.isFinite, value >= 0 else { return nil }
            return PatternExposureDay(dayKey: day, timeZoneID: zoneID, exposed: value > Double(threshold))
        }
    }
}

/// The app's exposures, in the shape JournalKit's pattern engine asks for.
nonisolated struct LooprPatternExposureProvider: PatternExposureProvider {
    let data: any PatternSourceData
    let timeZone: @Sendable () -> TimeZone
    let policy: PatternPolicy
    private var timeZoneID: String { timeZone().identifier }

    init(data: any PatternSourceData, timeZone: @escaping @Sendable () -> TimeZone = { .current }, policy: PatternPolicy = .default) {
        self.data = data; self.timeZone = timeZone; self.policy = policy
    }

    static let lateDinner = PatternCandidate.food(
        id: "lateMeal", habitID: FoodAssociationKind.lateMeal.id, title: "Last meal after 21:00",
        label: "when you eat after 21:00", metrics: [.deepSleepMinutes, .sleepScore])
    static let protein = PatternCandidate.food(
        id: "proteinTarget", habitID: FoodAssociationKind.proteinTarget.id, title: "Protein target met",
        label: "a day you met your protein target", metrics: [.recoveryScore, .hrvRMSSD])

    static let alcohol = PatternCandidate.food(
        id: "alcohol", habitID: FoodAssociationKind.alcohol.id, title: "Alcohol",
        label: "when you drink alcohol", metrics: [.recoveryScore, .hrvRMSSD, .sleepScore, .restingHeartRate])
    static let lateCaffeine = PatternCandidate.food(
        id: "lateCaffeine", habitID: FoodAssociationKind.lateCaffeine.id, title: "Caffeine after 14:00",
        label: "when you have caffeine after 14:00", metrics: [.sleepScore, .deepSleepMinutes, .sleepDuration])

    /// Food exposures and the kind each answer comes from. A food exposure is left out when the person keeps the
    /// matching Journal question, which Journal already answers from the same food log, so one habit never shows twice.
    static func foodCandidates(journalHabits: [HabitDefinition]) -> [(FoodAssociationKind, PatternCandidate)] {
        let asked = Set(JournalAutoFillQuestion.allCases.filter { question in
            journalHabits.contains { !$0.isArchived && question.accepts($0) }
        })
        var list: [(FoodAssociationKind, PatternCandidate)] = [(.lateMeal, lateDinner), (.proteinTarget, protein)]
        if !asked.contains(.alcohol) { list.append((.alcohol, alcohol)) }
        if !asked.contains(.lateCaffeine) { list.append((.lateCaffeine, lateCaffeine)) }
        return list
    }

    func candidates() async throws -> [PatternCandidate] {
        let habits = try await data.journalDefinitions()
        return PatternCandidate.catalog(journalHabits: habits, food: Self.foodCandidates(journalHabits: habits).map(\.1), policy: policy)
    }

    func exposures(endingOn day: String, windowDays: Int) async throws -> [PatternExposureSeries] {
        let candidates = try await candidates()
        guard let first = PatternDays.add(-(max(windowDays, 1) - 1), to: day) else { return [] }
        var series: [PatternExposureSeries] = []

        let records = try await data.journalRecords().filter { $0.behaviorDay.habitKey >= first && $0.behaviorDay.habitKey <= day }
        for candidate in candidates where candidate.kind == .journalHabit {
            series.append(.journal(candidate: candidate, records: records))
        }

        let food = try await data.foodAnswers(endingOn: day)
        for (kind, candidate) in Self.foodCandidates(journalHabits: try await data.journalDefinitions()) {
            series.append(PatternExposureSeries(candidateID: candidate.id, days: (food[kind] ?? []).filter { $0.dayKey >= first && $0.dayKey <= day }))
        }

        let training = try await data.training(from: first, to: day)
        series.append(.init(candidateID: PatternCandidate.trainingDay.id,
                            days: PatternExposureRules.trainingDays(training, from: first, to: day, zoneID: timeZoneID, leg: false)))
        series.append(.init(candidateID: PatternCandidate.legDay.id,
                            days: PatternExposureRules.trainingDays(training, from: first, to: day, zoneID: timeZoneID, leg: true)))

        let stepsCandidate = PatternCandidate.steps(over: policy.stepsThreshold)
        series.append(.init(candidateID: stepsCandidate.id,
                            days: PatternExposureRules.stepDays(try await data.steps(from: first, to: day), over: policy.stepsThreshold, zoneID: timeZoneID)))
        let known = Set(candidates.map(\.id))
        return series.filter { known.contains($0.candidateID) }
    }

    func outcomes(forRecords records: [HabitDayRecord]) async throws -> PatternOutcomeSet {
        try await data.outcomes(forRecords: records)
    }
}

// MARK: Production data

/// Reads the product database. Every call is safe off the main actor.
nonisolated struct LooprPatternSourceData: PatternSourceData {
    private let habits: SQLiteHabitRepository
    private let food: FoodStore
    private let train: TrainStore
    private let workouts: SQLiteWorkoutStore
    private let history: any MetricHistoryProviding
    private let resolver: AppHabitOutcomeResolver
    private let library: ExerciseLibrary?
    private let timeZone: @Sendable () -> TimeZone

    init(persistent: PersistentProductRepositories, history: any MetricHistoryProviding = LooprMetricHistory.shared,
         calendar: any CalendarProviding = SystemCalendarProvider(), dates: any DateProviding = SystemDateProvider(),
         timeZone: @escaping @Sendable () -> TimeZone = { .current }) {
        habits = persistent.habits; food = persistent.food; train = persistent.train; workouts = persistent.workouts
        self.history = history; self.timeZone = timeZone
        resolver = AppHabitOutcomeResolver(today: persistent.today, sleep: persistent.sleep, heart: persistent.heart,
                                           calendar: calendar, dateProvider: dates)
        library = try? TrainTemplateRoot.loadBundledLibrary()
    }

    func journalDefinitions() async throws -> [HabitDefinition] { try await habits.definitions(includeArchived: false) }
    func journalRecords() async throws -> [HabitDayRecord] { try await habits.dayRecords() }

    func foodAnswers(endingOn day: String) async throws -> [FoodAssociationKind: [PatternExposureDay]] {
        let zone = timeZone()
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        guard let date = AgentDays.noon(of: day, in: zone), let first = AgentDays.add(-119, to: day) else { return [:] }
        let store = food
        let overview = try await Task.detached(priority: .userInitiated) { try store.overview(from: first, through: day) }.value
        let input = try FoodAssociationInput(data: overview, endingOn: date, calendar: calendar, trainingDays: nil)
        var answers: [FoodAssociationKind: [PatternExposureDay]] = [:]
        for kind in FoodAssociationKind.allCases {
            answers[kind] = input.records.compactMap { $0.response(for: kind.id).flatMap(PatternExposureDay.init(response:)) }
        }
        return answers
    }

    func training(from firstDay: String, to lastDay: String) async throws -> PatternTrainingInput {
        let zone = timeZone()
        let store = train, library = library
        let sessions = try await Task.detached(priority: .userInitiated) { try store.sessions().filter { $0.status == .completed } }.value
        var input = PatternTrainingInput()
        func note(_ day: String) { if input.earliestDay.map({ day < $0 }) ?? true { input.earliestDay = day } }
        var linked = Set<UUID>()
        for session in sessions {
            if let id = session.workoutID { linked.insert(id) }
            note(session.localDay)
            guard session.localDay >= firstDay, session.localDay <= lastDay else { continue }
            input.trainedDays.insert(session.localDay)
            let sets = session.exercises.map { exercise -> (muscles: [String], sets: Int) in
                (library?.definition(forKey: exercise.exercise.key)?.primaryMuscles ?? [], exercise.sets.filter { !$0.skipped }.count)
            }
            if PatternExposureRules.isLegSession(setsByExercise: sets) { input.legDays.insert(session.localDay) }
        }
        for workout in await workouts.all() where !workout.isActive && !linked.contains(workout.id) {
            guard let start = workout.startedAt, workout.endedAt != nil else { continue }
            let day = AgentDays.string(start, in: zone)
            note(day)
            if day >= firstDay, day <= lastDay { input.trainedDays.insert(day) }
        }
        return input
    }

    func steps(from firstDay: String, to lastDay: String) async throws -> [String: Double] {
        let zone = timeZone()
        guard let last = AgentDays.noon(of: lastDay, in: zone), let count = AgentDays.count(from: firstDay, to: lastDay) else { return [:] }
        var byDay: [String: Double] = [:]
        for point in try await history.series(for: .steps, days: count, endingOn: last) {
            let day = AgentDays.string(point.day, in: zone)
            if day >= firstDay, day <= lastDay { byDay[day] = point.value }
        }
        return byDay
    }

    func outcomes(forRecords records: [HabitDayRecord]) async throws -> PatternOutcomeSet {
        var outcomes: [HabitOutcomeSnapshot] = [], exclusions: [HabitOutcomeExclusionRecord] = []
        for record in records {
            try Task.checkCancellation()
            switch await resolver.resolve(record: record) {
            case .outcome(let outcome): outcomes.append(outcome)
            case .excluded(let exclusion): exclusions.append(exclusion)
            }
        }
        return PatternOutcomeSet(outcomes: outcomes, exclusions: exclusions)
    }
}
