import XCTest
import AnalyticsKit
@testable import WorkoutKit

final class WorkoutRecoveryPresentationTests: XCTestCase {
    func testPlainDropAndPersonalContext() {
        let first = HRRecovery(peakBPM: 165, heartRateAtRecovery: 134, dropBPM: 31, dropPercent: 18.8,
                               algorithmVersion: TimedHeartRateRecovery.algorithmVersion)
        let assessment = TimedHeartRateRecovery(firstMinute: first, secondMinute: nil, reason: nil)
        let shown = WorkoutRecoveryPresentation(assessment: assessment, usualDrop: 27, eligibleWorkouts: 8)
        XCTAssertEqual(shown.sentence, "Heart rate dropped 31 bpm in the first minute.")
        XCTAssertEqual(shown.context, "+4 bpm vs usual for this activity · 8 workouts")
        XCTAssertEqual(WorkoutRecoveryPresentation(assessment: assessment, eligibleWorkouts: 2).context,
                       "Learning your usual drop · 2 of 5 eligible workouts")
    }
    func testCachedRecoveryDecodesInListingAndClearsWhenTimeIsEdited() async throws {
        let start = Date(timeIntervalSince1970: 600)
        let first = HRRecovery(peakBPM: 165, heartRateAtRecovery: 135, dropBPM: 30, dropPercent: 18,
                               algorithmVersion: TimedHeartRateRecovery.algorithmVersion)
        let assessment = TimedHeartRateRecovery(firstMinute: first, secondMinute: nil, reason: nil)
        let record = WorkoutRecord(id: UUID(), identity: .init(canonicalKey: "cached"), activity: .run,
            source: .manual, state: .completed, createdAt: start, startedAt: start, endedAt: start.addingTimeInterval(600),
            heartRateRecovery: assessment)
        let encoded = try JSONEncoder().encode(record)
        XCTAssertEqual(try JSONDecoder().decode(WorkoutRecord.self, from: encoded).heartRateRecovery, assessment)
        XCTAssertEqual(try JSONDecoder().decode(WorkoutListingRowDocument.self, from: encoded).row.heartRateRecovery, assessment)
        let store = InMemoryWorkoutStore(workouts: [record])
        let controller = WorkoutSessionController(store: store)
        let edited = try await controller.edit(id: record.id, endedAt: start.addingTimeInterval(610))
        XCTAssertNil(edited.heartRateRecovery)
    }
    func testIneligibleHasOnlyReason() {
        let shown = WorkoutRecoveryPresentation(assessment: .init(firstMinute: nil, secondMinute: nil, reason: "No continuous heart rate."))
        XCTAssertEqual(shown.sentence, "No continuous heart rate.")
        XCTAssertNil(shown.context)
    }
}
