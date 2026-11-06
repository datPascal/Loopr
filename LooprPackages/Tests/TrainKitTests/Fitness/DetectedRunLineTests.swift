import Foundation
import Testing
import WorkoutKit
@testable import TrainKit

/// The detected-workout card says when it was and how long, so it can be reviewed without opening it.
struct DetectedRunLineTests {
    @Test func theLineHasTheStartTimeTheDurationAndTheReviewPrompt() {
        let start = Date(timeIntervalSince1970: 1_700_000_400)
        let run = DetectedWorkout(detectionID: "run", activity: .run, startedAt: start, endedAt: start.addingTimeInterval(34 * 60 + 20))
        let line = TrainScreen.detectedLine(run)
        let parts = line.components(separatedBy: " · ")
        #expect(parts.count == 3, "\(line)")
        #expect(parts[1] == "34 min" && parts[2] == "Review before saving")
        #expect(parts[0] == "Started " + start.formatted(date: .omitted, time: .shortened), "The time follows the phone's clock setting")
    }

    @Test func aDetectionWithNoLengthLeavesTheDurationOut() {
        let start = Date(timeIntervalSince1970: 1_700_000_400)
        let blip = DetectedWorkout(detectionID: "blip", activity: .run, startedAt: start, endedAt: start)
        #expect(TrainScreen.detectedLine(blip).hasSuffix(" · Review before saving"))
        #expect(!TrainScreen.detectedLine(blip).contains("min"))
    }
}
