import Foundation
import WorkoutKit

public enum ProgramSlotKind: String, CaseIterable, Codable, Sendable {
    case normal, heavy, light
}

/// What a program day is for (R2-VET-12, R1-VET-09). A runner plans easy, hard and long days; a lifter strength days.
public enum ProgramSessionType: String, CaseIterable, Codable, Sendable {
    case easy, hard, long, strength, mobility

    public var title: String {
        switch self {
        case .easy: "Easy"
        case .hard: "Hard"
        case .long: "Long"
        case .strength: "Strength"
        case .mobility: "Mobility"
        }
    }

    /// The type a slot without one gets, from its workout: a cardio workout aimed at zone 4 or 5 is hard, one named
    /// "long" or lasting 75 minutes or more is long, yoga and mobility are mobility, other cardio is easy, and the
    /// rest is strength. Nil template counts as strength, as the grid always has.
    public static func inferred(for template: WorkoutTemplate?) -> ProgramSessionType {
        guard let template else { return .strength }
        let words = Set(template.name.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        if !words.isDisjoint(with: ["mobility", "stretch", "stretching", "yoga"]) { return .mobility }
        switch template.kind {
        case .strength:
            return .strength
        case .cardio:
            guard let cardio = template.cardio else { return words.contains("long") ? .long : .easy }
            if cardio.activity == .yoga || cardio.activity == .mobility || cardio.activity == .pilates { return .mobility }
            if let zone = cardio.zone, zone >= 4 { return .hard }
            if cardio.activity == .hiit { return .hard }
            if words.contains("long") || cardio.minutes >= 75 { return .long }
            return .easy
        }
    }
}

/// One scheduled session in one week of a program.
public struct ProgramSlot: Codable, Equatable, Hashable, Sendable {
    public var weekday: TrainWeekday
    public var templateID: UUID
    public var kind: ProgramSlotKind
    /// Short grid label such as "UA" or "Z2". Two letters at most.
    public var tag: String?
    /// Planned start, in minutes after local midnight (18:00 is 1080). Nil means no set time.
    /// Older payloads have no value and decode as nil.
    public var startMinute: Int?
    /// Easy, hard, long, strength or mobility. Nil means "from the workout" (`ProgramSessionType.inferred`).
    /// Older payloads have no value and decode as nil.
    public var sessionType: ProgramSessionType?

    public init(weekday: TrainWeekday, templateID: UUID, kind: ProgramSlotKind = .normal, tag: String? = nil,
                startMinute: Int? = nil, sessionType: ProgramSessionType? = nil) {
        self.weekday = weekday; self.templateID = templateID; self.kind = kind; self.tag = tag; self.startMinute = startMinute
        self.sessionType = sessionType
    }

    /// The slot's own type, else the one its workout implies.
    public func type(template: WorkoutTemplate?) -> ProgramSessionType {
        sessionType ?? ProgramSessionType.inferred(for: template)
    }

    /// Minutes in a day. A start minute is below this.
    public static let minutesPerDay = 24 * 60

    func validate() throws {
        if let tag, tag.isEmpty || tag.count > 3 { throw TrainError.invalidRecord }
        if let startMinute, !(0..<Self.minutesPerDay).contains(startMinute) { throw TrainError.invalidRecord }
    }
}

public enum MissedSessionRule: String, CaseIterable, Codable, Sendable {
    /// Move the missed session to the next free slot, never two on one day.
    case moveBack
    /// Drop it and carry on.
    case skip
}

public struct ProgramRules: Codable, Equatable, Hashable, Sendable {
    /// Turn the first strength slot of a week light when recent recovery is low.
    public var earlyLightWeek: Bool
    /// Average recovery below this score counts as low.
    public var earlyLightBelowScore: Int
    /// Recovery readings needed in the window before the rule can fire.
    public var earlyLightMinDays: Int
    public var earlyLightWindowDays: Int
    public var missed: MissedSessionRule
    public var calendarExport: Bool

    public init(earlyLightWeek: Bool = true, earlyLightBelowScore: Int = 50, earlyLightMinDays: Int = 5,
                earlyLightWindowDays: Int = 7, missed: MissedSessionRule = .moveBack, calendarExport: Bool = false) {
        self.earlyLightWeek = earlyLightWeek; self.earlyLightBelowScore = earlyLightBelowScore
        self.earlyLightMinDays = earlyLightMinDays; self.earlyLightWindowDays = earlyLightWindowDays
        self.missed = missed; self.calendarExport = calendarExport
    }

    func validate() throws {
        guard (1...100).contains(earlyLightBelowScore), (1...30).contains(earlyLightWindowDays),
              (1...earlyLightWindowDays).contains(earlyLightMinDays) else { throw TrainError.invalidRecord }
    }
}

/// A change the app made to a plan or session because of a rule. Persisted so the
/// person can see what changed and why, and so a rule never fires twice for one week.
public struct ProgramAdjustment: Codable, Equatable, Hashable, Sendable, Identifiable {
    public enum Kind: String, CaseIterable, Codable, Sendable {
        case earlyLightWeek, movedSession, setsRemoved
        /// The early light week rule was checked for `week` and left it as planned. Stored so the week is never decided twice.
        /// `recoveryScore` is the window average, or nil when no day in the window had a reading.
        case earlyLightDeclined
    }

    public let id: UUID
    public var kind: Kind
    /// 1-based program week the change applies to.
    public var week: Int?
    public var weekday: TrainWeekday?
    public var movedToWeekday: TrainWeekday?
    public var setsRemoved: Int?
    /// Plain sentence shown to the person, for example "Recovery averaged 46 over the last 7 days."
    public var reason: String
    public var recoveryScore: Double?
    /// Recovery days that had a reading in the rule's window. Set on early light week decisions.
    public var daysWithReadings: Int?
    /// When the change or decision was made.
    public var createdAt: Date

    public init(id: UUID = UUID(), kind: Kind, week: Int? = nil, weekday: TrainWeekday? = nil,
                movedToWeekday: TrainWeekday? = nil, setsRemoved: Int? = nil, reason: String,
                recoveryScore: Double? = nil, daysWithReadings: Int? = nil, createdAt: Date) {
        self.id = id; self.kind = kind; self.week = week; self.weekday = weekday; self.movedToWeekday = movedToWeekday
        self.setsRemoved = setsRemoved; self.reason = reason; self.recoveryScore = recoveryScore; self.daysWithReadings = daysWithReadings; self.createdAt = createdAt
    }

    func validate() throws {
        guard TrainLimits.validText(reason, limit: TrainLimits.note), createdAt.timeIntervalSince1970.isFinite,
              week.map({ (1...TrainLimits.maxProgramWeeks).contains($0) }) ?? true,
              setsRemoved.map({ (1...TrainLimits.maxSets).contains($0) }) ?? true,
              recoveryScore.map({ $0.isFinite && (0...100).contains($0) }) ?? true,
              daysWithReadings.map({ (0...30).contains($0) }) ?? true else { throw TrainError.invalidRecord }
        switch kind {
        case .earlyLightWeek, .earlyLightDeclined: guard week != nil else { throw TrainError.invalidRecord }
        case .movedSession: guard week != nil, weekday != nil, movedToWeekday != nil, weekday != movedToWeekday else { throw TrainError.invalidRecord }
        case .setsRemoved: guard setsRemoved != nil else { throw TrainError.invalidRecord }
        }
    }
}

public enum ProgramStatus: String, CaseIterable, Codable, Sendable {
    /// Built by the agent or half-edited. A draft never schedules, exports or shows as a plan.
    case draft, active, paused, completed, archived
}

public struct Program: Codable, Equatable, Sendable, Identifiable {
    public let schemaVersion: Int
    public let id: UUID
    /// 0 means never saved. See `WorkoutTemplate.revision`.
    public var revision: Int
    public var name: String
    /// The request the person typed when an agent built the program.
    public var request: String?
    public var source: TrainRecordSource
    public var status: ProgramStatus
    /// Local day (`yyyy-MM-dd`) of week 1. Weeks are counted in blocks of seven days from here.
    public var startDay: String
    /// `weeks[0]` is week 1. Each week holds at most one slot per weekday.
    public var weeks: [[ProgramSlot]]
    public var rules: ProgramRules
    public var adjustments: [ProgramAdjustment]
    /// Templates an agent draft brings with it. They exist only while the program is a draft: accepting
    /// the draft saves the ones its slots use, discarding it drops them. Nil on every other program.
    public var pendingTemplates: [WorkoutTemplate]?
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), revision: Int = 0, name: String, request: String? = nil,
                source: TrainRecordSource = .manual, status: ProgramStatus = .draft, startDay: String,
                weeks: [[ProgramSlot]] = [], rules: ProgramRules = .init(), adjustments: [ProgramAdjustment] = [],
                pendingTemplates: [WorkoutTemplate]? = nil,
                createdAt: Date = Date(timeIntervalSince1970: 0), updatedAt: Date = Date(timeIntervalSince1970: 0),
                schemaVersion: Int = TrainRecordSchema.currentVersion) {
        self.schemaVersion = schemaVersion; self.id = id; self.revision = revision; self.name = name
        self.request = request; self.source = source; self.status = status; self.startDay = startDay
        self.weeks = weeks; self.rules = rules; self.adjustments = adjustments; self.pendingTemplates = pendingTemplates
        self.createdAt = createdAt; self.updatedAt = updatedAt
    }

    /// True for a program that has not been accepted. It never schedules, exports or shows in the week.
    public var isDraft: Bool { status == .draft }

    /// The most pending templates a draft can carry.
    public static let maxPendingTemplates = 20

    public var weekCount: Int { weeks.count }

    /// Template ids the program schedules, so deleting a template can warn first.
    public var templateIDs: Set<UUID> { Set(weeks.flatMap { $0.map(\.templateID) }) }

    public func validate() throws {
        guard schemaVersion >= 1 else { throw TrainError.invalidRecord }
        guard schemaVersion <= TrainLimits.currentSchemaVersion else { throw TrainError.unsupportedVersion(schemaVersion) }
        guard revision >= 0, TrainLimits.validText(name, limit: TrainLimits.name),
              request.map({ TrainLimits.validText($0, limit: TrainLimits.request, allowEmpty: true) }) ?? true,
              TrainDay.isValid(startDay), (1...TrainLimits.maxProgramWeeks).contains(weeks.count),
              createdAt.timeIntervalSince1970.isFinite, updatedAt.timeIntervalSince1970.isFinite else { throw TrainError.invalidRecord }
        try rules.validate()
        for week in weeks {
            guard Set(week.map(\.weekday)).count == week.count else { throw TrainError.invalidRecord }
            for slot in week { try slot.validate() }
        }
        if let pendingTemplates {
            guard status == .draft, !pendingTemplates.isEmpty, pendingTemplates.count <= Self.maxPendingTemplates,
                  Set(pendingTemplates.map(\.id)).count == pendingTemplates.count else { throw TrainError.invalidRecord }
            for template in pendingTemplates { try template.validate() }
        }
        guard Set(adjustments.map(\.id)).count == adjustments.count else { throw TrainError.invalidRecord }
        for adjustment in adjustments {
            try adjustment.validate()
            if let week = adjustment.week, week > weeks.count { throw TrainError.invalidRecord }
        }
    }
}
