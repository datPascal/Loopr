import Foundation

/// One slot as the slot sheet edits it. A copy: Apply hands it back, Cancel drops it.
public struct ProgramSlotDraft: Equatable, Sendable {
    /// Nil means a rest day.
    public var templateID: UUID?
    public var kind: ProgramSlotKind
    /// One to three characters, or empty for "use the workout's initials".
    public var tag: String
    /// Minutes after local midnight, or nil for no set time.
    public var startMinute: Int?

    public init(templateID: UUID? = nil, kind: ProgramSlotKind = .normal, tag: String = "", startMinute: Int? = nil) {
        self.templateID = templateID; self.kind = kind; self.tag = tag; self.startMinute = startMinute
    }

    public static let maxTagLength = 3
}

/// The editable state of the program editor. Pure value logic: no storage, no views.
///
/// The model keeps the program as loaded (`original`) and the program being edited (`draft`).
/// Every change goes through a method, so a week never holds two slots on one weekday and a
/// program always has between 1 and 52 weeks.
public struct ProgramEditorModel: Equatable, Sendable {
    /// Saves a program and returns it as stored, with its new revision.
    public typealias SaveHandler = @Sendable (Program) async throws -> Program

    /// Why the program cannot be saved yet. The messages say what to fix.
    public enum Problem: Error, Equatable, Sendable, LocalizedError {
        case nameMissing
        case noTemplates
        case noSessions
        case invalid

        public var errorDescription: String? { message }

        public var message: String {
            switch self {
            case .nameMissing: "Name this program to save it."
            case .noTemplates: "Save a workout first. A program schedules the workouts you have saved."
            case .noSessions: "Add at least one session to save this program."
            case .invalid: "Check the name, start day and sessions. One of them is out of range."
            }
        }
    }

    public static let maxWeeks = 52
    public static let defaultWeekCount = 4
    public static let untitledName = "New program"

    public private(set) var original: Program
    public private(set) var draft: Program
    /// The workouts a slot can use: saved templates, plus the ones an agent draft carries.
    public let templates: [WorkoutTemplate]
    /// 1-based week the editor shows.
    public var selectedWeek = 1

    public init(program: Program, templates: [WorkoutTemplate]) {
        original = program
        draft = program
        self.templates = templates.sorted { ($0.name.lowercased(), $0.id.uuidString) < ($1.name.lowercased(), $1.id.uuidString) }
    }

    /// A blank program that is active as soon as it is saved. It starts with four empty weeks.
    public static func blank(startDay: String, templates: [WorkoutTemplate], id: UUID = UUID()) -> ProgramEditorModel {
        ProgramEditorModel(
            program: Program(id: id, name: "", source: .manual, status: .active, startDay: startDay,
                             weeks: Array(repeating: [], count: defaultWeekCount), rules: ProgramRules()),
            templates: templates)
    }

    // MARK: State

    public var isNew: Bool { original.revision == 0 }
    public var isDirty: Bool { draft != original }
    public var isDraftProgram: Bool { draft.isDraft }
    public var weekCount: Int { draft.weeks.count }
    public var weeks: [[ProgramSlot]] { draft.weeks }

    public var title: String {
        let trimmed = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Self.untitledName : trimmed
    }

    public var name: String {
        get { draft.name }
        set { draft.name = String(newValue.prefix(80)) }
    }

    public var startDay: String {
        get { draft.startDay }
        set { if TrainDay.isValid(newValue) { draft.startDay = newValue } }
    }

    public var rules: ProgramRules {
        get { draft.rules }
        set { draft.rules = newValue }
    }

    public var summary: String {
        let sessions = draft.weeks.reduce(0) { $0 + $1.count }
        return "\(weekCount) \(weekCount == 1 ? "week" : "weeks"), \(sessions) \(sessions == 1 ? "session" : "sessions")"
    }

    public func template(id: UUID) -> WorkoutTemplate? { templates.first { $0.id == id } }

    // MARK: Slots

    public func slot(week: Int, weekday: TrainWeekday) -> ProgramSlot? {
        guard (1...weekCount).contains(week) else { return nil }
        return draft.weeks[week - 1].first { $0.weekday == weekday }
    }

    /// The slot sheet's starting point. A rest day gives an empty draft.
    public func slotDraft(week: Int, weekday: TrainWeekday) -> ProgramSlotDraft {
        guard let slot = slot(week: week, weekday: weekday) else { return ProgramSlotDraft() }
        return ProgramSlotDraft(templateID: slot.templateID, kind: slot.kind, tag: slot.tag ?? "", startMinute: slot.startMinute)
    }

    /// Writes a slot sheet's result. A nil template clears the day. An unknown template is ignored.
    public mutating func apply(_ slotDraft: ProgramSlotDraft, week: Int, weekday: TrainWeekday) {
        guard (1...weekCount).contains(week) else { return }
        var slots = draft.weeks[week - 1].filter { $0.weekday != weekday }
        if let id = slotDraft.templateID, template(id: id) != nil {
            let tag = String(slotDraft.tag.trimmingCharacters(in: .whitespaces).prefix(ProgramSlotDraft.maxTagLength))
            slots.append(ProgramSlot(weekday: weekday, templateID: id, kind: slotDraft.kind, tag: tag.isEmpty ? nil : tag,
                                     startMinute: slotDraft.startMinute.flatMap { (0..<ProgramSlot.minutesPerDay).contains($0) ? $0 : nil }))
        }
        draft.weeks[week - 1] = slots.sorted { $0.weekday < $1.weekday }
    }

    public mutating func clearSlot(week: Int, weekday: TrainWeekday) {
        apply(ProgramSlotDraft(), week: week, weekday: weekday)
    }

    // MARK: Weeks

    public var canAddWeek: Bool { weekCount < Self.maxWeeks }
    public var canRemoveWeek: Bool { weekCount > 1 }

    /// Adds a week after the last one, with the same sessions as the last week, and selects it.
    public mutating func addWeek() {
        guard canAddWeek else { return }
        draft.weeks.append(draft.weeks.last ?? [])
        selectedWeek = weekCount
    }

    /// Removes a week. Recorded changes for weeks after it move with them and the ones for it are dropped.
    public mutating func removeWeek(_ week: Int) {
        guard canRemoveWeek, (1...weekCount).contains(week) else { return }
        draft.weeks.remove(at: week - 1)
        draft.adjustments = draft.adjustments.compactMap { adjustment in
            guard let number = adjustment.week else { return adjustment }
            if number == week { return nil }
            var shifted = adjustment
            if number > week { shifted.week = number - 1 }
            return shifted
        }
        selectedWeek = min(max(1, selectedWeek > week ? selectedWeek - 1 : selectedWeek), weekCount)
    }

    /// Gives every week the sessions of `week`.
    public mutating func copyWeekToAll(_ week: Int) {
        guard (1...weekCount).contains(week) else { return }
        let source = draft.weeks[week - 1]
        draft.weeks = Array(repeating: source, count: weekCount)
    }

    // MARK: Saving

    /// Why the program cannot be saved, or nil when it can.
    public var problem: Problem? {
        if draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .nameMissing }
        if templates.isEmpty { return .noTemplates }
        if draft.weeks.allSatisfy(\.isEmpty) { return .noSessions }
        return normalized().validationError == nil ? nil : .invalid
    }

    public var canSave: Bool { problem == nil }

    /// The program as it will be stored: trimmed name, slots in weekday order, recorded changes that no longer
    /// point at a week removed, and pending templates only while it is still a draft and a slot uses them.
    public func normalized() -> Program {
        var program = draft
        program.name = program.name.trimmingCharacters(in: .whitespacesAndNewlines)
        program.weeks = program.weeks.map { $0.sorted { $0.weekday < $1.weekday } }
        program.adjustments = program.adjustments.filter { ($0.week ?? 1) <= program.weeks.count }
        if program.isDraft, let pending = program.pendingTemplates {
            let used = program.templateIDs
            let kept = pending.filter { used.contains($0.id) }
            program.pendingTemplates = kept.isEmpty ? nil : kept
        }
        return program
    }

    /// Validates and stores the program. On success the model holds what the store returned.
    public mutating func save(using handler: SaveHandler) async throws {
        if let problem { throw problem }
        let saved = try await handler(normalized())
        original = saved
        draft = saved
    }

    // MARK: Start day

    /// The date a local-day string stands for in `calendar`, at the start of that day.
    public static func date(fromDay day: String, calendar: Calendar) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// The `yyyy-MM-dd` local day of a date in `calendar`.
    public static func day(from date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
    }

    /// "Weeks run Wednesday to Tuesday."
    public var weekRunText: String {
        guard let first = TrainDay.weekday(of: draft.startDay) else { return "" }
        let last = TrainWeekday(rawValue: (first.rawValue + 5) % 7 + 1) ?? .sunday
        return "Weeks run \(first.ruleName) to \(last.ruleName)."
    }
}

private extension Program {
    var validationError: (any Error)? {
        do { try validate(); return nil } catch { return error }
    }
}
