import Foundation

/// The heaviest load lifted for an exact rep count, for the "Heaviest by reps" list.
public struct ExerciseRepBest: Equatable, Sendable, Identifiable {
    public let reps: Int
    public let loadKg: Double
    /// The session where the load was first lifted for this many reps.
    public let date: Date
    public var id: Int { reps }

    /// Rep counts a lifter compares: singles, triples, fives, eights and tens.
    public static let repCounts = [1, 3, 5, 8, 10]

    /// One row per rep count the history has a loaded set for, in rep order. A rep count with no set
    /// at exactly that many reps is left out, so nothing shown is inferred. An equal load lifted later
    /// keeps the first date.
    public static func bests(for exercise: ExerciseHistory.Exercise, repCounts: [Int] = repCounts) -> [ExerciseRepBest] {
        repCounts.compactMap { reps in
            var best: ExerciseRepBest?
            // Entries are newest first; walk oldest first so a tie keeps the earliest date.
            for entry in exercise.entries.reversed() {
                for set in entry.sets where set.reps == reps && !set.skipped {
                    guard let load = set.loadKg, load.isFinite, load > 0 else { continue }
                    if load > (best?.loadKg ?? 0) { best = ExerciseRepBest(reps: reps, loadKg: load, date: entry.date) }
                }
            }
            return best
        }
    }
}

/// When the progress chart may draw a line.
public enum ExerciseTrend {
    /// Fewer points than this draw dots only. Two points make a line that reads as a trend it is not.
    public static let minimumPoints = 3

    public static func drawsLine(pointCount: Int) -> Bool { pointCount >= minimumPoints }

    /// "One session so far." under a chart with one point (R2-DES-14), "One more session to draw a trend." with two,
    /// nil once there are enough.
    public static func caption(pointCount: Int) -> String? {
        let missing = minimumPoints - max(pointCount, 0)
        switch missing {
        case ...0: return nil
        case 1: return "One more session to draw a trend."
        case 2: return "One session so far."
        default: return nil
        }
    }
}

/// Joins history that two names for one lift would split.
///
/// Lines share an exercise when they have the same key, the same folded name ("Pull-up" and "Pullups"),
/// a name that is an alias of the other's key ("RDL" and `Romanian_Deadlift`), or a key the library merged
/// into another (`Band_Assisted_Pull-Up` into `Pullups`). Each group keeps one key: the merge target, then a
/// library key over a custom one, then the first in sort order.
public enum ExerciseHistoryMerge {
    /// Every exercise key in the sessions, mapped to the key its group keeps.
    public static func canonicalKeys(in sessions: [TrainSession]) -> [String: String] {
        var parent: [String: String] = [:]
        func root(_ key: String) -> String {
            var key = key
            while let next = parent[key], next != key { key = next }
            return key
        }
        func keeps(_ lhs: String, over rhs: String) -> Bool {
            let lhsMerged = ExerciseAliases.mergedKeys[lhs] != nil, rhsMerged = ExerciseAliases.mergedKeys[rhs] != nil
            if lhsMerged != rhsMerged { return !lhsMerged }
            let lhsCustom = lhs.hasPrefix(ExerciseDefinition.customKeyPrefix), rhsCustom = rhs.hasPrefix(ExerciseDefinition.customKeyPrefix)
            return lhsCustom != rhsCustom ? !lhsCustom : lhs < rhs
        }
        var owner: [String: String] = [:]
        for session in sessions {
            for line in session.exercises {
                let key = line.exercise.key
                if parent[key] == nil { parent[key] = key }
                var tokens = ["key:" + key]
                let name = ExerciseName.compact(line.exercise.name)
                if !name.isEmpty { tokens.append("name:" + name) }
                if let aliased = ExerciseAliases.key(forAlias: line.exercise.name) { tokens.append("key:" + aliased) }
                if let merged = ExerciseAliases.mergedKeys[key] { tokens.append("key:" + merged) }
                for token in tokens {
                    guard let other = owner[token] else { owner[token] = key; continue }
                    let lhs = root(other), rhs = root(key)
                    guard lhs != rhs else { continue }
                    if keeps(lhs, over: rhs) { parent[rhs] = lhs } else { parent[lhs] = rhs }
                }
            }
        }
        // A group made only of a merged key still files under the key it joined.
        return Dictionary(uniqueKeysWithValues: parent.keys.map { ($0, ExerciseAliases.canonicalKey(root($0))) })
    }

    /// The sessions with every line pointed at its group's key. Names stay as logged.
    public static func merged(_ sessions: [TrainSession]) -> [TrainSession] {
        let keys = canonicalKeys(in: sessions)
        return sessions.map { session in
            var session = session
            for index in session.exercises.indices {
                let ref = session.exercises[index].exercise
                if let key = keys[ref.key], key != ref.key { session.exercises[index].exercise = ExerciseRef(key: key, name: ref.name) }
            }
            return session
        }
    }
}

extension ExerciseHistory {
    /// History with lines that name one lift two ways joined (see `ExerciseHistoryMerge`).
    public init(mergingAliasesIn sessions: [TrainSession]) {
        self.init(sessions: ExerciseHistoryMerge.merged(sessions))
    }
}

/// The exercises behind the picker's Recent list.
public enum ExerciseRecents {
    /// Keys from finished sessions, newest session first and in workout order inside one, each once.
    /// Keys that name one lift two ways count once, under the key history keeps.
    public static func keys(from sessions: [TrainSession], limit: Int = 8) -> [String] {
        let finished = sessions.filter { $0.status == .completed }
        let canonical = ExerciseHistoryMerge.canonicalKeys(in: finished)
        var seen = Set<String>()
        var keys: [String] = []
        let ordered = finished.sorted { ($0.startedAt, $0.id.uuidString) > ($1.startedAt, $1.id.uuidString) }
        for session in ordered {
            for line in session.exercises where line.status != .skipped && line.sets.contains(where: { !$0.skipped }) {
                let key = canonical[line.exercise.key] ?? line.exercise.key
                guard seen.insert(key).inserted else { continue }
                keys.append(key)
                if keys.count >= limit { return keys }
            }
        }
        return keys
    }
}
