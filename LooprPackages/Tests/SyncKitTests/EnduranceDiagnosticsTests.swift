import Foundation
import SyncKit
import XCTest

/// BLE-09 simulator-side endurance smoke coverage.  This is intentionally
/// logical time/data volume: a real 24-hour radio/energy measurement remains
/// the explicit hardware gate in the adoption checklist.
final class EnduranceDiagnosticsTests: XCTestCase {
    func testIntegratedRegressionEventStreamHasNoSafetyViolations() async {
        let recorder = ConnectionDiagnosticsRecorder(capacity: 64)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let events = [
            ConnectionDiagnosticsEvent(
                kind: .validFrame,
                timestamp: date,
                generation: 1
            ),
            ConnectionDiagnosticsEvent(
                kind: .writeStarted,
                timestamp: date,
                generation: 1,
                correlationID: "init-0"
            ),
            ConnectionDiagnosticsEvent(
                kind: .writeCompleted,
                timestamp: date,
                generation: 1,
                correlationID: "init-0"
            ),
            ConnectionDiagnosticsEvent(
                kind: .historyDrainStarted,
                timestamp: date,
                generation: 1,
                correlationID: "history-1"
            ),
            ConnectionDiagnosticsEvent(
                kind: .historyCommitted,
                timestamp: date,
                generation: 1,
                correlationID: "history-1"
            ),
            ConnectionDiagnosticsEvent(
                kind: .acknowledgementEmitted,
                timestamp: date,
                generation: 1,
                correlationID: "history-1"
            ),
            ConnectionDiagnosticsEvent(
                kind: .historyDrainCompleted,
                timestamp: date,
                generation: 1,
                correlationID: "history-1"
            ),
            ConnectionDiagnosticsEvent(
                kind: .staleConnection,
                timestamp: date.addingTimeInterval(30),
                generation: 1
            ),
            ConnectionDiagnosticsEvent(
                kind: .corruptFrame,
                timestamp: date.addingTimeInterval(30),
                generation: 1
            )
        ]

        for event in events {
            await recorder.record(event)
        }

        let snapshot = await recorder.snapshot()
        XCTAssertTrue(snapshot.isSafe, "integrated event stream violations: \(snapshot.violations)")
        XCTAssertEqual(snapshot.events.count, events.count)
    }

    func testLogicalEnduranceKeepsDiagnosticsBoundedAcrossManyCycles() async {
        let capacity = 256
        let recorder = ConnectionDiagnosticsRecorder(capacity: capacity)
        let date = Date(timeIntervalSince1970: 1_700_000_000)

        for cycle in 0..<10_000 {
            let suffix = String(cycle)
            let timestamp = date.addingTimeInterval(TimeInterval(cycle))
            await recorder.record(ConnectionDiagnosticsEvent(
                kind: .validFrame,
                timestamp: timestamp,
                generation: UInt64(cycle)
            ))
            await recorder.record(ConnectionDiagnosticsEvent(
                kind: .writeStarted,
                timestamp: timestamp,
                generation: UInt64(cycle),
                correlationID: "write-\(suffix)"
            ))
            await recorder.record(ConnectionDiagnosticsEvent(
                kind: .writeCompleted,
                timestamp: timestamp,
                generation: UInt64(cycle),
                correlationID: "write-\(suffix)"
            ))
            await recorder.record(ConnectionDiagnosticsEvent(
                kind: .historyDrainStarted,
                timestamp: timestamp,
                generation: UInt64(cycle),
                correlationID: "drain-\(suffix)"
            ))
            await recorder.record(ConnectionDiagnosticsEvent(
                kind: .historyCommitted,
                timestamp: timestamp,
                generation: UInt64(cycle),
                correlationID: "drain-\(suffix)"
            ))
            await recorder.record(ConnectionDiagnosticsEvent(
                kind: .acknowledgementEmitted,
                timestamp: timestamp,
                generation: UInt64(cycle),
                correlationID: "drain-\(suffix)"
            ))
            await recorder.record(ConnectionDiagnosticsEvent(
                kind: .historyDrainCompleted,
                timestamp: timestamp,
                generation: UInt64(cycle),
                correlationID: "drain-\(suffix)"
            ))
        }

        let snapshot = await recorder.snapshot()
        XCTAssertEqual(snapshot.events.count, capacity)
        XCTAssertTrue(snapshot.isSafe, "endurance audit violations: \(snapshot.violations)")
        XCTAssertEqual(snapshot.events.last?.generation, 9_999)
    }
}
