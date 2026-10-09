import BluetoothKit
import DesignSystem
import Foundation
import SyncKit
import Testing
@testable import Loopr

/// A healthy band must never read as "not connected" because one write failed,
/// and a reconnect that takes a second must not show anything at all.
struct RuntimeStateClassifierTests {
    private let peripheral = UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!

    private func state(
        connection: BluetoothConnectionState,
        running: Bool = true,
        lastError: String? = nil,
        pendingReconnect: ReconnectRequest? = nil,
        bondRepair: BluetoothBondRepairReason? = nil,
        radio: ConnectionRadioState = .poweredOn
    ) -> BluetoothAdoptionRuntimeState {
        BluetoothAdoptionRuntimeState(
            running: running, generation: 1, connection: connection,
            setupReady: true, setupComplete: true, radioState: radio,
            health: ConnectionHealthReport(healthy: true, stale: false, shouldBounce: false,
                                           ageOfLatestObservation: 1, corruptionRate: 0, reasons: []),
            pendingReconnect: pendingReconnect, liveConsumerCount: 0, pendingHistoryReplayCount: 0,
            validFrameCount: 1, corruptFrameCount: 0, writeTimeoutCount: 1, lastError: lastError,
            bondRepairRequired: bondRepair
        )
    }

    @Test
    func aTimedOutHeartbeatOnAListeningBandStaysConnected() {
        let listening = state(connection: .listening(generation: 1, peripheral: peripheral), lastError: "timedOut(20)")
        #expect(LooprRuntimeStateClassifier.appState(for: listening) == .ready(peripheral))
        #expect(LooprRuntimeStateClassifier.gen5AppState(for: listening) == .ready(peripheral))
    }

    @Test
    func aWriteErrorWhileTheLinkComesUpDoesNotEndIt() {
        let settingUp = state(connection: .settingUp(generation: 1, peripheral: peripheral), lastError: "timedOut(5)")
        #expect(LooprRuntimeStateClassifier.appState(for: settingUp) == .subscribing)
        let reconnecting = state(connection: .reconnecting(generation: 2), lastError: "outOfRange")
        guard case .disconnected = LooprRuntimeStateClassifier.appState(for: reconnecting) else {
            Issue.record("A reconnecting link must stay a quiet disconnect, not a failure")
            return
        }
    }

    @Test
    func anIdleLinkWithAReconnectScheduledIsNotAFailure() {
        let request = ReconnectRequest(id: UUID(), generation: 2, attempt: 1, delay: 1, requestedAt: Date())
        let idle = state(connection: .idle, lastError: "timedOut(20)", pendingReconnect: request)
        guard case .disconnected = LooprRuntimeStateClassifier.appState(for: idle) else {
            Issue.record("Expected a disconnect that is about to reconnect")
            return
        }
    }

    @Test
    func anErrorThatEndedTheSessionIsAFailure() {
        let stopped = state(connection: .idle, running: false, lastError: "timedOut(20)")
        guard case .failed(let copy) = LooprRuntimeStateClassifier.appState(for: stopped) else {
            Issue.record("A stopped session with an error must fail")
            return
        }
        #expect(!copy.contains("timedOut"))

        let abandoned = state(connection: .idle, lastError: "invalidState")
        guard case .failed = LooprRuntimeStateClassifier.appState(for: abandoned) else {
            Issue.record("An idle session with no reconnect scheduled must fail")
            return
        }
    }

    @Test
    func bondRepairAndBluetoothOffWin() {
        let repair = state(connection: .listening(generation: 1, peripheral: peripheral), bondRepair: .peerRemovedPairing)
        #expect(LooprRuntimeStateClassifier.appState(for: repair) == .failed(LooprBluetoothFailureCopy.bondRepair))
        let off = state(connection: .listening(generation: 1, peripheral: peripheral), radio: .poweredOff)
        #expect(LooprRuntimeStateClassifier.appState(for: off) == .bluetoothOff)
    }
}

struct BandLinkHysteresisTests {
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let identifier = UUID()

    private func signal(_ status: BluetoothApplicationStatus) -> BandLinkHysteresis.Signal {
        BandLinkHysteresis.signal(for: status, isPaired: true, isSyncing: false)
    }

    @Test
    func aBlipInsideTheGraceWindowNeverShowsDisconnected() {
        var hysteresis = BandLinkHysteresis(grace: 10)
        #expect(hysteresis.resolve(signal(.connected(identifier)), now: start) == .connected)

        let steps: [(BluetoothApplicationStatus, TimeInterval)] = [
            (.disconnected(identifier, reason: "lost"), 0.5),
            (.scanning, 1),
            (.connecting, 3),
            (.discovering, 6),
            (.subscribing, 9.5)
        ]
        for (status, offset) in steps {
            #expect(hysteresis.resolve(signal(status), now: start.addingTimeInterval(offset)) == .reconnecting)
        }
        #expect(hysteresis.resolve(signal(.connected(identifier)), now: start.addingTimeInterval(9.9)) == .connected)
        #expect(hysteresis.graceDeadline == nil)
    }

    @Test
    func aRealDisconnectShowsOnceTheGraceWindowCloses() {
        var hysteresis = BandLinkHysteresis(grace: 10)
        _ = hysteresis.resolve(signal(.connected(identifier)), now: start)
        let down = signal(.disconnected(identifier, reason: "lost"))
        #expect(hysteresis.resolve(down, now: start.addingTimeInterval(1)) == .reconnecting)
        #expect(hysteresis.graceDeadline == start.addingTimeInterval(11))
        #expect(hysteresis.resolve(down, now: start.addingTimeInterval(10.9)) == .reconnecting)
        #expect(hysteresis.resolve(down, now: start.addingTimeInterval(11)) == .disconnected)
        // Coming back is immediate.
        #expect(hysteresis.resolve(signal(.connected(identifier)), now: start.addingTimeInterval(30)) == .connected)
    }

    @Test
    func finalAnswersSkipTheGraceWindow() {
        var hysteresis = BandLinkHysteresis(grace: 10)
        #expect(hysteresis.resolve(signal(.bluetoothOff(identifier)), now: start) == .bluetoothOff)
        #expect(hysteresis.resolve(.notPaired, now: start) == .notPaired)
        #expect(hysteresis.resolve(signal(.failed("Fix it")), now: start) == .needsAttention("Fix it"))
        let experimental = signal(.disconnected(identifier, reason: BluetoothApplicationModel.experimentalSupportOffReason))
        #expect(hysteresis.resolve(experimental, now: start) == .needsAttention(BluetoothApplicationModel.experimentalSupportOffReason))
    }

    @Test
    func syncingIsALinkedState() {
        var hysteresis = BandLinkHysteresis(grace: 10)
        let syncing = BandLinkHysteresis.signal(for: .connected(identifier), isPaired: true, isSyncing: true)
        let state = hysteresis.resolve(syncing, now: start)
        #expect(state == .syncing)
        #expect(state.indicatorLink == .syncing)
        #expect(state.isConnectedOrQuiet)
    }

    @Test
    func launchInspectionIsQuietAndDoesNotRunTheClock() {
        var hysteresis = BandLinkHysteresis(grace: 10)
        #expect(hysteresis.resolve(signal(.checkingProvisioning), now: start) == .reconnecting)
        #expect(hysteresis.resolve(signal(.checkingProvisioning), now: start.addingTimeInterval(60)) == .reconnecting)
        #expect(hysteresis.graceDeadline == nil)
    }

    @Test
    func todayShowsACardOnlyAfterTheGraceWindow() {
        #expect(TodayBandConnectionCopy.card(for: .reconnecting, isPaired: true) == nil)
        #expect(TodayBandConnectionCopy.card(for: .connected, isPaired: true) == nil)
        #expect(TodayBandConnectionCopy.card(for: .syncing, isPaired: true) == nil)
        #expect(TodayBandConnectionCopy.card(for: .disconnected, isPaired: false) == nil)
        #expect(TodayBandConnectionCopy.card(for: .disconnected, isPaired: true)?.title == TodayBandConnectionCopy.title)
        #expect(TodayBandConnectionCopy.card(for: .bluetoothOff, isPaired: true)?.title == TodayBandConnectionCopy.bluetoothOffTitle)
    }
}

/// The observable presentation and its deadline, driven by the real model.
@MainActor
struct BandLinkPresentationTests {
    private let identifier = UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!

    @Test
    func theDeadlineReportsADownLinkWithoutAnotherStatusChange() async throws {
        let presentation = BandLinkPresentation(grace: 0.2)
        var disconnects = 0
        presentation.onDisconnected = { disconnects += 1 }
        presentation.update(status: .connected(identifier), isPaired: true, isSyncing: false,
                            canOfferPairing: false, bandModelName: "WHOOP 4.0", bandIsExperimental: false)
        #expect(presentation.state == .connected)

        presentation.update(status: .disconnected(identifier, reason: "lost"), isPaired: true, isSyncing: false,
                            canOfferPairing: false, bandModelName: "WHOOP 4.0", bandIsExperimental: false)
        #expect(presentation.state == .reconnecting)
        #expect(presentation.settingsSummary == "Connected")
        #expect(presentation.keepsLiveSession)

        try await waitUntil { presentation.state == .disconnected }
        #expect(presentation.indicator.link == .disconnected)
        #expect(disconnects == 1)
        #expect(!presentation.keepsLiveSession)
    }

    @Test
    func aBlipThatEndsInTimeNeverReportsADisconnect() async throws {
        let presentation = BandLinkPresentation(grace: 0.5)
        var disconnects = 0
        presentation.onDisconnected = { disconnects += 1 }
        let connected = BluetoothApplicationStatus.connected(identifier)
        presentation.update(status: connected, isPaired: true, isSyncing: false,
                            canOfferPairing: false, bandModelName: nil, bandIsExperimental: false)
        presentation.update(status: .connecting, isPaired: true, isSyncing: false,
                            canOfferPairing: false, bandModelName: nil, bandIsExperimental: false)
        try await Task.sleep(for: .milliseconds(100))
        presentation.update(status: connected, isPaired: true, isSyncing: false,
                            canOfferPairing: false, bandModelName: nil, bandIsExperimental: false)
        try await Task.sleep(for: .milliseconds(700))
        #expect(presentation.state == .connected)
        #expect(disconnects == 0)
    }

    @Test
    func batteryKeepsItsLastKnownValue() {
        let presentation = BandLinkPresentation(grace: 10)
        presentation.update(status: .connected(identifier), isPaired: true, isSyncing: false,
                            canOfferPairing: false, bandModelName: nil, bandIsExperimental: false)
        presentation.updateDetails(batteryPercent: 80, charging: false, lastSyncedAt: nil)
        presentation.updateDetails(batteryPercent: nil, charging: nil, lastSyncedAt: nil)
        #expect(presentation.indicator.batteryPercent == 80)
        #expect(presentation.indicator.charging == nil)
        presentation.updateDetails(batteryPercent: nil, charging: true, onWrist: false, lastSyncedAt: nil)
        #expect(presentation.settingsSummary == "Off wrist")
        presentation.updateDetails(batteryPercent: nil, charging: true, onWrist: true, lastSyncedAt: nil)
        #expect(presentation.settingsSummary == "Charging")
    }

    @Test
    func theModelReportsABlipAsConnectedAndARealDropAfterGrace() async throws {
        let runtime = PresentationTestRuntime()
        let model = BluetoothApplicationModel(
            provisioning: PresentationTestProvisioning(identifier: identifier),
            runtimeFactory: PresentationTestRuntimeFactory(runtime: runtime),
            bandLinkGrace: 0.4
        )
        await model.inspectProvisioningOnLaunch()
        await runtime.emit(.ready(identifier))
        try await waitUntil { model.bandLink.state == .connected }

        // Blip: down and straight back up.
        await runtime.emit(.disconnected("Lost the connection to your band. Reconnecting."))
        try await waitUntil { !model.status.isConnected }
        #expect(model.bandLink.state == .reconnecting)
        await runtime.emit(.ready(identifier))
        try await waitUntil { model.status.isConnected }
        #expect(model.bandLink.state == .connected)

        // A drop that lasts.
        await runtime.emit(.disconnected("Lost the connection to your band. Reconnecting."))
        try await waitUntil { !model.status.isConnected }
        #expect(model.bandLink.state == .reconnecting)
        try await waitUntil { model.bandLink.state == .disconnected }
        #expect(model.bandLink.settingsSummary == "Not connected")
    }

    @Test
    func theShellRuntimeHandleFollowsTheBoundRuntime() async {
        let runtime = PresentationTestRuntime()
        let model = BluetoothApplicationModel(
            provisioning: PresentationTestProvisioning(identifier: identifier),
            runtimeFactory: PresentationTestRuntimeFactory(runtime: runtime)
        )
        #expect(await model.runtimeHandle.hasBoundRuntime() == false)
        await model.inspectProvisioningOnLaunch()
        #expect(await model.runtimeHandle.hasBoundRuntime())
        await model.removePairing()
        #expect(await model.runtimeHandle.hasBoundRuntime() == false)
        #expect(model.bandLink.state == .notPaired)
    }

    private func waitUntil(timeout: Duration = .seconds(3), _ condition: @MainActor () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else {
                Issue.record("Timed out waiting for condition")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

private struct PresentationTestProvisioning: LooprAccessoryProvisioningFlow {
    let identifier: UUID

    func inspectExisting() async -> AccessoryProvisioningOutcome { .alreadyProvisioned(identifier) }
    func userTappedPair() async -> AccessoryProvisioningOutcome { .alreadyProvisioned(identifier) }
    func continueAfterExplanation() async -> AccessoryProvisioningOutcome { .alreadyProvisioned(identifier) }
    func removeProvisionedAccessory() async -> AccessoryProvisioningOutcome { .removed }
}

private struct PresentationTestRuntimeFactory: LooprBluetoothRuntimeFactory {
    let runtime: PresentationTestRuntime

    func makeRuntime(for identifier: UUID) async throws -> any LooprBluetoothAdoptionRuntime { runtime }
}

private actor PresentationTestRuntime: LooprBluetoothAdoptionRuntime, LooprDeviceCenterRuntime {
    private var current: LooprBluetoothRuntimeState = .idle
    private var continuation: AsyncStream<LooprBluetoothRuntimeState>.Continuation?

    func events() async -> AsyncStream<LooprBluetoothRuntimeState> {
        let pair = AsyncStream<LooprBluetoothRuntimeState>.makeStream()
        continuation = pair.continuation
        return pair.stream
    }

    func emit(_ state: LooprBluetoothRuntimeState) {
        current = state
        continuation?.yield(state)
    }

    func state() async -> LooprBluetoothRuntimeState { current }
    func start() async { continuation?.yield(current) }
    func stop() async {}
    func enterForeground() async {}
    func enterBackground() async {}
    func runBackground(kind: BackgroundRunKind) async -> Bool { true }
    func expireBackground() async {}

    func acquireLiveStream(kind: LiveStreamKind, consumer: LiveStreamConsumer) async throws -> LiveStreamConsumerHandle {
        throw HeartLiveStreamAdapterError.unavailable
    }

    func bufferedLiveSamples(for kind: LiveStreamKind) async -> [LiveStreamSample] { [] }
    func performManualSync(maxDuration: TimeInterval) async -> Bool { true }

    func runtimeState() async -> BluetoothAdoptionRuntimeState {
        LooprRuntimeHandle.unboundState
    }
}
