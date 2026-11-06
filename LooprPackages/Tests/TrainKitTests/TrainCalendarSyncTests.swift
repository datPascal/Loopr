import Foundation
import Testing
import TrainKit

/// Calendar export against a fake writer that follows the `TrainCalendarWriter` contract: one event per key.
struct TrainCalendarSyncTests {
    /// Tuesday 2023-11-14, 10:00 in Perth.
    private let now = Date(timeIntervalSince1970: 1_699_927_200)
    private let upper = ProgramTemplates.upper
    private let zone = ProgramTemplates.zone

    private var perth: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Australia/Perth") ?? .gmt
        return calendar
    }

    private func context(_ now: Date? = nil, completed: [CompletedSession] = []) -> ProgramScheduler.Context {
        .init(now: now ?? self.now, completed: completed, lightExemptTemplateIDs: [zone.id])
    }

    private func program(status: ProgramStatus = .active, export: Bool = true, weeks: Int = 8) -> Program {
        Program(id: UUID(uuidString: "7A0460FE-0000-4000-8000-000000000011") ?? UUID(), revision: 1, name: "Strength block",
                source: .manual, status: status, startDay: "2023-10-30", weeks: ProgramTemplates.weeks(count: weeks),
                rules: ProgramRules(calendarExport: export))
    }

    private func sync(_ writer: FakeCalendar) -> TrainCalendarSync { TrainCalendarSync(writer: writer) }

    // MARK: Events

    @Test func upcomingSessionsBecomeEventsWithStableKeysAndTimes() {
        let events = TrainCalendarExport.events(for: program(), templates: [upper, zone], context: context(), calendar: perth, horizonDays: 8)
        // Tuesday 14 and Wednesday 15 of week 3, then Tuesday 21 and Wednesday 22 of week 4.
        #expect(events.map(\.title) == ["Upper A", "Zone 2", "Upper A", "Zone 2"])
        let first = events[0]
        #expect(first.key == "loopr.program.7a0460fe-0000-4000-8000-000000000011.w3.d2")
        #expect(!first.isAllDay)
        let parts = perth.dateComponents([.year, .month, .day, .hour, .minute], from: first.start)
        #expect(parts.day == 14 && parts.month == 11 && parts.hour == 18 && parts.minute == 0)
        #expect(first.end > first.start && first.notes.contains("Week 3 of 8 in Strength block"))
        // A slot without a time is an all-day event.
        #expect(events[1].isAllDay && perth.component(.hour, from: events[1].start) == 0)
        #expect(Set(events.map(\.key)).count == events.count)
    }

    @Test func doneSessionsAndPastDaysAreLeftOut() {
        let done = CompletedSession(localDay: "2023-11-14", templateID: upper.id, programWeek: 3)
        let events = TrainCalendarExport.events(for: program(), templates: [upper, zone], context: context(completed: [done]), calendar: perth, horizonDays: 1)
        #expect(events.map(\.title) == ["Zone 2"])
    }

    @Test func onlyAnActiveProgramExports() {
        for status in [ProgramStatus.draft, .paused, .completed, .archived] {
            #expect(TrainCalendarExport.events(for: program(status: status), templates: [upper, zone], context: context(), calendar: perth).isEmpty)
        }
    }

    @Test func aProgramPastItsLastWeekExportsNothing() {
        #expect(TrainCalendarExport.events(for: program(weeks: 2), templates: [upper, zone], context: context(), calendar: perth).isEmpty)
    }

    @Test func aMovedSessionKeepsItsKey() {
        // Planned for Monday 13th and not done, so on Tuesday 14th it moves to today and keeps its Monday key.
        var moved = program()
        moved.weeks[2] = [ProgramSlot(weekday: .monday, templateID: upper.id, startMinute: 18 * 60)]
        let events = TrainCalendarExport.events(for: moved, templates: [upper, zone], context: context(), calendar: perth, horizonDays: 0)
        #expect(events.map(\.key) == ["loopr.program.7a0460fe-0000-4000-8000-000000000011.w3.d1"])
        #expect(perth.component(.day, from: events[0].start) == 14)
    }

    // MARK: Diff

    @Test func diffCreatesUpdatesAndRemovesByKey() {
        func event(_ key: String, hour: Int) -> TrainCalendarEvent {
            TrainCalendarEvent(key: key, title: key, start: Date(timeIntervalSince1970: Double(hour) * 3_600),
                               end: Date(timeIntervalSince1970: Double(hour + 1) * 3_600), isAllDay: false, notes: "")
        }
        let diff = TrainCalendarDiff(existing: ["a": "id-a", "b": "id-b"], desired: [event("b", hour: 5), event("c", hour: 6), event("c", hour: 7)])
        #expect(diff.create.map(\.key) == ["c"] && diff.create[0].start == Date(timeIntervalSince1970: 7 * 3_600))
        #expect(diff.update.map(\.identifier) == ["id-b"])
        #expect(diff.remove.map(\.key) == ["a"] && diff.remove.map(\.identifier) == ["id-a"])
    }

    // MARK: Sync

    @Test func turnOnAsksThenCreatesEvents() async {
        let writer = FakeCalendar(access: .notDetermined, grants: true)
        let outcome = await sync(writer).turnOn(program: program(), templates: [upper, zone], context: context(), calendar: perth)
        guard case .synced(let result) = outcome else { Issue.record("expected synced, got \(outcome)"); return }
        #expect(result.created > 0 && result.updated == 0 && result.removed == 0)
        #expect(await writer.requests == 1)
        #expect(await writer.count == result.created)
    }

    @Test func exportingAgainUpdatesWithoutDuplicates() async {
        let writer = FakeCalendar(access: .granted, grants: true)
        let calendarSync = sync(writer)
        _ = await calendarSync.turnOn(program: program(), templates: [upper, zone], context: context(), calendar: perth)
        let created = await writer.count
        let again = await calendarSync.refresh(program: program(), templates: [upper, zone], context: context(), calendar: perth)
        guard case .synced(let result) = again else { Issue.record("expected synced"); return }
        #expect(result.created == 0 && result.updated == created && result.removed == 0)
        #expect(await writer.count == created)
        // The plan changes: Tuesday's session gets a new time. The same event updates.
        var edited = program()
        edited.weeks = edited.weeks.map { $0.map { ProgramSlot(weekday: $0.weekday, templateID: $0.templateID, kind: $0.kind, tag: $0.tag, startMinute: $0.weekday == .tuesday ? 7 * 60 : $0.startMinute) } }
        _ = await calendarSync.refresh(program: edited, templates: [upper, zone], context: context(), calendar: perth)
        #expect(await writer.count == created)
        let key = TrainCalendarKeys.key(programID: edited.id, week: 3, weekday: .tuesday)
        let updated = await writer.event(key)
        #expect(perth.component(.hour, from: updated?.start ?? .distantPast) == 7)
    }

    @Test func aSessionThatNoLongerAppearsIsRemoved() async {
        let writer = FakeCalendar(access: .granted, grants: true)
        let calendarSync = sync(writer)
        _ = await calendarSync.refresh(program: program(), templates: [upper, zone], context: context(), calendar: perth)
        let before = await writer.count
        let done = CompletedSession(localDay: "2023-11-14", templateID: upper.id, programWeek: 3)
        let outcome = await calendarSync.refresh(program: program(), templates: [upper, zone], context: context(completed: [done]), calendar: perth)
        guard case .synced(let result) = outcome else { Issue.record("expected synced"); return }
        let after = await writer.count
        #expect(result.removed == 1 && after == before - 1)
    }

    @Test func turningOffRemovesEveryEventLooprCreated() async {
        let writer = FakeCalendar(access: .granted, grants: true)
        let calendarSync = sync(writer)
        let on = program()
        _ = await calendarSync.refresh(program: on, templates: [upper, zone], context: context(), calendar: perth)
        let other = await writer.add(prefix: "someone.else.", count: 2)
        let created = await writer.count - other
        #expect(created > 0)
        let outcome = await calendarSync.clear(programID: on.id)
        guard case .cleared(let result) = outcome else { Issue.record("expected cleared"); return }
        let left = await writer.count
        #expect(result.removed == created && left == other)
        // Refresh with the switch off clears too.
        _ = await calendarSync.refresh(program: on, templates: [upper, zone], context: context(), calendar: perth)
        let off = await calendarSync.refresh(program: program(export: false), templates: [upper, zone], context: context(), calendar: perth)
        if case .cleared = off {} else { Issue.record("expected cleared, got \(off)") }
        let remaining = await writer.count
        #expect(remaining == other)
    }

    @Test func aDraftNeverReachesCalendarEvenWithTheSwitchOn() async {
        let writer = FakeCalendar(access: .granted, grants: true)
        let outcome = await sync(writer).refresh(program: program(status: .draft), templates: [upper, zone], context: context(), calendar: perth)
        if case .cleared = outcome {} else { Issue.record("expected cleared, got \(outcome)") }
        #expect(await writer.count == 0)
        let turnOn = await sync(writer).turnOn(program: program(status: .draft), templates: [upper, zone], context: context(), calendar: perth)
        guard case .synced(let result) = turnOn else { Issue.record("expected synced"); return }
        let stored = await writer.count
        #expect(result.saved == 0 && stored == 0)
    }

    @Test func deniedAccessWritesNothingAndSaysSo() async {
        let writer = FakeCalendar(access: .denied, grants: false)
        let calendarSync = sync(writer)
        #expect(await calendarSync.turnOn(program: program(), templates: [upper, zone], context: context(), calendar: perth) == .denied)
        #expect(await calendarSync.refresh(program: program(), templates: [upper, zone], context: context(), calendar: perth) == .denied)
        #expect(await writer.count == 0)
        #expect(ProgramScreenModel.calendarDeniedMessage == "Calendar access is off. Turn it on in Settings to add sessions.")
    }

    @Test func refreshNeverPromptsAndTheFirstAskHappensOnTurnOn() async {
        let writer = FakeCalendar(access: .notDetermined, grants: true)
        #expect(await sync(writer).refresh(program: program(), templates: [upper, zone], context: context(), calendar: perth) == .denied)
        #expect(await writer.requests == 0)
        _ = await sync(writer).turnOn(program: program(), templates: [upper, zone], context: context(), calendar: perth)
        #expect(await writer.requests == 1)
    }

    @Test func aWriterErrorBecomesAPlainMessage() async {
        let writer = FakeCalendar(access: .granted, grants: true, fails: true)
        let outcome = await sync(writer).refresh(program: program(), templates: [upper, zone], context: context(), calendar: perth)
        #expect(outcome == .failed(TrainCalendarSync.failureMessage))
    }
}

/// The contract of `TrainCalendarWriter` in memory: one event per key, update in place, remove what is not listed.
actor FakeCalendar: TrainCalendarWriter {
    private var access: TrainCalendarAuthorization
    private let grants: Bool
    private let fails: Bool
    private var events: [String: TrainCalendarEvent] = [:]
    private(set) var requests = 0

    init(access: TrainCalendarAuthorization, grants: Bool, fails: Bool = false) { self.access = access; self.grants = grants; self.fails = fails }

    var count: Int { events.count }
    func event(_ key: String) -> TrainCalendarEvent? { events[key] }

    func add(prefix: String, count: Int) -> Int {
        for index in 0..<count {
            events["\(prefix)\(index)"] = TrainCalendarEvent(key: "\(prefix)\(index)", title: "Other", start: .distantPast, end: .distantPast, isAllDay: true, notes: "")
        }
        return count
    }

    func authorization() async -> TrainCalendarAuthorization { access }

    func requestAccess() async -> Bool {
        requests += 1
        if access == .notDetermined { access = grants ? .granted : .denied }
        return access == .granted
    }

    func replaceEvents(keyPrefix: String, with desired: [TrainCalendarEvent]) async throws -> TrainCalendarReplaceResult {
        if fails { throw FakeCalendarError.refused }
        var result = TrainCalendarReplaceResult()
        let keys = Set(desired.map(\.key))
        for key in events.keys where key.hasPrefix(keyPrefix) && !keys.contains(key) { events[key] = nil; result.removed += 1 }
        for event in desired where event.key.hasPrefix(keyPrefix) {
            if events[event.key] == nil { result.created += 1 } else { result.updated += 1 }
            events[event.key] = event
        }
        return result
    }
}

enum FakeCalendarError: Error { case refused }

/// The fixture templates and the eight-week Strength block, as the app fixture builds them.
enum ProgramTemplates {
    static let upper = WorkoutTemplate(id: UUID(uuidString: "7A0460FE-0000-4000-8000-000000000001") ?? UUID(), name: "Upper A",
                                       weekdays: [.tuesday], exercises: [TrainFixture.line(TrainFixture.bench)])
    static let lowerA = WorkoutTemplate(id: UUID(uuidString: "7A0460FE-0000-4000-8000-000000000002") ?? UUID(), name: "Lower A",
                                        weekdays: [.monday], exercises: [TrainFixture.line(TrainFixture.row)])
    static let lowerB = WorkoutTemplate(id: UUID(uuidString: "7A0460FE-0000-4000-8000-000000000003") ?? UUID(), name: "Lower B",
                                        weekdays: [.thursday], exercises: [TrainFixture.line(TrainFixture.pushdown)])
    static let upperB = WorkoutTemplate(id: UUID(uuidString: "7A0460FE-0000-4000-8000-000000000004") ?? UUID(), name: "Upper B",
                                        weekdays: [.saturday], exercises: [TrainFixture.line(TrainFixture.bench)])
    static let zone = WorkoutTemplate(id: UUID(uuidString: "7A0460FE-0000-4000-8000-000000000005") ?? UUID(), name: "Zone 2", kind: .cardio,
                                      weekdays: [.wednesday], cardio: CardioTarget(activity: .run, minutes: 45, zone: 2))

    static var all: [WorkoutTemplate] { [lowerA, upper, zone, lowerB, upperB] }

    /// Weeks 4 and 7 are light. Week 3 has heavy Lower B and Upper B. Upper A starts at 18:00. Only Monday to Wednesday here
    /// when `short` is true, which keeps the calendar tests small.
    static func weeks(count: Int, full: Bool = false) -> [[ProgramSlot]] {
        (1...count).map { number in
            let light = number == 4 || number == 7
            let heavy = number == 3
            func kind(_ heavyDay: Bool) -> ProgramSlotKind { light ? .light : heavy && heavyDay ? .heavy : .normal }
            var slots = [
                ProgramSlot(weekday: .tuesday, templateID: upper.id, kind: kind(false), tag: "UA", startMinute: 18 * 60),
                ProgramSlot(weekday: .wednesday, templateID: zone.id, kind: .normal, tag: "Z2")
            ]
            if full {
                slots += [ProgramSlot(weekday: .monday, templateID: lowerA.id, kind: kind(false), tag: "LA"),
                          ProgramSlot(weekday: .thursday, templateID: lowerB.id, kind: kind(true), tag: "LB"),
                          ProgramSlot(weekday: .saturday, templateID: upperB.id, kind: kind(true), tag: "UB")]
            }
            return slots.sorted { $0.weekday < $1.weekday }
        }
    }
}
