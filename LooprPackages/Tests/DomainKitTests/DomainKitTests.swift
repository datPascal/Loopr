import DomainKit
import Foundation
import Testing
import TestSupport

@Suite struct DomainKitTests {
    @Test func typedIdentifiersAndDayIdentityAreDistinct() {
        let uuid = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        #expect(DeviceID(rawValue: uuid).rawValue == uuid)
        #expect(SessionID(rawValue: uuid).rawValue == uuid)
        #expect(WorkoutID(rawValue: uuid).rawValue == uuid)
        #expect(DayID(rawValue: uuid).rawValue == uuid)
        #expect(RecordID(rawValue: uuid).rawValue == uuid)
        #expect(DayIdentity(year: 2026, month: 8, day: 16) != DayIdentity(year: 2026, month: 8, day: 17))
    }

    @Test func metricEnvelopeKeepsAbsentAndMeasuredZeroDistinct() {
        let absent: MetricEnvelope<Double> = .absent
        let zero: MetricEnvelope<Double> = .measured(0)
        let present: MetricEnvelope<Double> = .measured(42)
        #expect(absent != zero); #expect(zero != present); #expect(absent != present)
    }

    @Test func deterministicDependenciesAreControllable() async {
        let start = Date(timeIntervalSince1970: 1_000)
        let clock = FakeDateProvider(now: start); clock.advance(by: 25)
        #expect(clock.now() == Date(timeIntervalSince1970: 1_025))
        let expected = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let uuids = FakeUUIDProvider(values: [expected]); #expect(await uuids.nextUUID() == expected)
        let scheduler = FakeScheduler(); await scheduler.schedule({}); #expect(await scheduler.pendingCount() == 1); await scheduler.runNext(); #expect(await scheduler.pendingCount() == 0)
    }

    @Test func dayBoundaryUsesCalendarAcrossDST() {
        let timeZone = TimeZone(identifier: "America/Los_Angeles")!
        var components = DateComponents(); components.year = 2026; components.month = 3; components.day = 8; components.hour = 12
        let calendar = FakeCalendarProvider(); let date = calendar.date(from: components, in: timeZone)!
        let boundary = DayBoundaryCalculator.boundary(containing: date, calendar: calendar, timeZone: timeZone)!
        #expect(boundary.end.timeIntervalSince(boundary.start) == 23 * 60 * 60)
    }

    @Test func loggingCategoriesAreExact() {
        #expect(LogCategory.allCases.map(\.rawValue) == ["lifecycle", "accessory provisioning", "connection", "GATT", "framing", "history", "storage", "analytics", "HealthKit", "background", "workout"])
    }

    @Test func diagnosticStoreIsBoundedAndEvictsOldest() async {
        let store = DiagnosticEventStore()
        for index in 0..<600 { await store.append(.init(category: .lifecycle, name: "event-\(index)", timestamp: Date(timeIntervalSince1970: Double(index)))) }
        let events = await store.events(); #expect(events.count == 500); #expect(events.first?.name == "event-100"); #expect(events.last?.name == "event-599")
    }

    @Test func diagnosticLogRedactsSensitiveShapedValues() {
        for value in ["hr=187", "bytes=AAFF19", "journal=private text"] { #expect(DiagnosticRedactor.redactSensitive(value) == "[REDACTED]") }
    }

    @Test func repeatedInjectedOperationIsByteIdentical() throws {
        let event = DiagnosticEvent(category: .lifecycle, name: "started", timestamp: Date(timeIntervalSince1970: 123))
        let first = "\(event.category.rawValue)|\(event.name)|\(event.timestamp.timeIntervalSince1970)".data(using: .utf8)
        let second = "\(event.category.rawValue)|\(event.name)|\(event.timestamp.timeIntervalSince1970)".data(using: .utf8)
        #expect(first == second)
    }
}
