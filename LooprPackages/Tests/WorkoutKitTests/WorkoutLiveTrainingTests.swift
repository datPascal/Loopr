import AnalyticsKit
import Foundation
import WorkoutKit
import XCTest

final class WorkoutLiveTrainingTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func zones() -> HeartRateZoneSet {
        ActivityAnalytics.zones(maxHR: 200, source: .agePredicted).value!
    }

    func testStaleAndMissingHeartRateRemainAbsent() {
        let workout = WorkoutRecord(
            id: UUID(), identity: .init(canonicalKey: "test"), activity: .run, source: .live,
            state: .active, createdAt: start, startedAt: start,
            samples: [WorkoutSample(timestamp: start, heartRate: 150)]
        )
        let live = WorkoutLiveMetrics(workout: workout, zones: zones(), now: start.addingTimeInterval(11))
        XCTAssertNil(live.heartRate)
        XCTAssertNil(live.zone)
        XCTAssertEqual(live.secondsInZones[3], 5)
        let absent = WorkoutLiveMetrics(workout: nil, zones: zones(), now: start)
        XCTAssertNil(absent.heartRate)
        XCTAssertNil(absent.elapsed)
    }

    func testMiniPlayerDoesNotFreezeAnOldHeartRate() {
        let workout = WorkoutRecord(
            id: UUID(), identity: .init(canonicalKey: "mini"), activity: .run, source: .live,
            state: .active, createdAt: start, startedAt: start,
            samples: [WorkoutSample(timestamp: start, heartRate: 145)]
        )
        XCTAssertNil(WorkoutMiniPlayer(workout: workout, now: start.addingTimeInterval(11)).heartRate)
        XCTAssertEqual(WorkoutMiniPlayer(workout: workout, now: start.addingTimeInterval(2)).heartRate, 145)
    }

    func testZonesReuseActivityAnalyticsBoundaries() {
        let set = zones()
        XCTAssertEqual(WorkoutZoneDisplay(bpm: 160, zones: set)?.number, set.zoneNumber(for: 160))
        XCTAssertEqual(WorkoutZoneAlertTarget.zone(4).range(in: set), 160...179)
        XCTAssertNil(WorkoutZoneAlertTarget.zone(4).range(in: nil))
        XCTAssertEqual(WorkoutZoneAlertTarget.zone(5).range(in: set), 180...200)
    }

    func testPreferencesAreSeparateByActivity() {
        let suite = "workout-live-tests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WorkoutZoneAlertPreferenceStore(defaults: defaults)
        store.set(.init(target: .custom(lower: 128, upper: 145), playSound: true), for: .run)
        XCTAssertEqual(store.preference(for: .run), .init(target: .custom(lower: 128, upper: 145), playSound: true))
        XCTAssertEqual(store.preference(for: .cycle), .init())
    }

    func testBoundaryJitterDoesNotAlert() {
        var machine = WorkoutZoneAlertMachine()
        for offset in 0..<120 {
            XCTAssertNil(machine.observe(bpm: offset.isMultiple(of: 2) ? 152 : 129,
                                         at: start.addingTimeInterval(Double(offset)), target: 130...150))
        }
        XCTAssertEqual(machine.state, .inRange)
    }
}
