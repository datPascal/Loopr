import DomainKit
import Foundation

public final class FakeDateProvider: DateProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    public init(now: Date) { value = now }
    public func now() -> Date { lock.withLock { value } }
    public func advance(by interval: TimeInterval) { lock.withLock { value = value.addingTimeInterval(interval) } }
}

public struct FakeCalendarProvider: CalendarProviding, Sendable {
    private let base = SystemCalendarProvider()
    public init() {}
    public func components(in timeZone: TimeZone, from date: Date) -> DateComponents { base.components(in: timeZone, from: date) }
    public func date(from components: DateComponents, in timeZone: TimeZone) -> Date? { base.date(from: components, in: timeZone) }
    public func date(byAdding component: Calendar.Component, value: Int, to date: Date, in timeZone: TimeZone) -> Date? { base.date(byAdding: component, value: value, to: date, in: timeZone) }
}

public struct FakeTimeZoneProvider: TimeZoneProviding, Sendable {
    public let timeZone: TimeZone
    public init(timeZone: TimeZone) { self.timeZone = timeZone }
}

public actor FakeUUIDProvider: UUIDProviding {
    private var values: [UUID]
    public init(values: [UUID]) { self.values = values }
    public func nextUUID() -> UUID { precondition(!values.isEmpty, "Fake UUID sequence exhausted"); return values.removeFirst() }
}

public actor FakeScheduler: Scheduling {
    private var operations: [@Sendable () async -> Void] = []
    public init() {}
    public func schedule(_ operation: @escaping @Sendable () async -> Void) { operations.append(operation) }
    public func runNext() async { guard !operations.isEmpty else { return }; await operations.removeFirst()() }
    public func pendingCount() -> Int { operations.count }
}
