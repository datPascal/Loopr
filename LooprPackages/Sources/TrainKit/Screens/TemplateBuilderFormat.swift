import Foundation

/// Text the template builder shows for exercises and rules. Pure functions so the
/// wording is tested without a view. Loads are kilograms until the app has a unit setting.
public enum TemplateBuilderFormat {
    /// "6" when the range is a single value, otherwise "6–8".
    public static func reps(min: Int, max: Int) -> String {
        min == max ? "\(min)" : "\(min)–\(max)"
    }

    /// A kilogram value without trailing zeros: 80 shows "80" and 2.5 shows "2.5".
    public static func kilograms(_ value: Double, locale: Locale = .current) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)).locale(locale))
    }

    /// Rest as minutes and seconds: 150 shows "2:30".
    public static func rest(seconds: Int) -> String {
        let clamped = max(seconds, 0)
        return "\(clamped / 60):" + String(format: "%02d", clamped % 60)
    }

    /// Sets, target and load with no rest, for the mono line of an exercise row: "4 × 6–8 · 80 kg",
    /// "4 × 6–8 · 20 kg assist", "3 × 0:45" or "3 × 40 m · 32 kg". A weighted exercise with no load set
    /// shows only sets and reps.
    public static func spec(_ line: TemplateExercise, locale: Locale = .current) -> String {
        let load = line.loadKg.flatMap { $0 > 0 ? " · \(kilograms($0, locale: locale)) kg" : nil } ?? ""
        switch line.measure {
        case .weight:
            return "\(line.sets) × \(reps(min: line.repsMin, max: line.repsMax))" + load
        case .bodyweight:
            return "\(line.sets) × \(reps(min: line.repsMin, max: line.repsMax)) · "
                + TrainSetFormat.bodyweight(addedKg: line.loadKg, assistKg: line.assistKg)
        case .time:
            return "\(line.sets) × \(TrainSetFormat.seconds(line.plannedSeconds))" + load
        case .distance:
            return "\(line.sets) × \(TrainSetFormat.metres(line.plannedMetres))" + load
        }
    }

    /// The rest an exercise row shows, or nil when the exercise has no rest.
    public static func restText(_ line: TemplateExercise) -> String? {
        line.restSeconds > 0 ? rest(seconds: line.restSeconds) : nil
    }

    /// What VoiceOver reads for an exercise row.
    public static func spokenLabel(_ line: TemplateExercise, includeRest: Bool = true, locale: Locale = .current) -> String {
        let target: String = switch line.measure {
        case .weight, .bodyweight: spokenReps(line)
        case .time: LooprSpokenSeconds.text(line.plannedSeconds)
        case .distance: "\(kilograms(line.plannedMetres, locale: locale)) metres"
        }
        var parts = ["\(line.exercise.name)", "\(line.sets) \(line.sets == 1 ? "set" : "sets") of \(target)"]
        if line.measure == .bodyweight {
            if let assist = line.assistKg, assist > 0 { parts.append("assisted by \(kilograms(assist, locale: locale)) kilograms") }
            else if let load = line.loadKg, load > 0 { parts.append("bodyweight plus \(kilograms(load, locale: locale)) kilograms") }
            else { parts.append("bodyweight") }
        } else if let load = line.loadKg, load > 0 {
            parts.append("at \(kilograms(load, locale: locale)) kilograms")
        }
        if includeRest, line.restSeconds > 0 { parts.append("rest \(spokenDuration(line.restSeconds))") }
        return parts.joined(separator: ", ")
    }

    private static func spokenReps(_ line: TemplateExercise) -> String {
        if line.repsMin == line.repsMax { return "\(line.repsMin) \(line.repsMin == 1 ? "rep" : "reps")" }
        return "\(line.repsMin) to \(line.repsMax) reps"
    }

    private static func spokenDuration(_ seconds: Int) -> String {
        let minutes = seconds / 60, rest = seconds % 60
        var parts: [String] = []
        if minutes > 0 { parts.append("\(minutes) \(minutes == 1 ? "minute" : "minutes")") }
        if rest > 0 { parts.append("\(rest) \(rest == 1 ? "second" : "seconds")") }
        return parts.joined(separator: " ")
    }

    /// The line under the EXERCISES header: "6 exercises, about 55 min".
    public static func exerciseSummary(_ summary: TemplateSummary) -> String {
        guard summary.exerciseCount > 0 else { return "No exercises yet" }
        let noun = summary.exerciseCount == 1 ? "exercise" : "exercises"
        return "\(summary.exerciseCount) \(noun), about \(summary.estimatedMinutes) min"
    }

    public static func progressionTitle(_ rule: ProgressionRule) -> String {
        switch rule {
        case .none: "None"
        case .doubleProgression: "Double progression"
        case .linear: "Linear"
        }
    }

    /// The Progression row subtitle.
    public static func progressionSummary(_ rule: ProgressionRule, locale: Locale = .current) -> String {
        switch rule {
        case .none:
            "No automatic increase. You choose each load."
        case .doubleProgression(let increment):
            "Add \(kilograms(increment, locale: locale)) kg when every set reaches the top of the range"
        case .linear(let increment):
            "Add \(kilograms(increment, locale: locale)) kg after each session where every set hits its planned reps"
        }
    }

    /// The Adjust to recovery subtitle: "One set fewer per lift below 34".
    public static func recoverySummary(_ rule: RecoveryRule) -> String {
        let amount = rule.setsRemoved == 1 ? "One set" : "\(rule.setsRemoved) sets"
        return "\(amount) fewer per lift below \(rule.belowScore)"
    }

    /// A dataset name for display: "lower back" shows "Lower back".
    public static func capitalized(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }
}

extension ExerciseEquipment {
    /// Equipment as shown in the picker: "body only" shows "Body only".
    public var displayName: String { TemplateBuilderFormat.capitalized(rawValue) }
}
