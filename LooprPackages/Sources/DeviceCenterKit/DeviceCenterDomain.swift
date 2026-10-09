import DomainKit
import Foundation

public enum DeviceGeneration: String, Codable, CaseIterable, Sendable {
    case stableGen4
    case betaGen5
    case betaMG
    case betaUnknownGen5
    case unknown

    public var displayName: String {
        switch self {
        case .stableGen4: "WHOOP 4.0"
        case .betaGen5: "WHOOP 5.0"
        case .betaMG: "WHOOP MG"
        case .betaUnknownGen5: "WHOOP 5.0 or MG"
        case .unknown: "Unknown model"
        }
    }
}

public enum ModelConfidence: String, Codable, CaseIterable, Sendable {
    case unknown
    case fixtureVerified
    case hardwareVerified
}

public enum DeviceAction: String, Codable, CaseIterable, Hashable, Sendable {
    case manualSync
    case rename
    case forgetBand
    case deprovision
    case rePair
    case findMyStrap
    case strapAlarmSetup
    case strapAlarmReadback
    case displayGestureMapping
    case markMoment
    case ringPhone
    case torch

    public var displayName: String {
        switch self {
        case .manualSync: "Manual sync"
        case .rename: "Rename strap"
        case .forgetBand: "Forget strap"
        case .deprovision: "Remove pairing"
        case .rePair: "Pair again"
        case .findMyStrap: "Find my strap"
        case .strapAlarmSetup: "Strap alarm"
        case .strapAlarmReadback: "Alarm status"
        case .displayGestureMapping: "Gesture controls"
        case .markMoment: "Mark a moment"
        case .ringPhone: "Ring iPhone"
        case .torch: "Control flashlight"
        }
    }

    public var symbolName: String {
        switch self {
        case .manualSync: "arrow.trianglehead.2.clockwise.rotate.90"
        case .rename: "pencil"
        case .forgetBand, .deprovision: "link.badge.minus"
        case .rePair: "link.badge.plus"
        case .findMyStrap: "location.magnifyingglass"
        case .strapAlarmSetup, .strapAlarmReadback: "alarm"
        case .displayGestureMapping: "hand.tap"
        case .markMoment: "bookmark"
        case .ringPhone: "iphone.radiowaves.left.and.right"
        case .torch: "flashlight.on.fill"
        }
    }
}

public enum DeviceGesture: String, Codable, CaseIterable, Hashable, Sendable {
    case singleTap
    case doubleTap
    case longPress
    case wristRaise

    public var displayName: String {
        switch self {
        case .singleTap: "Single tap"
        case .doubleTap: "Double tap"
        case .longPress: "Long press"
        case .wristRaise: "Raise wrist"
        }
    }
}

public struct DeviceGestureMapping: Codable, Equatable, Hashable, Sendable {
    public let gesture: DeviceGesture
    public let action: DeviceAction?

    public init(gesture: DeviceGesture, action: DeviceAction?) {
        self.gesture = gesture
        self.action = action
    }
}

public enum DeviceCapabilityStatus: String, Codable, CaseIterable, Sendable {
    case supported
    case unsupported
    /// The band can do this, but Loopr has not built it yet.
    case notInLoopr
    case unknown

    /// Stable copy used by the package-owned surface.  `unknown` is kept
    /// distinct from `unsupported`: both are unavailable to callers, but only
    /// the latter is a confirmed hardware limitation.
    public var presentationTitle: String {
        switch self {
        case .supported: "Available"
        case .unsupported: "Not supported by this strap"
        case .notInLoopr: "Not in Loopr yet"
        case .unknown: "Not verified"
        }
    }

    public var isAvailable: Bool { self == .supported }
}

public struct DeviceCapabilityMatrix: Codable, Equatable, Sendable {
    public let supportedActions: Set<DeviceAction>
    /// Per-action status is intentionally retained instead of collapsing a
    /// beta/unknown capability into one aggregate supported flag.
    public let statuses: [DeviceAction: DeviceCapabilityStatus]

    public init(
        supportedActions: Set<DeviceAction> = [],
        statuses: [DeviceAction: DeviceCapabilityStatus] = [:]
    ) {
        var allowed = supportedActions
        var normalized = statuses
        for action in DeviceAction.allCases {
            if normalized[action] == nil {
                normalized[action] = allowed.contains(action) ? .supported : .unknown
            }
            if normalized[action] == .supported {
                allowed.insert(action)
            }
        }
        self.supportedActions = allowed
        self.statuses = normalized
    }

    private enum CodingKeys: String, CodingKey {
        case supportedActions
        case statuses
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let supported = try container.decodeIfPresent(Set<DeviceAction>.self, forKey: .supportedActions) ?? []
        let statuses = try container.decodeIfPresent([DeviceAction: DeviceCapabilityStatus].self, forKey: .statuses) ?? [:]
        self.init(supportedActions: supported, statuses: statuses)
    }

    public func status(for action: DeviceAction) -> DeviceCapabilityStatus {
        statuses[action] ?? (supportedActions.contains(action) ? .supported : .unknown)
    }

    public func allows(_ action: DeviceAction) -> Bool { status(for: action) == .supported }

    public var rows: [DeviceCapabilityRow] {
        DeviceAction.allCases.map { DeviceCapabilityRow(action: $0, status: status(for: $0)) }
    }

    public static let none = Self()
}

public struct DeviceCapabilityRow: Codable, Equatable, Hashable, Sendable {
    public let action: DeviceAction
    public let status: DeviceCapabilityStatus

    public init(action: DeviceAction, status: DeviceCapabilityStatus) {
        self.action = action
        self.status = status
    }

    public var presentationTitle: String { status.presentationTitle }

    public var accessibilityLabel: String {
        action.displayName + ", " + status.presentationTitle
    }
}

public struct DeviceIdentity: Codable, Equatable, Sendable {
    public let id: DeviceID
    public let peripheralIdentifier: UUID?
    public let generation: DeviceGeneration
    public let modelName: String?
    public let displayName: String?
    public let modelConfidence: ModelConfidence
    public let firmwareVersion: String?
    public let serialNumber: String?
    public let betaStatus: String?
    public let capabilities: DeviceCapabilityMatrix

    public init(
        id: DeviceID,
        peripheralIdentifier: UUID? = nil,
        generation: DeviceGeneration,
        modelName: String? = nil,
        displayName: String? = nil,
        modelConfidence: ModelConfidence = .unknown,
        firmwareVersion: String? = nil,
        serialNumber: String? = nil,
        betaStatus: String? = nil,
        capabilities: DeviceCapabilityMatrix = .none
    ) {
        self.id = id
        self.peripheralIdentifier = peripheralIdentifier
        self.generation = generation
        self.modelName = modelName
        self.displayName = displayName
        self.modelConfidence = modelConfidence
        self.firmwareVersion = firmwareVersion
        self.serialNumber = serialNumber
        self.betaStatus = betaStatus
        self.capabilities = capabilities
    }

    public func renamed(to name: String) -> DeviceIdentity {
        DeviceIdentity(
            id: id,
            peripheralIdentifier: peripheralIdentifier,
            generation: generation,
            modelName: modelName,
            displayName: name,
            modelConfidence: modelConfidence,
            firmwareVersion: firmwareVersion,
            serialNumber: serialNumber,
            betaStatus: betaStatus,
            capabilities: capabilities
        )
    }
}

public enum DeviceConnection: String, Codable, CaseIterable, Sendable {
    case disconnected
    case connecting
    case connected
    case synchronizing

    public var displayName: String {
        switch self {
        case .disconnected: "Disconnected"
        case .connecting: "Connecting"
        case .connected: "Connected"
        case .synchronizing: "Syncing"
        }
    }
}

public enum BluetoothAvailability: String, Codable, CaseIterable, Sendable {
    case unknown
    case poweredOn
    case poweredOff
    case unsupported
    case permissionDenied

    public var displayName: String {
        switch self {
        case .unknown: "Checking Bluetooth"
        case .poweredOn: "Bluetooth on"
        case .poweredOff: "Bluetooth off"
        case .unsupported: "Bluetooth unavailable"
        case .permissionDenied: "Bluetooth access denied"
        }
    }
}

public enum WristState: String, Codable, CaseIterable, Sendable {
    case unknown
    case worn
    case notWorn

    public var displayName: String {
        switch self {
        case .unknown: "Wear status unavailable"
        case .worn: "On wrist"
        case .notWorn: "Off wrist"
        }
    }
}

public enum AlarmWeekday: String, Codable, CaseIterable, Hashable, Sendable {
    case sunday
    case monday
    case tuesday
    case wednesday
    case thursday
    case friday
    case saturday
}

/// How the person wants to be woken.
public enum StrapAlarmMode: String, Codable, CaseIterable, Sendable {
    /// Wake at `startMinute`, every time.
    case exactTime
    /// Wake anywhere between `startMinute` and `endMinute`, earlier if Loopr
    /// sees the person surfacing. `endMinute` is the promise: the band alarm
    /// and the iPhone alarm are both armed for it.
    case wakeWindow
}

public struct StrapAlarmConfiguration: Codable, Equatable, Sendable {
    /// How long a wake window is when the person has not chosen one.
    public static let defaultWindowMinutes = 30

    public let isEnabled: Bool
    public let startMinute: Int?
    public let endMinute: Int?
    public let weekdays: Set<AlarmWeekday>
    public let updatedAt: Date?
    public let mode: StrapAlarmMode

    public init(
        isEnabled: Bool,
        startMinute: Int? = nil,
        endMinute: Int? = nil,
        weekdays: Set<AlarmWeekday> = [],
        updatedAt: Date? = nil,
        mode: StrapAlarmMode = .exactTime
    ) {
        self.isEnabled = isEnabled
        self.startMinute = startMinute
        self.endMinute = endMinute
        self.weekdays = weekdays
        self.updatedAt = updatedAt
        self.mode = mode
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled, startMinute, endMinute, weekdays, updatedAt, mode
    }

    /// Records written before wake windows existed carry no `mode`. They were
    /// all exact-time alarms, so that is what they decode as, rather than
    /// failing the whole read and losing the person's alarm.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        startMinute = try container.decodeIfPresent(Int.self, forKey: .startMinute)
        endMinute = try container.decodeIfPresent(Int.self, forKey: .endMinute)
        weekdays = try container.decodeIfPresent(Set<AlarmWeekday>.self, forKey: .weekdays) ?? []
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
        mode = try container.decodeIfPresent(StrapAlarmMode.self, forKey: .mode) ?? .exactTime
    }

    /// The minute of day Loopr guarantees a buzz at. In a wake window that is
    /// the end of the window, never the start.
    public var guaranteedMinute: Int? {
        switch mode {
        case .exactTime: startMinute
        case .wakeWindow: endMinute ?? startMinute
        }
    }

    /// How long the window is, walking forward over midnight. Zero in exact
    /// mode, and zero when the two ends are the same minute.
    public var windowMinutes: Int {
        guard mode == .wakeWindow, let startMinute, let endMinute else { return 0 }
        let span = endMinute - startMinute
        return span >= 0 ? span : span + 1_440
    }

    public func validated() throws -> StrapAlarmConfiguration {
        if let startMinute, !(0..<1_440).contains(startMinute) {
            throw DeviceConfigurationError.invalidAlarmConfiguration
        }
        if let endMinute, !(0..<1_440).contains(endMinute) {
            throw DeviceConfigurationError.invalidAlarmConfiguration
        }
        if isEnabled && (startMinute == nil || endMinute == nil || weekdays.isEmpty) {
            throw DeviceConfigurationError.invalidAlarmConfiguration
        }
        return self
    }
}

/// Turns a weekly repeat into the single occurrence the band can hold. The
/// band stores one absolute fire time, so Loopr re-arms the next one after
/// each alarm fires.
public enum StrapAlarmSchedulePlanner {
    /// The next moment strictly after `date` that Loopr guarantees a buzz at,
    /// or nil when the alarm is off or incomplete.
    ///
    /// In a wake window this is the end of the window. The band alarm and the
    /// iPhone alarm are both armed for it, so the latest promised time fires
    /// whatever else fails; waking early is the detector's job, not the
    /// schedule's.
    public static func nextFireDate(
        for configuration: StrapAlarmConfiguration,
        after date: Date,
        calendar: Calendar
    ) -> Date? {
        guard configuration.isEnabled,
              let minute = configuration.guaranteedMinute,
              (0..<1_440).contains(minute),
              !configuration.weekdays.isEmpty else {
            return nil
        }
        // Calendar matching walks the real calendar, so a spring-forward day
        // moves the alarm instead of dropping it. Adding 24 hour multiples
        // would slip by an hour twice a year.
        return configuration.weekdays
            .compactMap { weekday in
                calendar.nextDate(
                    after: date,
                    matching: DateComponents(
                        hour: minute / 60,
                        minute: minute % 60,
                        weekday: weekday.calendarWeekday
                    ),
                    matchingPolicy: .nextTime
                )
            }
            .min()
    }

    /// When the next wake window opens, or nil outside window mode.
    ///
    /// Derived by walking back from the guaranteed end rather than matching
    /// the start minute on its own, so a window that crosses midnight, or one
    /// whose start lands on an unselected weekday, still belongs to the right
    /// night.
    public static func nextWindowStart(
        for configuration: StrapAlarmConfiguration,
        after date: Date,
        calendar: Calendar
    ) -> Date? {
        guard configuration.mode == .wakeWindow, configuration.windowMinutes > 0 else { return nil }
        guard let end = nextFireDate(for: configuration, after: date, calendar: calendar) else {
            return nil
        }
        return calendar.date(byAdding: .minute, value: -configuration.windowMinutes, to: end)
    }
}

public extension AlarmWeekday {
    /// Foundation numbers Sunday as 1 in the Gregorian calendar.
    var calendarWeekday: Int {
        switch self {
        case .sunday: 1
        case .monday: 2
        case .tuesday: 3
        case .wednesday: 4
        case .thursday: 5
        case .friday: 6
        case .saturday: 7
        }
    }
}

public enum DeviceConfigurationError: Error, Equatable, Sendable, LocalizedError {
    case invalidAlarmConfiguration

    public var errorDescription: String? {
        "Choose a valid strap alarm time and at least one weekday."
    }
}

public struct BatteryForecast: Codable, Equatable, Sendable {
    public let hoursRemaining: Double
    public let confidence: Confidence

    public init(hoursRemaining: Double, confidence: Confidence) {
        self.hoursRemaining = hoursRemaining
        self.confidence = confidence
    }
}

public enum Confidence: String, Codable, CaseIterable, Sendable {
    case high
    case medium
    case low
}

public enum MetricReading<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    case absent
    case measured(Value)

    public var isAbsent: Bool {
        if case .absent = self { return true }
        return false
    }
}

public enum DeviceBondRepairReason: String, Codable, Equatable, Sendable {
    case firstWriteTimeoutLoop
    case insufficientAuthentication
    case insufficientEncryption
    case peerRemovedPairing
}

public struct DeviceStatusSnapshot: Codable, Equatable, Sendable {
    public let connection: DeviceConnection
    public let bluetooth: BluetoothAvailability
    public let restorationDescription: String?
    public let batteryPercent: MetricReading<Int>
    public let charging: Bool?
    public let batteryForecast: MetricReading<BatteryForecast>
    public let wristState: WristState
    public let freshness: MetricReading<Date>
    public let lastPacketAt: Date?
    public let historyCommitAt: Date?
    public let completedSyncAt: Date?
    public let storedAt: Date?
    public let bondRepairRequired: DeviceBondRepairReason?

    public init(
        connection: DeviceConnection,
        bluetooth: BluetoothAvailability,
        restorationDescription: String? = nil,
        batteryPercent: MetricReading<Int> = .absent,
        charging: Bool? = nil,
        batteryForecast: MetricReading<BatteryForecast> = .absent,
        wristState: WristState = .unknown,
        freshness: MetricReading<Date> = .absent,
        lastPacketAt: Date? = nil,
        historyCommitAt: Date? = nil,
        completedSyncAt: Date? = nil,
        storedAt: Date? = nil,
        bondRepairRequired: DeviceBondRepairReason? = nil
    ) {
        self.connection = connection
        self.bluetooth = bluetooth
        self.restorationDescription = restorationDescription
        self.batteryPercent = batteryPercent
        self.charging = charging
        self.batteryForecast = batteryForecast
        self.wristState = wristState
        self.freshness = freshness
        self.lastPacketAt = lastPacketAt
        self.historyCommitAt = historyCommitAt
        self.completedSyncAt = completedSyncAt
        self.storedAt = storedAt
        self.bondRepairRequired = bondRepairRequired
    }
}

public struct DeviceDiagnosticExport: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let generatedAt: Date
    public let identity: DeviceIdentity?
    public let status: DeviceStatusSnapshot?

    public init(
        schemaVersion: Int = currentSchemaVersion,
        generatedAt: Date,
        identity: DeviceIdentity?,
        status: DeviceStatusSnapshot?
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.identity = identity
        self.status = status
    }
}

public enum DeviceDiagnosticExporter {
    public static func make(
        identity: DeviceIdentity?,
        status: DeviceStatusSnapshot?,
        generatedAt: Date
    ) -> DeviceDiagnosticExport {
        DeviceDiagnosticExport(generatedAt: generatedAt, identity: identity, status: status)
    }

    public static func encode(_ export: DeviceDiagnosticExport) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(export)
    }
}

public protocol StrapAlarmConfigurationRepository: Sendable {
    func readAlarmConfiguration() async throws -> StrapAlarmConfiguration?
    func saveAlarmConfiguration(_ configuration: StrapAlarmConfiguration) async throws
}

public protocol DeviceCenterRepository: Sendable {
    func readIdentity() async throws -> DeviceIdentity?
    func readStatus() async throws -> DeviceStatusSnapshot?
    func saveIdentity(_ identity: DeviceIdentity) async throws
    func saveStatus(_ status: DeviceStatusSnapshot) async throws
    func forgetBand() async throws
    func deprovision() async throws
}

public actor InMemoryDeviceCenterRepository: DeviceCenterRepository, StrapAlarmConfigurationRepository {
    private var identity: DeviceIdentity?
    private var status: DeviceStatusSnapshot?
    private var alarmConfiguration: StrapAlarmConfiguration?

    public init(
        identity: DeviceIdentity? = nil,
        status: DeviceStatusSnapshot? = nil,
        alarmConfiguration: StrapAlarmConfiguration? = nil
    ) {
        self.identity = identity
        self.status = status
        self.alarmConfiguration = alarmConfiguration
    }

    public func readIdentity() async throws -> DeviceIdentity? { identity }
    public func readStatus() async throws -> DeviceStatusSnapshot? { status }
    public func saveIdentity(_ identity: DeviceIdentity) async throws { self.identity = identity }
    public func saveStatus(_ status: DeviceStatusSnapshot) async throws { self.status = status }

    public func readAlarmConfiguration() async throws -> StrapAlarmConfiguration? { alarmConfiguration }

    public func saveAlarmConfiguration(_ configuration: StrapAlarmConfiguration) async throws {
        alarmConfiguration = try configuration.validated()
    }

    public func forgetBand() async throws {
        identity = nil
        status = nil
        alarmConfiguration = nil
    }

    public func deprovision() async throws {
        identity = nil
        status = nil
        alarmConfiguration = nil
    }
}

public enum DeviceCenterUniversalState: String, CaseIterable, Codable, Sendable {
    case ready
    case loading
    case noRecordsYet
    case absentMetric
    case measuredZero
    case partialData
    case lowConfidence
    case settlingOrRecomputing
    case stale
    case disconnected
    case bluetoothOff
    case permissionDenied
    case unsupportedHardware
    case recoverableError
    case destructiveOrMigrationFailure
}

public struct DeviceCenterStateFixture: Equatable, Sendable {
    public let state: DeviceCenterUniversalState
    public let identity: DeviceIdentity?
    public let status: DeviceStatusSnapshot?
    public let message: String

    public init(state: DeviceCenterUniversalState, identity: DeviceIdentity?, status: DeviceStatusSnapshot?, message: String) {
        self.state = state
        self.identity = identity
        self.status = status
        self.message = message
    }
}

public enum DeviceCenterStateFixtures {
    public static let sampleDevice = DeviceIdentity(
        id: DeviceID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!),
        peripheralIdentifier: UUID(uuidString: "00000000-0000-0000-0000-000000000040"),
        generation: .stableGen4,
        modelName: "WHOOP 4.0",
        displayName: "Training strap",
        modelConfidence: .fixtureVerified,
        firmwareVersion: "4.0.0",
        serialNumber: "fixture-serial",
        betaStatus: nil,
        capabilities: DeviceCapabilityMatrix(supportedActions: Set(DeviceAction.allCases))
    )

    public static let unsupportedDevice = DeviceIdentity(
        id: sampleDevice.id,
        generation: .unknown,
        modelConfidence: .unknown,
        capabilities: .none
    )

    /// A deterministic launch fixture for a connected beta Gen 5 device whose
    /// capabilities have been qualified independently.  The matrix is total:
    /// no action falls back to an aggregate device-level flag.  Unknown and
    /// unsupported actions must both remain unavailable until a verified
    /// runtime adapter explicitly authorizes them.
    public static let connectedMixedCapabilitiesMatrix = DeviceCapabilityMatrix(
        supportedActions: [.manualSync, .rename, .forgetBand],
        statuses: [
            .manualSync: .supported,
            .rename: .supported,
            .forgetBand: .supported,
            .deprovision: .unknown,
            .rePair: .unknown,
            .findMyStrap: .unsupported,
            .strapAlarmSetup: .unsupported,
            .strapAlarmReadback: .unsupported,
            .displayGestureMapping: .unsupported,
            .markMoment: .unsupported,
            .ringPhone: .unsupported,
            .torch: .unsupported
        ]
    )

    public static let connectedMixedCapabilitiesDevice = DeviceIdentity(
        id: DeviceID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!),
        peripheralIdentifier: UUID(uuidString: "00000000-0000-0000-0000-000000000050"),
        generation: .betaGen5,
        modelName: "WHOOP 5.0",
        displayName: "Mixed capability strap",
        modelConfidence: .fixtureVerified,
        firmwareVersion: "5.0.0-beta",
        serialNumber: "mixed-capability-fixture",
        betaStatus: "capability-gated",
        capabilities: connectedMixedCapabilitiesMatrix
    )

    public static let populatedStatus = DeviceStatusSnapshot(
        connection: .connected,
        bluetooth: .poweredOn,
        restorationDescription: "Ready",
        batteryPercent: .measured(78),
        charging: false,
        batteryForecast: .measured(BatteryForecast(hoursRemaining: 42, confidence: .high)),
        wristState: .worn,
        freshness: .measured(Date(timeIntervalSince1970: 1_700_000_000)),
        lastPacketAt: Date(timeIntervalSince1970: 1_700_000_000),
        historyCommitAt: Date(timeIntervalSince1970: 1_700_000_001),
        completedSyncAt: Date(timeIntervalSince1970: 1_700_000_002),
        storedAt: Date(timeIntervalSince1970: 1_700_000_003)
    )

    public static let connectedMixedCapabilities = DeviceCenterStateFixture(
        state: .ready,
        identity: connectedMixedCapabilitiesDevice,
        status: populatedStatus,
        message: "Connected. Capabilities are individually verified."
    )

    public static let all: [DeviceCenterStateFixture] = DeviceCenterUniversalState.allCases.map { state in
        return switch state {
        case .ready:
            DeviceCenterStateFixture(state: state, identity: sampleDevice, status: populatedStatus, message: "Connected and ready.")
        case .loading:
            DeviceCenterStateFixture(state: state, identity: nil, status: nil, message: "Loading device status.")
        case .noRecordsYet:
            DeviceCenterStateFixture(state: state, identity: sampleDevice, status: nil, message: "No sync records yet.")
        case .absentMetric:
            DeviceCenterStateFixture(state: state, identity: sampleDevice, status: DeviceStatusSnapshot(connection: .connected, bluetooth: .poweredOn), message: "Battery forecast is not available.")
        case .measuredZero:
            DeviceCenterStateFixture(state: state, identity: sampleDevice, status: DeviceStatusSnapshot(connection: .connected, bluetooth: .poweredOn, batteryPercent: .measured(0)), message: "Measured battery is zero percent.")
        case .partialData:
            DeviceCenterStateFixture(state: state, identity: sampleDevice, status: DeviceStatusSnapshot(connection: .synchronizing, bluetooth: .poweredOn, batteryPercent: .measured(65)), message: "Sync is still in progress.")
        case .lowConfidence:
            DeviceCenterStateFixture(state: state, identity: sampleDevice, status: DeviceStatusSnapshot(connection: .connected, bluetooth: .poweredOn, batteryForecast: .measured(BatteryForecast(hoursRemaining: 5, confidence: .low))), message: "Forecast has low confidence.")
        case .settlingOrRecomputing:
            DeviceCenterStateFixture(state: state, identity: sampleDevice, status: DeviceStatusSnapshot(connection: .synchronizing, bluetooth: .poweredOn), message: "Device data is settling.")
        case .stale:
            DeviceCenterStateFixture(state: state, identity: sampleDevice, status: DeviceStatusSnapshot(connection: .connected, bluetooth: .poweredOn, restorationDescription: "Last packet is stale"), message: "The last packet is stale.")
        case .disconnected:
            DeviceCenterStateFixture(state: state, identity: sampleDevice, status: DeviceStatusSnapshot(connection: .disconnected, bluetooth: .poweredOn), message: "Device is disconnected.")
        case .bluetoothOff:
            DeviceCenterStateFixture(state: state, identity: sampleDevice, status: DeviceStatusSnapshot(connection: .disconnected, bluetooth: .poweredOff), message: "Bluetooth is off.")
        case .permissionDenied:
            DeviceCenterStateFixture(state: state, identity: sampleDevice, status: DeviceStatusSnapshot(connection: .disconnected, bluetooth: .permissionDenied), message: "Bluetooth permission is denied.")
        case .unsupportedHardware:
            DeviceCenterStateFixture(state: state, identity: unsupportedDevice, status: DeviceStatusSnapshot(connection: .disconnected, bluetooth: .unsupported), message: "This hardware is unsupported.")
        case .recoverableError:
            DeviceCenterStateFixture(state: state, identity: sampleDevice, status: DeviceStatusSnapshot(connection: .disconnected, bluetooth: .unknown, restorationDescription: "Try again"), message: "The device operation can be retried.")
        case .destructiveOrMigrationFailure:
            DeviceCenterStateFixture(state: state, identity: sampleDevice, status: DeviceStatusSnapshot(connection: .disconnected, bluetooth: .poweredOn, restorationDescription: "Data was preserved"), message: "The destructive operation failed safely.")
        }
    }
}

public enum RSSIGuidance: String, Codable, CaseIterable, Sendable {
    case warmer
    case colder
    case nearby
    case unavailable
}

public enum FindMyStrapHapticCue: String, Codable, CaseIterable, Sendable {
    case intensify
    case soften
    case neutral
    case unavailable
}

public struct FindMyStrapFeedback: Codable, Equatable, Sendable {
    public let guidance: RSSIGuidance
    public let haptic: FindMyStrapHapticCue

    public init(guidance: RSSIGuidance, haptic: FindMyStrapHapticCue) {
        self.guidance = guidance
        self.haptic = haptic
    }
}

public enum FindMyStrapGuidanceCalculator {
    public static func guidance(currentRSSI: Int?, previousRSSI: Int?, threshold: Int = 3) -> RSSIGuidance {
        guard let currentRSSI else { return .unavailable }
        guard let previousRSSI else { return .nearby }
        if currentRSSI - previousRSSI >= threshold { return .warmer }
        if previousRSSI - currentRSSI >= threshold { return .colder }
        return .nearby
    }

    public static func feedback(currentRSSI: Int?, previousRSSI: Int?, threshold: Int = 3) -> FindMyStrapFeedback {
        let guidance = guidance(currentRSSI: currentRSSI, previousRSSI: previousRSSI, threshold: threshold)
        let haptic: FindMyStrapHapticCue = switch guidance {
        case .warmer: .intensify
        case .colder: .soften
        case .nearby: .neutral
        case .unavailable: .unavailable
        }
        return FindMyStrapFeedback(guidance: guidance, haptic: haptic)
    }
}
