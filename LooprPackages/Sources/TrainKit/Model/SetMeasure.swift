import Foundation

/// What one set of an exercise records. Each exercise line in a template or session has one measure,
/// and the set screen, the table, the bests and the CSV follow it.
///
/// The raw values of `weight` and `bodyweight` match the old `TrainLoadKind`, so a payload written
/// before measures existed decodes to the same thing.
public enum TrainSetMeasure: String, CaseIterable, Codable, Sendable {
    /// Reps at a load: bench press, curls. The default.
    case weight
    /// Reps at body weight, with an optional added load (a weighted dip) or an assisting load taken
    /// off (a band or machine pull-up).
    case bodyweight
    /// A hold, in seconds, with an optional load: plank, dead hang, L-sit.
    case time
    /// A distance, in metres, with an optional load: farmer carry, sled push.
    case distance

    /// The measure picker's label.
    public var title: String {
        switch self {
        case .weight: "Reps and weight"
        case .bodyweight: "Bodyweight"
        case .time: "Time"
        case .distance: "Distance"
        }
    }

    /// True when a set of this measure is counted in reps.
    public var countsReps: Bool { self == .weight || self == .bodyweight }

    /// The most reps one set may hold: 100 for a loaded lift, 1,000 for bodyweight work such as double-unders.
    public var maxReps: Int { self == .weight ? TrainLimits.maxReps : TrainLimits.maxBodyweightReps }

    /// The measure a newly added exercise starts with, from its library category, equipment and name.
    ///
    /// Stretches and holds (plank, side plank, dead hang, L-sit, hollow hold, wall sit) are timed. Carries,
    /// farmer walks, yoke walks and sled pushes and drags are distances. Anything else done with "body only"
    /// equipment is bodyweight, and the rest is reps and weight.
    public static func defaultMeasure(for definition: ExerciseDefinition) -> TrainSetMeasure {
        defaultMeasure(name: definition.name, category: definition.category, equipment: definition.equipment)
    }

    public static func defaultMeasure(name: String, category: String?, equipment: String?) -> TrainSetMeasure {
        let text = name.lowercased().replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        let words = Set(text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        let category = (category ?? "").lowercased()
        let equipment = (equipment ?? "").lowercased()

        if distanceNames.contains(where: { text.contains($0) }) || words.contains("carry") || words.contains("carries") {
            return .distance
        }
        if category == "stretching" || category == "cardio" { return .time }
        if holdNames.contains(where: { text.contains($0) }) { return .time }
        // "Hang" alone is a hold. "Hang clean" and "hang snatch" are lifts from the hang position.
        if words.contains("hang"), words.isDisjoint(with: ["clean", "snatch", "pull", "power", "high"]) { return .time }
        if words.contains("plank"), words.isDisjoint(with: ["jack", "jacks", "push", "row", "up", "tap", "taps"]) { return .time }
        if words.contains("hold"), words.isDisjoint(with: ["row"]) { return .time }
        if equipment == "body only" || words.contains("bodyweight") { return .bodyweight }
        return .weight
    }

    private static let holdNames = ["side bridge", "dead hang", "l sit", "hollow hold", "hollow body", "wall sit", "isometric",
                                    "static hold", "handstand hold"]
    private static let distanceNames = ["farmer", "yoke walk", "sled push", "sled drag", "sled pull", "prowler",
                                        "backward walk", "suitcase walk", "overhead walk"]
}

extension LoggedSet {
    /// What a set was, beyond a plain working set. Nil means a working set.
    public enum Tag: String, CaseIterable, Codable, Sendable {
        /// Lighter sets before the work. They never count toward volume, bests, progression or the weekly dose.
        case warmUp
        /// A set straight after another at a lower load. It counts as work.
        case drop
        /// A set taken to failure. It counts as work.
        case failure

        public var title: String {
            switch self {
            case .warmUp: "Warm-up"
            case .drop: "Drop set"
            case .failure: "To failure"
            }
        }

        /// The one letter the set table shows in place of the set number.
        public var letter: String {
            switch self {
            case .warmUp: "W"
            case .drop: "D"
            case .failure: "F"
            }
        }
    }
}

/// The numbers of one set, whatever its measure. The live screen edits one of these and logs it.
public struct TrainSetValues: Equatable, Hashable, Sendable {
    /// The barbell or dumbbell load, or for bodyweight the load added on a belt or vest. Nil or 0 means none.
    public var loadKg: Double?
    public var reps: Int
    /// Seconds held, for a time set.
    public var seconds: Int?
    /// Metres covered, for a distance set.
    public var metres: Double?
    /// Kilograms of assistance taken off body weight, for a band or machine assisted set.
    public var assistKg: Double?

    public init(loadKg: Double? = nil, reps: Int = 0, seconds: Int? = nil, metres: Double? = nil, assistKg: Double? = nil) {
        self.loadKg = loadKg; self.reps = reps; self.seconds = seconds; self.metres = metres; self.assistKg = assistKg
    }

    public init(_ set: LoggedSet) {
        self.init(loadKg: set.loadKg, reps: set.reps, seconds: set.seconds, metres: set.metres, assistKg: set.assistKg)
    }
}

/// Text for sets of every measure. Assistance is written out ("20 kg assist"), never as a signed number.
public enum TrainSetFormat {
    public static let minus = "\u{2212}"

    /// "0:45" for 45 seconds, "1:30" for 90.
    public static func seconds(_ value: Int) -> String {
        let clamped = max(value, 0)
        return "\(clamped / 60):" + String(format: "%02d", clamped % 60)
    }

    /// "40 m", "1.2 km" from 1,200 m.
    public static func metres(_ value: Double) -> String {
        value >= 1_000 ? "\(TrainLiveFormat.kilograms((value / 100).rounded() / 10)) km" : "\(TrainLiveFormat.kilograms(value)) m"
    }

    /// "Bodyweight", "+10 kg" or "20 kg assist": the load of a bodyweight set in words, the same in the set table's
    /// Load column, the log bar, the builder and the history (R2-LIFT-04, R2-DES-18). `unit` is kept for older callers;
    /// the text always names kilograms, because "−20" read as a weight.
    public static func bodyweight(addedKg: Double?, assistKg: Double?, unit: Bool = true) -> String {
        if let assistKg, assistKg > 0 { return "\(TrainLiveFormat.kilograms(assistKg)) kg assist" }
        if let addedKg, addedKg > 0 { return "+\(TrainLiveFormat.kilograms(addedKg)) kg" }
        return "Bodyweight"
    }

    /// One set in words: "80 kg × 8", "+10 kg × 6", "20 kg assist × 7", "12 reps", "0:45", "0:30 at 10 kg", "40 m at 32 kg".
    public static func set(_ values: TrainSetValues, measure: TrainSetMeasure) -> String {
        switch measure {
        case .weight:
            guard let load = values.loadKg, load > 0 else { return "\(values.reps) reps" }
            return "\(TrainLiveFormat.kilograms(load)) kg × \(values.reps)"
        case .bodyweight:
            guard (values.assistKg ?? 0) > 0 || (values.loadKg ?? 0) > 0 else { return "\(values.reps) reps" }
            return "\(bodyweight(addedKg: values.loadKg, assistKg: values.assistKg)) × \(values.reps)"
        case .time:
            return seconds(values.seconds ?? 0) + loadSuffix(values.loadKg)
        case .distance:
            return metres(values.metres ?? 0) + loadSuffix(values.loadKg)
        }
    }

    /// The same set for VoiceOver: "20 kilograms of assistance, 8 reps", "45 seconds".
    public static func spoken(_ values: TrainSetValues, measure: TrainSetMeasure) -> String {
        let load = values.loadKg.flatMap { $0 > 0 ? ", at \(TrainLiveFormat.kilograms($0)) kilograms" : nil } ?? ""
        switch measure {
        case .weight:
            guard let kg = values.loadKg, kg > 0 else { return "\(values.reps) reps" }
            return "\(TrainLiveFormat.kilograms(kg)) kilograms, \(values.reps) reps"
        case .bodyweight:
            if let assist = values.assistKg, assist > 0 {
                return "\(TrainLiveFormat.kilograms(assist)) kilograms of assistance, \(values.reps) reps"
            }
            if let added = values.loadKg, added > 0 {
                return "Body weight plus \(TrainLiveFormat.kilograms(added)) kilograms, \(values.reps) reps"
            }
            return "Body weight, \(values.reps) reps"
        case .time:
            return LooprSpokenSeconds.text(values.seconds ?? 0) + load
        case .distance:
            return "\(TrainLiveFormat.kilograms(values.metres ?? 0)) metres" + load
        }
    }

    private static func loadSuffix(_ load: Double?) -> String {
        guard let load, load > 0 else { return "" }
        return " at \(TrainLiveFormat.kilograms(load)) kg"
    }
}

/// "45 seconds", "1 minute 30 seconds".
enum LooprSpokenSeconds {
    static func text(_ value: Int) -> String {
        let value = max(value, 0)
        let minutes = value / 60, rest = value % 60
        var parts: [String] = []
        if minutes > 0 { parts.append("\(minutes) \(minutes == 1 ? "minute" : "minutes")") }
        if rest > 0 || parts.isEmpty { parts.append("\(rest) \(rest == 1 ? "second" : "seconds")") }
        return parts.joined(separator: " ")
    }
}
