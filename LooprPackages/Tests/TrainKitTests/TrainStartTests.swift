import Foundation
import Testing
import WorkoutKit
@testable import TrainKit

/// The Train tab's start grid and week totals.
struct TrainStartTests {
    @Test func theRecordedActivitiesLeaveTheGymToTheSetLog() {
        #expect(!ActivityType.recordable.contains(.strength))
        #expect(Set(ActivityType.recordable).union([.strength]) == Set(ActivityType.allCases))
        for activity in ActivityType.allCases {
            #expect(!activity.shortName.isEmpty)
            #expect(!activity.symbolName.isEmpty)
        }
        #expect(ActivityType.run.recordsCaption == "Route, pace and heart rate")
    }

    @Test func weekTotalsCountFinishedSessionsTheirTimeAndTheWeightLifted() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        func workout(_ minutes: Double, state: WorkoutLifecycleState = .completed) -> WorkoutRecord {
            let end = start.addingTimeInterval(minutes * 60)
            return WorkoutRecord(id: UUID(), identity: WorkoutIdentity.make(activity: .run, sourceKey: UUID().uuidString, startedAt: start, endedAt: end),
                                 activity: .run, source: .manual, state: state, createdAt: start, startedAt: start, endedAt: end,
                                 finalizationStage: .activeStateCleared)
        }
        let session = TrainSessionSummary(id: UUID(), workoutID: nil, name: "Lower A", localDay: "2023-11-13", minutes: 62,
                                          tonnageKg: 8_420, caption: "", detail: "", spokenLabel: "")
        let totals = TrainWeekTotals(workouts: [workout(30), workout(62), workout(45, state: .interruptedAndRecoverable)], sessions: [session])
        #expect(totals.count == 2)
        #expect(totals.minutes == 92)
        #expect(totals.timeValue == "92" && totals.timeUnit == "min")
        #expect(totals.liftedKg == 8_420 && totals.liftedUnit == "kg")
        // R2-UPG-11: the unsaved run is in the list but not in the totals, and the week says why.
        #expect(totals.unsavedNote == "\(ActivityType.run.displayName) is not counted until you finish saving it.")
        #expect(TrainWeekTotals(workouts: [workout(30)], sessions: []).unsavedNote == nil)

        let long = TrainWeekTotals(workouts: [workout(130), workout(80)], sessions: [session, session])
        #expect(long.timeUnit == "h")
        // The app's one number locale, whatever the device region (R3-OPT-11).
        #expect(long.timeValue == "3.5")
        #expect(totals.liftedValue == "8,420")
        #expect(long.liftedUnit == "t")

        let empty = TrainWeekTotals(workouts: [], sessions: [])
        #expect(empty.count == 0 && empty.timeValue == "0" && empty.liftedValue == "0")
    }
}
