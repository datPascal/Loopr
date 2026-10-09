import XCTest
import Foundation
import BluetoothKit
import DeviceCenterKit
import SyncKit
@testable import Loopr

/// Launch behaviour of the Today band card. A band Loopr already knows must
/// never be reported as not connected while its link is still coming up, and
/// the card must stay away entirely until that attempt has had its window.
@MainActor
final class LaunchConnectionStatusTests: XCTestCase {
    private let identifier = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!

    func testKnownBandShowsNoCardBeforeTheLinkResolves() async {
        let runtime = LaunchTestRuntime(initialState: .idle)
        let model = BluetoothApplicationModel(
            provisioning: LaunchTestProvisioning(inspect: .alreadyProvisioned(identifier)),
            runtimeFactory: LaunchTestRuntimeFactory(runtime: runtime)
        )

        await model.inspectProvisioningOnLaunch()

        // The runtime reports idle, which becomes a disconnected status. The
        // surface must still be waiting rather than reporting the band down.
        XCTAssertEqual(model.provisionedIdentifier, identifier)
        XCTAssertFalse(model.status.isConnected)
        XCTAssertTrue(model.isResolvingBandLink)
        XCTAssertNil(
            TodayBandConnectionCopy.message(
                isPaired: model.provisionedIdentifier != nil,
                isConnected: model.status.isConnected,
                isResolvingLink: model.isResolvingBandLink
            )
        )
    }

    func testLinkComingUpEndsTheWaitAndReportsTheBandConnected() async {
        let runtime = LaunchTestRuntime(initialState: .idle)
        let model = BluetoothApplicationModel(
            provisioning: LaunchTestProvisioning(inspect: .alreadyProvisioned(identifier)),
            runtimeFactory: LaunchTestRuntimeFactory(runtime: runtime)
        )
        await model.inspectProvisioningOnLaunch()
        XCTAssertTrue(model.isResolvingBandLink)

        await runtime.set(.ready(identifier))
        await model.enterForeground()

        XCTAssertTrue(model.status.isConnected)
        XCTAssertFalse(model.isResolvingBandLink)
        XCTAssertNil(TodayBandConnectionCopy.message(
            isPaired: true, isConnected: model.status.isConnected,
            isResolvingLink: model.isResolvingBandLink
        ))
    }

    /// A link that drops after it came up gets the same grace, so a reconnect
    /// that takes a second does not flash a card over the rings.
    func testADroppedLinkReopensTheGraceWindow() async {
        let runtime = LaunchTestRuntime(initialState: .idle)
        let model = BluetoothApplicationModel(
            provisioning: LaunchTestProvisioning(inspect: .alreadyProvisioned(identifier)),
            runtimeFactory: LaunchTestRuntimeFactory(runtime: runtime)
        )
        await model.inspectProvisioningOnLaunch()
        await runtime.set(.ready(identifier))
        await model.enterForeground()
        XCTAssertTrue(model.status.isConnected)
        XCTAssertFalse(model.isResolvingBandLink)

        await runtime.set(.disconnected("The band moved out of range."))
        await model.enterForeground()

        XCTAssertFalse(model.status.isConnected)
        XCTAssertTrue(model.isResolvingBandLink)
        XCTAssertNil(TodayBandConnectionCopy.message(
            isPaired: true, isConnected: model.status.isConnected,
            isResolvingLink: model.isResolvingBandLink
        ))
    }

    func testAResolvedDownLinkStillSaysTheBandIsNotConnected() {
        XCTAssertEqual(TodayBandConnectionCopy.title, "Band not connected")
        let message = TodayBandConnectionCopy.message(isPaired: true, isConnected: false, isResolvingLink: false)
        XCTAssertEqual(message?.hasPrefix("Your band is paired but has not connected yet."), true)
    }

    func testForegroundEntryWaitsForLaunchInspectionBeforeReconnecting() async {
        let runtime = LaunchTestRuntime(initialState: .idle)
        let model = BluetoothApplicationModel(
            provisioning: LaunchTestProvisioning(inspect: .alreadyProvisioned(identifier)),
            runtimeFactory: LaunchTestRuntimeFactory(runtime: runtime)
        )

        // A scene can activate before the launch task has installed the runtime.
        await model.enterForeground()

        XCTAssertTrue(model.didFinishLaunchInspection)
        let events = await runtime.lifecycleEvents()
        XCTAssertEqual(events, ["start", "foreground"])
    }

    func testReturningFromBackgroundRestartsTheExistingRuntime() async {
        let runtime = LaunchTestRuntime(initialState: .idle)
        let model = BluetoothApplicationModel(
            provisioning: LaunchTestProvisioning(inspect: .alreadyProvisioned(identifier)),
            runtimeFactory: LaunchTestRuntimeFactory(runtime: runtime)
        )

        await model.enterForeground()
        await model.enterBackground()
        await model.enterForeground()

        let events = await runtime.lifecycleEvents()
        XCTAssertEqual(events, ["start", "foreground", "background", "foreground"])
    }

    func testAnUnpairedPhoneShowsNoBandCard() {
        XCTAssertNil(TodayBandConnectionCopy.message(isPaired: false, isConnected: false, isResolvingLink: false))
        XCTAssertNil(TodayBandConnectionCopy.message(isPaired: false, isConnected: false, isResolvingLink: true))
    }
}

private struct LaunchTestProvisioning: LooprAccessoryProvisioningFlow {
    let inspect: AccessoryProvisioningOutcome

    func inspectExisting() async -> AccessoryProvisioningOutcome { inspect }
    func userTappedPair() async -> AccessoryProvisioningOutcome { inspect }
    func continueAfterExplanation() async -> AccessoryProvisioningOutcome { inspect }
    func removeProvisionedAccessory() async -> AccessoryProvisioningOutcome { .removed }
}

private struct LaunchTestRuntimeFactory: LooprBluetoothRuntimeFactory {
    let runtime: LaunchTestRuntime

    func makeRuntime(for identifier: UUID) async throws -> any LooprBluetoothAdoptionRuntime { runtime }
}

private actor LaunchTestRuntime: LooprBluetoothAdoptionRuntime, LooprDeviceCenterRuntime {
    private var current: LooprBluetoothRuntimeState
    private var continuation: AsyncStream<LooprBluetoothRuntimeState>.Continuation?
    private var recordedLifecycleEvents: [String] = []

    init(initialState: LooprBluetoothRuntimeState) { current = initialState }

    func events() async -> AsyncStream<LooprBluetoothRuntimeState> {
        let pair = AsyncStream<LooprBluetoothRuntimeState>.makeStream()
        continuation = pair.continuation
        return pair.stream
    }

    func state() async -> LooprBluetoothRuntimeState { current }
    func set(_ state: LooprBluetoothRuntimeState) { current = state }
    func start() async { recordedLifecycleEvents.append("start"); continuation?.yield(current) }
    func stop() async {}
    func enterForeground() async { recordedLifecycleEvents.append("foreground") }
    func enterBackground() async { recordedLifecycleEvents.append("background") }
    func lifecycleEvents() -> [String] { recordedLifecycleEvents }
    func runBackground(kind: BackgroundRunKind) async -> Bool { true }
    func expireBackground() async {}

    func acquireLiveStream(kind: LiveStreamKind, consumer: LiveStreamConsumer) async throws -> LiveStreamConsumerHandle {
        throw HeartLiveStreamAdapterError.unavailable
    }

    func bufferedLiveSamples(for kind: LiveStreamKind) async -> [LiveStreamSample] { [] }

    func performManualSync(maxDuration: TimeInterval) async -> Bool { true }

    func runtimeState() async -> BluetoothAdoptionRuntimeState {
        BluetoothAdoptionRuntimeState(
            running: true, generation: 1,
            connection: .listening(generation: 1, peripheral: UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!),
            setupReady: true, setupComplete: true, radioState: .poweredOn,
            health: ConnectionHealthReport(healthy: true, stale: false, shouldBounce: false,
                                           ageOfLatestObservation: 1, corruptionRate: 0, reasons: []),
            pendingReconnect: nil, liveConsumerCount: 0, pendingHistoryReplayCount: 0,
            validFrameCount: 1, corruptFrameCount: 0, writeTimeoutCount: 0, lastError: nil
        )
    }
}
