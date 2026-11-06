import Foundation

/// The muscle groups the hard-sets page draws, one bar each. The library's 17 muscle names fold into these.
public enum MuscleGroup: String, CaseIterable, Sendable, Identifiable {
    case chest, back, shoulders, biceps, triceps, forearms, core, quads, hamstrings, glutes, calves, lowerBack, traps, hips

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .chest: "Chest"
        case .back: "Back"
        case .shoulders: "Shoulders"
        case .biceps: "Biceps"
        case .triceps: "Triceps"
        case .forearms: "Forearms"
        case .core: "Core"
        case .quads: "Quads"
        case .hamstrings: "Hamstrings"
        case .glutes: "Glutes"
        case .calves: "Calves"
        case .lowerBack: "Lower back"
        case .traps: "Traps"
        case .hips: "Hips"
        }
    }

    /// The group a library muscle name belongs to, or nil for a name Loopr does not know. Case does not matter.
    public init?(libraryMuscle name: String) {
        switch name.lowercased().trimmingCharacters(in: .whitespaces) {
        case "chest": self = .chest
        case "lats", "middle back": self = .back
        case "shoulders": self = .shoulders
        case "biceps": self = .biceps
        case "triceps": self = .triceps
        case "forearms": self = .forearms
        case "abdominals": self = .core
        case "quadriceps": self = .quads
        case "hamstrings": self = .hamstrings
        case "glutes": self = .glutes
        case "calves": self = .calves
        case "lower back": self = .lowerBack
        case "traps", "neck": self = .traps
        case "abductors", "adductors": self = .hips
        default: return nil
        }
    }
}

/// Hard sets per muscle group for one week (R2-LIFT-06, R1-LIFT-06). Pure: built from finished sessions and a lookup
/// from exercise key to library entry.
///
/// The rule, also written on the page: a hard set is a working set, so warm-ups and skipped sets do not count. Each
/// working set adds 1 to every group its exercise names as primary and 0.5 to every other group it names as
/// secondary. A group named both ways counts once, as primary. Stretches and cardio machines add nothing, and an
/// exercise without muscles in the library is counted apart so the page can say how many sets it left out.
public struct MuscleVolumeWeek: Equatable, Sendable {
    /// One bar.
    public struct Group: Equatable, Sendable, Identifiable {
        public let group: MuscleGroup
        /// Primary sets plus half the secondary ones.
        public let sets: Double
        public let primarySets: Int
        public let secondarySets: Int
        /// Exercise names that added to the group, most sets first.
        public let exercises: [String]
        public var id: MuscleGroup { group }
    }

    /// The groups trained this week, most sets first, then in `MuscleGroup` order.
    public let groups: [Group]
    /// Groups with no set this week, in `MuscleGroup` order.
    public let untrained: [MuscleGroup]
    /// Working sets of exercises the library has no muscles for, such as a custom exercise saved without any.
    public let unmappedSets: Int
    /// Finished sessions this week that held at least one working set.
    public let sessionCount: Int
    /// The week counted, Monday 00:00 to the next Monday 00:00 in the person's zone.
    public let start: Date
    public let end: Date

    /// The rule as the page writes it.
    public static let rule = "A hard set is a working set. Warm-ups don't count. A secondary muscle counts as half a set."

    /// The reference mark on each bar, from one review (Schoenfeld, Ogborn and Krieger, J Sports Sci 2017): ten or more
    /// weekly sets per muscle gave more growth than fewer. Drawn as a thin mark only, never as a colour.
    public static let referenceSets = 10.0

    /// What the reference mark means, for the page footnote.
    public static let referenceNote = "The mark at 10 sets is from a 2017 review by Schoenfeld, Ogborn and Krieger. "
        + "People doing 10 or more sets per muscle a week gained more muscle than people doing fewer. "
        + "It is about muscle size. Loopr does not set it as your target."

    /// - Parameters:
    ///   - sessions: Any sessions. Only completed ones that started inside `week` count.
    ///   - definition: The library entry for an exercise key, merged custom exercises included.
    public init(sessions: [TrainSession], week: ISOWeek, definition: (String) -> ExerciseDefinition?) {
        var totals: [MuscleGroup: (primary: Int, secondary: Int, byExercise: [String: Double])] = [:]
        var unmapped = 0
        var counted = 0
        for session in sessions where session.status == .completed && week.contains(session.startedAt) {
            var sessionHasWork = false
            for line in session.exercises where line.status != .skipped {
                let sets = line.sets.filter(\.isWorking).count
                guard sets > 0 else { continue }
                sessionHasWork = true
                guard let entry = definition(line.exercise.key) else { unmapped += sets; continue }
                let category = entry.categoryKind
                if category == .stretching || category == .cardio { continue }
                let primary = Set(entry.primaryMuscles.compactMap(MuscleGroup.init(libraryMuscle:)))
                let secondary = Set(entry.secondaryMuscles.compactMap(MuscleGroup.init(libraryMuscle:))).subtracting(primary)
                guard !primary.isEmpty || !secondary.isEmpty else { unmapped += sets; continue }
                for group in primary {
                    totals[group, default: (0, 0, [:])].primary += sets
                    totals[group, default: (0, 0, [:])].byExercise[line.exercise.name, default: 0] += Double(sets)
                }
                for group in secondary {
                    totals[group, default: (0, 0, [:])].secondary += sets
                    totals[group, default: (0, 0, [:])].byExercise[line.exercise.name, default: 0] += Double(sets) / 2
                }
            }
            if sessionHasWork { counted += 1 }
        }
        let order = Dictionary(uniqueKeysWithValues: MuscleGroup.allCases.enumerated().map { ($1, $0) })
        groups = totals.map { group, total in
            Group(group: group, sets: Double(total.primary) + Double(total.secondary) / 2, primarySets: total.primary,
                  secondarySets: total.secondary,
                  exercises: total.byExercise.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map(\.key))
        }
        .sorted { lhs, rhs in
            lhs.sets != rhs.sets ? lhs.sets > rhs.sets : (order[lhs.group] ?? 0) < (order[rhs.group] ?? 0)
        }
        untrained = MuscleGroup.allCases.filter { totals[$0] == nil }
        unmappedSets = unmapped
        sessionCount = counted
        start = week.start
        end = week.end
    }

    public var isEmpty: Bool { groups.isEmpty }

    /// "8", "7.5": whole sets without a decimal, half sets with one.
    public static func setsText(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }

    /// "8 sets", "1 set", "7.5 sets".
    public static func setsPhrase(_ value: Double) -> String {
        "\(setsText(value)) \(value == 1 ? "set" : "sets")"
    }

    /// "Chest, 8 hard sets: 6 as the main muscle, 4 as a helper counted at half."
    public static func spoken(_ group: Group) -> String {
        var parts = ["\(group.group.title), \(setsText(group.sets)) hard \(group.sets == 1 ? "set" : "sets")"]
        var detail: [String] = []
        if group.primarySets > 0 { detail.append("\(group.primarySets) as the main muscle") }
        if group.secondarySets > 0 { detail.append("\(group.secondarySets) as a helper, counted at half") }
        if !detail.isEmpty { parts.append(detail.joined(separator: ", ")) }
        return parts.joined(separator: ". ")
    }
}
