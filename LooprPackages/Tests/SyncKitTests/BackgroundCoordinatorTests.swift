import Foundation
import SyncKit
import XCTest

private actor BackgroundEventLog {
    private(set) var events: [String] = []
    func append(_ event: String) { events.append(event) }
    func snapshot() -> [String] { events }
}

private actor RecordingBackgroundDriver: BackgroundWorkDriver {
    private(set) var actions: [BackgroundExpirationAction] = []
    private(set) var staleMarks = 0

    func performExpiration(_ action: BackgroundExpirationAction) async {
        actions.append(action)
    }

    func markConnectionStale() async { staleMarks += 1 }
    func recordedActions() -> [BackgroundExpirationAction] { actions }
    func recordedStaleMarks() -> Int { staleMarks }
}

private final class LockedCompletionCount: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var value = 0

    func increment() { lock.withLock { value += 1 } }
    func read() -> Int { lock.withLock { value } }
}

private actor NonCooperativeGate {
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func signal() {
        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume()
    }
}

final class BackgroundCoordinatorTests: XCTestCase {
    func testForegroundPreemptionWaitsForBackgroundBeforeGATTWork() async throws {
        let coordinator = BackgroundCoordinator()
        let log = BackgroundEventLog()
        let completionCount = LockedCompletionCount()
        let completion = BackgroundTaskCompletion { _ in completionCount.increment() }

        guard let handle = await coordinator.startBackground(
            kind: .processing,
            completion: completion,
            work: {
            await log.append("background-start")
            while !Task.isCancelled {
                await Task.yield()
            }
            await log.append("background-end")
            }
        ) else {
            return XCTFail("background task did not start")
        }

        while !(await log.snapshot().contains("background-start")) {
            await Task.yield()
        }
        _ = try await coordinator.runForeground {
            await log.append("foreground")
            return true
        }

        let events = await log.snapshot()
        XCTAssertEqual(events, ["background-start", "background-end", "foreground"])
        XCTAssertEqual(completionCount.read(), 1)
        XCTAssertTrue(handle.completion.isComplete)
        let state = await coordinator.currentState()
        XCTAssertEqual(state, .idle)
    }

    func testBackgroundTaskCompletionIsOneShot() async throws {
        let coordinator = BackgroundCoordinator()
        let completionCount = LockedCompletionCount()
        let completion = BackgroundTaskCompletion { _ in completionCount.increment() }
        guard let handle = await coordinator.startBackground(
            kind: .appRefresh,
            completion: completion,
            work: {}
        ) else {
            return XCTFail("background task did not start")
        }

        await handle.cancel()
        XCTAssertFalse(handle.completion.complete(success: true))
        XCTAssertEqual(completionCount.read(), 1)
        let state = await coordinator.currentState()
        XCTAssertEqual(state, .idle)
    }

    func testExpirationRunsExactPriorityAndReportsStale() async throws {
        let coordinator = BackgroundCoordinator()
        let driver = RecordingBackgroundDriver()
        let completionCount = LockedCompletionCount()
        let completion = BackgroundTaskCompletion { _ in completionCount.increment() }
        let started = await coordinator.startBackground(
            kind: .restoration,
            completion: completion,
            work: {
            while !Task.isCancelled { await Task.yield() }
            }
        )
        guard started != nil else {
            return XCTFail("background task did not start")
        }

        let expired = await coordinator.expireActive(driver: driver)
        XCTAssertTrue(expired)
        let actions = await driver.recordedActions()
        XCTAssertEqual(actions, [
            .completeOrRollbackTransaction,
            .preserveTokenAndCursor,
            .stopBLEWork,
            .checkpointActiveWorkout,
            .deferAnalyticsHealthWidgetsNotifications
        ])
        let staleMarks = await driver.recordedStaleMarks()
        let state = await coordinator.currentState()
        XCTAssertEqual(staleMarks, 1)
        XCTAssertEqual(state, .stale)
        XCTAssertEqual(completionCount.read(), 1)
    }

    func testExpirationReturnsWithinGracePeriodForNonCooperativeWork() async throws {
        let coordinator = BackgroundCoordinator(cancellationGraceNanoseconds: 20_000_000)
        let gate = NonCooperativeGate()
        let completionCount = LockedCompletionCount()
        let completion = BackgroundTaskCompletion { _ in completionCount.increment() }
        guard let handle = await coordinator.startBackground(
            kind: .processing,
            completion: completion,
            work: {
                // Deliberately ignores cancellation until the test releases
                // it; expiration must not await this closure indefinitely.
                await gate.wait()
            }
        ) else {
            return XCTFail("background task did not start")
        }

        let startedAt = Date()
        let expired = await coordinator.expireActive(driver: RecordingBackgroundDriver())
        let elapsed = Date().timeIntervalSince(startedAt)
        XCTAssertTrue(expired)
        XCTAssertLessThan(elapsed, 0.5)
        let stateAfterExpiration = await coordinator.currentState()
        XCTAssertEqual(stateAfterExpiration, .stale)
        let activeAfterExpiration = await coordinator.hasActiveBackgroundTask()
        XCTAssertTrue(activeAfterExpiration, "non-cooperative work is quarantined")
        XCTAssertEqual(completionCount.read(), 1)

        await gate.signal()
        for _ in 0..<100 {
            if !(await coordinator.hasActiveBackgroundTask()) { break }
            await Task.yield()
        }
        let activeAfterRelease = await coordinator.hasActiveBackgroundTask()
        XCTAssertFalse(activeAfterRelease)
        _ = handle
    }

    func testDiagnosticsAuditRejectsDangerousOpcodeStaleACKDoubleWriteAndDoubleDrain() async {
        let recorder = ConnectionDiagnosticsRecorder(capacity: 32)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        await recorder.record(ConnectionDiagnosticsEvent(
            kind: .writeStarted,
            timestamp: date,
            generation: 1,
            correlationID: "write-1"
        ))
        await recorder.record(ConnectionDiagnosticsEvent(
            kind: .writeStarted,
            timestamp: date,
            generation: 1,
            correlationID: "write-1"
        ))
        await recorder.record(ConnectionDiagnosticsEvent(
            kind: .historyDrainStarted,
            timestamp: date,
            generation: 1,
            correlationID: "drain-1"
        ))
        await recorder.record(ConnectionDiagnosticsEvent(
            kind: .historyDrainStarted,
            timestamp: date,
            generation: 1,
            correlationID: "drain-1"
        ))
        await recorder.record(ConnectionDiagnosticsEvent(
            kind: .dangerousOpcodeAttempt,
            timestamp: date,
            generation: 1,
            opcode: 0x1D
        ))
        await recorder.record(ConnectionDiagnosticsEvent(
            kind: .staleAcknowledgement,
            timestamp: date,
            generation: 1,
            correlationID: "batch-1"
        ))

        let snapshot = await recorder.snapshot()
        XCTAssertFalse(snapshot.isSafe)
        XCTAssertTrue(snapshot.violations.contains(.dangerousOpcode(0x1D)))
        XCTAssertTrue(snapshot.violations.contains(.doubleWrite("write-1")))
        XCTAssertTrue(snapshot.violations.contains(.doubleDrain("drain-1")))
        XCTAssertTrue(snapshot.violations.contains(.staleAcknowledgement("batch-1")))
    }

    func testDiagnosticsAuditAcceptsCommittedACKAndBalancedWritesAndDrains() async {
        let recorder = ConnectionDiagnosticsRecorder(capacity: 16)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let events = [
            ConnectionDiagnosticsEvent(kind: .historyDrainStarted, timestamp: date, generation: 3, correlationID: "batch-1"),
            ConnectionDiagnosticsEvent(kind: .historyCommitted, timestamp: date, generation: 3, correlationID: "batch-1"),
            ConnectionDiagnosticsEvent(kind: .acknowledgementEmitted, timestamp: date, generation: 3, correlationID: "batch-1"),
            ConnectionDiagnosticsEvent(kind: .historyDrainCompleted, timestamp: date, generation: 3, correlationID: "batch-1"),
            ConnectionDiagnosticsEvent(kind: .writeStarted, timestamp: date, generation: 3, correlationID: "write-1"),
            ConnectionDiagnosticsEvent(kind: .writeCompleted, timestamp: date, generation: 3, correlationID: "write-1")
        ]
        for event in events { await recorder.record(event) }
        let snapshot = await recorder.snapshot()
        XCTAssertTrue(snapshot.isSafe, "\(snapshot.violations)")
    }

    func testDiagnosticsInfersCrossGenerationStaleAcknowledgement() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let events = [
            ConnectionDiagnosticsEvent(
                kind: .historyCommitted,
                timestamp: date,
                generation: 1,
                correlationID: "batch-1"
            ),
            ConnectionDiagnosticsEvent(
                kind: .validFrame,
                timestamp: date.addingTimeInterval(1),
                generation: 2
            ),
            ConnectionDiagnosticsEvent(
                kind: .acknowledgementEmitted,
                timestamp: date.addingTimeInterval(2),
                generation: 1,
                correlationID: "batch-1"
            ),
            ConnectionDiagnosticsEvent(
                kind: .acknowledgementEmitted,
                timestamp: date.addingTimeInterval(3),
                generation: 2,
                correlationID: "batch-1"
            )
        ]

        let violations = ConnectionDiagnosticsAudit.violations(in: events)
        XCTAssertEqual(
            violations.filter {
                if case .staleAcknowledgement("batch-1") = $0 { return true }
                return false
            }.count,
            2
        )
        XCTAssertFalse(violations.contains(.acknowledgementBeforeCommit("batch-1")))
    }

    func testDiagnosticsStorageIsBoundedAndKeepsNewestEvents() async {
        let recorder = ConnectionDiagnosticsRecorder(capacity: 2)
        let first = Date(timeIntervalSince1970: 1_700_000_000)
        for offset in 0..<3 {
            await recorder.record(ConnectionDiagnosticsEvent(
                kind: .validFrame,
                timestamp: first.addingTimeInterval(TimeInterval(offset)),
                generation: 1
            ))
        }
        let events = await recorder.events()
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.map(\.timestamp.timeIntervalSince1970), [1_700_000_001, 1_700_000_002])
    }
}
