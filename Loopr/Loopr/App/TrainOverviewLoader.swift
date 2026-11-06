import Combine
import Foundation
import TrainKit
import WorkoutKit

/// Loads what the Train overview reads and keeps the one swap the person made today.
///
/// Storage reads run in `AppTrainRepository`, an actor, so the main thread only builds the
/// overview from plain values. The overview is rebuilt on every load, so a template saved in the
/// builder shows when the person comes back to Train.
@MainActor
final class TrainOverviewLoader: ObservableObject {
    @Published private(set) var overview: TrainOverview?
    @Published private(set) var failure: String?
    private(set) var input: TrainOverviewInput?
    private var generation = 0
    private var swapped: (day: String, templateID: UUID)?

    private let repository: AppTrainRepository
    private let workouts: any WorkoutStore

    init(repository: AppTrainRepository, workouts: any WorkoutStore) {
        self.repository = repository
        self.workouts = workouts
    }

    /// Reads templates, programs, finished sessions, recovery and strain, then rebuilds the overview.
    /// A load that a newer load overtook is dropped.
    /// - Parameter dailyZone2: the protocol's every-day Zone 2 rule, which the week and today's card show beside the
    ///   program (R3-OPT-6).
    func load(now: Date, calendar: Calendar, history: any MetricHistoryProviding, dailyZone2: TrainDailyZone2? = nil) async {
        generation += 1
        let token = generation
        do {
            async let templates = repository.templates()
            async let programs = repository.programs()
            async let sessions = repository.recentSessions(limit: 200, status: .completed)
            let readings = await TrainRecoveryProvider(history: history).readings(endingOn: now, calendar: calendar)
            let loadedTemplates = try await templates
            let loadedSessions = try await sessions
            let loadedPrograms = try await programs
            var next = TrainOverviewInput(
                now: now, calendar: calendar, templates: loadedTemplates, programs: loadedPrograms,
                sessions: loadedSessions, recovery: readings, dailyZone2: dailyZone2)
            await recordAdjustments(in: &next)
            let day = ProgramScheduler(calendar: calendar).localDay(for: now)
            next.swappedTemplateID = swapped.flatMap { $0.day == day ? $0.templateID : nil }
            // Expected strain needs the workout records of the template on today's card.
            if let templateID = TrainOverviewModel(next).overview.todayTemplateID {
                next.strainSamples = await strainSamples(for: templateID, sessions: next.sessions)
            }
            guard token == generation else { return }
            input = next
            failure = nil
            overview = TrainOverviewModel(next).overview
        } catch is CancellationError {
            return
        } catch {
            guard token == generation else { return }
            failure = "Saved templates and programs could not load. Close Fitness and open it again."
            if overview == nil { overview = TrainOverviewModel(TrainOverviewInput(now: now, calendar: calendar)).overview }
        }
    }

    /// Saves what the scheduler decided for the current week, then reads the programs again so the
    /// recorded decisions are what the overview plans from. Saving fails quietly: the week is then
    /// decided again on the next load, from the same inputs.
    private func recordAdjustments(in input: inout TrainOverviewInput) async {
        let pending = ProgramAdjustmentPlanner.pending(input: input)
        guard !pending.isEmpty else { return }
        guard (try? await repository.recordAdjustments(pending, at: input.now)) == true,
              let refreshed = try? await repository.programs() else { return }
        input.programs = refreshed
    }

    /// Plans the programs again from what was last loaded and saves any new decision. A session start
    /// calls this, so the decision is on record before the person trains.
    /// Saves a workout the tab offers, such as the beginner's starter. Returns the stored copy.
    func saveTemplate(_ template: WorkoutTemplate, at date: Date) async throws -> WorkoutTemplate {
        try await repository.saveTemplate(template, at: date)
    }

    func recordProgramAdjustments() async {
        guard var current = input else { return }
        await recordAdjustments(in: &current)
        input = current
    }

    /// Saves an agent draft as an active program, then reloads. Returns a sentence when it could not be saved.
    func accept(_ draft: TrainDraftSummary, now: Date, calendar: Calendar, history: any MetricHistoryProviding) async -> String? {
        do {
            _ = try await repository.acceptDraft(id: draft.id, expectedRevision: draft.revision, at: now)
            await load(now: now, calendar: calendar, history: history)
            return nil
        } catch {
            await load(now: now, calendar: calendar, history: history)
            return error.localizedDescription
        }
    }

    /// Deletes an agent draft and the templates it carried, then reloads.
    func discard(_ draft: TrainDraftSummary, now: Date, calendar: Calendar, history: any MetricHistoryProviding) async -> String? {
        do {
            try await repository.discardDraft(id: draft.id, expectedRevision: draft.revision)
            await load(now: now, calendar: calendar, history: history)
            return nil
        } catch {
            await load(now: now, calendar: calendar, history: history)
            return error.localizedDescription
        }
    }

    /// Shows `templateID` in place of today's plan, or the plan again when nil. Not saved.
    func swap(to templateID: UUID?) {
        guard var current = input else { return }
        let day = ProgramScheduler(calendar: current.calendar).localDay(for: current.now)
        swapped = templateID.map { (day, $0) }
        current.swappedTemplateID = templateID
        input = current
        overview = TrainOverviewModel(current).overview
    }

    /// Strain of the template's last three sessions, from their linked workout records.
    private func strainSamples(for templateID: UUID, sessions: [TrainSession]) async -> [ExpectedStrain.Sample] {
        let recent = sessions.filter { $0.templateID == templateID && $0.status == .completed }
            .sorted { ($0.endedAt ?? $0.startedAt) > ($1.endedAt ?? $1.startedAt) }
            .prefix(ExpectedStrain.sessionCount)
        var samples: [ExpectedStrain.Sample] = []
        for session in recent {
            guard let workoutID = session.workoutID, let record = await workouts.workout(id: workoutID) else { continue }
            let strain = record.samples.reversed().compactMap(\.strain).first ?? record.importedSummary?.strain
            samples.append(.init(templateID: templateID, endedAt: session.endedAt ?? session.startedAt, strain: strain))
        }
        return samples
    }
}
