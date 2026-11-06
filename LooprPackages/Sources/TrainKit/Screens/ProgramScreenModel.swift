import DesignSystem
import Foundation

/// Everything the Program screen reads. The app loads these off the main actor and hands them over
/// as plain values, so the model never touches storage, a clock or Calendar.
public struct ProgramScreenInput: Sendable {
    public var program: Program
    /// Saved templates, plus the ones a draft carries.
    public var templates: [WorkoutTemplate]
    /// Finished sessions. The model keeps the ones that belong to this program.
    public var sessions: [TrainSession]
    public var now: Date
    public var calendar: Calendar
    /// True when Calendar access is off and the person has asked for export, or just tried to turn it on.
    public var calendarDenied: Bool

    public init(program: Program, templates: [WorkoutTemplate], sessions: [TrainSession] = [], now: Date, calendar: Calendar,
                calendarDenied: Bool = false) {
        self.program = program; self.templates = templates; self.sessions = sessions
        self.now = now; self.calendar = calendar; self.calendarDenied = calendarDenied
    }
}

/// The Program screen as plain values (mockup 13).
public struct ProgramScreenModel: Equatable, Sendable {
    public struct Rule: Equatable, Sendable {
        public let title: String
        public let subtitle: String?
    }

    public struct SoFar: Equatable, Sendable {
        /// "9 of 10"
        public let sessionsValue: String
        public let sessionsSpoken: String
        /// "Squat, estimated max", or nil when no lift has been logged in this program.
        public let liftTitle: String?
        /// "120 → 125 kg", or "125 kg" when there is only one reading.
        public let liftValue: String?
        public let liftSpoken: String?
    }

    /// One planned day in the grid.
    public struct Day: Equatable, Sendable {
        /// The workout's name, cut to one or two short words so it fits a cell: "Lower A", "Zone 2", "4x4".
        public let name: String
        /// The full name, for VoiceOver.
        public let spokenName: String
        public let type: ProgramSessionType
        /// Heavy or light, for a strength day.
        public let intensity: ProgramSlotKind
        /// The cell for today.
        public let isCurrent: Bool

        /// True for a day the hard-day note counts: a hard type, or a heavy strength day.
        public var isHard: Bool { type == .hard || (type == .strength && intensity == .heavy) }
    }

    /// One row of the grid: seven days, Monday first. Nil is a rest day.
    public struct Week: Equatable, Sendable, Identifiable {
        public let number: Int
        public let days: [Day?]
        public var id: Int { number }
        /// "W3"
        public var label: String { "W\(number)" }
    }

    public let programID: UUID
    public let title: String
    public let isDraft: Bool
    /// The quoted request, shown in the hero. Nil when nobody wrote one.
    public let request: String?
    /// "8 weeks"
    public let weeksTitle: String
    /// "Weeks 4 and 7 are lighter", or "No lighter weeks".
    public let lighterCaption: String
    /// 1-based numbers of weeks whose strength slots are all light.
    public let lightWeeks: [Int]
    /// The weeks with names in the cells, not codes (R2-NEW-13).
    public let grid: [Week]
    /// The session types the grid uses, in `ProgramSessionType` order, for the legend.
    public let types: [ProgramSessionType]
    /// True when some strength day is heavy or light, so the legend names those too.
    public let hasHeavy: Bool
    public let hasLight: Bool
    /// "Thu and Fri are both hard in week 8." Nil when no two hard days touch (R2-VET-12).
    public let hardDayNote: String?
    public let earlyLight: Rule
    public let earlyLightOn: Bool
    public let missed: Rule
    public let missedRule: MissedSessionRule
    public let calendarTitle: String
    public let calendarOn: Bool
    /// True while the program is a draft: the switch cannot be used until the person accepts it.
    public let calendarLocked: Bool
    /// A line under the switch: why it is locked, or the Settings hint. Nil when there is nothing to say.
    public let calendarNote: String?
    public let calendarDenied: Bool
    /// Nil for a draft, which has no history.
    public let soFar: SoFar?
    /// What the rules changed, newest first. At most three.
    public let changes: [String]

    public static let draftMessage = "Draft from Ask. Nothing is scheduled until you accept it."
    public static let calendarDeniedMessage = "Calendar access is off. Turn it on in Settings to add sessions."

    public init(_ input: ProgramScreenInput) {
        let program = input.program
        let templatesByID = Dictionary(input.templates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let scheduler = ProgramScheduler(calendar: input.calendar)
        let today = scheduler.localDay(for: input.now)

        programID = program.id
        title = program.name
        isDraft = program.isDraft
        let trimmed = program.request?.trimmingCharacters(in: .whitespacesAndNewlines)
        request = trimmed?.isEmpty == false ? trimmed : nil
        weeksTitle = "\(program.weekCount) \(program.weekCount == 1 ? "week" : "weeks")"

        let light = Self.lightWeeks(of: program, templates: templatesByID)
        lightWeeks = light
        lighterCaption = Self.lighterCaption(light)

        let currentWeek = program.isDraft ? nil : scheduler.week(containing: today, in: program)
        let todayWeekday = TrainDay.weekday(of: today)
        let weeks = program.weeks.enumerated().map { index, week in
            let slots = Dictionary(week.map { ($0.weekday, $0) }, uniquingKeysWith: { first, _ in first })
            let days = TrainWeekday.allCases.map { weekday -> Day? in
                guard let slot = slots[weekday] else { return nil }
                let template = templatesByID[slot.templateID]
                let type = slot.type(template: template)
                return Day(name: Self.shortName(template?.name ?? "Session"), spokenName: template?.name ?? "Session", type: type,
                           intensity: type == .strength ? slot.kind : .normal,
                           isCurrent: currentWeek == index + 1 && todayWeekday == weekday)
            }
            return Week(number: index + 1, days: days)
        }
        grid = weeks
        let used = Set(weeks.flatMap { $0.days.compactMap { $0?.type } })
        types = ProgramSessionType.allCases.filter(used.contains)
        let strengthDays = weeks.flatMap { $0.days.compactMap { $0 } }.filter { $0.type == .strength }
        hasHeavy = strengthDays.contains { $0.intensity == .heavy }
        hasLight = strengthDays.contains { $0.intensity == .light }
        hardDayNote = Self.hardDayNote(weeks)

        let rules = program.rules
        earlyLightOn = rules.earlyLightWeek
        earlyLight = Rule(title: "Early light week",
                          subtitle: "When \(rules.earlyLightWindowDays)-day recovery averages under \(rules.earlyLightBelowScore)")
        missedRule = rules.missed
        missed = Rule(title: "Missed session", subtitle: Self.missedText(rules.missed))
        calendarTitle = "Add to Calendar"
        calendarLocked = program.isDraft
        calendarDenied = input.calendarDenied && !program.isDraft
        calendarOn = rules.calendarExport && !input.calendarDenied && !program.isDraft
        calendarNote = program.isDraft ? "Available after you accept the plan." : (input.calendarDenied ? Self.calendarDeniedMessage : nil)

        soFar = program.isDraft ? nil : Self.makeSoFar(program: program, sessions: input.sessions, today: today)
        changes = program.adjustments
            .filter { $0.kind == .earlyLightWeek || $0.kind == .movedSession }
            .sorted { ($0.createdAt, $0.id.uuidString) > ($1.createdAt, $1.id.uuidString) }
            .prefix(3).map(\.reason)
    }

    // MARK: Grid and weeks

    /// A week is light when it has at least one strength slot and every strength slot is light.
    /// Cardio slots do not count either way. A slot whose template is missing counts as strength.
    public static func lightWeeks(of program: Program, templates: [UUID: WorkoutTemplate]) -> [Int] {
        program.weeks.enumerated().compactMap { index, week in
            let strength = week.filter { templates[$0.templateID]?.kind != .cardio }
            return !strength.isEmpty && strength.allSatisfy { $0.kind == .light } ? index + 1 : nil
        }
    }

    /// "Week 4 is lighter", "Weeks 4 and 7 are lighter", "Weeks 2, 4 and 7 are lighter".
    public static func lighterCaption(_ weeks: [Int]) -> String {
        switch weeks.count {
        case 0: return "No lighter weeks"
        case 1: return "Week \(weeks[0]) is lighter"
        default:
            let head = weeks.dropLast().map(String.init).joined(separator: ", ")
            return "Weeks \(head) and \(weeks[weeks.count - 1]) are lighter"
        }
    }

    public static func missedText(_ rule: MissedSessionRule) -> String {
        switch rule {
        case .moveBack: "Move the week back, never double up"
        case .skip: "Skip it and carry on"
        }
    }

    /// A name short enough for a grid cell: the whole name up to nine characters ("Lower A", "Long run"), else its
    /// first word ("4x4 intervals" gives "4x4").
    public static func shortName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 9, let first = trimmed.split(separator: " ").first else { return trimmed }
        return String(first.prefix(9))
    }

    /// Plain sentences for hard days that touch, Sunday to the next Monday included: "Tue and Wed are both hard."
    /// when it happens every week, else "Thu and Fri are both hard in weeks 3 and 8." A hard day is a hard session
    /// or a heavy strength day. The note says what the plan holds and sets no rule of its own.
    public static func hardDayNote(_ weeks: [Week]) -> String? {
        var pairs: [(first: TrainWeekday, second: TrainWeekday, weeks: [Int])] = []
        func add(_ first: TrainWeekday, _ second: TrainWeekday, week: Int) {
            if let index = pairs.firstIndex(where: { $0.first == first && $0.second == second }) {
                if pairs[index].weeks.last != week { pairs[index].weeks.append(week) }
            } else {
                pairs.append((first, second, [week]))
            }
        }
        let days = TrainWeekday.allCases
        for (index, week) in weeks.enumerated() {
            for offset in 0..<(days.count - 1) where week.days[offset]?.isHard == true && week.days[offset + 1]?.isHard == true {
                add(days[offset], days[offset + 1], week: week.number)
            }
            if index + 1 < weeks.count, week.days[6]?.isHard == true, weeks[index + 1].days[0]?.isHard == true {
                add(.sunday, .monday, week: week.number)
            }
        }
        guard !pairs.isEmpty else { return nil }
        return pairs.map { pair in
            let days = "\(pair.first.shortName) and \(pair.second.shortName) are both hard"
            if pair.weeks.count == weeks.count { return days + "." }
            return days + " in " + weekList(pair.weeks) + "."
        }.joined(separator: " ")
    }

    /// "week 8", "weeks 3 and 8", "weeks 2, 3 and 8".
    static func weekList(_ numbers: [Int]) -> String {
        guard numbers.count > 1 else { return "week \(numbers.first ?? 0)" }
        return "weeks " + numbers.dropLast().map(String.init).joined(separator: ", ") + " and \(numbers[numbers.count - 1])"
    }

    /// The slot's tag, else up to two letters from the template name: "Upper A" gives "UA", "Zone" gives "ZO".
    public static func code(for slot: ProgramSlot, template: WorkoutTemplate?) -> String {
        if let tag = slot.tag, !tag.isEmpty { return tag }
        guard let name = template?.name else { return "?" }
        let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let letters: String
        if words.count >= 2 {
            letters = words.prefix(2).compactMap(\.first).map(String.init).joined()
        } else {
            letters = String(words.first?.prefix(2) ?? "")
        }
        return letters.isEmpty ? "?" : letters.uppercased()
    }

    // MARK: So far

    private static func makeSoFar(program: Program, sessions: [TrainSession], today: String) -> SoFar {
        let mine = sessions.filter { $0.programID == program.id && $0.status == .completed }
            .sorted { ($0.startedAt, $0.id.uuidString) < ($1.startedAt, $1.id.uuidString) }
        let due = dueSessions(program: program, today: today)
        let done = mine.count
        let value = "\(done) of \(max(due, done))"
        let lift = headlineLift(in: mine)
        return SoFar(
            sessionsValue: value, sessionsSpoken: "Sessions done, \(done) of \(max(due, done))",
            liftTitle: lift.map { "\($0.name), estimated max" },
            liftValue: lift.map { $0.valueText }, liftSpoken: lift.map { "\($0.name), estimated max, \($0.spokenText)" })
    }

    /// Planned sessions on or before `today`, counting the ones that moved or were skipped.
    public static func dueSessions(program: Program, today: String) -> Int {
        guard let start = TrainDayMath.ordinal(program.startDay), let now = TrainDayMath.ordinal(today) else { return 0 }
        let startWeekday = TrainDayMath.weekday(ordinal: start)
        var count = 0
        for (index, week) in program.weeks.enumerated() {
            for slot in week {
                let offset = ((slot.weekday.rawValue - startWeekday.rawValue) % 7 + 7) % 7
                if start + 7 * index + offset <= now { count += 1 }
            }
        }
        return count
    }

    struct Lift: Equatable {
        let name: String
        let first: Double
        let best: Double

        var changed: Bool { Int(first.rounded()) != Int(best.rounded()) }
        var valueText: String { changed ? "\(Int(first.rounded())) → \(Int(best.rounded())) kg" : "\(Int(best.rounded())) kg" }
        var spokenText: String {
            changed ? "\(Int(first.rounded())) to \(Int(best.rounded())) kilograms" : "\(Int(best.rounded())) kilograms"
        }
    }

    /// The lift whose estimated one-rep max rose the most between the first session that held it and the best one,
    /// from `PersonalBestEvaluator`. Without any rise, the first lift of the earliest session with a load. Nil without loads.
    static func headlineLift(in sessions: [TrainSession]) -> Lift? {
        var order: [String] = []
        var names: [String: String] = [:]
        var firstValue: [String: Double] = [:]
        for session in sessions {
            for line in session.exercises where line.status != .skipped {
                let key = line.exercise.key
                guard let value = PersonalBestEvaluator.bestValues(exerciseKey: key, in: [session])?[.estimatedOneRepMax] else { continue }
                if names[key] == nil { order.append(key); firstValue[key] = value }
                names[key] = line.exercise.name
            }
        }
        let lifts = order.compactMap { key -> Lift? in
            guard let name = names[key], let first = firstValue[key],
                  let best = PersonalBestEvaluator.bestValues(exerciseKey: key, in: sessions)?[.estimatedOneRepMax] else { return nil }
            return Lift(name: name, first: first, best: best)
        }
        if let risen = lifts.filter({ $0.best - $0.first > 1e-9 }).max(by: { ($0.best - $0.first, $1.name) < ($1.best - $1.first, $0.name) }) {
            return risen
        }
        return lifts.first
    }
}

extension TrainWeekday {
    /// "Mon", "Tue": the first three letters of the English day name.
    var shortName: String { String(ruleName.prefix(3)) }
}
