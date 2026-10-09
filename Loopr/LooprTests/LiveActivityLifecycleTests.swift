import Foundation
import AnalyticsKit
import Testing
import WorkoutKit

@testable import Loopr

struct LiveActivityLifecycleTests {
    private let session = UUID(uuidString: "00000000-0000-0000-0000-000000000111")!
    private let other = UUID(uuidString: "00000000-0000-0000-0000-000000000222")!

    @Test
    func launchEndsOrphanedActivities() {
        let plan = LooprActivityLifecycle.decide(
            existing: [.init(id: "old", sessionID: session, isStale: false)],
            session: .none
        )
        #expect(plan.ends == [.init(id: "old", reason: .orphan)])
        #expect(plan.updateID == nil)
        #expect(!plan.shouldStart)
    }

    @Test
    func duplicateStartKeepsOneActivityForCanonicalSession() {
        let plan = LooprActivityLifecycle.decide(existing: [
            .init(id: "b", sessionID: session, isStale: false),
            .init(id: "a", sessionID: session, isStale: false),
            .init(id: "other", sessionID: other, isStale: false)
        ], session: .running(session))
        #expect(plan.updateID == "a")
        #expect(!plan.shouldStart)
        #expect(plan.ends == [
            .init(id: "b", reason: .duplicate),
            .init(id: "other", reason: .orphan)
        ])
    }

    @Test
    func discardEndsImmediatelyAndDoesNotStartAnother() {
        let plan = LooprActivityLifecycle.decide(
            existing: [.init(id: "current", sessionID: session, isStale: false)],
            session: .discarded(session)
        )
        #expect(plan.ends == [.init(id: "current", reason: .discarded)])
        #expect(!plan.shouldStart)
    }

    @Test
    func finishRetainsTheFinalSummaryDecision() {
        let plan = LooprActivityLifecycle.decide(
            existing: [.init(id: "current", sessionID: session, isStale: false)],
            session: .finished(session)
        )
        #expect(plan.ends == [.init(id: "current", reason: .finished)])
        #expect(!plan.shouldStart)
    }

    @Test
    func finishingAnotherWorkoutKeepsTheCurrentLiveActivity() {
        let plan = LooprActivityLifecycle.decide(
            existing: [.init(id: "live", sessionID: session, isStale: false)],
            session: .finished(other)
        )
        #expect(plan.ends.isEmpty)
        #expect(!plan.shouldStart)
    }

    @Test
    func staleActivityEndsAndRunningSessionCanStartFresh() {
        let plan = LooprActivityLifecycle.decide(
            existing: [.init(id: "stale", sessionID: session, isStale: true)],
            session: .running(session)
        )
        #expect(plan.ends == [.init(id: "stale", reason: .stale)])
        #expect(plan.updateID == nil)
        #expect(plan.shouldStart)
    }

    @Test
    func finishingRecordWithEndDateClosesActivityBeforeFinalHookReturns() {
        let workout = WorkoutRecord(
            id: session, identity: .init(canonicalKey: "live"), activity: .run,
            source: .live, state: .finishing,
            createdAt: Date(timeIntervalSince1970: 1_000),
            startedAt: Date(timeIntervalSince1970: 1_000),
            endedAt: Date(timeIntervalSince1970: 1_600)
        )
        #expect(LooprActivityLifecycle.session(for: workout, allowed: true) == .finished(session))
        #expect(LooprActivityLifecycle.session(for: workout, allowed: false) == .none)
    }

    @Test
    func projectionUsesTheLiveWorkoutZoneAndMeasuredRouteData() {
        let start = Date(timeIntervalSince1970: 1_000)
        let zones = ActivityAnalytics.zones(maxHR: 200, source: .agePredicted).value!
        let sample = WorkoutSample(timestamp: start.addingTimeInterval(600),
                                   heartRate: 142, zone: 5, distanceMeters: 2_000)
        let workout = WorkoutRecord(
            id: session, identity: .init(canonicalKey: "live"), activity: .run,
            source: .live, state: .active, createdAt: start, startedAt: start,
            samples: [sample]
        )
        let state = LooprWorkoutActivityProjection.state(
            for: workout, zones: zones, now: start.addingTimeInterval(610)
        )
        #expect(state.heartRate == 142)
        #expect(state.zone == WorkoutLiveMetrics(
            workout: workout, zones: zones, now: start.addingTimeInterval(610)
        ).zone?.number)
        #expect(state.distanceMeters == 2_000)
        #expect(state.paceSecondsPerKilometer == 300)
        #expect(state.startedAt == start)

        let stale = LooprWorkoutActivityProjection.state(
            for: workout, zones: zones, now: start.addingTimeInterval(611)
        )
        #expect(stale.heartRate == nil)
        #expect(stale.zone == nil)
        #expect(stale.distanceMeters == 2_000)
        let noZones = LooprWorkoutActivityProjection.state(
            for: workout, zones: nil, now: start.addingTimeInterval(605)
        )
        #expect(noZones.heartRate == 142)
        #expect(noZones.zone == nil)

        let invalidDistance = WorkoutRecord(
            id: session, identity: .init(canonicalKey: "invalid-distance"), activity: .run,
            source: .live, state: .active, createdAt: start, startedAt: start,
            samples: [WorkoutSample(timestamp: start.addingTimeInterval(600),
                                    distanceMeters: .infinity)]
        )
        #expect(LooprWorkoutActivityProjection.state(
            for: invalidDistance, zones: zones, now: start.addingTimeInterval(610)
        ).distanceMeters == nil)
    }

    @Test
    func updatesNeedMeaningfulChangeAndTimeToPass() {
        let previous = state(heartRate: 120, zone: 2, distance: 100)
        #expect(!LooprLiveActivityRuntime.shouldPublish(
            previous: previous, next: state(heartRate: 122, zone: 2, distance: 110),
            elapsedSinceUpdate: 20
        ))
        #expect(!LooprLiveActivityRuntime.shouldPublish(
            previous: previous, next: state(heartRate: 124, zone: 2, distance: 110),
            elapsedSinceUpdate: 5
        ))
        #expect(LooprLiveActivityRuntime.shouldPublish(
            previous: previous, next: state(heartRate: 124, zone: 2, distance: 110),
            elapsedSinceUpdate: 20
        ))
        #expect(LooprLiveActivityRuntime.shouldPublish(
            previous: previous, next: state(heartRate: 120, zone: 3, distance: 100),
            elapsedSinceUpdate: 1
        ))
        #expect(LooprLiveActivityRuntime.shouldPublish(
            previous: previous, next: state(heartRate: 120, zone: 2, distance: 130),
            elapsedSinceUpdate: 20
        ))
        #expect(LooprLiveActivityRuntime.shouldPublish(
            previous: previous, next: state(heartRate: nil, zone: nil, distance: 100),
            elapsedSinceUpdate: 1
        ))
        #expect(LooprLiveActivityRuntime.shouldPublish(
            previous: previous,
            next: state(heartRate: 120, zone: 2, distance: 100, observedAtOffset: 69),
            elapsedSinceUpdate: 5
        ))
    }

    @Test
    func targetStatusAndPausedElapsedReachTheActivity() {
        let start = Date(timeIntervalSince1970: 1_000)
        let preference = WorkoutZoneAlertPreference(target: .custom(lower: 131, upper: 144))
        let target = WorkoutZoneTarget(preference: preference, zones: nil, zoneTwo: nil)!
        var workout = WorkoutRecord(id: session, identity: .init(canonicalKey: "target"), activity: .run,
            source: .live, state: .active, createdAt: start, startedAt: start,
            samples: [.init(timestamp: start.addingTimeInterval(600), heartRate: 156)],
            pauses: [.init(start: start.addingTimeInterval(120), end: start.addingTimeInterval(300))],
            zoneAlertPreference: preference, zoneTargetChanges: [.init(at: start, target: target)])
        let warm = LooprWorkoutActivityProjection.state(for: workout, zones: nil, now: start.addingTimeInterval(600))
        #expect(warm.elapsedSeconds == 420)
        #expect(warm.targetStatus == "Warm-up 1:00")
        #expect(warm.targetName == "Target")
        var above = warm
        above.targetStatus = "Above"
        #expect(LooprLiveActivityRuntime.shouldPublish(previous: warm, next: above, elapsedSinceUpdate: 1))
        workout.zoneAlertPreference?.warmUpMinutes = 0
        let active = LooprWorkoutActivityProjection.state(for: workout, zones: nil, now: start.addingTimeInterval(600))
        #expect(active.targetStatus == "Above by 12 bpm")
        let visual = LooprWorkoutLiveActivityVisual(name: "Run", state: active, isStale: false)
        #expect(visual.targetLine == "Target · Above by 12 bpm")
        #expect(visual.heartRateAccessibility == "156 bpm")
        workout.state = .paused
        workout.pauses?.append(.init(start: start.addingTimeInterval(600)))
        let paused = LooprWorkoutActivityProjection.state(for: workout, zones: nil, now: start.addingTimeInterval(660))
        #expect(paused.elapsedSeconds == 420)
        #expect(paused.startedAt == nil)
        #expect(paused.targetStatus == "Paused")
    }

    @Test
    func bpmOffsetsKeepTheExistingLiveActivityCadence() {
        var previous = state(heartRate: 156, zone: 3, distance: 100)
        previous.targetName = "Zone 2"
        previous.targetStatus = "Above by 12 bpm"
        var next = state(heartRate: 157, zone: 3, distance: 100, observedAtOffset: 61)
        next.targetName = "Zone 2"
        next.targetStatus = "Above by 13 bpm"
        #expect(!LooprLiveActivityRuntime.shouldPublish(previous: previous, next: next, elapsedSinceUpdate: 1))
        var fresh = state(heartRate: 157, zone: 3, distance: 100, observedAtOffset: 68)
        fresh.targetName = next.targetName
        fresh.targetStatus = next.targetStatus
        #expect(LooprLiveActivityRuntime.shouldPublish(previous: previous, next: fresh, elapsedSinceUpdate: 8))
        next.targetStatus = "In zone"
        #expect(LooprLiveActivityRuntime.shouldPublish(previous: previous, next: next, elapsedSinceUpdate: 1))
    }

    private func state(heartRate: Int?, zone: Int?, distance: Double?, observedAtOffset: TimeInterval = 60)
    -> LooprWorkoutActivityAttributes.ContentState {
        .init(elapsedSeconds: 60, heartRate: heartRate, status: "Active",
              startedAt: Date(timeIntervalSince1970: 1_000),
              heartRateObservedAt: heartRate == nil ? nil : Date(timeIntervalSince1970: 1_000 + observedAtOffset),
              zone: zone, distanceMeters: distance, paceSecondsPerKilometer: nil)
    }
}

struct WorkoutRecoveryPathTests {
    @Test
    func resumeShowsLiveWorkoutAndDiscardClosesRecovery() {
        let id = UUID()
        let started = Date(timeIntervalSince1970: 1_000)
        var workout = WorkoutRecord(
            id: id, identity: .init(canonicalKey: "recovery"), activity: .run,
            source: .live, state: .interruptedAndRecoverable,
            createdAt: started, startedAt: started
        )
        let path: [AppWorkoutRoute] = [.catalog, .recovery(id)]
        workout.state = .active
        #expect(WorkoutRecoveryPathTransition.path(after: workout, in: path) == [
            .catalog, .live(id, .run)
        ])
        workout.state = .discarded
        #expect(WorkoutRecoveryPathTransition.path(after: workout, in: path) == [.catalog])
        let other = UUID()
        #expect(WorkoutRecoveryPathTransition.path(after: workout, in: [.recovery(other)])
                == [.recovery(other)])
    }
}
