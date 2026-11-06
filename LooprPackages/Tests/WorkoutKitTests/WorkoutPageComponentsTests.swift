import XCTest
@testable import WorkoutKit

final class WorkoutPageComponentsTests: XCTestCase {
    func testDurationUsesTimeUnits() {
        XCTAssertEqual(WorkoutDurationText.formatted(1_800), "30 min")
        XCTAssertEqual(WorkoutDurationText.formatted(5_400), "1 h 30 m")
        XCTAssertNil(WorkoutDurationText.formatted(nil))
    }

    /// A 30-minute run never reads as 250 m, and a ride that stopped says how long it ran before it did.
    func testFixtureRowsShowDurationAndAFullDistance() throws {
        let now = Date(timeIntervalSince1970: 1_700_100_000)
        let run = try XCTUnwrap(WorkoutSessionPresentation.detailLine(for: WorkoutFixtures.completedRun, now: now)).lowercased()
        XCTAssertTrue(run.contains("30 min") && run.contains("5.2 km"), run)
        let ride = try XCTUnwrap(WorkoutSessionPresentation.detailLine(for: WorkoutFixtures.interrupted, now: now)).lowercased()
        XCTAssertTrue(ride.contains("41 min") && ride.contains("14.3 km"), ride)
        // A recoverable workout with no checkpoint and no samples has no duration to claim.
        var bare = WorkoutFixtures.interrupted
        bare.samples = []
        bare.lastCheckpointAt = nil
        let line = try XCTUnwrap(WorkoutSessionPresentation.detailLine(for: bare, now: now)).lowercased()
        XCTAssertFalse(line.contains("min") || line.contains("km"), line)
    }
}
