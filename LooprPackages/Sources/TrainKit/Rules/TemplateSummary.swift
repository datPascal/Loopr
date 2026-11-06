import Foundation

/// Counts and a time estimate for a template card. Pure value logic.
public struct TemplateSummary: Equatable, Sendable {
    /// Seconds one rep takes, including the lowering phase.
    public static let secondsPerRep = 3.0
    /// Seconds to set up each exercise (load the bar, find the station).
    public static let setupSecondsPerExercise = 30.0
    /// Walking pace for a carry or sled, in metres per second.
    public static let metresPerSecond = 1.0

    /// One set's working time: reps at `secondsPerRep` from the middle of the range, the hold itself,
    /// or the distance at `metresPerSecond`.
    static func workSeconds(_ line: TemplateExercise) -> Double {
        switch line.measure {
        case .weight, .bodyweight: Double(line.repsMin + line.repsMax) / 2 * secondsPerRep
        case .time: Double(line.plannedSeconds)
        case .distance: line.plannedMetres / metresPerSecond
        }
    }

    public let exerciseCount: Int
    public let totalSets: Int
    public let estimatedMinutes: Int

    public init(exerciseCount: Int, totalSets: Int, estimatedMinutes: Int) {
        self.exerciseCount = exerciseCount; self.totalSets = totalSets; self.estimatedMinutes = estimatedMinutes
    }

    public init(template: WorkoutTemplate) {
        if template.kind == .cardio {
            self.init(exerciseCount: 0, totalSets: 0, estimatedMinutes: template.cardio?.minutes ?? 0)
        } else {
            self.init(exercises: template.exercises)
        }
    }

    /// Time is reps at `secondsPerRep` using the middle of each rep range, plus `setupSecondsPerExercise`
    /// per exercise, plus rest after every set except the last one of the session. Superset members
    /// share one rest per round, using the longest rest in the group. The result rounds to the nearest
    /// minute, and is at least one minute when there is any work.
    public init(exercises: [TemplateExercise]) {
        var blocks: [[TemplateExercise]] = []
        for line in exercises {
            if let group = line.supersetGroup, let lastGroup = blocks.last?.last?.supersetGroup, group == lastGroup {
                blocks[blocks.count - 1].append(line)
            } else {
                blocks.append([line])
            }
        }
        var seconds = 0.0
        var lastBlockRest = 0.0
        for block in blocks {
            for line in block {
                seconds += Double(line.sets) * Self.workSeconds(line) + Self.setupSecondsPerExercise
            }
            let rounds = Double(block.map(\.sets).max() ?? 0)
            let rest = Double(block.map(\.restSeconds).max() ?? 0)
            seconds += rounds * rest
            lastBlockRest = rounds > 0 ? rest : 0
        }
        seconds -= lastBlockRest
        let sets = exercises.reduce(0) { $0 + $1.sets }
        let minutes = sets == 0 ? 0 : max(1, Int((max(seconds, 0) / 60).rounded()))
        self.init(exerciseCount: exercises.count, totalSets: sets, estimatedMinutes: minutes)
    }
}

/// The strain a person can expect from a template, from how it went before.
public enum ExpectedStrain {
    /// A finished session's strain, kept apart from `TrainSession` because strain lives on the linked workout record.
    public struct Sample: Equatable, Sendable {
        public let templateID: UUID?
        public let endedAt: Date
        public let strain: Double?

        public init(templateID: UUID?, endedAt: Date, strain: Double?) {
            self.templateID = templateID; self.endedAt = endedAt; self.strain = strain
        }
    }

    public static let sessionCount = 3

    /// Mean strain of the last three sessions of the template that have a strain value.
    /// Nil when there is no such history.
    public static func estimate(templateID: UUID, history: [Sample]) -> Double? {
        let recent = history
            .filter { $0.templateID == templateID && ($0.strain.map(\.isFinite) ?? false) }
            .sorted { $0.endedAt > $1.endedAt }
            .prefix(sessionCount)
            .compactMap(\.strain)
        guard !recent.isEmpty else { return nil }
        return recent.reduce(0, +) / Double(recent.count)
    }
}
