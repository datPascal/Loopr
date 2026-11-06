import Combine
import Foundation

/// The observable owner of one live session. The pushed screen and the mini-player sheet both
/// read the same instance, so a set logged in one is there in the other.
///
/// The model it wraps is pure. This class adds what a screen needs: the load and reps the
/// person is editing, an error line, and one hook, `onChange`, the app uses to save progress,
/// schedule the rest cue and update the Live Activity.
@MainActor
public final class TrainLiveSession: ObservableObject {
    /// The values in the set controls. Reset from the prefill whenever the next set changes.
    public struct Draft: Equatable, Sendable {
        /// For a bodyweight set: no extra load, a load added, or assistance taken off.
        public enum BodyweightLoad: String, CaseIterable, Sendable { case none, added, assisted }

        /// The load, or for bodyweight the added load. 0 means none.
        public var loadKg: Double
        public var reps: Int
        public var seconds: Int
        public var metres: Double
        public var assistKg: Double
        public var bodyweightLoad: BodyweightLoad

        public init(loadKg: Double, reps: Int, seconds: Int = 0, metres: Double = 0, assistKg: Double = 0,
                    bodyweightLoad: BodyweightLoad = .none) {
            self.loadKg = loadKg; self.reps = reps; self.seconds = seconds; self.metres = metres
            self.assistKg = assistKg; self.bodyweightLoad = bodyweightLoad
        }

        /// The draft as values for a line of `measure`. A bodyweight draft keeps only the load its toggle picks.
        public func values(for measure: TrainSetMeasure) -> TrainSetValues {
            switch measure {
            case .weight: TrainSetValues(loadKg: loadKg, reps: reps)
            case .bodyweight:
                TrainSetValues(loadKg: bodyweightLoad == .added ? loadKg : nil, reps: reps,
                               assistKg: bodyweightLoad == .assisted ? assistKg : nil)
            case .time: TrainSetValues(loadKg: loadKg, reps: 0, seconds: seconds)
            case .distance: TrainSetValues(loadKg: loadKg, reps: 0, metres: metres)
            }
        }
    }

    @Published public private(set) var model: TrainLiveModel
    @Published public var draft: Draft
    @Published public private(set) var errorMessage: String?

    /// The one clock. Fixtures pass a frozen or offset clock.
    public let clock: @Sendable () -> Date
    /// Runs after every change to the model, on the main actor.
    public var onChange: (@MainActor @Sendable (TrainLiveModel) -> Void)?

    public init(model: TrainLiveModel, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.model = model
        self.clock = clock
        draft = Self.draft(for: model)
    }

    private static func draft(for model: TrainLiveModel) -> Draft {
        guard let prefill = model.currentPrefill else { return Draft(loadKg: 0, reps: 0) }
        let assist = prefill.assistKg ?? 0
        let load = prefill.loadKg ?? 0
        return Draft(loadKg: load, reps: prefill.reps, seconds: prefill.seconds ?? 0, metres: prefill.metres ?? 0,
                     assistKg: assist, bodyweightLoad: assist > 0 ? .assisted : load > 0 ? .added : .none)
    }

    public var now: Date { clock() }

    private func apply(resetDraft: Bool, _ change: (inout TrainLiveModel) throws -> Void) {
        var next = model
        do {
            try change(&next)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        model = next
        if resetDraft { draft = Self.draft(for: next) }
        onChange?(next)
    }

    public func clearError() { errorMessage = nil }

    // MARK: Sets

    /// The measure of the set about to be logged.
    public var currentMeasure: TrainSetMeasure { model.cursor.map { model.measure(ofExerciseAt: $0.exerciseIndex) } ?? .weight }

    /// Logs the next set with the controls' values.
    public func logSet(rpe: Double? = nil, tag: LoggedSet.Tag? = nil) {
        let values = draft.values(for: currentMeasure)
        let at = clock()
        apply(resetDraft: true) { try $0.logSet(values, rpe: rpe, tag: tag, now: at) }
    }

    public func setTag(_ tag: LoggedSet.Tag?, exerciseIndex: Int, setIndex: Int) {
        apply(resetDraft: true) { try $0.setTag(tag, exerciseIndex: exerciseIndex, setIndex: setIndex) }
    }

    public func setMeasure(_ measure: TrainSetMeasure, forExerciseAt index: Int) {
        apply(resetDraft: true) { try $0.setMeasure(measure, forExerciseAt: index) }
    }

    public func skipSet() {
        let at = clock()
        apply(resetDraft: true) { try $0.skipSet(now: at) }
    }

    public func skipExercise(at index: Int) { apply(resetDraft: true) { try $0.skipExercise(at: index) } }

    public func setRPE(_ rpe: Double?, exerciseIndex: Int, setIndex: Int) {
        apply(resetDraft: false) { try $0.setRPE(rpe, exerciseIndex: exerciseIndex, setIndex: setIndex) }
    }

    public func editSet(exerciseIndex: Int, setIndex: Int, loadKg: Double?, reps: Int, rpe: Double?) {
        apply(resetDraft: true) { try $0.editSet(exerciseIndex: exerciseIndex, setIndex: setIndex, loadKg: loadKg, reps: reps, rpe: rpe) }
    }

    public func editSet(exerciseIndex: Int, setIndex: Int, values: TrainSetValues, rpe: Double?) {
        apply(resetDraft: true) { try $0.editSet(exerciseIndex: exerciseIndex, setIndex: setIndex, values: values, rpe: rpe) }
    }

    public func swapExercise(at index: Int, with replacement: ExerciseDefinition) {
        apply(resetDraft: true) { try $0.swapExercise(at: index, with: replacement) }
    }

    public func focus(exerciseAt index: Int) { apply(resetDraft: true) { try $0.focus(exerciseAt: index) } }

    public func addExercise(_ definition: ExerciseDefinition) { apply(resetDraft: true) { try $0.addExercise(definition) } }
    public func addSet(toExerciseAt index: Int) { apply(resetDraft: true) { try $0.addSet(toExerciseAt: index) } }
    public func removeSet(exerciseIndex: Int, setIndex: Int) {
        apply(resetDraft: true) { try $0.removeSet(exerciseIndex: exerciseIndex, setIndex: setIndex) }
    }
    public func removeExercise(at index: Int) { apply(resetDraft: true) { try $0.removeExercise(at: index) } }

    // MARK: Rest

    public func extendRest() {
        let at = clock()
        apply(resetDraft: false) { $0.extendRest(now: at) }
    }

    public func endRest() { apply(resetDraft: false) { $0.clearRest() } }

    /// True once when the rest has just ended. The caller buzzes. See `RestTimer.claimCue`.
    public func claimRestCue() -> Bool {
        var next = model
        let at = clock()
        let claimed = next.claimRestCue(at: at)
        guard claimed || next != model else { return false }
        model = next
        onChange?(next)
        return claimed
    }

    // MARK: Finish

    /// Closes the model and returns the finished session. Throws when the session does not validate.
    @discardableResult
    public func finish() throws -> TrainSession {
        var next = model
        let finished = try next.finish(now: clock())
        model = next
        errorMessage = nil
        onChange?(next)
        return finished
    }

    public func recordSaved(revision: Int) {
        var next = model
        next.recordSaved(revision: revision)
        model = next
    }
}
