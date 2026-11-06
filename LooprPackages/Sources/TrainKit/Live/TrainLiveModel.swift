import Foundation

public enum TrainLiveError: Error, Equatable, Sendable, LocalizedError {
    case noOpenSet, noSuchExercise, noSuchSet, exerciseStarted, invalidRPE, invalidValue, emptyTemplate, sessionFinished, measureLocked
    case tooManyExercises, tooManySets

    public var errorDescription: String? {
        switch self {
        case .noOpenSet: "Every set is logged. Finish the session when you are ready."
        case .noSuchExercise: "That exercise is not in this session."
        case .noSuchSet: "That set has not been logged."
        case .exerciseStarted: "You can swap an exercise only before its first set."
        case .invalidRPE: "RPE runs from 6 to 10 in half steps."
        case .invalidValue: "Check the load and the reps."
        case .measureLocked: "You can change what an exercise records only before its first set."
        case .emptyTemplate: "Add an exercise to this workout before you start it."
        case .sessionFinished: "This session is already finished."
        case .tooManyExercises: "A workout holds up to \(TrainLimits.maxExercisesPerTemplate) exercises."
        case .tooManySets: "An exercise holds up to \(TrainLimits.maxSets) sets."
        }
    }
}

/// Everything a live session starts from. The app builds it from the Train overview, then adds the
/// swap pool and the linked workout.
public struct TrainLiveSetup: Sendable {
    public var template: WorkoutTemplate
    /// Today's 0 to 100 recovery score, or nil without a reading.
    public var recoveryScore: Double?
    public var programID: UUID?
    public var programWeek: Int?
    /// Finished sessions. They feed prefill, "last time" and personal bests.
    public var history: [TrainSession]
    /// Mean strain of the template's last sessions, for "of about 11".
    public var expectedStrain: Double?
    /// Exercises a swap can offer. Usually the whole library plus custom exercises.
    public var swapPool: [ExerciseDefinition]
    /// Replaces every exercise's rest. UI test fixtures use it to keep a session short.
    public var restSecondsOverride: Int?
    public var timeZoneIdentifier: String
    public var sessionID: UUID
    /// The `WorkoutRecord` this session records heart rate and strain on.
    public var workoutID: UUID?
    /// A workout built as it goes: it may start with no exercises and belongs to no saved template.
    public var isFreeform: Bool

    public init(template: WorkoutTemplate, recoveryScore: Double? = nil, programID: UUID? = nil, programWeek: Int? = nil,
                history: [TrainSession] = [], expectedStrain: Double? = nil, swapPool: [ExerciseDefinition] = [],
                restSecondsOverride: Int? = nil, timeZoneIdentifier: String = TimeZone.current.identifier,
                sessionID: UUID = UUID(), workoutID: UUID? = nil, isFreeform: Bool = false) {
        self.template = template; self.recoveryScore = recoveryScore; self.programID = programID
        self.programWeek = programWeek; self.history = history; self.expectedStrain = expectedStrain
        self.swapPool = swapPool; self.restSecondsOverride = restSecondsOverride
        self.timeZoneIdentifier = timeZoneIdentifier; self.sessionID = sessionID; self.workoutID = workoutID
        self.isFreeform = isFreeform
    }

    /// A blank workout. The person adds exercises as they train.
    public static func freeform(name: String = "Workout", history: [TrainSession] = [],
                                timeZoneIdentifier: String = TimeZone.current.identifier) -> Self {
        .init(template: WorkoutTemplate(name: name), history: history, timeZoneIdentifier: timeZoneIdentifier, isFreeform: true)
    }
}

/// One row of the set table for an exercise.
public struct TrainSetRow: Equatable, Sendable, Identifiable {
    public enum State: Sendable, Equatable { case logged, skipped, current, planned }

    /// 1-based set number within the exercise.
    public let number: Int
    public let loadKg: Double?
    public let reps: Int
    public let rpe: Double?
    public let state: State
    public var seconds: Int? = nil
    public var metres: Double? = nil
    public var assistKg: Double? = nil
    public var tag: LoggedSet.Tag? = nil
    /// True for a logged set that beat an earlier best. A first performance sets a baseline and is not marked.
    public var isRecord = false

    public var id: Int { number }
    public var values: TrainSetValues { TrainSetValues(loadKg: loadKg, reps: reps, seconds: seconds, metres: metres, assistKg: assistKg) }
}

/// How far one exercise has got, for the exercise menu.
public struct TrainExerciseProgress: Equatable, Sendable, Identifiable {
    public let index: Int
    public let name: String
    public let status: SessionExerciseStatus
    public let loggedSets: Int
    public let plannedSets: Int
    public let isCurrent: Bool

    public var id: Int { index }
}

/// The state of a strength session in progress. Pure value logic: nothing here reads a clock,
/// storage or the network. Every change that needs the time takes `now`.
///
/// The session keeps one `SessionExercise` per planned exercise, in template order. The next set
/// to log (`cursor`) follows from what has been logged, so nothing drifts: the exercise's
/// `sets` array holds its logged and skipped sets in order, and the next set number is its count.
/// Superset members alternate round by round.
public struct TrainLiveModel: Equatable, Sendable {
    public struct Position: Equatable, Hashable, Sendable {
        public let exerciseIndex: Int
        /// Zero-based.
        public let setIndex: Int

        public init(exerciseIndex: Int, setIndex: Int) { self.exerciseIndex = exerciseIndex; self.setIndex = setIndex }
    }

    public private(set) var session: TrainSession
    public private(set) var rest: RestTimer?
    public private(set) var isFinished = false
    public let progression: ProgressionRule
    public let bandRestCue: Bool
    /// What the recovery rule decided. Nil when the model was resumed.
    public let recoveryAdjustment: RecoveryAdjustment?
    public let expectedStrain: Double?
    private var focusedExercise: Int?
    private let history: [TrainSession]
    private let swapPool: [ExerciseDefinition]

    // MARK: Start

    public init(setup: TrainLiveSetup, now: Date) throws {
        guard setup.template.kind == .strength, setup.isFreeform || !setup.template.exercises.isEmpty else { throw TrainLiveError.emptyTemplate }
        let adjustment = RecoveryAdjuster.adjust(template: setup.template, score: setup.recoveryScore)
        var exercises = adjustment.exercises
        if let override = setup.restSecondsOverride {
            exercises = exercises.map { line in var copy = line; copy.restSeconds = max(0, override); return copy }
        }
        let applied = adjustment.programAdjustment(createdAt: now).map { [$0] } ?? []
        let created = try TrainSession(
            id: setup.sessionID, workoutID: setup.workoutID, templateID: setup.isFreeform ? nil : setup.template.id, name: setup.template.name,
            programID: setup.programID, programWeek: setup.programWeek, startedAt: now,
            timeZoneIdentifier: setup.timeZoneIdentifier, status: .active, recoveryAtStart: setup.recoveryScore,
            appliedAdjustments: applied, exercises: exercises.map { SessionExercise(planned: $0) })
        try created.validate()
        session = created
        progression = setup.template.progression
        bandRestCue = setup.template.bandRestCue
        recoveryAdjustment = adjustment
        expectedStrain = setup.expectedStrain
        history = Self.sortedHistory(setup.history)
        swapPool = setup.swapPool
    }

    /// Picks up an active session that was saved while the app was closed. Rest starts over.
    public init(resuming session: TrainSession, template: WorkoutTemplate?, history: [TrainSession],
                swapPool: [ExerciseDefinition] = [], expectedStrain: Double? = nil) throws {
        guard session.status == .active else { throw TrainLiveError.noOpenSet }
        try session.validate()
        self.session = session
        progression = template?.progression ?? .none
        bandRestCue = template?.bandRestCue ?? true
        recoveryAdjustment = nil
        self.expectedStrain = expectedStrain
        self.history = Self.sortedHistory(history)
        self.swapPool = swapPool
    }

    private static func sortedHistory(_ sessions: [TrainSession]) -> [TrainSession] {
        sessions.filter { $0.status == .completed }.sorted { ($0.startedAt, $0.id.uuidString) > ($1.startedAt, $1.id.uuidString) }
    }

    // MARK: Order and cursor

    /// Contiguous exercise ranges that run together: a lone exercise, or one superset.
    private var blocks: [Range<Int>] {
        var result: [Range<Int>] = []
        var index = 0
        let lines = session.exercises
        while index < lines.count {
            var end = index + 1
            if let group = lines[index].planned.supersetGroup {
                while end < lines.count, lines[end].planned.supersetGroup == group { end += 1 }
            }
            result.append(index..<end)
            index = end
        }
        return result
    }

    /// Every set of the plan in the order it is done: an exercise's sets in a row, and the members
    /// of a superset one set each, round after round.
    private var plannedOrder: [Position] {
        var steps: [Position] = []
        for block in blocks {
            let rounds = block.map { session.exercises[$0].planned.sets }.max() ?? 0
            for round in 0..<rounds {
                for index in block where session.exercises[index].planned.sets > round {
                    steps.append(Position(exerciseIndex: index, setIndex: round))
                }
            }
        }
        return steps
    }

    private func isOpen(_ line: SessionExercise) -> Bool {
        line.status == .pending || line.status == .swapped
    }

    /// Sets still to do, in order.
    public var remainingSteps: [Position] {
        plannedOrder.filter { step in
            let line = session.exercises[step.exerciseIndex]
            return isOpen(line) && step.setIndex >= line.sets.count
        }
    }

    /// The next set to log, or nil when every set is logged, skipped or dropped.
    public var cursor: Position? {
        let remaining = remainingSteps
        if let focus = focusedExercise, let block = blocks.first(where: { $0.contains(focus) }),
           let step = remaining.first(where: { block.contains($0.exerciseIndex) }) {
            return step
        }
        return remaining.first
    }

    public var isComplete: Bool { cursor == nil }
    public var exerciseCount: Int { session.exercises.count }
    public var currentExercise: SessionExercise? { cursor.map { session.exercises[$0.exerciseIndex] } }

    /// "1 of 6 · set 3 of 4". Uppercased by the screen.
    public var eyebrow: String {
        guard let cursor else { return "All sets logged" }
        let line = session.exercises[cursor.exerciseIndex]
        var text = "\(cursor.exerciseIndex + 1) of \(exerciseCount) · set \(cursor.setIndex + 1) of \(line.planned.sets)"
        if line.planned.supersetGroup != nil { text += " · superset" }
        return text
    }

    /// The same words for VoiceOver.
    public var spokenEyebrow: String {
        guard let cursor else { return "All sets logged" }
        let line = session.exercises[cursor.exerciseIndex]
        var text = "Exercise \(cursor.exerciseIndex + 1) of \(exerciseCount), set \(cursor.setIndex + 1) of \(line.planned.sets)"
        if line.planned.supersetGroup != nil { text += ", superset" }
        return text
    }

    public var exerciseProgress: [TrainExerciseProgress] {
        let current = cursor?.exerciseIndex
        return session.exercises.enumerated().map { index, line in
            TrainExerciseProgress(index: index, name: line.exercise.name, status: line.status,
                                  loggedSets: line.sets.filter { !$0.skipped }.count, plannedSets: line.planned.sets,
                                  isCurrent: index == current)
        }
    }

    // MARK: Totals

    public var tonnageKg: Double { session.tonnageKg }
    public var countedSetCount: Int { session.countedSets.count }
    public var warmUpSetCount: Int { session.warmUpSetCount }
    public var totalHoldSeconds: Int { session.totalHoldSeconds }
    public var totalMetres: Double { session.totalMetres }

    /// What has been logged, for the finish dialog: "6 sets, 2,160 kg", "3 sets, 2:15 held", or nil before the first set.
    public var loggedSummary: String? {
        let count = countedSetCount
        guard count > 0 else { return nil }
        var parts = ["\(count) \(count == 1 ? "set" : "sets")"]
        if tonnageKg > 0 { parts.append("\(TrainLiveFormat.kilograms(tonnageKg.rounded())) kg") }
        if totalHoldSeconds > 0 { parts.append("\(TrainSetFormat.seconds(totalHoldSeconds)) held") }
        if totalMetres > 0 { parts.append("\(TrainSetFormat.metres(totalMetres)) covered") }
        return parts.joined(separator: ", ")
    }
    /// Sets the person has not logged or skipped yet.
    public var openSetCount: Int { remainingSteps.count }
    public func elapsedSeconds(at now: Date) -> TimeInterval { max(0, (session.endedAt ?? now).timeIntervalSince(session.startedAt)) }

    // MARK: Prefill and history

    private func lastSession(forKey key: String) -> SessionExercise? {
        for past in history {
            if let line = past.exercises.first(where: { $0.exercise.key == key && $0.status != .skipped && $0.sets.contains { !$0.skipped } }) {
                return line
            }
        }
        return nil
    }

    /// The heaviest set of the last session that had this exercise, with its reps. Nil before the first time.
    public func lastTopSet(forExerciseAt index: Int) -> (loadKg: Double, reps: Int)? {
        guard session.exercises.indices.contains(index),
              let last = lastSession(forKey: session.exercises[index].exercise.key) else { return nil }
        let sets = last.sets.filter { $0.isWorking && $0.reps > 0 }
        guard let top = sets.max(by: { ($0.loadKg ?? 0, $0.reps) < ($1.loadKg ?? 0, $1.reps) }) else { return nil }
        return (top.loadKg ?? 0, top.reps)
    }

    /// The most reps ever done for this exercise at `loadKg` or heavier, across past sessions and the
    /// sets already logged today. Nil when nothing that heavy has been lifted, so any count is a first.
    public func bestReps(forExerciseAt index: Int, atLeast loadKg: Double) -> Int? {
        guard session.exercises.indices.contains(index) else { return nil }
        let key = session.exercises[index].exercise.key
        let past = history.flatMap { $0.exercises.filter { $0.exercise.key == key && $0.status != .skipped }.flatMap(\.sets) }
        let today = session.exercises[index].sets
        let reps = (past + today).filter { $0.isWorking && $0.reps > 0 && $0.assistKg == nil && ($0.loadKg ?? 0) + 0.001 >= loadKg }.map(\.reps)
        return reps.max()
    }

    /// True when the exercise is done with a barbell, so the set screen can show plates. Uses the
    /// library's equipment when the exercise is in it, otherwise its name.
    public func usesBarbell(exerciseAt index: Int) -> Bool {
        guard session.exercises.indices.contains(index) else { return false }
        let line = session.exercises[index]
        guard line.planned.measure == .weight else { return false }
        if let definition = swapPool.first(where: { $0.key == line.exercise.key }), let equipment = definition.equipment {
            return equipment.lowercased() == "barbell"
        }
        return (line.exercise.key + " " + line.exercise.name).lowercased().contains("barbell")
    }

    /// The suggested values for a set, in the exercise's measure.
    public func prefill(for position: Position) -> SetPrefill {
        let line = session.exercises[position.exerciseIndex]
        return SetPrefill.resolve(setIndex: position.setIndex, planned: line.planned, progression: progression,
                                  thisSession: line.sets, lastSession: lastSession(forKey: line.exercise.key))
    }

    public func measure(ofExerciseAt index: Int) -> TrainSetMeasure {
        session.exercises.indices.contains(index) ? session.exercises[index].planned.measure : .weight
    }

    public var currentPrefill: SetPrefill? { cursor.map(prefill(for:)) }

    /// Why the suggestion moved from last time, for the caption under the number (R2-LIFT-08):
    /// "Last time 20 kg assist × 8. Rule: 2.5 kg less assist." or "Last time 80 kg × 8. Rule: add 2.5 kg."
    /// Nil when the suggestion copies a set or the plan, because "Last time" and the table already say so.
    public func prefillReason(for position: Position) -> String? {
        guard session.exercises.indices.contains(position.exerciseIndex) else { return nil }
        let line = session.exercises[position.exerciseIndex]
        let suggestion = prefill(for: position)
        guard suggestion.source == .progression, let last = lastSession(forKey: line.exercise.key) else { return nil }
        let measure = line.planned.measure
        let working = last.sets.filter { $0.isWorking && $0.reps > 0 }
        let increment = TrainLiveFormat.kilograms(progression.incrementKg ?? 0)
        let rule: String
        let top: LoggedSet?
        if measure == .bodyweight, working.contains(where: { ($0.assistKg ?? 0) > 0 }) {
            top = working.min { ($0.assistKg ?? 0, -$0.reps) < ($1.assistKg ?? 0, -$1.reps) }
            rule = (suggestion.assistKg ?? 0) > 0 ? "Rule: \(increment) kg less assist." : "Rule: no assist this time."
        } else {
            top = working.max { ($0.loadKg ?? 0, $0.reps) < ($1.loadKg ?? 0, $1.reps) }
            rule = "Rule: add \(increment) kg."
        }
        guard let top else { return nil }
        return "Last time \(TrainSetFormat.set(top.values, measure: measure)). \(rule)"
    }

    /// The reason for the set about to be logged. See `prefillReason(for:)`.
    public var currentPrefillReason: String? { cursor.flatMap(prefillReason(for:)) }

    /// "80 kg × 7, 7, 6, 6", "80 kg × 7, 82.5 kg × 6" or "8, 7, 6 reps" for a bodyweight exercise.
    /// Nil when the exercise has no history.
    public func lastTimeSummary(forExerciseAt index: Int) -> String? {
        guard session.exercises.indices.contains(index),
              let last = lastSession(forKey: session.exercises[index].exercise.key) else { return nil }
        let measure = session.exercises[index].planned.measure
        let sets = last.sets.filter { $0.isWorking && (measure.countsReps ? $0.reps > 0 : true) }
        guard !sets.isEmpty else { return nil }
        guard measure == .weight else { return "Last time " + ExerciseHistory.setsText(sets, measure: measure) }
        let loaded = sets.contains { ($0.loadKg ?? 0) > 0 }
        guard loaded else { return "Last time " + sets.map { String($0.reps) }.joined(separator: ", ") + " reps" }
        var groups: [(load: Double, reps: [Int])] = []
        for set in sets {
            let load = set.loadKg ?? 0
            if let last = groups.last, last.load == load { groups[groups.count - 1].reps.append(set.reps) }
            else { groups.append((load, [set.reps])) }
        }
        let text = groups.map { "\(TrainLiveFormat.kilograms($0.load)) kg × \($0.reps.map(String.init).joined(separator: ", "))" }
        return "Last time " + text.joined(separator: ", ")
    }

    // MARK: Table

    public func tableRows(forExerciseAt index: Int) -> [TrainSetRow] {
        guard session.exercises.indices.contains(index) else { return [] }
        let line = session.exercises[index]
        let current = cursor.flatMap { $0.exerciseIndex == index ? $0.setIndex : nil }
        var rows: [TrainSetRow] = []
        let count = max(line.planned.sets, line.sets.count)
        for setIndex in 0..<count {
            if setIndex < line.sets.count {
                let set = line.sets[setIndex]
                rows.append(TrainSetRow(number: setIndex + 1, loadKg: set.loadKg, reps: set.reps, rpe: set.rpe,
                                        state: set.skipped ? .skipped : .logged, seconds: set.seconds, metres: set.metres,
                                        assistKg: set.assistKg, tag: set.tag,
                                        isRecord: isRecord(exerciseIndex: index, setIndex: setIndex)))
            } else if line.status == .skipped || line.status == .done {
                continue
            } else {
                let suggestion = prefill(for: Position(exerciseIndex: index, setIndex: setIndex))
                rows.append(TrainSetRow(number: setIndex + 1, loadKg: suggestion.loadKg, reps: suggestion.reps, rpe: nil,
                                        state: setIndex == current ? .current : .planned, seconds: suggestion.seconds,
                                        metres: suggestion.metres, assistKg: suggestion.assistKg))
            }
        }
        return rows
    }

    // MARK: Records

    /// True when the logged set beat every earlier working set of this exercise, in past sessions and earlier
    /// today, on a metric its measure allows. A first performance has nothing to beat and is not a record.
    public func isRecord(exerciseIndex: Int, setIndex: Int) -> Bool {
        guard session.exercises.indices.contains(exerciseIndex),
              session.exercises[exerciseIndex].sets.indices.contains(setIndex) else { return false }
        let line = session.exercises[exerciseIndex]
        let set = line.sets[setIndex]
        let values = PersonalBestEvaluator.metricValues(of: set, measure: line.planned.measure)
        guard !values.isEmpty else { return false }
        var best = PersonalBestEvaluator.bestValues(exerciseKey: line.exercise.key, in: history) ?? [:]
        let earlier = session.exercises.filter { $0.exercise.key == line.exercise.key }
            .flatMap { other in other.sets.filter { $0.loggedAt < set.loggedAt && $0.id != set.id }.map { ($0, other.planned.measure) } }
        for (previous, measure) in earlier {
            for (metric, value) in PersonalBestEvaluator.metricValues(of: previous, measure: measure) {
                if let current = best[metric], !PersonalBestEvaluator.beats(value, current, metric: metric) { continue }
                best[metric] = value
            }
        }
        return values.contains { metric, value in
            best[metric].map { PersonalBestEvaluator.beats(value, $0, metric: metric) } ?? false
        }
    }

    // MARK: RPE

    /// The set logged most recently, which the rest card asks about. Nil before the first set.
    public var lastLoggedPosition: Position? {
        var latest: (Position, Date)?
        for (exerciseIndex, line) in session.exercises.enumerated() {
            for (setIndex, set) in line.sets.enumerated() where !set.skipped {
                if latest.map({ set.loggedAt >= $0.1 }) ?? true { latest = (Position(exerciseIndex: exerciseIndex, setIndex: setIndex), set.loggedAt) }
            }
        }
        return latest?.0
    }

    /// The RPE to suggest for a set: the last one given for this exercise earlier today, else in its last session.
    public func suggestedRPE(exerciseIndex: Int, setIndex: Int) -> Double? {
        guard session.exercises.indices.contains(exerciseIndex) else { return nil }
        let line = session.exercises[exerciseIndex]
        if let today = line.sets.prefix(max(setIndex, 0)).last(where: { $0.isWorking && $0.rpe != nil })?.rpe { return today }
        return lastSession(forKey: line.exercise.key)?.sets.last(where: { $0.isWorking && $0.rpe != nil })?.rpe
    }

    // MARK: Logging

    /// Checks the values against the line's measure and drops what does not apply: a load of zero is no
    /// load, a weight set has no seconds, and a bodyweight set is either loaded or assisted.
    private func validated(_ values: TrainSetValues, rpe: Double?, for line: SessionExercise) throws -> TrainSetValues {
        if let rpe, !LoggedSet.isValidRPE(rpe) { throw TrainLiveError.invalidRPE }
        func kilograms(_ value: Double?) throws -> Double? {
            guard let value else { return nil }
            guard value.isFinite, (0...TrainLimits.maxLoadKg).contains(value) else { throw TrainLiveError.invalidValue }
            return value > 0 ? value : nil
        }
        let measure = line.planned.measure
        let load = try kilograms(values.loadKg)
        switch measure {
        case .weight:
            guard (1...TrainLimits.maxReps).contains(values.reps) else { throw TrainLiveError.invalidValue }
            return TrainSetValues(loadKg: load, reps: values.reps)
        case .bodyweight:
            guard (1...TrainLimits.maxBodyweightReps).contains(values.reps) else { throw TrainLiveError.invalidValue }
            let assist = try kilograms(values.assistKg)
            guard load == nil || assist == nil else { throw TrainLiveError.invalidValue }
            return TrainSetValues(loadKg: load, reps: values.reps, assistKg: assist)
        case .time:
            guard let seconds = values.seconds, (1...TrainLimits.maxSetSeconds).contains(seconds),
                  (0...TrainLimits.maxBodyweightReps).contains(values.reps) else { throw TrainLiveError.invalidValue }
            return TrainSetValues(loadKg: load, reps: values.reps, seconds: seconds)
        case .distance:
            guard let metres = values.metres, TrainLimits.validMetres(metres),
                  (0...TrainLimits.maxBodyweightReps).contains(values.reps) else { throw TrainLiveError.invalidValue }
            return TrainSetValues(loadKg: load, reps: values.reps, metres: metres)
        }
    }

    /// Logs the next set with a load and reps. See `logSet(_:rpe:tag:now:)`.
    @discardableResult
    public mutating func logSet(loadKg: Double?, reps: Int, rpe: Double? = nil, now: Date) throws -> LoggedSet {
        try logSet(TrainSetValues(loadKg: loadKg, reps: reps), rpe: rpe, now: now)
    }

    /// Logs the next set in its exercise's measure. A load of zero is stored as no load. Starts the
    /// rest timer when another set follows. Returns the stored set.
    @discardableResult
    public mutating func logSet(_ values: TrainSetValues, rpe: Double? = nil, tag: LoggedSet.Tag? = nil, now: Date) throws -> LoggedSet {
        guard !isFinished else { throw TrainLiveError.sessionFinished }
        guard let position = cursor else { throw TrainLiveError.noOpenSet }
        let line = session.exercises[position.exerciseIndex]
        let stored = try validated(values, rpe: rpe, for: line)
        let suggestion = try? validated(prefill(for: position).values, rpe: nil, for: line)
        let edited = stored != suggestion
        let set = LoggedSet(loadKg: stored.loadKg, reps: stored.reps, rpe: rpe, loggedAt: now,
                            prefillSource: prefill(for: position).source.loggedSetSource, edited: edited,
                            seconds: stored.seconds, metres: stored.metres, assistKg: stored.assistKg, tag: tag)
        session.exercises[position.exerciseIndex].sets.append(set)
        closeIfComplete(position.exerciseIndex)
        if let seconds = restSeconds(after: position), cursor != nil {
            rest = RestTimer(startingAt: now, seconds: seconds)
        } else {
            rest = nil
        }
        return set
    }

    /// Records a skipped set for the next set to do. It keeps its place in the table and counts for nothing.
    public mutating func skipSet(now: Date) throws {
        guard !isFinished else { throw TrainLiveError.sessionFinished }
        guard let position = cursor else { throw TrainLiveError.noOpenSet }
        session.exercises[position.exerciseIndex].sets.append(
            LoggedSet(loadKg: nil, reps: 0, loggedAt: now, prefillSource: .manual, skipped: true))
        closeIfComplete(position.exerciseIndex)
    }

    /// Drops an exercise. With no counted set it is skipped. With some it finishes early and keeps them.
    public mutating func skipExercise(at index: Int) throws {
        guard !isFinished else { throw TrainLiveError.sessionFinished }
        guard session.exercises.indices.contains(index) else { throw TrainLiveError.noSuchExercise }
        guard isOpen(session.exercises[index]) else { return }
        session.exercises[index].status = session.exercises[index].sets.contains { !$0.skipped } ? .done : .skipped
    }

    /// Changes the load, reps or RPE of a set already logged. See `editSet(exerciseIndex:setIndex:values:rpe:)`.
    public mutating func editSet(exerciseIndex: Int, setIndex: Int, loadKg: Double?, reps: Int, rpe: Double?) throws {
        try editSet(exerciseIndex: exerciseIndex, setIndex: setIndex, values: TrainSetValues(loadKg: loadKg, reps: reps), rpe: rpe)
    }

    /// Changes the values or RPE of a set already logged. Its tag stays. Editing a skipped set turns it into a logged one.
    public mutating func editSet(exerciseIndex: Int, setIndex: Int, values: TrainSetValues, rpe: Double?) throws {
        guard !isFinished else { throw TrainLiveError.sessionFinished }
        guard session.exercises.indices.contains(exerciseIndex) else { throw TrainLiveError.noSuchExercise }
        guard session.exercises[exerciseIndex].sets.indices.contains(setIndex) else { throw TrainLiveError.noSuchSet }
        let line = session.exercises[exerciseIndex]
        let stored = try validated(values, rpe: rpe, for: line)
        session.exercises[exerciseIndex].sets[setIndex].loadKg = stored.loadKg
        session.exercises[exerciseIndex].sets[setIndex].reps = stored.reps
        session.exercises[exerciseIndex].sets[setIndex].seconds = stored.seconds
        session.exercises[exerciseIndex].sets[setIndex].metres = stored.metres
        session.exercises[exerciseIndex].sets[setIndex].assistKg = stored.assistKg
        session.exercises[exerciseIndex].sets[setIndex].rpe = rpe
        session.exercises[exerciseIndex].sets[setIndex].skipped = false
        session.exercises[exerciseIndex].sets[setIndex].edited = true
        if session.exercises[exerciseIndex].status == .skipped { session.exercises[exerciseIndex].status = .done }
    }

    /// Sets or clears the RPE of a logged set. Nothing else about the set changes.
    public mutating func setRPE(_ rpe: Double?, exerciseIndex: Int, setIndex: Int) throws {
        guard !isFinished else { throw TrainLiveError.sessionFinished }
        guard session.exercises.indices.contains(exerciseIndex) else { throw TrainLiveError.noSuchExercise }
        guard session.exercises[exerciseIndex].sets.indices.contains(setIndex),
              !session.exercises[exerciseIndex].sets[setIndex].skipped else { throw TrainLiveError.noSuchSet }
        if let rpe, !LoggedSet.isValidRPE(rpe) { throw TrainLiveError.invalidRPE }
        session.exercises[exerciseIndex].sets[setIndex].rpe = rpe
    }

    /// Marks a logged set as a warm-up, drop or failure set, or back to a working set with nil.
    public mutating func setTag(_ tag: LoggedSet.Tag?, exerciseIndex: Int, setIndex: Int) throws {
        guard !isFinished else { throw TrainLiveError.sessionFinished }
        guard session.exercises.indices.contains(exerciseIndex) else { throw TrainLiveError.noSuchExercise }
        guard session.exercises[exerciseIndex].sets.indices.contains(setIndex),
              !session.exercises[exerciseIndex].sets[setIndex].skipped else { throw TrainLiveError.noSuchSet }
        session.exercises[exerciseIndex].sets[setIndex].tag = tag
    }

    /// True while an exercise has no logged or skipped set, so what it records can still change.
    public func canChangeMeasure(ofExerciseAt index: Int) -> Bool {
        session.exercises.indices.contains(index) && isOpen(session.exercises[index]) && session.exercises[index].sets.isEmpty
    }

    /// Changes what an exercise records, before its first set. Time and distance start from their default targets.
    public mutating func setMeasure(_ measure: TrainSetMeasure, forExerciseAt index: Int) throws {
        guard !isFinished else { throw TrainLiveError.sessionFinished }
        guard session.exercises.indices.contains(index) else { throw TrainLiveError.noSuchExercise }
        guard canChangeMeasure(ofExerciseAt: index) else { throw TrainLiveError.measureLocked }
        var planned = session.exercises[index].planned
        guard planned.measure != measure else { return }
        planned.measure = measure
        planned.assistKg = nil
        if measure != .weight { planned.loadKg = nil }
        if measure == .time { planned.targetSeconds = planned.targetSeconds ?? TemplateExercise.defaultTargetSeconds }
        if measure == .distance { planned.targetMetres = planned.targetMetres ?? TemplateExercise.defaultTargetMetres }
        planned.repsMin = min(planned.repsMin, measure.maxReps)
        planned.repsMax = min(max(planned.repsMax, planned.repsMin), measure.maxReps)
        session.exercises[index].planned = planned
    }

    /// Moves to the block holding this exercise, when it still has sets to do.
    public mutating func focus(exerciseAt index: Int) throws {
        guard session.exercises.indices.contains(index) else { throw TrainLiveError.noSuchExercise }
        focusedExercise = index
    }

    private mutating func closeIfComplete(_ index: Int) {
        let line = session.exercises[index]
        guard isOpen(line), line.sets.count >= line.planned.sets else { return }
        session.exercises[index].status = line.sets.contains { !$0.skipped } ? .done : .skipped
    }

    // MARK: Build as you go

    /// Adds an exercise at the end and moves to it. It gets as many sets as last time, or three, and the
    /// reps and load from last time when there is one.
    @discardableResult
    public mutating func addExercise(_ definition: ExerciseDefinition) throws -> Int {
        guard !isFinished else { throw TrainLiveError.sessionFinished }
        guard session.exercises.count < TrainLimits.maxExercisesPerTemplate else { throw TrainLiveError.tooManyExercises }
        let last = lastSession(forKey: definition.key)
        let counted = last?.sets.filter(\.isWorking) ?? []
        // Last time's measure wins, so an exercise the person logged as a hold stays a hold.
        let measure = last?.planned.measure ?? TrainSetMeasure.defaultMeasure(for: definition)
        let reps = min(max(counted.first?.reps ?? 8, 1), measure.maxReps)
        let planned = TemplateExercise(exercise: definition.reference, sets: min(max(counted.count, 3), TrainLimits.maxSets),
                                       repsMin: reps, repsMax: reps, measure: measure, assistKg: last?.planned.assistKg,
                                       targetSeconds: measure == .time ? (last?.planned.targetSeconds ?? TemplateExercise.defaultTargetSeconds) : nil,
                                       targetMetres: measure == .distance ? (last?.planned.targetMetres ?? TemplateExercise.defaultTargetMetres) : nil,
                                       restSeconds: 120)
        session.exercises.append(SessionExercise(planned: planned))
        let index = session.exercises.count - 1
        focusedExercise = index
        return index
    }

    /// One more set at the end of an exercise. A finished exercise opens again.
    public mutating func addSet(toExerciseAt index: Int) throws {
        guard !isFinished else { throw TrainLiveError.sessionFinished }
        guard session.exercises.indices.contains(index) else { throw TrainLiveError.noSuchExercise }
        let line = session.exercises[index]
        let count = max(line.planned.sets, line.sets.count) + 1
        guard count <= TrainLimits.maxSets else { throw TrainLiveError.tooManySets }
        session.exercises[index].planned.sets = count
        settle(index)
        focusedExercise = index
    }

    /// Deletes a set, logged or still to do. The rows after it move up. Deleting an exercise's last set
    /// removes the exercise.
    public mutating func removeSet(exerciseIndex: Int, setIndex: Int) throws {
        guard !isFinished else { throw TrainLiveError.sessionFinished }
        guard session.exercises.indices.contains(exerciseIndex) else { throw TrainLiveError.noSuchExercise }
        var line = session.exercises[exerciseIndex]
        guard setIndex >= 0, setIndex < max(line.planned.sets, line.sets.count) else { throw TrainLiveError.noSuchSet }
        if setIndex < line.sets.count { line.sets.remove(at: setIndex) }
        line.planned.sets = max(line.planned.sets - 1, line.sets.count)
        guard line.planned.sets > 0 else { return try removeExercise(at: exerciseIndex) }
        session.exercises[exerciseIndex] = line
        settle(exerciseIndex)
    }

    /// Takes an exercise out of the session, with any sets logged for it.
    public mutating func removeExercise(at index: Int) throws {
        guard !isFinished else { throw TrainLiveError.sessionFinished }
        guard session.exercises.indices.contains(index) else { throw TrainLiveError.noSuchExercise }
        session.exercises.remove(at: index)
        if let focus = focusedExercise { focusedExercise = focus == index ? nil : focus > index ? focus - 1 : focus }
    }

    /// After sets are added or deleted: open while sets are left to do, otherwise done or skipped.
    private mutating func settle(_ index: Int) {
        let line = session.exercises[index]
        if line.sets.count < line.planned.sets {
            session.exercises[index].status = line.swappedFrom == nil ? .pending : .swapped
        } else {
            session.exercises[index].status = line.sets.contains { !$0.skipped } ? .done : .skipped
        }
    }

    // MARK: Swap

    /// Exercises that work the same muscles, not already in the session. Same equipment and the same
    /// kind of movement come first, then names in order.
    public func swapOptions(forExerciseAt index: Int, limit: Int = 12) -> [ExerciseDefinition] {
        guard session.exercises.indices.contains(index) else { return [] }
        let current = session.exercises[index].exercise
        guard let definition = swapPool.first(where: { $0.key == current.key }) else { return [] }
        let used = Set(session.exercises.map(\.exercise.key))
        let muscles = Set(definition.primaryMuscles.map { $0.lowercased() })
        guard !muscles.isEmpty else { return [] }
        let candidates = swapPool.filter { candidate in
            !used.contains(candidate.key)
                && candidate.category.lowercased() == definition.category.lowercased()
                && !muscles.isDisjoint(with: candidate.primaryMuscles.map { $0.lowercased() })
        }
        let sorted = candidates.sorted { lhs, rhs in
            let l = (lhs.equipment == definition.equipment ? 0 : 1, lhs.mechanic == definition.mechanic ? 0 : 1)
            let r = (rhs.equipment == definition.equipment ? 0 : 1, rhs.mechanic == definition.mechanic ? 0 : 1)
            if l != r { return l < r }
            return (lhs.name.lowercased(), lhs.key) < (rhs.name.lowercased(), rhs.key)
        }
        return Array(sorted.prefix(max(limit, 0)))
    }

    /// Every exercise the swap and the add-exercise picker can offer.
    public var exercisePool: [ExerciseDefinition] { swapPool }

    /// True while the exercise still has sets to do. Before its first set a swap replaces it; after, the sets
    /// already logged stay with it and the rest move to the replacement (R2-LIFT-11).
    public func canSwapExercise(at index: Int) -> Bool {
        session.exercises.indices.contains(index) && isOpen(session.exercises[index])
    }

    /// Sets of the exercise that a swap would move to the replacement: all of them before the first set.
    public func setsMovedBySwap(at index: Int) -> Int {
        guard canSwapExercise(at: index) else { return 0 }
        let line = session.exercises[index]
        return max(line.planned.sets - line.sets.count, 0)
    }

    /// Replaces an exercise. With no sets yet, the line itself changes: the plan keeps its sets, reps and rest, and
    /// the load, which belongs to the old lift, starts empty unless the new one has history. With sets logged, the
    /// exercise ends with them and a new line right after it takes the sets still to do.
    public mutating func swapExercise(at index: Int, with replacement: ExerciseDefinition) throws {
        guard !isFinished else { throw TrainLiveError.sessionFinished }
        guard session.exercises.indices.contains(index) else { throw TrainLiveError.noSuchExercise }
        guard canSwapExercise(at: index) else { throw TrainLiveError.exerciseStarted }
        let original = session.exercises[index]
        let started = !original.sets.isEmpty
        if started, session.exercises.count >= TrainLimits.maxExercisesPerTemplate { throw TrainLiveError.tooManyExercises }
        var planned = started
            ? TemplateExercise(exercise: replacement.reference, sets: original.planned.sets - original.sets.count,
                               repsMin: original.planned.repsMin, repsMax: original.planned.repsMax,
                               measure: original.planned.measure, targetSeconds: original.planned.targetSeconds,
                               targetMetres: original.planned.targetMetres, restSeconds: original.planned.restSeconds,
                               supersetGroup: original.planned.supersetGroup)
            : original.planned
        planned.exercise = replacement.reference
        planned.loadKg = nil
        planned.assistKg = nil
        let measure = TrainSetMeasure.defaultMeasure(for: replacement)
        planned.measure = measure
        planned.targetSeconds = measure == .time ? (planned.targetSeconds ?? TemplateExercise.defaultTargetSeconds) : nil
        planned.targetMetres = measure == .distance ? (planned.targetMetres ?? TemplateExercise.defaultTargetMetres) : nil
        planned.repsMin = min(planned.repsMin, measure.maxReps)
        planned.repsMax = min(max(planned.repsMax, planned.repsMin), measure.maxReps)
        let swapped = SessionExercise(planned: planned, exercise: replacement.reference, status: .swapped,
                                      swappedFrom: original.swappedFrom ?? original.exercise)
        if started {
            session.exercises[index].planned.sets = original.sets.count
            session.exercises[index].status = original.sets.contains { !$0.skipped } ? .done : .skipped
            session.exercises.insert(swapped, at: index + 1)
            if let focus = focusedExercise, focus > index { focusedExercise = focus + 1 }
            focusedExercise = index + 1
        } else {
            session.exercises[index] = SessionExercise(id: original.id, planned: planned, exercise: replacement.reference,
                                                       status: .swapped, swappedFrom: swapped.swappedFrom)
        }
    }

    // MARK: Rest

    /// Rest after the set at `position`. A superset rests once per round, after its last member, using the
    /// longest rest in the group. Nil means no rest.
    private func restSeconds(after position: Position) -> Int? {
        let line = session.exercises[position.exerciseIndex]
        guard line.planned.supersetGroup != nil,
              let block = blocks.first(where: { $0.contains(position.exerciseIndex) }) else {
            return line.planned.restSeconds > 0 ? line.planned.restSeconds : nil
        }
        let members = block.filter { session.exercises[$0].planned.sets > position.setIndex && session.exercises[$0].status != .skipped }
        guard members.last == position.exerciseIndex || members.isEmpty else { return nil }
        let longest = block.map { session.exercises[$0].planned.restSeconds }.max() ?? 0
        return longest > 0 ? longest : nil
    }

    public mutating func startRest(seconds: Int, now: Date) { rest = seconds > 0 ? RestTimer(startingAt: now, seconds: seconds) : nil }
    public mutating func extendRest(bySeconds seconds: Int = RestTimer.extensionSeconds, now: Date) {
        guard rest != nil else { return }
        rest?.extend(bySeconds: seconds, now: now)
    }
    public mutating func clearRest() { rest = nil }

    /// True once when the rest has just ended and is worth a buzz. See `RestTimer.claimCue`.
    public mutating func claimRestCue(at now: Date) -> Bool { rest?.claimCue(at: now) ?? false }

    // MARK: Finish

    /// Closes the session: open exercises are skipped or finished early, the end time is set and personal
    /// bests are worked out against earlier sessions. Calling it again returns the same session.
    @discardableResult
    public mutating func finish(now: Date) throws -> TrainSession {
        if isFinished { return session }
        var closed = session
        for index in closed.exercises.indices {
            let line = closed.exercises[index]
            guard line.status == .pending || line.status == .swapped || line.status == .done else { continue }
            closed.exercises[index].status = line.sets.contains { !$0.skipped } ? .done : .skipped
        }
        closed.status = .completed
        closed.endedAt = max(now, closed.startedAt)
        closed.bests = PersonalBestEvaluator.evaluate(session: closed, history: history)
        try closed.validate()
        session = closed
        rest = nil
        isFinished = true
        return closed
    }

    /// Keeps the revision the store returned, so the next save of this session is not stale.
    public mutating func recordSaved(revision: Int) { session.revision = revision }
}

/// Number text for the live screens. Loads are kilograms.
public enum TrainLiveFormat {
    private static let locale = Locale(identifier: "en_US")

    /// 80 shows "80", 82.5 shows "82.5", 2560 shows "2,560".
    public static func kilograms(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)).locale(locale))
    }

    /// RPE 8 shows "8", RPE 8.5 shows "8.5".
    public static func rpe(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)).locale(locale))
    }

    /// 1450 seconds shows "24:10", 3725 shows "1:02:05".
    public static func clock(seconds: TimeInterval) -> String {
        let whole = Int(max(0, seconds.isFinite ? seconds : 0))
        let hours = whole / 3_600, minutes = whole / 60 % 60, rest = whole % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%d:%02d", minutes, rest)
    }

    /// 62 minutes shows "62 min".
    public static func minutes(seconds: TimeInterval) -> String {
        "\(Int((max(0, seconds) / 60).rounded())) min"
    }
}
