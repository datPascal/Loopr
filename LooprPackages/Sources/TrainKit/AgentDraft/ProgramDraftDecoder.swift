import Foundation
import WorkoutKit

// MARK: Schema

/// The JSON an agent writes to propose a program. It is a request, not a record: the decoder checks it
/// against the saved templates and the exercise library and returns a `Program` with status `.draft`.
///
/// ```json
/// {
///   "schemaVersion": 1,
///   "name": "Spring base",
///   "request": "Three runs and two lifts a week for 4 weeks",
///   "startDay": "2023-11-20",
///   "weeks": [
///     [
///       { "weekday": "monday", "template": "Lower A", "kind": "normal", "tag": "LA", "startTime": "18:00" },
///       { "weekday": "thursday", "template": "Easy ride" }
///     ]
///   ],
///   "newTemplates": [
///     { "name": "Easy ride", "kind": "cardio", "cardio": { "activity": "cycle", "minutes": 40, "zone": 2 } }
///   ],
///   "rules": { "earlyLightWeek": true, "missed": "moveBack" }
/// }
/// ```
///
/// Rules of the schema:
/// - Every key is listed above or in the types below. An unknown key is an error, so a typo never passes silently.
/// - A slot names its template. The name must match exactly one saved template or one entry of `newTemplates`,
///   ignoring case and extra spaces.
/// - A week holds 1 to 7 slots, one per weekday. A program has 1 to 52 weeks.
/// - `kind` is `normal`, `heavy` or `light`, and defaults to `normal`.
/// - A strength template in `newTemplates` lists exercises by library name. An exercise the library does not have is an error.
/// - There is no key for Calendar export. A draft never turns it on.
public struct ProgramDraft: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var schemaVersion: Int
    public var name: String
    public var request: String?
    /// `yyyy-MM-dd`. Without it the decoder uses the start day it was given.
    public var startDay: String?
    public var weeks: [[Slot]]
    public var newTemplates: [NewTemplate]?
    public var rules: Rules?

    public init(schemaVersion: Int = ProgramDraft.currentVersion, name: String, request: String? = nil, startDay: String? = nil,
                weeks: [[Slot]], newTemplates: [NewTemplate]? = nil, rules: Rules? = nil) {
        self.schemaVersion = schemaVersion; self.name = name; self.request = request; self.startDay = startDay
        self.weeks = weeks; self.newTemplates = newTemplates; self.rules = rules
    }

    public struct Slot: Codable, Equatable, Sendable {
        /// `monday` to `sunday`, or the three-letter form `mon` to `sun`.
        public var weekday: String
        /// The template's name.
        public var template: String
        /// `normal`, `heavy` or `light`. Nil means normal.
        public var kind: String?
        /// A grid label of one to three characters.
        public var tag: String?
        /// `HH:mm`, 24-hour, local time.
        public var startTime: String?

        public init(weekday: String, template: String, kind: String? = nil, tag: String? = nil, startTime: String? = nil) {
            self.weekday = weekday; self.template = template; self.kind = kind; self.tag = tag; self.startTime = startTime
        }
    }

    public struct NewTemplate: Codable, Equatable, Sendable {
        public var name: String
        /// `strength` or `cardio`.
        public var kind: String
        public var exercises: [Exercise]?
        public var cardio: Cardio?

        public init(name: String, kind: String, exercises: [Exercise]? = nil, cardio: Cardio? = nil) {
            self.name = name; self.kind = kind; self.exercises = exercises; self.cardio = cardio
        }
    }

    public struct Exercise: Codable, Equatable, Sendable {
        /// A name from the exercise library.
        public var exercise: String
        public var sets: Int
        public var repsMin: Int
        public var repsMax: Int?
        public var loadKg: Double?
        public var restSeconds: Int?

        public init(exercise: String, sets: Int, repsMin: Int, repsMax: Int? = nil, loadKg: Double? = nil, restSeconds: Int? = nil) {
            self.exercise = exercise; self.sets = sets; self.repsMin = repsMin; self.repsMax = repsMax
            self.loadKg = loadKg; self.restSeconds = restSeconds
        }
    }

    public struct Cardio: Codable, Equatable, Sendable {
        /// An `ActivityType` raw value such as `run`, `cycle` or `walk`.
        public var activity: String
        public var minutes: Int
        public var zone: Int?

        public init(activity: String, minutes: Int, zone: Int? = nil) {
            self.activity = activity; self.minutes = minutes; self.zone = zone
        }
    }

    public struct Rules: Codable, Equatable, Sendable {
        public var earlyLightWeek: Bool?
        /// `moveBack` or `skip`.
        public var missed: String?

        public init(earlyLightWeek: Bool? = nil, missed: String? = nil) {
            self.earlyLightWeek = earlyLightWeek; self.missed = missed
        }
    }
}

// MARK: Errors

/// Why a draft was refused. The messages are plain sentences. FT-05 returns them to the agent so it can fix the draft.
public enum ProgramDraftError: Error, Equatable, Sendable, LocalizedError {
    case malformed(String)
    case unsupportedVersion(Int)
    case unknownField(String)
    case nameMissing
    case nameTooLong
    case requestTooLong
    case badStartDay(String)
    case noWeeks
    case tooManyWeeks(Int)
    case emptyWeek(Int)
    case tooManySlots(week: Int, count: Int)
    case duplicateWeekday(week: Int, weekday: String)
    case badWeekday(String)
    case badKind(String)
    case badTag(String)
    case badStartTime(String)
    case unknownTemplate(String)
    case ambiguousTemplate(String)
    case duplicateNewTemplate(String)
    case templateNameTaken(String)
    case templateNeedsExercises(String)
    case templateNeedsCardioTarget(String)
    case unknownExercise(String)
    case badTemplateKind(String)
    case badActivity(String)
    case invalidTemplate(String)
    case unusedTemplate(String)
    case tooManyNewTemplates(Int)
    case badRule(String)
    case invalid

    public var errorDescription: String? { message }

    public var message: String {
        switch self {
        case .malformed(let detail): "The draft is not valid JSON for a program. \(detail)"
        case .unsupportedVersion(let version): "Draft schema version \(version) is not supported. Use version \(ProgramDraft.currentVersion)."
        case .unknownField(let path): "The draft has a field that is not in the schema: \(path)."
        case .nameMissing: "Give the program a name."
        case .nameTooLong: "The program name is longer than 80 characters."
        case .requestTooLong: "The request text is longer than 2,000 characters."
        case .badStartDay(let day): "The start day \"\(day)\" is not a date written as yyyy-MM-dd."
        case .noWeeks: "The draft has no weeks. Add 1 to 52."
        case .tooManyWeeks(let count): "The draft has \(count) weeks. A program holds up to 52."
        case .emptyWeek(let week): "Week \(week) has no sessions. Every week needs 1 to 7."
        case .tooManySlots(let week, let count): "Week \(week) has \(count) sessions. A week holds up to 7, one per day."
        case .duplicateWeekday(let week, let weekday): "Week \(week) has two sessions on \(weekday). Use one session per day."
        case .badWeekday(let value): "\"\(value)\" is not a weekday. Use monday to sunday."
        case .badKind(let value): "\"\(value)\" is not a session kind. Use normal, heavy or light."
        case .badTag(let value): "The tag \"\(value)\" must be 1 to 3 characters."
        case .badStartTime(let value): "The start time \"\(value)\" is not written as HH:mm, for example 18:00."
        case .unknownTemplate(let name): "There is no template named \"\(name)\". Use a saved template or add it to newTemplates."
        case .ambiguousTemplate(let name): "More than one saved template is named \"\(name)\"."
        case .duplicateNewTemplate(let name): "newTemplates lists \"\(name)\" more than once."
        case .templateNameTaken(let name): "A saved template is already named \"\(name)\". Use it by name instead of adding it again."
        case .templateNeedsExercises(let name): "The strength template \"\(name)\" needs at least one exercise."
        case .templateNeedsCardioTarget(let name): "The cardio template \"\(name)\" needs a cardio target with an activity and minutes."
        case .unknownExercise(let name): "The exercise library has no exercise named \"\(name)\"."
        case .badTemplateKind(let value): "\"\(value)\" is not a template kind. Use strength or cardio."
        case .badActivity(let value): "\"\(value)\" is not an activity. Use run, cycle, walk, hike, swim, cardio, yoga, hiit or other."
        case .invalidTemplate(let name): "The template \"\(name)\" has sets, reps, load, rest or minutes outside the allowed range."
        case .unusedTemplate(let name): "The new template \"\(name)\" is not used by any week."
        case .tooManyNewTemplates(let count): "The draft adds \(count) templates. The limit is \(Program.maxPendingTemplates)."
        case .badRule(let value): "\"\(value)\" is not a missed-session rule. Use moveBack or skip."
        case .invalid: "The draft is outside the limits a program can hold."
        }
    }
}

// MARK: Decoder

/// Turns an agent's draft into a `Program` the person can review.
///
/// The result always has `status == .draft` and `source == .agent`, a fresh id and revision 0. A draft is inert:
/// the scheduler ignores it, the week strip never lists it and Calendar export skips it until the person
/// accepts it (`TrainStore.acceptProgramDraft`). New templates it asks for ride along in `pendingTemplates`
/// and are saved only on accept.
///
/// ```swift
/// let decoder = ProgramDraftDecoder(templates: saved, library: library, defaultStartDay: "2023-11-20")
/// let draft = try decoder.decode(json)          // throws ProgramDraftError
/// _ = try store.saveProgram(draft, at: now)     // revision 0 saves a new record
/// ```
public struct ProgramDraftDecoder: Sendable {
    public let templates: [WorkoutTemplate]
    public let library: ExerciseLibrary?
    public let defaultStartDay: String
    private let makeID: @Sendable () -> UUID

    /// - Parameters:
    ///   - templates: The saved templates a slot can name.
    ///   - library: Resolves exercise names in new strength templates. Nil rejects every exercise name.
    ///   - defaultStartDay: Week 1 starts here when the draft has no `startDay`.
    ///   - makeID: Ids for the program and its new templates. Tests pass a counter.
    public init(templates: [WorkoutTemplate], library: ExerciseLibrary? = nil, defaultStartDay: String,
                makeID: @escaping @Sendable () -> UUID = { UUID() }) {
        self.templates = templates; self.library = library; self.defaultStartDay = defaultStartDay; self.makeID = makeID
    }

    public func decode(_ text: String) throws -> Program { try decode(Data(text.utf8)) }

    public func decode(_ data: Data) throws -> Program {
        try Self.checkKeys(in: data)
        let draft: ProgramDraft
        do { draft = try JSONDecoder().decode(ProgramDraft.self, from: data) } catch {
            throw ProgramDraftError.malformed(Self.describe(error))
        }
        return try program(from: draft)
    }

    public func program(from draft: ProgramDraft) throws -> Program {
        guard draft.schemaVersion == ProgramDraft.currentVersion else { throw ProgramDraftError.unsupportedVersion(draft.schemaVersion) }
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ProgramDraftError.nameMissing }
        guard name.count <= 80 else { throw ProgramDraftError.nameTooLong }
        let request = draft.request?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let request, request.count > 2_000 { throw ProgramDraftError.requestTooLong }
        let startDay = draft.startDay ?? defaultStartDay
        guard TrainDay.isValid(startDay) else { throw ProgramDraftError.badStartDay(startDay) }
        guard !draft.weeks.isEmpty else { throw ProgramDraftError.noWeeks }
        guard draft.weeks.count <= 52 else { throw ProgramDraftError.tooManyWeeks(draft.weeks.count) }

        let created = try newTemplates(draft.newTemplates ?? [])
        var resolver: [String: [UUID]] = [:]
        for template in templates { resolver[Self.fold(template.name), default: []].append(template.id) }
        for template in created { resolver[Self.fold(template.name), default: []].append(template.id) }

        var used = Set<UUID>()
        var weeks: [[ProgramSlot]] = []
        for (index, week) in draft.weeks.enumerated() {
            let number = index + 1
            guard !week.isEmpty else { throw ProgramDraftError.emptyWeek(number) }
            guard week.count <= 7 else { throw ProgramDraftError.tooManySlots(week: number, count: week.count) }
            var days = Set<TrainWeekday>()
            var slots: [ProgramSlot] = []
            for slot in week {
                let weekday = try Self.weekday(slot.weekday)
                guard days.insert(weekday).inserted else { throw ProgramDraftError.duplicateWeekday(week: number, weekday: slot.weekday) }
                guard let ids = resolver[Self.fold(slot.template)], !ids.isEmpty else { throw ProgramDraftError.unknownTemplate(slot.template) }
                guard ids.count == 1, let id = ids.first else { throw ProgramDraftError.ambiguousTemplate(slot.template) }
                used.insert(id)
                slots.append(ProgramSlot(weekday: weekday, templateID: id, kind: try Self.kind(slot.kind), tag: try Self.tag(slot.tag),
                                         startMinute: try Self.startMinute(slot.startTime)))
            }
            weeks.append(slots.sorted { $0.weekday < $1.weekday })
        }
        for template in created where !used.contains(template.id) { throw ProgramDraftError.unusedTemplate(template.name) }

        var rules = ProgramRules(calendarExport: false)
        if let earlyLight = draft.rules?.earlyLightWeek { rules.earlyLightWeek = earlyLight }
        if let missed = draft.rules?.missed {
            guard let rule = MissedSessionRule(rawValue: missed) else { throw ProgramDraftError.badRule(missed) }
            rules.missed = rule
        }

        let program = Program(id: makeID(), name: name, request: request?.isEmpty == true ? nil : request, source: .agent,
                              status: .draft, startDay: startDay, weeks: weeks, rules: rules,
                              pendingTemplates: created.isEmpty ? nil : created)
        do { try program.validate() } catch { throw ProgramDraftError.invalid }
        return program
    }

    // MARK: New templates

    private func newTemplates(_ specs: [ProgramDraft.NewTemplate]) throws -> [WorkoutTemplate] {
        guard specs.count <= Program.maxPendingTemplates else { throw ProgramDraftError.tooManyNewTemplates(specs.count) }
        let saved = Set(templates.map { Self.fold($0.name) })
        var seen = Set<String>()
        var result: [WorkoutTemplate] = []
        for spec in specs {
            let name = spec.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.count <= 80 else { throw ProgramDraftError.invalidTemplate(spec.name) }
            let key = Self.fold(name)
            guard !saved.contains(key) else { throw ProgramDraftError.templateNameTaken(name) }
            guard seen.insert(key).inserted else { throw ProgramDraftError.duplicateNewTemplate(name) }
            var template: WorkoutTemplate
            switch spec.kind {
            case "strength":
                guard let exercises = spec.exercises, !exercises.isEmpty else { throw ProgramDraftError.templateNeedsExercises(name) }
                let lines = try exercises.map(line)
                template = WorkoutTemplate(id: makeID(), name: name, exercises: lines, source: .agent)
            case "cardio":
                guard let cardio = spec.cardio else { throw ProgramDraftError.templateNeedsCardioTarget(name) }
                guard let activity = ActivityType(rawValue: cardio.activity) else { throw ProgramDraftError.badActivity(cardio.activity) }
                template = WorkoutTemplate(id: makeID(), name: name, kind: .cardio,
                                           cardio: CardioTarget(activity: activity, minutes: cardio.minutes, zone: cardio.zone), source: .agent)
            default:
                throw ProgramDraftError.badTemplateKind(spec.kind)
            }
            template.bandRestCue = true
            do { try template.validate() } catch { throw ProgramDraftError.invalidTemplate(name) }
            result.append(template)
        }
        return result
    }

    private func line(_ spec: ProgramDraft.Exercise) throws -> TemplateExercise {
        guard let library, let match = library.all.filter({ Self.fold($0.name) == Self.fold(spec.exercise) }).first else {
            throw ProgramDraftError.unknownExercise(spec.exercise)
        }
        return TemplateExercise(id: makeID(), exercise: match.reference, sets: spec.sets, repsMin: spec.repsMin,
                                repsMax: spec.repsMax ?? spec.repsMin, loadKg: spec.loadKg, restSeconds: spec.restSeconds ?? 90)
    }

    // MARK: Fields

    private static func weekday(_ value: String) throws -> TrainWeekday {
        switch value.lowercased() {
        case "monday", "mon": .monday
        case "tuesday", "tue": .tuesday
        case "wednesday", "wed": .wednesday
        case "thursday", "thu": .thursday
        case "friday", "fri": .friday
        case "saturday", "sat": .saturday
        case "sunday", "sun": .sunday
        default: throw ProgramDraftError.badWeekday(value)
        }
    }

    private static func kind(_ value: String?) throws -> ProgramSlotKind {
        guard let value else { return .normal }
        guard let kind = ProgramSlotKind(rawValue: value) else { throw ProgramDraftError.badKind(value) }
        return kind
    }

    private static func tag(_ value: String?) throws -> String? {
        guard let value else { return nil }
        guard (1...3).contains(value.count) else { throw ProgramDraftError.badTag(value) }
        return value
    }

    private static func startMinute(_ value: String?) throws -> Int? {
        guard let value else { return nil }
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 2, parts[1].count == 2,
              parts.allSatisfy({ $0.allSatisfy(\.isASCII) }),
              let hour = Int(parts[0]), let minute = Int(parts[1]), (0..<24).contains(hour), (0..<60).contains(minute)
        else { throw ProgramDraftError.badStartTime(value) }
        return hour * 60 + minute
    }

    /// Case and spacing do not tell two names apart.
    static func fold(_ name: String) -> String {
        name.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    // MARK: Strict keys

    private static let topKeys: Set<String> = ["schemaVersion", "name", "request", "startDay", "weeks", "newTemplates", "rules"]
    private static let slotKeys: Set<String> = ["weekday", "template", "kind", "tag", "startTime"]
    private static let templateKeys: Set<String> = ["name", "kind", "exercises", "cardio"]
    private static let exerciseKeys: Set<String> = ["exercise", "sets", "repsMin", "repsMax", "loadKg", "restSeconds"]
    private static let cardioKeys: Set<String> = ["activity", "minutes", "zone"]
    private static let ruleKeys: Set<String> = ["earlyLightWeek", "missed"]

    /// Rejects any key the schema does not name. Type errors are left to the decoder.
    private static func checkKeys(in data: Data) throws {
        let root: Any
        do { root = try JSONSerialization.jsonObject(with: data) } catch { throw ProgramDraftError.malformed("The text is not JSON.") }
        guard let top = root as? [String: Any] else { throw ProgramDraftError.malformed("The top level must be an object.") }
        func check(_ object: Any?, allowed: Set<String>, path: String) throws {
            guard let object = object as? [String: Any] else { return }
            for key in object.keys.sorted() where !allowed.contains(key) { throw ProgramDraftError.unknownField("\(path)\(key)") }
        }
        try check(top, allowed: topKeys, path: "")
        if let weeks = top["weeks"] as? [Any] {
            for (weekIndex, week) in weeks.enumerated() {
                for (slotIndex, slot) in ((week as? [Any]) ?? []).enumerated() {
                    try check(slot, allowed: slotKeys, path: "weeks[\(weekIndex)][\(slotIndex)].")
                }
            }
        }
        if let templates = top["newTemplates"] as? [Any] {
            for (index, template) in templates.enumerated() {
                try check(template, allowed: templateKeys, path: "newTemplates[\(index)].")
                guard let template = template as? [String: Any] else { continue }
                try check(template["cardio"], allowed: cardioKeys, path: "newTemplates[\(index)].cardio.")
                for (exerciseIndex, exercise) in ((template["exercises"] as? [Any]) ?? []).enumerated() {
                    try check(exercise, allowed: exerciseKeys, path: "newTemplates[\(index)].exercises[\(exerciseIndex)].")
                }
            }
        }
        try check(top["rules"], allowed: ruleKeys, path: "rules.")
    }

    private static func describe(_ error: any Error) -> String {
        guard let error = error as? DecodingError else { return "" }
        func path(_ context: DecodingError.Context) -> String {
            context.codingPath.map { $0.intValue.map { "[\($0)]" } ?? ".\($0.stringValue)" }.joined().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        }
        switch error {
        case .keyNotFound(let key, let context):
            return "Missing \"\(key.stringValue)\"" + (context.codingPath.isEmpty ? "." : " at \(path(context)).")
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            return "Wrong type at \(path(context))."
        case .dataCorrupted(let context):
            return "Unreadable value at \(path(context))."
        @unknown default:
            return ""
        }
    }
}
