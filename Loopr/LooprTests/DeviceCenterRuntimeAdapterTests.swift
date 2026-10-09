import AnalyticsKit
import BluetoothKit
import DeviceCenterKit
import Foundation
import ProtocolKit
import SyncKit
import Testing
@testable import Loopr

@MainActor
struct DeviceCenterRuntimeAdapterTests {
    @Test
    func sharedHandleForwardsSharingAndRefusesAfterUnbinding() async throws {
        let runtime = TestDeviceCenterRuntime(state: RuntimeStateFactory.readyState)
        let handle = LooprRuntimeHandle()
        handle.bind(runtime)
        let confirmation = try await handle.setHeartRateSharing(enabled: true)
        #expect(confirmation == nil)
        #expect(await runtime.sharingWrites() == [true])
        handle.bind(nil)
        do {
            _ = try await handle.setHeartRateSharing(enabled: false)
            Issue.record("An unbound handle must not write")
        } catch {
            #expect(error as? LooprDeviceRuntimeCommandError == .unavailable)
        }
    }

    @Test
    func sharingChoiceQueuesPersistsAndReappliesAfterReconnect() async throws {
        let suite = "band-link-tests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let down = RuntimeStateFactory.make(connection: .outOfRange, setupComplete: false, stale: true)
        let runtime = TestDeviceCenterRuntime(state: down)
        let service = LooprHeartRateSharingService(runtime: runtime, defaults: defaults)
        await service.setEnabled(true)
        #expect(service.requested == true)
        #expect(service.confirmed == nil)
        #expect(service.message == "Waiting for the next connection.")
        #expect(await runtime.sharingWrites() == [])
        let reopened = LooprHeartRateSharingService(runtime: runtime, defaults: defaults)
        #expect(reopened.requested == true)
        await runtime.setState(RuntimeStateFactory.readyState)
        await service.reconcile()
        #expect(await runtime.sharingWrites() == [true])
        #expect(service.message == "Sent. This band doesn't confirm the change.")
        await service.reconcile()
        #expect(await runtime.sharingWrites() == [true])
        await runtime.setState(down)
        await service.reconcile()
        await runtime.setState(RuntimeStateFactory.readyState)
        await service.reconcile()
        #expect(await runtime.sharingWrites() == [true, true])
        await runtime.setSharingConfirmation(false)
        await service.setEnabled(false)
        #expect(service.confirmed == false)
        #expect(service.message == "Off, confirmed by the band.")
        await service.setEnabled(true)
        #expect(service.confirmed == false)
        #expect(service.enabled == true)
        #expect(service.message == "The band reports sharing is off. Try again.")
    }

    @Test
    func batteryLogKeepsEventChargingAndDropsOldGenerations() async throws {
        let log = TestChargingBatteryLog()
        let runtime = TestDeviceCenterRuntime(state: RuntimeStateFactory.readyState)
        let repository = RuntimeDeviceCenterRepository(base: InMemoryDeviceCenterRepository(),
            runtime: runtime, batteryLog: log)
        let date = Date(timeIntervalSince1970: 1_750_000_000)
        await repository.recordBandState(.init(eventID: 7, generation: 1, receivedAt: date,
            bandEpochSeconds: nil, batteryPercentage: 78, charging: true))
        await repository.recordBandState(.init(eventID: 8, generation: 0, receivedAt: date,
            bandEpochSeconds: nil, batteryPercentage: 77, charging: false))
        let samples = await log.samples(through: date)
        #expect(samples.count == 1)
        #expect(samples.first?.charging == true)
        #expect(samples.first?.pct == 78)
    }

    @Test
    func runtimeChargingAndWristEvidenceReplaceStoredState() {
        let state = RuntimeStateFactory.make(connection: .listening(generation: 1, peripheral: RuntimeStateFactory.peripheral),
            stale: false, charging: true, onWrist: false)
        let result = DeviceCenterRuntimeProjection.status(existing: DeviceCenterStateFixtures.populatedStatus,
            state: state, now: Date())
        #expect(result.charging == true)
        #expect(result.wristState == .notWorn)
        #expect(result.batteryForecast == .absent)
        let unknown = DeviceCenterRuntimeProjection.status(existing: result,
            state: RuntimeStateFactory.readyState, now: Date())
        #expect(unknown.charging == nil)
        #expect(unknown.wristState == .unknown)
    }

    @Test
    func experimentalBandKeepsHistoryAndLocalActionsButHidesUnverifiedCommands() {
        let state = RuntimeStateFactory.make(
            connection: .listening(generation: 1, peripheral: RuntimeStateFactory.peripheral),
            stale: false,
            bandModel: .whoopMG
        )
        let projected = DeviceCenterRuntimeProjection.identity(existing: nil, state: state)
        #expect(projected?.generation == .betaMG)
        #expect(projected?.modelName == "WHOOP MG")
        #expect(projected?.capabilities.status(for: .manualSync) == .supported)
        for action in [DeviceAction.rename, .findMyStrap, .strapAlarmSetup, .strapAlarmReadback] {
            #expect(projected?.capabilities.status(for: action) == .notInLoopr)
        }
    }

    @Test
    func readyRuntimeProjectsOnlyVerifiedCapabilities() async {
        let state = RuntimeStateFactory.make(connection: .listening(generation: 1, peripheral: RuntimeStateFactory.peripheral), stale: false)
        let identity = DeviceCenterStateFixtures.sampleDevice
        let projected = DeviceCenterRuntimeProjection.identity(existing: identity, state: state)

        #expect(projected?.capabilities.status(for: .manualSync) == .supported)
        #expect(projected?.capabilities.status(for: .forgetBand) == .supported)
        #expect(projected?.capabilities.status(for: .deprovision) == .supported)
        #expect(projected?.capabilities.status(for: .rename) == .supported)
        #expect(projected?.capabilities.status(for: .findMyStrap) == .supported)
        #expect(projected?.capabilities.status(for: .strapAlarmSetup) == .supported)
        #expect(projected?.capabilities.status(for: .strapAlarmReadback) == .supported)
        #expect(projected?.capabilities.status(for: .displayGestureMapping) == .supported)
        #expect(projected?.capabilities.status(for: .rePair) == .supported)
        #expect(projected?.capabilities.status(for: .markMoment) == .supported)
        #expect(projected?.capabilities.status(for: .ringPhone) == .supported)
        #expect(projected?.capabilities.status(for: .torch) == .supported)
    }

    @Test
    func bandWritesNeedALiveLinkWhilePhoneSideActionsOnlyNeedAnIdentity() async {
        let stale = RuntimeStateFactory.make(
            connection: .listening(generation: 1, peripheral: RuntimeStateFactory.peripheral),
            stale: true
        )
        let projected = DeviceCenterRuntimeProjection.identity(
            existing: DeviceCenterStateFixtures.sampleDevice,
            state: stale
        )

        #expect(projected?.capabilities.status(for: .rename) == .unknown)
        #expect(projected?.capabilities.status(for: .findMyStrap) == .unknown)
        #expect(projected?.capabilities.status(for: .strapAlarmSetup) == .unknown)
        // The gesture map and re-pairing are iPhone-side records, so a stale
        // link does not take them away.
        #expect(projected?.capabilities.status(for: .displayGestureMapping) == .supported)
        #expect(projected?.capabilities.status(for: .rePair) == .supported)
    }

    @Test
    func disconnectedAndStaleRuntimeStatesRemainTruthful() async throws {
        let identity = DeviceCenterStateFixtures.sampleDevice
        let stored = DeviceCenterStateFixtures.populatedStatus
        let repository = InMemoryDeviceCenterRepository(identity: identity, status: stored)

        let disconnectedRuntime = TestDeviceCenterRuntime(
            state: RuntimeStateFactory.make(
                connection: .outOfRange,
                radioState: .poweredOn,
                running: true,
                setupComplete: false,
                stale: true
            )
        )
        let disconnected = RuntimeDeviceCenterRepository(base: repository, runtime: disconnectedRuntime)
        let disconnectedStatus = try await disconnected.readStatus()
        #expect(disconnectedStatus?.connection == .disconnected)
        #expect(disconnectedStatus?.bluetooth == .poweredOn)
        #expect(disconnectedStatus?.batteryPercent == .measured(78))
        #expect((try await disconnected.readIdentity())?.capabilities.status(for: .manualSync) == .unknown)

        let staleRuntime = TestDeviceCenterRuntime(
            state: RuntimeStateFactory.make(
                connection: .listening(generation: 1, peripheral: RuntimeStateFactory.peripheral),
                radioState: .poweredOn,
                running: true,
                setupComplete: true,
                stale: true
            )
        )
        let stale = RuntimeDeviceCenterRepository(base: repository, runtime: staleRuntime)
        let staleStatus = try await stale.readStatus()
        #expect(staleStatus?.connection == .connected)
        #expect(staleStatus?.restorationDescription?.lowercased().contains("stale") == true)
        #expect((try await stale.readIdentity())?.capabilities.status(for: .manualSync) == .unknown)
    }

    @Test
    func typedBondRepairStateProjectsIntoDeviceCenterWithoutParsingMessages() async throws {
        let cases: [(BluetoothBondRepairReason, DeviceBondRepairReason)] = [
            (.firstWriteTimeoutLoop, .firstWriteTimeoutLoop),
            (.insufficientAuthentication, .insufficientAuthentication),
            (.insufficientEncryption, .insufficientEncryption)
        ]
        for (runtimeReason, deviceReason) in cases {
            let state = RuntimeStateFactory.make(
                connection: .outOfRange,
                running: true,
                setupComplete: false,
                stale: false,
                bondRepairRequired: runtimeReason
            )
            let projected = DeviceCenterRuntimeProjection.status(
                existing: nil,
                state: state,
                now: .distantPast
            )
            let repository = InMemoryDeviceCenterRepository(
                identity: DeviceCenterStateFixtures.sampleDevice,
                status: projected
            )
            let viewState = try await DeviceCenterViewStateLoader.load(from: repository)

            #expect(projected.bondRepairRequired == deviceReason)
            #expect(viewState.universalState == .recoverableError)
            #expect(viewState.message?.contains("forget the band") == true)
        }
    }

    @Test
    func manualSyncUsesOneSharedRuntimeOperationAndRejectsOverlap() async throws {
        let runtime = TestDeviceCenterRuntime(
            state: RuntimeStateFactory.make(
                connection: .listening(generation: 1, peripheral: RuntimeStateFactory.peripheral),
                radioState: .poweredOn,
                running: true,
                setupComplete: true,
                stale: false
            ),
            holdSync: true
        )
        let writer = SharedBluetoothDeviceCommandWriter(runtime: runtime)
        let first = Task { () -> Bool in
            do {
                try await writer.send(DeviceCommand(action: .manualSync))
                return true
            } catch {
                return false
            }
        }

        await runtime.waitForSyncStart()
        await #expect(throws: LooprDeviceRuntimeCommandError.busy) {
            try await writer.send(DeviceCommand(action: .manualSync))
        }
        await runtime.finishSync()
        #expect(await first.value)
        #expect(await runtime.manualSyncCalls() == 1)
    }

    @Test
    func manualSyncRejectsOverlapWhileCheckingReadiness() async throws {
        let runtime = TestDeviceCenterRuntime(
            state: RuntimeStateFactory.make(connection: .listening(generation: 1, peripheral: RuntimeStateFactory.peripheral), stale: false),
            holdState: true
        )
        let writer = SharedBluetoothDeviceCommandWriter(runtime: runtime)
        let first = Task { try await writer.send(DeviceCommand(action: .manualSync)) }
        await runtime.waitForStateRead()
        await #expect(throws: LooprDeviceRuntimeCommandError.busy) {
            try await writer.send(DeviceCommand(action: .manualSync))
        }
        await runtime.finishStateRead()
        try await first.value
        #expect(await runtime.manualSyncCalls() == 1)
    }

    @Test
    func manualSyncFailsClosedWhenRuntimeIsDisconnected() async {
        let runtime = TestDeviceCenterRuntime(
            state: RuntimeStateFactory.make(
                connection: .outOfRange,
                radioState: .poweredOn,
                running: true,
                setupComplete: false,
                stale: false
            )
        )
        let writer = SharedBluetoothDeviceCommandWriter(runtime: runtime)

        await #expect(throws: LooprDeviceRuntimeCommandError.unavailable) {
            try await writer.send(DeviceCommand(action: .manualSync))
        }
        #expect(await runtime.manualSyncCalls() == 0)
    }

    @Test
    func actionsWithoutAVerifiedWriteStillFailClosed() async {
        let runtime = TestDeviceCenterRuntime(state: RuntimeStateFactory.readyState)
        let writer = SharedBluetoothDeviceCommandWriter(runtime: runtime)

        // Mark a moment runs on this iPhone from a band event. It has no
        // outbound command, so the writer's fail-closed floor must reject it
        // rather than inventing one.
        await #expect(throws: LooprDeviceRuntimeCommandError.unsupported(.markMoment)) {
            try await writer.send(DeviceCommand(action: .markMoment))
        }
        #expect(await runtime.manualSyncCalls() == 0)
        #expect(await runtime.renamedNames.isEmpty)
        #expect(await runtime.buzzEffects.isEmpty)
    }

    @Test
    func renameWritesTheWhoopPrefixedNameToTheBand() async throws {
        let runtime = TestDeviceCenterRuntime(state: RuntimeStateFactory.readyState)
        let writer = SharedBluetoothDeviceCommandWriter(runtime: runtime)

        try await writer.send(DeviceCommand(action: .rename, argument: " Bedroom  "))

        // Pairing matches on "WHOOP", so dropping the prefix would strand the
        // strap outside the accessory picker.
        #expect(await runtime.renamedNames == ["WHOOP Bedroom"])
    }

    @Test
    func renameRefusesNamesTheBandCannotAdvertise() async {
        let runtime = TestDeviceCenterRuntime(state: RuntimeStateFactory.readyState)
        let writer = SharedBluetoothDeviceCommandWriter(runtime: runtime)

        await #expect(throws: DeviceActionError.invalidArgument(.rename)) {
            try await writer.send(DeviceCommand(action: .rename, argument: "Fifteen characters"))
        }
        await #expect(throws: DeviceActionError.invalidArgument(.rename)) {
            try await writer.send(DeviceCommand(action: .rename, argument: "Schlafzimmer ü"))
        }
        #expect(await runtime.renamedNames.isEmpty)
    }

    @Test
    func findMyStrapSendsTheShortDoubleBuzz() async throws {
        let runtime = TestDeviceCenterRuntime(state: RuntimeStateFactory.readyState)
        let writer = SharedBluetoothDeviceCommandWriter(runtime: runtime)

        try await writer.send(DeviceCommand(action: .findMyStrap))

        // Effect 1 latches until the user taps the strap, which is the wrong
        // answer for a casual hunt.
        #expect(await runtime.buzzEffects == [2])
    }

    @Test
    func bandWritesFailClosedWhenTheLinkIsNotReady() async {
        let runtime = TestDeviceCenterRuntime(
            state: RuntimeStateFactory.make(
                connection: .listening(generation: 1, peripheral: RuntimeStateFactory.peripheral),
                stale: true
            )
        )
        let writer = SharedBluetoothDeviceCommandWriter(runtime: runtime)

        await #expect(throws: LooprDeviceRuntimeCommandError.unavailable) {
            try await writer.send(DeviceCommand(action: .rename, argument: "Bedroom"))
        }
        await #expect(throws: LooprDeviceRuntimeCommandError.unavailable) {
            try await writer.send(DeviceCommand(action: .findMyStrap))
        }
        #expect(await runtime.renamedNames.isEmpty)
        #expect(await runtime.buzzEffects.isEmpty)
    }

    @Test
    func pairAgainSendsNothingToTheBand() async throws {
        let runtime = TestDeviceCenterRuntime(state: RuntimeStateFactory.readyState)
        let writer = SharedBluetoothDeviceCommandWriter(runtime: runtime)

        // Re-pairing is an accessory operation on this iPhone. No opcode
        // exists for it, so the writer must stay silent.
        try await writer.send(DeviceCommand(action: .rePair))

        #expect(await runtime.renamedNames.isEmpty)
        #expect(await runtime.buzzEffects.isEmpty)
        #expect(await runtime.manualSyncCalls() == 0)
    }
}

private enum RuntimeStateFactory {
    static let peripheral = UUID(uuidString: "00000000-0000-0000-0000-000000000040")!

    static let readyState = make(
        connection: .listening(generation: 1, peripheral: peripheral),
        radioState: .poweredOn,
        running: true,
        setupComplete: true,
        stale: false
    )

    static func make(
        connection: BluetoothConnectionState,
        radioState: ConnectionRadioState = .poweredOn,
        running: Bool = true,
        setupComplete: Bool = true,
        stale: Bool,
        pendingHistoryReplayCount: Int = 0,
        bondRepairRequired: BluetoothBondRepairReason? = nil,
        bandModel: BandModel? = nil,
        charging: Bool? = nil,
        onWrist: Bool? = nil
    ) -> BluetoothAdoptionRuntimeState {
        BluetoothAdoptionRuntimeState(
            running: running,
            generation: setupComplete ? 1 : nil,
            connection: connection,
            setupReady: setupComplete,
            setupComplete: setupComplete,
            radioState: radioState,
            health: ConnectionHealthReport(
                healthy: !stale,
                stale: stale,
                shouldBounce: stale,
                ageOfLatestObservation: stale ? 180 : 1,
                corruptionRate: 0,
                reasons: stale ? [.staleObservation] : []
            ),
            pendingReconnect: nil,
            liveConsumerCount: 0,
            pendingHistoryReplayCount: pendingHistoryReplayCount,
            validFrameCount: stale ? 1 : 4,
            corruptFrameCount: 0,
            writeTimeoutCount: 0,
            lastError: nil,
            charging: charging,
            onWrist: onWrist,
            bondRepairRequired: bondRepairRequired,
            bandModel: bandModel
        )
    }
}

private actor TestDeviceCenterRuntime: LooprDeviceCenterRuntime {
    private var state: BluetoothAdoptionRuntimeState
    private var sharing: [Bool] = []
    private var sharingConfirmation: Bool?
    func setState(_ state: BluetoothAdoptionRuntimeState) { self.state = state }
    func setSharingConfirmation(_ value: Bool?) { sharingConfirmation = value }
    func sharingWrites() -> [Bool] { sharing }
    func setHeartRateSharing(enabled: Bool) async throws -> Bool? {
        sharing.append(enabled)
        return sharingConfirmation
    }
    private var syncCount = 0
    private var holdSync: Bool
    private var syncStarted = false
    private var holdState: Bool
    private var stateReadStarted = false
    private var stateWaiter: CheckedContinuation<Void, Never>?
    private var waiters: [CheckedContinuation<Bool, Never>] = []

    init(state: BluetoothAdoptionRuntimeState, holdSync: Bool = false, holdState: Bool = false) {
        self.state = state
        self.holdSync = holdSync
        self.holdState = holdState
    }

    func acquireLiveStream(kind: LiveStreamKind, consumer: LiveStreamConsumer) async throws -> LiveStreamConsumerHandle {
        throw HeartLiveStreamAdapterError.unavailable
    }

    func bufferedLiveSamples(for kind: LiveStreamKind) async -> [LiveStreamSample] { [] }

    func runtimeState() async -> BluetoothAdoptionRuntimeState {
        stateReadStarted = true
        if holdState { await withCheckedContinuation { stateWaiter = $0 } }
        return state
    }

    func waitForStateRead() async {
        while !stateReadStarted { await Task.yield() }
    }

    func finishStateRead() {
        holdState = false
        stateWaiter?.resume()
        stateWaiter = nil
    }

    func performManualSync(maxDuration: TimeInterval) async -> Bool {
        syncCount += 1
        syncStarted = true
        if holdSync {
            return await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }
        return true
    }

    func waitForSyncStart() async {
        while !syncStarted { await Task.yield() }
    }

    func finishSync() {
        holdSync = false
        let pending = waiters
        waiters.removeAll(keepingCapacity: true)
        for waiter in pending { waiter.resume(returning: true) }
    }

    func manualSyncCalls() -> Int { syncCount }

    // Band operations the writer forwards. Recording them proves the writer
    // sends the exact semantic call, without this test knowing an opcode.
    private(set) var renamedNames: [String] = []
    private(set) var buzzEffects: [UInt8] = []

    func renameBand(to name: String) async throws {
        renamedNames.append(name)
    }

    func buzzBand(effect: UInt8) async throws {
        buzzEffects.append(effect)
    }
}

private actor TestChargingBatteryLog: LooprBatterySampleLog {
    private var values: [BatterySample] = []
    func samples(through now: Date) -> [BatterySample] { values }
    func record(percent: Double, charging: Bool?, at date: Date) {
        values.append(BatterySample(tsSec: Int(date.timeIntervalSince1970), pct: percent, charging: charging))
    }
}
