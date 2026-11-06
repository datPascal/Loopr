import Foundation
import RoutineKit

/// Everything the Train overview reads. The app loads these off the main
/// actor and hands them over as plain values, so the overview itself never
/// touches storage, a clock or the network.
public struct TrainOverviewInput: Sendable {
    public var now: Date
    public var calendar: Calendar
    public var templates: [WorkoutTemplate]
    public var programs: [Program]
    /// Finished sessions, newest first or in any order.
    public var sessions: [TrainSession]
    /// Recovery scores by local day. Needs the week plus the early-light window before it.
    public var recovery: [RecoveryReading]
    /// Strain of finished sessions, for the expected-strain line.
    public var strainSamples: [ExpectedStrain.Sample]
    /// A template the person chose in place of today's plan. Not saved.
    public var swappedTemplateID: UUID?
    /// The protocol's every-day Zone 2 rule, so the week and today's card show it beside the program (R3-OPT-6).
    public var dailyZone2: TrainDailyZone2?

    public init(now: Date, calendar: Calendar, templates: [WorkoutTemplate] = [], programs: [Program] = [],
                sessions: [TrainSession] = [], recovery: [RecoveryReading] = [],
                strainSamples: [ExpectedStrain.Sample] = [], swappedTemplateID: UUID? = nil,
                dailyZone2: TrainDailyZone2? = nil) {
        self.now = now; self.calendar = calendar; self.templates = templates; self.programs = programs
        self.sessions = sessions; self.recovery = recovery; self.strainSamples = strainSamples
        self.swappedTemplateID = swappedTemplateID; self.dailyZone2 = dailyZone2
    }
}

/// A protocol rule that asks for Zone 2 minutes every day, as "Zone 2, 45 min, 17:30" does. Nil for a weekly or
/// longer rule, which the weekly dose already shows, and for no rule.
public struct TrainDailyZone2: Equatable, Sendable {
    /// The rule's own name, "Zone 2, 45 min".
    public let title: String
    public let minutes: Int
    /// Minutes after local midnight, or nil for any time of day.
    public let startMinute: Int?

    public init(title: String, minutes: Int, startMinute: Int?) {
        self.title = title; self.minutes = minutes; self.startMinute = startMinute
    }

    /// The first Zone 2 rule of the protocol, the one `DoseTargets(rules:)` reads, when it is due every day.
    public init?(rules: [ProtocolRule]) {
        guard let rule = rules.first(where: { $0.target.metric == DoseTargets.zone2MinutesMetric }),
              rule.target.kind == .atLeast || rule.target.kind == .exactly,
              let value = rule.target.value, value.isFinite, value > 0 else { return nil }
        if let cadence = rule.cadence {
            guard cadence.unit == .day, cadence.every == 1 else { return nil }
        } else if let unit = rule.target.unit?.lowercased(), unit.contains("week") || unit.contains("/wk") {
            return nil
        }
        self.init(title: rule.title, minutes: Int(value.rounded()), startMinute: rule.timeOfDayMinutes)
    }

    /// True for a template that is itself a Zone 2 session.
    static func covers(_ template: WorkoutTemplate?) -> Bool {
        template?.kind == .cardio && template?.cardio?.zone == 2
    }
}

/// One cell of the week strip.
public struct TrainWeekDay: Equatable, Sendable, Identifiable {
    public let localDay: String
    public let weekday: TrainWeekday
    /// "M", "T", ...
    public let letter: String
    /// "14"
    public let numeral: String
    /// "Done", a template name, "Skipped" or "Rest".
    public let caption: String
    public let isDone: Bool
    public let isToday: Bool
    /// The first planned template, so a tap can open it.
    public let templateID: UUID?
    /// "Tuesday 14 November, Upper A, today"
    public let spokenLabel: String
    /// Gym sessions finished that day, by name.
    public var doneNames: [String] = []
    /// Sessions still planned that day: templates not yet done, and the protocol's daily Zone 2.
    public var plannedNames: [String] = []
    /// True when a planned session was skipped by the program's rules.
    public var isSkipped = false
    /// The planned names that are Zone 2 sessions: the protocol's daily Zone 2 or a Zone 2 cardio template. A run or a
    /// ride that day takes one of these off what is planned; a WOD or a stretch does not (R2-DES-06).
    public var zone2PlannedNames: [String] = []

    /// Sessions still planned that day.
    public var plannedCount: Int { plannedNames.count }

    /// `train-day-2023-11-14`
    public var id: String { "train-day-\(localDay)" }
}

/// Today's session when there is one to start.
public struct TrainTodayPlan: Equatable, Sendable {
    public let templateID: UUID
    public let name: String
    public let kind: WorkoutTemplateKind
    /// "6 exercises · about 55 min · expected strain 11"
    public let detail: String
    /// "6 exercises · about 55 min", the card's one line. Strain stays out of it (R1-NEW-09).
    public var summary: String = ""
    /// True when recovery lightened the session, so the card says why.
    public var recoveryAdjusts = false
    /// "Zone 2, 45 min at 17:30", the protocol's daily Zone 2 as a chip on the card. Nil without the rule.
    public var dailyChip: String?
    /// Today's 0 to 100 recovery score, or nil without a reading.
    public let recoveryScore: Double?
    /// The same score as the whole number the sentence shows.
    public let recoveryShown: Int?
    /// From `RecoveryAdjuster`. Nil for cardio, which has no sets to remove.
    public let recoveryMessage: String?
    /// The scheduler's reason for a lighter or moved session, such as "Week 5 is lighter. ..."
    public let scheduleNote: String?
    /// The protocol's daily Zone 2 beside a session that is not Zone 2 itself, with which comes first (R3-OPT-6).
    public let dailyNote: String?
    public let isLight: Bool
    /// The slot's planned start in minutes after local midnight, or nil when it has no set time.
    public let startMinute: Int?
    /// True when the person swapped it in for the planned session.
    public let isSwapped: Bool
    public let programID: UUID?
    public let programWeek: Int?
}

/// What the hero card says today.
public enum TrainToday: Equatable, Sendable {
    /// No template and no program. The overview shows its empty state.
    case none
    case plan(TrainTodayPlan)
    /// A session finished today and nothing else is planned.
    case done(TrainSessionSummary)
    /// Nothing planned today. `next` names the next planned day this week.
    case rest(next: String?)
}

public struct TrainProgramSummary: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let name: String
    /// `strength-block`, unique among the programs.
    public let slug: String
    public let status: ProgramStatus
    /// "8 weeks · 5 days a week", "Paused", "Completed"
    public let caption: String
    /// 0 to 1, or nil when the program is not running.
    public let progress: Double?
    /// "3" and "of 8".
    public let value: String?
    public let valueUnit: String?
    public let spokenLabel: String
}

/// An agent-built program waiting for the person's answer. It never schedules until they accept it.
public struct TrainDraftSummary: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let name: String
    /// `spring-base`, unique among programs and drafts.
    public let slug: String
    /// "4 weeks · 4 days a week"
    public let caption: String
    public let spokenLabel: String
    /// The program's revision when the overview loaded, so a stale tap cannot act on a newer draft.
    public let revision: Int
}

public struct TrainTemplateSummary: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let name: String
    /// `upper-a`, unique among the templates.
    public let slug: String
    public let kind: WorkoutTemplateKind
    /// "Bench press, Pull-up and 4 more", "45 min · zone 2"
    public let caption: String
    public let spokenLabel: String
}

/// A finished session, for the This week list.
public struct TrainSessionSummary: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let workoutID: UUID?
    public let name: String
    public let localDay: String
    public let minutes: Int?
    public let tonnageKg: Int
    /// "MON · 62 MIN · 8,420 KG"
    public let caption: String
    /// "62 min · 8,420 kg", for prose. Empty when there is neither.
    public let detail: String
    public let spokenLabel: String
    /// "Mon 13 Nov"
    public var dayLabel: String = ""
}

public struct TrainOverview: Equatable, Sendable {
    /// "WEEK 3 OF 8 · STRENGTH BLOCK", or nil when no program is running.
    public let headerMeta: String?
    /// No template and no program: the strip and the hero give way to an honest empty state.
    public let isEmpty: Bool
    public let week: [TrainWeekDay]
    /// False when nothing is planned or done this week.
    public let showsWeekStrip: Bool
    public let today: TrainToday
    public let programs: [TrainProgramSummary]
    /// Agent drafts, shown above the programs with Accept and Discard.
    public let drafts: [TrainDraftSummary]
    public let templates: [TrainTemplateSummary]
    /// Templates the person can swap in for today, everything except the one shown.
    public let swapChoices: [TrainTemplateSummary]
    public let thisWeek: [TrainSessionSummary]
    /// Every finished session that has a linked workout, so the workout list can show its tonnage.
    public let sessionsByWorkoutID: [UUID: TrainSessionSummary]
    /// The calendar the week was built in, so rows outside the model (workout records) fall on the same days.
    public var calendar: Calendar = Calendar(identifier: .gregorian)
    /// The protocol's every-day Zone 2 rule, for today's card. Nil without one.
    public var dailyZone2: TrainDailyZone2?
    /// Today's recovery as a whole number, shown on the today card whatever is planned (R2-WOD-04). Nil without a reading.
    public var todayRecovery: Int?

    public var todayTemplateID: UUID? {
        if case .plan(let plan) = today { return plan.templateID }
        return nil
    }
}

/// Builds the Train overview from loaded records. Pure value logic: the clock
/// and the time zone arrive in the input.
public struct TrainOverviewModel: Sendable {
    public let overview: TrainOverview

    public init(_ input: TrainOverviewInput) {
        overview = Self.build(input)
    }

    // MARK: Build

    private struct Entry {
        let templateID: UUID
        let status: ScheduledSession.Status
        let kind: ProgramSlotKind
        let note: String?
        let startMinute: Int?
        let programID: UUID?
        let programWeek: Int?
    }

    private static func build(_ input: TrainOverviewInput) -> TrainOverview {
        let programs = input.programs.filter { $0.status != .draft && $0.status != .archived }
        let templates = input.templates.sorted { ($0.name.lowercased(), $0.id.uuidString) < ($1.name.lowercased(), $1.id.uuidString) }
        let isEmpty = templates.isEmpty && programs.isEmpty
        let scheduler = ProgramScheduler(calendar: input.calendar)
        let today = scheduler.localDay(for: input.now)
        let completed = input.sessions.filter { $0.status == .completed }
        let templatesByID = Dictionary(templates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let context = ProgramScheduler.Context(
            now: input.now, recovery: input.recovery, completed: CompletedSession.completed(in: completed),
            lightExemptTemplateIDs: Set(templates.filter { $0.kind == .cardio }.map(\.id)))
        let activePrograms = programs.filter { $0.status == .active }.sorted { ($0.startDay, $0.name) < ($1.startDay, $1.name) }

        func entries(on day: String) -> [Entry] {
            var result: [Entry] = []
            var covered = false
            for program in activePrograms {
                let plan = scheduler.resolve(day: day, program: program, context: context)
                guard plan.week != nil else { continue }
                covered = true
                for session in plan.sessions {
                    let note = session.reasons.first { reason in
                        switch reason {
                        case .earlyLightWeek, .movedBack, .noFreeDay: true
                        default: false
                        }
                    }?.message
                    result.append(Entry(templateID: session.templateID, status: session.status, kind: session.kind, note: note,
                                        startMinute: session.startMinute, programID: program.id, programWeek: plan.week))
                }
            }
            if !covered, let weekday = TrainDay.weekday(of: day) {
                result = templates.filter { $0.weekdays.contains(weekday) }
                    .map { Entry(templateID: $0.id, status: .scheduled, kind: .normal, note: nil, startMinute: nil, programID: nil, programWeek: nil) }
            }
            return result
        }

        let week = weekDays(today: today, completed: completed, templatesByID: templatesByID, entries: entries,
                            dailyZone2: input.dailyZone2)
        let summaries = completed.map { sessionSummary($0) }.sorted { ($0.localDay, $0.id.uuidString) > ($1.localDay, $1.id.uuidString) }
        let weekDaysSet = Set(week.map(\.localDay))
        let thisWeek = summaries.filter { weekDaysSet.contains($0.localDay) }
        var byWorkout: [UUID: TrainSessionSummary] = [:]
        for summary in summaries { if let id = summary.workoutID { byWorkout[id] = summary } }

        let templateSummaries = uniqueSlugs(templates.map(\.name))
            .enumerated().map { index, slug in templateSummary(templates[index], slug: slug) }
        let programList = programs.sorted { lhs, rhs in
            let order: [ProgramStatus: Int] = [.active: 0, .paused: 1, .completed: 2]
            let l = order[lhs.status] ?? 3, r = order[rhs.status] ?? 3
            return (l, lhs.name.lowercased(), lhs.id.uuidString) < (r, rhs.name.lowercased(), rhs.id.uuidString)
        }
        let draftList = input.programs.filter { $0.status == .draft }
            .sorted { ($0.name.lowercased(), $0.id.uuidString) < ($1.name.lowercased(), $1.id.uuidString) }
        let programSlugs = uniqueSlugs((programList + draftList).map(\.name))
        let programSummaries = programList.enumerated().map { index, program in
            programSummary(program, slug: programSlugs[index], today: today, scheduler: scheduler)
        }
        let draftSummaries = draftList.enumerated().map { index, draft in
            draftSummary(draft, slug: programSlugs[programList.count + index])
        }

        let todayResult = todayState(input: input, today: today, week: week, templatesByID: templatesByID, entries: entries(on: today),
                                    todaySessions: summaries.filter { $0.localDay == today }, isEmpty: isEmpty)
        let shownTemplateID: UUID? = { if case .plan(let plan) = todayResult { return plan.templateID } else { return nil } }()

        var overview = TrainOverview(
            headerMeta: headerMeta(activePrograms: activePrograms, today: today, scheduler: scheduler),
            isEmpty: isEmpty,
            week: isEmpty ? [] : week,
            showsWeekStrip: !isEmpty && week.contains { $0.templateID != nil || $0.isDone },
            today: todayResult,
            programs: programSummaries,
            drafts: draftSummaries,
            templates: templateSummaries,
            swapChoices: templateSummaries.filter { $0.id != shownTemplateID },
            thisWeek: thisWeek,
            sessionsByWorkoutID: byWorkout)
        overview.calendar = input.calendar
        overview.dailyZone2 = isEmpty ? nil : input.dailyZone2
        overview.todayRecovery = (input.recovery.last { $0.localDay == today }?.score)
            .flatMap { $0.isFinite ? Int($0.rounded(.down)) : nil }
        return overview
    }

    // MARK: Header

    private static func headerMeta(activePrograms: [Program], today: String, scheduler: ProgramScheduler) -> String? {
        for program in activePrograms {
            if let week = scheduler.week(containing: today, in: program) {
                return "Week \(week) of \(program.weekCount) · \(program.name)".looprLabelCased
            }
        }
        return nil
    }

    // MARK: Week strip

    private static let letters = ["M", "T", "W", "T", "F", "S", "S"]
    private static let dayNames = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
    private static let monthNames = ["January", "February", "March", "April", "May", "June", "July",
                                     "August", "September", "October", "November", "December"]
    private static let shortMonths = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    private static let dayCodes = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    private static func parts(_ localDay: String) -> (month: Int, day: Int) {
        let pieces = localDay.split(separator: "-")
        return (Int(pieces[1]) ?? 1, Int(pieces[2]) ?? 1)
    }

    private static func weekDays(today: String, completed: [TrainSession], templatesByID: [UUID: WorkoutTemplate],
                                 entries: (String) -> [Entry], dailyZone2: TrainDailyZone2? = nil) -> [TrainWeekDay] {
        guard let weekday = TrainDay.weekday(of: today), let monday = TrainDay.adding(days: -(weekday.rawValue - 1), to: today) else { return [] }
        let doneDays = Set(completed.map(\.localDay))
        let doneByDay = Dictionary(grouping: completed.sorted { $0.startedAt < $1.startedAt }, by: \.localDay)
        return (0..<7).compactMap { offset -> TrainWeekDay? in
            guard let day = TrainDay.adding(days: offset, to: monday), let dayWeekday = TrainDay.weekday(of: day) else { return nil }
            let dayEntries = entries(day)
            let scheduled = dayEntries.filter { $0.status == .scheduled }
            let isDone = doneDays.contains(day)
            let isToday = day == today
            // The protocol's every-day Zone 2 is a session of its own on every day the program has no Zone 2 (R3-OPT-6).
            let addsZone2 = dailyZone2 != nil && !scheduled.contains { TrainDailyZone2.covers(templatesByID[$0.templateID]) }
            let sessionCount = scheduled.count + (addsZone2 ? 1 : 0)
            let caption: String
            if isDone { caption = "Done" }
            else if sessionCount > 1 { caption = "\(sessionCount) sessions" }
            else if let first = scheduled.first { caption = templatesByID[first.templateID]?.name ?? "Planned" }
            else if addsZone2 { caption = "Zone 2" }
            else if dayEntries.contains(where: { $0.status == .skipped }) { caption = "Skipped" }
            else { caption = "Rest" }
            let (month, number) = parts(day)
            let names = scheduled.compactMap { templatesByID[$0.templateID]?.name } + (addsZone2 ? [dailyZone2?.title ?? "Zone 2"] : [])
            let said = sessionCount > 1 && names.count == sessionCount ? names.joined(separator: " and ") : caption
            var spoken = "\(dayNames[dayWeekday.rawValue - 1]) \(number) \(monthNames[month - 1]), \(isDone ? "done" : said.lowercased() == "rest" ? "rest" : said)"
            if isToday { spoken += ", today" }
            var result = TrainWeekDay(localDay: day, weekday: dayWeekday, letter: letters[dayWeekday.rawValue - 1], numeral: "\(number)",
                                      caption: caption, isDone: isDone, isToday: isToday,
                                      templateID: scheduled.first?.templateID, spokenLabel: spoken)
            result.doneNames = (doneByDay[day] ?? []).map(\.name)
            result.plannedNames = names.count == sessionCount ? names : names + Array(repeating: "Planned", count: sessionCount - names.count)
            result.isSkipped = dayEntries.contains { $0.status == .skipped }
            result.zone2PlannedNames = scheduled.compactMap { entry in
                TrainDailyZone2.covers(templatesByID[entry.templateID]) ? templatesByID[entry.templateID]?.name : nil
            } + (addsZone2 ? [dailyZone2?.title ?? "Zone 2"] : [])
            return result
        }
    }

    // MARK: Today

    private static func todayState(input: TrainOverviewInput, today: String, week: [TrainWeekDay],
                                   templatesByID: [UUID: WorkoutTemplate], entries: [Entry],
                                   todaySessions: [TrainSessionSummary], isEmpty: Bool) -> TrainToday {
        if isEmpty { return .none }
        if let swapped = input.swappedTemplateID.flatMap({ templatesByID[$0] }) {
            return .plan(plan(for: swapped, entry: nil, today: today, input: input, isSwapped: true))
        }
        if let entry = entries.first(where: { $0.status == .scheduled }), let template = templatesByID[entry.templateID] {
            return .plan(plan(for: template, entry: entry, today: today, input: input, isSwapped: false))
        }
        if let done = todaySessions.first { return .done(done) }
        let upcoming = week.drop(while: { $0.localDay <= today }).first(where: { $0.templateID != nil })
        return .rest(next: upcoming.map { "\($0.caption) on \(dayNames[$0.weekday.rawValue - 1])" })
    }

    private static func plan(for template: WorkoutTemplate, entry: Entry?, today: String, input: TrainOverviewInput,
                             isSwapped: Bool) -> TrainTodayPlan {
        let score = input.recovery.last { $0.localDay == today }?.score
        let strain = ExpectedStrain.estimate(templateID: template.id, history: input.strainSamples)
        let startMinute = isSwapped ? nil : entry?.startMinute
        let dailyNote = TrainDailyZone2.covers(template) ? nil
            : input.dailyZone2.map { zone2Note($0, sessionStart: startMinute, sessionName: template.name) }
        var detail = detailLine(for: template)
        if let strain {
            detail += " · expected strain \(strain.formatted(.number.precision(.fractionLength(0...1)).locale(Locale(identifier: "en_US"))))"
            // With Zone 2 on the same day this is one session's share, not the day's strain Today suggests (R3-OPT-6).
            if dailyNote != nil { detail += " for this session" }
        }
        let adjustment = template.kind == .strength ? RecoveryAdjuster.adjust(template: template, score: score) : nil
        var plan = TrainTodayPlan(
            templateID: template.id, name: template.name, kind: template.kind, detail: detail, recoveryScore: score,
            recoveryShown: score.flatMap { $0.isFinite ? Int($0.rounded(.down)) : nil }, recoveryMessage: adjustment?.message,
            scheduleNote: isSwapped ? nil : entry?.note, dailyNote: dailyNote, isLight: !isSwapped && entry?.kind == .light,
            startMinute: startMinute, isSwapped: isSwapped,
            programID: isSwapped ? nil : entry?.programID, programWeek: isSwapped ? nil : entry?.programWeek)
        plan.summary = detailLine(for: template)
        plan.recoveryAdjusts = adjustment?.isAdjusted ?? false
        if !TrainDailyZone2.covers(template), let zone2 = input.dailyZone2 {
            plan.dailyChip = zone2.startMinute.map { "\(zone2.title) at \(TrainClockText.time(minute: $0))" } ?? zone2.title
        }
        return plan
    }

    /// "Your protocol has Zone 2, 45 min at 17:30, before Upper A." The order follows the two start times; a session
    /// with no set time gets no order.
    public static func zone2Note(_ zone2: TrainDailyZone2, sessionStart: Int?, sessionName: String) -> String {
        guard let start = zone2.startMinute else { return "Your protocol also has \(zone2.title) today." }
        let time = TrainClockText.time(minute: start)
        guard let sessionStart else { return "Your protocol also has \(zone2.title) at \(time) today." }
        let order = start + zone2.minutes <= sessionStart ? "before" : start >= sessionStart ? "after" : "overlapping"
        return "Your protocol has \(zone2.title) at \(time), \(order) \(sessionName)."
    }

    private static func detailLine(for template: WorkoutTemplate) -> String {
        switch template.kind {
        case .cardio:
            return cardioLine(template.cardio)
        case .strength:
            let summary = TemplateSummary(template: template)
            guard summary.exerciseCount > 0 else { return "No exercises yet" }
            return "\(plural(summary.exerciseCount, "exercise")) · about \(summary.estimatedMinutes) min"
        }
    }

    private static func cardioLine(_ target: CardioTarget?) -> String {
        guard let target else { return "Cardio" }
        return target.zone.map { "\(target.minutes) min · zone \($0)" } ?? "\(target.minutes) min"
    }

    private static func plural(_ count: Int, _ noun: String) -> String { "\(count) \(noun)\(count == 1 ? "" : "s")" }

    // MARK: Rows

    private static func templateSummary(_ template: WorkoutTemplate, slug: String) -> TrainTemplateSummary {
        let names = template.exercises.map(\.exercise.name)
        let caption: String
        switch template.kind {
        case .cardio: caption = cardioLine(template.cardio)
        case .strength:
            switch names.count {
            case 0: caption = "No exercises yet"
            case 1: caption = names[0]
            case 2: caption = "\(names[0]) and \(names[1])"
            default: caption = "\(names[0]), \(names[1]) and \(names.count - 2) more"
            }
        }
        let spoken: String
        switch template.kind {
        case .cardio: spoken = "\(template.name), \(caption)"
        case .strength: spoken = template.exercises.isEmpty ? "\(template.name), no exercises yet"
            : "\(template.name), \(plural(template.exercises.count, "exercise")), about \(TemplateSummary(template: template).estimatedMinutes) minutes"
        }
        return TrainTemplateSummary(id: template.id, name: template.name, slug: slug, kind: template.kind,
                                    caption: caption, spokenLabel: spoken)
    }

    private static func draftSummary(_ program: Program, slug: String) -> TrainDraftSummary {
        let weeks = program.weekCount
        let daysPerWeek = program.weeks.map(\.count).max() ?? 0
        let layout = "\(weeks) \(weeks == 1 ? "week" : "weeks") · \(daysPerWeek) \(daysPerWeek == 1 ? "day" : "days") a week"
        return TrainDraftSummary(id: program.id, name: program.name, slug: slug, caption: layout,
                                 spokenLabel: "\(program.name), draft, \(layout). \(ProgramScreenModel.draftMessage)",
                                 revision: program.revision)
    }

    private static func programSummary(_ program: Program, slug: String, today: String, scheduler: ProgramScheduler) -> TrainProgramSummary {
        let weeks = program.weekCount
        let daysPerWeek = program.weeks.map(\.count).max() ?? 0
        let layout = "\(weeks) weeks · \(daysPerWeek) \(daysPerWeek == 1 ? "day" : "days") a week"
        func make(caption: String, progress: Double? = nil, value: String? = nil, unit: String? = nil, spoken: String) -> TrainProgramSummary {
            TrainProgramSummary(id: program.id, name: program.name, slug: slug, status: program.status, caption: caption,
                                progress: progress, value: value, valueUnit: unit, spokenLabel: spoken)
        }
        switch program.status {
        case .paused: return make(caption: "Paused", spoken: "\(program.name), paused")
        case .completed: return make(caption: "Completed", spoken: "\(program.name), completed")
        default: break
        }
        if let week = scheduler.week(containing: today, in: program) {
            return make(caption: layout, progress: Double(week) / Double(weeks), value: "\(week)", unit: "of \(weeks)",
                        spoken: "\(program.name), week \(week) of \(weeks), \(layout)")
        }
        if let start = TrainDayMath.ordinal(program.startDay), let now = TrainDayMath.ordinal(today), now < start {
            let (month, day) = parts(program.startDay)
            let when = "starts \(day) \(shortMonths[month - 1])"
            return make(caption: "\(weeks) weeks · \(when)", spoken: "\(program.name), \(weeks) weeks, \(when)")
        }
        return make(caption: "\(weeks) weeks · finished", progress: 1, value: "\(weeks)", unit: "of \(weeks)",
                    spoken: "\(program.name), finished all \(weeks) weeks")
    }

    // MARK: Sessions

    private static func sessionSummary(_ session: TrainSession) -> TrainSessionSummary {
        let minutes = session.endedAt.map { max(0, Int(($0.timeIntervalSince(session.startedAt) / 60).rounded())) }
        let tonnage = Int(session.tonnageKg.rounded())
        let code = TrainDay.weekday(of: session.localDay).map { dayCodes[$0.rawValue - 1] }
        var pieces: [String] = []
        if let code { pieces.append([code, dayAndMonth(session.localDay)].compactMap { $0 }.joined(separator: " ")) }
        if let minutes { pieces.append("\(minutes) min") }
        let sets = session.countedSets.count
        if sets > 0 { pieces.append("\(sets) \(sets == 1 ? "set" : "sets")") }
        if tonnage > 0 { pieces.append("\(grouped(tonnage)) kg") }
        var detailPieces: [String] = []
        if let minutes { detailPieces.append("\(minutes) min") }
        if tonnage > 0 { detailPieces.append("\(grouped(tonnage)) kg") }
        var spoken = session.name
        if let minutes { spoken += ", \(minutes) minutes" }
        if tonnage > 0 { spoken += ", \(grouped(tonnage)) kilograms lifted" }
        var summary = TrainSessionSummary(id: session.id, workoutID: session.workoutID, name: session.name, localDay: session.localDay,
                                          minutes: minutes, tonnageKg: tonnage, caption: pieces.joined(separator: " · "),
                                          detail: detailPieces.joined(separator: " · "), spokenLabel: spoken)
        summary.dayLabel = dayLabel(localDay: session.localDay)
        return summary
    }

    /// "Tue 7 Nov" for `2023-11-07`. Empty for a day it cannot read.
    public static func dayLabel(localDay: String) -> String {
        guard let weekday = TrainDay.weekday(of: localDay) else { return "" }
        let (month, day) = parts(localDay)
        return "\(dayCodes[weekday.rawValue - 1]) \(day) \(shortMonths[month - 1])"
    }

    /// "2023-11-13" becomes "13 Nov", so a row a week old does not read as this Monday.
    static func dayAndMonth(_ localDay: String) -> String? {
        let parts = localDay.split(separator: "-").compactMap { Int($0) }
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        guard parts.count == 3, (1...12).contains(parts[1]) else { return nil }
        return "\(parts[2]) \(months[parts[1] - 1])"
    }

    /// 8420 becomes "8,420".
    static func grouped(_ value: Int) -> String {
        let digits = String(abs(value))
        var result = ""
        for (index, character) in digits.reversed().enumerated() {
            if index > 0, index % 3 == 0 { result.append(",") }
            result.append(character)
        }
        return (value < 0 ? "-" : "") + String(result.reversed())
    }

    // MARK: Identifiers

    /// One slug per name, in order. A second row with the same name gets `-2`.
    private static func uniqueSlugs(_ names: [String]) -> [String] {
        var seen: [String: Int] = [:]
        return names.map { name in
            let base = slug(name)
            seen[base, default: 0] += 1
            let count = seen[base] ?? 1
            return count == 1 ? base : "\(base)-\(count)"
        }
    }

    /// Lowercase letters and digits joined by single hyphens.
    public static func slug(_ name: String) -> String {
        var result = ""
        var pendingHyphen = false
        for scalar in name.lowercased().unicodeScalars {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) {
                if pendingHyphen, !result.isEmpty { result.append("-") }
                pendingHyphen = false
                result.unicodeScalars.append(scalar)
            } else {
                pendingHyphen = true
            }
        }
        return result.isEmpty ? "untitled" : result
    }
}
