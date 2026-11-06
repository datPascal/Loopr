import DomainKit
import Foundation

// A protocol is a versioned list of rules. The Swift type is `RoutineProtocol` and the module is `RoutineKit`
// because `ProtocolKit` is the Bluetooth protocol package; screens say "Protocol".

public struct ProtocolID: RawRepresentable, Codable, Hashable, Comparable, Sendable {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
    public init() { rawValue = UUID() }
    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(UUID.self) }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
    public static func < (lhs: ProtocolID, rhs: ProtocolID) -> Bool { lhs.rawValue.uuidString < rhs.rawValue.uuidString }
}

/// The stable identity of a rule. It survives version bumps, so a rule's check history follows the key even when the
/// title, target or time change. Templates and migrated Journal habits choose their own keys.
public struct RuleKey: RawRepresentable, Codable, Hashable, Comparable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
    public static func < (lhs: RuleKey, rhs: RuleKey) -> Bool { lhs.rawValue < rhs.rawValue }
    public var isValid: Bool { !rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

public enum RuleGroup: String, Codable, CaseIterable, Sendable {
    case sleep, food, fitness, supplements, tests, custom
}

/// Who decides whether a rule was kept. `manual` is a tick from the person.
public enum CheckSource: String, Codable, CaseIterable, Sendable {
    case band, food, fitness, appleHealth, manual
}

public enum RuleTargetKind: String, Codable, CaseIterable, Sendable {
    /// Done or not done. No value.
    case done
    case atLeast
    case atMost
    case exactly
}

/// What a rule asks for. `metric` names the measured quantity ("protein", "zone2Minutes", "bedtime") so a later step can
/// evaluate it against a source. A time-of-day target stores minutes since midnight in `value`.
public struct RuleTarget: Codable, Equatable, Sendable {
    public let kind: RuleTargetKind
    public let metric: String?
    public let value: Double?
    public let unit: String?

    public init(kind: RuleTargetKind, metric: String? = nil, value: Double? = nil, unit: String? = nil) {
        self.kind = kind; self.metric = metric; self.value = value; self.unit = unit
    }

    public static let done = RuleTarget(kind: .done)

    var isValid: Bool {
        switch kind {
        case .done: value == nil || value?.isFinite == true
        case .atLeast, .atMost, .exactly: value?.isFinite == true
        }
    }
}

/// A day of the week for a rule kept on chosen days. Payloads and files store the three-letter name, Monday first.
public enum RuleWeekday: String, Codable, CaseIterable, Comparable, Sendable {
    case monday = "mon", tuesday = "tue", wednesday = "wed", thursday = "thu", friday = "fri", saturday = "sat", sunday = "sun"

    /// Monday is 1 and Sunday is 7, as ISO 8601 counts.
    public var isoNumber: Int { (Self.allCases.firstIndex(of: self) ?? 0) + 1 }

    public static func < (lhs: RuleWeekday, rhs: RuleWeekday) -> Bool { lhs.isoNumber < rhs.isoNumber }

    /// The day for a `Calendar` weekday number, where Sunday is 1 and Saturday is 7.
    public init?(calendarWeekday: Int) {
        guard (1...7).contains(calendarWeekday) else { return nil }
        self = Self.allCases[(calendarWeekday + 5) % 7]
    }

    /// The weekday of a calendar day, the same in every time zone. Nil for a date that does not exist.
    public init?(day: DayIdentity) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard day.routineDayKey != nil,
              let date = calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day)) else { return nil }
        self.init(calendarWeekday: calendar.component(.weekday, from: date))
    }
}

/// How often a rule is due. A rule with no cadence is due every day. "Zone 2, 150 minutes a week" is one week, and a
/// blood test every six months is six months. A daily rule can be kept on chosen weekdays only ("Mon, Wed, Fri"), and a
/// weekly one can ask for a number of times ("3 times a week"). Rules checked by a source over a longer period are
/// scored over that period by the weekly dose and the tests screens; the day view leaves them unknown, and a manual tick
/// works on any day. A rule on chosen days is checked on those days only (`ProtocolRule.isDue(on:)`).
public struct RuleCadence: Codable, Hashable, Sendable {
    public enum Unit: String, Codable, CaseIterable, Sendable { case day, week, month }
    public static let largestEvery = 24
    /// "N times a week" runs from 2 to 6. Once is "each week" and seven is every day.
    public static let timesPerWeekRange = 2...6

    public let unit: Unit
    public let every: Int
    /// The weekdays a daily rule is due on, Monday first. Empty means every day. Only a cadence of one day has days.
    public let days: [RuleWeekday]
    /// How many times a week the rule asks for, as in "3 times a week". Nil means once a period. Only a cadence of one
    /// week has a count.
    public let timesPerWeek: Int?

    public init(unit: Unit, every: Int = 1) {
        self.unit = unit; self.every = every; days = []; timesPerWeek = nil
    }

    private init(unit: Unit, every: Int, days: [RuleWeekday], timesPerWeek: Int?) {
        self.unit = unit; self.every = every; self.days = days; self.timesPerWeek = timesPerWeek
    }

    /// Due on the chosen weekdays only. None or all seven is every day.
    public static func on(_ days: Set<RuleWeekday>) -> RuleCadence {
        RuleCadence(unit: .day, every: 1, days: Self.normalized(Array(days)), timesPerWeek: nil)
    }

    /// "3 times a week". Once is each week, and seven or more is every day.
    public static func timesAWeek(_ count: Int) -> RuleCadence {
        if count >= 7 { return RuleCadence(unit: .day) }
        return RuleCadence(unit: .week, every: 1, days: [], timesPerWeek: count <= 1 ? nil : count)
    }

    /// Every day, with no chosen days.
    public var isEveryDay: Bool { unit == .day && every == 1 && days.isEmpty }
    /// Checked day by day: every day, or on chosen weekdays.
    public var isDaily: Bool { unit == .day && every == 1 }
    /// True for a rule kept on chosen weekdays.
    public var hasChosenDays: Bool { !days.isEmpty }

    var isValid: Bool {
        guard (1...Self.largestEvery).contains(every) else { return false }
        if !days.isEmpty, !isDaily { return false }
        if let timesPerWeek, unit != .week || every != 1 || !Self.timesPerWeekRange.contains(timesPerWeek) { return false }
        return true
    }

    /// Monday first, each day once, and all seven days as none.
    static func normalized(_ days: [RuleWeekday]) -> [RuleWeekday] {
        let unique = Set(days)
        return unique.count == RuleWeekday.allCases.count ? [] : unique.sorted()
    }

    private enum CodingKeys: String, CodingKey { case unit, every, days, timesPerWeek }

    /// A payload saved before chosen days and counts existed has neither, and decodes as it was.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        unit = try container.decode(Unit.self, forKey: .unit)
        every = try container.decode(Int.self, forKey: .every)
        days = Self.normalized(try container.decodeIfPresent([RuleWeekday].self, forKey: .days) ?? [])
        timesPerWeek = try container.decodeIfPresent(Int.self, forKey: .timesPerWeek)
    }

    /// Writes `days` and `timesPerWeek` only when set, so a plain cadence keeps its old shape.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(unit, forKey: .unit)
        try container.encode(every, forKey: .every)
        if !days.isEmpty { try container.encode(days, forKey: .days) }
        try container.encodeIfPresent(timesPerWeek, forKey: .timesPerWeek)
    }
}

public struct ProtocolRule: Codable, Equatable, Identifiable, Sendable {
    public var id: RuleKey { key }
    public let key: RuleKey
    public let title: String
    public let group: RuleGroup
    public let target: RuleTarget
    /// Minutes since local midnight, 0 to 1439. Nil means any time of day.
    public let timeOfDayMinutes: Int?
    public let source: CheckSource
    /// Evening rules can carry a rebuttal the person wrote in the morning (DEC-12.18).
    public let isEvening: Bool
    public let rebuttal: String?
    /// Nil means every day.
    public let cadence: RuleCadence?
    /// Why the rule is on the list, in one plain sentence, such as a template's reason. Unlike the rebuttal it travels
    /// in protocol files, so a template or a shared protocol can say why each rule is there. A template's why never
    /// names the rule's number, so it stays true when the person changes the target (ICP R2-VET-05).
    public let why: String?
    /// Where the rule comes from: the study or guideline behind it, in a sentence or three. The why stays short and the
    /// source sits here, shown as "Where this comes from" (ICP R2-NEW-07, R2-DES-02). It travels in files like `why`.
    public let evidence: String?

    public init(key: RuleKey, title: String, group: RuleGroup = .custom, target: RuleTarget = .done,
                timeOfDayMinutes: Int? = nil, source: CheckSource = .manual,
                isEvening: Bool = false, rebuttal: String? = nil, cadence: RuleCadence? = nil, why: String? = nil,
                evidence: String? = nil) {
        self.key = key; self.title = title; self.group = group; self.target = target
        self.timeOfDayMinutes = timeOfDayMinutes; self.source = source
        self.isEvening = isEvening; self.rebuttal = rebuttal; self.cadence = cadence; self.why = why
        self.evidence = evidence
    }

    private enum CodingKeys: String, CodingKey {
        case key, title, group, target, timeOfDayMinutes, source, isEvening, rebuttal, cadence, why, evidence
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(RuleKey.self, forKey: .key)
        title = try container.decode(String.self, forKey: .title)
        group = try container.decode(RuleGroup.self, forKey: .group)
        target = try container.decode(RuleTarget.self, forKey: .target)
        timeOfDayMinutes = try container.decodeIfPresent(Int.self, forKey: .timeOfDayMinutes)
        source = try container.decode(CheckSource.self, forKey: .source)
        isEvening = try container.decodeIfPresent(Bool.self, forKey: .isEvening) ?? false
        rebuttal = try container.decodeIfPresent(String.self, forKey: .rebuttal)
        cadence = try container.decodeIfPresent(RuleCadence.self, forKey: .cadence)
        why = try container.decodeIfPresent(String.self, forKey: .why)
        evidence = try container.decodeIfPresent(String.self, forKey: .evidence)
    }

    /// The longest a why line runs under a card or a row: two or three caption lines on a 6.1 inch phone.
    public static let shortLineLimit = 120

    /// A why for a card or a row that never ends mid-word (ICP R2-SEN-05, R2-DES-02). Text that fits comes back whole.
    /// Longer text keeps as many whole sentences as fit, and with none that fits it stops at the last whole word with an
    /// ellipsis. Nil for blank text.
    public static func shortLine(_ text: String?, limit: Int = shortLineLimit) -> String? {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.count > limit else { return trimmed }
        var end: String.Index?
        var index = trimmed.startIndex
        while index < trimmed.endIndex {
            let next = trimmed.index(after: index)
            if ".?!".contains(trimmed[index]), next == trimmed.endIndex || trimmed[next] == " " {
                guard trimmed.distance(from: trimmed.startIndex, to: next) <= limit else { break }
                end = next
            }
            index = next
        }
        if let end { return String(trimmed[..<end]) }
        let head = trimmed.prefix(limit)
        let words = head.lastIndex(of: " ").map { head[..<$0] } ?? head
        return words.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:")) + "\u{2026}"
    }

    func validate() throws {
        guard key.isValid, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, target.isValid else {
            throw RoutineError.invalidRule(key)
        }
        if let timeOfDayMinutes, !(0..<1_440).contains(timeOfDayMinutes) { throw RoutineError.invalidRule(key) }
        if let cadence, !cadence.isValid { throw RoutineError.invalidRule(key) }
    }
}

/// Where a protocol came from, such as "fork of sleep-first" at version 3.
public struct ProtocolLineage: Codable, Equatable, Sendable {
    public let forkedFromName: String
    public let forkedFromVersion: Int?
    /// Where the original lives, for a protocol shared on the web.
    public let url: String?
    public init(forkedFromName: String, forkedFromVersion: Int? = nil, url: String? = nil) {
        self.forkedFromName = forkedFromName; self.forkedFromVersion = forkedFromVersion; self.url = url
    }
}

public struct RoutineProtocol: Codable, Equatable, Identifiable, Sendable {
    public let id: ProtocolID
    public let name: String
    public let author: String?
    public let lineage: ProtocolLineage?
    public let createdAt: Date

    public init(id: ProtocolID = ProtocolID(), name: String, author: String? = nil,
                lineage: ProtocolLineage? = nil, createdAt: Date) {
        self.id = id; self.name = name; self.author = author; self.lineage = lineage; self.createdAt = createdAt
    }

    func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RoutineError.invalidProtocol }
    }
}

/// One saved state of a protocol. Every property is a `let` and the store never rewrites a saved version, so a version
/// read next year equals the one saved today. A change is a new version with the next number.
public struct ProtocolVersion: Codable, Equatable, Identifiable, Sendable {
    public var id: String { "\(protocolID.rawValue.uuidString).\(number)" }
    public let protocolID: ProtocolID
    /// Starts at 1.
    public let number: Int
    public let createdAt: Date
    public let note: String?
    /// In the order the person sees them.
    public let rules: [ProtocolRule]

    public init(protocolID: ProtocolID, number: Int, createdAt: Date, note: String? = nil, rules: [ProtocolRule]) throws {
        self.protocolID = protocolID; self.number = number; self.createdAt = createdAt
        self.note = note; self.rules = rules
        try validate()
    }

    private enum CodingKeys: String, CodingKey { case protocolID, number, createdAt, note, rules }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolID = try container.decode(ProtocolID.self, forKey: .protocolID)
        number = try container.decode(Int.self, forKey: .number)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        note = try container.decodeIfPresent(String.self, forKey: .note)
        rules = try container.decode([ProtocolRule].self, forKey: .rules)
        try validate()
    }

    public func rule(for key: RuleKey) -> ProtocolRule? { rules.first { $0.key == key } }

    private func validate() throws {
        guard number >= 1 else { throw RoutineError.invalidVersionNumber }
        for rule in rules { try rule.validate() }
        guard Set(rules.map(\.key)).count == rules.count else { throw RoutineError.duplicateRuleKey }
    }
}

/// The outcome of one rule on one day. `unknown` means no source could say; it is never counted as missed. `skipped`
/// is the person's "Skip today", such as a sick day: neither kept nor missed, and left out of every kept share. A
/// payload written before `skipped` existed holds one of the other four and decodes unchanged.
public enum CheckState: String, Codable, CaseIterable, Sendable {
    case kept, missed, pending, unknown, skipped
}

/// Where the person gave an answer when it was not on one of Loopr's screens.
public enum AnswerOrigin: String, Codable, CaseIterable, Sendable {
    /// Done or Skip today on a rule's reminder, without opening Loopr (ICP round 4, SEN and VET).
    case reminder
}

public struct RuleCheck: Codable, Equatable, Sendable {
    public let ruleKey: RuleKey
    public let day: DayIdentity
    /// The version the rule belonged to when the check was decided.
    public let version: Int
    public let state: CheckState
    /// The source that decided the state. A person's override makes this `manual`.
    public let source: CheckSource
    /// What the source measured. Nil when nothing was measured; never a stand-in zero. Always nil for `unknown`.
    public let measuredValue: Double?
    public let overriddenByPerson: Bool
    public let recordedAt: Date
    /// Set when the person answered from a rule reminder. Nil for an answer in the app, for a source's check, and for
    /// every check saved before Loopr kept it.
    public let answeredFrom: AnswerOrigin?

    public init(ruleKey: RuleKey, day: DayIdentity, version: Int, state: CheckState, source: CheckSource,
                measuredValue: Double? = nil, overriddenByPerson: Bool = false, recordedAt: Date,
                answeredFrom: AnswerOrigin? = nil) throws {
        self.ruleKey = ruleKey; self.day = day; self.version = version; self.state = state; self.source = source
        self.measuredValue = measuredValue; self.overriddenByPerson = overriddenByPerson; self.recordedAt = recordedAt
        self.answeredFrom = answeredFrom
        try validate()
    }

    private enum CodingKeys: String, CodingKey {
        case ruleKey, day, version, state, source, measuredValue, overriddenByPerson, recordedAt, answeredFrom
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ruleKey = try container.decode(RuleKey.self, forKey: .ruleKey)
        day = try container.decode(DayIdentity.self, forKey: .day)
        version = try container.decode(Int.self, forKey: .version)
        state = try container.decode(CheckState.self, forKey: .state)
        source = try container.decode(CheckSource.self, forKey: .source)
        measuredValue = try container.decodeIfPresent(Double.self, forKey: .measuredValue)
        overriddenByPerson = try container.decode(Bool.self, forKey: .overriddenByPerson)
        recordedAt = try container.decode(Date.self, forKey: .recordedAt)
        // Absent in older payloads; a value a newer build wrote that this one does not know reads as nil.
        answeredFrom = try? container.decodeIfPresent(AnswerOrigin.self, forKey: .answeredFrom)
        try validate()
    }

    private func validate() throws {
        guard ruleKey.isValid, version >= 1, day.routineDayKey != nil else { throw RoutineError.invalidCheck }
        if let measuredValue {
            guard measuredValue.isFinite, state != .unknown else { throw RoutineError.invalidCheck }
        }
    }
}

public extension DayIdentity {
    /// The `YYYY-MM-DD` key checks are stored under. Nil for a date that does not exist.
    var routineDayKey: String? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard (1...9_999).contains(year),
              let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return nil }
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        guard parts.year == year, parts.month == month, parts.day == day else { return nil }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    init?(routineDayKey: String) {
        let values = routineDayKey.split(separator: "-", omittingEmptySubsequences: false).compactMap { Int($0) }
        guard values.count == 3, routineDayKey.count == 10 else { return nil }
        let day = DayIdentity(year: values[0], month: values[1], day: values[2])
        guard day.routineDayKey == routineDayKey else { return nil }
        self = day
    }
}

public enum RoutineError: Error, Equatable, LocalizedError, Sendable {
    case invalidProtocol
    case invalidRule(RuleKey)
    case duplicateRuleKey
    case invalidVersionNumber
    case invalidCheck
    case missingProtocol
    case missingVersion
    case unknownRule(RuleKey)
    case invalidOverride
    case notManualRule(RuleKey)
    case corruptRecord

    public var errorDescription: String? {
        switch self {
        case .invalidProtocol: "Give the protocol a name."
        case .invalidRule(let key): "The rule \(key.rawValue) needs a title, a valid target and a time between 00:00 and 23:59."
        case .duplicateRuleKey: "Two rules share one key."
        case .invalidVersionNumber: "A version number starts at 1."
        case .invalidCheck: "That check is not valid."
        case .missingProtocol: "This protocol is no longer available."
        case .missingVersion: "This version is no longer available."
        case .unknownRule(let key): "The rule \(key.rawValue) is not part of this version."
        case .invalidOverride: "A person can mark a rule kept, not kept or skipped."
        case .notManualRule(let key): "The rule \(key.rawValue) is checked by a source, so you cannot tick it."
        case .corruptRecord: "A stored protocol record could not be read."
        }
    }
}
