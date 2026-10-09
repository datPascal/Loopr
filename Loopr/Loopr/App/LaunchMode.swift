import Foundation

public enum LaunchMode: String, CaseIterable, Sendable {
    case onboarding, pairing, empty, populated, stale, disconnected, activeWorkout, connectedMixedCapabilities
}

public enum LaunchModeParser {
    public static let argumentPrefix = "--loopr-launch-mode="
    public static let environmentKey = "LOOPR_LAUNCH_MODE"

    public static func parse(arguments: [String], environment: [String: String]) -> LaunchMode? {
        if let argument = arguments.first(where: { $0.hasPrefix(argumentPrefix) }) {
            return LaunchMode(rawValue: String(argument.dropFirst(argumentPrefix.count)))
        }
        guard let value = environment[environmentKey] else { return nil }
        return LaunchMode(rawValue: value)
    }

    public static func processMode() -> LaunchMode? {
        #if DEBUG
        parse(arguments: ProcessInfo.processInfo.arguments, environment: ProcessInfo.processInfo.environment)
        #else
        nil
        #endif
    }
}
