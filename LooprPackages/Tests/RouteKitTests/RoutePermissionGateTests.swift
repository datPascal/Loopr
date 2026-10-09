import RouteKit
import XCTest

private actor PermissionDenyingGate: LocationStartGate {
    func start() async throws { throw LocationGateError.permissionDenied }
    func stop() async {}
}

private actor AcceptingGate: LocationStartGate {
    private(set) var starts = 0
    func start() async { starts += 1 }
    func stop() async {}
    func startCount() -> Int { starts }
}

/// The shell used to pass `.authorized` without asking Core Location. The
/// recorder now takes the real answer, so `.notRequested` has to reach the
/// location gate rather than fail before the system prompt can appear.
final class RoutePermissionGateTests: XCTestCase {
    func testNotRequestedReachesTheLocationGate() async throws {
        let gate = AcceptingGate()
        let recorder = RouteRecorder(location: gate)
        try await recorder.start(workoutID: "w", activity: .run, permission: .notRequested)
        let starts = await gate.startCount()
        XCTAssertEqual(starts, 1)
        let state = await recorder.currentState()
        XCTAssertEqual(state, .recording)
    }

    func testNotRequestedStillFailsWhenTheGateReportsADenial() async {
        let recorder = RouteRecorder(location: PermissionDenyingGate())
        do {
            _ = try await recorder.start(workoutID: "w", activity: .run, permission: .notRequested)
            XCTFail("a denied prompt must not leave the recorder running")
        } catch RouteError.permissionDenied {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let state = await recorder.currentState()
        XCTAssertEqual(state, .permissionDenied)
    }

    func testKnownDenialStillFailsBeforeTouchingLocation() async {
        let gate = AcceptingGate()
        let recorder = RouteRecorder(location: gate)
        do {
            _ = try await recorder.start(workoutID: "w", activity: .run, permission: .denied)
            XCTFail("a known denial must fail fast")
        } catch RouteError.permissionDenied {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let starts = await gate.startCount()
        XCTAssertEqual(starts, 0)
    }
}
