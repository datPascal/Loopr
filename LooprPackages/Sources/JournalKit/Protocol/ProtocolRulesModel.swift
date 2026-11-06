import Combine
import CoreTransferable
import DesignSystem
import DomainKit
import Foundation
import RoutineKit
import UniformTypeIdentifiers

/// The protocol file as the share sheet sees it: the `com.loopr.protocol` type, named after the protocol.
public struct ProtocolFileDocument: Transferable, Sendable {
    public let data: Data
    public let fileName: String

    public init(file: ProtocolFile) throws {
        data = try ProtocolFileCodec.encode(file)
        fileName = file.suggestedFileName
    }

    public static var protocolType: UTType { UTType(exportedAs: ProtocolFile.typeIdentifier, conformingTo: .json) }

    public static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: protocolType) { document in document.data }
            .suggestedFileName { document in document.fileName }
    }
}

/// What the Rules segment says after a save, and the rules Undo puts back (ICP R1-HAB-19, R1-DES-08, R1-SEN-12). The
/// version line comes after Save, never before it.
public struct ProtocolSavedNotice: Equatable, Identifiable, Sendable {
    public var id: UUID { toast.id }
    /// "Saved as version 3."
    public let toast: LooprToastContent
    /// The rules before the save. Nil when there is nothing to undo, such as after an undo or a reminder switch.
    public let previousRules: [ProtocolRule]?

    /// True after a new rule was saved: the toast's action is "Add another", which opens a new rule, since someone
    /// moving several habits over adds them one after another (ICP R3-HAB-08). Remove on the row takes one back.
    public let addsAnother: Bool

    public var message: String { toast.message }
    public var canUndo: Bool { previousRules != nil && !addsAnother }

    init(_ message: String, previousRules: [ProtocolRule]? = nil, addsAnother: Bool = false) {
        let action: String? = addsAnother ? ProtocolRulesText.addAnother : previousRules == nil ? nil : "Undo"
        toast = LooprToastContent(message, accent: .protocol, actionTitle: action)
        self.previousRules = previousRules
        self.addsAnother = addsAnother
    }

    /// "Saved as version 3.", "Removed Sauna. Saved as version 3.", "Replaced Zone 2, 45 min. Saved as version 4."
    static func saved(_ draft: ProtocolRuleDraft, version: Int, replaced: String? = nil) -> String {
        let name = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let replaced { return "Replaced \(replaced). Saved as version \(version)." }
        if draft.isRemoved { return "Removed \(name). Saved as version \(version)." }
        if draft.isAdding { return "Added \(name). Saved as version \(version)." }
        return "Saved as version \(version)."
    }
}

/// The pass card with the file it describes.
public struct ProtocolPassContent: Sendable {
    public let pass: ProtocolPass
    public let document: ProtocolFileDocument
    /// The rules, for the rosette.
    public let rules: [ProtocolRule]
}

// The Rules segment's actions (LV-07.4). Every save goes through the source, which writes a new immutable version.
public extension ProtocolTabModel {
    var ruleSections: [ProtocolRuleSection] {
        ProtocolRulesPresentation.sections(routine?.rules ?? [], reminders: reminderMinutes, progress: ruleProgress,
                                           today: routine?.today, week: routine?.week ?? [], lastWeek: routine?.lastWeek ?? [],
                                           tests: ProtocolRulesPresentation.testTexts(running: experimentData?.running),
                                           locale: week.locale)
    }

    var versionEntries: [ProtocolVersionEntry] { ProtocolVersionEntry.entries(versionList ?? [], locale: week.locale) }

    var hasReminders: Bool { reminders != nil }

    /// Rules with a longer period and how far they have come this week (ICP R1-VET-08, R1-VET-23).
    var ruleProgress: [RuleKey: RuleProgress] { routine?.progress ?? [:] }

    /// "Your rules", or the protocol's own name when it has one.
    var rulesTitle: String {
        guard let name = routine?.protocolName.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
              name != "My protocol" else { return "Your rules" }
        return name
    }

    /// Versions sits in the Rules menu once there is more than one (ICP R1-DES-16).
    var hasEarlierVersions: Bool { (routine?.version ?? 1) > 1 }

    var rulesErrorMessage: String? { rulesMessage }

    func version(_ number: Int) -> ProtocolVersion? { versionList?.first { $0.number == number } }

    /// A version against the one before it, for the version screen.
    func versionDetail(_ number: Int) -> ProtocolVersionDetail? {
        guard let version = version(number) else { return nil }
        let previous = versionList?.filter { $0.number < number }.max { $0.number < $1.number }
        return ProtocolVersionDetail.make(version, previous: previous, locale: week.locale)
    }

    func reminderMinute(for key: RuleKey) -> Int? { reminderMinutes[key] }

    /// The rule that already measures what the draft would save, so the editor can ask "Keep both?" first (ICP
    /// R3-VET-05). Asked for a new rule, and for an edit that changes what the rule measures; an edit that leaves the
    /// measure alone never asks again.
    func ruleSharingMeasure(with draft: ProtocolRuleDraft) -> ProtocolRule? {
        guard !draft.isRemoved, let rules = routine?.rules else { return nil }
        let key = draft.originalKey
        let saved = draft.rule(key: draft.isAdding ? ProtocolRuleDraft.newKey(title: draft.title, existing: Set(rules.map(\.key)))
                                                   : key ?? "new")
        if !draft.isAdding, let before = rules.first(where: { $0.key == key }), before.target.metric == saved.target.metric {
            return nil
        }
        return ProtocolRuleOverlap.ruleSharingMeasure(with: saved, among: rules.filter { draft.isAdding || $0.key != key })
    }

    func draft(for rule: ProtocolRule) -> ProtocolRuleDraft {
        ProtocolRuleDraft(rule: rule, remindMe: reminderMinutes[rule.key] != nil)
    }

    func loadVersions() async {
        do {
            versionList = try await sourceVersions()
        } catch {
            rulesMessage = "Loopr could not read the versions. \(error.localizedDescription)"
        }
    }

    func refreshReminders() async {
        guard let reminders else { return }
        reminderMinutes = await reminders.waiting()
    }

    /// Saves the draft as the next version, with the person's `reason` ("Why this change?") as its note when they gave
    /// one (ICP R2-VET-07). Returns what to say afterwards, with Undo, when a version was saved, or when only the
    /// reminder switch changed and that worked, so the screen can play the soft success. Nil when nothing was saved;
    /// `rulesErrorMessage` then says why.
    ///
    /// `replacing` names a rule to take out in the same version, when the person picked "Replace" over "Keep both".
    @discardableResult
    func saveRule(_ draft: ProtocolRuleDraft, reason: String? = nil, replacing: RuleKey? = nil) async -> ProtocolSavedNotice? {
        guard !isSaving, let routine, draft.canSave else { return nil }
        isSavingRules(true)
        defer { isSavingRules(false) }
        if draft.onlyReminderChanged, let key = draft.originalKey, let rule = routine.rules.first(where: { $0.key == key }) {
            let message = await applyReminder(for: rule, on: draft.remindMe)
            rulesMessage = message
            await refreshReminders()
            guard message == nil else { return nil }
            return ProtocolSavedNotice(draft.remindMe ? "Reminder on." : "Reminder off.")
        }
        let replaced = replacing.flatMap { key in routine.rules.first { $0.key == key && $0.key != draft.originalKey } }
        let rules = ProtocolRuleEdit.apply(draft, to: routine.rules).filter { $0.key != replaced?.key }
        do {
            let saved = try await sourceSaveRules(rules, reason: reason)
            rulesMessage = nil
            await syncReminders(with: saved.rules, draft: draft)
            await load()
            await loadVersions()
            let message = ProtocolSavedNotice.saved(draft, version: saved.number,
                                                    replaced: replaced?.displayTitle(locale: week.locale))
            return ProtocolSavedNotice(message, previousRules: routine.rules, addsAnother: draft.isAdding && replaced == nil)
        } catch let error as ProtocolEditError where error == .noChange {
            rulesMessage = error.localizedDescription
            return nil
        } catch {
            rulesMessage = "\(ProtocolRulesText.saveFailed) \(error.localizedDescription)"
            return nil
        }
    }

    /// Undo after a save: the rules from before it become the next version, so every version stays as it was saved.
    /// Reminders follow the rules back, and a reminder of a rule that comes back stays off.
    @discardableResult
    func undoSave(_ notice: ProtocolSavedNotice) async -> ProtocolSavedNotice? {
        guard !isSaving, let previous = notice.previousRules else { return nil }
        isSavingRules(true)
        defer { isSavingRules(false) }
        do {
            let saved = try await sourceSaveRules(previous)
            rulesMessage = nil
            await syncReminders(with: saved.rules, draft: nil)
            await load()
            await loadVersions()
            return ProtocolSavedNotice(ProtocolRulesText.undone)
        } catch let error as ProtocolEditError where error == .noChange {
            return ProtocolSavedNotice(ProtocolRulesText.undone)
        } catch {
            rulesMessage = "Loopr could not undo that. \(error.localizedDescription)"
            return nil
        }
    }

    /// The pass card for the newest version, with its encoded file.
    func passContent() async -> ProtocolPassContent? {
        do {
            let file = try await sourceProtocolFile()
            let document = try ProtocolFileDocument(file: file)
            return ProtocolPassContent(pass: ProtocolPass.make(file: file, data: document.data, keptPercent: summary?.percent,
                                                                 checkCount: summary?.decided),
                                       document: document, rules: file.rules)
        } catch {
            rulesMessage = "Loopr could not make the file. \(error.localizedDescription)"
            return nil
        }
    }

    // MARK: Files

    /// Hands every file the app receives to the Rules segment. The model keeps the subscription.
    func attach(incoming: AnyPublisher<ProtocolFileIncoming, Never>) {
        incomingSubscription = incoming.receive(on: DispatchQueue.main).sink { [weak self] value in
            MainActor.assumeIsolated { self?.receive(value) }
        }
    }

    /// A file arrived: a valid one waits for review, a refused one shows the validator's sentence. Nothing is saved.
    func receive(_ incoming: ProtocolFileIncoming) {
        requestedSegment = .rules
        switch incoming {
        case .preview(let preview):
            importError = nil
            importReview = ProtocolImportReview.make(preview, current: routine?.rules, currentVersion: routine?.version,
                                                     locale: week.locale)
        case .rejected(let message):
            importReview = nil
            importError = message
        }
    }

    /// The Rules segment's importer picked a file.
    func openPickedFile(_ url: URL) {
        if let openFile {
            if !openFile(url) { receive(.rejected("Loopr opens protocol files that end in .looprprotocol or .json.")) }
            return
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { receive(.rejected("Loopr could not read this file.")); return }
        do {
            receive(.preview(try ProtocolFileCodec.validate(data)))
        } catch {
            receive(.rejected(error.localizedDescription))
        }
    }

    func pickerFailed(_ error: Error) {
        receive(.rejected("Loopr could not open that file. \(error.localizedDescription)"))
    }

    /// "Use this protocol".
    @discardableResult
    func useImport() async -> Bool {
        guard !isSaving, let review = importReview else { return false }
        isSavingRules(true)
        defer { isSavingRules(false) }
        do {
            let saved = try await sourceAdoptFile(review.preview)
            importReview = nil
            importError = nil
            rulesMessage = nil
            await syncReminders(with: saved.rules, draft: nil)
            await load()
            await loadVersions()
            return true
        } catch {
            importError = "\(ProtocolRulesText.saveFailed) \(error.localizedDescription)"
            return false
        }
    }

    func dismissImport() {
        importReview = nil
    }

    func dismissImportError() { importError = nil }

    /// First run: the template becomes version 1.
    @discardableResult
    func installTemplate(_ template: ProtocolTemplate) async -> Bool {
        guard !isSaving else { return false }
        isSavingRules(true)
        defer { isSavingRules(false) }
        do {
            try await sourceInstallTemplate(template)
            rulesMessage = nil
            await load()
            return true
        } catch {
            rulesMessage = "Loopr could not start this template. \(error.localizedDescription)"
            await load()
            return false
        }
    }

    /// "Use my questions": the check-in's questions become version 1, with their answers as history (ICP R3-UPG-5).
    @discardableResult
    func startFromQuestions() async -> Bool {
        guard !isSaving else { return false }
        isSavingRules(true)
        defer { isSavingRules(false) }
        do {
            try await sourceStartFromQuestions(habits.activeDefinitions.map(\.routineHabit),
                                               responses: habits.records.flatMap(\.routineResponses))
            rulesMessage = nil
            await load()
            return true
        } catch {
            rulesMessage = "Loopr could not start a protocol from your questions. \(error.localizedDescription)"
            requestedSegment = .rules
            await load()
            return false
        }
    }

    // MARK: Reminders

    /// After a save: the edited rule's reminder follows its switch, and every other waiting reminder takes the rule's
    /// new time and words, or goes when its rule or time is gone. Loopr never adds a reminder the person did not ask for.
    private func syncReminders(with rules: [ProtocolRule], draft: ProtocolRuleDraft?) async {
        guard let reminders else { return }
        let waiting = await reminders.waiting()
        let byKey = Dictionary(rules.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        var message: String?
        var handled = Set<RuleKey>()
        if let draft, let key = draft.isAdding ? rules.last?.key : draft.originalKey {
            handled.insert(key)
            if let rule = byKey[key], draft.remindMe, !draft.isRemoved {
                message = await applyReminder(for: rule, on: true)
            } else if waiting[key] != nil {
                await reminders.remove(key)
            }
        }
        for key in waiting.keys where !handled.contains(key) {
            if let rule = byKey[key], rule.timeOfDayMinutes != nil {
                message = await reminders.set(rule) ?? message
            } else {
                await reminders.remove(key)
            }
        }
        if let message { rulesMessage = message }
        reminderMinutes = await reminders.waiting()
    }

    private func applyReminder(for rule: ProtocolRule, on: Bool) async -> String? {
        guard let reminders else { return nil }
        guard on else { await reminders.remove(rule.key); return nil }
        guard rule.timeOfDayMinutes != nil else { return ProtocolRulesText.reminderNeedsTime }
        return await reminders.set(rule)
    }
}
