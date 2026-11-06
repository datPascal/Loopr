import Combine
import Foundation
import WorkoutKit
import XCTest

final class IntervalTimerTests: XCTestCase, @unchecked Sendable {
    private let start = Date(timeIntervalSince1970: 100)

    func testWorkRestBoundariesAndNoRestAfterTheLastRound() {
        // Eight rounds of 20/10 end after the eighth work interval: 8 x 20 + 7 x 10 (R2-VET-05).
        let schedule = IntervalSchedule(configuration: .init(workSeconds: 20, restSeconds: 10, rounds: 8), startedAt: start)
        XCTAssertEqual(schedule.endsAt, start.addingTimeInterval(230))
        XCTAssertEqual(schedule.progress(at: start).phase, .work)
        XCTAssertEqual(schedule.progress(at: start).remainingSeconds, 20)
        let rest = schedule.progress(at: start.addingTimeInterval(20))
        XCTAssertEqual(rest.phase, .rest)
        XCTAssertEqual(rest.remainingSeconds, 10)
        XCTAssertEqual(rest.phaseIndex, 1)
        let second = schedule.progress(at: start.addingTimeInterval(30))
        XCTAssertEqual(second.phase, .work)
        XCTAssertEqual(second.round, 2)
        XCTAssertEqual(schedule.progress(at: start.addingTimeInterval(229.5)).remainingSeconds, 1)
        XCTAssertEqual(schedule.progress(at: start.addingTimeInterval(230)).phase, .complete)
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

    @MainActor
    func testOldStopCannotClearANewTimer() async {
        let gate = IntervalLifecycleGate()
        let model = IntervalTimerModel()
        await model.start(configuration: .thirtyThirty, hooks: .init(ended: { _ in await gate.enter() }))
        let stopping = Task { await model.stop() }
        await gate.waitForEntry()
        await model.start(configuration: .tabata)
        XCTAssertEqual(model.schedule?.configuration, .tabata)
        await gate.release()
        await stopping.value
        XCTAssertTrue(model.isRunning)
        XCTAssertEqual(model.schedule?.configuration, .tabata)
        await model.stop()
    }

    @MainActor
    func testCancelledStartDoesNotLeaveATimerRunning() async {
        let gate = IntervalLifecycleGate()
        let model = IntervalTimerModel()
        let starting = Task {
            await model.start(configuration: .thirtyThirty, hooks: .init(started: { _, _ in await gate.enter() }))
        }
        await gate.waitForEntry()
        starting.cancel()
        await gate.release()
        await starting.value
        XCTAssertFalse(model.isRunning)
        XCTAssertNil(model.schedule)
        await model.stop()
    }

    @MainActor
    func testCancelledSensorAcquisitionStopsTheTimer() async {
        struct Source: WorkoutLiveSampleSource {
            func acquire(generation: UUID) async throws -> WorkoutLiveSampleLease { throw CancellationError() }
        }
        let model = IntervalTimerModel()
        await model.start(configuration: .thirtyThirty, liveSource: Source())
        XCTAssertFalse(model.isRunning)
        XCTAssertNil(model.schedule)
    }

    func testZeroRestOneRoundAndInputLimits() {
        let schedule = IntervalSchedule(configuration: .init(workSeconds: 1, restSeconds: 0, rounds: 3), startedAt: start)
        XCTAssertEqual(schedule.phaseStarts.count, 3)
        XCTAssertEqual(schedule.progress(at: start.addingTimeInterval(1)).round, 2)
        XCTAssertEqual(schedule.progress(at: start.addingTimeInterval(3)).phase, .complete)
        XCTAssertEqual(IntervalConfiguration(workSeconds: 20, restSeconds: 10, rounds: 1).duration, 20)
        XCTAssertFalse(IntervalConfiguration(workSeconds: 0).isValid)
        XCTAssertFalse(IntervalConfiguration(restSeconds: -1).isValid)
        XCTAssertFalse(IntervalConfiguration(rounds: 101).isValid)
    }
}

private actor IntervalLifecycleGate {
    private var entered = false
    private var entry: CheckedContinuation<Void, Never>?
    private var blocked: CheckedContinuation<Void, Never>?
    func enter() async {
        entered = true
        entry?.resume(); entry = nil
        await withCheckedContinuation { blocked = $0 }
    }
    func waitForEntry() async {
        if !entered { await withCheckedContinuation { entry = $0 } }
    }
    func release() { blocked?.resume(); blocked = nil }
}
