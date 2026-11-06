import Foundation

/// Destinations the Train tab pushes. The app wraps this in `AppWorkoutRoute.train`.
public enum TrainRoute: Hashable, Sendable {
    /// The template builder. Nil starts a new template.
    case template(UUID?)
    case program(UUID)
    /// The program editor. Nil starts a new program.
    case programEditor(UUID?)
    /// The live strength session in progress.
    case live
    /// The summary of a finished session.
    case summary(UUID)
    /// The exercise library picker, pushed from the template builder.
    case libraryPicker
    /// Every exercise the person has logged.
    case exercises
    /// One exercise's bests and history, by exercise key.
    case exercise(String)
    /// Hard sets per muscle group this week.
    case muscleVolume
    /// A gym session already done, entered set by set (R2-LIFT-05).
    case pastSession
}
