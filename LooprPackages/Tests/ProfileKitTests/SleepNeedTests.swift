import Foundation
import Testing
import ProfileKit

struct SleepNeedTests {
    private func goal(_ target: Double, _ unit: String, enabled: Bool = true) -> Goal {
        Goal(id: UUID(), type: .sleep, target: target, unit: unit,
             isEnabled: enabled, updatedAt: Date(timeIntervalSince1970: 0))
    }

    @Test func savedGoalAndDefaultUseOneResolver() {
        #expect(SleepNeed.minutes(from: []) == 480)
        #expect(SleepNeed.minutes(from: [goal(7.5, "hours")]) == 450)
        #expect(SleepNeed.minutes(from: [goal(450, "minutes")]) == 450)
        #expect(SleepNeed.minutes(from: [goal(7.5, "hours", enabled: false)]) == 480)
        #expect(SleepNeed.minutes(from: [goal(7.5, "points")]) == 480)
    }
}
