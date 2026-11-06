import Foundation

/// One recovery score on one local day.
public struct RecoveryReading: Equatable, Hashable, Sendable {
    public let localDay: String
    public let score: Double

    public init(localDay: String, score: Double) { self.localDay = localDay; self.score = score }
}

/// A finished session, reduced to what the scheduler needs to know which slots are done.
public struct CompletedSession: Equatable, Hashable, Sendable {
    public let localDay: String
    public let templateID: UUID?
    public let programWeek: Int?

    public init(localDay: String, templateID: UUID?, programWeek: Int?) {
        self.localDay = localDay; self.templateID = templateID; self.programWeek = programWeek
    }

    public init(_ session: TrainSession) {
        self.init(localDay: session.localDay, templateID: session.templateID, programWeek: session.programWeek)
    }

    /// The completed sessions in `sessions`.
    public static func completed(in sessions: [TrainSession]) -> [CompletedSession] {
        sessions.filter { $0.status == .completed }.map(CompletedSession.init)
    }
}

/// Why the schedule looks the way it does. The UI words these with `message`.
public enum ScheduleReason: Equatable, Sendable {
    case notActive
    case beforeStart
    case afterEnd
    case restDay
    case earlyLightWeek(week: Int, averageRecovery: Int, windowDays: Int)
    /// The session was moved here from its planned weekday.
    case movedBack(from: TrainWeekday)
    case missedSkipped(weekday: TrainWeekday)
    /// The session was missed and no day is left this week to move it to.
    case noFreeDay(weekday: TrainWeekday)

    public var message: String {
        switch self {
        case .notActive: "This program is not active."
        case .beforeStart: "This program has not started yet."
        case .afterEnd: "This program has finished."
        case .restDay: "Nothing planned."
        case .earlyLightWeek(let week, let average, let window):
            "Week \(week) is lighter. Recovery averaged \(average) over the last \(window) days."
        case .movedBack(let from): "Moved from \(from.ruleName) so no day has two sessions."
        case .missedSkipped(let weekday): "Skipped \(weekday.ruleName)'s session and carried on."
        case .noFreeDay(let weekday): "\(weekday.ruleName)'s session was missed and no day is free this week."
        }
    }
}

/// How the early light week rule came out for a week.
public enum EarlyLightOutcome: Equatable, Sendable {
    case ruleOff
    /// The week was already made light and recorded. `average` is the recorded recovery average.
    case alreadyLight(average: Double?)
    /// The week was already checked and left as planned. Nothing is decided again.
    case alreadyDeclined(average: Double?, daysWithReadings: Int?)
    /// The week's first strength slot day has not arrived yet, so nothing was decided.
    case notDueYet
    /// Fewer recovery days than the rule needs, so no decision was possible. The week stays as planned
    /// and a declined adjustment must be saved so the week is not decided later on other data.
    case notEnoughDays(present: Int, needed: Int)
    /// The average was low. The week is light and a new adjustment must be saved.
    case triggered(average: Double, daysUsed: Int)
    /// The average was high enough. The week stays as planned and a declined adjustment must be saved.
    case notTriggered(average: Double, daysUsed: Int)
}

/// One program slot placed on a real day.
public struct ScheduledSession: Equatable, Sendable, Identifiable {
    public enum Status: String, Sendable { case scheduled, completed, skipped }

    public var id: String { "\(week)-\(originalWeekday.rawValue)" }
    public let week: Int
    public let originalWeekday: TrainWeekday
    /// The day the session happens on. Equal to the planned day unless it was moved.
    public let localDay: String
    public let plannedLocalDay: String
    public let templateID: UUID
    public let plannedKind: ProgramSlotKind
    /// The kind after the early light week rule.
    public let kind: ProgramSlotKind
    public let tag: String?
    /// The slot's planned start in minutes after local midnight, or nil when it has no set time.
    public let startMinute: Int?
    public let status: Status
    public let reasons: [ScheduleReason]

    public var isMoved: Bool { localDay != plannedLocalDay }
}

/// A whole program week with the rules applied.
public struct WeekPlan: Equatable, Sendable {
    public let week: Int
    public let sessions: [ScheduledSession]
    public let earlyLight: EarlyLightOutcome
    /// Decisions made in this pass. Save them on the program. Planning again afterwards returns
    /// the same sessions and no new adjustments.
    public let newAdjustments: [ProgramAdjustment]
    public let reasons: [ScheduleReason]
}

/// One local day resolved against a program.
public struct DayPlan: Equatable, Sendable {
    public let localDay: String
    /// The 1-based program week, or nil before the start or after the last week.
    public let week: Int?
    public let sessions: [ScheduledSession]
    public let earlyLight: EarlyLightOutcome?
    public let newAdjustments: [ProgramAdjustment]
    public let reasons: [ScheduleReason]
}

/// Places a program on real days and applies its rules. Pure value logic: the only time input is
/// the `now` the caller passes, and the calendar only turns that instant into a local day.
public struct ProgramScheduler: Sendable {
    public struct Context: Sendable {
        public var now: Date
        public var recovery: [RecoveryReading]
        public var completed: [CompletedSession]
        /// Templates the early light week rule leaves alone, such as cardio.
        public var lightExemptTemplateIDs: Set<UUID>

        public init(now: Date, recovery: [RecoveryReading] = [], completed: [CompletedSession] = [],
                    lightExemptTemplateIDs: Set<UUID> = []) {
            self.now = now; self.recovery = recovery; self.completed = completed
            self.lightExemptTemplateIDs = lightExemptTemplateIDs
        }
    }

    public let calendar: Calendar

    public init(calendar: Calendar) { self.calendar = calendar }

    /// The `yyyy-MM-dd` local day of an instant in the scheduler's calendar and time zone.
    public func localDay(for date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
    }

    /// The 1-based week of `localDay`, or nil outside the program. Weeks are blocks of seven days from `startDay`.
    public func week(containing localDay: String, in program: Program) -> Int? {
        guard let start = TrainDayMath.ordinal(program.startDay), let day = TrainDayMath.ordinal(localDay), day >= start else { return nil }
        let week = (day - start) / 7 + 1
        return week <= program.weeks.count ? week : nil
    }

    // MARK: Day

    public func resolve(day localDay: String, program: Program, context: Context) -> DayPlan {
        guard program.status == .active else {
            return .init(localDay: localDay, week: nil, sessions: [], earlyLight: nil, newAdjustments: [], reasons: [.notActive])
        }
        guard let start = TrainDayMath.ordinal(program.startDay), let day = TrainDayMath.ordinal(localDay) else {
            return .init(localDay: localDay, week: nil, sessions: [], earlyLight: nil, newAdjustments: [], reasons: [.notActive])
        }
        guard let week = week(containing: localDay, in: program) else {
            return .init(localDay: localDay, week: nil, sessions: [], earlyLight: nil, newAdjustments: [],
                         reasons: [day < start ? .beforeStart : .afterEnd])
        }
        let plan = evaluate(program: program, week: week, context: context)
        let sessions = plan.sessions.filter { sessionDay($0) == localDay }
        let reasons: [ScheduleReason] = sessions.isEmpty ? [.restDay] : []
        return .init(localDay: localDay, week: week, sessions: sessions, earlyLight: plan.earlyLight,
                     newAdjustments: plan.newAdjustments, reasons: reasons)
    }

    private func sessionDay(_ session: ScheduledSession) -> String {
        // A skipped session stays on its planned day so the person can see what was dropped.
        session.status == .skipped ? session.plannedLocalDay : session.localDay
    }

    // MARK: Week

    private struct Work {
        let slot: ProgramSlot
        let plannedDay: Int
        var currentDay: Int
        var kind: ProgramSlotKind
        var status: ScheduledSession.Status = .scheduled
        var reasons: [ScheduleReason] = []
    }

    public func evaluate(program: Program, week: Int, context: Context) -> WeekPlan {
        func empty(_ reasons: [ScheduleReason]) -> WeekPlan {
            .init(week: week, sessions: [], earlyLight: .notDueYet, newAdjustments: [], reasons: reasons)
        }
        guard program.status == .active else { return empty([.notActive]) }
        guard let startOrdinal = TrainDayMath.ordinal(program.startDay), week >= 1 else { return empty([.beforeStart]) }
        guard week <= program.weeks.count else { return empty([.afterEnd]) }
        guard let today = TrainDayMath.ordinal(localDay(for: context.now)) else { return empty([.notActive]) }

        let startWeekday = TrainDayMath.weekday(ordinal: startOrdinal)
        let blockStart = startOrdinal + 7 * (week - 1)
        let blockEnd = blockStart + 6
        func day(of weekday: TrainWeekday) -> Int { blockStart + ((weekday.rawValue - startWeekday.rawValue) % 7 + 7) % 7 }

        var works = program.weeks[week - 1].map { slot -> Work in
            let planned = day(of: slot.weekday)
            return Work(slot: slot, plannedDay: planned, currentDay: planned, kind: slot.kind)
        }.sorted { ($0.plannedDay, $0.slot.weekday) < ($1.plannedDay, $1.slot.weekday) }

        var newAdjustments: [ProgramAdjustment] = []

        // Early light week: decided once, on the first evaluation on or after the first strength slot day.
        // The window is the seven local days before that slot day, so the inputs are fixed in the past and
        // the result does not depend on which day the app was first opened. Both outcomes are recorded.
        let rules = program.rules
        let outcome: EarlyLightOutcome
        var lightReason: ScheduleReason?
        if let recorded = program.adjustments.last(where: { ($0.kind == .earlyLightWeek || $0.kind == .earlyLightDeclined) && $0.week == week }) {
            if recorded.kind == .earlyLightWeek {
                outcome = .alreadyLight(average: recorded.recoveryScore)
                lightReason = .earlyLightWeek(week: week, averageRecovery: Self.whole(recorded.recoveryScore ?? 0), windowDays: rules.earlyLightWindowDays)
            } else {
                outcome = .alreadyDeclined(average: recorded.recoveryScore, daysWithReadings: recorded.daysWithReadings)
            }
        } else if !rules.earlyLightWeek {
            outcome = .ruleOff
        } else if let first = works.first(where: { !context.lightExemptTemplateIDs.contains($0.slot.templateID) }), first.plannedDay <= today {
            let readings = Self.readingsByDay(context.recovery)
            let window = (first.plannedDay - rules.earlyLightWindowDays)..<first.plannedDay
            let scores = window.compactMap { readings[$0] }
            let average = scores.isEmpty ? nil : scores.reduce(0, +) / Double(scores.count)
            if scores.count < rules.earlyLightMinDays {
                outcome = .notEnoughDays(present: scores.count, needed: rules.earlyLightMinDays)
                newAdjustments.append(ProgramAdjustment(
                    kind: .earlyLightDeclined, week: week,
                    reason: "Week \(week) stays as planned. Only \(scores.count) of the last \(rules.earlyLightWindowDays) days had a recovery reading.",
                    recoveryScore: average, daysWithReadings: scores.count, createdAt: context.now))
            } else if let average, average < Double(rules.earlyLightBelowScore) {
                outcome = .triggered(average: average, daysUsed: scores.count)
                let reason = ScheduleReason.earlyLightWeek(week: week, averageRecovery: Self.whole(average), windowDays: rules.earlyLightWindowDays)
                lightReason = reason
                newAdjustments.append(ProgramAdjustment(kind: .earlyLightWeek, week: week, reason: reason.message,
                                                        recoveryScore: average, daysWithReadings: scores.count, createdAt: context.now))
            } else {
                let shown = Self.whole(average ?? 0)
                outcome = .notTriggered(average: average ?? 0, daysUsed: scores.count)
                newAdjustments.append(ProgramAdjustment(
                    kind: .earlyLightDeclined, week: week,
                    reason: "Week \(week) stays as planned. Recovery averaged \(shown) over the last \(rules.earlyLightWindowDays) days.",
                    recoveryScore: average, daysWithReadings: scores.count, createdAt: context.now))
            }
        } else {
            outcome = .notDueYet
        }
        if let lightReason {
            for index in works.indices where works[index].kind != .light && !context.lightExemptTemplateIDs.contains(works[index].slot.templateID) {
                works[index].kind = .light
                works[index].reasons.append(lightReason)
            }
        }

        // Moves already on record put a slot on its new day.
        for index in works.indices {
            let slot = works[index].slot
            if let move = program.adjustments.last(where: { $0.kind == .movedSession && $0.week == week && $0.weekday == slot.weekday }),
               let target = move.movedToWeekday {
                works[index].currentDay = day(of: target)
                works[index].reasons.append(.movedBack(from: slot.weekday))
            }
        }

        // A finished session ticks off the earliest open slot for its template in this week.
        var available = context.completed.filter { $0.programWeek == week }
        for index in works.indices.sorted(by: { (works[$0].currentDay, works[$0].slot.weekday) < (works[$1].currentDay, works[$1].slot.weekday) }) {
            if let match = available.firstIndex(where: { $0.templateID == works[index].slot.templateID }) {
                available.remove(at: match)
                works[index].status = .completed
            }
        }
        let completedDays = Set(context.completed.compactMap { TrainDayMath.ordinal($0.localDay) })

        // Missed slots: before today and not done.
        let order = works.indices.sorted { (works[$0].currentDay, works[$0].slot.weekday) < (works[$1].currentDay, works[$1].slot.weekday) }
        for index in order where works[index].status == .scheduled && works[index].currentDay < today {
            let slot = works[index].slot
            switch rules.missed {
            case .skip:
                works[index].status = .skipped
                works[index].reasons.append(.missedSkipped(weekday: slot.weekday))
            case .moveBack:
                var occupied = completedDays
                for other in works.indices where other != index && works[other].status == .scheduled { occupied.insert(works[other].currentDay) }
                let from = max(works[index].currentDay + 1, today)
                if from <= blockEnd, let free = (from...blockEnd).first(where: { !occupied.contains($0) }) {
                    works[index].currentDay = free
                    works[index].reasons.removeAll { if case .movedBack = $0 { true } else { false } }
                    works[index].reasons.append(.movedBack(from: slot.weekday))
                    newAdjustments.append(ProgramAdjustment(
                        kind: .movedSession, week: week, weekday: slot.weekday, movedToWeekday: TrainDayMath.weekday(ordinal: free),
                        reason: ScheduleReason.movedBack(from: slot.weekday).message, createdAt: context.now))
                } else {
                    works[index].status = .skipped
                    works[index].reasons.append(.noFreeDay(weekday: slot.weekday))
                }
            }
        }

        let sessions = works.map { work in
            ScheduledSession(week: week, originalWeekday: work.slot.weekday, localDay: TrainDayMath.string(ordinal: work.currentDay),
                             plannedLocalDay: TrainDayMath.string(ordinal: work.plannedDay), templateID: work.slot.templateID,
                             plannedKind: work.slot.kind, kind: work.kind, tag: work.slot.tag, startMinute: work.slot.startMinute,
                             status: work.status, reasons: work.reasons)
        }.sorted { ($0.localDay, $0.originalWeekday) < ($1.localDay, $1.originalWeekday) }
        return .init(week: week, sessions: sessions, earlyLight: outcome, newAdjustments: newAdjustments, reasons: [])
    }

    // MARK: Helpers

    private static func whole(_ value: Double) -> Int { Int(value.rounded(.down)) }

    /// One score per day. When a day has several readings the last one wins.
    private static func readingsByDay(_ readings: [RecoveryReading]) -> [Int: Double] {
        var byDay: [Int: Double] = [:]
        for reading in readings where reading.score.isFinite {
            if let day = TrainDayMath.ordinal(reading.localDay) { byDay[day] = reading.score }
        }
        return byDay
    }
}
