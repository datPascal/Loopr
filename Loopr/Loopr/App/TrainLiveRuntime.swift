import Combine
import Foundation
import TrainKit
import UIKit
import WorkoutKit

/// What the live strength session needs from the rest of the app. The shell builds one per start.
struct TrainLiveEnvironment {
    let repository: AppTrainRepository
    let workoutSession: WorkoutSessionController?
    /// The band, for the rest-end buzz. Nil in fixtures and when no band is paired.
    let bandRuntime: (any LooprDeviceCenterRuntime)?
    /// False when the band cannot buzz, so the rest card does not promise it.
    let bandCueAvailable: Bool
    /// The one clock for the session. A fixture pins the day and lets time run from there.
    let clock: @Sendable () -> Date
    /// Replaces every rest. Set by a UI test fixture, nil in production.
    let restSecondsOverride: Int?
    let timeZoneIdentifier: String
}

/// The end of a rest, on the phone and on the band: a haptic, then one short band buzz.
struct TrainRestCue: Sendable {
    let delivery: BandCueDelivery
    let sessionID: UUID
    let haptic: @MainActor @Sendable () -> Void
    let queue: BandCueCommandQueue

    init(delivery: BandCueDelivery, sessionID: UUID, queue: BandCueCommandQueue = .shared,
         haptic: @escaping @MainActor @Sendable () -> Void = { UINotificationFeedbackGenerator().notificationOccurred(.warning) }) {
        self.delivery = delivery; self.sessionID = sessionID; self.queue = queue; self.haptic = haptic
    }

    @MainActor
    func deliver(band: Bool) async {
        haptic()
        guard band else { return }
        await delivery.send(pattern: [BandCuePattern.restEnd], sessionID: sessionID, queue: queue)
    }
}

/// Fires the rest cue once, when the rest timer's end date passes.
///
/// It waits on the end date, not on a count of seconds, so a rest that grows by 30 seconds is
/// rescheduled and a rest that ended while the app slept is answered the moment the app is
/// active again (`fireIfDue`). The session's cue claim makes every route to the same end date
/// fire at most once.
@MainActor
final class TrainRestCueScheduler {
    typealias Sleep = @Sendable (TimeInterval) async -> Void

    private let session: TrainLiveSession
    private let deliver: @MainActor @Sendable (_ band: Bool) async -> Void
    private let sleep: Sleep
    private var task: Task<Void, Never>?
    private var scheduledFor: Date?
    private var firing = false

    init(session: TrainLiveSession, sleep: @escaping Sleep = { seconds in _ = try? await Task.sleep(for: .seconds(seconds)) },
         deliver: @escaping @MainActor @Sendable (_ band: Bool) async -> Void) {
        self.session = session; self.sleep = sleep; self.deliver = deliver
    }

    /// Call after every change to the model.
    func update() {
        guard let rest = session.model.rest else { cancelPending(); return }
        // Claimed means the cue is being delivered or was delivered. Leave it alone.
        if rest.cueClaimed { return }
        if scheduledFor == rest.endsAt { return }
        cancelPending()
        scheduledFor = rest.endsAt
        let wait = max(0, rest.endsAt.timeIntervalSince(session.now))
        task = Task { [weak self, sleep] in
            await sleep(wait)
            guard !Task.isCancelled else { return }
            await self?.fireIfDue()
        }
    }

    /// Delivers the cue if the rest has ended, a recent end only, and nobody has claimed it yet.
    func fireIfDue() async {
        guard session.claimRestCue() else { return }
        firing = true
        defer { firing = false }
        await deliver(session.model.bandRestCue)
    }

    func cancel() {
        task?.cancel(); task = nil; scheduledFor = nil
    }

    /// Resolves when a scheduled cue has been delivered. For tests.
    func waitUntilIdle() async { await task?.value }

    private func cancelPending() {
        guard !firing else { return }
        task?.cancel(); task = nil; scheduledFor = nil
    }
}

/// Owns the live strength session from start to summary: the session object the screens read, the
/// rest cue, progress saves, and the Live Activity text. The workout recording underneath stays
/// the app's normal workout path, so this class never touches heart rate or strain.
@MainActor
final class TrainLiveRuntime: ObservableObject {
    @Published private(set) var session: TrainLiveSession?
    private(set) var workoutID: UUID?
    /// True from the first finish attempt until `end()`, so the workout leaving "active" is not read as an abandon.
    private(set) var isFinishing = false
    private(set) var bandCueAvailable = true
    private var environment: TrainLiveEnvironment?
    private var scheduler: TrainRestCueScheduler?
    private var saveChain: Task<Void, Never>?
    private var savedRevision = 0
    private var finalSession: TrainSession?
    private var lastOverlay: TrainActivityOverlay?

    var hasSession: Bool { session != nil }

    // MARK: Start and resume

    /// The clock for a live session. A fixture pins the day to the fixture day and lets time run from there.
    nonisolated static func makeClock(fixtureStart: Date?) -> @Sendable () -> Date {
        guard let fixtureStart else { return { Date() } }
        let anchor = Date()
        return { fixtureStart.addingTimeInterval(Date().timeIntervalSince(anchor)) }
    }

    /// Builds the model, starts the cue scheduler and begins saving progress.
    func begin(setup: TrainLiveSetup, environment: TrainLiveEnvironment) throws {
        var setup = setup
        setup.restSecondsOverride = environment.restSecondsOverride
        setup.timeZoneIdentifier = environment.timeZoneIdentifier
        let model = try TrainLiveModel(setup: setup, now: environment.clock())
        attach(TrainLiveSession(model: model, clock: environment.clock), workoutID: setup.workoutID, environment: environment)
        // The first checkpoint, so a session closed right away is still found.
        if let session { enqueueCheckpoint(session.model.session) }
    }

    /// Resumes an active session whose workout is still recording, after a relaunch. Returns false when there is none.
    @discardableResult
    func resumeIfNeeded(for workout: WorkoutRecord, environment: TrainLiveEnvironment,
                        swapPool: @Sendable () async -> [ExerciseDefinition]) async -> Bool {
        guard session == nil, workout.activity == .strength, workout.source == .live else { return false }
        do {
            guard let stored = try await environment.repository.session(workoutID: workout.id), stored.status == .active else { return false }
            var template: WorkoutTemplate?
            if let templateID = stored.templateID { template = try await environment.repository.template(id: templateID) }
            let history = try await environment.repository.recentSessions(limit: 200, status: .completed)
            guard session == nil else { return false }
            let pool = await swapPool()
            let model = try TrainLiveModel(resuming: stored, template: template, history: history, swapPool: pool)
            savedRevision = stored.revision
            attach(TrainLiveSession(model: model, clock: environment.clock), workoutID: workout.id, environment: environment)
            return true
        } catch {
            return false
        }
    }

    private func attach(_ live: TrainLiveSession, workoutID: UUID?, environment: TrainLiveEnvironment) {
        scheduler?.cancel()
        self.environment = environment
        self.workoutID = workoutID
        bandCueAvailable = environment.bandCueAvailable
        isFinishing = false
        finalSession = nil
        lastOverlay = nil
        let cue = TrainRestCue(delivery: BandCueDelivery(runtime: environment.bandRuntime), sessionID: live.model.session.id)
        let scheduler = TrainRestCueScheduler(session: live) { @MainActor @Sendable band in await cue.deliver(band: band) }
        self.scheduler = scheduler
        live.onChange = { @MainActor @Sendable [weak self] model in self?.modelChanged(model) }
        session = live
        scheduler.update()
        publishActivity(for: live.model)
    }

    // MARK: Changes

    private func modelChanged(_ model: TrainLiveModel) {
        scheduler?.update()
        guard !model.isFinished else { return }
        enqueueCheckpoint(model.session)
        publishActivity(for: model)
    }

    /// Saves the in-progress session, one write at a time, so a relaunch can pick it up. Best effort: the
    /// save at finish is the one that reports errors.
    private func enqueueCheckpoint(_ snapshot: TrainSession) {
        guard let repository = environment?.repository else { return }
        let previous = saveChain
        saveChain = Task { [weak self] in
            await previous?.value
            guard let self, !self.isFinishing else { return }
            var toSave = snapshot
            toSave.revision = self.savedRevision
            if let saved = try? await repository.saveSession(toSave) { self.savedRevision = saved.revision }
        }
    }

    /// The text the Live Activity adds: the next set and, during a rest, when it ends.
    static func overlay(for model: TrainLiveModel, now: Date) -> TrainActivityOverlay {
        let summary: String
        if let cursor = model.cursor {
            let line = model.session.exercises[cursor.exerciseIndex]
            summary = "\(line.exercise.name) · set \(cursor.setIndex + 1) of \(line.planned.sets)"
        } else {
            summary = "All sets logged"
        }
        let end = model.rest.flatMap { $0.isExpired(at: now) ? nil : $0.endsAt }
        return TrainActivityOverlay(restEndsAt: end, setSummary: summary)
    }

    private func publishActivity(for model: TrainLiveModel) {
        guard let workoutID, let live = session, let workoutSession = environment?.workoutSession else { return }
        let overlay = Self.overlay(for: model, now: live.now)
        guard overlay != lastOverlay else { return }
        lastOverlay = overlay
        Task {
            guard let workout = await workoutSession.workout(id: workoutID) else { return }
            await LooprLiveActivityRuntime.shared.updateTrainOverlay(overlay, workout: workout)
        }
    }

    /// Call when the app becomes active. A rest that ended while the app slept still buzzes if it ended just now.
    func sceneBecameActive() {
        guard let scheduler else { return }
        Task { await scheduler.fireIfDue() }
        scheduler.update()
    }

    /// Resolves when every queued progress save has finished. For tests.
    func waitForCheckpoint() async { await saveChain?.value }

    // MARK: Finish

    /// Closes the session, saves it, then finishes the workout. The session is saved first, so a failure
    /// finishing the workout leaves the log safe and a second attempt skips the save. The caller moves
    /// to the summary and then calls `end()`.
    func finish(finishWorkout: @MainActor () async throws -> Void) async throws -> TrainSession {
        guard let live = session, let repository = environment?.repository else { throw TrainLiveError.noOpenSet }
        isFinishing = true
        scheduler?.cancel()
        await saveChain?.value
        let completed: TrainSession
        if let finalSession {
            completed = finalSession
        } else {
            do {
                var closed = try live.finish()
                closed.revision = savedRevision
                completed = try await repository.saveSession(closed)
            } catch {
                // Nothing is saved yet, so a later attempt starts clean.
                isFinishing = false
                throw error
            }
            finalSession = completed
            savedRevision = completed.revision
            live.recordSaved(revision: completed.revision)
        }
        try await finishWorkout()
        return completed
    }

    /// Clears the session after the summary is on screen.
    func end() {
        scheduler?.cancel()
        scheduler = nil
        session?.onChange = nil
        session = nil
        workoutID = nil
        environment = nil
        isFinishing = false
        finalSession = nil
        lastOverlay = nil
        savedRevision = 0
    }

    /// The workout ended without Finish, for example a discard. The session stays in the log as abandoned.
    func abandon() async {
        guard let live = session, let repository = environment?.repository, !isFinishing else { return }
        scheduler?.cancel()
        await saveChain?.value
        var closed = live.model.session
        closed.status = .abandoned
        closed.endedAt = max(live.now, closed.startedAt)
        closed.revision = savedRevision
        _ = try? await repository.saveSession(closed)
        end()
    }

    // MARK: Library

    /// The bundled library and the person's custom exercises, as the pool a swap draws from.
    nonisolated static func loadSwapPool(repository: AppTrainRepository) async -> [ExerciseDefinition] {
        let bundled = try? await Task.detached(priority: .userInitiated) { try TrainTemplateRoot.loadBundledLibrary() }.value
        let custom = (try? await repository.customExercises()) ?? []
        guard let bundled else { return custom }
        return ((try? bundled.merged(withCustom: custom)) ?? bundled).all
    }
}
