import BluetoothKit
import Foundation
import TestSupport
import XCTest

final class AccessoryProvisioningTests: XCTestCase {
    func testAlreadyProvisionedShortCircuitsPickerAndRoundTripsAcrossStoreReconstruction() async throws {
        let identifier = UUID()
        let suiteName = "AccessoryProvisioningTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let firstStore = UserDefaultsAccessoryProvisioningStore(defaults: defaults)
        try await firstStore.saveBluetoothIdentifier(identifier)
        let client = FakeAccessorySetupClient(accessories: [
            ProvisionedAccessory(bluetoothIdentifier: identifier)
        ])

        let controller = AccessoryProvisioningController(client: client, store: firstStore)
        let outcome = await controller.inspectExisting()
        XCTAssertEqual(outcome, .alreadyProvisioned(identifier))
        let pickerCalls = await client.pickerCallCount()
        XCTAssertEqual(pickerCalls, 0)

        let relaunchedStore = UserDefaultsAccessoryProvisioningStore(defaults: defaults)
        let relaunchedIdentifier = await relaunchedStore.loadBluetoothIdentifier()
        XCTAssertEqual(relaunchedIdentifier, identifier)
    }

    func testPickerIsOnlyInvokedAfterExplicitExplanationAction() async {
        let identifier = UUID()
        let client = FakeAccessorySetupClient(nextPickerResult: .success(
            ProvisionedAccessory(bluetoothIdentifier: identifier)
        ))
        let store = InMemoryAccessoryProvisioningStore()
        let controller = AccessoryProvisioningController(client: client, store: store)

        let inspected = await controller.inspectExisting()
        XCTAssertEqual(inspected, .noResult)
        let preExplanationPickerCalls = await client.pickerCallCount()
        XCTAssertEqual(preExplanationPickerCalls, 0)
        let explanation = await controller.userTappedPair()
        XCTAssertEqual(explanation, .explanationRequired)
        let stateAfterExplanation = await controller.state
        XCTAssertEqual(stateAfterExplanation, .explanationRequired)
        let secondPreExplanationPickerCalls = await client.pickerCallCount()
        XCTAssertEqual(secondPreExplanationPickerCalls, 0)
        // The blue side light is the state users have to reach before the
        // picker can find the band at all.
        let explanationText = AccessoryProvisioningController.ownershipExplanation
        XCTAssertTrue(explanationText.contains("pulsing blue"))
        XCTAssertTrue(explanationText.contains("WHOOP app"))
        XCTAssertTrue(
            AccessoryProvisioningController.ownershipExplanationShort.contains("pulsing blue")
        )

        let paired = await controller.continueAfterExplanation()
        XCTAssertEqual(paired, .provisioned(identifier))
        let pickerCallCount = await client.pickerCallCount()
        XCTAssertEqual(pickerCallCount, 1)
        let persisted = await store.loadBluetoothIdentifier()
        XCTAssertEqual(persisted, identifier)
    }

    func testCancellationIsRecoverable() async {
        let client = FakeAccessorySetupClient(nextPickerResult: .failure(.cancelled))
        let controller = AccessoryProvisioningController(
            client: client,
            store: InMemoryAccessoryProvisioningStore()
        )

        let explanation = await controller.userTappedPair()
        XCTAssertEqual(explanation, .explanationRequired)
        let cancelled = await controller.continueAfterExplanation()
        XCTAssertEqual(cancelled, .cancelled)
        let cancelledState = await controller.state
        XCTAssertEqual(cancelledState, .cancelled)
        let retry = await controller.userTappedPair()
        XCTAssertEqual(retry, .explanationRequired)
    }

    func testNoResultIsDistinctFromCancellation() async {
        let client = FakeAccessorySetupClient(nextPickerResult: .success(nil))
        let controller = AccessoryProvisioningController(
            client: client,
            store: InMemoryAccessoryProvisioningStore()
        )

        let explanation = await controller.userTappedPair()
        XCTAssertEqual(explanation, .explanationRequired)
        let noResult = await controller.continueAfterExplanation()
        XCTAssertEqual(noResult, .noResult)
        let noResultState = await controller.state
        XCTAssertEqual(noResultState, .noResult)
    }

    func testProvisioningBoundaryNeverInvokesGattOperations() async {
        let identifier = UUID()
        let client = FakeAccessorySetupClient(nextPickerResult: .success(
            ProvisionedAccessory(bluetoothIdentifier: identifier)
        ))
        let controller = AccessoryProvisioningController(
            client: client,
            store: InMemoryAccessoryProvisioningStore()
        )

        let explanation = await controller.userTappedPair()
        XCTAssertEqual(explanation, .explanationRequired)
        let paired = await controller.continueAfterExplanation()
        XCTAssertEqual(paired, .provisioned(identifier))
        let operations = await client.operationLog()
        XCTAssertEqual(operations, ["showPicker"])
    }

    func testRemovalClearsProvisionedAccessoryAndStore() async {
        let identifier = UUID()
        let client = FakeAccessorySetupClient(nextPickerResult: .success(
            ProvisionedAccessory(bluetoothIdentifier: identifier)
        ))
        let store = InMemoryAccessoryProvisioningStore()
        let controller = AccessoryProvisioningController(client: client, store: store)

        let explanation = await controller.userTappedPair()
        XCTAssertEqual(explanation, .explanationRequired)
        _ = await controller.continueAfterExplanation()
        let removed = await controller.removeProvisionedAccessory()
        XCTAssertEqual(removed, .removed)
        let persisted = await store.loadBluetoothIdentifier()
        XCTAssertNil(persisted)
        let removedIdentifiers = await client.removedIdentifiers()
        XCTAssertEqual(removedIdentifiers, [identifier])
    }

    func testRepairAfterRemovalWorksWithoutProcessRestart() async {
        let firstIdentifier = UUID()
        let secondIdentifier = UUID()
        let client = FakeAccessorySetupClient(nextPickerResult: .success(
            ProvisionedAccessory(bluetoothIdentifier: firstIdentifier)
        ))
        let store = InMemoryAccessoryProvisioningStore()
        let controller = AccessoryProvisioningController(client: client, store: store)

        let firstExplanation = await controller.userTappedPair()
        XCTAssertEqual(firstExplanation, .explanationRequired)
        _ = await controller.continueAfterExplanation()
        _ = await controller.removeProvisionedAccessory()
        await client.setNextPickerResult(.success(
            ProvisionedAccessory(bluetoothIdentifier: secondIdentifier)
        ))
        let secondExplanation = await controller.userTappedPair()
        XCTAssertEqual(secondExplanation, .explanationRequired)
        let secondPaired = await controller.continueAfterExplanation()
        XCTAssertEqual(secondPaired, .provisioned(secondIdentifier))
        let persisted = await store.loadBluetoothIdentifier()
        XCTAssertEqual(persisted, secondIdentifier)
    }

    func testRepeatedPickerIsRejectedWhileFirstPickerIsInFlight() async {
        let identifier = UUID()
        let client = FakeAccessorySetupClient()
        let controller = AccessoryProvisioningController(
            client: client,
            store: InMemoryAccessoryProvisioningStore()
        )

        let explanation = await controller.userTappedPair()
        XCTAssertEqual(explanation, .explanationRequired)
        let first = Task { await controller.continueAfterExplanation() }
        await client.waitForPickerCall()
        let repeated = await controller.userTappedPair()
        XCTAssertEqual(repeated, .pickerAlreadyPresented)

        await client.resolvePicker(.success(ProvisionedAccessory(bluetoothIdentifier: identifier)))
        let paired = await first.value
        XCTAssertEqual(paired, .provisioned(identifier))
    }

}

final class ConnectionStateMachineTests: XCTestCase {
    func testEveryDiagrammedStateCanBeReachedWithoutWriting() {
        var machine = ConnectionStateMachine()
        let peripheral = UUID()
        let generation = machine.beginScan()
        XCTAssertEqual(machine.state, .scanning(generation: generation, service: HarvardBluetoothProfile.service))

        XCTAssertEqual(
            machine.handle(
                .discovered(peripheral, advertisedServices: [HarvardBluetoothProfile.service]),
                generation: generation
            ),
            .accepted(.connecting(generation: generation, peripheral: peripheral))
        )
        XCTAssertEqual(
            machine.handle(.connected(peripheral), generation: generation),
            .accepted(.discovering(generation: generation, peripheral: peripheral))
        )
        XCTAssertEqual(
            machine.handle(
                .servicesDiscovered(HarvardBluetoothProfile.requiredServices),
                generation: generation
            ),
            .accepted(.subscribing(generation: generation, peripheral: peripheral))
        )
        let descriptors = [
            CharacteristicDescriptor(id: HarvardBluetoothProfile.command, properties: [.write]),
            CharacteristicDescriptor(id: HarvardBluetoothProfile.response, properties: [.notify]),
            CharacteristicDescriptor(id: HarvardBluetoothProfile.events, properties: [.notify]),
            CharacteristicDescriptor(id: HarvardBluetoothProfile.data, properties: [.notify])
        ]
        XCTAssertEqual(
            machine.handle(.characteristicsDiscovered(descriptors), generation: generation),
            .accepted(.subscribing(generation: generation, peripheral: peripheral))
        )
        for characteristic in [HarvardBluetoothProfile.response, HarvardBluetoothProfile.events, HarvardBluetoothProfile.data] {
            let result = machine.handle(
                .notificationStateChanged(characteristic, enabled: true),
                generation: generation
            )
            if characteristic == HarvardBluetoothProfile.data {
                XCTAssertEqual(
                    result,
                    .accepted(.settingUp(generation: generation, peripheral: peripheral))
                )
            }
        }
        XCTAssertEqual(
            machine.markSetupComplete(generation: generation),
            .accepted(.listening(generation: generation, peripheral: peripheral))
        )
        XCTAssertEqual(
            machine.handle(.value(HarvardBluetoothProfile.response, Data([0xAA])), generation: generation),
            .accepted(.listening(generation: generation, peripheral: peripheral))
        )
    }

    func testImpossibleEventsAreRejectedAndDoNotCrash() {
        var machine = ConnectionStateMachine()
        let result = machine.handle(
            .value(HarvardBluetoothProfile.response, Data([0x00])),
            generation: 1
        )
        guard case .rejected(.invalidEvent(state: .idle, event: .value)) = result else {
            return XCTFail("idle/value must be rejected")
        }
    }

    func testScanAcceptsEdgeWHOOPNameFallbackWithoutAdvertisedService() {
        var machine = ConnectionStateMachine()
        let peripheral = UUID()
        let generation = machine.beginScan()
        XCTAssertEqual(
            machine.handle(
                .discoveredWithAdvertisement(
                    peripheral,
                    advertisedName: "WHOOP",
                    advertisedServices: []
                ),
                generation: generation
            ),
            .accepted(.connecting(generation: generation, peripheral: peripheral))
        )
    }

    func testStaleGenerationEventsAreIgnoredAndConnectGenerationsIncrease() {
        var machine = ConnectionStateMachine()
        let first = machine.beginConnect(to: UUID())
        let second = machine.beginConnect(to: UUID())
        XCTAssertGreaterThan(second, first)
        XCTAssertEqual(
            machine.handle(.connected(UUID()), generation: first),
            .ignoredStaleGeneration
        )
        XCTAssertEqual(machine.state.generation, second)
    }

    func testBluetoothOffAndOutOfRangeRemainDistinct() {
        var machine = ConnectionStateMachine()
        let generation = machine.beginConnect(to: UUID())
        XCTAssertEqual(
            machine.handle(.managerState(.poweredOff), generation: generation),
            .accepted(.bluetoothOff)
        )
        XCTAssertEqual(
            machine.handle(.managerState(.poweredOn), generation: generation),
            .accepted(.idle)
        )

        let reconnectGeneration = machine.beginConnect(to: UUID())
        guard let peripheral = machine.selectedPeripheral else {
            return XCTFail("connect must select exactly one peripheral")
        }
        XCTAssertEqual(
            machine.handle(
                .disconnected(peripheral, error: .outOfRange),
                generation: reconnectGeneration
            ),
            .accepted(.outOfRange)
        )
        XCTAssertNotEqual(machine.state, .bluetoothOff)
    }

    func testForegroundConnectBoundIsTheParityTwentySeconds() {
        XCTAssertEqual(BluetoothTiming.foregroundConnectNanoseconds, 20_000_000_000)
    }

    func testCoordinatorRetrievesPersistedPeripheralBeforeAnyScan() async throws {
        let identifier = UUID()
        let peripheral = UUID()
        let transport = ScriptedTransport(events: [], retrievalResult: [peripheral])
        let store = InMemoryAccessoryProvisioningStore()
        try await store.saveBluetoothIdentifier(identifier)
        let clock = ManualBluetoothClock()
        let coordinator = BluetoothConnectionCoordinator(
            transport: transport,
            store: store,
            clock: clock
        )

        let plan = await coordinator.start()
        guard case .connect(let generation, peripheral: peripheral) = plan else {
            return XCTFail("a successful retrieval must connect the retrieved peripheral")
        }
        XCTAssertEqual(generation, 2)
        XCTAssertEqual(transport.recordedRetrievals(), [[identifier]])
        XCTAssertTrue(transport.recordedScans().isEmpty)
        XCTAssertEqual(transport.recordedConnects(), [peripheral])
        let deadline = await coordinator.connectDeadline()
        XCTAssertEqual(deadline, BluetoothTiming.foregroundConnectNanoseconds)
    }

    func testFallbackScanConnectsOnlyTheProvisionedAccessory() async throws {
        let paired = UUID()
        let other = UUID()
        let transport = ScriptedTransport(events: [], retrievalResult: [])
        let coordinator = BluetoothConnectionCoordinator(
            transport: transport,
            store: InMemoryAccessoryProvisioningStore(identifier: paired)
        )
        guard case .scan(let generation, _) = await coordinator.start() else {
            return XCTFail("Expected scan after retrieval miss")
        }
        for event in [
            TransportEvent.discovered(other, advertisedServices: [HarvardBluetoothProfile.service]),
            .discoveredWithAdvertisement(other, advertisedName: "WHOOP", advertisedServices: [])
        ] {
            _ = await coordinator.handle(event, generation: generation)
        }
        XCTAssertTrue(transport.recordedConnects().isEmpty)
        _ = await coordinator.handle(.discoveredWithAdvertisement(
            paired,
            advertisedName: "WHOOP 4A0B",
            advertisedServices: []
        ), generation: generation)
        XCTAssertEqual(transport.recordedConnects(), [paired])
        await coordinator.disconnect()
    }

    func testFallbackScanNameMatchIsCaseInsensitiveAndStillRequiresSavedIdentifier() async throws {
        let paired = UUID()
        let other = UUID()
        let transport = ScriptedTransport(events: [], retrievalResult: [])
        let coordinator = BluetoothConnectionCoordinator(
            transport: transport,
            store: InMemoryAccessoryProvisioningStore(identifier: paired)
        )
        guard case .scan(let generation, _) = await coordinator.start() else {
            return XCTFail("Expected scan after retrieval miss")
        }

        _ = await coordinator.handle(.discoveredWithAdvertisement(
            other,
            advertisedName: "whoop",
            advertisedServices: []
        ), generation: generation)
        XCTAssertTrue(transport.recordedConnects().isEmpty)

        _ = await coordinator.handle(.discoveredWithAdvertisement(
            paired,
            advertisedName: "wHoOp 4A0B",
            advertisedServices: []
        ), generation: generation)
        XCTAssertEqual(transport.recordedConnects(), [paired])
        await coordinator.disconnect()
    }

    func testWHOOPDiscoveryDescriptorCarriesNameSubstringFallback() {
        let descriptor = AccessoryDiscoveryDescriptor.harvardWHOOP4
        XCTAssertEqual(descriptor.bluetoothNameSubstring, "WHOOP")
    }

    func testCoordinatorFallsBackToHarvardServiceScanWhenRetrievalMisses() async throws {
        let identifier = UUID()
        let transport = ScriptedTransport(events: [], retrievalResult: [])
        let store = InMemoryAccessoryProvisioningStore()
        try await store.saveBluetoothIdentifier(identifier)
        let coordinator = BluetoothConnectionCoordinator(
            transport: transport,
            store: store,
            clock: ManualBluetoothClock()
        )

        let plan = await coordinator.start()
        guard case .scan(let generation, service: let service) = plan else {
            return XCTFail("retrieval miss must use the service-filtered scan fallback")
        }
        XCTAssertEqual(generation, 2)
        XCTAssertEqual(service, HarvardBluetoothProfile.service)
        XCTAssertEqual(transport.recordedRetrievals(), [[identifier]])
        XCTAssertEqual(transport.recordedScans(), [HarvardBluetoothProfile.service])
        XCTAssertTrue(transport.recordedConnects().isEmpty)
    }

    func testConnectTimeoutRetriesThePairedBandDirectlyWithoutScanning() async throws {
        let paired = UUID()
        let transport = ScriptedTransport(events: [], retrievalResult: [paired])
        let clock = ManualBluetoothClock()
        let coordinator = BluetoothConnectionCoordinator(
            transport: transport,
            store: InMemoryAccessoryProvisioningStore(identifier: paired),
            clock: clock
        )
        _ = await coordinator.start()
        clock.advance(byNanoseconds: BluetoothTiming.foregroundConnectNanoseconds)
        _ = await coordinator.expireConnectIfNeeded()
        guard case .connect(_, let peripheral) = await coordinator.start() else {
            return XCTFail("A known identifier is retried directly, as Edge does")
        }
        XCTAssertEqual(peripheral, paired)
        XCTAssertEqual(transport.recordedConnects(), [paired, paired])
        await coordinator.disconnect()
    }

    func testAutonomousWatchdogSleepsTheRemainderWhenItWakesEarly() async throws {
        let peripheral = UUID()
        let transport = ScriptedTransport(events: [], retrievalResult: [peripheral])
        let clock = EarlyWakingBluetoothClock()
        let coordinator = BluetoothConnectionCoordinator(
            transport: transport,
            store: InMemoryAccessoryProvisioningStore(identifier: peripheral),
            clock: clock
        )
        _ = await coordinator.start()
        for _ in 0..<200 {
            if case .connecting = await coordinator.state() { await Task.yield() } else { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let finalState = await coordinator.state()
        XCTAssertEqual(finalState, .idle)
        XCTAssertGreaterThan(clock.sleepCount(), 1)
    }

    func testCoordinatorExpiresConnectAtTwentySecondsAndReleasesResources() async throws {
        let peripheral = UUID()
        let transport = ScriptedTransport(events: [], retrievalResult: [peripheral])
        let store = InMemoryAccessoryProvisioningStore(identifier: UUID())
        let clock = ManualBluetoothClock()
        let coordinator = BluetoothConnectionCoordinator(
            transport: transport,
            store: store,
            clock: clock
        )

        _ = await coordinator.start()
        clock.advance(byNanoseconds: BluetoothTiming.foregroundConnectNanoseconds - 1)
        let beforeDeadline = await coordinator.expireConnectIfNeeded()
        XCTAssertFalse(beforeDeadline)
        clock.advance(byNanoseconds: 1)
        let expired = await coordinator.expireConnectIfNeeded()
        XCTAssertTrue(expired)
        let state = await coordinator.state()
        XCTAssertEqual(state, .idle)
        let clearedDeadline = await coordinator.connectDeadline()
        XCTAssertNil(clearedDeadline)
        XCTAssertEqual(transport.recordedDisconnectCount(), 1)
    }
}

final class SubscriptionBarrierTests: XCTestCase {
    func testDiscoveryRequestsExactlyOneHarvardServiceAndSubscriptionsNeverWrite() async throws {
        let transport = ScriptedTransport(events: [])
        let session = GATTSession()
        await session.discover(using: transport)
        let discovered = transport.recordedServiceDiscovery()
        XCTAssertEqual(discovered, [[HarvardBluetoothProfile.service]])

        try await installAllCharacteristics(in: session)
        try await session.subscribe(using: transport)
        let notifications = transport.recordedNotifications()
        XCTAssertEqual(Set(notifications.map(\.0)), HarvardBluetoothProfile.inboundCharacteristics)
        XCTAssertTrue(notifications.allSatisfy(\.1))
        XCTAssertTrue(transport.recordedWrites().isEmpty)
    }

    func testMismatchedCharacteristicPropertiesAreRejected() async throws {
        let session = GATTSession()
        try await session.acceptServices([HarvardBluetoothProfile.service])
        let invalid = [
            CharacteristicDescriptor(id: HarvardBluetoothProfile.command, properties: [.notify]),
            CharacteristicDescriptor(id: HarvardBluetoothProfile.response, properties: [.notify]),
            CharacteristicDescriptor(id: HarvardBluetoothProfile.events, properties: [.notify]),
            CharacteristicDescriptor(id: HarvardBluetoothProfile.data, properties: [.notify])
        ]
        do {
            try await session.acceptCharacteristics(invalid)
            XCTFail("mismatched command properties must fail closed")
        } catch let error as GATTDiscoveryError {
            guard case .propertyMismatch(HarvardBluetoothProfile.command, _, _) = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
    }

    func testDiscoveryRejectsExtraOrDuplicateServices() async throws {
        let session = GATTSession()
        do {
            try await session.acceptServices([HarvardBluetoothProfile.service, UUID()])
            XCTFail("an extra service must fail closed")
        } catch { }

        do {
            try await session.acceptServices([
                HarvardBluetoothProfile.service,
                HarvardBluetoothProfile.service
            ])
            XCTFail("a duplicate service must fail closed")
        } catch { }
    }

    func testEveryNotificationConfirmationOrderOpensTheBarrierOnlyAtTheEnd() async throws {
        let permutations = permutations(of: [
            HarvardBluetoothProfile.response,
            HarvardBluetoothProfile.events,
            HarvardBluetoothProfile.data
        ])
        for order in permutations {
            let session = GATTSession()
            try await installAllCharacteristics(in: session)
            for (index, characteristic) in order.enumerated() {
                let barrierOpened = try await session.handleNotificationStateChanged(characteristic, enabled: true)
                XCTAssertEqual(barrierOpened, index == order.count - 1)
            }
            let setupReady = await session.setupReady
            XCTAssertTrue(setupReady)
        }
    }

    func testMissingConfirmationNeverOpensBarrier() async throws {
        let session = GATTSession()
        try await installAllCharacteristics(in: session)
        _ = try await session.handleNotificationStateChanged(HarvardBluetoothProfile.response, enabled: true)
        _ = try await session.handleNotificationStateChanged(HarvardBluetoothProfile.events, enabled: true)
        let setupReady = await session.setupReady
        XCTAssertFalse(setupReady)
        let barrier = await session.subscriptionBarrier()
        let confirmedCount = await barrier.confirmedCharacteristics.count
        XCTAssertEqual(confirmedCount, 2)
    }

    func testMalformedInputIsIsolatedAndDiagnosticsContainNoPayload() async throws {
        let session = GATTSession()
        try await installAllCharacteristics(in: session)
        let malformed = Data(repeating: 0xFF, count: 32)
        _ = try await session.ingest(malformed, from: HarvardBluetoothProfile.response, atNanoseconds: 10)
        _ = try await session.ingest(malformed, from: HarvardBluetoothProfile.events, atNanoseconds: 20)

        let resources = await session.resources
        XCTAssertEqual(resources.diagnostics[.response]?.notificationCount, 1)
        XCTAssertEqual(resources.diagnostics[.events]?.notificationCount, 1)
        XCTAssertEqual(resources.diagnostics[.data]?.notificationCount, 0)
        XCTAssertNil(resources.diagnostics[.response]?.lastValidFrameTimeNanoseconds)
        XCTAssertFalse(resources.isEmpty)
    }

    func testDisconnectClearsCharacteristicsReassemblersAndTimers() async throws {
        let session = GATTSession()
        try await installAllCharacteristics(in: session)
        _ = try await session.ingest(Data([0xAA, 0x00]), from: HarvardBluetoothProfile.data, atNanoseconds: 1)
        await session.disconnect()
        let resources = await session.resources
        XCTAssertTrue(resources.isEmpty)
        let discoveredServices = await session.discoveredServiceIDs
        XCTAssertTrue(discoveredServices.isEmpty)
        let setupReady = await session.setupReady
        XCTAssertFalse(setupReady)
    }

    private func installAllCharacteristics(in session: GATTSession) async throws {
        try await session.acceptServices([HarvardBluetoothProfile.service])
        try await session.acceptCharacteristics([
            CharacteristicDescriptor(id: HarvardBluetoothProfile.command, properties: [.write]),
            CharacteristicDescriptor(id: HarvardBluetoothProfile.response, properties: [.notify]),
            CharacteristicDescriptor(id: HarvardBluetoothProfile.events, properties: [.notify]),
            CharacteristicDescriptor(id: HarvardBluetoothProfile.data, properties: [.notify])
        ])
    }

    private func permutations(of values: [CharacteristicID]) -> [[CharacteristicID]] {
        guard values.count > 1 else { return [values] }
        return values.enumerated().flatMap { index, value in
            permutations(of: Array(values.enumerated().filter { $0.offset != index }.map(\.element)))
                .map { [value] + $0 }
        }
    }
}

final class NativeParityCompositionTests: XCTestCase {
    func testProcessWideOwnerRegistryAllowsExactlyOneNormalOrRestoredOwner() throws {
        let registry = BluetoothOwnerRegistry()
        let first = try registry.acquire()
        XCTAssertEqual(registry.ownerCount(), 1)
        XCTAssertThrowsError(try registry.acquire()) { error in
            XCTAssertEqual(error as? BluetoothOwnerError, .alreadyOwned)
        }
        registry.release(UUID())
        XCTAssertEqual(registry.ownerCount(), 1)
        registry.release(first)
        XCTAssertEqual(registry.ownerCount(), 0)
        XCTAssertNoThrow(try registry.acquire())
    }

    func testStaleScopedNotificationCannotEnterCurrentParser() async throws {
        let peripheral = UUID()
        let transport = ScriptedTransport(events: [])
        let session = BluetoothConnectionSession(
            transport: transport,
            store: InMemoryAccessoryProvisioningStore(),
            clock: ManualBluetoothClock()
        )

        guard case .scan(let generation, _) = await session.start() else {
            return XCTFail("a fresh session must start with the service-filtered scan")
        }
        _ = await session.handle(
            .discovered(peripheral, advertisedServices: [HarvardBluetoothProfile.service]),
            generation: generation
        )
        let current = TransportSessionIdentity(peripheral: peripheral)
        _ = await session.handle(.connectedInSession(current), generation: generation)
        _ = await session.handle(
            .servicesDiscoveredInSession(current, services: HarvardBluetoothProfile.requiredServices),
            generation: generation
        )
        _ = await session.handle(
            .characteristicsDiscoveredInSession(current, characteristics: allDescriptors),
            generation: generation
        )
        for characteristic in [HarvardBluetoothProfile.response, HarvardBluetoothProfile.events, HarvardBluetoothProfile.data] {
            _ = await session.handle(
                .notificationStateChangedInSession(current, characteristic: characteristic, enabled: true),
                generation: generation
            )
        }
        let setupReady = await session.setupReady()
        XCTAssertTrue(setupReady)

        let stale = TransportSessionIdentity(peripheral: peripheral)
        let result = await session.handle(
            .valueInSession(stale, characteristic: HarvardBluetoothProfile.response, Data([0xAA])),
            generation: generation
        )
        guard case .rejected(.staleSession) = result else {
            return XCTFail("a callback from a replaced session must be rejected before parsing")
        }
        let frames = await session.drainFrames()
        XCTAssertTrue(frames.isEmpty)
    }

    func testInvalidCharacteristicTableCannotMarkSetupReady() async throws {
        let peripheral = UUID()
        let transport = ScriptedTransport(events: [])
        let session = BluetoothConnectionSession(
            transport: transport,
            store: InMemoryAccessoryProvisioningStore(),
            clock: ManualBluetoothClock()
        )
        guard case .scan(let generation, _) = await session.start() else {
            return XCTFail("a fresh session must start with the service-filtered scan")
        }
        _ = await session.handle(
            .discovered(peripheral, advertisedServices: [HarvardBluetoothProfile.service]),
            generation: generation
        )
        let identity = TransportSessionIdentity(peripheral: peripheral)
        _ = await session.handle(.connectedInSession(identity), generation: generation)
        _ = await session.handle(
            .servicesDiscoveredInSession(identity, services: HarvardBluetoothProfile.requiredServices),
            generation: generation
        )
        var invalid = allDescriptors
        invalid[0] = CharacteristicDescriptor(id: HarvardBluetoothProfile.command, properties: [.notify])
        let result = await session.handle(
            .characteristicsDiscoveredInSession(identity, characteristics: invalid),
            generation: generation
        )
        guard case .rejected(.gattValidationFailed(.propertyMismatch)) = result else {
            return XCTFail("property mismatch must fail closed before notification setup")
        }
        let setupReady = await session.setupReady()
        XCTAssertFalse(setupReady)
        let state = await session.state()
        XCTAssertEqual(state, .idle)
    }

    func testEdgeWatchdogsExposeTwelveAndFifteenSecondBounds() async throws {
        let transport = ScriptedTransport(events: [])
        let clock = ManualBluetoothClock()
        let coordinator = BluetoothConnectionCoordinator(
            transport: transport,
            store: InMemoryAccessoryProvisioningStore(),
            clock: clock
        )
        guard case .scan = await coordinator.start() else {
            return XCTFail("expected scan plan")
        }
        let scanPhase = await coordinator.activeWatchdogPhase()
        XCTAssertEqual(scanPhase, .scan)
        let scanDeadline = await coordinator.watchdogDeadline()
        XCTAssertEqual(scanDeadline, BluetoothTiming.foregroundScanNanoseconds)
        clock.advance(byNanoseconds: BluetoothTiming.foregroundScanNanoseconds)
        let expired = await coordinator.expireConnectIfNeeded()
        XCTAssertTrue(expired)
        let scanState = await coordinator.state()
        XCTAssertEqual(scanState, .outOfRange)

        let connectTransport = ScriptedTransport(events: [], retrievalResult: [UUID()])
        let connectClock = ManualBluetoothClock()
        let connected = BluetoothConnectionCoordinator(
            transport: connectTransport,
            store: InMemoryAccessoryProvisioningStore(identifier: UUID()),
            clock: connectClock
        )
        guard case .connect(let generation, let peripheral) = await connected.start() else {
            return XCTFail("expected retrieved connect plan")
        }
        _ = await connected.handle(.connected(peripheral), generation: generation)
        let discoveryPhase = await connected.activeWatchdogPhase()
        XCTAssertEqual(discoveryPhase, .discovery)
        let discoveryDeadline = await connected.watchdogDeadline()
        XCTAssertEqual(discoveryDeadline, BluetoothTiming.gattDiscoveryNanoseconds)
    }

    private var allDescriptors: [CharacteristicDescriptor] {
        [
            CharacteristicDescriptor(id: HarvardBluetoothProfile.command, properties: [.write]),
            CharacteristicDescriptor(id: HarvardBluetoothProfile.response, properties: [.notify]),
            CharacteristicDescriptor(id: HarvardBluetoothProfile.events, properties: [.notify]),
            CharacteristicDescriptor(id: HarvardBluetoothProfile.data, properties: [.notify])
        ]
    }
}

private actor FakeAccessorySetupClient: AccessorySetupClient {
    private var accessoriesStorage: [ProvisionedAccessory]
    private var nextPickerResult: Result<ProvisionedAccessory?, AccessorySetupError>?
    private var pickerCalls = 0
    private var removed: [UUID] = []
    private var operationLogStorage: [String] = []
    private var pickerContinuation: CheckedContinuation<Result<ProvisionedAccessory?, AccessorySetupError>, Never>?
    private var pickerWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        accessories: [ProvisionedAccessory] = [],
        nextPickerResult: Result<ProvisionedAccessory?, AccessorySetupError>? = nil
    ) {
        accessoriesStorage = accessories
        self.nextPickerResult = nextPickerResult
    }

    func provisionedAccessories() async -> [ProvisionedAccessory] {
        operationLogStorage.append("provisionedAccessories")
        return accessoriesStorage
    }

    func showPicker(for descriptor: AccessoryDiscoveryDescriptor) async throws -> ProvisionedAccessory? {
        operationLogStorage.append("showPicker")
        pickerCalls += 1
        pickerWaiters.forEach { $0.resume() }
        pickerWaiters.removeAll(keepingCapacity: false)
        let result: Result<ProvisionedAccessory?, AccessorySetupError>
        if let nextPickerResult {
            result = nextPickerResult
            self.nextPickerResult = nil
        } else {
            result = await withCheckedContinuation { continuation in
                pickerContinuation = continuation
            }
        }
        return try result.get()
    }

    func removeAccessory(_ accessory: ProvisionedAccessory) async throws {
        operationLogStorage.append("removeAccessory")
        removed.append(accessory.bluetoothIdentifier)
        accessoriesStorage.removeAll { $0.bluetoothIdentifier == accessory.bluetoothIdentifier }
    }

    func pickerCallCount() -> Int { pickerCalls }
    func removedIdentifiers() -> [UUID] { removed }
    func operationLog() -> [String] { operationLogStorage }

    func setNextPickerResult(_ result: Result<ProvisionedAccessory?, AccessorySetupError>) {
        nextPickerResult = result
    }

    func waitForPickerCall() async {
        if pickerCalls > 0 { return }
        await withCheckedContinuation { pickerWaiters.append($0) }
    }

    func resolvePicker(_ result: Result<ProvisionedAccessory?, AccessorySetupError>) {
        pickerContinuation?.resume(returning: result)
        pickerContinuation = nil
    }
}

/// Wakes after half of every requested sleep, like a sleep clock that runs
/// ahead of the monotonic deadline clock.
private final class EarlyWakingBluetoothClock: BluetoothClock, @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0
    private var sleeps = 0

    var supportsAutonomousSleep: Bool { true }

    func nowNanoseconds() -> UInt64 { lock.withLock { value } }
    func sleepCount() -> Int { lock.withLock { sleeps } }

    func sleep(forNanoseconds nanoseconds: UInt64) async throws {
        lock.withLock {
            sleeps += 1
            value += max(nanoseconds / 2, min(nanoseconds, 1_000_000))
        }
    }
}
