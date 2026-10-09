import ActivityKit
import AnalyticsKit
import Foundation
import OSLog
import SettingsKit
import SharedSurfaceKit
import StressKit
import WatchConnectivity
import WidgetKit
import WorkoutKit

actor LooprLiveActivityRuntime {
    static let shared = LooprLiveActivityRuntime()
    private let logger = Logger(subsystem: "com.loopr.ios", category: "LiveActivity")
    /// Set by the production composition. Fixture and test compositions leave
    /// it nil and keep today's behaviour; only the production path can turn
    /// the Live Activity off from Settings.
    private var privacy: (any LooprSurfacePrivacyReading)?
    private var lastPublishedAt: [UUID: Date] = [:]
    private var zonesByWorkout: [UUID: HeartRateZoneSet] = [:]
    private var freshnessSampleAt: Date?
    private var freshnessWorkoutID: UUID?
    private var freshnessTask: Task<Void, Never>?
    private var pendingSynchronization: Task<Void, Never>?
    private var endedWorkoutIDs: Set<UUID> = []

    func setPrivacyReader(_ reader: any LooprSurfacePrivacyReading) {
        privacy = reader
    }

    func allowsLiveActivities() async -> Bool { await isAllowed() }

    private func isAllowed() async -> Bool {
        guard let privacy else { return true }
        return await privacy.currentSurfacePrivacy().liveActivity
    }

    func synchronize(_ workout: WorkoutRecord, zones: HeartRateZoneSet? = nil) async {
        let predecessor = pendingSynchronization
        let operation = Task {
            await predecessor?.value
            await performSynchronization(workout, zones: zones)
        }
        pendingSynchronization = operation
        await operation.value
    }

    private func performSynchronization(_ workout: WorkoutRecord, zones: HeartRateZoneSet?) async {
        let now = Date()
        let allowed = await isAllowed()
        let session = LooprActivityLifecycle.session(for: workout, allowed: allowed)
        if workout.state == .completed || workout.state == .discarded
            || (workout.state == .finishing && workout.endedAt != nil) {
            endedWorkoutIDs.insert(workout.id)
        } else if case .running = session, endedWorkoutIDs.contains(workout.id) {
            return
        }
        if let zones { zonesByWorkout[workout.id] = zones }
        let activities = Activity<LooprWorkoutActivityAttributes>.activities
        let decision = LooprActivityLifecycle.decide(
            existing: activities.map { activity in
                .init(id: activity.id, sessionID: activity.attributes.sessionID,
                      isStale: (activity.content.staleDate ?? .distantFuture) <= now)
            }, session: session
        )
        let state = LooprWorkoutActivityProjection.state(
            for: workout, zones: zonesByWorkout[workout.id], now: now
        )
        switch session {
        case .running: break
        default:
            if freshnessWorkoutID == workout.id { clearHeartRateExpiry() }
        }
        for end in decision.ends {
            guard let activity = activities.first(where: { $0.id == end.id }) else { continue }
            let finalContent: ActivityContent<LooprWorkoutActivityAttributes.ContentState>?
            if end.reason == .finished {
                finalContent = ActivityContent(state: state, staleDate: nil)
            } else {
                finalContent = ActivityContent(state: .init(
                    elapsedSeconds: activity.content.state.elapsedSeconds,
                    heartRate: nil, status: end.reason == .stale ? "Stopped updating" : "Ended",
                    startedAt: activity.content.state.startedAt,
                    heartRateObservedAt: nil, zone: nil,
                    distanceMeters: activity.content.state.distanceMeters,
                    paceSecondsPerKilometer: activity.content.state.paceSecondsPerKilometer
                ), staleDate: nil)
            }
            await activity.end(finalContent, dismissalPolicy: end.reason == .finished
                ? .after(now.addingTimeInterval(3 * 60)) : .immediate)
            lastPublishedAt.removeValue(forKey: activity.attributes.sessionID)
        }
        guard case .running = session else {
            zonesByWorkout.removeValue(forKey: workout.id)
            return
        }
        let content = ActivityContent(state: state, staleDate: now.addingTimeInterval(90))
        if let id = decision.updateID, let activity = activities.first(where: { $0.id == id }) {
            let previous = activity.content.state
            let last = lastPublishedAt[workout.id] ?? .distantPast
            guard Self.shouldPublish(previous: previous, next: state,
                                     elapsedSinceUpdate: now.timeIntervalSince(last)) else { return }
            await activity.update(content)
            lastPublishedAt[workout.id] = now
            scheduleHeartRateExpiry(workoutID: workout.id, observedAt: state.heartRateObservedAt)
            return
        }
        guard decision.shouldStart else { return }

        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            logger.notice("Workout Live Activity is disabled by system authorization")
            return
        }
        do {
            _ = try Activity.request(
                attributes: LooprWorkoutActivityAttributes(
                    sessionID: workout.id,
                    activityName: workout.activity.displayName
                ),
                content: content,
                pushType: nil
            )
            lastPublishedAt[workout.id] = now
            scheduleHeartRateExpiry(workoutID: workout.id, observedAt: state.heartRateObservedAt)
        } catch {
            logger.error("Could not start workout Live Activity: \(String(describing: error), privacy: .public)")
        }
    }

    func recover(canonicalWorkout: WorkoutRecord?) async {
        if let canonicalWorkout {
            await synchronize(canonicalWorkout)
        } else {
            await pendingSynchronization?.value
            await endAll()
        }
    }

    func endAll() async {
        clearHeartRateExpiry()
        for activity in Activity<LooprWorkoutActivityAttributes>.activities {
            let old = activity.content.state
            let final = LooprWorkoutActivityAttributes.ContentState(
                elapsedSeconds: old.elapsedSeconds, heartRate: nil, status: "Ended",
                startedAt: old.startedAt, heartRateObservedAt: nil, zone: nil,
                distanceMeters: old.distanceMeters, paceSecondsPerKilometer: old.paceSecondsPerKilometer
            )
            await activity.end(ActivityContent(state: final, staleDate: nil), dismissalPolicy: .immediate)
        }
        lastPublishedAt.removeAll()
        zonesByWorkout.removeAll()
    }

    private func scheduleHeartRateExpiry(workoutID: UUID, observedAt: Date?) {
        guard let observedAt else {
            if freshnessWorkoutID == workoutID { clearHeartRateExpiry() }
            return
        }
        guard freshnessSampleAt != observedAt || freshnessWorkoutID != workoutID else { return }
        freshnessTask?.cancel()
        freshnessSampleAt = observedAt
        freshnessWorkoutID = workoutID
        freshnessTask = Task { [weak self] in
            let remaining = max(0, observedAt.addingTimeInterval(
                WorkoutLiveMetrics.heartRateFreshness + 0.01
            ).timeIntervalSinceNow)
            try? await Task.sleep(for: .seconds(remaining))
            guard !Task.isCancelled else { return }
            await self?.expireHeartRate(workoutID: workoutID, observedAt: observedAt)
        }
    }

    private func expireHeartRate(workoutID: UUID, observedAt: Date) async {
        let predecessor = pendingSynchronization
        let operation = Task {
            await predecessor?.value
            await performHeartRateExpiry(workoutID: workoutID, observedAt: observedAt)
        }
        pendingSynchronization = operation
        await operation.value
    }

    private func performHeartRateExpiry(workoutID: UUID, observedAt: Date) async {
        guard freshnessSampleAt == observedAt,
              freshnessWorkoutID == workoutID else { return }
        freshnessTask = nil
        freshnessSampleAt = nil
        freshnessWorkoutID = nil
        guard let activity = Activity<LooprWorkoutActivityAttributes>.activities.first(where: {
            $0.attributes.sessionID == workoutID
                && $0.content.state.heartRateObservedAt == observedAt
        }) else { return }
        let old = activity.content.state
        let expired = LooprWorkoutActivityAttributes.ContentState(
            elapsedSeconds: old.elapsedSeconds, heartRate: nil, status: old.status,
            startedAt: old.startedAt, heartRateObservedAt: nil, zone: nil,
            distanceMeters: old.distanceMeters,
            paceSecondsPerKilometer: old.paceSecondsPerKilometer,
            targetName: old.targetName,
            targetStatus: old.targetStatus?.hasPrefix("Warm-up") == true ? old.targetStatus : "No heart rate"
        )
        await activity.update(ActivityContent(state: expired, staleDate: Date().addingTimeInterval(90)))
        lastPublishedAt[workoutID] = Date()
    }

    private func clearHeartRateExpiry() {
        freshnessTask?.cancel()
        freshnessTask = nil
        freshnessSampleAt = nil
        freshnessWorkoutID = nil
    }

    nonisolated static func shouldPublish(
        previous: LooprWorkoutActivityAttributes.ContentState,
        next: LooprWorkoutActivityAttributes.ContentState,
        elapsedSinceUpdate: TimeInterval
    ) -> Bool {
        if previous.status != next.status || previous.zone != next.zone || previous.targetName != next.targetName { return true }
        // Countdown and bpm offsets change every second. Publish position changes
        // immediately; keep numeric changes on the existing heart-rate cadence.
        let previousPosition = previous.targetStatus?.split(separator: " ").first
        let nextPosition = next.targetStatus?.split(separator: " ").first
        if previousPosition != nextPosition { return true }
        if (previous.heartRate == nil) != (next.heartRate == nil) { return true }
        if let old = previous.heartRateObservedAt, let new = next.heartRateObservedAt,
           new.timeIntervalSince(old) >= 8 { return true }
        guard elapsedSinceUpdate >= 15 else { return false }
        if let old = previous.heartRate, let new = next.heartRate, abs(new - old) >= 3 { return true }
        if let old = previous.distanceMeters, let new = next.distanceMeters, abs(new - old) >= 25 { return true }
        if (previous.distanceMeters == nil) != (next.distanceMeters == nil) { return true }
        return elapsedSinceUpdate >= 60 && next.heartRateObservedAt != nil
    }
}

actor LooprBreathingLiveActivityHook: BreathingActivityHook {
    static let shared = LooprBreathingLiveActivityHook()

    private struct Session: Sendable {
        let startedAt: Date
        let cadence: Double
    }

    private var sessions: [UUID: Session] = [:]
    private var pendingStart: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.loopr.ios", category: "BreathingLiveActivity")

    func started(sessionID: UUID, cadence: Double) async {
        let predecessor = pendingStart
        let operation = Task {
            await predecessor?.value
            await performStart(sessionID: sessionID, cadence: cadence)
        }
        pendingStart = operation
        await operation.value
    }

    private func performStart(sessionID: UUID, cadence: Double) async {
        let session = sessions[sessionID] ?? Session(startedAt: Date(), cadence: cadence)
        sessions[sessionID] = session
        let content = content(session: session, at: Date(), status: "In progress")

        let existing = Activity<LooprBreathingActivityAttributes>.activities
        let keeper = existing.filter { $0.attributes.sessionID == sessionID &&
            ($0.content.staleDate ?? .distantFuture) > Date() }.map(\.id).sorted().first
        for other in existing where other.id != keeper {
            await other.end(ActivityContent(state: .init(
                completedCycles: other.content.state.completedCycles,
                status: "Ended", startedAt: other.content.state.startedAt
            ), staleDate: nil), dismissalPolicy: .immediate)
            if other.attributes.sessionID != sessionID {
                sessions.removeValue(forKey: other.attributes.sessionID)
            }
        }

        if let activity = existing.first(where: { $0.id == keeper }) {
            await activity.update(content)
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            logger.notice("Breathing Live Activity is disabled by system authorization")
            return
        }
        do {
            _ = try Activity.request(
                attributes: LooprBreathingActivityAttributes(sessionID: sessionID),
                content: content,
                pushType: nil
            )
        } catch {
            logger.error("Could not start breathing Live Activity: \(String(describing: error), privacy: .public)")
        }
    }

    func updated(sessionID: UUID, sample: LiveCardiacSample) async {
        guard let session = sessions[sessionID], let activity = activity(sessionID: sessionID) else { return }
        let next = content(session: session, at: sample.timestamp, status: "In progress")
        if next.state.completedCycles != activity.content.state.completedCycles
            || activity.content.state.status != next.state.status {
            await activity.update(next)
        }
    }

    func interrupted(sessionID: UUID) async {
        guard let session = sessions[sessionID], let activity = activity(sessionID: sessionID) else { return }
        await activity.update(content(session: session, at: Date(), status: "Paused"))
    }

    func ended(sessionID: UUID, result: BreathingResult?) async {
        await pendingStart?.value
        let session = sessions.removeValue(forKey: sessionID)
        guard let activity = activity(sessionID: sessionID) else { return }
        let date = result?.endedAt ?? Date()
        let status = result == nil ? "Cancelled" : "Complete"
        let finalContent = session.map {
            ActivityContent(state: content(session: $0, at: date, status: status).state, staleDate: nil)
        } ?? ActivityContent(state: .init(
            completedCycles: activity.content.state.completedCycles, status: status,
            startedAt: activity.content.state.startedAt
        ), staleDate: nil)
        await activity.end(finalContent, dismissalPolicy: result == nil
            ? .immediate : .after(Date().addingTimeInterval(2 * 60)))
    }

    func endOrphans() async {
        sessions.removeAll()
        for activity in Activity<LooprBreathingActivityAttributes>.activities {
            await activity.end(ActivityContent(state: .init(
                completedCycles: activity.content.state.completedCycles,
                status: "Ended", startedAt: activity.content.state.startedAt
            ), staleDate: nil), dismissalPolicy: .immediate)
        }
    }

    func reconcileOnWake() async {
        await pendingStart?.value
        let now = Date()
        let current = sessions.max { $0.value.startedAt < $1.value.startedAt }?.key
        let activities = Activity<LooprBreathingActivityAttributes>.activities
        let plan = LooprActivityLifecycle.decide(
            existing: activities.map { .init(
                id: $0.id, sessionID: $0.attributes.sessionID,
                isStale: ($0.content.staleDate ?? .distantFuture) <= now
            ) },
            session: current.map(LooprActivityLifecycle.Session.running) ?? .none
        )
        for end in plan.ends {
            guard let activity = activities.first(where: { $0.id == end.id }) else { continue }
            await activity.end(ActivityContent(state: .init(
                completedCycles: activity.content.state.completedCycles,
                status: end.reason == .stale ? "Stopped updating" : "Ended",
                startedAt: activity.content.state.startedAt
            ), staleDate: nil), dismissalPolicy: .immediate)
            if end.reason != .duplicate {
                sessions.removeValue(forKey: activity.attributes.sessionID)
            }
        }
    }

    private func activity(sessionID: UUID) -> Activity<LooprBreathingActivityAttributes>? {
        Activity<LooprBreathingActivityAttributes>.activities.first {
            $0.attributes.sessionID == sessionID
        }
    }

    private func content(
        session: Session,
        at date: Date,
        status: String
    ) -> ActivityContent<LooprBreathingActivityAttributes.ContentState> {
        let elapsed = max(0, date.timeIntervalSince(session.startedAt))
        let completedCycles = max(0, Int((elapsed * session.cadence / 60).rounded(.down)))
        return ActivityContent(
            state: .init(completedCycles: completedCycles, status: status, startedAt: session.startedAt),
            staleDate: Date().addingTimeInterval(90)
        )
    }
}

#if DEBUG
enum LooprNativeSurfaceProbe {
    static let environmentKey = "LOOPR_NATIVE_SURFACE_PROBE"

    static func startIfRequested(environment: [String: String] = ProcessInfo.processInfo.environment) async {
        guard let probe = environment[environmentKey] else { return }
        if probe == "widget" {
            await seedWidgetSnapshot()
            return
        }
        if probe == "both" {
            let now = Date()
            await LooprLiveActivityRuntime.shared.synchronize(
                WorkoutRecord(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000703")!,
                    identity: WorkoutIdentity(canonicalKey: "native-surface-probe"),
                    activity: .run,
                    source: .live,
                    state: .active,
                    createdAt: now.addingTimeInterval(-180),
                    startedAt: now.addingTimeInterval(-180)
                )
            )
        }
        guard probe == "breathing" || probe == "both" else { return }
        await LooprBreathingLiveActivityHook.shared.started(
            sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000805")!,
            cadence: 6
        )
    }

    private static func seedWidgetSnapshot() async {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SurfaceConfiguration.appGroupIdentifier
        ) else { return }
        let now = Date()
        let snapshot = SurfaceSnapshot(
            generation: 805,
            createdAt: now,
            sourceDay: SurfaceDayLabel.format(now),
            syncDate: now,
            metrics: .init(recovery: 82, strain: 8.6, heartRate: 54, sleepMinutes: 462),
            battery: .init(level: 0.74, observedAt: now),
            activeWorkout: nil,
            staleReasons: []
        )
        try? await AtomicSurfaceSnapshotStore(
            url: container.appendingPathComponent("surface.json")
        ).write(snapshot)
        WidgetCenter.shared.reloadAllTimelines()
    }
}
#endif

final class LooprWatchSnapshotBridge: NSObject, WCSessionDelegate, @unchecked Sendable {
    static let shared = LooprWatchSnapshotBridge()
    private let logger = Logger(subsystem: "com.loopr.ios", category: "WatchSnapshot")
    private let activationLock = NSLock()
    private var activationWaiters: [CheckedContinuation<Void, any Error>] = []

    /// Activation is asynchronous and the first publish would otherwise pay
    /// for it. Calling this at launch means a snapshot written seconds later
    /// reaches the Watch on the same run.
    func activateIfNeeded() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState != .activated else { return }
        session.delegate = self
        session.activate()
    }

    func publish(_ snapshot: SurfaceSnapshot) async {
        guard WCSession.isSupported(),
              let data = try? JSONEncoder().encode(snapshot) else { return }
        let session = WCSession.default
        session.delegate = self
        do {
            try await waitForActivation(of: session)
            guard session.isPaired, session.isWatchAppInstalled else { return }
            try session.updateApplicationContext(WatchSurfaceApplicationContext.publishing(data))
        } catch {
            // Watch delivery is a secondary surface. A temporary connectivity
            // failure must not block local workout finalization; the next
            // snapshot publication replaces the durable application context.
            logger.error("Could not publish Watch snapshot: \(String(describing: error), privacy: .public)")
        }
    }

    /// Replaces the durable WatchConnectivity context with an explicit empty
    /// context. The Watch receiver treats that as revocation and removes its
    /// App Group cache, so phone-side account deletion cannot leave health
    /// metrics visible on the paired Watch.
    func clear() async throws {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        try await waitForActivation(of: session)
        guard session.isPaired, session.isWatchAppInstalled else { return }
        try session.updateApplicationContext(WatchSurfaceApplicationContext.revoking)
    }

    private func waitForActivation(of session: WCSession) async throws {
        if session.activationState == .activated { return }
        try await withCheckedThrowingContinuation { continuation in
            activationLock.lock()
            if session.activationState == .activated {
                activationLock.unlock()
                continuation.resume()
                return
            }
            activationWaiters.append(continuation)
            activationLock.unlock()
            session.activate()
        }
    }

    func session(
        _: WCSession,
        activationDidCompleteWith _: WCSessionActivationState,
        error: (any Error)?
    ) {
        activationLock.lock()
        let waiters = activationWaiters
        activationWaiters.removeAll()
        activationLock.unlock()
        for waiter in waiters {
            if let error {
                waiter.resume(throwing: error)
            } else if WCSession.default.activationState == .activated {
                waiter.resume()
            } else {
                waiter.resume(throwing: WCError(.sessionNotActivated))
            }
        }
    }

    func sessionDidBecomeInactive(_: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }
}
