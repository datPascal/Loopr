import BluetoothKit
import Foundation
import SyncKit
import XCTest

private actor RecordingReconnectScheduler: ReconnectScheduling {
    private(set) var scheduled: [ReconnectRequest] = []
    private(set) var cancelled: [ReconnectRequest] = []

    func scheduleReconnect(_ request: ReconnectRequest) async { scheduled.append(request) }
    func cancelReconnect(_ request: ReconnectRequest) async { cancelled.append(request) }
    func recordedScheduled() -> [ReconnectRequest] { scheduled }
    func recordedCancelled() -> [ReconnectRequest] { cancelled }
}

final class ReconnectPolicyTests: XCTestCase {
    func testSetupWriteTimeoutDetectorPausesAfterThreeConsecutiveFailuresAndResetsOnSuccess() {
        var detector = SetupWriteTimeoutLoopDetector(threshold: 3)
        XCTAssertFalse(detector.recordTimeout())
        XCTAssertFalse(detector.recordTimeout())
        XCTAssertTrue(detector.recordTimeout())
        XCTAssertTrue(detector.isPaused)
        XCTAssertFalse(detector.recordTimeout(), "pause is latched until a successful setup")
        detector.recordSuccess()
        XCTAssertEqual(detector.consecutiveTimeouts, 0)
        XCTAssertFalse(detector.isPaused)
    }

    func testBondRecoveryPolicyMapsThreeFirstWriteTimeoutsAndTypedTransportFailures() {
        var policy = SetupBondRecoveryPolicy(timeoutThreshold: 3)
        XCTAssertNil(policy.recordFirstWriteTimeout())
        XCTAssertNil(policy.recordFirstWriteTimeout())
        XCTAssertEqual(policy.recordFirstWriteTimeout(), .firstWriteTimeoutLoop)
        XCTAssertEqual(policy.requiredRepair, .firstWriteTimeoutLoop)

        policy.recordFirstWriteSuccess()
        XCTAssertNil(policy.requiredRepair)
        XCTAssertEqual(policy.consecutiveFirstWriteTimeouts, 0)

        XCTAssertEqual(
            policy.recordTransportFailure(.insufficientAuthentication),
            .insufficientAuthentication
        )
        XCTAssertEqual(policy.requiredRepair, .insufficientAuthentication)

        policy.recordFirstWriteSuccess()
        XCTAssertEqual(
            policy.recordTransportFailure(.insufficientEncryption),
            .insufficientEncryption
        )
    }

    func testBackoffEscalatesAcrossGenerationsUntilSetupCompletes() async {
        // Every retry allocates a new connection generation. The delay has
        // to keep growing anyway; only a completed setup resets it.
        let controller = ReconnectController(jitterSource: FixedReconnectJitter())
        var delays: [TimeInterval] = []
        for generation in UInt64(1)...4 {
            guard let request = await controller.disconnected(generation: generation, now: Date()) else {
                return XCTFail("A disconnect with nothing pending must schedule a reconnect")
            }
            delays.append(request.delay)
            let consumed = await controller.consume(request)
            XCTAssertTrue(consumed)
        }
        XCTAssertEqual(delays, [2, 4, 8, 16])

        // On a real band the generation that finishes setup is newer than
        // the one that dropped.
        await controller.connected(generation: 5)
        let afterSuccess = await controller.disconnected(generation: 5, now: Date())
        XCTAssertEqual(afterSuccess?.delay, 2)
    }

    func testPeerRemovedPairingLatchesRepair() {
        var policy = SetupBondRecoveryPolicy()
        XCTAssertEqual(policy.recordTransportFailure(.peerRemovedPairing), .peerRemovedPairing)
        XCTAssertEqual(policy.requiredRepair, .peerRemovedPairing)
    }

    func testBondErrorsAreTypedForRepairGuidance() {
        XCTAssertTrue(TransportError.insufficientAuthentication.isBondFailure)
        XCTAssertTrue(TransportError.insufficientEncryption.isBondFailure)
        XCTAssertFalse(TransportError.writeFailed("other").isBondFailure)
    }

    func testConnectedButSilentPastThresholdIsStaleAndUnhealthy() {
        let evaluator = ConnectionHealthEvaluator()
        let now = Date(timeIntervalSince1970: 1_700_000_120)
        let input = ConnectionLivenessInput(
            radioState: .poweredOn,
            lastValidFrameAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastHistoricalCommitAt: Date(timeIntervalSince1970: 1_700_000_000),
            validFrameCount: 10,
            expectedCharacteristicsReady: true
        )

        let report = evaluator.evaluate(input: input, now: now)
        XCTAssertFalse(report.healthy)
        XCTAssertTrue(report.stale)
        XCTAssertTrue(report.shouldBounce)
        XCTAssertTrue(report.reasons.contains(.staleObservation))
        XCTAssertNotNil(report.ageOfLatestObservation)
        XCTAssertEqual(report.ageOfLatestObservation ?? .nan, 120, accuracy: 0.0001)
    }

    func testBluetoothOffAndOutOfRangeRemainDistinct() {
        let evaluator = ConnectionHealthEvaluator()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let common: (ConnectionRadioState) -> ConnectionLivenessInput = { state in
            ConnectionLivenessInput(
                radioState: state,
                lastValidFrameAt: base,
                lastHistoricalCommitAt: base,
                expectedCharacteristicsReady: true
            )
        }

        let off = evaluator.evaluate(input: common(.poweredOff), now: base)
        let range = evaluator.evaluate(input: common(.outOfRange), now: base)
        XCTAssertTrue(off.reasons.contains(.radioUnavailable))
        XCTAssertFalse(off.reasons.contains(.outOfRange))
        XCTAssertTrue(range.reasons.contains(.outOfRange))
        XCTAssertFalse(range.reasons.contains(.radioUnavailable))
    }

    func testHealthConsumesReadinessCommitCorruptionAndWriteTimeoutSignals() {
        let evaluator = ConnectionHealthEvaluator()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let input = ConnectionLivenessInput(
            radioState: .poweredOn,
            lastValidFrameAt: base,
            lastHistoricalCommitAt: base.addingTimeInterval(10),
            validFrameCount: 16,
            corruptFrameCount: 4,
            writeTimeoutCount: 1,
            expectedCharacteristicsReady: false
        )

        let report = evaluator.evaluate(input: input, now: base.addingTimeInterval(20))
        XCTAssertFalse(report.healthy)
        XCTAssertFalse(report.stale, "recent commit/frame activity is not stale yet")
        XCTAssertFalse(report.shouldBounce)
        XCTAssertEqual(report.ageOfLatestObservation ?? .nan, 10, accuracy: 0.0001)
        XCTAssertEqual(report.corruptionRate, 0.2, accuracy: 0.0001)
        XCTAssertTrue(report.reasons.contains(.characteristicsNotReady))
        XCTAssertTrue(report.reasons.contains(.corruptionObserved))
        XCTAssertTrue(report.reasons.contains(.writeTimeoutObserved))
        XCTAssertEqual(report.ageOfLastValidFrame ?? .nan, 20, accuracy: 0.0001)
        XCTAssertEqual(report.ageOfLastHistoricalCommit ?? .nan, 10, accuracy: 0.0001)
    }

    func testRollingCorruptionUsesEdgeWindowAndRecoversAfterBadFramesAgeOut() {
        var detector = RollingCorruptionDetector()
        for _ in 0..<16 { _ = detector.record(validFrame: true) }
        var state = ConnectionCorruptionState()
        for _ in 0..<4 { state = detector.record(validFrame: false) }
        XCTAssertEqual(state.sampleCount, 20)
        XCTAssertEqual(state.corruptCount, 4)
        XCTAssertTrue(state.thresholdExceeded)

        // A 50-frame detector can only forget every old corrupt sample after
        // 50 subsequent valid observations have replaced the whole window.
        for _ in 0..<50 { state = detector.record(validFrame: true) }
        XCTAssertEqual(state.sampleCount, 50)
        XCTAssertEqual(state.corruptCount, 0)
        XCTAssertFalse(state.thresholdExceeded)

        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let input = ConnectionLivenessInput(
            radioState: .poweredOn,
            lastValidFrameAt: base,
            lastHistoricalCommitAt: base,
            expectedCharacteristicsReady: true,
            rollingCorruption: state
        )
        let report = ConnectionHealthEvaluator().evaluate(
            input: input,
            now: base.addingTimeInterval(1)
        )
        XCTAssertTrue(report.healthy)
        XCTAssertFalse(report.reasons.contains(.corruptionObserved))
    }

    func testHistoricalCommitCannotMaskSilentLinkRX() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let input = ConnectionLivenessInput(
            radioState: .poweredOn,
            lastValidFrameAt: base,
            lastHistoricalCommitAt: base.addingTimeInterval(29),
            expectedCharacteristicsReady: true
        )
        let report = ConnectionHealthEvaluator().evaluate(
            input: input,
            now: base.addingTimeInterval(31)
        )
        XCTAssertTrue(report.stale)
        XCTAssertTrue(report.reasons.contains(.staleObservation))
        XCTAssertEqual(report.ageOfLatestObservation ?? .nan, 2, accuracy: 0.0001)
        XCTAssertEqual(report.ageOfLastValidFrame ?? .nan, 31, accuracy: 0.0001)
    }

    func testAllGateTimingDefaultsFireAtExactBounds() {
        let evaluator = ConnectionHealthEvaluator()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let before = base.addingTimeInterval(-1)

        XCTAssertFalse(evaluator.shouldReclaimStaleConnection(lastObservationAt: before, now: base))
        XCTAssertTrue(evaluator.shouldReclaimStaleConnection(
            lastObservationAt: base.addingTimeInterval(-ReconnectTimingDefaults.staleConnectionReclamation),
            now: base
        ))
        XCTAssertFalse(evaluator.shouldLivenessBounce(
            lastObservationAt: base.addingTimeInterval(-ReconnectTimingDefaults.livenessBounce + 0.001),
            now: base
        ))
        XCTAssertTrue(evaluator.shouldLivenessBounce(
            lastObservationAt: base.addingTimeInterval(-ReconnectTimingDefaults.livenessBounce),
            now: base
        ))
        XCTAssertTrue(evaluator.shouldRequestPeriodicHistory(
            lastRequestAt: base.addingTimeInterval(-ReconnectTimingDefaults.periodicHistoryRequest),
            now: base
        ))
        XCTAssertTrue(evaluator.foregroundBackfillAllowed(
            lastRequestAt: base.addingTimeInterval(-ReconnectTimingDefaults.foregroundBackfillFloor),
            now: base
        ))
        XCTAssertTrue(evaluator.offloadIsStalled(
            startedAt: base.addingTimeInterval(-ReconnectTimingDefaults.stalledOffloadDetection),
            now: base
        ))
        XCTAssertTrue(evaluator.continuationExpired(
            startedAt: base.addingTimeInterval(-ReconnectTimingDefaults.continuationWindow),
            now: base
        ))
    }

    func testBackoffIsExactlyTwoFourEightSixteenThirtySecondsPlusInjectedJitter() async {
        let scheduler = RecordingReconnectScheduler()
        let fixedID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let controller = ReconnectController(
            scheduler: scheduler,
            jitterSource: FixedReconnectJitter(value: 0.125),
            makeID: { fixedID }
        )
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let expected = [2.125, 4.125, 8.125, 16.125, 30.125]

        for (index, delay) in expected.enumerated() {
            let request = await controller.disconnected(generation: 7, now: now.addingTimeInterval(Double(index)))
            XCTAssertEqual(request?.attempt, index)
            XCTAssertEqual(request?.delay ?? -1, delay, accuracy: 0.0001)
            if let request {
                let consumed = await controller.consume(request)
                XCTAssertTrue(consumed)
            }
        }
        let currentAttempt = await controller.currentAttempt()
        XCTAssertEqual(currentAttempt, 4)
        let scheduled = await scheduler.recordedScheduled()
        XCTAssertEqual(scheduled.map(\.delay), expected)
    }

    func testEdgeJitterIsBoundedToTwentyPercentWithDeterministicRandom() {
        let policy = ReconnectPolicy()
        XCTAssertEqual(
            policy.delay(forAttempt: 1, random: FixedReconnectRandom(value: -10_000)),
            2.0,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            policy.delay(forAttempt: 1, random: FixedReconnectRandom(value: 10_000)),
            2.4,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            policy.delay(forAttempt: 2, random: FixedReconnectRandom(value: -10_000)),
            3.2,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            policy.delay(forAttempt: 2, random: FixedReconnectRandom(value: 10_000)),
            4.8,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            policy.delay(forAttempt: 5, random: FixedReconnectRandom(value: 10_000)),
            30.0,
            accuracy: 0.0001
        )
    }

    func testStaleGenerationCannotResetReconnectAttemptOrCancelCurrentRequest() async {
        let scheduler = RecordingReconnectScheduler()
        let controller = ReconnectController(
            scheduler: scheduler,
            randomSource: FixedReconnectRandom(value: 0)
        )
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        guard let request = await controller.disconnected(generation: 5, now: now) else {
            return XCTFail("expected reconnect request")
        }
        var currentAttempt = await controller.currentAttempt()
        XCTAssertEqual(currentAttempt, 1)

        // Stale means older than the generation that dropped. A newer one
        // is the reconnect itself and must reset, which the next test covers.
        await controller.connected(generation: 4)
        currentAttempt = await controller.currentAttempt()
        XCTAssertEqual(currentAttempt, 1)
        let pendingAfterStaleConnect = await controller.pendingRequest()
        XCTAssertNotNil(pendingAfterStaleConnect)
        let cancelledAfterStaleConnect = await scheduler.recordedCancelled()
        XCTAssertTrue(cancelledAfterStaleConnect.isEmpty)

        await controller.connected(generation: 5)
        currentAttempt = await controller.currentAttempt()
        XCTAssertEqual(currentAttempt, 0)
        let pendingAfterConnect = await controller.pendingRequest()
        XCTAssertNil(pendingAfterConnect)
        let cancelledAfterConnect = await scheduler.recordedCancelled()
        XCTAssertEqual(cancelledAfterConnect, [request])
    }

    func testConnectedWithStaleGenerationCannotResetAfterRequestWasConsumed() async {
        let controller = ReconnectController(randomSource: FixedReconnectRandom(value: 0))
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        guard let request = await controller.disconnected(generation: 11, now: now) else {
            return XCTFail("expected reconnect request")
        }
        let consumed = await controller.consume(request)
        XCTAssertTrue(consumed)
        var currentAttempt = await controller.currentAttempt()
        XCTAssertEqual(currentAttempt, 1)
        await controller.connected(generation: 10)
        currentAttempt = await controller.currentAttempt()
        XCTAssertEqual(currentAttempt, 1)
        // The runtime allocates a newer generation for every reconnect, so
        // the setup that succeeds always carries one. It must reset.
        await controller.connected(generation: 13)
        currentAttempt = await controller.currentAttempt()
        XCTAssertEqual(currentAttempt, 0)
    }

    func testDisconnectStormSchedulesOnlyOnePendingReconnect() async {
        let scheduler = RecordingReconnectScheduler()
        let controller = ReconnectController(scheduler: scheduler)
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let first = await controller.disconnected(generation: 1, now: now)
        let duplicateOne = await controller.disconnected(generation: 1, now: now)
        let duplicateTwo = await controller.disconnected(generation: 2, now: now)
        XCTAssertNotNil(first)
        XCTAssertNil(duplicateOne)
        XCTAssertNil(duplicateTwo)
        let scheduledCount = (await scheduler.recordedScheduled()).count
        XCTAssertEqual(scheduledCount, 1)

        if let first {
            await controller.connected(generation: first.generation)
        }
        let cancelledCount = (await scheduler.recordedCancelled()).count
        let currentAttempt = await controller.currentAttempt()
        XCTAssertEqual(cancelledCount, 1)
        XCTAssertEqual(currentAttempt, 0)
    }
}
