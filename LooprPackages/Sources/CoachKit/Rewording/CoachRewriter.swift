import Foundation

/// What a rewording came to. A reworded note passed every check. Anything else is the rule text with the reason.
public enum CoachRewordOutcome: Equatable, Sendable {
    case reworded(CoachNote)
    case rules(CoachNote, rejected: CoachRewordRejection)

    /// The note to show.
    public var note: CoachNote {
        switch self {
        case .reworded(let note), .rules(let note, _): note
        }
    }

    public var isReworded: Bool {
        if case .reworded = self { return true }
        return false
    }
}

/// Rewords a rule-written note for flow with a language model on this iPhone (DEC-12.12). The rule text is always the
/// fallback and no setting is needed: when the model is unavailable, fails, runs out of time, or answers with anything
/// the note does not support, the person sees the rule text. A rewording is shown only when every number in it is in the
/// note's number set and none is missing, no forbidden word, exclamation mark or dash is in it, the comparison keeps its
/// direction, every name is intact and the length stays within the limit.
///
/// Nothing leaves the phone. The model behind `CoachRewordingModel` is Apple's on-device model, and the rewriter has no
/// network code.
public struct CoachRewriter: Sendable {
    /// What the model is told. It is a request, not a guarantee: the validator holds the line.
    public static let instructions = """
        Reword the note you are given so it reads smoothly. Keep every number, name, day and comparison exactly as \
        written, in the same units and the same direction. Do not add a number or a fact. Say that nights differed, \
        never that one thing caused another. Do not give advice. Use sentence case, no exclamation marks and no dashes. \
        Answer with the reworded note only.
        """

    private let model: any CoachRewordingModel
    public let limits: CoachRewordLimits

    public init(model: any CoachRewordingModel, limits: CoachRewordLimits = .standard) {
        self.model = model; self.limits = limits
    }

    /// A rewriter on this device's own model: Apple's when it exists, and one that always keeps the rule text when not.
    public static func system(limits: CoachRewordLimits = .standard) -> CoachRewriter {
        CoachRewriter(model: systemCoachRewordingModel(), limits: limits)
    }

    public var isAvailable: Bool { model.isAvailable }

    /// Pattern lines are labels in a list. Morning, evening and weekly review notes are sentences.
    public static func isRewordable(_ kind: CoachNoteKind) -> Bool { kind != .patternLine }

    public func reword(_ note: CoachNote) async -> CoachRewordOutcome {
        guard Self.isRewordable(note.kind) else { return .rules(note, rejected: .notRewordable) }
        guard model.isAvailable else { return .rules(note, rejected: .modelUnavailable) }

        let answer: String
        switch await ask(note.text) {
        case .success(let text): answer = text
        case .failure(let rejection): return .rules(note, rejected: rejection)
        }
        switch CoachRewordValidator.validate(answer, for: note, limits: limits) {
        case .success(let reworded): return .reworded(reworded)
        case .failure(let rejection): return .rules(note, rejected: rejection)
        }
    }

    /// One request to the model with a time limit. The slower of the two tasks is cancelled.
    private func ask(_ text: String) async -> Result<String, CoachRewordRejection> {
        let model = model
        let timeout = limits.timeout
        return await withTaskGroup(of: Result<String, CoachRewordRejection>.self) { group in
            group.addTask {
                do { return .success(try await model.reword(text, instructions: Self.instructions)) } catch {
                    return .failure(Task.isCancelled ? .timedOut : .modelFailed)
                }
            }
            group.addTask {
                do { try await Task.sleep(for: timeout) } catch { return .failure(.timedOut) }
                return .failure(.timedOut)
            }
            let first = await group.next() ?? .failure(.modelFailed)
            group.cancelAll()
            return first
        }
    }
}
