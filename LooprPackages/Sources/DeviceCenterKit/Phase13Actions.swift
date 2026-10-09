import Foundation
import DomainKit

// MARK: - Shared runtime identity

/// The generation that owns a physical connection.  Feature actions must
/// carry the generation they were observed on so a late packet from a
/// disconnected strap cannot be replayed into a new connection.
public protocol DeviceRuntimeGenerationProvider: Sendable {
    func currentGeneration() async -> UInt64?
}

/// A production-safe provider for surfaces that do not have a verified live
/// runtime yet.  It intentionally returns nil rather than inventing a
/// generation or allowing an action to proceed.
public struct UnavailableDeviceRuntimeGenerationProvider: DeviceRuntimeGenerationProvider {
    public let reason: String

    public init(reason: String = "No verified device connection is available.") {
        self.reason = reason
    }

    public func currentGeneration() async -> UInt64? {
        _ = reason
        return nil
    }
}

/// Capability gates are injected separately from command transports.  This
/// keeps a UI/action contract honest when the shared runtime has not yet
/// verified a particular physical operation.
public protocol DeviceActionCapabilityProvider: Sendable {
    func status(for action: DeviceAction) async -> DeviceCapabilityStatus
}

public struct UnavailableDeviceActionCapabilityProvider: DeviceActionCapabilityProvider {
    public init() {}

    public func status(for action: DeviceAction) async -> DeviceCapabilityStatus {
        _ = action
        return .unknown
    }
}

public struct StaticDeviceActionCapabilityProvider: DeviceActionCapabilityProvider {
    private let statuses: [DeviceAction: DeviceCapabilityStatus]

    public init(statuses: [DeviceAction: DeviceCapabilityStatus] = [:]) {
        self.statuses = statuses
    }

    public init(supportedActions: Set<DeviceAction>) {
        self.statuses = Dictionary(uniqueKeysWithValues: supportedActions.map { ($0, .supported) })
    }

    public func status(for action: DeviceAction) async -> DeviceCapabilityStatus {
        statuses[action] ?? .unknown
    }
}

/// Reads the canonical Device Center capability matrix without granting any
/// capability on repository failure or when no identity is paired.
public struct RepositoryDeviceActionCapabilityProvider: DeviceActionCapabilityProvider {
    private let repository: any DeviceCenterRepository

    public init(repository: any DeviceCenterRepository) {
        self.repository = repository
    }

    public func status(for action: DeviceAction) async -> DeviceCapabilityStatus {
        guard let identity = try? await repository.readIdentity() else {
            return .unknown
        }
        return identity.capabilities.status(for: action)
    }
}

// MARK: - APP-13.1 strap alarm

public struct StrapAlarmClockReading: Equatable, Sendable {
    public let generation: UInt64
    public let bandDate: Date
    public let sampledAt: Date

    public init(generation: UInt64, bandDate: Date, sampledAt: Date) {
        self.generation = generation
        self.bandDate = bandDate
        self.sampledAt = sampledAt
    }
}

public struct StrapAlarmClockCorrelation: Equatable, Sendable {
    public let generation: UInt64
    public let hostDate: Date
    public let bandDate: Date
    public let offsetSeconds: TimeInterval
    public let maximumAcceptedOffset: TimeInterval

    public init(
        generation: UInt64,
        hostDate: Date,
        bandDate: Date,
        maximumAcceptedOffset: TimeInterval
    ) {
        self.generation = generation
        self.hostDate = hostDate
        self.bandDate = bandDate
        self.offsetSeconds = bandDate.timeIntervalSince(hostDate)
        self.maximumAcceptedOffset = max(0, maximumAcceptedOffset)
    }

    public var isWithinTolerance: Bool {
        abs(offsetSeconds) <= maximumAcceptedOffset
    }

    /// Converts an app wall-clock date into the band clock domain.  The
    /// transport remains responsible for translating this typed value into
    /// its verified protocol command; no opcode or raw bytes are exposed.
    public func bandDate(for hostDate: Date) -> Date {
        hostDate.addingTimeInterval(offsetSeconds)
    }
}

public struct StrapAlarmSchedule: Equatable, Sendable {
    /// `hostFireDate` is the single occurrence driven by this workflow.
    /// The persisted configuration carries the validated band parameters but
    /// does not turn this APP-13 action into a sleep-stage wake window.
    public let configuration: StrapAlarmConfiguration
    public let hostFireDate: Date

    public init(configuration: StrapAlarmConfiguration, hostFireDate: Date) {
        self.configuration = configuration
        self.hostFireDate = hostFireDate
    }
}

public struct StrapAlarmSetRequest: Equatable, Sendable {
    public let requestID: UUID
    public let generation: UInt64
    public let configuration: StrapAlarmConfiguration
    public let hostFireDate: Date
    public let bandFireDate: Date
    public let correlation: StrapAlarmClockCorrelation

    public init(
        requestID: UUID,
        generation: UInt64,
        configuration: StrapAlarmConfiguration,
        hostFireDate: Date,
        bandFireDate: Date,
        correlation: StrapAlarmClockCorrelation
    ) {
        self.requestID = requestID
        self.generation = generation
        self.configuration = configuration
        self.hostFireDate = hostFireDate
        self.bandFireDate = bandFireDate
        self.correlation = correlation
    }
}

/// A transport must be implemented by a verified adapter before any
/// physical alarm operation is enabled.  The semantic operations map to the
/// already-pinned ProtocolKit family in the owning transport; this package
/// deliberately does not invent a second opcode or raw-payload API.
public protocol StrapAlarmTransport: Sendable {
    func readBandClock() async throws -> StrapAlarmClockReading
    func setAlarm(_ request: StrapAlarmSetRequest) async throws
    func readAlarm() async throws -> StrapAlarmDeviceReadback?
    func testAlarm() async throws
    func disableAlarm() async throws
}

public struct StrapAlarmDeviceReadback: Equatable, Sendable {
    public let requestID: UUID
    public let generation: UInt64
    public let configuration: StrapAlarmConfiguration
    public let bandFireDate: Date
    public let confirmedAt: Date
    public let executed: Bool

    public init(
        requestID: UUID,
        generation: UInt64,
        configuration: StrapAlarmConfiguration,
        bandFireDate: Date,
        confirmedAt: Date,
        executed: Bool = true
    ) {
        self.requestID = requestID
        self.generation = generation
        self.configuration = configuration
        self.bandFireDate = bandFireDate
        self.confirmedAt = confirmedAt
        self.executed = executed
    }
}

public enum StrapAlarmRecoveryReason: Equatable, Sendable {
    case clockReadFailed(String)
    case clockOutOfTolerance(TimeInterval)
    case setFailed(String)
    case readbackUnavailable
    case readbackFailed(String)
    case readbackMismatch
    case persistenceFailed(String)
    case testFailed(String)
    case disableFailed(String)
    case recoveryReadbackFailed(String)
}

public enum StrapAlarmWorkflowState: Equatable, Sendable {
    case idle
    case clockCorrelated(StrapAlarmClockCorrelation)
    case setting(StrapAlarmSetRequest)
    case awaitingReadback(StrapAlarmSetRequest)
    case readyToTest(StrapAlarmSetRequest, StrapAlarmDeviceReadback)
    case tested(StrapAlarmSetRequest, StrapAlarmDeviceReadback)
    case disabled(StrapAlarmSetRequest)
    case recoveryRequired(StrapAlarmRecoveryReason)
    case unavailable(String)
}

public enum StrapAlarmWorkflowError: Error, Equatable, Sendable, LocalizedError {
    case invalidTransition(operation: String, state: StrapAlarmWorkflowState)
    case invalidSchedule
    case capabilityUnavailable(DeviceAction)
    case clockUnavailable(String)
    case clockOutOfTolerance(TimeInterval)
    case setFailed(String)
    case readbackUnavailable
    case readbackFailed(String)
    case readbackMismatch
    case persistenceFailed(String)
    case testFailed(String)
    case disableFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidTransition(let operation, let state):
            return "Cannot \(operation) while strap alarm is in state \(String(describing: state))."
        case .invalidSchedule:
            return "The strap alarm time must be in the future."
        case .capabilityUnavailable(let action):
            switch action {
            case .strapAlarmSetup, .strapAlarmReadback:
                return "No verified strap alarm capability is available for this device."
            default:
                return "\(action.displayName) is not available for this device."
            }
        case .clockUnavailable(let reason):
            return "The strap alarm clock is unavailable: \(reason)"
        case .clockOutOfTolerance(let offset):
            return "The strap alarm clocks differ by \(offset) seconds; no strap alarm was written."
        case .setFailed(let reason):
            return "The strap alarm could not be set: \(reason)"
        case .readbackUnavailable:
            return "The strap alarm was not confirmed by the band."
        case .readbackFailed(let reason):
            return "The strap alarm readback failed: \(reason)"
        case .readbackMismatch:
            return "The band returned a different strap alarm; no success was reported."
        case .persistenceFailed(let reason):
            return "The confirmed strap alarm could not be saved locally: \(reason)"
        case .testFailed(let reason):
            return "The strap alarm test failed: \(reason)"
        case .disableFailed(let reason):
            return "The strap alarm could not be disabled: \(reason)"
        }
    }
}

public enum StrapAlarmRecoveryResult: Equatable, Sendable {
    case readbackConfirmed(StrapAlarmDeviceReadback)
    case resetForRetry
    case stillUnavailable(String)
}

public struct UnavailableStrapAlarmTransport: StrapAlarmTransport {
    public let reason: String

    public init(reason: String = "No verified strap alarm command/readback adapter is available.") {
        self.reason = reason
    }

    public func readBandClock() async throws -> StrapAlarmClockReading {
        throw StrapAlarmWorkflowError.clockUnavailable(reason)
    }

    public func setAlarm(_ request: StrapAlarmSetRequest) async throws {
        throw StrapAlarmWorkflowError.setFailed(reason)
    }

    public func readAlarm() async throws -> StrapAlarmDeviceReadback? {
        throw StrapAlarmWorkflowError.readbackFailed(reason)
    }

    public func testAlarm() async throws {
        throw StrapAlarmWorkflowError.testFailed(reason)
    }

    public func disableAlarm() async throws {
        throw StrapAlarmWorkflowError.disableFailed(reason)
    }
}

/// Coordinates the complete software contract for a one-time strap alarm.
/// A command acknowledgement never advances this state machine past
/// `awaitingReadback`; only an exact, generation-matched band readback can do
/// so.  A failed operation enters recovery and never reports success.
public actor StrapAlarmWorkflow {
    public private(set) var state: StrapAlarmWorkflowState = .idle

    private let transport: any StrapAlarmTransport
    private let repository: (any StrapAlarmConfigurationRepository)?
    private let capabilityProvider: any DeviceActionCapabilityProvider
    private let dateProvider: any DateProviding
    private let maximumClockOffset: TimeInterval
    private var latestCorrelation: StrapAlarmClockCorrelation?
    private var request: StrapAlarmSetRequest?

    public init(
        transport: any StrapAlarmTransport,
        repository: (any StrapAlarmConfigurationRepository)? = nil,
        capabilityProvider: any DeviceActionCapabilityProvider = UnavailableDeviceActionCapabilityProvider(),
        dateProvider: any DateProviding = SystemDateProvider(),
        maximumClockOffset: TimeInterval = 2
    ) {
        self.transport = transport
        self.repository = repository
        self.capabilityProvider = capabilityProvider
        self.dateProvider = dateProvider
        self.maximumClockOffset = max(0, maximumClockOffset)
    }

    @discardableResult
    public func correlateClock(at hostDate: Date? = nil) async throws -> StrapAlarmClockCorrelation {
        guard await capabilityProvider.status(for: .strapAlarmSetup) == .supported else {
            let error = StrapAlarmWorkflowError.capabilityUnavailable(.strapAlarmSetup)
            state = .unavailable(error.localizedDescription)
            throw error
        }
        let hostDate = hostDate ?? dateProvider.now()
        do {
            let reading = try await transport.readBandClock()
            let correlation = StrapAlarmClockCorrelation(
                generation: reading.generation,
                hostDate: hostDate,
                bandDate: reading.bandDate,
                maximumAcceptedOffset: maximumClockOffset
            )
            guard correlation.isWithinTolerance else {
                latestCorrelation = nil
                request = nil
                state = .recoveryRequired(.clockOutOfTolerance(correlation.offsetSeconds))
                throw StrapAlarmWorkflowError.clockOutOfTolerance(correlation.offsetSeconds)
            }
            latestCorrelation = correlation
            request = nil
            state = .clockCorrelated(correlation)
            return correlation
        } catch let error as StrapAlarmWorkflowError {
            if case .clockOutOfTolerance = error { throw error }
            state = .recoveryRequired(.clockReadFailed(error.localizedDescription))
            throw error
        } catch {
            let reason = String(describing: error)
            state = .recoveryRequired(.clockReadFailed(reason))
            throw StrapAlarmWorkflowError.clockUnavailable(reason)
        }
    }

    @discardableResult
    public func set(
        _ schedule: StrapAlarmSchedule,
        requestID: UUID = UUID()
    ) async throws -> StrapAlarmSetRequest {
        guard case .clockCorrelated(let correlation) = state,
              latestCorrelation == correlation else {
            throw StrapAlarmWorkflowError.invalidTransition(operation: "set the strap alarm", state: state)
        }
        let configuration: StrapAlarmConfiguration
        do {
            configuration = try schedule.configuration.validated()
        } catch {
            throw StrapAlarmWorkflowError.invalidSchedule
        }
        guard configuration.isEnabled,
              schedule.hostFireDate > dateProvider.now() else {
            throw StrapAlarmWorkflowError.invalidSchedule
        }

        let request = StrapAlarmSetRequest(
            requestID: requestID,
            generation: correlation.generation,
            configuration: configuration,
            hostFireDate: schedule.hostFireDate,
            bandFireDate: correlation.bandDate(for: schedule.hostFireDate),
            correlation: correlation
        )
        self.request = request
        state = .setting(request)
        do {
            try await transport.setAlarm(request)
            state = .awaitingReadback(request)
            return request
        } catch let error as StrapAlarmWorkflowError {
            state = .recoveryRequired(.setFailed(error.localizedDescription))
            throw error
        } catch {
            let reason = String(describing: error)
            state = .recoveryRequired(.setFailed(reason))
            throw StrapAlarmWorkflowError.setFailed(reason)
        }
    }

    @discardableResult
    public func readback() async throws -> StrapAlarmDeviceReadback {
        guard case .awaitingReadback(let request) = state else {
            throw StrapAlarmWorkflowError.invalidTransition(operation: "read back the strap alarm", state: state)
        }
        guard await capabilityProvider.status(for: .strapAlarmReadback) == .supported else {
            let error = StrapAlarmWorkflowError.capabilityUnavailable(.strapAlarmReadback)
            state = .unavailable(error.localizedDescription)
            throw error
        }
        do {
            guard let readback = try await transport.readAlarm() else {
                state = .recoveryRequired(.readbackUnavailable)
                throw StrapAlarmWorkflowError.readbackUnavailable
            }
            guard matches(readback, request: request) else {
                state = .recoveryRequired(.readbackMismatch)
                throw StrapAlarmWorkflowError.readbackMismatch
            }
            if let repository {
                do {
                    try await repository.saveAlarmConfiguration(request.configuration)
                } catch {
                    let reason = String(describing: error)
                    state = .recoveryRequired(.persistenceFailed(reason))
                    throw StrapAlarmWorkflowError.persistenceFailed(reason)
                }
            }
            state = .readyToTest(request, readback)
            return readback
        } catch let error as StrapAlarmWorkflowError {
            if case .persistenceFailed = error { throw error }
            switch error {
            case .readbackUnavailable, .readbackMismatch:
                throw error
            default:
                break
            }
            state = .recoveryRequired(.readbackFailed(error.localizedDescription))
            throw error
        } catch {
            let reason = String(describing: error)
            state = .recoveryRequired(.readbackFailed(reason))
            throw StrapAlarmWorkflowError.readbackFailed(reason)
        }
    }

    @discardableResult
    public func test() async throws -> StrapAlarmWorkflowState {
        guard case .readyToTest(let request, let readback) = state else {
            throw StrapAlarmWorkflowError.invalidTransition(operation: "test the strap alarm", state: state)
        }
        do {
            try await transport.testAlarm()
            state = .tested(request, readback)
            return state
        } catch let error as StrapAlarmWorkflowError {
            state = .recoveryRequired(.testFailed(error.localizedDescription))
            throw error
        } catch {
            let reason = String(describing: error)
            state = .recoveryRequired(.testFailed(reason))
            throw StrapAlarmWorkflowError.testFailed(reason)
        }
    }

    @discardableResult
    public func disable() async throws -> StrapAlarmWorkflowState {
        guard case .tested(let request, _) = state else {
            throw StrapAlarmWorkflowError.invalidTransition(operation: "disable the strap alarm", state: state)
        }
        do {
            try await transport.disableAlarm()
            state = .disabled(request)
            return state
        } catch let error as StrapAlarmWorkflowError {
            state = .recoveryRequired(.disableFailed(error.localizedDescription))
            throw error
        } catch {
            let reason = String(describing: error)
            state = .recoveryRequired(.disableFailed(reason))
            throw StrapAlarmWorkflowError.disableFailed(reason)
        }
    }

    /// Recovery attempts one verified readback.  If the band confirms the
    /// exact pending request, the workflow returns to `readyToTest`; if it
    /// cannot confirm it, the pending request is discarded and the workflow
    /// resets for an explicit retry.  It never treats a failed command as a
    /// successful alarm.
    public func recover() async -> StrapAlarmRecoveryResult {
        guard case .recoveryRequired = state, let request else {
            state = .idle
            self.request = nil
            return .resetForRetry
        }
        do {
            guard let readback = try await transport.readAlarm() else {
                state = .idle
                self.request = nil
                return .resetForRetry
            }
            guard matches(readback, request: request) else {
                state = .idle
                self.request = nil
                return .resetForRetry
            }
            if let repository {
                do {
                    try await repository.saveAlarmConfiguration(request.configuration)
                } catch {
                    let reason = String(describing: error)
                    state = .recoveryRequired(.persistenceFailed(reason))
                    return .stillUnavailable(reason)
                }
            }
            state = .readyToTest(request, readback)
            return .readbackConfirmed(readback)
        } catch {
            state = .recoveryRequired(.recoveryReadbackFailed(String(describing: error)))
            return .stillUnavailable(String(describing: error))
        }
    }

    private func matches(_ readback: StrapAlarmDeviceReadback, request: StrapAlarmSetRequest) -> Bool {
        readback.requestID == request.requestID
            && readback.generation == request.generation
            && readback.configuration == request.configuration
            && readback.bandFireDate == request.bandFireDate
            && readback.executed
    }
}

// MARK: - APP-13.2 Find My Strap

public struct FindMyStrapRequest: Equatable, Sendable {
    public let requestID: UUID
    public let generation: UInt64
    public let requestedAt: Date

    public init(requestID: UUID, generation: UInt64, requestedAt: Date) {
        self.requestID = requestID
        self.generation = generation
        self.requestedAt = requestedAt
    }
}

public struct FindMyStrapReadback: Equatable, Sendable {
    public let requestID: UUID
    public let generation: UInt64
    public let confirmedAt: Date
    public let executed: Bool

    public init(requestID: UUID, generation: UInt64, confirmedAt: Date, executed: Bool) {
        self.requestID = requestID
        self.generation = generation
        self.confirmedAt = confirmedAt
        self.executed = executed
    }
}

public protocol FindMyStrapTransport: Sendable {
    func requestFindMyStrap(_ request: FindMyStrapRequest) async throws
    func readFindMyStrap(_ request: FindMyStrapRequest) async throws -> FindMyStrapReadback?
}

public struct UnavailableFindMyStrapTransport: FindMyStrapTransport {
    public let reason: String

    public init(reason: String = "No verified Find My Strap command/readback adapter is available.") {
        self.reason = reason
    }

    public func requestFindMyStrap(_ request: FindMyStrapRequest) async throws {
        throw FindMyStrapWorkflowError.unavailable(reason)
    }

    public func readFindMyStrap(_ request: FindMyStrapRequest) async throws -> FindMyStrapReadback? {
        throw FindMyStrapWorkflowError.unavailable(reason)
    }
}

public enum FindMyStrapWorkflowState: Equatable, Sendable {
    case idle
    case awaitingReadback(FindMyStrapRequest)
    case confirmed(FindMyStrapRequest, FindMyStrapReadback)
    case recoveryRequired(String)
    case unavailable(String)
}

public enum FindMyStrapWorkflowError: Error, Equatable, Sendable, LocalizedError {
    case noGeneration
    case staleGeneration
    case capabilityUnavailable
    case invalidTransition(FindMyStrapWorkflowState)
    case readbackNotConfirmed
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .noGeneration: "Find My Strap is unavailable without an active connection."
        case .staleGeneration: "The Find My Strap response belongs to an older connection."
        case .capabilityUnavailable: "Find My Strap is not verified for this device."
        case .invalidTransition(let state): "Find My Strap cannot proceed from \(String(describing: state))."
        case .readbackNotConfirmed: "Find My Strap was not confirmed by the band."
        case .unavailable(let reason): reason
        }
    }
}

public actor FindMyStrapWorkflow {
    public private(set) var state: FindMyStrapWorkflowState = .idle

    private let transport: any FindMyStrapTransport
    private let generationProvider: any DeviceRuntimeGenerationProvider
    private let capabilityProvider: any DeviceActionCapabilityProvider
    private let dateProvider: any DateProviding

    public init(
        transport: any FindMyStrapTransport,
        generationProvider: any DeviceRuntimeGenerationProvider,
        capabilityProvider: any DeviceActionCapabilityProvider = UnavailableDeviceActionCapabilityProvider(),
        dateProvider: any DateProviding = SystemDateProvider()
    ) {
        self.transport = transport
        self.generationProvider = generationProvider
        self.capabilityProvider = capabilityProvider
        self.dateProvider = dateProvider
    }

    @discardableResult
    public func request(
        generation: UInt64,
        requestID: UUID = UUID(),
        at requestedAt: Date? = nil
    ) async throws -> FindMyStrapRequest {
        guard await capabilityProvider.status(for: .findMyStrap) == .supported else {
            state = .unavailable("Find My Strap is not verified for this device.")
            throw FindMyStrapWorkflowError.capabilityUnavailable
        }
        guard await generationProvider.currentGeneration() == generation else {
            state = .recoveryRequired("The Find My Strap connection is unavailable or stale.")
            throw FindMyStrapWorkflowError.staleGeneration
        }
        let request = FindMyStrapRequest(
            requestID: requestID,
            generation: generation,
            requestedAt: requestedAt ?? dateProvider.now()
        )
        do {
            try await transport.requestFindMyStrap(request)
            state = .awaitingReadback(request)
            return request
        } catch let error as FindMyStrapWorkflowError {
            state = .unavailable(error.localizedDescription)
            throw error
        } catch {
            let reason = String(describing: error)
            state = .unavailable(reason)
            throw FindMyStrapWorkflowError.unavailable(reason)
        }
    }

    @discardableResult
    public func confirmReadback() async throws -> FindMyStrapReadback {
        guard case .awaitingReadback(let request) = state else {
            throw FindMyStrapWorkflowError.invalidTransition(state)
        }
        guard await capabilityProvider.status(for: .findMyStrap) == .supported else {
            state = .unavailable("Find My Strap is not verified for this device.")
            throw FindMyStrapWorkflowError.capabilityUnavailable
        }
        guard await generationProvider.currentGeneration() == request.generation else {
            state = .recoveryRequired("The Find My Strap response belongs to an older connection.")
            throw FindMyStrapWorkflowError.staleGeneration
        }
        do {
            guard let readback = try await transport.readFindMyStrap(request),
                  readback.requestID == request.requestID,
                  readback.generation == request.generation,
                  readback.executed else {
                state = .recoveryRequired("The band did not confirm Find My Strap execution.")
                throw FindMyStrapWorkflowError.readbackNotConfirmed
            }
            state = .confirmed(request, readback)
            return readback
        } catch let error as FindMyStrapWorkflowError {
            if case .readbackNotConfirmed = error { throw error }
            state = .recoveryRequired(error.localizedDescription)
            throw error
        } catch {
            let reason = String(describing: error)
            state = .recoveryRequired(reason)
            throw FindMyStrapWorkflowError.unavailable(reason)
        }
    }

    public func resetForRetry() {
        state = .idle
    }
}

// MARK: - APP-13.3 double-tap actions

public enum DeviceGestureAction: String, Codable, CaseIterable, Hashable, Sendable {
    case markMoment
    case startWorkout
    case pauseWorkout
    case finishWorkout

    public var displayName: String {
        switch self {
        case .markMoment: "Mark a moment"
        case .startWorkout: "Start workout"
        case .pauseWorkout: "Pause workout"
        case .finishWorkout: "Finish workout"
        }
    }
}

public protocol DeviceGestureCapabilityProvider: Sendable {
    func status(for action: DeviceGestureAction) async -> DeviceCapabilityStatus
}

public struct UnavailableDeviceGestureCapabilityProvider: DeviceGestureCapabilityProvider {
    public init() {}

    public func status(for action: DeviceGestureAction) async -> DeviceCapabilityStatus {
        _ = action
        return .unknown
    }
}

public struct StaticDeviceGestureCapabilityProvider: DeviceGestureCapabilityProvider {
    private let statuses: [DeviceGestureAction: DeviceCapabilityStatus]

    public init(statuses: [DeviceGestureAction: DeviceCapabilityStatus] = [:]) {
        self.statuses = statuses
    }

    public init(supportedActions: Set<DeviceGestureAction>) {
        self.statuses = Dictionary(uniqueKeysWithValues: supportedActions.map { ($0, .supported) })
    }

    public func status(for action: DeviceGestureAction) async -> DeviceCapabilityStatus {
        statuses[action] ?? .unknown
    }
}

public struct DeviceGestureEvent: Equatable, Sendable {
    public let eventID: UUID
    public let gesture: DeviceGesture
    public let generation: UInt64
    public let occurredAt: Date

    public init(eventID: UUID, gesture: DeviceGesture, generation: UInt64, occurredAt: Date) {
        self.eventID = eventID
        self.gesture = gesture
        self.generation = generation
        self.occurredAt = occurredAt
    }
}

public struct DeviceJournalMarker: Equatable, Sendable {
    public let eventID: UUID
    public let generation: UInt64
    public let occurredAt: Date
    public let source: DeviceGesture

    public init(eventID: UUID, generation: UInt64, occurredAt: Date, source: DeviceGesture = .doubleTap) {
        self.eventID = eventID
        self.generation = generation
        self.occurredAt = occurredAt
        self.source = source
    }
}

public enum DeviceSafeWorkoutAction: String, Codable, CaseIterable, Hashable, Sendable {
    case startWorkout
    case pauseWorkout
    case finishWorkout
}

public struct DeviceWorkoutActionRequest: Equatable, Sendable {
    public let eventID: UUID
    public let generation: UInt64
    public let occurredAt: Date
    public let action: DeviceSafeWorkoutAction

    public init(eventID: UUID, generation: UInt64, occurredAt: Date, action: DeviceSafeWorkoutAction) {
        self.eventID = eventID
        self.generation = generation
        self.occurredAt = occurredAt
        self.action = action
    }
}

public protocol DeviceJournalMarkerSink: Sendable {
    func append(_ marker: DeviceJournalMarker) async throws
}

public protocol DeviceWorkoutActionSink: Sendable {
    func perform(_ request: DeviceWorkoutActionRequest) async throws
}

public enum DeviceGestureDispatchError: Error, Equatable, Sendable, LocalizedError {
    case unsupportedGesture(DeviceGesture)
    case noGeneration
    case staleGeneration
    case eventTooOld
    case eventFromFuture
    case replayed
    case unsupportedAction(DeviceGestureAction)
    case sinkUnavailable(DeviceGestureAction)
    case actionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedGesture(let gesture): "The \(gesture.displayName.lowercased()) gesture is not mapped."
        case .noGeneration: "The gesture connection is unavailable."
        case .staleGeneration: "The gesture belongs to an older connection."
        case .eventTooOld: "The gesture event is too old to execute."
        case .eventFromFuture: "The gesture event timestamp is invalid."
        case .replayed: "The gesture event was already handled."
        case .unsupportedAction(let action): "\(action.displayName) is not supported by this device."
        case .sinkUnavailable(let action): "\(action.displayName) is unavailable right now."
        case .actionFailed(let reason): "The gesture action failed: \(reason)"
        }
    }
}

/// Routes only the safe, typed APP-13 gesture destinations.  It does not
/// construct a BLE command and it marks an event consumed only after the
/// destination has committed successfully.
public actor DeviceGestureActionDispatcher {
    private let generationProvider: any DeviceRuntimeGenerationProvider
    private let dateProvider: any DateProviding
    private let capabilityProvider: any DeviceGestureCapabilityProvider
    private let journalSink: (any DeviceJournalMarkerSink)?
    private let workoutSink: (any DeviceWorkoutActionSink)?
    private let maximumAge: TimeInterval
    private let maximumFutureSkew: TimeInterval
    private var consumedEventIDs: Set<UUID> = []

    public init(
        generationProvider: any DeviceRuntimeGenerationProvider,
        dateProvider: any DateProviding = SystemDateProvider(),
        capabilityProvider: any DeviceGestureCapabilityProvider = UnavailableDeviceGestureCapabilityProvider(),
        journalSink: (any DeviceJournalMarkerSink)? = nil,
        workoutSink: (any DeviceWorkoutActionSink)? = nil,
        maximumAge: TimeInterval = 10,
        maximumFutureSkew: TimeInterval = 0.5
    ) {
        self.generationProvider = generationProvider
        self.dateProvider = dateProvider
        self.capabilityProvider = capabilityProvider
        self.journalSink = journalSink
        self.workoutSink = workoutSink
        self.maximumAge = max(0, maximumAge)
        self.maximumFutureSkew = max(0, maximumFutureSkew)
    }

    @discardableResult
    public func dispatch(
        _ event: DeviceGestureEvent,
        action: DeviceGestureAction
    ) async throws -> DeviceGestureAction {
        guard event.gesture == .doubleTap else {
            throw DeviceGestureDispatchError.unsupportedGesture(event.gesture)
        }
        guard await capabilityProvider.status(for: action) == .supported else {
            throw DeviceGestureDispatchError.unsupportedAction(action)
        }
        guard let generation = await generationProvider.currentGeneration() else {
            throw DeviceGestureDispatchError.noGeneration
        }
        guard generation == event.generation else {
            throw DeviceGestureDispatchError.staleGeneration
        }
        guard event.occurredAt.timeIntervalSinceReferenceDate.isFinite else {
            throw DeviceGestureDispatchError.eventFromFuture
        }
        let now = dateProvider.now()
        let age = now.timeIntervalSince(event.occurredAt)
        guard age >= -maximumFutureSkew else {
            throw DeviceGestureDispatchError.eventFromFuture
        }
        guard age <= maximumAge else {
            throw DeviceGestureDispatchError.eventTooOld
        }
        guard !consumedEventIDs.contains(event.eventID) else {
            throw DeviceGestureDispatchError.replayed
        }

        do {
            switch action {
            case .markMoment:
                guard let journalSink else { throw DeviceGestureDispatchError.sinkUnavailable(action) }
                try await journalSink.append(DeviceJournalMarker(
                    eventID: event.eventID,
                    generation: event.generation,
                    occurredAt: event.occurredAt
                ))
            case .startWorkout, .pauseWorkout, .finishWorkout:
                guard let workoutSink else { throw DeviceGestureDispatchError.sinkUnavailable(action) }
                let workoutAction: DeviceSafeWorkoutAction
                switch action {
                case .startWorkout: workoutAction = .startWorkout
                case .pauseWorkout: workoutAction = .pauseWorkout
                case .finishWorkout: workoutAction = .finishWorkout
                case .markMoment: throw DeviceGestureDispatchError.unsupportedAction(action)
                }
                try await workoutSink.perform(DeviceWorkoutActionRequest(
                    eventID: event.eventID,
                    generation: event.generation,
                    occurredAt: event.occurredAt,
                    action: workoutAction
                ))
            }
            consumedEventIDs.insert(event.eventID)
            return action
        } catch let error as DeviceGestureDispatchError {
            throw error
        } catch {
            throw DeviceGestureDispatchError.actionFailed(String(describing: error))
        }
    }
}

// MARK: - APP-13.4 phone actions

public enum DevicePhoneAction: String, Codable, CaseIterable, Hashable, Sendable {
    case ringPhone
    case torch

    public var displayName: String {
        switch self {
        case .ringPhone: "Ring phone"
        case .torch: "Flashlight"
        }
    }
}

public protocol DevicePhoneCapabilityProvider: Sendable {
    func status(for action: DevicePhoneAction) async -> DeviceCapabilityStatus
}

public struct UnavailableDevicePhoneCapabilityProvider: DevicePhoneCapabilityProvider {
    public init() {}

    public func status(for action: DevicePhoneAction) async -> DeviceCapabilityStatus {
        _ = action
        return .unknown
    }
}

public struct StaticDevicePhoneCapabilityProvider: DevicePhoneCapabilityProvider {
    private let statuses: [DevicePhoneAction: DeviceCapabilityStatus]

    public init(statuses: [DevicePhoneAction: DeviceCapabilityStatus] = [:]) {
        self.statuses = statuses
    }

    public init(supportedActions: Set<DevicePhoneAction>) {
        self.statuses = Dictionary(uniqueKeysWithValues: supportedActions.map { ($0, .supported) })
    }

    public func status(for action: DevicePhoneAction) async -> DeviceCapabilityStatus {
        statuses[action] ?? .unknown
    }
}

public struct DevicePhoneActionRequest: Equatable, Sendable {
    public let eventID: UUID
    public let action: DevicePhoneAction
    public let generation: UInt64
    public let occurredAt: Date

    public init(eventID: UUID, action: DevicePhoneAction, generation: UInt64, occurredAt: Date) {
        self.eventID = eventID
        self.action = action
        self.generation = generation
        self.occurredAt = occurredAt
    }
}

public protocol DevicePhoneActionSink: Sendable {
    func perform(_ request: DevicePhoneActionRequest) async throws
}

public struct UnavailableDevicePhoneActionSink: DevicePhoneActionSink {
    public let reason: String

    public init(reason: String = "No verified phone action adapter is available.") {
        self.reason = reason
    }

    public func perform(_ request: DevicePhoneActionRequest) async throws {
        _ = request
        throw DevicePhoneActionDispatchError.unavailable(reason)
    }
}

public enum DevicePhoneActionDispatchError: Error, Equatable, Sendable, LocalizedError {
    case invalidAction(DevicePhoneAction)
    case noGeneration
    case staleGeneration
    case eventTooOld
    case eventFromFuture
    case replayed
    case debounced(DevicePhoneAction)
    case unsupportedAction(DevicePhoneAction)
    case unavailable(String)
    case actionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidAction(let action): "\(action.displayName) is not available."
        case .noGeneration: "The phone action connection is unavailable."
        case .staleGeneration: "The phone action belongs to an older connection."
        case .eventTooOld: "The phone action event is too old to execute."
        case .eventFromFuture: "The phone action timestamp is invalid."
        case .replayed: "The phone action event was already handled."
        case .debounced(let action): "\(action.displayName) was requested too recently. Try again shortly."
        case .unsupportedAction(let action): "\(action.displayName) is not supported by this device."
        case .unavailable(let reason): reason
        case .actionFailed(let reason): "The phone action failed: \(reason)"
        }
    }
}

/// Applies the APP-13.4 recency, generation, debounce, and anti-replay fence
/// before forwarding a typed ring/torch request to a phone capability seam.
public actor DevicePhoneActionDispatcher {
    private let generationProvider: any DeviceRuntimeGenerationProvider
    private let dateProvider: any DateProviding
    private let capabilityProvider: any DevicePhoneCapabilityProvider
    private let sink: any DevicePhoneActionSink
    private let maximumAge: TimeInterval
    private let maximumFutureSkew: TimeInterval
    private let debounceInterval: TimeInterval
    private var lastAcceptedAt: [DevicePhoneAction: Date] = [:]
    private var consumedEventIDs: Set<UUID> = []

    public init(
        generationProvider: any DeviceRuntimeGenerationProvider,
        dateProvider: any DateProviding = SystemDateProvider(),
        capabilityProvider: any DevicePhoneCapabilityProvider = UnavailableDevicePhoneCapabilityProvider(),
        sink: any DevicePhoneActionSink,
        maximumAge: TimeInterval = 10,
        maximumFutureSkew: TimeInterval = 0.5,
        debounceInterval: TimeInterval = 0.75
    ) {
        self.generationProvider = generationProvider
        self.dateProvider = dateProvider
        self.capabilityProvider = capabilityProvider
        self.sink = sink
        self.maximumAge = max(0, maximumAge)
        self.maximumFutureSkew = max(0, maximumFutureSkew)
        self.debounceInterval = max(0, debounceInterval)
    }

    @discardableResult
    public func dispatch(
        _ request: DevicePhoneActionRequest
    ) async throws -> DevicePhoneActionRequest {
        guard request.action == .ringPhone || request.action == .torch else {
            throw DevicePhoneActionDispatchError.invalidAction(request.action)
        }
        guard await capabilityProvider.status(for: request.action) == .supported else {
            throw DevicePhoneActionDispatchError.unsupportedAction(request.action)
        }
        guard let generation = await generationProvider.currentGeneration() else {
            throw DevicePhoneActionDispatchError.noGeneration
        }
        guard generation == request.generation else {
            throw DevicePhoneActionDispatchError.staleGeneration
        }
        guard request.occurredAt.timeIntervalSinceReferenceDate.isFinite else {
            throw DevicePhoneActionDispatchError.eventFromFuture
        }
        let now = dateProvider.now()
        let age = now.timeIntervalSince(request.occurredAt)
        guard age >= -maximumFutureSkew else {
            throw DevicePhoneActionDispatchError.eventFromFuture
        }
        guard age <= maximumAge else {
            throw DevicePhoneActionDispatchError.eventTooOld
        }
        guard !consumedEventIDs.contains(request.eventID) else {
            throw DevicePhoneActionDispatchError.replayed
        }
        if let previous = lastAcceptedAt[request.action],
           now.timeIntervalSince(previous) < debounceInterval {
            throw DevicePhoneActionDispatchError.debounced(request.action)
        }

        do {
            try await sink.perform(request)
            lastAcceptedAt[request.action] = now
            consumedEventIDs.insert(request.eventID)
            return request
        } catch let error as DevicePhoneActionDispatchError {
            throw error
        } catch {
            throw DevicePhoneActionDispatchError.actionFailed(String(describing: error))
        }
    }
}
