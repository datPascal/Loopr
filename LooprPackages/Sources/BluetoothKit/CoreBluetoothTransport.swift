#if canImport(CoreBluetooth)
@preconcurrency import CoreBluetooth
import Foundation
import ProtocolKit
#if canImport(UIKit)
@preconcurrency import UIKit
#endif

public enum CoreBluetoothTransportFactoryError: Error, Equatable, Sendable, LocalizedError {
    case notProvisioned
    case transportAlreadyCreated
    case activeOwner

    public var errorDescription: String? {
        switch self {
        case .notProvisioned:
            "CoreBluetooth cannot be created before AccessorySetupKit provisioning."
        case .transportAlreadyCreated:
            "The process-wide Bluetooth transport has already been created."
        case .activeOwner:
            "Another process-wide Bluetooth owner is active."
        }
    }
}

/// Process-wide construction gate for the one native central owner.  The
/// factory is deliberately the only public construction path; callers must
/// persist the AccessorySetupKit UUID first, then ask this seam for the
/// transport.  Normal and restored paths can share the same
/// `BluetoothOwnerRegistry` instance through `ownerRegistry`.
public final class CoreBluetoothTransportFactory: @unchecked Sendable {
    public static let shared = CoreBluetoothTransportFactory()

    private let lock = NSLock()
    public let ownerRegistry: BluetoothOwnerRegistry
    private var provisionedIdentifier: PeripheralID?
    private var transport: CoreBluetoothTransport?

    public init(ownerRegistry: BluetoothOwnerRegistry = .processWide) {
        self.ownerRegistry = ownerRegistry
    }

    public func provision(_ identifier: PeripheralID) throws {
        try lock.withLock {
            if transport != nil, provisionedIdentifier != identifier {
                throw CoreBluetoothTransportFactoryError.transportAlreadyCreated
            }
            provisionedIdentifier = identifier
        }
    }

    public func isProvisioned() -> Bool {
        lock.withLock { provisionedIdentifier != nil }
    }

    public func makeTransport(
        queueLabel: String = "com.loopr.bluetooth.central",
        profile: GATTProfile = .gen4
    ) throws -> CoreBluetoothTransport {
        try lock.withLock {
            guard let provisionedIdentifier else {
                throw CoreBluetoothTransportFactoryError.notProvisioned
            }
            guard transport == nil else {
                throw CoreBluetoothTransportFactoryError.transportAlreadyCreated
            }
            let ownerToken: UUID
            do {
                ownerToken = try ownerRegistry.acquire()
            } catch {
                throw CoreBluetoothTransportFactoryError.activeOwner
            }
            let created = CoreBluetoothTransport(
                queueLabel: queueLabel,
                provisionedIdentifier: provisionedIdentifier,
                ownerRegistry: ownerRegistry,
                ownerToken: ownerToken,
                profile: profile
            )
            transport = created
            return created
        }
    }

    public func release(_ transport: CoreBluetoothTransport) {
        lock.withLock {
            guard self.transport === transport else { return }
            self.transport = nil
            transport.shutdown()
        }
    }
}

/// The sole CoreBluetooth owner.  Delegate callbacks are converted into
/// immutable `TransportEvent`s on one dedicated serial queue; no protocol or
/// command decisions are made in this adapter.
public final class CoreBluetoothTransport: NSObject, BLEPeripheralRetriever, BLEPeripheralScanner, BLEGATTDiscoverer, BLEWatchdogDisconnecting, BLENativeLinkReporting, BLESignalStrengthReporting, CBCentralManagerDelegate, CBPeripheralDelegate, @unchecked Sendable {
    public static let restorationIdentifier = "com.loopr.bluetooth.central"
    public static let didRestoreStateNotification = Notification.Name("com.loopr.bluetooth.didRestoreState")

    /// CoreBluetooth does not put an operation ID on peripheral delegate
    /// callbacks.  A delegate object is therefore created for every native
    /// connection attempt and captures the immutable transport identity at
    /// creation time.  Replaced delegates are invalidated; a callback already
    /// queued by CoreBluetooth can only be dropped, never re-labelled with the
    /// identity of a newer connection on the same CBPeripheral instance.
    private final class SessionPeripheralDelegate: NSObject, CBPeripheralDelegate {
        weak var owner: CoreBluetoothTransport?
        let identity: TransportSessionIdentity

        init(owner: CoreBluetoothTransport, identity: TransportSessionIdentity) {
            self.owner = owner
            self.identity = identity
        }

        func invalidate() { owner = nil }

        func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
            owner?.forwardDidDiscoverServices(
                peripheral,
                error: error,
                identity: identity
            )
        }

        func peripheral(
            _ peripheral: CBPeripheral,
            didDiscoverCharacteristicsFor service: CBService,
            error: Error?
        ) {
            owner?.forwardDidDiscoverCharacteristics(
                peripheral,
                service: service,
                error: error,
                identity: identity
            )
        }

        func peripheral(
            _ peripheral: CBPeripheral,
            didUpdateNotificationStateFor characteristic: CBCharacteristic,
            error: Error?
        ) {
            owner?.forwardDidUpdateNotificationState(
                peripheral,
                characteristic: characteristic,
                error: error,
                identity: identity
            )
        }

        func peripheral(
            _ peripheral: CBPeripheral,
            didUpdateValueFor characteristic: CBCharacteristic,
            error: Error?
        ) {
            owner?.forwardDidUpdateValue(
                peripheral,
                characteristic: characteristic,
                error: error,
                identity: identity
            )
        }

        func peripheral(
            _ peripheral: CBPeripheral,
            didWriteValueFor characteristic: CBCharacteristic,
            error: Error?
        ) {
            owner?.forwardDidWriteValue(
                peripheral,
                characteristic: characteristic,
                error: error,
                identity: identity
            )
        }

        func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
            owner?.forwardDidReadRSSI(peripheral, rssi: RSSI, error: error, identity: identity)
        }
    }

    private let callbackQueue: DispatchQueue
    private let provisionedIdentifier: PeripheralID
    private let profile: GATTProfile
    private let ownerRegistry: BluetoothOwnerRegistry
    private let ownerToken: UUID
    private let ownerReleaseLock = NSLock()
    private var ownerReleased = false
    private var central: CBCentralManager!
    private var continuation: AsyncStream<TransportEvent>.Continuation?
    private var stream: AsyncStream<TransportEvent>?
    private var streamID: UUID?
    private var peripherals: [PeripheralID: CBPeripheral] = [:]
    private var selectedPeripheral: PeripheralID?
    private var activePeripheral: CBPeripheral?
    private var activeIdentity: TransportSessionIdentity?
    private var activeDelegate: SessionPeripheralDelegate?
    private var didConnectToken: UUID?
    private var restoredPeripheralIDs: Set<PeripheralID> = []
    /// Set by the first accepted `didConnect`. Until then any system link to
    /// the band belongs to some other app.
    private var hasConnectedLocally = false
    /// See `SharedLinkHint`. Read-only: nothing here connects or writes.
    private var sharedLinkObserved = false
    /// `willRestoreState` is delivered as soon as the central is created, which
    /// is before the runtime asks for the event stream. Without this buffer the
    /// one callback that proves iOS relaunched the app for the band is dropped.
    private var pendingRestoration: RestorationSnapshot?
    private var scanning = false
    private var discoveryPolicy: BluetoothDiscoveryPolicy
    private var applicationObservers: [NSObjectProtocol] = []

    private struct NativeCharacteristic {
        let peripheral: CBPeripheral
        let characteristic: CBCharacteristic
    }

    private struct PendingWrite {
        let requestID: UUID
        let identity: TransportSessionIdentity
        let continuation: CheckedContinuation<Void, Error>
    }

    private struct PendingSignalRead {
        let requestID: UUID
        let identity: TransportSessionIdentity
        let continuation: CheckedContinuation<Int?, Never>
    }

    private var characteristics: [CharacteristicID: NativeCharacteristic] = [:]
    private var pendingSignalReads: [PendingSignalRead] = []
    private var pendingWrites: [CharacteristicID: PendingWrite] = [:]
    private var cancelledWriteRequests: Set<UUID> = []
    private var writeRequests: Set<UUID> = []

    fileprivate init(
        queueLabel: String,
        provisionedIdentifier: PeripheralID,
        ownerRegistry: BluetoothOwnerRegistry,
        ownerToken: UUID,
        profile: GATTProfile
    ) {
        callbackQueue = DispatchQueue(label: queueLabel)
        self.provisionedIdentifier = provisionedIdentifier
        self.profile = profile
        self.discoveryPolicy = BluetoothDiscoveryPolicy(isForeground: false, service: profile.service)
        self.ownerRegistry = ownerRegistry
        self.ownerToken = ownerToken
        super.init()
        central = CBCentralManager(
            delegate: self,
            queue: callbackQueue,
            options: [CBCentralManagerOptionRestoreIdentifierKey: Self.restorationIdentifier]
        )
        #if canImport(UIKit)
        applicationObservers = [
            NotificationCenter.default.addObserver(
                forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil
            ) { [weak self] _ in self?.setScanForeground(false) },
            NotificationCenter.default.addObserver(
                forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil
            ) { [weak self] _ in self?.setScanForeground(true) }
        ]
        #endif
    }

    deinit {
        applicationObservers.forEach(NotificationCenter.default.removeObserver)
        releaseOwner()
    }

    public func events() -> AsyncStream<TransportEvent> {
        if let stream { return stream }
        let (stream, continuation) = AsyncStream<TransportEvent>.makeStream()
        let streamID = UUID()
        self.stream = stream
        self.streamID = streamID
        self.continuation = continuation
        continuation.onTermination = { [weak self] _ in
            // Drop the cached stream too. Returning a finished stream to the
            // next consumer would end event delivery with no error. The ID
            // keeps a late callback from clearing a newer stream.
            self?.callbackQueue.async { [weak self] in
                guard let self, self.streamID == streamID else { return }
                self.continuation = nil
                self.stream = nil
            }
        }
        // Replay a restoration callback that landed before this consumer
        // existed, so the runtime always learns it was relaunched for the band.
        callbackQueue.async { [weak self] in
            guard let self,
                  self.streamID == streamID,
                  let pending = self.pendingRestoration else { return }
            self.pendingRestoration = nil
            self.emit(.restored(pending))
        }
        // The central may have reported its initial state before the runtime
        // subscribed. Replaying its current value lets the fd4b session wait
        // for powered-on before it retrieves or scans.
        callbackQueue.async { [weak self] in
            guard let self, self.streamID == streamID else { return }
            self.emit(.managerState(Self.managerState(self.central.state)))
        }
        return stream
    }

    public func retrieve(_ identifiers: [PeripheralID]) async -> [PeripheralID] {
        await withCheckedContinuation { continuation in
            callbackQueue.async { [weak self] in
                guard let self, self.central.state == .poweredOn else {
                    continuation.resume(returning: [])
                    return
                }
                let matched = self.central.retrievePeripherals(withIdentifiers: identifiers)
                matched.forEach { self.remember($0) }
                if !self.hasConnectedLocally {
                    let systemConnected = self.central
                        .retrieveConnectedPeripherals(withServices: [CBUUID(nsuuid: self.profile.service)])
                        .map(\.identifier)
                    if SharedLinkHint.otherAppHoldsLink(
                        systemConnected: systemConnected,
                        provisioned: self.provisionedIdentifier,
                        restored: self.restoredPeripheralIDs,
                        hasConnectedLocally: self.hasConnectedLocally
                    ) {
                        self.sharedLinkObserved = true
                    }
                }
                continuation.resume(returning: matched.map(\.identifier))
            }
        }
    }

    /// True when iOS listed the band as connected before Loopr's first own
    /// connection in this process. A hint for the person, never proof.
    public func otherAppLinkObservedBeforeConnect() async -> Bool {
        await withCheckedContinuation { continuation in
            callbackQueue.async { [weak self] in
                continuation.resume(returning: self?.sharedLinkObserved ?? false)
            }
        }
    }

    public func connect(_ peripheral: PeripheralID) async {
        callbackQueue.async { [weak self] in
            guard let self, self.central.state == .poweredOn else { return }
            // Match Edge's native client: resolve the current CoreBluetooth
            // object rather than reusing a previous scan's object indefinitely.
            guard let native = self.central.retrievePeripherals(withIdentifiers: [peripheral]).first
                ?? self.peripherals[peripheral] else { return }
            self.remember(native)
            self.stopScanOnQueue()
            self.failPendingWrites(with: .cancelled)
            self.clearSessionOnQueue(clearDelegate: true)
            let identity = TransportSessionIdentity(peripheral: peripheral)
            self.selectedPeripheral = peripheral
            self.activePeripheral = native
            self.activeIdentity = identity
            let delegate = SessionPeripheralDelegate(owner: self, identity: identity)
            self.activeDelegate = delegate
            self.didConnectToken = nil
            native.delegate = delegate
            #if DEBUG
            fputs("[Loopr BLE] \(Date().formatted(date: .omitted, time: .standard)) connect requested; nativeState=\(native.state.rawValue)\n", stderr)
            #endif
            // One use only. A restored link is already connected exactly once;
            // afterwards this peripheral needs a real connect call.
            if self.restoredPeripheralIDs.remove(peripheral) != nil, native.state == .connected {
                // iOS has already connected this central's restored peripheral.
                // FBP resumes its didConnect path here; waiting for another
                // native callback would leave GATT setup blocked forever.
                self.centralManager(self.central, didConnect: native)
            } else {
                // No connect options. On the test iPhone, passing
                // CBConnectPeripheralOptionEnableAutoReconnect made iOS reject
                // every attempt with CBError.invalidParameters.
                self.central.connect(native, options: nil)
            }
        }
    }

    public func scan(for service: ServiceID) async {
        guard service == profile.service else { return }
        #if canImport(UIKit)
        // Enqueue from the main actor so app-state reads and lifecycle
        // notifications reach the Bluetooth queue in the same order.
        await MainActor.run {
            enqueueScan(isForeground: UIApplication.shared.applicationState != .background)
        }
        #else
        enqueueScan(isForeground: true)
        #endif
    }

    private func enqueueScan(isForeground: Bool) {
        callbackQueue.async { [weak self] in
            guard let self,
                  self.central.state == .poweredOn else { return }
            self.discoveryPolicy.isForeground = isForeground
            self.startScanOnQueue()
        }
    }

    private func setScanForeground(_ isForeground: Bool) {
        callbackQueue.async { [weak self] in
            guard let self else { return }
            self.discoveryPolicy.isForeground = isForeground
            if self.scanning { self.startScanOnQueue() }
        }
    }

    private func startScanOnQueue() {
        stopScanOnQueue()
        guard central.state == .poweredOn else { return }
        central.scanForPeripherals(
            withServices: discoveryPolicy.serviceUUIDs?.map { CBUUID(string: $0.uuidString) },
            options: nil
        )
        scanning = true
    }

    public func stopScan() async {
        callbackQueue.async { [weak self] in self?.stopScanOnQueue() }
    }

    public func discoverServices(_ ids: [ServiceID]) async {
        callbackQueue.async { [weak self] in
            guard let self,
                  let native = self.currentPeripheralOnQueue(),
                  self.central.state == .poweredOn else { return }
            native.delegate = activeDelegate
            native.discoverServices(ids.map { CBUUID(string: $0.uuidString) })
        }
    }

    public func discoverCharacteristics(_ ids: [CharacteristicID]) async {
        callbackQueue.async { [weak self] in
            guard let self,
                  let native = self.currentPeripheralOnQueue(),
                  let services = native.services else { return }
            services
                .filter { $0.uuid == CBUUID(string: self.profile.service.uuidString) }
                .forEach { service in
                    native.discoverCharacteristics(
                        ids.map { CBUUID(string: $0.uuidString) },
                        for: service
                    )
                }
        }
    }

    public func setNotify(_ char: CharacteristicID, enabled: Bool) async {
        callbackQueue.async { [weak self] in
            guard let self,
                  let native = self.characteristics[char],
                  let identity = self.activeIdentity,
                  native.peripheral === self.activePeripheral,
                  native.peripheral.identifier == identity.peripheral else { return }
            native.peripheral.setNotifyValue(enabled, for: native.characteristic)
        }
    }

    /// A with-response write remains suspended until CoreBluetooth invokes
    /// `didWriteValueFor`.  Disconnect/failure paths resume every pending
    /// continuation with `.disconnected`; an early successful return is never
    /// synthesized by this adapter.
    public func write(_ data: Data, to char: CharacteristicID) async throws {
        let requestID = UUID()
        _ = callbackQueue.sync { writeRequests.insert(requestID) }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                callbackQueue.async { [weak self] in
                    guard let self,
                          let native = self.characteristics[char],
                          let identity = self.activeIdentity,
                          native.peripheral === self.activePeripheral,
                          native.peripheral.identifier == identity.peripheral else {
                        self?.writeRequests.remove(requestID)
                        continuation.resume(throwing: TransportError.unavailable)
                        return
                    }
                    guard self.pendingWrites[char] == nil else {
                        self.writeRequests.remove(requestID)
                        continuation.resume(throwing: TransportError.invalidState("a write is already pending for this characteristic"))
                        return
                    }
                    guard native.peripheral.state == .connected else {
                        self.writeRequests.remove(requestID)
                        continuation.resume(throwing: TransportError.disconnected)
                        return
                    }
                    guard native.characteristic.properties.contains(.write) else {
                        self.writeRequests.remove(requestID)
                        continuation.resume(throwing: TransportError.writeFailed("characteristic does not support write-with-response"))
                        return
                    }
                    if self.cancelledWriteRequests.remove(requestID) != nil {
                        self.writeRequests.remove(requestID)
                        continuation.resume(throwing: TransportError.cancelled)
                        return
                    }
                    self.pendingWrites[char] = PendingWrite(
                        requestID: requestID,
                        identity: identity,
                        continuation: continuation
                    )
                    native.peripheral.writeValue(data, for: native.characteristic, type: .withResponse)
                }
            }
        } onCancel: { [weak self] in
            self?.cancelWrite(requestID: requestID, characteristic: char)
        }
    }

    public func disconnect() async {
        callbackQueue.async { [weak self] in
            guard let self else { return }
            self.stopScanOnQueue()
            self.failPendingWrites(with: .disconnected)
            if let native = self.activePeripheral {
                self.central.cancelPeripheralConnection(native)
            }
            self.clearSessionOnQueue(clearDelegate: true)
        }
    }

    /// True once CoreBluetooth reports the selected peripheral connected, even
    /// if the runtime has not consumed the `didConnect` event yet.
    public func isNativeLinkConnected() async -> Bool {
        await withCheckedContinuation { continuation in
            callbackQueue.async { [weak self] in
                continuation.resume(returning: self?.activePeripheral?.state == .connected)
            }
        }
    }

    /// How long a signal read waits for the radio.  The reference client uses
    /// the same three seconds while its hunt screen is open.
    public static let signalReadTimeoutSeconds: TimeInterval = 3

    /// The connected peripheral's RSSI in dBm.
    ///
    /// It never throws and never scans.  A link that drops mid-hunt, a radio
    /// that does not answer, and an error from CoreBluetooth all read as nil,
    /// because "Find my strap" has to keep working while the person walks
    /// around the room.
    public func readSignalStrength() async -> Int? {
        let requestID = UUID()
        return await withCheckedContinuation { (continuation: CheckedContinuation<Int?, Never>) in
            callbackQueue.async { [weak self] in
                guard let self,
                      let identity = self.activeIdentity,
                      let native = self.currentPeripheralOnQueue(),
                      native.state == .connected else {
                    continuation.resume(returning: nil)
                    return
                }
                self.pendingSignalReads.append(
                    PendingSignalRead(requestID: requestID, identity: identity, continuation: continuation)
                )
                native.readRSSI()
                self.callbackQueue.asyncAfter(deadline: .now() + Self.signalReadTimeoutSeconds) { [weak self] in
                    self?.resolveSignalRead(requestID: requestID, value: nil)
                }
            }
        }
    }

    private func resolveSignalRead(requestID: UUID, value: Int?) {
        guard let index = pendingSignalReads.firstIndex(where: { $0.requestID == requestID }) else { return }
        let pending = pendingSignalReads.remove(at: index)
        pending.continuation.resume(returning: value)
    }

    /// Every unanswered read is resolved with nil when a session ends, so a
    /// disconnect can never leave the hunt screen suspended forever.
    private func failPendingSignalReads(for identity: TransportSessionIdentity? = nil) {
        let matching: [PendingSignalRead]
        if let identity {
            matching = pendingSignalReads.filter { $0.identity == identity }
            pendingSignalReads.removeAll { $0.identity == identity }
        } else {
            matching = pendingSignalReads
            pendingSignalReads.removeAll(keepingCapacity: false)
        }
        matching.forEach { $0.continuation.resume(returning: nil) }
    }

    private func forwardDidReadRSSI(
        _ peripheral: CBPeripheral,
        rssi: NSNumber,
        error: Error?,
        identity: TransportSessionIdentity
    ) {
        guard isCurrent(identity, peripheral: peripheral),
              let index = pendingSignalReads.firstIndex(where: { $0.identity == identity }) else { return }
        let pending = pendingSignalReads.remove(at: index)
        pending.continuation.resume(returning: error == nil ? Int(truncating: rssi) : nil)
    }

    /// Watchdog-specific native teardown. Unlike an explicit stop/background
    /// disconnect, this emits exactly one immutable scoped link-down before
    /// clearing the native identity. The owning connection session can then
    /// accept the event, tear down its GATT resources, and let the runtime's
    /// reconnect policy run. If there is no active operation, no event is
    /// synthesized and the coordinator may use its local fallback.
    public func disconnectForWatchdog() async -> Bool {
        await withCheckedContinuation { continuation in
            callbackQueue.async { [weak self] in
                guard let self,
                      let identity = self.activeIdentity,
                      let native = self.activePeripheral else {
                    continuation.resume(returning: false)
                    return
                }
                self.stopScanOnQueue()
                self.failPendingWrites(for: identity, with: .timeout)
                // Yield before clearing the identity. The stream consumer is
                // serialized by its owning runtime, while any later native
                // callback is fenced by the delegate token and identity check.
                self.emit(.disconnectedInSession(identity, error: .timeout))
                self.central.cancelPeripheralConnection(native)
                self.clearSessionOnQueue(clearDelegate: true)
                continuation.resume(returning: true)
            }
        }
    }

    /// Factory release hook.  It is idempotent and keeps native delegate,
    /// pending continuation, scan, and characteristic state from surviving a
    /// process-wide owner release.
    fileprivate func shutdown() {
        releaseOwner()
        callbackQueue.async { [weak self] in
            guard let self else { return }
            self.applicationObservers.forEach(NotificationCenter.default.removeObserver)
            self.applicationObservers.removeAll()
            self.stopScanOnQueue()
            self.failPendingWrites(with: .disconnected)
            if let native = self.activePeripheral {
                self.central.cancelPeripheralConnection(native)
            }
            self.clearSessionOnQueue(clearDelegate: true)
            self.continuation?.finish()
            self.continuation = nil
            self.stream = nil
        }
    }

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = Self.managerState(central.state)
        emit(.managerState(state))
        guard state == .poweredOff || state == .unsupported else { return }
        failPendingWrites(with: .bluetoothOff)
        clearSessionOnQueue(clearDelegate: true)
    }

    public func centralManager(
        _ central: CBCentralManager,
        willRestoreState dict: [String: Any]
    ) {
        // Scene-based apps may receive nil launchOptions. Apple directs them
        // to detect restoration here instead:
        // https://developer.apple.com/documentation/corebluetooth/central-manager-state-restoration-options
        NotificationCenter.default.post(name: Self.didRestoreStateNotification, object: nil)
        let restored = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral]) ?? []
        restoredPeripheralIDs.formUnion(restored.map(\.identifier))
        restored.forEach { remember($0) }
        #if DEBUG
        let connectedCount = restored.filter { $0.state == .connected }.count
        fputs("[Loopr BLE] \(Date().formatted(date: .omitted, time: .standard)) willRestoreState; peripherals=\(restored.count), connected=\(connectedCount), pairedMatch=\(restored.contains { $0.identifier == provisionedIdentifier })\n", stderr)
        #endif
        let snapshot = RestorationSnapshot(
            managerState: Self.managerState(central.state),
            peripherals: restored.map(\.identifier)
        )
        if continuation == nil { pendingRestoration = snapshot }
        emit(.restored(snapshot))
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        remember(peripheral)
        let services: [ServiceID]
        if let advertised = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] {
            services = advertised.compactMap { Self.id(for: $0) }
        } else {
            services = []
        }
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
            ?? peripheral.name
        guard discoveryPolicy.accepts(name: advertisedName, services: services) else { return }
        #if DEBUG
        fputs("[Loopr BLE] \(Date().formatted(date: .omitted, time: .standard)) advertisement; pairedMatch=\(peripheral.identifier == provisionedIdentifier), RSSI=\(RSSI), connectable=\(advertisementData[CBAdvertisementDataIsConnectable] ?? "unknown")\n", stderr)
        #endif
        emit(.discoveredWithAdvertisement(
            peripheral.identifier,
            advertisedName: advertisedName,
            advertisedServices: services
        ))
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        #if DEBUG
        fputs("[Loopr BLE] \(Date().formatted(date: .omitted, time: .standard)) didConnect; nativeState=\(peripheral.state.rawValue), current=\(identity(for: peripheral) != nil)\n", stderr)
        #endif
        // `didConnect` carries no operation token.  Accept it only for the
        // currently selected object, while it is actually connected, and only
        // once for this native operation. A delayed callback from a previous
        // operation on the same CBPeripheral cannot create a second accepted
        // connection event.
        guard peripheral.state == .connected,
              let identity = identity(for: peripheral),
              didConnectToken == nil else { return }
        remember(peripheral)
        didConnectToken = identity.token
        hasConnectedLocally = true
        emit(.connectedInSession(identity))
    }

    public func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        #if DEBUG
        fputs("[Loopr BLE] \(Date().formatted(date: .omitted, time: .standard)) didFailToConnect; nativeState=\(peripheral.state.rawValue), current=\(identity(for: peripheral) != nil), error=\(String(describing: error))\n", stderr)
        #endif
        // A failed-connect callback is authoritative only while the native
        // peripheral is disconnected. If the object has already been reused by
        // a newer operation, fail closed rather than mapping an old callback to
        // the new identity.
        guard peripheral.state == .disconnected,
              let identity = identity(for: peripheral) else { return }
        failPendingWrites(for: identity, with: .disconnected)
        emit(.disconnectedInSession(
            identity,
            error: Self.transportError(error) ?? .disconnected
        ))
        clearSessionOnQueue(clearDelegate: true)
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        #if DEBUG
        fputs("[Loopr BLE] \(Date().formatted(date: .omitted, time: .standard)) didDisconnect; nativeState=\(peripheral.state.rawValue), current=\(identity(for: peripheral) != nil), error=\(String(describing: error))\n", stderr)
        #endif
        // A disconnect for an old operation can arrive after the same native
        // object has been selected again. The state read is the only native
        // correlation CoreBluetooth gives us here; if it is not disconnected,
        // drop the ambiguous callback and let the current operation's watchdog
        // decide. Never relabel it with `activeIdentity`.
        guard peripheral.state == .disconnected,
              let identity = identity(for: peripheral) else { return }
        let mapped = Self.transportError(error) ?? .disconnected
        failPendingWrites(for: identity, with: .disconnected)
        emit(.disconnectedInSession(identity, error: mapped))
        clearSessionOnQueue(clearDelegate: true)
    }

    private func forwardDidDiscoverServices(
        _ peripheral: CBPeripheral,
        error: Error?,
        identity: TransportSessionIdentity
    ) {
        guard isCurrent(identity, peripheral: peripheral) else { return }
        let ids = (peripheral.services ?? []).compactMap { Self.id(for: $0.uuid) }
        emit(.servicesDiscoveredInSession(identity, services: error == nil ? ids : []))
    }

    private func forwardDidDiscoverCharacteristics(
        _ peripheral: CBPeripheral,
        service: CBService,
        error: Error?,
        identity: TransportSessionIdentity
    ) {
        guard isCurrent(identity, peripheral: peripheral),
              service.uuid == CBUUID(string: profile.service.uuidString) else { return }
        let descriptors: [CharacteristicDescriptor] = (service.characteristics ?? []).compactMap { characteristic in
            let properties: CharacteristicProperties = [
                characteristic.properties.contains(.write) ? .write : [],
                characteristic.properties.contains(.writeWithoutResponse) ? .writeWithoutResponse : [],
                characteristic.properties.contains(.notify) ? .notify : [],
                characteristic.properties.contains(.indicate) ? .indicate : []
            ]
            guard let id = Self.id(for: characteristic.uuid) else { return nil }
            characteristics[id] = NativeCharacteristic(peripheral: peripheral, characteristic: characteristic)
            return CharacteristicDescriptor(id: id, properties: properties)
        }
        emit(.characteristicsDiscoveredInSession(
            identity,
            characteristics: error == nil ? descriptors : []
        ))
    }

    private func forwardDidUpdateNotificationState(
        _ peripheral: CBPeripheral,
        characteristic: CBCharacteristic,
        error: Error?,
        identity: TransportSessionIdentity
    ) {
        guard isCurrent(identity, peripheral: peripheral),
              let id = Self.id(for: characteristic.uuid),
              let native = characteristics[id],
              native.peripheral === peripheral,
              native.characteristic === characteristic else { return }
        emit(.notificationStateChangedInSession(
            identity,
            characteristic: id,
            enabled: error == nil && characteristic.isNotifying
        ))
    }

    private func forwardDidUpdateValue(
        _ peripheral: CBPeripheral,
        characteristic: CBCharacteristic,
        error: Error?,
        identity: TransportSessionIdentity
    ) {
        guard error == nil,
              isCurrent(identity, peripheral: peripheral),
              let value = characteristic.value,
              let id = Self.id(for: characteristic.uuid),
              let native = characteristics[id],
              native.peripheral === peripheral,
              native.characteristic === characteristic else { return }
        emit(.valueInSession(identity, characteristic: id, value))
    }

    private func forwardDidWriteValue(
        _ peripheral: CBPeripheral,
        characteristic: CBCharacteristic,
        error: Error?,
        identity: TransportSessionIdentity
    ) {
        guard isCurrent(identity, peripheral: peripheral),
              let id = Self.id(for: characteristic.uuid),
              let native = characteristics[id],
              native.peripheral === peripheral,
              native.characteristic === characteristic else { return }
        let mapped = Self.transportError(error)
        if let pending = pendingWrites[id], pending.identity == identity {
            pendingWrites.removeValue(forKey: id)
            writeRequests.remove(pending.requestID)
            if let mapped { pending.continuation.resume(throwing: mapped) }
            else { pending.continuation.resume(returning: ()) }
        }
        emit(.writeCompletedInSession(identity, characteristic: id, error: mapped))
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let identity = identity(for: peripheral) else { return }
        forwardDidDiscoverServices(peripheral, error: error, identity: identity)
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard let identity = identity(for: peripheral),
              service.uuid == CBUUID(string: profile.service.uuidString) else { return }
        forwardDidDiscoverCharacteristics(
            peripheral,
            service: service,
            error: error,
            identity: identity
        )
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard let identity = identity(for: peripheral) else { return }
        forwardDidUpdateNotificationState(
            peripheral,
            characteristic: characteristic,
            error: error,
            identity: identity
        )
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard let identity = identity(for: peripheral) else { return }
        forwardDidUpdateValue(
            peripheral,
            characteristic: characteristic,
            error: error,
            identity: identity
        )
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard let identity = identity(for: peripheral) else { return }
        forwardDidWriteValue(
            peripheral,
            characteristic: characteristic,
            error: error,
            identity: identity
        )
    }

    public func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        guard let identity = identity(for: peripheral) else { return }
        forwardDidReadRSSI(peripheral, rssi: RSSI, error: error, identity: identity)
    }

    private func remember(_ peripheral: CBPeripheral) {
        peripherals[peripheral.identifier] = peripheral
    }

    private func currentPeripheralOnQueue() -> CBPeripheral? {
        guard let identity = activeIdentity,
              identity.peripheral == selectedPeripheral,
              let activePeripheral,
              activePeripheral.identifier == identity.peripheral else { return nil }
        return activePeripheral
    }

    private func identity(for peripheral: CBPeripheral) -> TransportSessionIdentity? {
        guard let identity = activeIdentity,
              let activePeripheral,
              activePeripheral === peripheral,
              selectedPeripheral == peripheral.identifier,
              identity.peripheral == peripheral.identifier else { return nil }
        return identity
    }

    private func isCurrent(
        _ identity: TransportSessionIdentity,
        peripheral: CBPeripheral
    ) -> Bool {
        activeIdentity == identity
            && activePeripheral === peripheral
            && selectedPeripheral == peripheral.identifier
            && identity.peripheral == peripheral.identifier
    }

    private func stopScanOnQueue() {
        guard scanning else { return }
        central.stopScan()
        scanning = false
    }

    private func clearSessionOnQueue(clearDelegate: Bool) {
        failPendingSignalReads(for: activeIdentity)
        if clearDelegate {
            activePeripheral?.delegate = nil
            activeDelegate?.invalidate()
        }
        activeDelegate = nil
        didConnectToken = nil
        characteristics.removeAll(keepingCapacity: false)
        selectedPeripheral = nil
        activePeripheral = nil
        activeIdentity = nil
    }

    private func cancelWrite(requestID: UUID, characteristic: CharacteristicID) {
        callbackQueue.async { [weak self] in
            guard let self else { return }
            if let pending = self.pendingWrites[characteristic], pending.requestID == requestID {
                self.pendingWrites.removeValue(forKey: characteristic)
                self.writeRequests.remove(requestID)
                pending.continuation.resume(throwing: TransportError.cancelled)
            } else if self.writeRequests.remove(requestID) != nil {
                // The cancellation handler can run before the callback queue
                // installs the pending continuation.  Leave a one-shot marker
                // for that queued install; the native write is never started.
                self.cancelledWriteRequests.insert(requestID)
            }
        }
    }

    private func releaseOwner() {
        let shouldRelease = ownerReleaseLock.withLock { () -> Bool in
            guard !ownerReleased else { return false }
            ownerReleased = true
            return true
        }
        if shouldRelease { ownerRegistry.release(ownerToken) }
    }

    private func failPendingWrites(with error: TransportError) {
        failPendingSignalReads()
        let pending = pendingWrites.values
        pendingWrites.removeAll(keepingCapacity: false)
        writeRequests.removeAll(keepingCapacity: false)
        cancelledWriteRequests.removeAll(keepingCapacity: false)
        pending.forEach { $0.continuation.resume(throwing: error) }
    }

    private func failPendingWrites(for identity: TransportSessionIdentity?, with error: TransportError) {
        guard let identity else {
            failPendingWrites(with: error)
            return
        }
        let matching = pendingWrites.filter { $0.value.identity == identity }
        matching.keys.forEach { pendingWrites.removeValue(forKey: $0) }
        matching.values.forEach {
            writeRequests.remove($0.requestID)
            $0.continuation.resume(throwing: error)
        }
    }

    private func emit(_ event: TransportEvent) {
        continuation?.yield(event)
    }

    private static func managerState(_ state: CBManagerState) -> ManagerState {
        switch state {
        case .unknown: .unknown
        case .resetting: .resetting
        case .unsupported: .unsupported
        case .unauthorized: .unauthorized
        case .poweredOff: .poweredOff
        case .poweredOn: .poweredOn
        @unknown default: .unknown
        }
    }

    private static func id(for uuid: CBUUID) -> UUID? {
        UUID(uuidString: uuid.uuidString)
    }

    static func transportError(_ error: Error?) -> TransportError? {
        guard let error else { return nil }
        let nsError = error as NSError
        if nsError.domain == CBError.errorDomain {
            switch CBError.Code(rawValue: nsError.code) {
            case .connectionTimeout, .connectionLimitReached: return .timeout
            case .peripheralDisconnected: return .disconnected
            case .peerRemovedPairingInformation: return .peerRemovedPairing
            case .operationCancelled: return .cancelled
            default: break
            }
        }
        if nsError.domain == CBATTError.errorDomain {
            switch CBATTError.Code(rawValue: nsError.code) {
            case .insufficientAuthentication: return .insufficientAuthentication
            case .insufficientEncryption: return .insufficientEncryption
            default: break
            }
        }
        return .disconnected
    }
}
#endif
