import Foundation

public enum HabitTelemetryEventName: String, Codable, CaseIterable, Sendable {
    case setupCompleted
    case checkInOpened
    case checkInCompleted
    case activeHabitCount
    case earlyThresholdReached
    case matureThresholdReached
    case insightOpened
    case habitArchived
}

public enum HabitCountBucket: String, Codable, Sendable {
    case oneToThree
    case fourToSix
    case sevenToTen

    public init(count: Int) {
        switch count {
        case ...3: self = .oneToThree
        case 4...6: self = .fourToSix
        default: self = .sevenToTen
        }
    }
}

public enum HabitTelemetryRouteSource: String, Codable, CaseIterable, Sendable {
    case setup
    case journal
    case today
    case notification
    case history
    case legacyLink
}

public struct HabitTelemetryEvent: Codable, Equatable, Sendable {
    public let name: HabitTelemetryEventName
    public let eventVersion: Int
    public let appVersion: String
    public let activeCountBucket: HabitCountBucket?
    public let routeSource: HabitTelemetryRouteSource?

    public init(
        name: HabitTelemetryEventName,
        eventVersion: Int = 1,
        appVersion: String,
        activeCountBucket: HabitCountBucket? = nil,
        routeSource: HabitTelemetryRouteSource? = nil
    ) {
        self.name = name
        self.eventVersion = eventVersion
        self.appVersion = appVersion
        self.activeCountBucket = activeCountBucket
        self.routeSource = routeSource
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    public static let allowedEncodedKeys: Set<String> = [
        "name", "eventVersion", "appVersion", "activeCountBucket", "routeSource"
    ]
}

public protocol HabitTelemetryClient: Sendable {
    func record(_ event: HabitTelemetryEvent) async
}

public struct NoOpHabitTelemetryClient: HabitTelemetryClient {
    public init() {}
    public func record(_ event: HabitTelemetryEvent) async {}
}
