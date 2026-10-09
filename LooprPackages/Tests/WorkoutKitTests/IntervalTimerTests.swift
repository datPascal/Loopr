import Combine
import Foundation
import WorkoutKit
import XCTest

final class IntervalTimerTests: XCTestCase, @unchecked Sendable {
    private let start = Date(timeIntervalSince1970: 100)

    func testWorkRestBoundariesAndCompletionIncludeFinalRest() {
        let schedule = IntervalSchedule(configuration: .init(workSeconds: 20, restSeconds: 10, rounds: 8), startedAt: start)
        XCTAssertEqual(schedule.endsAt, start.addingTimeInterval(240))
        XCTAssertEqual(schedule.progress(at: start).phase, .work)
        XCTAssertEqual(schedule.progress(at: start).remainingSeconds, 20)
        let rest = schedule.progress(at: start.addingTimeInterval(20))
        XCTAssertEqual(rest.phase, .rest)
        XCTAssertEqual(rest.remainingSeconds, 10)
        XCTAssertEqual(rest.phaseIndex, 1)
        let second = schedule.progress(at: start.addingTimeInterval(30))
        XCTAssertEqual(second.phase, .work)
        XCTAssertEqual(second.round, 2)
        XCTAssertEqual(schedule.progress(at: start.addingTimeInterval(239.5)).remainingSeconds, 1)
        XCTAssertEqual(schedule.progress(at: start.addingTimeInterval(240)).phase, .complete)
    }

    func testWakeAfterSuspensionResolvesCurrentPhase() {
        let schedule = IntervalSchedule(configuration: .thirtyThirty, startedAt: start)
        let progress = schedule.progress(at: start.addingTimeInterval(165))
        XCTAssertEqual(progress.phase, .rest)
        XCTAssertEqual(progress.round, 3)
        XCTAssertEqual(progress.phaseIndex, 5)
        XCTAssertEqual(progress.phaseEndsAt, start.addingTimeInterval(180))
        XCTAssertEqual(progress.remainingSeconds, 15)
    }

    @MainActor
    func testModelStartsWorkAndStopsItsSessionHooks() async {
        let firstWork = expectation(description: "First work phase")
        let ended = expectation(description: "Session ended")
        let model = IntervalTimerModel()
        let hooks = IntervalTimerHooks(changed: { _, progress in
            XCTAssertEqual(progress.phase, .work)
            XCTAssertEqual(progress.round, 1)
            firstWork.fulfill()
        }, ended: { _ in ended.fulfill() })
        await model.start(configuration: .thirtyThirty, hooks: hooks)
        let firstWorkResult = await XCTWaiter.fulfillment(of: [firstWork], timeout: 2)
        XCTAssertEqual(firstWorkResult, .completed)
        XCTAssertTrue(model.isRunning)
        XCTAssertNil(model.heartRate(at: Date()))
        await model.stop()
        let endedResult = await XCTWaiter.fulfillment(of: [ended], timeout: 2)
        XCTAssertEqual(endedResult, .completed)
        XCTAssertFalse(model.isRunning)
        XCTAssertNil(model.schedule)
        XCTAssertNil(model.progress)
    }

    @MainActor
    func testLiveHeartRateExpiresAndStopReleasesTheStream() async {
        let sampleTime = Date()
        let pair = AsyncStream<WorkoutSample>.makeStream()
        let released = expectation(description: "Live lease released")
        let received = expectation(description: "Live heart rate received")
        struct Source: WorkoutLiveSampleSource {
            let lease: WorkoutLiveSampleLease
            func acquire(generation: UUID) async throws -> WorkoutLiveSampleLease { lease }
        }
        let lease = WorkoutLiveSampleLease(generation: UUID(), stream: pair.stream) {
            pair.continuation.finish()
            released.fulfill()
        }
        let model = IntervalTimerModel()
        let observation = model.$latestSample.compactMap { $0 }.first().sink { _ in received.fulfill() }
        await model.start(configuration: .thirtyThirty, liveSource: Source(lease: lease))
        pair.continuation.yield(WorkoutSample(timestamp: sampleTime, heartRate: 128))
        let receivedResult = await XCTWaiter.fulfillment(of: [received], timeout: 2)
        XCTAssertEqual(receivedResult, .completed)
        XCTAssertEqual(model.heartRate(at: sampleTime), 128)
        XCTAssertNil(model.heartRate(at: sampleTime.addingTimeInterval(-1)))
        XCTAssertNil(model.heartRate(at: sampleTime.addingTimeInterval(11)))
        await model.stop()
        let releasedResult = await XCTWaiter.fulfillment(of: [released], timeout: 2)
        XCTAssertEqual(releasedResult, .completed)
        XCTAssertNil(model.heartRate(at: sampleTime))
        withExtendedLifetime(observation) {}
    }

    func testZeroRestOneRoundAndInputLimits() {
        let schedule = IntervalSchedule(configuration: .init(workSeconds: 1, restSeconds: 0, rounds: 3), startedAt: start)
        XCTAssertEqual(schedule.phaseStarts.count, 3)
        XCTAssertEqual(schedule.progress(at: start.addingTimeInterval(1)).round, 2)
        XCTAssertEqual(schedule.progress(at: start.addingTimeInterval(3)).phase, .complete)
        XCTAssertEqual(IntervalConfiguration(workSeconds: 20, restSeconds: 10, rounds: 1).duration, 30)
        XCTAssertFalse(IntervalConfiguration(workSeconds: 0).isValid)
        XCTAssertFalse(IntervalConfiguration(restSeconds: -1).isValid)
        XCTAssertFalse(IntervalConfiguration(rounds: 101).isValid)
    }
}
