import Foundation

/// Folds exercise names so the ways people write one name compare equal.
///
/// Case, diacritics, apostrophes, hyphens, slashes and spaces are ignored, and a trailing "s" on a
/// word is dropped: "Pull-up", "pullup", "Pull ups" and "Pullups" all become `pullup`.
public enum ExerciseName {
    /// The words of a name, folded, each without a trailing "s". "World's greatest stretch" gives
    /// `["world", "greatest", "stretch"]`.
    public static func words(_ text: String) -> [String] {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "")
        return folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map { singular(String($0)) }
    }

    /// The words joined with nothing between them. Two names with the same compact form are the same name.
    public static func compact(_ text: String) -> String { words(text).joined() }

    /// "pullups" to "pullup", "dips" to "dip". Words under three letters and words ending in "ss" stay.
    static func singular(_ word: String) -> String {
        guard word.count >= 3, word.hasSuffix("s"), !word.hasSuffix("ss") else { return word }
        return String(word.dropLast())
    }
}

/// Other names people use for exercises in the library, keyed by the exercise's key.
///
/// An alias finds the exercise in search and joins history logged under that name, so "RDL" and
/// "Romanian deadlift" never become two lifts. Spelling variants that `ExerciseName` already folds
/// ("pull-up" and "Pullups") need no alias.
public enum ExerciseAliases {
    /// The aliases below, plus each renamed library entry's dataset name (`ExerciseDisplayNames`), so a search for
    /// "Barbell Squat" still finds Back squat and history logged under the old name joins the new one.
    public static let byKey: [String: [String]] = {
        var aliases = written
        for (key, renamed) in ExerciseDisplayNames.byKey {
            aliases[key, default: []].append(renamed.dataset)
        }
        for (merged, key) in mergedKeys {
            aliases[key, default: []].append(contentsOf: ExerciseDisplayNames.mergedDatasetNames[merged].map { [$0] } ?? [])
        }
        return aliases
    }()

    /// Library keys that are the same lift as another key. The library lists only the key on the right, and
    /// history logged under the left one joins it, so a band pull-up and a pull-up are one chart (R2-WOD-13).
    public static let mergedKeys: [String: String] = [
        "Band_Assisted_Pull-Up": "Pullups"
    ]

    /// The key a library key lives under: itself, or the key it was merged into.
    public static func canonicalKey(_ key: String) -> String { mergedKeys[key] ?? key }

    private static let written: [String: [String]] = [
        // Bundled Free Exercise DB entries.
        // "Assisted pull-up" stays the Loopr addition's own name (`loopr-assisted-pull-up`).
        "Pullups": ["Pull-up", "Strict pull-up", "Banded pull-up"],
        "Pushups": ["Push-up"],
        "Chin-Up": ["Chin"],
        "Romanian_Deadlift": ["RDL"],
        "Barbell_Deadlift": ["Deadlift", "Conventional deadlift"],
        "Barbell_Squat": ["Back squat", "Squat"],
        "Barbell_Bench_Press_-_Medium_Grip": ["Bench press", "Bench"],
        "Barbell_Shoulder_Press": ["Overhead press", "OHP", "Shoulder press", "Strict press"],
        "Barbell_Hip_Thrust": ["Hip thrust"],
        "Handstand_Push-Ups": ["HSPU", "Handstand push-up"],
        "Muscle_Up": ["Ring muscle-up", "RMU", "MU"],
        "Ring_Dips": ["Ring dip"],
        "Rope_Climb": ["Rope climbs"],
        "Rope_Jumping": ["Single-under", "Singles", "Jump rope", "Skipping"],
        "Rowing_Stationary": ["Rowing erg", "Row erg", "Rower", "Concept2"],
        "Standing_Long_Jump": ["Broad jump"],
        "Side_Bridge": ["Side plank"],
        "Farmers_Walk": ["Farmer carry", "Farmers carry"],
        "Butt_Lift_Bridge": ["Glute bridge", "Hip bridge"],
        "Natural_Glute_Ham_Raise": ["Nordic curl", "Nordic hamstring curl", "Nordics"],
        "Inverted_Row": ["Australian pull-up", "Body row"],
        "Push-Ups_-_Close_Triceps_Position": ["Diamond push-up"],
        "Worlds_Greatest_Stretch": ["WGS"],
        "Childs_Pose": ["Child pose"],
        "Bodyweight_Squat": ["Air squat"],
        "Sit-Up": ["Situp", "Abmat sit-up"],
        "Overhead_Squat": ["OHS"],
        "Sled_Push": ["Prowler push"],
        "Dead_Bug": ["Deadbug"],
        // Loopr additions.
        "loopr-double-under": ["DU", "Doubles"],
        "loopr-toes-to-bar": ["T2B", "TTB"],
        "loopr-knees-to-elbows": ["K2E"],
        "loopr-chest-to-bar-pull-up": ["C2B", "Chest to bar"],
        "loopr-bar-muscle-up": ["BMU"],
        "loopr-kettlebell-swing": ["KB swing", "Russian kettlebell swing", "Russian swing"],
        "loopr-american-kettlebell-swing": ["American KB swing", "American swing"],
        "loopr-sumo-deadlift-high-pull": ["SDHP"],
        "loopr-wall-ball": ["Wall ball shot"],
        "loopr-box-jump-over": ["BJO"],
        "loopr-handstand-walk": ["HSW"],
        // Not "Air bike": the dataset uses that name for a crunch.
        "loopr-assault-bike": ["Echo bike", "Fan bike", "Airdyne"],
        "loopr-ski-erg": ["Skierg"],
        "loopr-hollow-hold": ["Hollow body hold"],
        "loopr-downward-dog": ["Downward-facing dog", "Down dog"],
        "loopr-thoracic-rotation": ["Open book"],
        "loopr-deep-squat-hold": ["Squat hold", "Deep squat"],
        "loopr-90-90-hip-switch": ["90/90"],
        "loopr-pigeon-pose": ["Pigeon stretch", "Pigeon"],
        "loopr-dumbbell-snatch": ["DB snatch"],
        "loopr-dumbbell-thruster": ["DB thruster"]
    ]

    /// Compact alias to the key it names. Built once from `byKey`.
    static let keyByCompactAlias: [String: String] = {
        var map: [String: String] = [:]
        for (key, aliases) in byKey.sorted(by: { $0.key < $1.key }) {
            for alias in aliases { map[ExerciseName.compact(alias)] = map[ExerciseName.compact(alias)] ?? key }
        }
        return map
    }()

    /// The key an alias names, or nil. "rdl" gives `Romanian_Deadlift`.
    public static func key(forAlias text: String) -> String? { keyByCompactAlias[ExerciseName.compact(text)] }
}

/// The names plans use for common lifts (R2-LIFT-07, R2-WOD-13). The bundled dataset calls the back squat
/// "Barbell Squat" and the pull-up "Pullups"; a template, a program and the live screen say "Back squat" and
/// "Pull-up". The library shows the plan name, and the dataset name stays searchable as an alias.
public enum ExerciseDisplayNames {
    public struct Renamed: Equatable, Sendable {
        /// What the picker, history and new template lines show.
        public let name: String
        /// The name in `exercises.v1.json`.
        public let dataset: String
    }

    public static let byKey: [String: Renamed] = [
        "Barbell_Squat": .init(name: "Back squat", dataset: "Barbell Squat"),
        "Barbell_Bench_Press_-_Medium_Grip": .init(name: "Bench press", dataset: "Barbell Bench Press - Medium Grip"),
        "Pullups": .init(name: "Pull-up", dataset: "Pullups"),
        "Bent_Over_Barbell_Row": .init(name: "Barbell row", dataset: "Bent Over Barbell Row"),
        "Romanian_Deadlift": .init(name: "Romanian deadlift", dataset: "Romanian Deadlift"),
        "Barbell_Deadlift": .init(name: "Deadlift", dataset: "Barbell Deadlift"),
        "Barbell_Shoulder_Press": .init(name: "Overhead press", dataset: "Barbell Shoulder Press"),
        "Pushups": .init(name: "Push-up", dataset: "Pushups"),
        "Chin-Up": .init(name: "Chin-up", dataset: "Chin-Up"),
        "Barbell_Hip_Thrust": .init(name: "Hip thrust", dataset: "Barbell Hip Thrust"),
        "Farmers_Walk": .init(name: "Farmer's walk", dataset: "Farmer's Walk"),
        "Front_Barbell_Squat": .init(name: "Front squat", dataset: "Front Barbell Squat"),
        "Dumbbell_Bicep_Curl": .init(name: "Dumbbell curl", dataset: "Dumbbell Bicep Curl"),
        "Seated_Cable_Rows": .init(name: "Seated cable row", dataset: "Seated Cable Rows"),
        "Wide-Grip_Lat_Pulldown": .init(name: "Lat pulldown", dataset: "Wide-Grip Lat Pulldown"),
        "Standing_Calf_Raises": .init(name: "Standing calf raise", dataset: "Standing Calf Raises"),
        "Lying_Leg_Curls": .init(name: "Lying leg curl", dataset: "Lying Leg Curls"),
        "Barbell_Walking_Lunge": .init(name: "Walking lunge", dataset: "Barbell Walking Lunge"),
        "Dumbbell_Lunges": .init(name: "Dumbbell lunge", dataset: "Dumbbell Lunges"),
        "Goblet_Squat": .init(name: "Goblet squat", dataset: "Goblet Squat"),
        "Leg_Press": .init(name: "Leg press", dataset: "Leg Press"),
        "Incline_Dumbbell_Press": .init(name: "Incline dumbbell press", dataset: "Incline Dumbbell Press"),
        "Side_Bridge": .init(name: "Side plank", dataset: "Side Bridge")
    ]

    /// Dataset names of the entries `ExerciseAliases.mergedKeys` folds into another key. They become aliases of it.
    static let mergedDatasetNames: [String: String] = ["Band_Assisted_Pull-Up": "Band Assisted Pull-Up"]

    /// The name the library shows for a dataset row.
    public static func name(forKey key: String, dataset: String) -> String { byKey[key]?.name ?? dataset }
}

/// Keys behind the picker's CrossFit chip and its Common list.
public enum ExerciseCollections {
    /// Movements a CrossFit class programs, from the bundled list and the Loopr additions.
    public static let crossFit: Set<String> = [
        "loopr-burpee", "loopr-bar-facing-burpee", "loopr-double-under", "loopr-toes-to-bar", "loopr-knees-to-elbows",
        "loopr-wall-ball", "loopr-box-jump-over", "loopr-ring-row", "loopr-bar-muscle-up", "loopr-kipping-pull-up",
        "loopr-chest-to-bar-pull-up", "loopr-handstand-hold", "loopr-handstand-walk", "loopr-wall-walk",
        "loopr-pistol-squat", "loopr-thruster", "loopr-dumbbell-thruster", "loopr-devil-press", "loopr-dumbbell-snatch",
        "loopr-push-jerk", "loopr-american-kettlebell-swing", "loopr-kettlebell-swing", "loopr-sumo-deadlift-high-pull",
        "loopr-ghd-sit-up", "loopr-assault-bike", "loopr-ski-erg", "loopr-l-sit", "loopr-hanging-knee-raise",
        "loopr-sandbag-carry", "loopr-overhead-carry", "loopr-front-rack-carry",
        "Pullups", "Pushups", "Muscle_Up", "Kipping_Muscle_Up", "Ring_Dips", "Rope_Climb", "Handstand_Push-Ups",
        "Rope_Jumping", "Rowing_Stationary", "Sled_Push", "Front_Box_Jump", "Box_Jump_Multiple_Response",
        "Bodyweight_Squat", "Sit-Up", "Power_Clean", "Hang_Clean", "Clean", "Clean_and_Jerk", "Power_Snatch",
        "Snatch", "Split_Jerk", "Push_Press", "Overhead_Squat", "Front_Squat_Clean_Grip", "Barbell_Deadlift",
        "Barbell_Squat", "Standing_Long_Jump", "Farmers_Walk", "Kettlebell_Turkish_Get-Up_Squat_style"
    ]

    /// What a gym starter reaches for, in this order. Shown before a search starts.
    public static let common: [String] = [
        "Barbell_Squat", "Barbell_Bench_Press_-_Medium_Grip", "Barbell_Deadlift", "Barbell_Shoulder_Press", "Pullups",
        "Pushups", "Bent_Over_Barbell_Row", "Romanian_Deadlift", "Goblet_Squat", "Dumbbell_Lunges", "Barbell_Hip_Thrust",
        "Wide-Grip_Lat_Pulldown", "Seated_Cable_Rows", "Dumbbell_Bicep_Curl", "Plank", "loopr-kettlebell-swing",
        "loopr-burpee", "loopr-knee-push-up", "Rowing_Stationary", "loopr-cat-cow"
    ]
}

/// The category chips above the exercise list. One is active at a time.
public enum ExercisePickerCategory: String, CaseIterable, Sendable, Identifiable {
    case strength, bodyweight, stretching, cardio, plyometrics, olympic, crossFit

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .strength: "Strength"
        case .bodyweight: "Bodyweight"
        case .stretching: "Stretching"
        case .cardio: "Cardio"
        case .plyometrics: "Plyometrics"
        case .olympic: "Olympic"
        case .crossFit: "CrossFit"
        }
    }

    public func matches(_ exercise: ExerciseDefinition) -> Bool {
        switch self {
        case .strength: [.strength, .powerlifting, .strongman].contains(exercise.categoryKind) && exercise.equipmentKind != .bodyOnly
        case .bodyweight: exercise.equipmentKind == .bodyOnly && exercise.categoryKind != .stretching
        case .stretching: exercise.categoryKind == .stretching
        case .cardio: exercise.categoryKind == .cardio
        case .plyometrics: exercise.categoryKind == .plyometrics
        case .olympic: exercise.categoryKind == .olympicWeightlifting
        case .crossFit: ExerciseCollections.crossFit.contains(exercise.key)
        }
    }
}
