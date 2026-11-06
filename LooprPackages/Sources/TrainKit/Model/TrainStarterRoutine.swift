import Foundation

/// The beginner's first gym workout (R3-NEW-01): four movements a new person can do in any gym, with no weights filled
/// in and no rules. The start sheet offers it until the person has a few workouts of their own; one tap saves it as
/// theirs and starts it, so it can be edited like any other.
public enum TrainStarterRoutine {
    public static let name = "Full body, beginner"
    public static let caption = "Goblet squat, dumbbell row, knee push-up, plank. No weights filled in."
    /// Offered while the person has fewer saved workouts than this.
    public static let offeredBelow = 3

    static let lines: [(key: String, name: String, measure: TrainSetMeasure, reps: Int, seconds: Int?)] = [
        ("Goblet_Squat", "Goblet squat", .weight, 10, nil),
        ("One-Arm_Dumbbell_Row", "One-arm dumbbell row", .weight, 10, nil),
        ("loopr-knee-push-up", "Knee push-up", .bodyweight, 8, nil),
        ("Plank", "Plank", .time, 0, 30)
    ]

    /// True when the sheet should offer it: not saved yet, and few workouts of the person's own.
    public static func isOffered(templateNames: [String]) -> Bool {
        templateNames.count < offeredBelow && !templateNames.contains(name)
    }

    public static func template(now: Date) -> WorkoutTemplate {
        WorkoutTemplate(name: name, exercises: lines.map { line in
            TemplateExercise(exercise: ExerciseRef(key: line.key, name: line.name), sets: 3,
                             repsMin: max(line.reps, 1), repsMax: max(line.reps, 1), measure: line.measure,
                             targetSeconds: line.seconds, restSeconds: 90)
        }, createdAt: now, updatedAt: now)
    }
}
