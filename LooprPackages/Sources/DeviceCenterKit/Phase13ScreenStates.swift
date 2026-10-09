import Foundation

/// Package-owned action surfaces for APP-13.  The app may present these from
/// the Device Center route, but the state contract remains independent of
/// SwiftUI and never fabricates a physical capability or readback.
public enum DeviceActionScreen: String, CaseIterable, Codable, Hashable, Sendable {
    case findMyStrap = "find-my-strap-screen"
    case strapAlarmSetup = "strap-alarm-setup-screen"
    case gestureMapping = "gesture-mapping-screen"

    public var action: DeviceAction {
        switch self {
        case .findMyStrap: .findMyStrap
        case .strapAlarmSetup: .strapAlarmSetup
        case .gestureMapping: .displayGestureMapping
        }
    }
}

public enum DeviceActionScreenCondition: String, Codable, CaseIterable, Sendable {
    case normal
    case strapAlarmRecovery
    case gestureCapabilityUnsupported
}

public struct DeviceActionScreenProjection: Equatable, Sendable {
    public let screen: DeviceActionScreen
    public let universalState: DeviceCenterUniversalState
    public let identity: DeviceIdentity?
    public let capability: DeviceCapabilityStatus
    public let readback: DeviceReadbackState
    public let condition: DeviceActionScreenCondition
    public let message: String

    public init(
        screen: DeviceActionScreen,
        universalState: DeviceCenterUniversalState,
        identity: DeviceIdentity?,
        capability: DeviceCapabilityStatus,
        readback: DeviceReadbackState,
        condition: DeviceActionScreenCondition = .normal,
        message: String
    ) {
        self.screen = screen
        self.universalState = universalState
        self.identity = identity
        self.capability = capability
        self.readback = readback
        self.condition = condition
        self.message = message
    }

    public var accessibilityIdentifier: String { screen.rawValue }

    public var accessibilitySummary: String {
        "\(screen.displayTitle). \(message). \(capability.presentationTitle). \(readback.accessibilitySummary)"
    }
}

private extension DeviceActionScreen {
    var displayTitle: String {
        switch self {
        case .findMyStrap: "Find my strap"
        case .strapAlarmSetup: "Strap alarm setup"
        case .gestureMapping: "Gesture mapping"
        }
    }
}

public extension DeviceReadbackState {
    var accessibilitySummary: String {
        switch self {
        case .unavailable(let reason): "Readback unavailable: \(reason)"
        case .pending: "Readback pending"
        case .confirmed: "Readback confirmed"
        }
    }
}

/// Loads an action surface only from the canonical Device Center repository
/// and the injected readback seam.  It deliberately does not derive a state
/// from a raw transport frame or turn an unavailable operation into success.
public enum DeviceActionScreenProjectionLoader {
    public static func load(
        screen: DeviceActionScreen,
        repository: any DeviceCenterRepository,
        readback: any DeviceActionReadback = UnavailableDeviceActionReadback()
    ) async throws -> DeviceActionScreenProjection {
        let view = try await DeviceCenterViewStateLoader.load(from: repository)
        let capability = view.identity?.capabilities.status(for: screen.action) ?? .unknown
        let readbackState = await readback.state(for: screen.action)
        let condition: DeviceActionScreenCondition
        switch screen {
        case .findMyStrap, .gestureMapping:
            condition = .normal
        case .strapAlarmSetup:
            condition = view.universalState == .recoverableError || view.universalState == .destructiveOrMigrationFailure
                ? .strapAlarmRecovery
                : .normal
        }
        return DeviceActionScreenProjection(
            screen: screen,
            universalState: view.universalState,
            identity: view.identity,
            capability: capability,
            readback: readbackState,
            condition: condition,
            message: view.message ?? "Action state is available."
        )
    }
}

public enum DeviceActionScreenStateFixtures {
    public static let allStates = DeviceCenterUniversalState.allCases
    public static let accessibilityIdentifiers = DeviceActionScreen.allCases.map(\.rawValue)

    public static let statesByScreen: [DeviceActionScreen: [DeviceActionScreenProjection]] =
        Dictionary(uniqueKeysWithValues: DeviceActionScreen.allCases.map { screen in
            (screen, allStates.map { fixture(screen: screen, state: $0) })
        })

    public static let all: [DeviceActionScreenProjection] =
        DeviceActionScreen.allCases.flatMap { statesByScreen[$0] ?? [] }

    private static func fixture(
        screen: DeviceActionScreen,
        state: DeviceCenterUniversalState
    ) -> DeviceActionScreenProjection {
        let capability: DeviceCapabilityStatus = state == .unsupportedHardware ? .unsupported :
            (state == .noRecordsYet || state == .loading ? .unknown : .supported)
        let readback: DeviceReadbackState = switch state {
        case .loading, .settlingOrRecomputing: .pending
        case .unsupportedHardware, .permissionDenied, .bluetoothOff, .noRecordsYet, .absentMetric,
             .recoverableError, .destructiveOrMigrationFailure:
            .unavailable(reason: "The action cannot be verified in this state.")
        default: .confirmed
        }
        let condition: DeviceActionScreenCondition = switch (screen, state) {
        case (.strapAlarmSetup, .recoverableError), (.strapAlarmSetup, .destructiveOrMigrationFailure):
            .strapAlarmRecovery
        case (.gestureMapping, .unsupportedHardware):
            .gestureCapabilityUnsupported
        default:
            .normal
        }
        return DeviceActionScreenProjection(
            screen: screen,
            universalState: state,
            identity: state == .loading || state == .noRecordsYet ? nil : DeviceCenterStateFixtures.sampleDevice,
            capability: capability,
            readback: readback,
            condition: condition,
            message: message(for: screen, state: state, condition: condition)
        )
    }

    private static func message(
        for screen: DeviceActionScreen,
        state: DeviceCenterUniversalState,
        condition: DeviceActionScreenCondition
    ) -> String {
        switch condition {
        case .strapAlarmRecovery: return "Strap alarm needs recovery before another action."
        case .gestureCapabilityUnsupported: return "Gesture capability is not verified for this hardware."
        case .normal: break
        }
        return "\(screen.rawValue) is \(state.rawValue)."
    }
}
