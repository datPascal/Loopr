import Foundation

/// Turns an accepted program into the Calendar events for its upcoming sessions. Pure value logic.
public enum TrainCalendarExport {
    /// How far ahead sessions are written.
    public static let defaultHorizonDays = 56

    /// Upcoming sessions of an active program, from today to `horizonDays` ahead.
    ///
    /// - A draft, paused, completed or archived program returns no events, so nothing leaks before the person accepts.
    /// - Done and skipped sessions are left out. A moved session appears on its new day under its original key.
    /// - It does not read `rules.calendarExport`. The caller decides whether the person asked for export.
    public static func events(for program: Program, templates: [WorkoutTemplate], context: ProgramScheduler.Context,
                              calendar: Calendar, horizonDays: Int = defaultHorizonDays) -> [TrainCalendarEvent] {
        guard program.status == .active else { return [] }
        let scheduler = ProgramScheduler(calendar: calendar)
        let today = scheduler.localDay(for: context.now)
        guard let todayOrdinal = TrainDayMath.ordinal(today), let startOrdinal = TrainDayMath.ordinal(program.startDay) else { return [] }
        let last = todayOrdinal + max(horizonDays, 0)
        let byID = Dictionary(templates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let firstWeek = max(1, (todayOrdinal - startOrdinal) / 7 + 1)
        guard firstWeek <= program.weeks.count else { return [] }
        let slots = Dictionary(uniqueKeysWithValues: program.weeks.enumerated().map { index, week in
            (index + 1, Dictionary(week.map { ($0.weekday, $0) }, uniquingKeysWith: { first, _ in first }))
        })

        var events: [TrainCalendarEvent] = []
        for week in firstWeek...program.weeks.count {
            if startOrdinal + 7 * (week - 1) > last { break }
            let plan = scheduler.evaluate(program: program, week: week, context: context)
            for session in plan.sessions where session.status == .scheduled {
                guard let day = TrainDayMath.ordinal(session.localDay), day >= todayOrdinal, day <= last,
                      let template = byID[session.templateID] else { continue }
                let slot = slots[week]?[session.originalWeekday]
                guard let start = start(of: session.localDay, minute: slot?.startMinute, calendar: calendar) else { continue }
                let minutes = duration(of: template)
                let end = slot?.startMinute == nil
                    ? (calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400))
                    : start.addingTimeInterval(Double(minutes) * 60)
                events.append(TrainCalendarEvent(
                    key: TrainCalendarKeys.key(programID: program.id, week: week, weekday: session.originalWeekday),
                    title: template.name, start: start, end: end, isAllDay: slot?.startMinute == nil,
                    notes: notes(program: program, week: week, kind: session.kind)))
            }
        }
        return events.sorted { ($0.start, $0.key) < ($1.start, $1.key) }
    }

    private static func start(of localDay: String, minute: Int?, calendar: Calendar) -> Date? {
        let pieces = localDay.split(separator: "-").compactMap { Int($0) }
        guard pieces.count == 3 else { return nil }
        let minute = minute ?? 0
        return calendar.date(from: DateComponents(year: pieces[0], month: pieces[1], day: pieces[2], hour: minute / 60, minute: minute % 60))
    }

    /// Minutes the event lasts. A strength template uses its estimate and a cardio template its target.
    static func duration(of template: WorkoutTemplate) -> Int {
        let minutes = TemplateSummary(template: template).estimatedMinutes
        return minutes > 0 ? minutes : 60
    }

    private static func notes(program: Program, week: Int, kind: ProgramSlotKind) -> String {
        var text = "Week \(week) of \(program.weekCount) in \(program.name)."
        switch kind {
        case .light: text += " Lighter session."
        case .heavy: text += " Heavy session."
        case .normal: break
        }
        return text + " Planned in Loopr."
    }
}

/// Keeps Calendar in step with a program through a `TrainCalendarWriter`.
public struct TrainCalendarSync: Sendable {
    public enum Outcome: Equatable, Sendable {
        /// Calendar now matches the plan.
        case synced(TrainCalendarReplaceResult)
        /// Calendar access is off. Nothing was written.
        case denied
        /// Export is off or the program is not active, so Loopr's events were removed.
        case cleared(TrainCalendarReplaceResult)
        /// Calendar refused the change. The message is for the person.
        case failed(String)
    }

    public static let failureMessage = "Calendar could not save these sessions. Try again."

    private let writer: any TrainCalendarWriter

    public init(writer: any TrainCalendarWriter) { self.writer = writer }

    /// Asks for access, which shows the system prompt the first time, then writes the upcoming sessions.
    /// Call it only when the person turns Add to Calendar on.
    public func turnOn(program: Program, templates: [WorkoutTemplate], context: ProgramScheduler.Context,
                       calendar: Calendar) async -> Outcome {
        guard await writer.requestAccess() else { return .denied }
        return await write(program: program, templates: templates, context: context, calendar: calendar)
    }

    /// Brings Calendar in line with the program after a reschedule or an edit. It never prompts.
    /// A program with export off, or one that is not active, has its events removed.
    public func refresh(program: Program, templates: [WorkoutTemplate], context: ProgramScheduler.Context,
                        calendar: Calendar) async -> Outcome {
        guard program.rules.calendarExport, program.status == .active else { return await clear(programID: program.id) }
        guard await writer.authorization() == .granted else { return .denied }
        return await write(program: program, templates: templates, context: context, calendar: calendar)
    }

    /// Removes every event Loopr saved for the program. Used when export turns off and when a program is deleted.
    public func clear(programID: UUID) async -> Outcome {
        guard await writer.authorization() == .granted else { return .cleared(.init()) }
        do {
            return .cleared(try await writer.replaceEvents(keyPrefix: TrainCalendarKeys.prefix(programID: programID), with: []))
        } catch {
            return .failed(Self.failureMessage)
        }
    }

    private func write(program: Program, templates: [WorkoutTemplate], context: ProgramScheduler.Context,
                       calendar: Calendar) async -> Outcome {
        let events = TrainCalendarExport.events(for: program, templates: templates, context: context, calendar: calendar)
        do {
            return .synced(try await writer.replaceEvents(keyPrefix: TrainCalendarKeys.prefix(programID: program.id), with: events))
        } catch {
            return .failed(Self.failureMessage)
        }
    }
}
