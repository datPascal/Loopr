import Combine
import DomainKit
import Foundation
import RoutineKit

/// The Protocol tab's state and actions. The routine part comes from the app through `ProtocolTabSource`; how the person
/// feels, the Journal questions that did not become rules and the notes come from the Journal's own `HabitViewModel`.
/// A Journal question that became a rule is answered on the deck only, as that rule (ICP R1-UPG-1).
@MainActor
public final class ProtocolTabModel: ObservableObject {
    @Published public private(set) var content: ProtocolTabContent?
    @Published public private(set) var isSaving = false
    @Published public private(set) var errorMessage: String?
    /// The last answer on the deck, until it is undone or the next one replaces it.
    @Published public private(set) var lastAnswer: ProtocolDeckAnswer?
    /// What "Skip the rest of today" skipped, while Undo can take it back. Gone once today changes.
    @Published public private(set) var skippedDay: ProtocolSkippedDay?
    /// The rule whose answer is being saved. The deck leaves its card out at once, so the slot closes as the card goes
    /// and the next card, the quiet line or the closing card takes its place (ICP R3-NEW-08, R3-DES-11).
    @Published public private(set) var answering: RuleKey?

    // MARK: Rules state (LV-07.4)

    /// Every version of the protocol, once the history or a save asked for them.
    @Published var versionList: [ProtocolVersion]?
    /// A valid file waiting for "Use this protocol".
    @Published public var importReview: ProtocolImportReview?
    /// The validator's sentence for a file that was refused. Nothing was saved.
    @Published public var importError: String?
    /// A sentence about the last Rules action that did not work.
    @Published var rulesMessage: String?
    /// The waiting rule reminders, by rule key, as minutes after midnight.
    @Published var reminderMinutes: [RuleKey: Int] = [:]
    /// The segment the screen should switch to, such as Rules when a file arrives. The screen clears it.
    @Published public var requestedSegment: ProtocolSegment?
    /// The rule reminders under "Reminders you set". Nil hides the editor's reminder switch.
    public var reminders: (any ProtocolRuleReminding)?
    /// Opens a file the Rules segment's importer picked. The app routes it through its file inbox, which hands the
    /// result back through `attach(incoming:)`. Returns false when the URL is not a protocol file.
    public var openFile: (@MainActor (URL) -> Bool)?
    var incomingSubscription: AnyCancellable?

    public let habits: HabitViewModel
    private let source: any ProtocolTabSource
    private let clock: @Sendable () -> Date
    public let week: ProtocolWeekCalendar
    private var loadGeneration = 0

    public init(source: any ProtocolTabSource, habits: HabitViewModel, timeZone: TimeZone, locale: Locale = .current,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.source = source
        self.habits = habits
        week = ProtocolWeekCalendar(timeZone: timeZone, locale: locale)
        clock = now
    }

    public var now: Date { clock() }
    public var routine: ProtocolRoutineData? { content?.routineData }
    public var isLoading: Bool { content == nil }

    public func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        let loaded = await source.load(now: clock())
        guard generation == loadGeneration else { return }
        content = loaded
        switch loaded.routine {
        case .ready(let data): habits.setRuleHabitIDs(Set(data.habitRuleIDs.map(HabitID.init(rawValue:))))
        case .noProtocol: habits.setRuleHabitIDs([])
        case .unavailable: break
        }
    }

    // MARK: Derived

    /// "Day 21 · 10 rules". The day counts from the first answer the protocol holds, so a protocol moved over from the
    /// Journal shows how long its history runs (ICP R1-UPG-11). The version lives on Rules (ICP R1-DES-16).
    public var headerMeta: String {
        switch content?.routine {
        case nil: "Loading your protocol"
        case .noProtocol?: "Nothing set up yet"
        case .unavailable?: "Protocol not available"
        case .ready(let data)?: Self.headerMeta(day: data.dayNumber, rules: data.rules.count)
        }
    }

    public nonisolated static func headerMeta(day: Int, rules: Int) -> String {
        "Day \(max(day, 1)) \u{00B7} \(rules) \(rules == 1 ? "rule" : "rules")"
    }

    /// The week's rosettes. Each day counts only the rules due that day, as Today does (ICP R4 Q3).
    public var days: [ProtocolDayPresentation] {
        (routine?.countedWeek ?? []).map { ProtocolDayPresentation.make($0, week: week) }
    }

    /// The hero, from the same counted week as the rosettes, so the share pass and "This week" match it.
    public var summary: ProtocolWeekSummary? {
        guard let routine else { return nil }
        return ProtocolWeekSummary.make(week: routine.countedWeek, calendar: week, dayNumber: routine.dayNumber,
                                        startedOn: week.adding(1 - max(routine.dayNumber, 1), to: routine.today))
    }

    /// The rules the person asked to answer now from the later list, for today only (ICP R2-VET-04).
    @Published public private(set) var early: [RuleKey] = []
    private var earlyDay: DayIdentity?

    /// Today's rules brought forward, or none once the day has changed.
    var todaysEarly: [RuleKey] { earlyDay == routine?.today ? early : [] }

    /// Brings a rule from the later list to the front of the deck, so it can be answered now.
    public func answerEarly(_ key: RuleKey) {
        guard let today = routine?.today else { return }
        if earlyDay != today { early = []; earlyDay = today }
        if !early.contains(key) { early.append(key) }
    }

    /// The rules to answer now: open, due today and whose time has come, with any brought forward first.
    public var deck: [ProtocolDeckQuestion] {
        guard let routine else { return [] }
        return ProtocolDeckQueue.questions(today: routine.todayInput, week: routine.week, progress: routine.progress,
                                           nowMinute: routine.nowMinute, early: todaysEarly, locale: week.locale)
            .filter { answering == nil || $0.ruleKey != answering }
    }

    /// True while the swipe hint shows: only to a person who has never answered a card (ICP R3-HAB-01, R3-SEN-08).
    public func showsSwipeHint(answersOnPhone: Int) -> Bool {
        guard let routine else { return false }
        return ProtocolDeckQueue.showsSwipeHint(answersOnPhone: answersOnPhone, history: routine.lastWeek + routine.week)
    }

    /// The rules the person ticks later today, one row each.
    public var deckLater: ProtocolDeckLater? {
        guard let routine else { return nil }
        return ProtocolDeckQueue.later(today: routine.todayInput, week: routine.week, progress: routine.progress,
                                       nowMinute: routine.nowMinute, early: todaysEarly, locale: week.locale)
    }

    /// The check-in's pattern line, from the protocol's third day, when the week has something to count (ICP R2-HAB-01),
    /// naming the rule on the list the pattern is about (ICP R3-NEW-02).
    public var patternSignal: ProtocolPatternSignal? {
        guard let routine, routine.dayNumber >= ProtocolWeekSummary.percentFromDay else { return nil }
        return content?.patterns.signal?.naming(rules: routine.rules)
    }

    /// "Tonight is an off night for the magnesium test."
    public var offNightLines: [String] { ProtocolDeckQueue.offNightLines(today: routine?.todayInput) }

    public var deckTitle: String { ProtocolDeckQueue.title(nowMinute: routine?.nowMinute ?? 0) }

    public var deckProgress: ProtocolDeckProgress {
        ProtocolDeckProgress(remaining: deck.count, later: deckLater?.keys.count ?? 0)
    }

    /// The closing card, once nothing is left to answer today. Nil while a card or a later rule waits.
    public var closing: ProtocolDeckClosing? {
        guard let routine, deck.isEmpty, deckLater == nil else { return nil }
        return ProtocolDeckClosing.make(nowMinute: routine.nowMinute, tomorrow: routine.rules,
                                        tomorrowDay: week.adding(1, to: routine.today), locale: week.locale)
    }

    public var isEvening: Bool { (routine?.nowMinute ?? 0) >= ProtocolDeckQueue.eveningMinute }

    /// "Nothing yet." or "Done for now.", in the deck's place while nothing is due and the later list names what is ahead.
    public var waitingLine: String? {
        ProtocolDeckQueue.waitingLine(today: routine?.todayInput, later: deckLater, answering: answering != nil)
    }

    public var autoFillItems: [ProtocolAutoFillItem] { ProtocolAutoFill.items(today: routine?.countedToday, locale: week.locale) }
    /// "4 checked for you", which opens today's day sheet.
    public var checkedForYou: ProtocolCheckedForYou? {
        ProtocolAutoFill.checkedForYou(today: routine?.countedToday, locale: week.locale)
    }

    /// Where the weekly review's row sits and what it says, for the review of the week starting `monday`.
    public func weeklyReviewPlacement(monday: DayIdentity) -> ProtocolWeeklyReviewPlacement? {
        guard let routine else { return nil }
        return ProtocolWeeklyReviewPlacement.make(monday: monday, today: routine.today, nowMinute: routine.nowMinute,
                                                  calendar: week)
    }

    // MARK: Answers

    /// Saves one Yes or No. Returns true when the answer kept a rule, so the screen can play the kept-rule success.
    @discardableResult
    public func answer(_ question: ProtocolDeckQuestion, yes: Bool) async -> Bool {
        await answer(question, choice: yes ? .yes : .no)
    }

    /// Takes the card off the deck while its answer saves. Call it inside the screen's animation, then `answer`.
    public func willAnswer(_ question: ProtocolDeckQuestion) {
        guard !isSaving else { return }
        answering = question.ruleKey
    }

    /// Saves one answer from the deck: Yes, No or Skip today. Returns true when the answer kept a rule.
    @discardableResult
    public func answer(_ question: ProtocolDeckQuestion, choice: ProtocolDeckChoice) async -> Bool {
        guard !isSaving, let day = routine?.today else {
            if answering == question.ruleKey { answering = nil }
            return false
        }
        isSaving = true
        answering = question.ruleKey
        defer { isSaving = false; answering = nil }
        do {
            try await save(question, choice: choice, day: day)
            lastAnswer = ProtocolDeckAnswer(question: question, choice: choice, day: day)
            errorMessage = nil
            await load()
            return choice == .yes && question.ruleKey != nil
        } catch {
            errorMessage = "Loopr could not save that answer. \(error.localizedDescription)"
            await load()
            return false
        }
    }

    /// Takes back the last answer.
    public func undo() async {
        guard !isSaving, let last = lastAnswer else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            switch last.question.kind {
            case .rule(let key, _):
                try await source.clear(key, day: last.day, now: clock())
            }
            lastAnswer = nil
            errorMessage = nil
        } catch {
            errorMessage = "Loopr could not undo that answer. \(error.localizedDescription)"
        }
        await load()
    }

    /// The person's answer in the day sheet, for any day of this week up to today: kept, missed or skipped. Nil goes
    /// back to what the source says, or to no answer for a rule the person checks. A kept manual rule is a tick; every
    /// other answer is an override, which the sheet marks "Changed by you" on a rule a source checks.
    public func setAnswer(_ key: RuleKey, day: DayIdentity, to state: CheckState?) async {
        guard !isSaving, let input = routine?.week.first(where: { $0.day == day }), input.phase != .future,
              let item = input.rules.first(where: { $0.rule.key == key }) else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            switch state {
            case nil: try await source.clear(key, day: day, now: clock())
            case .kept? where item.rule.source == .manual && item.offNightTest == nil:
                try await source.tick(key, day: day, now: clock())
            case .kept?: try await source.override(key, day: day, kept: true, now: clock())
            case .missed?: try await source.override(key, day: day, kept: false, now: clock())
            case .skipped?: try await source.skip(key, day: day, now: clock())
            case .pending?, .unknown?: return
            }
            // A change in the sheet replaces the deck's last answer for that rule, so Undo cannot take back the wrong one.
            if lastAnswer?.question.ruleKey == key && lastAnswer?.day == day { lastAnswer = nil }
            // The same for "Skip the rest of today": Undo leaves a rule the person has since changed by hand alone.
            if let skipped = skippedDay, skipped.day == day, skipped.keys.contains(key) {
                let keys = skipped.keys.filter { $0 != key }
                skippedDay = keys.isEmpty ? nil : ProtocolSkippedDay(day: day, keys: keys)
            }
            errorMessage = nil
        } catch {
            errorMessage = "Loopr could not change that answer. \(error.localizedDescription)"
        }
        await load()
    }

    // MARK: Skip the rest of today (ICP R2-HAB-02)

    /// The rules "Skip the rest of today" would skip now: the open ones the person answers (ICP R3-DES-04).
    public var skipDayOpenKeys: [RuleKey] {
        ProtocolSkipDay.openRules(today: routine?.todayInput, week: routine?.week ?? [], progress: routine?.progress ?? [:])
    }
    /// "Food and the band keep checking their rules.", for the skip's confirm.
    public var skipDayChecking: String? {
        ProtocolSkipDay.checkingLine(today: routine?.todayInput, week: routine?.week ?? [], progress: routine?.progress ?? [:],
                                     locale: week.locale)
    }
    public var skipDayOpenCount: Int { skipDayOpenKeys.count }

    /// Today's skip, for Undo. Nil once the day it was for is over.
    public var skippedToday: ProtocolSkippedDay? {
        guard let skippedDay, skippedDay.day == routine?.today else { return nil }
        return skippedDay
    }

    /// Skips every rule still open today in one go, then reads the day once. What a source or the person already
    /// answered stays. A rule that fails stops the run; the ones before it stay skipped and Undo takes them back.
    public func skipRestOfToday() async {
        guard !isSaving, let day = routine?.today else { return }
        let keys = skipDayOpenKeys
        guard !keys.isEmpty else { return }
        isSaving = true
        defer { isSaving = false }
        var done: [RuleKey] = []
        do {
            for key in keys {
                try await source.skip(key, day: day, now: clock())
                done.append(key)
            }
            errorMessage = nil
        } catch {
            errorMessage = "Loopr could not skip the rest of today. \(error.localizedDescription)"
        }
        // The deck's last answer was for a rule that had an answer, so it is not one of these and its Undo stays.
        skippedDay = done.isEmpty ? nil : ProtocolSkippedDay(day: day, keys: done)
        await load()
    }

    /// Takes back "Skip the rest of today": the rules it skipped are open again.
    public func undoSkipRestOfToday() async {
        guard !isSaving, let skipped = skippedToday else { return }
        isSaving = true
        defer { isSaving = false }
        var left: [RuleKey] = []
        for key in skipped.keys {
            do { try await source.clear(key, day: skipped.day, now: clock()) } catch { left.append(key) }
        }
        if left.isEmpty {
            skippedDay = nil
            errorMessage = nil
        } else {
            skippedDay = ProtocolSkippedDay(day: skipped.day, keys: left)
            errorMessage = "Loopr could not undo all of it. Change the rest in today's day sheet."
        }
        await load()
    }

    // MARK: Experiments

    /// The segment a launch asked for, such as `--loopr-start-at=protocol-experiments`. The screen reads it once.
    public var initialSegment: ProtocolSegment?

    /// Hands the launch's segment to the screen once.
    public func takeInitialSegment() -> ProtocolSegment? {
        defer { initialSegment = nil }
        return initialSegment
    }

    public var experimentData: ProtocolExperimentsData? { content?.experimentData }

    public func experiment(_ id: ExperimentID) -> ProtocolExperimentItem? {
        guard let data = experimentData else { return nil }
        if data.running?.id == id { return data.running }
        return data.finished.first { $0.id == id }
    }

    /// Keep it in my protocol. Returns true when the result is kept afterwards, so the screen can play the kept-rule
    /// success.
    @discardableResult
    public func keep(_ id: ExperimentID) async -> Bool {
        guard !isSaving else { return false }
        isSaving = true
        defer { isSaving = false }
        do {
            try await source.keepExperiment(id, now: clock())
            errorMessage = nil
            await load()
            return experiment(id)?.keptVersion != nil
        } catch {
            errorMessage = "Loopr could not keep this result. \(error.localizedDescription)"
            await load()
            return false
        }
    }

    // MARK: Rules plumbing (LV-07.4)

    func isSavingRules(_ value: Bool) { isSaving = value }
    func sourceVersions() async throws -> [ProtocolVersion] { try await source.versions() }
    func sourceSaveRules(_ rules: [ProtocolRule], reason: String? = nil) async throws -> ProtocolVersion {
        try await source.saveRules(rules, reason: reason, now: clock())
    }
    func sourceProtocolFile() async throws -> ProtocolFile { try await source.protocolFile() }
    func sourceAdoptFile(_ preview: ProtocolImportPreview) async throws -> ProtocolVersion {
        try await source.adoptFile(preview, now: clock())
    }
    func sourceInstallTemplate(_ template: ProtocolTemplate) async throws { try await source.installTemplate(template, now: clock()) }
    func sourceStartFromQuestions(_ habits: [JournalHabit], responses: [JournalHabitResponse]) async throws {
        try await source.startFromQuestions(habits, responses: responses, now: clock())
    }

    private func save(_ question: ProtocolDeckQuestion, choice: ProtocolDeckChoice, day: DayIdentity) async throws {
        switch question.kind {
        case .rule(let key, let ruleSource):
            // The same write as a rule reminder's Done and Skip today (ICP R3-HAB-02).
            try await ProtocolRuleAnswerWrite.save(choice, key: key, ruleSource: ruleSource, day: day, to: source, now: clock())
        }
    }
}

public enum ProtocolTabError: Error, Equatable, LocalizedError, Sendable {
    case questionGone
    case journal(String)
    case experimentsUnavailable
    /// None of the person's questions asks about something they do, so none becomes a rule.
    case noRuleInQuestions

    public var errorDescription: String? {
        switch self {
        case .questionGone: "That question is no longer in your check-in."
        case .journal(let message): message
        case .experimentsUnavailable: "Experiments are not available on this iPhone right now."
        case .noRuleInQuestions: "Your questions are about your day, like travel or a nap, so none of them becomes a rule. Pick a template instead."
        }
    }
}
