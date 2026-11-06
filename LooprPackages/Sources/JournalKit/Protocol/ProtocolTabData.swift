import DomainKit
import Foundation
import RoutineKit

// What the Protocol tab reads. The app's loader fills these from RoutineKit, the Journal and Patterns; everything the
// screen shows is worked out from them by the pure types in this folder, so each rule can be tested without a store.

/// One rule on one day, as the loader read or evaluated it.
public struct ProtocolRuleDay: Equatable, Sendable, Identifiable {
    public var id: RuleKey { rule.key }
    public let rule: ProtocolRule
    /// Nil when no check is stored for the day. The screen never reads that as missed. `skipped` on an off night of a
    /// running test, whatever is stored, unless the person changed it in the day sheet (ICP R1-VET-02).
    public let state: CheckState?
    /// Who decided the check. A person's tick or override is `manual`.
    public let decidedBy: CheckSource?
    public let overriddenByPerson: Bool
    /// What the rule's source measured, kept when the person changed the answer, so the day sheet can say what the
    /// source saw. Nil when nothing was measured; never a stand-in zero.
    public let measuredValue: Double?
    /// The running test's name, such as "magnesium", when this day is one of its off nights for this rule.
    public let offNightTest: String?
    /// The person answered with Done or Skip today on the rule's reminder (R1, ICP round 4 SEN and VET).
    public let answeredFromReminder: Bool

    public init(rule: ProtocolRule, state: CheckState?, decidedBy: CheckSource? = nil, overriddenByPerson: Bool = false,
                measuredValue: Double? = nil, offNightTest: String? = nil, answeredFromReminder: Bool = false) {
        self.rule = rule; self.decidedBy = decidedBy; self.overriddenByPerson = overriddenByPerson
        self.measuredValue = measuredValue; self.offNightTest = offNightTest
        self.answeredFromReminder = answeredFromReminder
        self.state = offNightTest != nil && !overriddenByPerson ? .skipped : state
    }

    public init(rule: ProtocolRule, check: RuleCheck?, offNightTest: String? = nil) {
        self.init(rule: rule, state: check?.state, decidedBy: check?.source, overriddenByPerson: check?.overriddenByPerson ?? false,
                  measuredValue: check?.measuredValue, offNightTest: offNightTest,
                  answeredFromReminder: check?.answeredFrom == .reminder)
    }

    /// Kept or missed: the checks the kept share counts.
    public var isDecided: Bool { state == .kept || state == .missed }
    /// Kept, missed or skipped.
    public var hasAnswer: Bool { isDecided || state == .skipped }
    /// Skipped because a running test keeps the rule off tonight, not by the person.
    public var isSkippedByDesign: Bool { offNightTest != nil && !overriddenByPerson }
}

/// Where a day sits against today and the protocol's start.
public enum ProtocolDayPhase: String, Equatable, Sendable {
    /// Before the protocol existed. Migrated history can still hold checks for it.
    case beforeProtocol
    case past
    case today
    case future
}

public struct ProtocolDayInput: Equatable, Sendable, Identifiable {
    public var id: DayIdentity { day }
    public let day: DayIdentity
    public let phase: ProtocolDayPhase
    /// The rules of the version in force that day, in the version's order.
    public let rules: [ProtocolRuleDay]
    /// The version whose list the day shows, so the day sheet can say when the list changed (ICP R4 Q6). Nil when the
    /// loader did not say.
    public let version: Int?

    public init(day: DayIdentity, phase: ProtocolDayPhase, rules: [ProtocolRuleDay], version: Int? = nil) {
        self.day = day; self.phase = phase; self.rules = rules; self.version = version
    }

    /// The same day with only `rules`.
    func keeping(_ rules: [ProtocolRuleDay]) -> ProtocolDayInput {
        ProtocolDayInput(day: day, phase: phase, rules: rules, version: version)
    }
}

/// The active protocol and two weeks of its checks.
public struct ProtocolRoutineData: Equatable, Sendable {
    public let protocolName: String
    public let version: Int
    public let versionNote: String?
    public let versionCreatedAt: Date
    /// Day 1 is the day the protocol was created.
    public let dayNumber: Int
    /// The newest version's rules, in order.
    public let rules: [ProtocolRule]
    /// Monday to Sunday of this ISO week.
    public let week: [ProtocolDayInput]
    /// Monday to Sunday of last week, from stored checks.
    public let lastWeek: [ProtocolDayInput]
    public let today: DayIdentity
    /// Minutes after local midnight now.
    public let nowMinute: Int
    /// Rules the app evaluated as unknown today, with the reason.
    public let unknownReasons: [RuleKey: UnknownReason]
    /// Free text the person typed, or the author of a file they used.
    public let author: String?
    /// Where the protocol came from, such as a template or a file.
    public let lineage: ProtocolLineage?
    /// The Journal habits that have a rule in any version. Their questions are asked and edited as rules only.
    public let habitRuleIDs: Set<UUID>
    /// How far each rule with a longer period has come: this week's amount or count, or when it is due (ICP R1-VET-08).
    public let progress: [RuleKey: RuleProgress]
    /// Every version of the protocol, for the day sheet's "You changed your rules on 2 Nov." (ICP R4 Q6). Empty when the
    /// source did not read them; the line is then left out.
    public let versions: [ProtocolVersion]
    /// `week` with only the rules each day counts: the ones due that day, as Today lists them, and any rule with an
    /// answer that day (ICP R4 Q3). The rosettes, the hero, "This week", the day sheet and the share pass count these.
    public let countedWeek: [ProtocolDayInput]

    public init(protocolName: String, version: Int, versionNote: String? = nil, versionCreatedAt: Date, dayNumber: Int,
                rules: [ProtocolRule], week: [ProtocolDayInput], lastWeek: [ProtocolDayInput], today: DayIdentity,
                nowMinute: Int, unknownReasons: [RuleKey: UnknownReason] = [:], author: String? = nil,
                lineage: ProtocolLineage? = nil, habitRuleIDs: Set<UUID>? = nil, progress: [RuleKey: RuleProgress] = [:],
                versions: [ProtocolVersion] = []) {
        self.protocolName = protocolName; self.version = version; self.versionNote = versionNote
        self.versionCreatedAt = versionCreatedAt; self.dayNumber = dayNumber; self.rules = rules; self.week = week
        self.lastWeek = lastWeek; self.today = today; self.nowMinute = nowMinute; self.unknownReasons = unknownReasons
        self.author = author; self.lineage = lineage
        self.habitRuleIDs = habitRuleIDs ?? Set(rules.compactMap { RoutineHabitMigration.habitID(forRuleKey: $0.key) })
        self.progress = progress
        self.versions = versions
        countedWeek = ProtocolDueDays.counted(week: week, progress: progress)
    }

    public var todayInput: ProtocolDayInput? { week.first { $0.phase == .today } }
    /// Today with only the rules it counts, the list Today shows.
    public var countedToday: ProtocolDayInput? { countedWeek.first { $0.phase == .today } }
}

public enum ProtocolRoutineState: Equatable, Sendable {
    /// The person has no protocol yet.
    case noProtocol
    case ready(ProtocolRoutineData)
    /// The store could not be read. The message says so in plain words.
    case unavailable(String)
}

/// One found pattern as a list line: "Dinner 4 h before bed" over "Sleep heart rate 5 bpm lower · 30 nights".
public struct ProtocolPatternLine: Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let detail: String
    /// 3 for Strong, 2 for Clear. Early patterns never reach the tab (DEC-06.4).
    public let bars: Int
    /// What the habit is linked to, as a short name: "HRV", "Deep sleep". Nil when the source did not say.
    public let outcome: String?

    public init(id: String, title: String, detail: String, bars: Int, outcome: String? = nil) {
        self.id = id; self.title = title; self.detail = detail; self.bars = min(max(bars, 1), 3); self.outcome = outcome
    }

    public var text: String { detail.isEmpty ? title : "\(title) \u{00B7} \(detail)" }
}

public struct ProtocolPatternsState: Equatable, Sendable {
    /// False when Patterns is switched off for this build. The section is then left out.
    public let isAvailable: Bool
    /// Strongest first.
    public let lines: [ProtocolPatternLine]
    /// Strong and clear patterns in all.
    public let total: Int
    /// The check-in's one line: the first pattern Patterns shows, or how far the nearest one is (ICP R2-HAB-01). Nil
    /// leaves the line out.
    public var signal: ProtocolPatternSignal?

    public init(isAvailable: Bool, lines: [ProtocolPatternLine], total: Int, signal: ProtocolPatternSignal? = nil) {
        self.isAvailable = isAvailable; self.lines = lines; self.total = max(total, lines.count); self.signal = signal
    }

    public static let unavailable = ProtocolPatternsState(isAvailable: false, lines: [], total: 0)
}

/// One Patterns test, for the Experiments segment.
public struct ProtocolExperimentRow: Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let detail: String
    public let isRunning: Bool

    public init(id: String, title: String, detail: String, isRunning: Bool) {
        self.id = id; self.title = title; self.detail = detail; self.isRunning = isRunning
    }
}

public struct ProtocolTabContent: Equatable, Sendable {
    public var routine: ProtocolRoutineState
    public var patterns: ProtocolPatternsState
    /// Nil when Patterns is off, so there is no test list to show.
    public var experiments: [ProtocolExperimentRow]?
    /// The experiments with a design (DEC-12.13). Nil when the source has no experiment store.
    public var designedExperiments: ProtocolExperimentsState?

    public init(routine: ProtocolRoutineState, patterns: ProtocolPatternsState = .unavailable,
                experiments: [ProtocolExperimentRow]? = nil, designedExperiments: ProtocolExperimentsState? = nil) {
        self.routine = routine; self.patterns = patterns; self.experiments = experiments
        self.designedExperiments = designedExperiments
    }

    public var experimentData: ProtocolExperimentsData? {
        if case .ready(let data)? = designedExperiments { return data }
        return nil
    }

    public var routineData: ProtocolRoutineData? {
        if case .ready(let data) = routine { return data }
        return nil
    }
}

/// The app side of the Protocol tab. Every write goes through `RoutineDayEvaluation`.
public protocol ProtocolTabSource: Sendable {
    func load(now: Date) async -> ProtocolTabContent
    /// A manual rule kept.
    func tick(_ key: RuleKey, day: DayIdentity, now: Date) async throws
    /// The person's own decision over whatever a source said.
    func override(_ key: RuleKey, day: DayIdentity, kept: Bool, now: Date) async throws
    /// "Skip today": the rule is neither kept nor missed that day.
    func skip(_ key: RuleKey, day: DayIdentity, now: Date) async throws
    /// Takes back the person's tick, override or skip. The rule goes back to what its source says.
    func clear(_ key: RuleKey, day: DayIdentity, now: Date) async throws
    /// Keep it in my protocol: saves the experiment's rule as the next protocol version. A second call for the same
    /// result writes nothing.
    func keepExperiment(_ id: ExperimentID, now: Date) async throws

    // MARK: Rules (LV-07.4)

    /// Saves the person's edited rules as the next version of the active protocol (`RoutineStore.saveEdit`).
    func saveRules(_ rules: [ProtocolRule], now: Date) async throws -> ProtocolVersion
    /// `saveRules`, with the person's "Why this change?" as the version's note when they gave one (ICP R2-VET-07).
    func saveRules(_ rules: [ProtocolRule], reason: String?, now: Date) async throws -> ProtocolVersion
    /// Every version of the active protocol, version 1 first.
    func versions() async throws -> [ProtocolVersion]
    /// The active protocol's newest version as a protocol file, with its experiment designs. No rebuttals.
    func protocolFile() async throws -> ProtocolFile
    /// First run: the template becomes version 1 (`RoutineStore.installTemplate`).
    func installTemplate(_ template: ProtocolTemplate, now: Date) async throws
    /// "Use this protocol": the file's rules become the next version (`RoutineStore.adoptFile`).
    func adoptFile(_ preview: ProtocolImportPreview, now: Date) async throws -> ProtocolVersion
    /// "Use my questions": the person's Journal questions become version 1 of a new protocol, with their answers as its
    /// history (ICP R3-UPG-5).
    func startFromQuestions(_ habits: [JournalHabit], responses: [JournalHabitResponse], now: Date) async throws
}

public extension ProtocolTabSource {
    func skip(_ key: RuleKey, day: DayIdentity, now: Date) async throws { throw RoutineError.invalidOverride }
    func keepExperiment(_ id: ExperimentID, now: Date) async throws { throw ProtocolTabError.experimentsUnavailable }
    func saveRules(_ rules: [ProtocolRule], now: Date) async throws -> ProtocolVersion { throw RoutineError.missingProtocol }
    /// A source without reasons saves the rules with Loopr's own note.
    func saveRules(_ rules: [ProtocolRule], reason: String?, now: Date) async throws -> ProtocolVersion {
        try await saveRules(rules, now: now)
    }
    func versions() async throws -> [ProtocolVersion] { throw RoutineError.missingProtocol }
    func protocolFile() async throws -> ProtocolFile { throw RoutineError.missingProtocol }
    func installTemplate(_ template: ProtocolTemplate, now: Date) async throws { throw RoutineError.missingProtocol }
    func adoptFile(_ preview: ProtocolImportPreview, now: Date) async throws -> ProtocolVersion { throw RoutineError.missingProtocol }
    func startFromQuestions(_ habits: [JournalHabit], responses: [JournalHabitResponse], now: Date) async throws {
        throw RoutineError.missingProtocol
    }
}

/// The reminders the person turned on for protocol rules, under "Reminders you set" (DEC-07.1). The app implements it
/// with NotificationKit's `ProtocolRuleReminder`; without one the rule editor shows no reminder switch.
public protocol ProtocolRuleReminding: Sendable {
    /// The rules that have a reminder waiting, with its minute of the day.
    func waiting() async -> [RuleKey: Int]
    /// Sets or moves the reminder to the rule's time with its current words. Nil when it is set, else a sentence that
    /// says why not.
    func set(_ rule: ProtocolRule) async -> String?
    func remove(_ key: RuleKey) async
}

/// A protocol file that reached the app, from the share sheet, Files or the Rules segment's importer.
public enum ProtocolFileIncoming: Equatable, Sendable {
    case preview(ProtocolImportPreview)
    /// The file was refused. The message is the validator's own sentence.
    case rejected(String)
}
