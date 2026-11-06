import AIKit
import DesignSystem
import FoodKit
import Foundation
import JournalKit
import NotificationKit
import StorageKit
import TrainKit
#if canImport(UserNotifications)
import UserNotifications
#endif

/// A failure the person can read. Anything else becomes a generic sentence, never a type name.
nonisolated struct AgentApplyError: Error, LocalizedError, Equatable, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
    static let generic = AgentApplyError("Loopr could not save this. Nothing was changed.")
    static func friendly(_ error: Error) -> AgentApplyError {
        if let error = error as? AgentApplyError { return error }
        if let error = error as? ProgramDraftError { return .init(error.message) }
        if let error = error as? LocalizedError, let text = error.errorDescription, !text.isEmpty,
           !(error is DecodingError) { return .init(text) }
        return .generic
    }
}

/// Words the person sees on the confirmation card.
nonisolated enum AgentProposalCopy {
    static let dismissedText = "Nothing was saved."
    static let estimatedLine = "Estimated by Ask. You can edit it in Food."
    static let draftLine = "It stays a draft until you accept it in Fitness."
    /// Shown on a failed reminder card, with a button to iOS Settings.
    static let notificationsOffText = "Notifications are off for Loopr. Turn them on in iOS Settings, then tap Try again."
    static let reminderLimitText = "Loopr holds at most \(NotificationFamily.userReminderLimit) reminders at a time, and \(NotificationFamily.userReminderLimit) are waiting. Cancel one in Settings > Notifications, then try again."
    static let reminderFamilyOffText = "Reminders you set are turned off. Turn them on in Settings > Notifications, then try again."
    static let quietHoursLine = "This falls in your quiet hours. It still arrives at the time you chose."
    static let reminderNotificationsOffLine = "Notifications are off for Loopr. Turn them on in iOS Settings before you confirm."
    static let testNotificationsOffLine = "Notifications are off for Loopr, so the test would run without a reminder."
}

// MARK: Seams

/// Everything a confirmed proposal writes to. The production type wraps the app's stores. Tests supply their own.
nonisolated protocol AgentWriteStore: Sendable {
    func mealExists(id: UUID) async throws -> Bool
    func confirmMeal(_ draft: FoodMealDraft, at date: Date) async throws
    func habitDefinitions() async throws -> [HabitDefinition]
    func saveHabitDefinition(_ definition: HabitDefinition) async throws
    func template(id: UUID) async throws -> WorkoutTemplate?
    func saveTemplate(_ template: WorkoutTemplate, at date: Date) async throws
    /// Decodes without saving. Throws `ProgramDraftError` with a sentence the model can act on.
    func checkProgramDraft(json: String, defaultStartDay: String) async throws
    /// Saves the draft with ids derived from `proposalID`, so a repeat does not create a second draft.
    func saveProgramDraft(json: String, defaultStartDay: String, proposalID: UUID, at date: Date) async throws
}

nonisolated protocol AgentReminderScheduling: Sendable {
    /// Asks for notification permission when needed, then schedules. Throws `AgentApplyError` when denied, when ten
    /// reminders already wait or when "Reminders you set" is off.
    func schedule(id: UUID, title: String, body: String, minuteOfDay: Int, repeatsDaily: Bool) async throws
    /// Whether that time of day falls inside the person's quiet hours. The reminder arrives anyway, and the card says so.
    func isInQuietHours(minuteOfDay: Int) async -> Bool
    /// Whether iOS notifications are refused for Loopr now.
    func notificationsAreRefused() async -> Bool
}

extension AgentReminderScheduling {
    func isInQuietHours(minuteOfDay: Int) async -> Bool { false }
    func notificationsAreRefused() async -> Bool { false }
}

/// W6 provides this. It starts a 14-day pattern test from a confirmed `propose_test`.
nonisolated protocol AgentTestStarting: Sendable {
    /// The pattern's title when this candidate and metric can be tested now, or nil when they cannot.
    func title(candidateID: String, metric: String?) async -> String?
    func start(candidateID: String, metric: String?, reminderMinuteOfDay: Int?, at date: Date) async throws
}

nonisolated enum AgentIDs {
    /// A stable id for the nth thing made from one proposal, so applying twice makes it once.
    static func derived(from id: UUID, index: UInt8 = 0) -> UUID {
        var bytes = id.uuid
        bytes.15 = bytes.15 &+ 1 &+ index
        bytes.14 = bytes.14 ^ 0xA5
        return UUID(uuid: bytes)
    }
}

// MARK: Template edits

/// The changes `propose_template_edit` may ask for. Unknown keys are refused.
nonisolated struct AgentTemplateEdit: Equatable, Sendable {
    struct ExerciseChange: Equatable, Sendable {
        var index: Int
        var sets: Int?
        var repsMin: Int?
        var repsMax: Int?
        var loadKg: Double?
        var restSeconds: Int?
    }
    var name: String?
    var exercises: [ExerciseChange] = []
    var cardioMinutes: Int?
    var cardioZone: Int?

    var isEmpty: Bool { name == nil && exercises.isEmpty && cardioMinutes == nil && cardioZone == nil }

    init(name: String? = nil, exercises: [ExerciseChange] = [], cardioMinutes: Int? = nil, cardioZone: Int? = nil) {
        self.name = name; self.exercises = exercises; self.cardioMinutes = cardioMinutes; self.cardioZone = cardioZone
    }

    init(object: Any) throws {
        guard let root = object as? [String: Any], Set(root.keys).isSubset(of: ["name", "exercises", "cardio"]) else {
            throw AgentToolFailure("changes may only have name, exercises and cardio.")
        }
        if let name = root["name"] {
            guard let text = name as? String else { throw AgentToolFailure("name must be text.") }
            self.name = text
        }
        if let list = root["exercises"] {
            guard let rows = list as? [[String: Any]] else { throw AgentToolFailure("exercises must be a list of objects.") }
            for row in rows {
                guard Set(row.keys).isSubset(of: ["index", "sets", "repsMin", "repsMax", "loadKg", "restSeconds"]),
                      let index = Self.integer(row["index"]) else { throw AgentToolFailure("Each exercise change needs an index and only sets, repsMin, repsMax, loadKg or restSeconds.") }
                var change = ExerciseChange(index: index)
                for key in ["sets", "repsMin", "repsMax", "restSeconds"] where row[key] != nil {
                    guard let value = Self.integer(row[key]) else { throw AgentToolFailure("\(key) must be a whole number.") }
                    switch key {
                    case "sets": change.sets = value
                    case "repsMin": change.repsMin = value
                    case "repsMax": change.repsMax = value
                    default: change.restSeconds = value
                    }
                }
                if row["loadKg"] != nil {
                    guard let load = (row["loadKg"] as? NSNumber)?.doubleValue, load.isFinite else { throw AgentToolFailure("loadKg must be a number.") }
                    change.loadKg = load
                }
                exercises.append(change)
            }
        }
        if let cardio = root["cardio"] {
            guard let row = cardio as? [String: Any], Set(row.keys).isSubset(of: ["minutes", "zone"]) else {
                throw AgentToolFailure("cardio may only have minutes and zone.")
            }
            if row["minutes"] != nil { guard let v = Self.integer(row["minutes"]) else { throw AgentToolFailure("minutes must be a whole number.") }; cardioMinutes = v }
            if row["zone"] != nil { guard let v = Self.integer(row["zone"]) else { throw AgentToolFailure("zone must be a whole number.") }; cardioZone = v }
        }
        guard !isEmpty else { throw AgentToolFailure("changes is empty. Say what to change.") }
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.rounded() == number.doubleValue, abs(number.doubleValue) < 1_000_000 else { return nil }
        return number.intValue
    }

    func json() throws -> String {
        var root: [String: Any] = [:]
        if let name { root["name"] = name }
        if !exercises.isEmpty {
            root["exercises"] = exercises.map { change -> [String: Any] in
                var row: [String: Any] = ["index": change.index]
                if let v = change.sets { row["sets"] = v }
                if let v = change.repsMin { row["repsMin"] = v }
                if let v = change.repsMax { row["repsMax"] = v }
                if let v = change.loadKg { row["loadKg"] = v }
                if let v = change.restSeconds { row["restSeconds"] = v }
                return row
            }
        }
        if cardioMinutes != nil || cardioZone != nil {
            var row: [String: Any] = [:]
            if let v = cardioMinutes { row["minutes"] = v }
            if let v = cardioZone { row["zone"] = v }
            root["cardio"] = row
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]), as: UTF8.self)
    }

    init(json: String) throws {
        try self.init(object: try JSONSerialization.jsonObject(with: Data(json.utf8)))
    }

    /// The template with the changes applied and validated. Nothing is saved here.
    func applied(to template: WorkoutTemplate) throws -> WorkoutTemplate {
        var result = template
        if let name {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.count <= 80 else { throw AgentToolFailure("The name must be 1 to 80 characters.") }
            result.name = trimmed
        }
        var seen = Set<Int>()
        for change in exercises {
            guard result.exercises.indices.contains(change.index), seen.insert(change.index).inserted else {
                throw AgentToolFailure("Exercise index \(change.index) is not in this template, or is listed twice. It has \(result.exercises.count) exercises, from 0.")
            }
            if let v = change.sets { result.exercises[change.index].sets = v }
            if let v = change.repsMin { result.exercises[change.index].repsMin = v }
            if let v = change.repsMax { result.exercises[change.index].repsMax = v }
            if let v = change.loadKg { result.exercises[change.index].loadKg = v }
            if let v = change.restSeconds { result.exercises[change.index].restSeconds = v }
        }
        if cardioMinutes != nil || cardioZone != nil {
            guard var cardio = result.cardio else { throw AgentToolFailure("This template has no cardio target to change.") }
            if let v = cardioMinutes { cardio.minutes = v }
            if let v = cardioZone { cardio.zone = v }
            result.cardio = cardio
        }
        guard result != template else { throw AgentToolFailure("Those changes leave the template as it is.") }
        do { try result.validate() } catch { throw AgentToolFailure("Those values are outside what a template can hold. Sets are 1 to 20, reps 1 to 100, rest up to 3,600 seconds.") }
        return result
    }

    /// Plain lines for the card, one per change.
    func summaryLines(for template: WorkoutTemplate) -> [String] {
        var lines: [String] = []
        if let name { lines.append("Rename to \(name)") }
        for change in exercises where template.exercises.indices.contains(change.index) {
            let exercise = template.exercises[change.index]
            var parts: [String] = []
            if let v = change.sets { parts.append("\(v) sets") }
            if change.repsMin != nil || change.repsMax != nil {
                let low = change.repsMin ?? exercise.repsMin, high = change.repsMax ?? exercise.repsMax
                parts.append(low == high ? "\(low) reps" : "\(low) to \(high) reps")
            }
            if let v = change.loadKg { parts.append("\(AgentFormat.number(v)) kg") }
            if let v = change.restSeconds { parts.append("\(v) s rest") }
            lines.append("\(exercise.exercise.name): " + parts.joined(separator: ", "))
        }
        if let v = cardioMinutes { lines.append("Cardio target \(v) minutes") }
        if let v = cardioZone { lines.append("Cardio zone \(v)") }
        return Array(lines.prefix(6))
    }
}

nonisolated struct AgentToolFailure: Error, Equatable, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
}

nonisolated enum AgentFormat {
    static func number(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
    /// Card text follows the phone's clock, like the rest of the app. The tool arguments stay HH:mm.
    static func clock(minuteOfDay: Int) -> String { LooprClockFormat.text(minuteOfDay: minuteOfDay) }
    static func minuteOfDay(_ text: String?) -> Int? {
        guard let text else { return nil }
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 2, parts[1].count == 2, let h = Int(parts[0]), let m = Int(parts[1]),
              (0..<24).contains(h), (0..<60).contains(m) else { return nil }
        return h * 60 + m
    }
}

// MARK: Creating proposals

/// Validates what the model asked for and turns it into a stored proposal with a card. It writes nothing
/// except the proposal itself.
nonisolated struct AgentProposalMaker: Sendable {
    let writes: any AgentWriteStore
    let tests: (any AgentTestStarting)?
    let provider: CoachProvider
    let model: String
    let now: Date
    let timeZone: TimeZone
    /// Lets a reminder or test card warn about quiet hours and refused notifications before the person confirms.
    var reminders: (any AgentReminderScheduling)?

    init(writes: any AgentWriteStore, tests: (any AgentTestStarting)?, provider: CoachProvider, model: String,
         now: Date, timeZone: TimeZone, reminders: (any AgentReminderScheduling)? = nil) {
        self.writes = writes; self.tests = tests; self.provider = provider; self.model = model
        self.now = now; self.timeZone = timeZone; self.reminders = reminders
    }

    var today: String { AgentDays.string(now, in: timeZone) }

    func make(tool: String, args: [String: Any]) async throws -> (proposal: AIProposal, card: AIProposalCard) {
        switch tool {
        case AgentToolName.proposeMeal: try meal(args)
        case AgentToolName.proposeJournalQuestion: try journalQuestion(args)
        case AgentToolName.proposeTemplateEdit: try await templateEdit(args)
        case AgentToolName.proposeProgramDraft: try await programDraft(args)
        case AgentToolName.proposeReminder: try await reminder(args)
        case AgentToolName.proposeTest: try await test(args)
        default: throw AgentToolFailure("\(tool) is not a proposal tool.")
        }
    }

    private func meal(_ args: [String: Any]) throws -> (AIProposal, AIProposalCard) {
        guard let slot = (args["slot"] as? String).flatMap(FoodMealSlot.init(rawValue:)) else {
            throw AgentToolFailure("slot must be breakfast, lunch, snack or dinner.")
        }
        let day = (args["day"] as? String) ?? today
        guard AgentDays.isValid(day), day <= today, let earliest = AgentDays.add(-30, to: today), day >= earliest else {
            throw AgentToolFailure("day must be a date written yyyy-MM-dd, today or up to 30 days back.")
        }
        let defaultMinute: Int = switch slot { case .breakfast: 8 * 60; case .lunch: 12 * 60 + 30; case .snack: 15 * 60 + 30; case .dinner: 19 * 60 }
        let minute: Int
        if let text = args["time"] as? String {
            guard let parsed = AgentFormat.minuteOfDay(text) else { throw AgentToolFailure("time must be written HH:mm, for example 19:30.") }
            minute = parsed
        } else { minute = defaultMinute }
        guard let occurredAt = Self.date(day: day, minuteOfDay: minute, in: timeZone), occurredAt <= now.addingTimeInterval(300) else {
            throw AgentToolFailure("That time is in the future. Use a time that has already passed.")
        }
        guard let estimateObject = args["estimate"] as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: estimateObject, options: [.sortedKeys]) else {
            throw AgentToolFailure("estimate must be an object with items and uncertainty.")
        }
        let providerName = provider == .openAI ? "openai" : "anthropic"
        let estimate: FoodEstimate
        do { estimate = try FoodEstimate.decode(data, provider: providerName, model: model, at: now, source: .agentText) }
        catch { throw AgentToolFailure("estimate does not match the schema. Include items and uncertainty, give every item a name, amount, unit, confidence and all nine nutrient keys, and use null for unknown nutrients.") }
        guard !estimate.items.isEmpty else { throw AgentToolFailure("estimate has no items. Add at least one food.") }
        var lines = ["\(slot.title), \(Self.dayLabel(day)), \(AgentFormat.clock(minuteOfDay: minute))"]
        for item in estimate.items.prefix(4) {
            let energy = item.nutrients[.energy].map { "about \(Int($0.rounded())) kcal" } ?? "energy not known"
            lines.append("\(item.name), \(AgentFormat.number(item.amount)) \(item.unit.title), \(energy)")
        }
        if estimate.items.count > 4 { lines.append("and \(estimate.items.count - 4) more") }
        lines.append(AgentProposalCopy.estimatedLine)
        return (.meal(estimateJSON: String(decoding: data, as: UTF8.self), slot: slot.rawValue, occurredAt: occurredAt,
                      timeZoneID: timeZone.identifier, provider: providerName, model: model),
                AIProposalCard(title: "Log this meal?", lines: lines, confirmTitle: "Log meal", doneText: "Meal logged."))
    }

    private func journalQuestion(_ args: [String: Any]) throws -> (AIProposal, AIProposalCard) {
        let name = (args["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let question = (args["question"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard (1...40).contains(name.count) else { throw AgentToolFailure("name must be 1 to 40 characters.") }
        guard (3...140).contains(question.count), question.hasSuffix("?") else { throw AgentToolFailure("question must be 3 to 140 characters and end with a question mark.") }
        return (.journalQuestion(name: name, question: question),
                AIProposalCard(title: "Add this question?", lines: [name, question], confirmTitle: "Add question", doneText: "Question added."))
    }

    private func templateEdit(_ args: [String: Any]) async throws -> (AIProposal, AIProposalCard) {
        guard let id = (args["templateId"] as? String).flatMap(UUID.init(uuidString:)) else { throw AgentToolFailure("templateId must be an id from get_training.") }
        guard let template = try await writes.template(id: id) else { throw AgentToolFailure("No saved template has that id. Read templates with get_training and includeTemplates first.") }
        guard let revision = (args["revision"] as? NSNumber)?.intValue, revision == template.revision else {
            throw AgentToolFailure("The template is at revision \(template.revision), not the one you read. Read it again before proposing an edit.")
        }
        let edit = try AgentTemplateEdit(object: args["changes"] ?? [:])
        _ = try edit.applied(to: template)
        return (.templateEdit(templateID: id, expectedRevision: template.revision, editJSON: try edit.json()),
                AIProposalCard(title: "Update this template?", lines: [template.name] + edit.summaryLines(for: template),
                               confirmTitle: "Update template", doneText: "Template updated."))
    }

    private func programDraft(_ args: [String: Any]) async throws -> (AIProposal, AIProposalCard) {
        guard let program = args["program"] as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: program, options: [.sortedKeys]) else {
            throw AgentToolFailure("program must be an object that follows the program draft schema.")
        }
        let json = String(decoding: data, as: UTF8.self)
        do { try await writes.checkProgramDraft(json: json, defaultStartDay: today) }
        catch let error as ProgramDraftError { throw AgentToolFailure(error.message) }
        let weeks = program["weeks"] as? [[Any]] ?? []
        let sessions = weeks.reduce(0) { $0 + $1.count }
        let name = (program["name"] as? String) ?? "Program"
        return (.programDraft(json: json),
                AIProposalCard(title: "Save this program as a draft?",
                               lines: [name, "\(weeks.count) \(weeks.count == 1 ? "week" : "weeks"), \(sessions) \(sessions == 1 ? "session" : "sessions")", AgentProposalCopy.draftLine],
                               confirmTitle: "Save draft", doneText: "Draft saved. Open Fitness to review it."))
    }

    private func reminder(_ args: [String: Any]) async throws -> (AIProposal, AIProposalCard) {
        let title = (args["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let body = (args["body"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard (1...60).contains(title.count) else { throw AgentToolFailure("title must be 1 to 60 characters.") }
        guard body.count <= 140 else { throw AgentToolFailure("body must be at most 140 characters.") }
        guard let minute = AgentFormat.minuteOfDay(args["time"] as? String) else { throw AgentToolFailure("time must be written HH:mm, for example 20:15.") }
        // The text shows on the lock screen as written, so a health reading cannot go in it.
        guard AgentReminderText.healthReading(in: title) == nil, AgentReminderText.healthReading(in: body) == nil else {
            throw AgentToolFailure(AgentReminderText.refusal)
        }
        let daily = args["repeatsDaily"] as? Bool ?? false
        let clock = AgentFormat.clock(minuteOfDay: minute)
        var lines = [title, daily ? "Every day" : "Once, the next time it is \(clock)"]
        if let reminders {
            if await reminders.notificationsAreRefused() { lines.append(AgentProposalCopy.reminderNotificationsOffLine) }
            else if await reminders.isInQuietHours(minuteOfDay: minute) { lines.append(AgentProposalCopy.quietHoursLine) }
        }
        return (.reminder(title: title, body: body, minuteOfDay: minute, repeatsDaily: daily),
                AIProposalCard(title: "Remind you at \(clock)?", lines: lines, confirmTitle: "Set reminder", doneText: "Reminder set."))
    }

    private func test(_ args: [String: Any]) async throws -> (AIProposal, AIProposalCard) {
        guard let tests else { throw AgentToolFailure("Tests are not available right now.") }
        guard let candidate = args["candidateId"] as? String, !candidate.isEmpty else { throw AgentToolFailure("candidateId must come from list_patterns.") }
        let metric = args["metric"] as? String
        guard let title = await tests.title(candidateID: candidate, metric: metric) else {
            throw AgentToolFailure("That pattern cannot be tested right now. Use a candidateId and metric from list_patterns.")
        }
        var reminderMinute: Int?
        if let text = args["reminderTime"] as? String {
            guard let parsed = AgentFormat.minuteOfDay(text) else { throw AgentToolFailure("reminderTime must be written HH:mm.") }
            reminderMinute = parsed
        }
        var lines = [title, "14 days. You answer one question a day."]
        if let reminderMinute {
            lines.append("Reminder at \(AgentFormat.clock(minuteOfDay: reminderMinute))")
            if let reminders {
                if await reminders.notificationsAreRefused() { lines.append(AgentProposalCopy.testNotificationsOffLine) }
                else if await reminders.isInQuietHours(minuteOfDay: reminderMinute) { lines.append(AgentProposalCopy.quietHoursLine) }
            }
        }
        return (.test(candidateID: candidate, metric: metric, reminderMinuteOfDay: reminderMinute),
                AIProposalCard(title: "Start this 14-day test?", lines: lines, confirmTitle: "Start test", doneText: "Test started."))
    }

    static func date(day: String, minuteOfDay: Int, in zone: TimeZone) -> Date? {
        guard let parsed = AgentDays.parse(day) else { return nil }
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let c = utc.dateComponents([.year, .month, .day], from: parsed)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        return calendar.date(from: DateComponents(year: c.year, month: c.month, day: c.day, hour: minuteOfDay / 60, minute: minuteOfDay % 60))
    }
    static func dayLabel(_ day: String) -> String {
        guard let date = AgentDays.parse(day) else { return day }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE d MMM"
        return formatter.string(from: date)
    }
}

// MARK: Applying proposals

/// The only code that writes for the agent. `AIProposalLedger.confirmAndApply` calls it, and the ledger
/// is reached only from a Confirm tap.
nonisolated struct AgentProposalApplier: AIProposalApplier {
    let writes: any AgentWriteStore
    let reminders: any AgentReminderScheduling
    let tests: (any AgentTestStarting)?
    let now: @Sendable () -> Date
    let timeZone: @Sendable () -> TimeZone

    init(writes: any AgentWriteStore, reminders: any AgentReminderScheduling, tests: (any AgentTestStarting)? = nil,
         now: @escaping @Sendable () -> Date = { Date() }, timeZone: @escaping @Sendable () -> TimeZone = { .current }) {
        self.writes = writes; self.reminders = reminders; self.tests = tests; self.now = now; self.timeZone = timeZone
    }

    func apply(_ proposal: AIProposal) async throws { throw AgentApplyError.generic }

    func apply(_ proposal: AIProposal, id: UUID) async throws {
        do { try await perform(proposal, id: id) } catch { throw AgentApplyError.friendly(error) }
    }

    private func perform(_ proposal: AIProposal, id: UUID) async throws {
        let date = now()
        switch proposal {
        case .meal(let json, let slotName, let occurredAt, let zoneID, let provider, let model):
            // The meal id is the proposal id, so a repeat after a crash finds the meal and stops.
            if try await writes.mealExists(id: id) { return }
            guard let slot = FoodMealSlot(rawValue: slotName) else { throw AgentApplyError.generic }
            let estimate = try FoodEstimate.decode(Data(json.utf8), provider: provider, model: model, at: date, source: .agentText)
            try await writes.confirmMeal(FoodMealDraft(id: id, slot: slot, occurredAt: occurredAt, timeZoneIdentifier: zoneID, items: estimate.items), at: date)
        case .journalQuestion(let name, let question):
            let habitID = HabitID(rawValue: AgentIDs.derived(from: id))
            let existing = try await writes.habitDefinitions()
            if existing.contains(where: { $0.id == habitID }) { return }
            let active = existing.filter { !$0.isArchived }.count
            guard active < HabitStoreValidator.activeLimit else { throw AgentApplyError("You already have \(HabitStoreValidator.activeLimit) active questions. Archive one in Protocol first.") }
            let order = (existing.map(\.sortOrder).max() ?? -1) + 1
            try await writes.saveHabitDefinition(HabitDefinition(id: habitID, source: .custom, name: name, question: question, sortOrder: order, createdAt: date))
        case .templateEdit(let templateID, let revision, let json):
            guard let template = try await writes.template(id: templateID) else { throw AgentApplyError("This template is gone, so nothing was changed.") }
            guard template.revision == revision else { throw AgentApplyError("This template changed after Ask suggested the edit. Ask again to get a fresh one.") }
            let updated: WorkoutTemplate
            do { updated = try AgentTemplateEdit(json: json).applied(to: template) }
            catch let failure as AgentToolFailure { throw AgentApplyError(failure.message) }
            try await writes.saveTemplate(updated, at: date)
        case .programDraft(let json):
            try await writes.saveProgramDraft(json: json, defaultStartDay: AgentDays.string(date, in: timeZone()), proposalID: id, at: date)
        case .reminder(let title, let body, let minute, let daily):
            guard AgentReminderText.healthReading(in: title) == nil, AgentReminderText.healthReading(in: body) == nil else {
                throw AgentApplyError("This reminder carries a health reading, which would show on the lock screen. Ask again without the number.")
            }
            try await reminders.schedule(id: id, title: title, body: body, minuteOfDay: minute, repeatsDaily: daily)
        case .test(let candidate, let metric, let reminderMinute):
            guard let tests else { throw AgentApplyError("Tests are not available right now.") }
            try await tests.start(candidateID: candidate, metric: metric, reminderMinuteOfDay: reminderMinute, at: date)
        case .journal, .goalAdjustment:
            throw AgentApplyError.generic
        }
    }
}

// MARK: Center

nonisolated struct AgentConfirmResult: Equatable, Sendable {
    /// True only when this call saved the change.
    let applied: Bool
    let proposal: StoredAIProposal?
    /// A sentence the person can read when saving failed.
    let failure: String?
}

/// The app's door to proposals: create, list, confirm, dismiss, delete with the chat.
nonisolated final class AgentProposalCenter: Sendable {
    let ledger: AIProposalLedger
    private let applier: any AIProposalApplier
    init(ledger: AIProposalLedger, applier: any AIProposalApplier) { self.ledger = ledger; self.applier = applier }

    func create(_ row: StoredAIProposal) async throws { try await ledger.create(row) }
    func proposals(conversationID: UUID) async -> [StoredAIProposal] { await ledger.proposals(conversationID: conversationID) }
    func proposal(id: UUID) async -> StoredAIProposal? { await ledger.proposal(id: id) }

    /// The Confirm tap. Saves once. A second tap, or one that lands while the first is saving, does nothing.
    func confirm(id: UUID, at date: Date = Date()) async -> AgentConfirmResult {
        do {
            let applied = try await ledger.confirmAndApply(id: id, at: date, using: applier)
            return AgentConfirmResult(applied: applied, proposal: await ledger.proposal(id: id), failure: nil)
        } catch {
            return AgentConfirmResult(applied: false, proposal: await ledger.proposal(id: id), failure: AgentApplyError.friendly(error).message)
        }
    }
    /// "Not now". Nothing is saved.
    func dismiss(id: UUID, at date: Date = Date()) async -> StoredAIProposal? {
        await ledger.dismiss(id: id, at: date)
        return await ledger.proposal(id: id)
    }
    func deleteProposals(conversationID: UUID) async { await ledger.delete(conversationID: conversationID) }
    func deleteAll() async { await ledger.deleteAll() }
}

/// Proposals in the `agent` namespace of the products database, keyed `proposal.<id>`.
nonisolated final class StorageDocumentProposalPersistence: AIProposalPersistence, @unchecked Sendable {
    static let namespace = "agent"
    static let prefix = "proposal."
    private let store: StorageDocumentStore
    init(database: StorageDatabase) throws { store = try StorageDocumentStore(database: database, namespace: Self.namespace) }
    func load() throws -> [StoredAIProposal] {
        try store.keys().filter { $0.hasPrefix(Self.prefix) }.compactMap { try? store.read(StoredAIProposal.self, key: $0) }
    }
    func save(_ row: StoredAIProposal) throws { try store.write(row, key: Self.prefix + row.id.uuidString) }
    func remove(ids: [UUID]) throws { for id in ids { try store.remove(key: Self.prefix + id.uuidString) } }
    func removeAll() throws { try store.removeAll(whereKeyPrefix: Self.prefix) }
}

// MARK: Production seams

/// Writes confirmed proposals into the app's stores.
nonisolated struct LooprAgentWriteStore: AgentWriteStore {
    private let food: FoodStore
    private let habits: SQLiteHabitRepository
    private let train: TrainStore

    init(persistent: PersistentProductRepositories) {
        food = persistent.food; habits = persistent.habits; train = persistent.train
    }

    func mealExists(id: UUID) async throws -> Bool { try food.meal(id: id) != nil }
    func confirmMeal(_ draft: FoodMealDraft, at date: Date) async throws { try food.confirm(draft, at: date) }
    func habitDefinitions() async throws -> [HabitDefinition] { try await habits.definitions(includeArchived: true) }
    func saveHabitDefinition(_ definition: HabitDefinition) async throws { try await habits.saveDefinition(definition) }
    func template(id: UUID) async throws -> WorkoutTemplate? { try train.template(id: id) }
    func saveTemplate(_ template: WorkoutTemplate, at date: Date) async throws { _ = try train.saveTemplate(template, at: date) }

    private func library() -> ExerciseLibrary? {
        guard let bundled = try? TrainTemplateRoot.loadBundledLibrary() else { return nil }
        return (try? bundled.merged(withCustom: (try? train.customExercises()) ?? [])) ?? bundled
    }
    func checkProgramDraft(json: String, defaultStartDay: String) async throws {
        _ = try ProgramDraftDecoder(templates: try train.templates(), library: library(), defaultStartDay: defaultStartDay).decode(json)
    }
    func saveProgramDraft(json: String, defaultStartDay: String, proposalID: UUID, at date: Date) async throws {
        let counter = AgentIDCounter(base: proposalID)
        let decoder = ProgramDraftDecoder(templates: try train.templates(), library: library(), defaultStartDay: defaultStartDay,
                                          makeID: { counter.next() })
        let program = try decoder.decode(json)
        // Same proposal, same ids: a second apply finds the draft and stops.
        if try train.program(id: program.id) != nil { return }
        _ = try train.saveProgram(program, at: date)
    }
}

nonisolated final class AgentIDCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var index: UInt8 = 0
    private let base: UUID
    init(base: UUID) { self.base = base }
    func next() -> UUID {
        lock.withLock { defer { index &+= 1 }; return AgentIDs.derived(from: base, index: index) }
    }
}

#if canImport(UserNotifications)
/// Schedules a confirmed reminder through the notification layer, as one of "Reminders you set". It fires at the
/// time the person chose, even inside quiet hours. The person wrote the words on the card, so the lock screen shows them.
nonisolated struct LooprAgentReminderScheduler: AgentReminderScheduling {
    func schedule(id: UUID, title: String, body: String, minuteOfDay: Int, repeatsDaily: Bool) async throws {
        let runtime = LooprNotificationRuntime.shared
        guard let first = LooprNotificationRuntime.nextOccurrence(ofMinute: minuteOfDay, after: Date()) else {
            throw AgentApplyError("Loopr could not schedule the reminder. Try again.")
        }
        let outcome = await runtime.scheduleUserReminder(UserReminderDraft(
            source: .ask, objectID: "ask." + id.uuidString, title: title, body: body, minuteOfDay: minuteOfDay,
            repeatsDaily: repeatsDaily, firstFire: first, expiresAt: nil))
        switch outcome {
        case .set: return
        case .notAllowed: throw AgentApplyError(AgentProposalCopy.notificationsOffText)
        case .full: throw AgentApplyError(AgentProposalCopy.reminderLimitText)
        case .familyOff: throw AgentApplyError(AgentProposalCopy.reminderFamilyOffText)
        case .failed: throw AgentApplyError("Loopr could not schedule the reminder. Try again.")
        }
    }

    func isInQuietHours(minuteOfDay: Int) async -> Bool {
        await LooprNotificationRuntime.shared.quietHoursContain(minuteOfDay: minuteOfDay)
    }

    func notificationsAreRefused() async -> Bool {
        await LooprNotificationRuntime.shared.refreshAuthorization() == .denied
    }
}
#endif
