import XCTest
@testable import WorkoutKit

final class CheckpointBudgetTests: XCTestCase {
    func testLiveUpdatesRemainBufferedAndExpirationYieldsAfterDurableCheckpoint() async throws {
        let clock = Date(timeIntervalSince1970: 1_787_472_000)
        let store = InMemoryWorkoutStore()
        let controller = WorkoutSessionController(store: store, now: { clock })
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000904")!
        _ = try await controller.start(activity: .run, source: .manual, id: id)
        _ = try await controller.transition(to: .preparing)
        _ = try await controller.transition(to: .active)
        let updates = await controller.updates(for: id)
        var iterator = updates.makeAsyncIterator()
        _ = await iterator.next()

        for offset in 0..<64 {
            try await controller.append(WorkoutSample(
                timestamp: clock.addingTimeInterval(Double(offset)),
                heartRate: 120 + offset % 5
            ))
        }
        let checkpoint = try await controller.checkpoint()
        XCTAssertEqual(checkpoint.checkpointNumber, 1)
        XCTAssertEqual(checkpoint.samples.count, 64)

        let recovered = try await controller.recoverInterrupted()
        XCTAssertEqual(recovered.count, 1)
        XCTAssertEqual(recovered[0].checkpointNumber, 1)
        XCTAssertEqual(recovered[0].lastCheckpointAt, clock)
        XCTAssertEqual(recovered[0].state, .interruptedAndRecoverable)
        let bufferedUpdate = await iterator.next()
        XCTAssertNotNil(bufferedUpdate, "buffered live display update must survive checkpoint publication")
    }
}
