import DesignSystem
import DomainKit
import Foundation
import StorageKit

// Editing a protocol (LV-07.4). Every edit is a new immutable version through `RoutineStore.saveVersion`: a rule changed,
// added or removed, a template picked on first run, or a file the person chose to use. Earlier versions stay as saved.

public extension ProtocolRule {
    /// A copy with the given fields replaced. A double optional sets a field to nil: `timeOfDayMinutes: .some(nil)`.
    func with(title: String? = nil, group: RuleGroup? = nil, target: RuleTarget? = nil, timeOfDayMinutes: Int?? = nil,
              source: CheckSource? = nil, isEvening: Bool? = nil, rebuttal: String?? = nil,
              cadence: RuleCadence?? = nil, why: String?? = nil, evidence: String?? = nil) -> ProtocolRule {
        ProtocolRule(key: key, title: title ?? self.title, group: group ?? self.group, target: target ?? self.target,
                     timeOfDayMinutes: timeOfDayMinutes ?? self.timeOfDayMinutes, source: source ?? self.source,
                     isEvening: isEvening ?? self.isEvening, rebuttal: rebuttal ?? self.rebuttal,
                     cadence: cadence ?? self.cadence, why: why ?? self.why, evidence: evidence ?? self.evidence)
    }

    /// The rule as a version stores it: the title trimmed, and a rebuttal only on an evening rule, trimmed, with a
    /// blank one dropped (DEC-12.18). A cadence of every day is stored as no cadence. A blank why or evidence is dropped.
    var normalized: ProtocolRule {
        let reason = rebuttal?.trimmingCharacters(in: .whitespacesAndNewlines)
        let keptReason = isEvening && reason?.isEmpty == false ? reason : nil
        let keptCadence = cadence.flatMap { $0.isEveryDay ? nil : $0 }
        let keptWhy = why?.trimmingCharacters(in: .whitespacesAndNewlines)
        let keptEvidence = evidence?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ProtocolRule(key: key, title: title.trimmingCharacters(in: .whitespacesAndNewlines), group: group,
                            target: target, timeOfDayMinutes: timeOfDayMinutes, source: source, isEvening: isEvening,
                            rebuttal: keptReason, cadence: keptCadence, why: keptWhy?.isEmpty == false ? keptWhy : nil,
                            evidence: keptEvidence?.isEmpty == false ? keptEvidence : nil)
    }

    /// The rule without the person's rebuttal. Files never carry one: it is personal text.
    var withoutRebuttal: ProtocolRule { rebuttal == nil ? self : with(rebuttal: .some(nil)) }
}

public enum ProtocolEditError: Error, Equatable, LocalizedError, Sendable {
    /// The rules are the same as the newest version's, so there is nothing to save.
    case noChange
    /// A template only starts a protocol. The person already has one.
    case protocolExists
    case rebuttalTooLong
    case whyTooLong
    case evidenceTooLong
    /// The person's "Why this change?" line is longer than a why may be.
    case reasonTooLong

    public var errorDescription: String? {
        switch self {
        case .noChange: "Nothing changed, so Loopr kept the current version."
        case .protocolExists: "You already have a protocol. Edit its rules, or import a file to replace them."
        case .rebuttalTooLong: "Keep your reason to \(ProtocolFile.maximumRebuttalLength) characters."
        case .whyTooLong: "Keep why to \(ProtocolFile.maximumWhyLength) characters."
        case .evidenceTooLong: "Keep where this comes from to \(ProtocolFile.maximumEvidenceLength) characters."
        case .reasonTooLong: "Keep the reason for this change to \(ProtocolFile.maximumWhyLength) characters."
        }
    }
}

/// One part of a rule a person can change.
public enum ProtocolRuleField: String, CaseIterable, Sendable {
    case title, group, target, time, evening, reason, source, cadence, why, evidence

    /// "time", for a sentence such as "Changed In bed by 22:30: time and reason."
    public var name: String {
        switch self {
        case .title: "name"
        case .group: "group"
        case .target: "target"
        case .time: "time"
        case .evening: "evening"
        case .reason: "reason"
        case .source: "check source"
        case .cadence: "how often"
        case .why: "why"
        case .evidence: "where it comes from"
        }
    }

    static func changed(from old: ProtocolRule, to new: ProtocolRule) -> [ProtocolRuleField] {
        var fields: [ProtocolRuleField] = []
        if old.title != new.title { fields.append(.title) }
        if old.group != new.group { fields.append(.group) }
        if old.target != new.target { fields.append(.target) }
        if old.timeOfDayMinutes != new.timeOfDayMinutes { fields.append(.time) }
        if old.isEvening != new.isEvening { fields.append(.evening) }
        if old.rebuttal != new.rebuttal { fields.append(.reason) }
        if old.source != new.source { fields.append(.source) }
        if (old.cadence ?? RuleCadence(unit: .day)) != (new.cadence ?? RuleCadence(unit: .day)) { fields.append(.cadence) }
        if old.why != new.why { fields.append(.why) }
        if old.evidence != new.evidence { fields.append(.evidence) }
        return fields
    }
}

public enum ProtocolRuleChange: Equatable, Sendable {
    case added(ProtocolRule)
    case removed(ProtocolRule)
    case changed(before: ProtocolRule, after: ProtocolRule, fields: [ProtocolRuleField])

    public var key: RuleKey {
        switch self {
        case .added(let rule), .removed(let rule): rule.key
        case .changed(_, let after, _): after.key
        }
    }
}

/// What changed between two lists of rules, matched by key.
public enum ProtocolVersionDiff {
    /// Changes and removals in the old order, then additions in the new order. A rule that only moved is not a change.
    public static func changes(from old: [ProtocolRule], to new: [ProtocolRule]) -> [ProtocolRuleChange] {
        let newByKey = Dictionary(new.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        let oldKeys = Set(old.map(\.key))
        var result: [ProtocolRuleChange] = []
        for rule in old {
            guard let next = newByKey[rule.key] else { result.append(.removed(rule)); continue }
            let fields = ProtocolRuleField.changed(from: rule, to: next)
            if !fields.isEmpty { result.append(.changed(before: rule, after: next, fields: fields)) }
        }
        for rule in new where !oldKeys.contains(rule.key) { result.append(.added(rule)) }
        return result
    }

    /// "Changed In bed by 22:30: time and reason. Added Stretch." Nil when nothing changed.
    public static func summary(_ changes: [ProtocolRuleChange]) -> String? {
        guard !changes.isEmpty else { return nil }
        return changes.map { change in
            switch change {
            case .added(let rule): "Added \(rule.title)."
            case .removed(let rule): "Removed \(rule.title)."
            case .changed(let before, let after, let fields):
                fields == [.title]
                    ? "Renamed \(before.title) to \(after.title)."
                    : "Changed \(after.title): \(list(fields.map { name($0, before: before, after: after) }))."
            }
        }.joined(separator: " ")
    }

    /// A field's name, with the amounts for a target that moved: "target 45 to 50 min", so a version note can tell 45
    /// from 50 (ICP R2-OPT-5). A clock target or one without an amount on both sides keeps the plain name.
    public static func name(_ field: ProtocolRuleField, before: ProtocolRule, after: ProtocolRule) -> String {
        guard field == .target, before.target.kind == after.target.kind, before.target.metric == after.target.metric,
              let old = before.target.value, let new = after.target.value, old.isFinite, new.isFinite,
              before.target.metric.flatMap(RoutineMetric.init(rawValue:))?.isTimeOfDay != true else { return field.name }
        let unit = (after.target.unit ?? "").isEmpty ? "" : " \(after.target.unit ?? "")"
        return "\(field.name) \(RoutineRuleTitle.amountText(old)) to \(RoutineRuleTitle.amountText(new))\(unit)"
    }

    /// What a version changed, in one short line for its row in Versions (ICP R2-VET-07): "Changed Magnesium, 300 mg:
    /// time to 21:30 · Added Sauna", with names and times in the locale's clock. Nil when nothing changed.
    public static func rowSummary(_ changes: [ProtocolRuleChange], locale: Locale = .current) -> String? {
        guard !changes.isEmpty else { return nil }
        return changes.map { change in
            switch change {
            case .added(let rule): return "Added \(rule.displayTitle(locale: locale))"
            case .removed(let rule): return "Removed \(rule.displayTitle(locale: locale))"
            case .changed(let before, let after, let fields):
                if fields == [.title] { return "Renamed \(before.displayTitle(locale: locale)) to \(after.displayTitle(locale: locale))" }
                // A name whose time or amount only followed the rule's own is not a rename (ICP R1-OPT-9, R2-OPT-5).
                let shown = fields.filter { $0 != .title || !nameFollowed(before: before, after: after) }
                let parts = shown.map { field -> String in
                    guard field == .time, let minute = after.timeOfDayMinutes else { return name(field, before: before, after: after) }
                    return "time to \(LooprClockFormat.text(minuteOfDay: minute, locale: locale))"
                }
                return "Changed \(after.displayTitle(locale: locale)): \(list(parts))"
            }
        }.joined(separator: " \u{00B7} ")
    }

    /// True when the new name is the old one with its time or amount moved the way the rule's time or target moved.
    static func nameFollowed(before: ProtocolRule, after: ProtocolRule) -> Bool {
        if let old = before.timeOfDayMinutes, let new = after.timeOfDayMinutes,
           RoutineRuleTitle.shiftingTime(in: before.title, by: new - old) == after.title { return true }
        if let old = before.titleMinute, let new = after.titleMinute,
           RoutineRuleTitle.shiftingTime(in: before.title, by: new - old) == after.title { return true }
        if let old = before.target.value, let new = after.target.value, old.isFinite, new.isFinite,
           RoutineRuleTitle.replacingAmount(in: before.title, from: old, to: new) == after.title { return true }
        return false
    }

    /// True when `note` is the one `saveEdit` writes by itself for these changes, so a screen shows it once, as what
    /// changed, and never again as a reason.
    public static func isAutomaticNote(_ note: String?, for changes: [ProtocolRuleChange]) -> Bool {
        guard let note else { return false }
        return note == summary(changes) || note == reorderedNote
    }

    /// The note of a save that only moved rules.
    public static let reorderedNote = "Rules reordered."

    static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: ""
        case 1: items[0]
        default: items.dropLast().joined(separator: ", ") + " and " + (items.last ?? "")
        }
    }
}

/// Two rules that read the same measure, such as a daily and a weekly Zone 2 rule, count the same minutes twice (ICP
/// R3-VET-05). Saving one more such rule asks first.
public enum ProtocolRuleOverlap {
    /// The first rule in `others` that measures what `rule` measures. Nil for a rule the person ticks, which measures
    /// nothing, and when no other rule shares the measure.
    public static func ruleSharingMeasure(with rule: ProtocolRule, among others: [ProtocolRule]) -> ProtocolRule? {
        guard let metric = rule.target.metric, metric != RoutineMetric.done.rawValue else { return nil }
        return others.first { $0.key != rule.key && $0.target.metric == metric }
    }
}

/// The community place for protocol files (DEC-12.5). Loopr only opens it in Safari: no GitHub API call and no network
/// request from the app.
public enum ProtocolCommunity {
    /// The `protocols` folder of the repository the method pages link to (`DataKit.MethodCatalog.repositoryURL`, which
    /// RoutineKit cannot import), which holds the bundled templates and how to add one. There is no separate community
    /// repository.
    public static let repositoryURL = URL(string: "https://github.com/datPascal/Loopr/tree/main/protocols")!
}

public extension RoutineStore {
    /// Saves the person's edit of the newest version as the next version. Its note is the person's `reason` ("Why this
    /// change?", ICP R2-VET-07) when they gave one, else a sentence that says what changed. The rules are stored
    /// normalized (a rebuttal only on an evening rule). Rules equal to the newest version's throw
    /// `ProtocolEditError.noChange` and write nothing.
    @discardableResult
    func saveEdit(protocolID: ProtocolID, rules: [ProtocolRule], reason: String? = nil, at date: Date) throws -> ProtocolVersion {
        let reason = reason?.trimmingCharacters(in: .whitespacesAndNewlines)
        if (reason?.count ?? 0) > ProtocolFile.maximumWhyLength { throw ProtocolEditError.reasonTooLong }
        let normalized = rules.map(\.normalized)
        if normalized.contains(where: { ($0.rebuttal?.count ?? 0) > ProtocolFile.maximumRebuttalLength }) {
            throw ProtocolEditError.rebuttalTooLong
        }
        if normalized.contains(where: { ($0.why?.count ?? 0) > ProtocolFile.maximumWhyLength }) {
            throw ProtocolEditError.whyTooLong
        }
        if normalized.contains(where: { ($0.evidence?.count ?? 0) > ProtocolFile.maximumEvidenceLength }) {
            throw ProtocolEditError.evidenceTooLong
        }
        guard let latest = try latestVersion(protocolID: protocolID) else { throw RoutineError.missingProtocol }
        guard normalized != latest.rules.map(\.normalized) else { throw ProtocolEditError.noChange }
        let note = reason?.isEmpty == false ? reason
            : ProtocolVersionDiff.summary(ProtocolVersionDiff.changes(from: latest.rules, to: normalized))
            ?? ProtocolVersionDiff.reorderedNote
        return try saveVersion(protocolID: protocolID, rules: normalized, note: note, at: date)
    }

    /// First run: makes the template version 1 of a new, active protocol whose lineage names the template. Throws
    /// `ProtocolEditError.protocolExists` when the person already has an active protocol, so a second pick writes
    /// nothing. "Start empty" is named "My protocol" and has no lineage.
    @discardableResult
    func installTemplate(_ template: ProtocolTemplate, at date: Date) throws -> ProtocolVersion {
        let file = try template.load().file
        let routineProtocol = template == .startEmpty
            ? RoutineProtocol(name: "My protocol", createdAt: date)
            : RoutineProtocol(name: file.name, lineage: ProtocolLineage(forkedFromName: template.rawValue, forkedFromVersion: file.version),
                              createdAt: date)
        try routineProtocol.validate()
        let first = try ProtocolVersion(protocolID: routineProtocol.id, number: 1, createdAt: date,
                                        note: "Started from the \(template.title) template.",
                                        rules: file.rules.map { $0.withoutRebuttal.normalized })
        return try database.write { db in
            if try Int.fetchOne(db, sql: "SELECT 1 FROM routine_protocol WHERE is_active = 1") != nil {
                throw ProtocolEditError.protocolExists
            }
            try Self.insertProtocol(routineProtocol, first: first, activate: true, in: db)
            return first
        }
    }

    /// "Use this protocol" on a file the person opened. With an active protocol, the file's rules become its next
    /// version and the protocol takes the file's name and author, with the file as its lineage; check history and
    /// experiments stay with the protocol. An evening rule keeps the rebuttal the person wrote for the same key, and a
    /// rebuttal in the file is never used. Without an active protocol, the file becomes version 1 of a new active one.
    @discardableResult
    func adoptFile(_ preview: ProtocolImportPreview, at date: Date) throws -> ProtocolVersion {
        let file = preview.file
        let lineage = ProtocolLineage(forkedFromName: file.name, forkedFromVersion: file.version)
        return try database.write { db in
            guard let payload = try Data.fetchOne(db, sql: "SELECT payload FROM routine_protocol WHERE is_active = 1") else {
                let created = RoutineProtocol(name: file.name, author: file.author, lineage: lineage, createdAt: date)
                let first = try ProtocolVersion(protocolID: created.id, number: 1, createdAt: date, note: "Imported from a file.",
                                                rules: file.rules.map { $0.withoutRebuttal.normalized })
                try Self.insertProtocol(created, first: first, activate: true, in: db)
                return first
            }
            let current = try Self.decode(RoutineProtocol.self, from: payload)
            guard let latest = try Self.latestVersion(of: current.id, in: db) else { throw RoutineError.corruptRecord }
            let rules = file.rules.map { incoming -> ProtocolRule in
                let own = latest.rule(for: incoming.key).flatMap { $0.isEvening ? $0.rebuttal : nil }
                return incoming.with(rebuttal: .some(incoming.isEvening ? own : nil)).normalized
            }
            let next = try ProtocolVersion(protocolID: current.id, number: latest.number + 1, createdAt: date,
                                           note: "From the file \(file.name).", rules: rules)
            try Self.insert(next, in: db)
            let renamed = RoutineProtocol(id: current.id, name: file.name, author: file.author, lineage: lineage,
                                          createdAt: current.createdAt)
            try renamed.validate()
            try db.execute(sql: "UPDATE routine_protocol SET name = ?, payload = ? WHERE id = ?",
                           arguments: [renamed.name, try Self.encode(renamed), current.id.rawValue.uuidString])
            return next
        }
    }
}
