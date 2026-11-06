import Foundation

/// The decisions the scheduler made for one program that nobody has saved yet.
public struct PendingProgramAdjustments: Equatable, Sendable {
    public let programID: UUID
    public let adjustments: [ProgramAdjustment]

    public init(programID: UUID, adjustments: [ProgramAdjustment]) { self.programID = programID; self.adjustments = adjustments }
}

/// Collects the rule decisions the scheduler makes when it plans the current week, and merges
/// them into a program so they are saved once. Pure value logic.
///
/// `ProgramScheduler` returns light-week decisions and moved sessions as `newAdjustments` and
/// expects the caller to save them. Without that, the early light week rule would decide again on
/// every launch, from whatever recovery data happened to be there that day.
public enum ProgramAdjustmentPlanner {
    /// Plans the week of every active program that contains today and returns the new decisions.
    /// Programs with nothing new are left out.
    public static func pending(input: TrainOverviewInput) -> [PendingProgramAdjustments] {
        let scheduler = ProgramScheduler(calendar: input.calendar)
        let today = scheduler.localDay(for: input.now)
        let cardio = Set(input.templates.filter { $0.kind == .cardio }.map(\.id))
        let context = ProgramScheduler.Context(
            now: input.now, recovery: input.recovery, completed: CompletedSession.completed(in: input.sessions),
            lightExemptTemplateIDs: cardio)
        var result: [PendingProgramAdjustments] = []
        for program in input.programs where program.status == .active {
            guard let week = scheduler.week(containing: today, in: program) else { continue }
            let plan = scheduler.evaluate(program: program, week: week, context: context)
            let fresh = plan.newAdjustments.filter { !contains(program.adjustments, $0) }
            if !fresh.isEmpty { result.append(PendingProgramAdjustments(programID: program.id, adjustments: fresh)) }
        }
        return result
    }

    /// The program with the new decisions added, or nil when it already holds every one. A decision
    /// counts as held when the program has one of the same kind for the same week and day.
    public static func merge(_ adjustments: [ProgramAdjustment], into program: Program) -> Program? {
        var merged = program
        for adjustment in adjustments where !contains(merged.adjustments, adjustment) {
            merged.adjustments.append(adjustment)
        }
        return merged.adjustments.count == program.adjustments.count ? nil : merged
    }

    private static func contains(_ held: [ProgramAdjustment], _ adjustment: ProgramAdjustment) -> Bool {
        held.contains {
            $0.kind == adjustment.kind && $0.week == adjustment.week && $0.weekday == adjustment.weekday
                && $0.movedToWeekday == adjustment.movedToWeekday
        }
    }
}
