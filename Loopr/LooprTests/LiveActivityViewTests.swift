import Foundation
import Testing
import WorkoutKit

@testable import Loopr

@MainActor
struct LiveActivityViewTests {
    @Test
    func staleAndMissingHeartRateRemainMissingInTheView() {
        let measured = state(heartRate: 142, zone: 3)
        let stale = LooprWorkoutLiveActivityVisual(name: "Running", state: measured, isStale: true)
        #expect(stale.heartRate == "--")
        #expect(stale.heartRateAccessibility == "Heart rate unavailable")
        #expect(stale.zone == nil)
        #expect(stale.zoneName == "Zone unavailable")

        let missing = LooprWorkoutLiveActivityVisual(
            name: "Running", state: state(heartRate: nil, zone: nil), isStale: false
        )
        #expect(missing.heartRate == "--")
        #expect(missing.pace == nil)

        let zero = LooprWorkoutLiveActivityVisual(
            name: "Running", state: state(heartRate: 0, zone: 1), isStale: false
        )
        #expect(zero.heartRate == "--")
        #expect(zero.zone == nil)
    }

    @Test
    func zoneNamesMatchTheLiveWorkoutScreen() {
        for number in 1...5 {
            let visual = LooprWorkoutLiveActivityVisual(
                name: "Running", state: state(heartRate: 142, zone: number), isStale: false
            )
            #expect(visual.zoneName == WorkoutZoneDisplay.name(for: number))
        }
    }

    private func state(heartRate: Int?, zone: Int?) -> LooprWorkoutActivityAttributes.ContentState {
        .init(elapsedSeconds: 60, heartRate: heartRate, status: "Active",
              startedAt: Date(timeIntervalSince1970: 1_000),
              heartRateObservedAt: heartRate == nil ? nil : Date(timeIntervalSince1970: 1_060),
              zone: zone, distanceMeters: nil, paceSecondsPerKilometer: nil)
    }
}
