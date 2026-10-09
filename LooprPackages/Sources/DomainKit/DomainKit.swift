import Foundation

public protocol DomainIdentifier: Hashable, Codable, Sendable {
    var rawValue: UUID { get }
    init(rawValue: UUID)
}

public struct DeviceID: DomainIdentifier { public let rawValue: UUID; public init(rawValue: UUID) { self.rawValue = rawValue } }
public struct SessionID: DomainIdentifier { public let rawValue: UUID; public init(rawValue: UUID) { self.rawValue = rawValue } }
public struct WorkoutID: DomainIdentifier { public let rawValue: UUID; public init(rawValue: UUID) { self.rawValue = rawValue } }
public struct DayID: DomainIdentifier { public let rawValue: UUID; public init(rawValue: UUID) { self.rawValue = rawValue } }
public struct RecordID: DomainIdentifier { public let rawValue: UUID; public init(rawValue: UUID) { self.rawValue = rawValue } }

public struct DayIdentity: Hashable, Codable, Sendable {
    public let era: Int
    public let year: Int
    public let month: Int
    public let day: Int

    public init(era: Int = 1, year: Int, month: Int, day: Int) {
        self.era = era
        self.year = year
        self.month = month
        self.day = day
    }
}

public enum MetricEnvelope<Value: Sendable & Equatable>: Sendable, Equatable {
    case absent
    case measured(Value)
}

public enum ConnectionState: String, Codable, CaseIterable, Sendable {
    case disconnected, scanning, connecting, connected, synchronizing
}

public enum WorkoutState: String, Codable, CaseIterable, Sendable {
    case planned, active, completed, discarded
}

public struct Workout: Equatable, Codable, Sendable {
    public let id: WorkoutID
    public let state: WorkoutState
    public let startedAt: Date?
    public let endedAt: Date?

    public init(id: WorkoutID, state: WorkoutState, startedAt: Date? = nil, endedAt: Date? = nil) {
        self.id = id
        self.state = state
        self.startedAt = startedAt
        self.endedAt = endedAt
    }
}

public protocol ConnectionStateRepository: Sendable {
    func currentState() async -> ConnectionState
}

public protocol WorkoutRepository: Sendable {
    func workout(id: WorkoutID) async throws -> Workout?
    func save(_ workout: Workout) async throws
}

public protocol DateProviding: Sendable { func now() -> Date }
public protocol CalendarProviding: Sendable {
    func components(in timeZone: TimeZone, from date: Date) -> DateComponents
    func date(from components: DateComponents, in timeZone: TimeZone) -> Date?
    func date(byAdding component: Calendar.Component, value: Int, to date: Date, in timeZone: TimeZone) -> Date?
}
public protocol TimeZoneProviding: Sendable { var timeZone: TimeZone { get } }
public protocol UUIDProviding: Sendable { func nextUUID() async -> UUID }
public protocol Scheduling: Sendable {
    func schedule(_ operation: @escaping @Sendable () async -> Void) async
}

public struct SystemDateProvider: DateProviding {
    public init() {}
    public func now() -> Date { Date() }
}
public struct SystemCalendarProvider: CalendarProviding {
    public init() {}
    public func components(in timeZone: TimeZone, from date: Date) -> DateComponents {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        return calendar.dateComponents([.era, .year, .month, .day, .hour, .minute, .second], from: date)
    }
    public func date(from components: DateComponents, in timeZone: TimeZone) -> Date? {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        return calendar.date(from: components)
    }
    public func date(byAdding component: Calendar.Component, value: Int, to date: Date, in timeZone: TimeZone) -> Date? {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        return calendar.date(byAdding: component, value: value, to: date)
    }
}
public struct SystemTimeZoneProvider: TimeZoneProviding {
    public let timeZone: TimeZone
    public init(timeZone: TimeZone = .autoupdatingCurrent) { self.timeZone = timeZone }
}
public actor SystemUUIDProvider: UUIDProviding {
    public init() {}
    public func nextUUID() -> UUID { UUID() }
}
public actor SystemScheduler: Scheduling {
    public init() {}
    public func schedule(_ operation: @escaping @Sendable () async -> Void) { Task { await operation() } }
}

public struct DayBoundary: Equatable, Sendable {
    public let identity: DayIdentity
    public let start: Date
    public let end: Date
}

public enum DayBoundaryCalculator {
    public static func boundary(containing date: Date, calendar: CalendarProviding, timeZone: TimeZone) -> DayBoundary? {
        let source = calendar.components(in: timeZone, from: date)
        guard let era = source.era, let year = source.year, let month = source.month, let day = source.day else { return nil }
        let identity = DayIdentity(era: era, year: year, month: month, day: day)
        var startComponents = DateComponents(); startComponents.era = era; startComponents.year = year; startComponents.month = month; startComponents.day = day
        guard let start = calendar.date(from: startComponents, in: timeZone),
              let end = calendar.date(byAdding: .day, value: 1, to: start, in: timeZone) else { return nil }
        return DayBoundary(identity: identity, start: start, end: end)
    }
}

public enum LogCategory: String, CaseIterable, Sendable {
    case lifecycle
    case accessoryProvisioning = "accessory provisioning"
    case connection
    case gatt = "GATT"
    case framing
    case history
    case storage
    case analytics
    case healthKit = "HealthKit"
    case background
    case workout
}

public struct DiagnosticEvent: Equatable, Sendable {
    public let category: LogCategory
    public let name: String
    public let timestamp: Date
    public init(category: LogCategory, name: String, timestamp: Date) { self.category = category; self.name = name; self.timestamp = timestamp }
}

public enum DiagnosticRedactor {
    public static let redacted = "[REDACTED]"
    public static func redactSensitive(_ value: String) -> String { redacted }
}

public actor DiagnosticEventStore {
    public static let defaultCapacity = 500
    private let capacity: Int
    private var storage: [DiagnosticEvent] = []
    public init(capacity: Int = defaultCapacity) { self.capacity = max(1, capacity) }
    public func append(_ event: DiagnosticEvent) {
        storage.append(event)
        if storage.count > capacity { storage.removeFirst(storage.count - capacity) }
    }
    public func events() -> [DiagnosticEvent] { storage }
}
