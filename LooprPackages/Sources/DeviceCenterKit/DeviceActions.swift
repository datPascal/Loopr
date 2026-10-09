import DomainKit
import Foundation

public struct DeviceCommand: Equatable, Sendable {
    public let action: DeviceAction
    public let argument: String?

    public init(action: DeviceAction, argument: String? = nil) {
        self.action = action
        self.argument = argument
    }
}

public enum DeviceActionError: Error, Equatable, Sendable, LocalizedError {
    case noDevice
    case unsupported(DeviceAction)
    case invalidArgument(DeviceAction)
    case debounced(DeviceAction)
    case writerUnavailable(DeviceAction)
    case writerFailed(String)
    /// A reason the device seam already wrote for a person. It passes through
    /// untouched so the copy is not wrapped in a second sentence.
    case deviceReported(String)

    public var errorDescription: String? {
        switch self {
        case .noDevice: "No device is paired."
        case .unsupported(let action): "This device does not support \(action.displayName.lowercased())."
        case .invalidArgument(let action): "The details for \(action.displayName.lowercased()) are invalid."
        case .debounced(let action): "\(action.displayName) is already in progress."
        case .writerUnavailable(let action): "\(action.displayName) is not available for this device."
        case .writerFailed(let reason): "The device command failed: \(reason)"
        case .deviceReported(let message): message
        }
    }
}

public protocol DeviceCommandWriter: Sendable {
    func send(_ command: DeviceCommand) async throws
}

/// Pairing matches any band whose advertised name contains "WHOOP", so the
/// name written to the strap keeps that prefix. Loopr shows and stores only
/// the part the user typed. The band accepts 20 printable ASCII bytes and the
/// prefix costs six of them, which leaves fourteen.
public enum StrapNameRules {
    public static let bandPrefix = "WHOOP "
    public static let maximumUserCharacters = 20 - bandPrefix.count

    /// One short line for the field, kept in Device Center's "strap" wording.
    public static let limitExplanation =
        "Up to \(maximumUserCharacters) letters, numbers, or spaces. Loopr keeps WHOOP at the front so you can pair the strap again."

    public static func trimmed(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Returns the user's part of the name, or throws when it is empty, too
    /// long, or carries a byte the band cannot advertise.
    public static func validatedUserName(_ raw: String) throws -> String {
        let candidate = trimmed(raw)
        guard !candidate.isEmpty,
              candidate.count <= maximumUserCharacters,
              isPrintableASCII(candidate) else {
            throw DeviceActionError.invalidArgument(.rename)
        }
        return candidate
    }

    /// The exact string written to the band.
    public static func bandName(for raw: String) throws -> String {
        bandPrefix + (try validatedUserName(raw))
    }

    /// Strips the prefix a previous rename added, so the field shows what the
    /// user typed rather than the wire name.
    public static func userName(fromBandName bandName: String) -> String {
        let candidate = trimmed(bandName)
        guard candidate.hasPrefix(bandPrefix) else { return candidate }
        return trimmed(String(candidate.dropFirst(bandPrefix.count)))
    }

    private static func isPrintableASCII(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { (0x20...0x7e).contains($0.value) }
    }
}

public struct NoopDeviceCommandWriter: DeviceCommandWriter {
    public init() {}
    /// A missing writer is an unavailable physical capability, not a
    /// successful fixture. Keep the result typed so UI can fail closed.
    public func send(_ command: DeviceCommand) async throws {
        throw DeviceActionError.writerUnavailable(command.action)
    }
}

public enum DeviceReadbackState: Codable, Equatable, Sendable {
    case unavailable(reason: String)
    case pending
    case confirmed

    public var isConfirmed: Bool {
        if case .confirmed = self { return true }
        return false
    }
}

/// Command dispatch and hardware readback are separate contracts. A command
/// writer cannot claim that a band applied a setting without a verified
/// readback adapter.
public protocol DeviceActionReadback: Sendable {
    func state(for action: DeviceAction) async -> DeviceReadbackState
}

public struct UnavailableDeviceActionReadback: DeviceActionReadback {
    public let reason: String

    public init(reason: String = "No verified device readback adapter is available.") {
        self.reason = reason
    }

    public func state(for action: DeviceAction) async -> DeviceReadbackState {
        _ = action
        return .unavailable(reason: reason)
    }
}

public actor RecordingDeviceActionReadback: DeviceActionReadback {
    private var values: [DeviceAction: DeviceReadbackState]

    public init(values: [DeviceAction: DeviceReadbackState] = [:]) {
        self.values = values
    }

    public func state(for action: DeviceAction) async -> DeviceReadbackState {
        values[action] ?? .unavailable(reason: "Readback has not been observed.")
    }

    public func set(_ state: DeviceReadbackState, for action: DeviceAction) {
        values[action] = state
    }
}

/// Alarm setup is deliberately a local repository operation. The APP-02
/// setup screen can persist a validated intent without sending a band command;
/// APP-13 owns the later readback/test/disable wire flow.
public struct DeviceAlarmSetupService: Sendable {
    private let repository: any StrapAlarmConfigurationRepository

    public init(repository: any StrapAlarmConfigurationRepository) {
        self.repository = repository
    }

    @discardableResult
    public func save(_ configuration: StrapAlarmConfiguration) async throws -> StrapAlarmConfiguration {
        let validated = try configuration.validated()
        try await repository.saveAlarmConfiguration(validated)
        return validated
    }

    public func load() async throws -> StrapAlarmConfiguration? {
        try await repository.readAlarmConfiguration()
    }
}

/// Commands pass through this actor only after the current identity's typed
/// capability matrix allows them.  Unsupported commands therefore cannot
/// reach the BLE writer, even if a caller constructs a command manually.
public actor CapabilityGatedDeviceActionService {
    private let repository: any DeviceCenterRepository
    private let writer: any DeviceCommandWriter
    private let dateProvider: any DateProviding
    private let debounceInterval: TimeInterval
    private var lastAcceptedAt: [DeviceAction: Date] = [:]

    public init(
        repository: any DeviceCenterRepository,
        writer: any DeviceCommandWriter,
        dateProvider: any DateProviding = SystemDateProvider(),
        debounceInterval: TimeInterval = 0.75
    ) {
        self.repository = repository
        self.writer = writer
        self.dateProvider = dateProvider
        self.debounceInterval = max(0, debounceInterval)
    }

    @discardableResult
    public func perform(_ command: DeviceCommand) async throws -> DeviceCommand {
        guard let identity = try await repository.readIdentity() else { throw DeviceActionError.noDevice }
        guard identity.capabilities.allows(command.action) else {
            throw DeviceActionError.unsupported(command.action)
        }
        try validate(command)

        let now = dateProvider.now()
        if shouldDebounce(command.action),
           let previous = lastAcceptedAt[command.action],
           now.timeIntervalSince(previous) < debounceInterval {
            throw DeviceActionError.debounced(command.action)
        }
        do {
            try await writer.send(command)
            switch command.action {
            case .rename:
                guard let argument = command.argument else {
                    throw DeviceActionError.invalidArgument(command.action)
                }
                // Loopr stores the user's part. The writer adds the WHOOP
                // prefix the band needs to stay pairable.
                try await repository.saveIdentity(
                    identity.renamed(to: try StrapNameRules.validatedUserName(argument))
                )
            case .forgetBand:
                try await repository.forgetBand()
            case .deprovision:
                try await repository.deprovision()
            default:
                break
            }
            lastAcceptedAt[command.action] = now
            return command
        } catch {
            if let typed = error as? DeviceActionError {
                throw typed
            }
            throw DeviceActionError.writerFailed(String(describing: error))
        }
    }

    public func perform(_ action: DeviceAction) async throws -> DeviceCommand {
        try await perform(DeviceCommand(action: action))
    }

    private func validate(_ command: DeviceCommand) throws {
        switch command.action {
        case .rename:
            guard let argument = command.argument else {
                throw DeviceActionError.invalidArgument(command.action)
            }
            _ = try StrapNameRules.validatedUserName(argument)
        default:
            break
        }
    }

    private func shouldDebounce(_ action: DeviceAction) -> Bool {
        switch action {
        case .findMyStrap, .strapAlarmSetup, .strapAlarmReadback, .markMoment, .ringPhone, .torch:
            true
        case .manualSync, .rename, .forgetBand, .deprovision, .rePair, .displayGestureMapping:
            false
        }
    }
}

public actor RecordingDeviceCommandWriter: DeviceCommandWriter {
    public private(set) var commands: [DeviceCommand] = []

    public init() {}
    public func send(_ command: DeviceCommand) async throws { commands.append(command) }
}

public struct DeviceCenterViewState: Equatable, Sendable {
    public let universalState: DeviceCenterUniversalState
    public let identity: DeviceIdentity?
    public let status: DeviceStatusSnapshot?
    public let message: String?
    public let diagnostics: DeviceFirstSessionDiagnostics?

    public init(
        universalState: DeviceCenterUniversalState,
        identity: DeviceIdentity?,
        status: DeviceStatusSnapshot?,
        message: String? = nil,
        diagnostics: DeviceFirstSessionDiagnostics? = nil
    ) {
        self.universalState = universalState
        self.identity = identity
        self.status = status
        self.message = message
        self.diagnostics = diagnostics
    }

    public var batteryAccessibilityValue: String {
        guard let status else { return "Battery unavailable" }
        switch status.batteryPercent {
        case .absent: return "Battery unavailable"
        case .measured(let value): return "Battery \(value) percent measured"
        }
    }

    public var forecastAccessibilityValue: String {
        guard let status else { return "Battery forecast unavailable" }
        switch status.batteryForecast {
        case .absent: return "Battery forecast unavailable"
        case .measured(let forecast):
            return "Battery forecast \(forecast.hoursRemaining.formatted(.number.precision(.fractionLength(1)))) hours, \(forecast.confidence.displayName) confidence"
        }
    }

    public var statusAccessibilityLabel: String {
        let state = message ?? universalState.accessibilityTitle
        return "\(state). \(batteryAccessibilityValue). \(forecastAccessibilityValue)."
    }

    public func isActionAvailable(_ action: DeviceAction) -> Bool {
        identity?.capabilities.status(for: action).isAvailable == true
    }

    public var capabilityRows: [DeviceCapabilityRow] {
        identity?.capabilities.rows ?? DeviceAction.allCases.map {
            DeviceCapabilityRow(action: $0, status: .unknown)
        }
    }
}

private extension Confidence {
    var displayName: String {
        switch self {
        case .high: "high"
        case .medium: "medium"
        case .low: "low"
        }
    }
}

private extension DeviceCenterUniversalState {
    var accessibilityTitle: String {
        switch self {
        case .ready: "Connected and ready"
        case .loading: "Loading"
        case .noRecordsYet: "No records yet"
        case .absentMetric: "Not measured"
        case .measuredZero: "Measured zero"
        case .partialData: "Partial data"
        case .lowConfidence: "Low confidence"
        case .settlingOrRecomputing: "Updating"
        case .stale: "Out of date"
        case .disconnected: "Strap disconnected"
        case .bluetoothOff: "Bluetooth off"
        case .permissionDenied: "Permission needed"
        case .unsupportedHardware: "Not supported by this strap"
        case .recoverableError: "Try again"
        case .destructiveOrMigrationFailure: "Needs attention"
        }
    }
}

public struct DeviceAccessibilityContract: Equatable, Sendable {
    public static let minimumTouchTarget: Double = 44
    public static let requiredScreenIdentifiers: Set<String> = [
        "device-center-screen",
        "device-manual-sync",
        "device-find-my-strap",
        "device-forget-band",
        "device-export-diagnostics",
        "device-first-session-diagnostics",
        "find-my-strap-screen",
        "strap-alarm-setup-screen",
        "strap-alarm-status-screen",
        "gesture-mapping-screen"
    ]

    public let supportsDynamicType: Bool
    public let supportsReduceMotion: Bool
    public let usesSemanticVoiceOverLabels: Bool

    public init(
        supportsDynamicType: Bool = true,
        supportsReduceMotion: Bool = true,
        usesSemanticVoiceOverLabels: Bool = true
    ) {
        self.supportsDynamicType = supportsDynamicType
        self.supportsReduceMotion = supportsReduceMotion
        self.usesSemanticVoiceOverLabels = usesSemanticVoiceOverLabels
    }
}

public enum DeviceCenterTelemetryPolicy {
    /// Device Center emits no analytics before explicit telemetry consent;
    /// diagnostic export is a user-triggered local operation.
    public static let emitsEventsBeforeConsent = false
}

public enum DeviceCenterViewStateLoader {
    public static var loading: DeviceCenterViewState {
        DeviceCenterViewState(universalState: .loading, identity: nil, status: nil, message: "Loading device status.")
    }

    public static func load(from repository: any DeviceCenterRepository) async throws -> DeviceCenterViewState {
        let identity = try await repository.readIdentity()
        let status = try await repository.readStatus()
        let diagnostics: DeviceFirstSessionDiagnostics?
        if let diagnosticsRepository = repository as? any DeviceCenterDiagnosticsRepository {
            diagnostics = await diagnosticsRepository.readConnectionDiagnostics()
        } else {
            diagnostics = nil
        }
        guard identity != nil || status != nil else {
            return DeviceCenterViewState(
                universalState: .noRecordsYet,
                identity: nil,
                status: nil,
                message: "No device data yet.",
                diagnostics: diagnostics
            )
        }
        guard let status else {
            return DeviceCenterViewState(
                universalState: .noRecordsYet,
                identity: identity,
                status: nil,
                message: "No sync records yet.",
                diagnostics: diagnostics
            )
        }

        let description = status.restorationDescription?.lowercased() ?? ""
        let state: DeviceCenterUniversalState
        let message: String?
        if status.bondRepairRequired != nil {
            state = .recoverableError
            message = "Open Settings > Bluetooth, forget the band, then return to Loopr to pair it again."
        } else if identity?.generation == .unknown,
                  status.connection == .connected || status.connection == .synchronizing {
            // The generation is only learned from a connected strap. Before
            // that, an unknown generation is not evidence of unsupported
            // hardware.
            state = .unsupportedHardware
            message = "This hardware is unsupported."
        } else {
            switch status.bluetooth {
            case .poweredOff:
                state = .bluetoothOff; message = "Bluetooth is off."
            case .permissionDenied:
                state = .permissionDenied; message = "Bluetooth permission is denied."
            case .unsupported:
                state = .unsupportedHardware; message = "This hardware is unsupported."
            case .unknown:
                state = .recoverableError; message = status.restorationDescription ?? "The device operation can be retried."
            case .poweredOn:
                if description.contains("destructive") || description.contains("migration") || description.contains("preserved") {
                    state = .destructiveOrMigrationFailure; message = status.restorationDescription
                } else if description.contains("stale") {
                    state = .stale; message = status.restorationDescription
                } else if description.contains("settling") || description.contains("recomput") {
                    state = .settlingOrRecomputing; message = status.restorationDescription
                } else if description.contains("error") || description.contains("retry") {
                    state = .recoverableError; message = status.restorationDescription
                } else if status.connection == .disconnected {
                    // A specific reason, such as being out of range, helps
                    // more than the generic line.
                    state = .disconnected
                    message = status.restorationDescription ?? "Device is disconnected."
                } else if case .measured(let forecast) = status.batteryForecast, forecast.confidence == .low {
                    state = .lowConfidence; message = "Forecast has low confidence."
                } else if status.connection == .synchronizing && status.batteryPercent.isAbsent {
                    state = .settlingOrRecomputing; message = "Device data is settling."
                } else {
                    switch status.batteryPercent {
                    case .absent:
                        state = .absentMetric; message = "Battery is unavailable."
                    case .measured(0):
                        state = .measuredZero; message = "Measured battery is zero percent."
                    case .measured:
                        if status.connection == .synchronizing {
                            state = .partialData; message = "Sync is still in progress."
                        } else if status.connection != .connected || status.batteryForecast.isAbsent || status.freshness.isAbsent
                                    || status.wristState == .unknown || status.charging == nil {
                            state = .partialData; message = nil
                        } else {
                            state = .ready; message = "Connected and ready."
                        }
                    }
                }
            }
        }
        return DeviceCenterViewState(
            universalState: state,
            identity: identity,
            status: status,
            message: message,
            diagnostics: diagnostics
        )
    }
}
