import DomainKit
import Foundation
import StorageKit

// Moves the Journal's habit questions into protocol version 1, once, with their answer history.
//
// RoutineKit does not import JournalKit, so the app maps `HabitDefinition` and `HabitDayRecord` onto the plain values
// below and this file decides what becomes a rule and what each answer means. Nothing is deleted from the Journal.
//
// Decisions, in one place:
// - A yes/no habit becomes a manual `done` rule whose "kept" is a yes. A habit the person wants to avoid (alcohol,
//   screens in bed) becomes a rule written the other way round ("No alcohol") so that a tick still means kept, and its
//   history flips: a "yes" answer is a miss, a "no" answer is kept.
// - A question about the person's day rather than their conduct (felt sick, travel day, shared bed) is not a rule. It
//   stays a Journal question and its answers stay in the Journal.
// - The four questions the Journal fills in by itself map onto a source and a metric with the same target. "Ate within
//   2 hours of bed" has no metric yet (it needs the bedtime and the last meal together), so it is a manual rule.
// - A skipped answer is not a check. No answer is no check, so nothing is ever turned into a miss or an unknown.
// - Habit answers are yes, no or skipped. The Journal accepts no other kind of habit, so there are no scale answers to
//   carry. Mood and the other wellbeing ratings are not habits and keep being read from the Journal.

public enum JournalHabitPeriod: String, Codable, Sendable {
    /// "Yesterday evening": asked in the morning about the evening before.
    case evening
    case today
}

public enum JournalHabitAnswer: String, Codable, Sendable { case yes, no, skipped }

/// Who gave the answer.
public enum JournalAnswerOrigin: String, Codable, Sendable {
    /// Filled in from Food or Fitness records and not changed since.
    case autoFill
    /// Typed by the person, including a change to an auto-filled answer.
    case person
}

/// A Journal habit definition, reduced to what the migration needs.
public struct JournalHabit: Equatable, Sendable {
    public let id: UUID
    /// The catalog id when the habit is an unchanged preset (same name and question as the catalog). Nil for a custom
    /// or edited habit.
    public let catalogID: String?
    /// True when the Journal fills this question in itself from Food or Fitness.
    public let isAutoFilled: Bool
    public let title: String
    public let period: JournalHabitPeriod
    public let isYesNo: Bool
    public let isArchived: Bool
    public let sortOrder: Int
    public let createdAt: Date

    public init(id: UUID, catalogID: String? = nil, isAutoFilled: Bool = false, title: String, period: JournalHabitPeriod,
                isYesNo: Bool = true, isArchived: Bool = false, sortOrder: Int = 0, createdAt: Date) {
        self.id = id; self.catalogID = catalogID; self.isAutoFilled = isAutoFilled; self.title = title; self.period = period
        self.isYesNo = isYesNo; self.isArchived = isArchived; self.sortOrder = sortOrder; self.createdAt = createdAt
    }
}

public struct JournalHabitResponse: Equatable, Sendable {
    public let habitID: UUID
    public let day: DayIdentity
    public let answer: JournalHabitAnswer
    public let origin: JournalAnswerOrigin
    public let recordedAt: Date

    public init(habitID: UUID, day: DayIdentity, answer: JournalHabitAnswer, origin: JournalAnswerOrigin, recordedAt: Date) {
        self.habitID = habitID; self.day = day; self.answer = answer; self.origin = origin; self.recordedAt = recordedAt
    }
}

public struct SkippedHabit: Equatable, Sendable {
    public enum Reason: String, Sendable { case archived, aboutTheDay, notYesNo }
    public let habitID: UUID
    public let title: String
    public let reason: Reason
}

public struct HabitMigrationPlan: Equatable, Sendable {
    public let rules: [ProtocolRule]
    public let checks: [RuleCheck]
    public let skippedHabits: [SkippedHabit]
    /// Answers the person skipped. They stay in the Journal and make no check.
    public let skippedAnswers: Int
}

public enum JournalHabitMigrationOutcome: Equatable, Sendable {
    case created(protocolID: ProtocolID, rules: Int, checks: Int, skipped: [SkippedHabit])
    /// An earlier run finished, or found a protocol already in place.
    case alreadyDone
    /// A protocol exists, so the habits are not moved. The run is recorded so a deleted protocol does not come back.
    case protocolExists
    /// No active habit question qualifies. Nothing is recorded, so a habit added later is still moved.
    case nothingToMigrate
}

public enum RoutineHabitMigration {
    public static let protocolName = "My protocol"
    public static let versionNote = "Moved over from your Journal habits."
    public static let receiptNamespace = "routine"
    public static let receiptKey = "migration.journal-habits.v1"

    /// The rule key a habit keeps for good. History follows it through every later version.
    public static func ruleKey(forHabit id: UUID) -> RuleKey { RuleKey(rawValue: "habit.\(id.uuidString.lowercased())") }

    // MARK: Mapping

    enum Polarity { case doIt, avoid, context }

    private struct Entry {
        let polarity: Polarity
        let group: RuleGroup
        /// The title when the rule is written as an "avoid".
        var avoidTitle: String? = nil
        /// The source and target the Journal's auto-fill already uses, as the vocabulary writes them.
        var auto: (source: CheckSource, target: RuleTarget)? = nil
    }

    private static let catalog: [String: Entry] = [
        // Conduct to do
        "trained_today": Entry(polarity: .doIt, group: .fitness,
                               auto: (.fitness, RuleTarget(kind: .done, metric: RoutineMetric.workoutMinutes.rawValue, unit: "min"))),
        "read_before_bed": Entry(polarity: .doIt, group: .sleep),
        "meditated": Entry(polarity: .doIt, group: .sleep),
        "stretched": Entry(polarity: .doIt, group: .sleep),
        "dark_room": Entry(polarity: .doIt, group: .sleep),
        "sleep_mask": Entry(polarity: .doIt, group: .sleep),
        "earplugs": Entry(polarity: .doIt, group: .sleep),
        "white_noise": Entry(polarity: .doIt, group: .sleep),
        "hydration_target": Entry(polarity: .doIt, group: .food),
        "sauna": Entry(polarity: .doIt, group: .fitness),
        "cold_exposure": Entry(polarity: .doIt, group: .fitness),
        "outdoor_daylight": Entry(polarity: .doIt, group: .fitness),
        "morning_sunlight": Entry(polarity: .doIt, group: .fitness),
        // Conduct to avoid, written so that kept means the person avoided it
        "alcohol": Entry(polarity: .avoid, group: .food, avoidTitle: "No alcohol",
                         auto: (.food, RuleTarget(kind: .atMost, metric: RoutineMetric.alcoholDrinks.rawValue, value: 0, unit: "drinks"))),
        // The Journal counts caffeine from 14:00 on as late, so the last caffeine must fall by 13:59.
        "late_caffeine": Entry(polarity: .avoid, group: .food, avoidTitle: "No caffeine after 14:00",
                               auto: (.food, RuleTarget(kind: .atMost, metric: RoutineMetric.lastCaffeineTime.rawValue, value: 839, unit: "min"))),
        "meal_within_two_hours": Entry(polarity: .avoid, group: .food, avoidTitle: "No meal in the last 2 hours before bed"),
        "late_meal": Entry(polarity: .avoid, group: .food, avoidTitle: "No meal in the last 3 hours before bed"),
        "late_sugary_snack": Entry(polarity: .avoid, group: .food, avoidTitle: "No sugary snack in the last 3 hours before bed"),
        "screens_in_bed": Entry(polarity: .avoid, group: .sleep, avoidTitle: "No screens in bed"),
        "short_video_before_bed": Entry(polarity: .avoid, group: .sleep, avoidTitle: "No short videos before bed"),
        "screen_before_bed": Entry(polarity: .avoid, group: .sleep, avoidTitle: "No screens in the last hour before bed"),
        "worked_late": Entry(polarity: .avoid, group: .sleep, avoidTitle: "No work in the last 2 hours before bed"),
        "nicotine": Entry(polarity: .avoid, group: .custom, avoidTitle: "No nicotine"),
        "cannabis": Entry(polarity: .avoid, group: .custom, avoidTitle: "No cannabis"),
        "late_intense_exercise": Entry(polarity: .avoid, group: .fitness, avoidTitle: "No intense exercise in the last 3 hours before bed"),
        // Questions about the day, not about conduct
        "feeling_sick": Entry(polarity: .context, group: .custom),
        "warm_bedroom": Entry(polarity: .context, group: .custom),
        "shared_bed": Entry(polarity: .context, group: .custom),
        "away_from_home": Entry(polarity: .context, group: .custom),
        "napped": Entry(polarity: .context, group: .custom),
        "travel_day": Entry(polarity: .context, group: .custom),
        "high_mental_stress": Entry(polarity: .context, group: .custom)
    ]

    /// The catalog ids that become no rule. Exposed so a test can hold the list against the Journal's catalog.
    public static var contextCatalogIDs: Set<String> { Set(catalog.filter { $0.value.polarity == .context }.keys) }
    public static var mappedCatalogIDs: Set<String> { Set(catalog.keys) }

    private struct Mapped {
        let rule: ProtocolRule
        let polarity: Polarity
    }

    private static func map(_ habit: JournalHabit) -> Mapped? {
        let entry = habit.catalogID.flatMap { catalog[$0] }
        if entry?.polarity == .context { return nil }
        let polarity = entry?.polarity ?? .doIt
        var source = CheckSource.manual
        var target = RuleTarget(kind: .done, metric: RoutineMetric.done.rawValue)
        if habit.isAutoFilled, let auto = entry?.auto { source = auto.source; target = auto.target }
        let title = polarity == .avoid ? (entry?.avoidTitle ?? habit.title) : habit.title
        let rule = ProtocolRule(key: ruleKey(forHabit: habit.id), title: title, group: entry?.group ?? .custom, target: target,
                                timeOfDayMinutes: nil, source: source, isEvening: habit.period == .evening)
        return Mapped(rule: rule, polarity: polarity)
    }

    // MARK: Plan

    /// Turns the active habit questions into rules and their answers into checks, all for version 1. Pure.
    public static func plan(habits: [JournalHabit], responses: [JournalHabitResponse]) throws -> HabitMigrationPlan {
        var skipped: [SkippedHabit] = []
        var mapped: [UUID: Mapped] = [:]
        var order: [UUID] = []
        for habit in habits.sorted(by: { ($0.sortOrder, $0.createdAt, $0.id.uuidString) < ($1.sortOrder, $1.createdAt, $1.id.uuidString) }) {
            if habit.isArchived { skipped.append(SkippedHabit(habitID: habit.id, title: habit.title, reason: .archived)); continue }
            if !habit.isYesNo { skipped.append(SkippedHabit(habitID: habit.id, title: habit.title, reason: .notYesNo)); continue }
            guard let item = map(habit) else {
                skipped.append(SkippedHabit(habitID: habit.id, title: habit.title, reason: .aboutTheDay)); continue
            }
            mapped[habit.id] = item
            order.append(habit.id)
        }

        var checks: [RuleCheck] = []
        var skippedAnswers = 0
        var seen = Set<String>()
        for response in responses.sorted(by: { ($0.day.routineDayKey ?? "", $0.habitID.uuidString) < ($1.day.routineDayKey ?? "", $1.habitID.uuidString) }) {
            guard let item = mapped[response.habitID] else { continue }
            guard response.answer != .skipped else { skippedAnswers += 1; continue }
            guard let dayKey = response.day.routineDayKey, seen.insert("\(response.habitID)|\(dayKey)").inserted else { continue }
            let said = response.answer == .yes
            let kept = item.polarity == .avoid ? !said : said
            let state: CheckState = kept ? .kept : .missed
            let ruleSource = item.rule.source
            // The deciding source: Food or Fitness for an answer the Journal filled in, otherwise the person.
            let decidedBy: CheckSource = response.origin == .autoFill ? autoFillSource(for: response.habitID, habits: habits) ?? .manual : .manual
            // A person's answer is theirs: it must survive a later automatic evaluation of that day. A manual rule keeps a
            // "kept" as a plain tick, so only its misses need the mark.
            let byPerson = response.origin == .person && (ruleSource != .manual || state == .missed)
            checks.append(try RuleCheck(ruleKey: item.rule.key, day: response.day, version: 1, state: state, source: decidedBy,
                                        measuredValue: nil, overriddenByPerson: byPerson, recordedAt: response.recordedAt))
        }
        return HabitMigrationPlan(rules: order.compactMap { mapped[$0]?.rule }, checks: checks, skippedHabits: skipped,
                                  skippedAnswers: skippedAnswers)
    }

    /// What filled an answer in: Fitness for "trained today", Food for the other three.
    private static func autoFillSource(for habitID: UUID, habits: [JournalHabit]) -> CheckSource? {
        guard let habit = habits.first(where: { $0.id == habitID }), habit.isAutoFilled else { return nil }
        return habit.catalogID == "trained_today" ? .fitness : .food
    }

    // MARK: After the move (ICP R1-UPG-1)

    // A habit that became a rule lives in one place from then on: the rule. The Journal hides its question and stops
    // offering it for editing, and every answer the person gives the rule is written back to the habit's Journal history,
    // translated through the habit's polarity, so Patterns, Insights and the metric comparisons keep one history that
    // means what it always meant. Nothing from before the move is changed.

    /// The habit a rule came from, for a key made by `ruleKey(forHabit:)`. Nil for every other rule.
    public static func habitID(forRuleKey key: RuleKey) -> UUID? {
        let prefix = "habit."
        guard key.rawValue.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(key.rawValue.dropFirst(prefix.count)))
    }

    /// The habits that have a rule in any version of the active protocol. A rule taken out in a later version keeps its
    /// habit here, so a removed rule does not bring its old Journal question back.
    public static func habitIDsWithRules(store: RoutineStore) throws -> Set<UUID> {
        guard let active = try store.activeProtocol() else { return [] }
        let versions = try store.versions(protocolID: active.routineProtocol.id)
        return Set(versions.flatMap(\.rules).compactMap { habitID(forRuleKey: $0.key) })
    }

    /// True when the habit's rule is written the other way round ("Alcohol?" became "No alcohol"), so a kept rule is a
    /// "no" in the Journal. The same decision the move made.
    public static func isWrittenAsAvoid(_ habit: JournalHabit) -> Bool { map(habit)?.polarity == .avoid }

    /// The Journal answer for a decided rule: kept is "yes" for a habit to do and "no" for a habit to avoid.
    public static func journalAnswer(kept: Bool, avoid: Bool) -> JournalHabitAnswer {
        (avoid ? !kept : kept) ? .yes : .no
    }

    /// What the habit's Journal answer for a day becomes after the person changed the rule's check.
    public enum JournalChange: Equatable, Sendable {
        /// The Journal already says this.
        case keep
        /// Save this answer as the person's.
        case set(JournalHabitAnswer)
        /// Take the person's answer away, so the day is unanswered again (or the Journal's own auto-fill answers it).
        case clear
    }

    /// - Parameters:
    ///   - check: the rule's check for the day as stored now. A person decided it when it is kept or missed and either the
    ///     rule is ticked by hand or the person overrode a source.
    ///   - current: the Journal's answer for the habit that day, if any, and who gave it.
    public static func journalChange(after check: RuleCheck?, avoid: Bool,
                                     current: (answer: JournalHabitAnswer, origin: JournalAnswerOrigin)?) -> JournalChange {
        if let check, check.state == .kept || check.state == .missed, check.source == .manual || check.overriddenByPerson {
            let answer = journalAnswer(kept: check.state == .kept, avoid: avoid)
            if let current, current.answer == answer, current.origin == .person { return .keep }
            return .set(answer)
        }
        // The person's decision is gone. Their own yes or no goes with it; a skip and an auto-filled answer stay.
        guard let current, current.origin == .person, current.answer != .skipped else { return .keep }
        return .clear
    }

    // MARK: Run

    /// False once a run has finished, so the app can skip reading the Journal on every launch.
    public static func isPending(database: StorageDatabase) throws -> Bool {
        _ = try StorageDocumentStore(database: database, namespace: receiptNamespace)
        return try database.read { db in try !receiptExists(in: db) }
    }

    /// Creates the protocol "My protocol" with version 1, the rules and the history, in one transaction together with the
    /// record that this ran. Running again does nothing. A crash leaves either nothing or all of it.
    @discardableResult
    public static func run(database: StorageDatabase, habits: [JournalHabit], responses: [JournalHabitResponse],
                           now: Date) throws -> JournalHabitMigrationOutcome {
        // Makes sure the shared document table exists before the receipt joins the transaction.
        _ = try StorageDocumentStore(database: database, namespace: receiptNamespace)
        let plan = try plan(habits: habits, responses: responses)
        let routineProtocol = RoutineProtocol(name: protocolName, createdAt: now)
        let first = try ProtocolVersion(protocolID: routineProtocol.id, number: 1, createdAt: now, note: versionNote, rules: plan.rules)
        return try database.write { db in
            if try receiptExists(in: db) { return .alreadyDone }
            if try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM routine_protocol") ?? 0 > 0 {
                try writeReceipt(Receipt(outcome: "protocolExists", protocolID: nil, rules: 0, checks: 0, at: now), in: db)
                return .protocolExists
            }
            guard !plan.rules.isEmpty else { return .nothingToMigrate }
            try db.execute(sql: """
                INSERT INTO routine_protocol(id, name, created_at, is_active, payload) VALUES (?, ?, ?, 1, ?)
                """, arguments: [routineProtocol.id.rawValue.uuidString, routineProtocol.name, now.timeIntervalSince1970,
                                 try RoutineStore.encode(routineProtocol)])
            try RoutineStore.insert(first, in: db)
            for check in plan.checks { _ = try RoutineStore.record(check, protocolID: routineProtocol.id, in: db) }
            try writeReceipt(Receipt(outcome: "created", protocolID: routineProtocol.id.rawValue.uuidString,
                                     rules: plan.rules.count, checks: plan.checks.count, at: now), in: db)
            return .created(protocolID: routineProtocol.id, rules: plan.rules.count, checks: plan.checks.count,
                            skipped: plan.skippedHabits)
        }
    }

    private struct Receipt: Codable {
        let outcome: String
        let protocolID: String?
        let rules: Int
        let checks: Int
        /// Seconds since 1970, so the stored document needs no date strategy.
        let at: TimeInterval
        init(outcome: String, protocolID: String?, rules: Int, checks: Int, at date: Date) {
            self.outcome = outcome; self.protocolID = protocolID; self.rules = rules; self.checks = checks
            at = date.timeIntervalSince1970
        }
    }

    private static func receiptExists(in db: Database) throws -> Bool {
        try Int.fetchOne(db, sql: "SELECT 1 FROM \(StorageDocumentStore.documentTable) WHERE namespace = ? AND document_key = ?",
                         arguments: [receiptNamespace, receiptKey]) != nil
    }

    private static func writeReceipt(_ receipt: Receipt, in db: Database) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try db.execute(sql: """
            INSERT INTO \(StorageDocumentStore.documentTable)(namespace, document_key, payload, updated_at) VALUES (?, ?, ?, ?)
            ON CONFLICT(namespace, document_key) DO UPDATE SET payload = excluded.payload, updated_at = excluded.updated_at
            """, arguments: [receiptNamespace, receiptKey, try encoder.encode(receipt), receipt.at])
    }
}
