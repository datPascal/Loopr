import DesignSystem
import Foundation

/// What a finished session adds per exercise: what last time was, what changed, how long the rests ran. Pure.
public struct TrainSessionComparison: Equatable, Sendable {
    public struct Exercise: Equatable, Sendable {
        /// "Last time, 7 Nov: 80 kg × 7, 7, 6, 6".
        public let lastTimeLine: String?
        /// "+2 reps", "+2.5 kg on the top set", "Same as last time". Nil without a last time, or for timed and distance sets.
        public let changeLine: String?
        /// "Rest about 2:10, longest 3:05", counted between logged sets.
        public let restLine: String?
        /// "Estimated 1RM 127 kg, was 120 kg". Worked out from the top set, every time, so it does not wait for a record.
        public let oneRepMaxLine: String?
    }

    /// By exercise index in the session.
    public let exercises: [Int: Exercise]

    public init(session: TrainSession, history: [TrainSession], calendar: Calendar = .autoupdatingCurrent) {
        let earlier = history.filter { $0.id != session.id && $0.status == .completed && $0.startedAt < session.startedAt }
        let past = ExerciseHistory(sessions: earlier)
        var output: [Int: Exercise] = [:]
        for (index, line) in session.exercises.enumerated() {
            let counted = line.sets.filter(\.isWorking)
            let entry = past.exercises.first { $0.key == line.exercise.key }?.entries.first
            // Assisted sets get lighter by adding load the other way, so their numbers are not compared here.
            let assisted = counted.contains { $0.assistKg != nil } || (entry?.sets.contains { $0.assistKg != nil } ?? false)
            let compares = [TrainSetMeasure.weight, .bodyweight].contains(line.planned.measure) && !assisted
            output[index] = Exercise(
                lastTimeLine: entry.flatMap { compares ? Self.lastTimeLine($0, calendar: calendar) : nil },
                changeLine: entry.flatMap { compares ? Self.changeLine(now: counted, last: $0.sets) : nil },
                restLine: Self.restLine(counted),
                oneRepMaxLine: compares ? Self.oneRepMaxLine(counted, last: entry) : nil)
        }
        exercises = output
    }

    /// "80 kg × 7, 7, 6, 6" when the load held, "80 kg × 7, 82.5 kg × 6" when it changed.
    static func setsText(_ sets: [LoggedSet]) -> String {
        guard let first = sets.first else { return "" }
        if Set(sets.map(\.loadKg)).count == 1 {
            let reps = sets.map { String($0.reps) }.joined(separator: ", ")
            return first.loadKg.map { "\(TrainLiveFormat.kilograms($0)) kg × \(reps)" } ?? "\(reps) reps"
        }
        return sets.map { set in
            set.loadKg.map { "\(TrainLiveFormat.kilograms($0)) kg × \(set.reps)" } ?? "\(set.reps) reps"
        }.joined(separator: ", ")
    }

    private static func lastTimeLine(_ entry: ExerciseHistory.Entry, calendar: Calendar) -> String {
        var style = Date.FormatStyle.dateTime.day().month(.abbreviated)
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        return "Last time, \(entry.date.formatted(style)): \(setsText(entry.sets))"
    }

    /// The top load first, since that is what moved; then total reps at the same top load.
    static func changeLine(now: [LoggedSet], last: [LoggedSet]) -> String? {
        guard !now.isEmpty, !last.isEmpty else { return nil }
        let top = now.compactMap(\.loadKg).max() ?? 0, lastTop = last.compactMap(\.loadKg).max() ?? 0
        if abs(top - lastTop) >= 0.01 {
            let change = top - lastTop
            return "\(LooprSignedNumber.text(change, fractionDigits: change == change.rounded() ? 0 : 1)) kg on the top set"
        }
        let reps = now.reduce(0) { $0 + $1.reps } - last.reduce(0) { $0 + $1.reps }
        return reps == 0 ? "Same as last time" : "\(LooprSignedNumber.text(Double(reps))) \(abs(reps) == 1 ? "rep" : "reps")"
    }

    static func oneRepMaxLine(_ sets: [LoggedSet], last: ExerciseHistory.Entry?) -> String? {
        guard let top = sets.compactMap(PersonalBestEvaluator.values(of:)).map(\.estimatedOneRepMax).max() else { return nil }
        let was = last?.estimatedOneRepMax.map { ", was \(Int($0.rounded())) kg" } ?? ""
        return "Estimated 1RM \(Int(top.rounded())) kg\(was)"
    }

    /// From when each set was logged. A gap over 15 minutes is something else, so it does not count as rest.
    static func restLine(_ sets: [LoggedSet]) -> String? {
        let gaps = zip(sets, sets.dropFirst()).map { $1.loggedAt.timeIntervalSince($0.loggedAt) }.filter { $0 > 0 && $0 <= 900 }
        guard !gaps.isEmpty, let longest = gaps.max() else { return nil }
        let average = gaps.reduce(0, +) / Double(gaps.count)
        return "Rest about \(clock(average)), longest \(clock(longest))"
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds.rounded())
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}

/// Fixing a set after the session. Bests are worked out again, so a corrected typo cannot leave a false record.
public enum TrainSessionCorrection {
    public static func editing(_ session: TrainSession, exerciseIndex: Int, setIndex: Int, values: TrainSetValues, tag: LoggedSet.Tag?,
                               rpe: Double? = nil, history: [TrainSession]) throws -> TrainSession {
        var copy = session
        guard copy.exercises.indices.contains(exerciseIndex), copy.exercises[exerciseIndex].sets.indices.contains(setIndex) else {
            throw TrainError.invalidRecord
        }
        var set = copy.exercises[exerciseIndex].sets[setIndex]
        set.loadKg = values.loadKg
        set.reps = values.reps
        set.seconds = values.seconds
        set.metres = values.metres
        set.assistKg = values.assistKg
        set.tag = tag
        set.rpe = rpe
        set.skipped = false
        set.edited = true
        try set.validate(measure: copy.exercises[exerciseIndex].planned.measure)
        copy.exercises[exerciseIndex].sets[setIndex] = set
        if copy.exercises[exerciseIndex].status == .skipped || copy.exercises[exerciseIndex].status == .pending {
            copy.exercises[exerciseIndex].status = .done
        }
        copy.bests = PersonalBestEvaluator.evaluate(session: copy, history: history)
        return copy
    }

    /// A set forgotten during the session, logged a little after the one before it, so rest stays believable.
    public static func adding(_ session: TrainSession, exerciseIndex: Int, values: TrainSetValues, tag: LoggedSet.Tag?, rpe: Double?,
                              history: [TrainSession]) throws -> TrainSession {
        var copy = session
        guard copy.exercises.indices.contains(exerciseIndex) else { throw TrainError.invalidRecord }
        let last = copy.exercises[exerciseIndex].sets.last?.loggedAt ?? session.startedAt
        var set = LoggedSet(loadKg: values.loadKg, reps: values.reps, rpe: rpe, loggedAt: last.addingTimeInterval(1), prefillSource: .manual, edited: true)
        set.seconds = values.seconds
        set.metres = values.metres
        set.assistKg = values.assistKg
        set.tag = tag
        try set.validate(measure: copy.exercises[exerciseIndex].planned.measure)
        copy.exercises[exerciseIndex].sets.append(set)
        if copy.exercises[exerciseIndex].status == .skipped || copy.exercises[exerciseIndex].status == .pending {
            copy.exercises[exerciseIndex].status = .done
        }
        copy.bests = PersonalBestEvaluator.evaluate(session: copy, history: history)
        return copy
    }

    public static func deleting(_ session: TrainSession, exerciseIndex: Int, setIndex: Int, history: [TrainSession]) throws -> TrainSession {
        var copy = session
        guard copy.exercises.indices.contains(exerciseIndex), copy.exercises[exerciseIndex].sets.indices.contains(setIndex) else {
            throw TrainError.invalidRecord
        }
        copy.exercises[exerciseIndex].sets.remove(at: setIndex)
        if copy.exercises[exerciseIndex].sets.isEmpty, copy.exercises[exerciseIndex].status != .swapped {
            copy.exercises[exerciseIndex].status = .skipped
        }
        copy.bests = PersonalBestEvaluator.evaluate(session: copy, history: history)
        return copy
    }
}
