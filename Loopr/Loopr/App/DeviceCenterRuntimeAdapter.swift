import AnalyticsKit
import BluetoothKit
import DeviceCenterKit
import DomainKit
import Foundation
import ProtocolKit
import SyncKit

/// The app-facing projection of the one SyncKit runtime already owned by the
/// Bluetooth application model.  Device Center may observe state and request
/// a bounded history sync through this seam, but it cannot issue raw BLE
/// writes or create another transport owner.
nonisolated protocol LooprDeviceCenterRuntime: LooprHeartLiveRuntime, Sendable {
    func runtimeState() async -> BluetoothAdoptionRuntimeState
    func performManualSync(maxDuration: TimeInterval) async -> Bool
    func diagnosticsSnapshot() async -> ConnectionDiagnosticsSnapshot

    // Semantic band operations. Each one mirrors a SyncKit runtime method, so
    // no app code builds an opcode or a raw payload. The default bodies below
    // fail closed, which keeps every existing test fake compiling.
    func setHeartRateSharing(enabled: Bool) async throws -> Bool?
    func readHeartRateSharing() async throws -> Bool?
    func renameBand(to name: String) async throws
    func buzzBand(effect: UInt8) async throws
    func buzzBand(effect: UInt8, expectedGeneration: UInt64) async throws
    func setBandAlarm(fireDate: Date) async throws
    func readBandAlarm() async throws -> Date?
    func testBandAlarm() async throws
    func disableBandAlarm() async throws
    func bandEvents() async -> AsyncStream<BandEventEnvelope>

    #if DEBUG
    /// Byte-level hardware experiments driven from the debug alarm request
    /// file. Present only in DEBUG builds; the firewall still fences it.
    @discardableResult
    func sendDebugRawBandCommand(body: Data, expectingOpcode: UInt8?) async throws -> Data
    #endif

    /// The band's signal strength in dBm while it is connected, for the
    /// "Find my strap" hunt. Nil means there is nothing to guide with; it is
    /// not an error, so the screen says the guidance is unavailable rather
    /// than showing a failure.
    func readSignalStrength() async -> Int?

    /// False while a stable stand-in has no runtime behind it, which is the
    /// case before a band is paired. Device Center then shows what it has
    /// stored instead of reporting a stopped session.
    func hasBoundRuntime() async -> Bool
}

extension LooprDeviceCenterRuntime {
    func readHeartRateSharing() async throws -> Bool? { nil }
    func setHeartRateSharing(enabled: Bool) async throws -> Bool? {
        throw LooprDeviceRuntimeCommandError.unavailable
    }

    func diagnosticsSnapshot() async -> ConnectionDiagnosticsSnapshot {
        ConnectionDiagnosticsSnapshot(events: [], violations: [])
    }

    func renameBand(to name: String) async throws {
        throw LooprDeviceRuntimeCommandError.unavailable
    }

    func buzzBand(effect: UInt8) async throws {
        throw LooprDeviceRuntimeCommandError.unavailable
    }

    func buzzBand(effect: UInt8, expectedGeneration: UInt64) async throws {
        throw LooprDeviceRuntimeCommandError.unavailable
    }

    func setBandAlarm(fireDate: Date) async throws {
        throw LooprDeviceRuntimeCommandError.unavailable
    }

    func readBandAlarm() async throws -> Date? {
        throw LooprDeviceRuntimeCommandError.unavailable
    }

    func testBandAlarm() async throws {
        throw LooprDeviceRuntimeCommandError.unavailable
    }

    func disableBandAlarm() async throws {
        throw LooprDeviceRuntimeCommandError.unavailable
    }

    func bandEvents() async -> AsyncStream<BandEventEnvelope> {
        AsyncStream { $0.finish() }
    }

    func readSignalStrength() async -> Int? { nil }

    func hasBoundRuntime() async -> Bool { true }

    #if DEBUG
    @discardableResult
    func sendDebugRawBandCommand(body: Data, expectingOpcode: UInt8?) async throws -> Data {
        throw LooprDeviceRuntimeCommandError.unavailable
    }
    #endif
}

/// Drives the signal reading behind "Find my strap".
///
/// One read a second while the hunt screen is open, and none at all otherwise.
/// The loop belongs in the screen's own `task`, so closing the screen cancels
/// it; nothing here scans, and nothing here runs in the background.
nonisolated struct FindMyStrapSignalPoll: Sendable {
    static let defaultIntervalSeconds: TimeInterval = 1

    let interval: TimeInterval

    init(interval: TimeInterval = FindMyStrapSignalPoll.defaultIntervalSeconds) {
        self.interval = interval
    }

    func run(
        reading: @escaping @Sendable () async -> Int?,
        emit: @escaping @Sendable (Int?) async -> Void
    ) async {
        while !Task.isCancelled {
            await emit(await reading())
            do { try await Task.sleep(for: .seconds(interval)) } catch { return }
        }
    }
}

/// One definition of "the band can take a command right now", shared by the
/// command writer and the capability projection so they cannot drift apart.
extension BluetoothAdoptionRuntimeState {
    nonisolated var acceptsBandCommands: Bool {
        running
            && setupComplete
            && connection.isConnected
            && radioState == .poweredOn
            && !health.stale
    }
}

extension BluetoothAdoptionRuntime: LooprDeviceCenterRuntime {
    public func runtimeState() async -> BluetoothAdoptionRuntimeState {
        await currentState()
    }

    public func performManualSync(maxDuration: TimeInterval) async -> Bool {
        await runBackgroundSync(maxDuration: maxDuration)
    }
}

/// Clears non-durable diagnostics after BluetoothApplicationModel has stopped
/// the shared runtime. This hook must never release transport ownership by
/// itself; product/history deletion is orchestrated separately by the model.
extension BluetoothAdoptionRuntime: PersistentDataDeletionDeleter {
    nonisolated var storeName: String { "bluetooth.runtime-cache-and-diagnostics" }

    public func deleteAll() async throws {
        await diagnostics.reset()
    }
}

enum LooprDeviceRuntimeCommandError: Error, Equatable, Sendable, LocalizedError {
    case unavailable
    case syncFailed
    case busy
    case unsupported(DeviceAction)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "Your strap is not connected right now. Bring it near your iPhone, then try again."
        case .syncFailed:
            "The sync did not finish. Any data already saved is still available."
        case .busy:
            "A device sync is already in progress."
        case .unsupported(let action):
            "No verified Bluetooth operation exists for \(action.rawValue)."
        }
    }
}

/// A command writer backed by the shared runtime.  Manual sync, rename, and
/// the find-my-strap buzz reach the band through SyncKit's semantic API.
/// Forget, deprovision, and pair again are iPhone-side actions and therefore
/// intentionally perform no transport write here.  Everything else hits the
/// fail-closed floor rather than becoming a guessed write.
actor SharedBluetoothDeviceCommandWriter: DeviceCommandWriter {
    private let runtime: any LooprDeviceCenterRuntime
    private let maxSyncDuration: TimeInterval
    private var manualSyncInFlight = false

    init(runtime: any LooprDeviceCenterRuntime, maxSyncDuration: TimeInterval = 30) {
        self.runtime = runtime
        self.maxSyncDuration = max(0.1, maxSyncDuration)
    }

    func send(_ command: DeviceCommand) async throws {
        switch command.action {
        case .manualSync:
            guard !manualSyncInFlight else {
                throw LooprDeviceRuntimeCommandError.busy
            }
            manualSyncInFlight = true
            defer { manualSyncInFlight = false }
            guard await runtime.runtimeState().acceptsBandCommands else {
                throw LooprDeviceRuntimeCommandError.unavailable
            }
            guard await runtime.performManualSync(maxDuration: maxSyncDuration) else {
                throw LooprDeviceRuntimeCommandError.syncFailed
            }

        case .rename:
            guard let argument = command.argument else {
                throw LooprDeviceRuntimeCommandError.unsupported(.rename)
            }
            // The wire name keeps the WHOOP prefix. Without it the accessory
            // picker stops matching the strap and it cannot be paired again.
            let bandName = try StrapNameRules.bandName(for: argument)
            try await requireReadyRuntime()
            try await reportingBandFailures { try await runtime.renameBand(to: bandName) }

        case .findMyStrap:
            try await requireReadyRuntime()
            // Effect 2 is the short double buzz. Effect 1 latches until the
            // user taps the strap, which is wrong for a casual hunt.
            try await reportingBandFailures { try await runtime.buzzBand(effect: 2) }

        case .rePair:
            // Re-pairing is an accessory operation on this iPhone. The band
            // has no opcode for it, so nothing is written here; the Device
            // Center feature runs removePairing and the pairing flow.
            return

        case .forgetBand, .deprovision:
            // CapabilityGatedDeviceActionService performs the canonical
            // repository deletion after this writer returns. No BLE command
            // is required for either local action.
            return

        default:
            throw LooprDeviceRuntimeCommandError.unsupported(command.action)
        }
    }

    private func requireReadyRuntime() async throws {
        guard await runtime.runtimeState().acceptsBandCommands else {
            throw LooprDeviceRuntimeCommandError.unavailable
        }
    }

    /// A transport result is not user copy. Translating here means the action
    /// service passes the message straight through instead of wrapping a
    /// Foundation error code in a second sentence.
    private func reportingBandFailures(
        _ operation: () async throws -> Void
    ) async throws {
        do {
            try await operation()
        } catch {
            throw DeviceActionError.deviceReported(BandActionCopy.readable(error))
        }
    }
}

/// Writer used when production has no shared runtime yet. It makes the
/// unavailable state explicit instead of silently accepting a command.
struct UnavailableDeviceCommandWriter: DeviceCommandWriter {
    init() {}

    func send(_ command: DeviceCommand) async throws {
        switch command.action {
        case .forgetBand, .deprovision:
            return
        default:
            throw LooprDeviceRuntimeCommandError.unavailable
        }
    }
}

enum DeviceCenterRuntimeProjection {
    nonisolated static func capabilities(
        existing: DeviceIdentity?,
        state: BluetoothAdoptionRuntimeState
    ) -> DeviceCapabilityMatrix {
        let bandReady = state.acceptsBandCommands
        let localActionsAvailable = existing != nil

        var statuses: [DeviceAction: DeviceCapabilityStatus] = [
            .manualSync: bandReady ? .supported : .unknown,
            .forgetBand: localActionsAvailable ? .supported : .unknown,
            .deprovision: localActionsAvailable ? .supported : .unknown,
            // These write to the band, so they need a live, fresh link.
            .rename: bandReady ? .supported : .unknown,
            .findMyStrap: bandReady ? .supported : .unknown,
            .strapAlarmSetup: bandReady ? .supported : .unknown,
            .strapAlarmReadback: bandReady ? .supported : .unknown,
            // The gesture map and re-pairing are iPhone-side records. They
            // stay usable while the strap is out of range.
            .displayGestureMapping: localActionsAvailable ? .supported : .unknown,
            .rePair: localActionsAvailable ? .supported : .unknown,
            // The strap only reports a double tap. These three run on this
            // iPhone, and their sinks ship with this build.
            .markMoment: localActionsAvailable ? .supported : .unknown,
            .ringPhone: localActionsAvailable ? .supported : .unknown,
            .torch: localActionsAvailable ? .supported : .unknown
        ]
        if state.bandModel == .whoop5 || state.bandModel == .whoopMG || state.bandModel == .unknownGen5 {
            // OpenStrap edge@82b094c3:lib/ble/ble_engine.dart:2747-2797
            // leaves these Gen 5 operations unverified. Keep local actions
            // and history sync, but do not expose Gen 4 band commands.
            statuses[.rename] = .notInLoopr
            statuses[.findMyStrap] = .notInLoopr
            statuses[.strapAlarmSetup] = .notInLoopr
            statuses[.strapAlarmReadback] = .notInLoopr
        }
        // Keep the dictionary total even if DeviceAction gains a new case.
        for action in DeviceAction.allCases where statuses[action] == nil {
            statuses[action] = .unknown
        }
        return DeviceCapabilityMatrix(statuses: statuses)
    }

    nonisolated static func identity(
        existing: DeviceIdentity?,
        state: BluetoothAdoptionRuntimeState
    ) -> DeviceIdentity? {
        let peripheral = peripheralIdentifier(from: state.connection) ?? existing?.peripheralIdentifier
        guard let peripheral else { return existing }
        let identity = existing?.peripheralIdentifier == peripheral ? existing : nil
        var generation = identity?.generation ?? .unknown
        // Only a Gen 4 band exposes the Harvard service and confirms all
        // three of its notifications.
        if generation == .unknown, state.setupReady {
            generation = switch state.bandModel {
            case .whoop5: .betaGen5
            case .whoopMG: .betaMG
            case .unknownGen5: .betaUnknownGen5
            default: .stableGen4
            }
        }
        return DeviceIdentity(
            id: identity?.id ?? DeviceID(rawValue: peripheral),
            peripheralIdentifier: peripheral,
            generation: generation,
            modelName: state.bandModel.map { model in
                switch model {
                case .whoop4: "WHOOP 4.0"
                case .whoop5: "WHOOP 5.0"
                case .whoopMG: "WHOOP MG"
                case .unknownGen5: "WHOOP 5.0 or MG"
                }
            } ?? identity?.modelName,
            displayName: state.advertisingName ?? identity?.displayName,
            modelConfidence: identity?.modelConfidence ?? .unknown,
            firmwareVersion: identity?.firmwareVersion,
            serialNumber: identity?.serialNumber,
            betaStatus: identity?.betaStatus,
            capabilities: capabilities(existing: identity, state: state)
        )
    }

    /// Turns the pinned AnalyticsKit drain projection into the two numbers
    /// Device Center renders. Anything the forecaster abstains on stays
    /// absent rather than becoming a guessed number of hours.
    nonisolated static func batteryForecast(
        _ forecast: AnalyticsKit.BatteryForecast?
    ) -> MetricReading<DeviceCenterKit.BatteryForecast> {
        guard let forecast, let rate = forecast.drainPctPerHour, rate > 0,
              let current = forecast.currentPct else { return .absent }
        let hours = current / rate
        guard hours.isFinite, hours >= 0 else { return .absent }
        let spanHours = Double(forecast.spanUsed.components.seconds) / 3_600
        let confidence: Confidence = if spanHours >= 12, forecast.samplesUsed >= 12 {
            .high
        } else if spanHours >= 6, forecast.samplesUsed >= 8 {
            .medium
        } else {
            .low
        }
        return .measured(DeviceCenterKit.BatteryForecast(hoursRemaining: hours, confidence: confidence))
    }

    nonisolated static func status(
        existing: DeviceStatusSnapshot?,
        state: BluetoothAdoptionRuntimeState,
        now: Date,
        forecast: AnalyticsKit.BatteryForecast? = nil
    ) -> DeviceStatusSnapshot {
        let connection = deviceConnection(for: state)
        let bluetooth = bluetoothAvailability(for: state.radioState)
        let restorationDescription: String?
        if state.bondRepairRequired != nil {
            restorationDescription = "Open Settings > Bluetooth, forget the band, then return to Loopr to pair it again."
        } else if let lastError = state.lastError, !lastError.isEmpty,
                  LooprRuntimeStateClassifier.sessionEnded(state) {
            // Device Center is the second surface that renders this
            // diagnostic string, so it needs the same translation. A failed
            // keep-alive on a live link is not news; the export keeps it.
            restorationDescription = ConnectionErrorCopy.readable(lastError)
        } else if state.health.stale {
            restorationDescription = "The last device observation is stale."
        } else if state.historyOffloadActive || state.pendingHistoryReplayCount > 0 {
            restorationDescription = "Syncing your band's history."
        } else if !state.running {
            restorationDescription = "Not connected."
        } else if state.setupComplete && state.connection.isConnected {
            restorationDescription = "Ready"
        } else {
            restorationDescription = "Connecting to your band."
        }

        return DeviceStatusSnapshot(
            connection: connection,
            bluetooth: bluetooth,
            restorationDescription: restorationDescription,
            batteryPercent: state.batteryPercentage.map { .measured(Int($0.rounded())) } ?? existing?.batteryPercent ?? .absent,
            charging: state.charging,
            batteryForecast: batteryForecast(forecast),
            wristState: state.onWrist.map { $0 ? .worn : .notWorn } ?? .unknown,
            freshness: state.historyCommitAt.map { .measured($0) } ?? existing?.freshness ?? .absent,
            lastPacketAt: state.lastPacketAt ?? existing?.lastPacketAt,
            historyCommitAt: state.historyCommitAt ?? existing?.historyCommitAt,
            completedSyncAt: state.completedSyncAt ?? existing?.completedSyncAt,
            storedAt: now,
            bondRepairRequired: deviceBondRepairReason(state.bondRepairRequired)
        )
    }

    private nonisolated static func deviceBondRepairReason(
        _ reason: BluetoothBondRepairReason?
    ) -> DeviceBondRepairReason? {
        switch reason {
        case .firstWriteTimeoutLoop: .firstWriteTimeoutLoop
        case .insufficientAuthentication: .insufficientAuthentication
        case .insufficientEncryption: .insufficientEncryption
        case .peerRemovedPairing: .peerRemovedPairing
        case nil: nil
        }
    }

    private nonisolated static func peripheralIdentifier(from state: BluetoothConnectionState) -> UUID? {
        switch state {
        case .connecting(_, let peripheral), .discovering(_, let peripheral),
                .subscribing(_, let peripheral), .settingUp(_, let peripheral),
                .listening(_, let peripheral):
            peripheral
        case .idle, .retrieving, .scanning, .reconnecting, .outOfRange, .bluetoothOff:
            nil
        }
    }

    private nonisolated static func deviceConnection(for state: BluetoothAdoptionRuntimeState) -> DeviceConnection {
        if state.historyOffloadActive || state.pendingHistoryReplayCount > 0 { return .synchronizing }
        switch state.connection {
        case .listening:
            return .connected
        case .retrieving:
            return .synchronizing
        case .scanning, .connecting, .discovering, .subscribing, .settingUp, .reconnecting:
            return .connecting
        case .idle, .outOfRange, .bluetoothOff:
            return .disconnected
        }
    }

    private nonisolated static func bluetoothAvailability(for state: ConnectionRadioState) -> BluetoothAvailability {
        switch state {
        case .unknown, .resetting:
            .unknown
        case .poweredOn:
            .poweredOn
        case .poweredOff:
            .poweredOff
        case .unauthorized:
            .permissionDenied
        case .unsupported:
            .unsupported
        case .outOfRange:
            .poweredOn
        }
    }
}

/// Wraps the canonical durable Device Center repository with live runtime
/// state. Reads remain canonical for identity and persisted metrics; the
/// connection/capability projection is derived from the shared runtime.
/// The durable battery readings the forecaster needs. The runtime only ever
/// reports the current percentage, so the drain rate has to come from a log
/// this app keeps.
nonisolated protocol LooprBatterySampleLog: Sendable, BatterySampleRepository {
    func record(percent: Double, charging: Bool?, at date: Date) async
}

nonisolated protocol LooprBandStateRecording: Sendable {
    func recordBandState(_ event: BandEventEnvelope) async
}

actor RuntimeDeviceCenterRepository: LooprBandStateRecording, DeviceCenterRepository, DeviceCenterDiagnosticsRepository, StrapAlarmConfigurationRepository {
    private let base: any DeviceCenterRepository
    private let alarmRepository: (any StrapAlarmConfigurationRepository)?
    private let runtime: any LooprDeviceCenterRuntime
    private let dateProvider: any DateProviding
    private let batteryLog: (any LooprBatterySampleLog)?
    private let forecaster = BatteryForecaster()

    init(
        base: any DeviceCenterRepository,
        alarmRepository: (any StrapAlarmConfigurationRepository)? = nil,
        runtime: any LooprDeviceCenterRuntime,
        dateProvider: any DateProviding = SystemDateProvider(),
        batteryLog: (any LooprBatterySampleLog)? = nil
    ) {
        self.base = base
        self.alarmRepository = alarmRepository
        self.runtime = runtime
        self.dateProvider = dateProvider
        self.batteryLog = batteryLog
    }

    func recordBandState(_ event: BandEventEnvelope) async {
        guard await runtime.runtimeState().generation == event.generation else { return }
        if let percent = event.batteryPercentage {
            await batteryLog?.record(percent: percent, charging: event.charging, at: event.receivedAt)
        }
        _ = try? await readStatus()
    }

    func readIdentity() async throws -> DeviceIdentity? {
        let stored = try await base.readIdentity()
        guard await runtime.hasBoundRuntime() else { return stored }
        let identity = DeviceCenterRuntimeProjection.identity(existing: stored, state: await runtime.runtimeState())
        if let identity, identity != stored { try await base.saveIdentity(identity) }
        return identity
    }

    func readStatus() async throws -> DeviceStatusSnapshot? {
        let stored = try await base.readStatus()
        guard await runtime.hasBoundRuntime() else { return stored }
        let state = await runtime.runtimeState()
        let now = dateProvider.now()
        var forecast: AnalyticsKit.BatteryForecast?
        if let batteryLog {
            if let percent = state.batteryPercentage {
                await batteryLog.record(percent: percent, charging: state.charging, at: now)
            }
            // The wake time only shifts the predicted level at wake, which
            // Device Center does not render. The hours-remaining figure this
            // screen shows comes from the drain rate alone.
            forecast = try? await forecaster.forecast(
                samples: batteryLog.samples(through: now),
                now: now,
                wakeAt: now
            )
        }
        let status = DeviceCenterRuntimeProjection.status(
            existing: stored, state: state, now: now, forecast: forecast
        )
        try await base.saveStatus(status)
        return status
    }

    func saveIdentity(_ identity: DeviceIdentity) async throws {
        try await base.saveIdentity(identity)
    }

    func saveStatus(_ status: DeviceStatusSnapshot) async throws {
        try await base.saveStatus(status)
    }

    func readConnectionDiagnostics() async -> DeviceFirstSessionDiagnostics {
        DeviceFirstSessionDiagnostics(snapshot: await runtime.diagnosticsSnapshot())
    }

    func forgetBand() async throws {
        try await base.forgetBand()
    }

    func deprovision() async throws {
        try await base.deprovision()
    }

    func readAlarmConfiguration() async throws -> StrapAlarmConfiguration? {
        guard let alarmRepository else { return nil }
        return try await alarmRepository.readAlarmConfiguration()
    }

    func saveAlarmConfiguration(_ configuration: StrapAlarmConfiguration) async throws {
        guard let alarmRepository else {
            throw DeviceConfigurationError.invalidAlarmConfiguration
        }
        try await alarmRepository.saveAlarmConfiguration(configuration)
    }
}
