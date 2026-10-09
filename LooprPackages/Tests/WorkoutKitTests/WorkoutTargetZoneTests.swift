import AnalyticsKit
import DomainKit
import Foundation
import WorkoutKit
import XCTest

final class WorkoutTargetZoneTests: XCTestCase {
    func testTargetStatusIncludesDistanceWithoutRepeatingReading() {
        let preference = WorkoutZoneAlertPreference(target: .custom(lower: 131, upper: 144), warmUpMinutes: 0)
        let target = WorkoutZoneTarget(preference: preference, zones: nil, zoneTwo: nil)!
        XCTAssertEqual(target.status(bpm: 156), "Above by 12 bpm")
        XCTAssertEqual(target.status(bpm: 125), "Below by 6 bpm")
        XCTAssertEqual(target.status(bpm: 131), "In zone")
        XCTAssertEqual(target.status(bpm: 144), "In zone")
        XCTAssertEqual(target.status(bpm: nil), "No heart rate")
    }

    func testStoredPausesExcludeElapsedAndSurviveDecoding() throws {
        let start = Date(timeIntervalSince1970: 1000)
        let workout = WorkoutRecord(id: UUID(), identity: .init(canonicalKey: "pause"), activity: .run, source: .live,
                                    state: .paused, createdAt: start, startedAt: start,
                                    pauses: [.init(start: start.addingTimeInterval(120), end: start.addingTimeInterval(180)),
                                             .init(start: start.addingTimeInterval(240))])
        XCTAssertEqual(workout.activeElapsed(at: start.addingTimeInterval(360)), 180)
        let restored = try JSONDecoder().decode(WorkoutRecord.self, from: JSONEncoder().encode(workout))
        XCTAssertEqual(restored.activeElapsed(at: start.addingTimeInterval(480)), 180)
    }
    func testPauseTransitionsAndRecoveryKeepGracePaused() async throws {
        let start = Date(timeIntervalSince1970: 1000)
        let clock = WorkoutTargetClock(start)
        let controller = WorkoutSessionController(store: InMemoryWorkoutStore(), now: { @Sendable in clock.read() })
        let workout = try await controller.start(activity: .run, source: .manual)
        _ = try await controller.transition(to: .preparing)
        _ = try await controller.transition(to: .active)
        clock.set(start.addingTimeInterval(120))
        _ = try await controller.transition(to: .paused)
        clock.set(start.addingTimeInterval(300))
        _ = try await controller.recoverInterrupted()
        _ = try await controller.resumeRecovered(id: workout.id)
        let resumed = await controller.activeWorkout()
        XCTAssertEqual(resumed?.activeElapsed(at: start.addingTimeInterval(360)), 180)
        XCTAssertEqual(resumed?.pauses?.first?.end, start.addingTimeInterval(300))
    }

    func testNewResolutionStartsASpanWithoutRewritingTheSavedTarget() async throws {
        let start = Date(timeIntervalSince1970: 1000)
        let clock = WorkoutTargetClock(start)
        let controller = WorkoutSessionController(store: InMemoryWorkoutStore(), now: { @Sendable in clock.read() })
        let workout = try await controller.start(activity: .run, source: .manual)
        _ = try await controller.transition(to: .preparing)
        _ = try await controller.transition(to: .active)
        let settings = HeartRateZoneSettings(manualMaximum: 184)
        let preference = WorkoutZoneAlertPreference(target: .zoneTwo)
        func target(_ resting: Double) -> WorkoutZoneTarget {
            let shared = settings.resolved(age: nil, restingNights: [resting])!
            return WorkoutZoneTarget(preference: preference,
                zones: ActivityAnalytics.zones(shared, source: .manual).value,
                zoneTwo: ZoneTwoRange.resolve(zones: shared))!
        }
        _ = try await controller.configureZoneAlerts(id: workout.id, preference: preference, target: target(51))
        clock.set(start.addingTimeInterval(120))
        _ = try await controller.configureZoneAlerts(id: workout.id, preference: preference, target: target(60))
        let updated = try await controller.configureZoneAlerts(id: workout.id, preference: preference, target: target(60))
        XCTAssertEqual(updated.zoneTargetChanges?.count, 2)
        XCTAssertEqual(updated.zoneTargetChanges?.first?.target?.range, 131...144)
        XCTAssertEqual(updated.zoneTargetChanges?.last?.target?.range, 135...146)
        XCTAssertEqual(updated.zoneTargetChanges?.last?.at, start.addingTimeInterval(120))
    }

    func testOldWorkoutJSONDecodesWithoutTargetOrPauses() throws {
        let workout = WorkoutRecord(id: UUID(), identity: .init(canonicalKey: "old"), activity: .run, source: .live, createdAt: Date())
        let data = try JSONEncoder().encode(workout)
        let restored = try JSONDecoder().decode(WorkoutRecord.self, from: data)
        XCTAssertNil(restored.pauses)
        XCTAssertNil(restored.zoneTargetChanges)
        XCTAssertNil(restored.zoneAlertPreference)
    }
    func testSummaryKeepsGapsMissingAndSubtractsPauses() {
        let start = Date(timeIntervalSince1970: 1000)
        let preference = WorkoutZoneAlertPreference(target: .custom(lower: 130, upper: 150), warmUpMinutes: 0)
        let target = WorkoutZoneTarget(preference: preference, zones: nil, zoneTwo: nil)!
        let workout = WorkoutRecord(id: UUID(), identity: .init(canonicalKey: "summary"), activity: .run, source: .live,
                                    state: .completed, createdAt: start, startedAt: start, endedAt: start.addingTimeInterval(30),
                                    samples: [.init(timestamp: start, heartRate: 140),
                                              .init(timestamp: start.addingTimeInterval(10), heartRate: 160),
                                              .init(timestamp: start.addingTimeInterval(20), heartRate: 120)],
                                    pauses: [.init(start: start.addingTimeInterval(12), end: start.addingTimeInterval(18))],
                                    zoneAlertPreference: preference, zoneTargetChanges: [.init(at: start, target: target)])
        let summary = WorkoutTargetZoneSummary(workout: workout)!
        XCTAssertEqual(summary.insideSeconds, 5)
        XCTAssertEqual(summary.observedSeconds, 12)
        XCTAssertEqual(summary.targetSeconds, 24)
        XCTAssertEqual(summary.percent, 21)
    }
}

private final class WorkoutTargetClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    init(_ date: Date) { self.date = date }
    func read() -> Date { lock.withLock { date } }
    func set(_ date: Date) { lock.withLock { self.date = date } }
}
