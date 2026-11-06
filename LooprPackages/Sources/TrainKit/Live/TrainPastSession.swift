import Foundation

/// A gym session already done, entered set by set after the fact (R2-LIFT-05, R1-LIFT-04). Pure value logic.
///
/// The person picks a day, a start time and a duration, adds exercises, and fills each one's sets as a table in its
/// measure. A new exercise starts from last time: as many sets as then, with the same numbers. There is no rest timer
/// and nothing goes to the band. Saving builds a completed `TrainSession` that starts at the chosen time, so it counts
/// in the dose for that day, with bests worked out against the sessions before it.
public struct TrainPastSessionDraft: Equatable, Sendable {
    /// One set in the table.
    public struct Row: Equatable, Sendable, Identifiable {
        public let id: UUID
        public var values: TrainSetValues
        public var rpe: Double?
        public var tag: LoggedSet.Tag?

        public init(id: UUID = UUID(), values: TrainSetValues, rpe: Double? = nil, tag: LoggedSet.Tag? = nil) {
            self.id = id; self.values = values; self.rpe = rpe; self.tag = tag
        }
    }

    /// One exercise and its sets.
    public struct Line: Equatable, Sendable, Identifiable {
        public let id: UUID
        public var exercise: ExerciseRef
        public var measure: TrainSetMeasure
        public var rows: [Row]
        /// True when the rows came from the last session of this exercise.
        public var fromLastTime: Bool

        public init(id: UUID = UUID(), exercise: ExerciseRef, measure: TrainSetMeasure, rows: [Row], fromLastTime: Bool = false) {
            self.id = id; self.exercise = exercise; self.measure = measure; self.rows = rows; self.fromLastTime = fromLastTime
        }
    }

    /// Why the draft cannot be saved yet.
    public enum Problem: Equatable, Sendable {
        case noExercise, noSet, inFuture, invalidSet(exercise: String)

        public var message: String {
            switch self {
            case .noExercise: "Add an exercise to save."
            case .noSet: "Add a set to save."
            case .inFuture: "This session ends after now. Pick an earlier start."
            case .invalidSet(let exercise): "Check the sets of \(exercise)."
            }
        }
    }

    public static let defaultName = "Workout"
    public static let durationRange = 5...300
    /// Sets a new exercise starts with when it has no history.
    public static let defaultSetCount = 3

    public var name: String
    public var startedAt: Date
    public var durationMinutes: Int
    public private(set) var lines: [Line]
    public let timeZoneIdentifier: String
    private let history: [TrainSession]

    /// - Parameters:
    ///   - startedAt: Where the start time begins. The screen offers now minus the default hour.
    ///   - history: Finished sessions, newest first or in any order. They fill new exercises and decide the bests.
    public init(startedAt: Date, durationMinutes: Int = 60, history: [TrainSession] = [],
                timeZoneIdentifier: String = TimeZone.current.identifier, name: String = TrainPastSessionDraft.defaultName) {
        self.name = name
        self.startedAt = startedAt
        self.durationMinutes = min(max(durationMinutes, Self.durationRange.lowerBound), Self.durationRange.upperBound)
        self.timeZoneIdentifier = timeZoneIdentifier
        self.history = history.filter { $0.status == .completed }
            .sorted { ($0.startedAt, $0.id.uuidString) > ($1.startedAt, $1.id.uuidString) }
        lines = []
    }

    /// A sensible start for a session done earlier today: an hour before `now`, on the quarter hour.
    public static func defaultStart(now: Date, durationMinutes: Int = 60) -> Date {
        let earlier = now.addingTimeInterval(-Double(durationMinutes) * 60)
        let quarter = 15.0 * 60
        return Date(timeIntervalSince1970: (earlier.timeIntervalSince1970 / quarter).rounded(.down) * quarter)
    }

    public var endedAt: Date { startedAt.addingTimeInterval(Double(durationMinutes) * 60) }

    /// Every set entered, across exercises.
    public var setCount: Int { lines.reduce(0) { $0 + $1.rows.count } }

    // MARK: Exercises

    /// The same exercise as it was last done, when it was done before this session.
    private func lastLine(forKey key: String) -> SessionExercise? {
        for past in history where past.startedAt < startedAt || past.startedAt >= startedAt {
            if let line = past.exercises.first(where: { $0.exercise.key == key && $0.status != .skipped && $0.sets.contains(where: \.isWorking) }) {
                return line
            }
        }
        return nil
    }

    /// Adds an exercise at the end. It takes last time's measure and working sets, or three sets of its plan defaults.
    @discardableResult
    public mutating func addExercise(_ definition: ExerciseDefinition) throws -> Int {
        guard lines.count < TrainLimits.maxExercisesPerTemplate else { throw TrainLiveError.tooManyExercises }
        let last = lastLine(forKey: definition.key)
        let measure = last?.planned.measure ?? TrainSetMeasure.defaultMeasure(for: definition)
        let rows: [Row]
        if let last {
            rows = last.sets.filter(\.isWorking).prefix(TrainLimits.maxSets).map { Row(values: $0.values) }
        } else {
            let values: TrainSetValues = switch measure {
            case .weight, .bodyweight: TrainSetValues(reps: 8)
            case .time: TrainSetValues(seconds: TemplateExercise.defaultTargetSeconds)
            case .distance: TrainSetValues(metres: TemplateExercise.defaultTargetMetres)
            }
            rows = (0..<Self.defaultSetCount).map { _ in Row(values: values) }
        }
        lines.append(Line(exercise: definition.reference, measure: measure, rows: rows, fromLastTime: last != nil))
        return lines.count - 1
    }

    public mutating func removeExercise(at index: Int) {
        guard lines.indices.contains(index) else { return }
        lines.remove(at: index)
    }

    /// One more set, a copy of the last one.
    public mutating func addSet(toLineAt index: Int) throws {
        guard lines.indices.contains(index) else { throw TrainLiveError.noSuchExercise }
        guard lines[index].rows.count < TrainLimits.maxSets else { throw TrainLiveError.tooManySets }
        let last = lines[index].rows.last
        lines[index].rows.append(Row(values: last?.values ?? TrainSetValues(reps: 8), tag: nil))
    }

    /// Deletes a set. The exercise stays, even with no sets, until it is removed.
    public mutating func removeSet(lineIndex: Int, rowIndex: Int) {
        guard lines.indices.contains(lineIndex), lines[lineIndex].rows.indices.contains(rowIndex) else { return }
        lines[lineIndex].rows.remove(at: rowIndex)
    }

    /// Changes a set's numbers and tag. Its RPE stays.
    public mutating func updateSet(lineIndex: Int, rowIndex: Int, values: TrainSetValues, tag: LoggedSet.Tag?) {
        guard lines.indices.contains(lineIndex), lines[lineIndex].rows.indices.contains(rowIndex) else { return }
        lines[lineIndex].rows[rowIndex].values = values
        lines[lineIndex].rows[rowIndex].tag = tag
    }

    public mutating func setRPE(_ rpe: Double?, lineIndex: Int, rowIndex: Int) throws {
        if let rpe, !LoggedSet.isValidRPE(rpe) { throw TrainLiveError.invalidRPE }
        guard lines.indices.contains(lineIndex), lines[lineIndex].rows.indices.contains(rowIndex) else { return }
        lines[lineIndex].rows[rowIndex].rpe = rpe
    }

    public mutating func setTag(_ tag: LoggedSet.Tag?, lineIndex: Int, rowIndex: Int) {
        guard lines.indices.contains(lineIndex), lines[lineIndex].rows.indices.contains(rowIndex) else { return }
        lines[lineIndex].rows[rowIndex].tag = tag
    }

    // MARK: Saving

    /// What stops a save, checked against `now`. Nil when the draft can be saved.
    public func problem(now: Date) -> Problem? {
        guard !lines.isEmpty else { return .noExercise }
        guard setCount > 0 else { return .noSet }
        guard endedAt <= now else { return .inFuture }
        for line in lines {
            for row in line.rows {
                guard (try? Self.loggedSet(row, measure: line.measure, at: startedAt)) != nil else {
                    return .invalidSet(exercise: line.exercise.name)
                }
            }
        }
        return nil
    }

    /// The finished session: completed, starting at `startedAt` and ending a duration later, its sets spread evenly
    /// across that time in the order entered, and its bests set against the sessions that came before it.
    ///
    /// - Parameter workoutID: The workout record the app saved for this session, so the dose and the lists count it once.
    public func session(id: UUID = UUID(), workoutID: UUID? = nil, now: Date) throws -> TrainSession {
        if let problem = problem(now: now) {
            throw problem == .inFuture ? TrainError.invalidRecord : TrainLiveError.invalidValue
        }
        let lines = self.lines.filter { !$0.rows.isEmpty }
        let total = max(lines.reduce(0) { $0 + $1.rows.count }, 1)
        let step = Double(durationMinutes * 60) / Double(total)
        var position = 0
        var exercises: [SessionExercise] = []
        for line in lines {
            var sets: [LoggedSet] = []
            for row in line.rows {
                sets.append(try Self.loggedSet(row, measure: line.measure, at: startedAt.addingTimeInterval(Double(position) * step)))
                position += 1
            }
            let first = line.rows.first?.values ?? TrainSetValues()
            let reps = line.rows.map(\.values.reps).filter { $0 > 0 }
            let planned = TemplateExercise(
                exercise: line.exercise, sets: line.rows.count,
                repsMin: min(max(reps.min() ?? 1, 1), line.measure.maxReps), repsMax: min(max(reps.max() ?? 1, 1), line.measure.maxReps),
                loadKg: line.measure == .weight ? first.loadKg : nil, measure: line.measure,
                assistKg: line.measure == .bodyweight ? first.assistKg : nil,
                targetSeconds: line.measure == .time ? first.seconds : nil, targetMetres: line.measure == .distance ? first.metres : nil,
                restSeconds: 0)
            exercises.append(SessionExercise(planned: planned, status: .done, sets: sets))
        }
        var session = try TrainSession(id: id, workoutID: workoutID, name: Self.cleanName(name), startedAt: startedAt,
                                       timeZoneIdentifier: timeZoneIdentifier, endedAt: endedAt, status: .completed,
                                       exercises: exercises)
        session.bests = PersonalBestEvaluator.evaluate(session: session, history: history)
        try session.validate()
        return session
    }

    static func cleanName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultName : String(trimmed.prefix(TrainLimits.name))
    }

    /// A row as a stored set, in its measure: a zero load is no load, and a bodyweight set is loaded or assisted.
    static func loggedSet(_ row: Row, measure: TrainSetMeasure, at date: Date) throws -> LoggedSet {
        func kilograms(_ value: Double?) -> Double? { value.flatMap { $0 > 0 ? $0 : nil } }
        var values = row.values
        values.loadKg = kilograms(values.loadKg)
        values.assistKg = measure == .bodyweight ? kilograms(values.assistKg) : nil
        if values.assistKg != nil { values.loadKg = nil }
        switch measure {
        case .weight, .bodyweight: values.seconds = nil; values.metres = nil
        case .time: values.reps = 0; values.metres = nil
        case .distance: values.reps = 0; values.seconds = nil
        }
        let set = LoggedSet(loadKg: values.loadKg, reps: values.reps, rpe: row.rpe, loggedAt: date, prefillSource: .manual,
                            seconds: values.seconds, metres: values.metres, assistKg: values.assistKg, tag: row.tag)
        try set.validate(measure: measure)
        return set
    }
}
