import DomainKit
import Foundation
import RoutineKit
import StorageKit
import TrainKit

/// The kinds of check the Tests group of a protocol asks for. A rule is read by its key, its title and its target
/// metric; anything Loopr does not recognise is a custom test and keeps the person's own title.
public enum LabTestKind: String, Equatable, Sendable {
    case bloodTest, grip, balance, dentist, skin, custom

    public static func classify(_ rule: ProtocolRule) -> LabTestKind {
        let text = [rule.key.rawValue, rule.title, rule.target.metric ?? ""].joined(separator: " ").lowercased()
        func has(_ words: [String]) -> Bool { words.contains { text.contains($0) } }
        if has(["grip"]) { return .grip }
        if has(["balance"]) { return .balance }
        if has(["blood test", "blood-test", "bloodtest", "bloodwork", "blood work", "blood panel", "lab test", "lab-test"]) { return .bloodTest }
        if has(["dentist", "dental"]) { return .dentist }
        if has(["skin check", "skin-check", "dermat"]) { return .skin }
        return .custom
    }

    /// Whether the person ticks it by hand. The blood test reads lab reports and grip and balance read Fitness results.
    public var isManual: Bool { self == .dentist || self == .skin || self == .custom }
}

public enum LabTestLastDoneSource: Equatable, Sendable {
    case labReport
    case capacityResult
    case protocolTick
}

public enum LabTestStatus: Equatable, Sendable {
    /// No result and no tick yet, so there is no date to count from.
    case notDoneYet
    case due
    case upcoming
}

/// One test of the active protocol with when it was last done and when it is next due.
public struct LabTestDue: Identifiable, Equatable, Sendable {
    public let ruleKey: RuleKey
    public let ruleTitle: String
    public let kind: LabTestKind
    public let cadence: RuleCadence
    public let lastDone: Date?
    public let lastDoneSource: LabTestLastDoneSource?
    public let nextDue: Date?
    public let status: LabTestStatus
    public var id: String { ruleKey.rawValue }

    /// The name the list shows: "Blood test", "Grip test", or the person's own title for a custom test.
    public var title: String {
        switch kind {
        case .bloodTest: "Blood test"
        case .grip: "Grip test"
        case .balance: "Balance test"
        case .dentist: "Dentist check"
        case .skin: "Skin check"
        case .custom: ruleTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// "Every 3 months".
    public var cadenceText: String { LabTestDue.cadenceText(cadence) }

    public static func cadenceText(_ cadence: RuleCadence) -> String {
        let unit = cadence.unit.rawValue
        return cadence.every == 1 ? "Every \(unit)" : "Every \(cadence.every) \(unit)s"
    }

    /// Where the last date came from, in words.
    public var lastDoneSourceText: String? {
        switch lastDoneSource {
        case .labReport?: "From your lab reports"
        case .capacityResult?: "From your Fitness results"
        case .protocolTick?: "From your tick"
        case nil: nil
        }
    }
}

/// The tests split into those due now and those coming up.
public struct LabTestsDueSummary: Equatable, Sendable {
    public let due: [LabTestDue]
    public let upcoming: [LabTestDue]

    public static let empty = LabTestsDueSummary(due: [], upcoming: [])

    public init(due: [LabTestDue], upcoming: [LabTestDue]) {
        self.due = due
        self.upcoming = upcoming
    }

    public var all: [LabTestDue] { due + upcoming }
    public var isEmpty: Bool { due.isEmpty && upcoming.isEmpty }
}

/// What the dates are worked out from.
public struct LabTestsDueInputs: Equatable, Sendable {
    public var rules: [ProtocolRule]
    public var latestReportDate: Date?
    public var latestGripDate: Date?
    public var latestBalanceDate: Date?
    /// The day of the newest kept check per rule, as a date.
    public var ticks: [RuleKey: Date]

    public init(rules: [ProtocolRule], latestReportDate: Date? = nil, latestGripDate: Date? = nil,
                latestBalanceDate: Date? = nil, ticks: [RuleKey: Date] = [:]) {
        self.rules = rules
        self.latestReportDate = latestReportDate
        self.latestGripDate = latestGripDate
        self.latestBalanceDate = latestBalanceDate
        self.ticks = ticks
    }
}

public enum LabTestsDueBuilder {
    /// A rule counts when it is in the Tests group and has a cadence. The last done date is the newest of the
    /// source's date (lab report for blood tests, capacity result for grip and balance) and the person's tick.
    public static func make(_ inputs: LabTestsDueInputs, now: Date, calendar: Calendar) -> LabTestsDueSummary {
        var due: [LabTestDue] = []
        var upcoming: [LabTestDue] = []
        for rule in inputs.rules where rule.group == .tests {
            guard let cadence = rule.cadence else { continue }
            let kind = LabTestKind.classify(rule)
            var last: Date?
            var source: LabTestLastDoneSource?
            switch kind {
            case .bloodTest: last = inputs.latestReportDate; source = .labReport
            case .grip: last = inputs.latestGripDate; source = .capacityResult
            case .balance: last = inputs.latestBalanceDate; source = .capacityResult
            case .dentist, .skin, .custom: break
            }
            if last == nil { source = nil }
            if let tick = inputs.ticks[rule.key], last.map({ tick > $0 }) ?? true { last = tick; source = .protocolTick }

            let next = last.flatMap { next(after: $0, cadence: cadence, calendar: calendar) }
            let status: LabTestStatus
            if let next {
                status = calendar.startOfDay(for: next) <= calendar.startOfDay(for: now) ? .due : .upcoming
            } else {
                status = .notDoneYet
            }
            let item = LabTestDue(ruleKey: rule.key, ruleTitle: rule.title, kind: kind, cadence: cadence, lastDone: last,
                                  lastDoneSource: source, nextDue: next, status: status)
            if status == .upcoming { upcoming.append(item) } else { due.append(item) }
        }
        // Dated tests first, the oldest date first, then the ones that have no date yet in the protocol's order.
        let dated = due.filter { $0.nextDue != nil }.sorted { ($0.nextDue ?? .distantFuture) < ($1.nextDue ?? .distantFuture) }
        let undated = due.filter { $0.nextDue == nil }
        return LabTestsDueSummary(due: dated + undated,
                                  upcoming: upcoming.sorted { ($0.nextDue ?? .distantFuture) < ($1.nextDue ?? .distantFuture) })
    }

    public static func next(after date: Date, cadence: RuleCadence, calendar: Calendar) -> Date? {
        let component: Calendar.Component = switch cadence.unit {
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        }
        return calendar.date(byAdding: component, value: cadence.every, to: date)
    }

    /// Reads the stores and works out the tests. Nothing is active, nothing is due.
    public static func load(routine: RoutineStore, labs: LabStore, capacity: CapacityStore, now: Date,
                            calendar: Calendar) throws -> LabTestsDueSummary {
        guard let active = try routine.activeProtocol() else { return .empty }
        let rules = active.latestVersion.rules.filter { $0.group == .tests && $0.cadence != nil }
        guard !rules.isEmpty else { return .empty }
        var ticks: [RuleKey: Date] = [:]
        for rule in rules {
            let kept = try routine.history(protocolID: active.routineProtocol.id, ruleKey: rule.key).filter { $0.state == .kept }
            if let last = kept.last, let date = date(of: last.day, calendar: calendar) { ticks[rule.key] = date }
        }
        let inputs = LabTestsDueInputs(
            rules: rules,
            latestReportDate: try labs.reports().first?.collectedAt,
            latestGripDate: try capacity.latest(for: .grip)?.recordedAt,
            latestBalanceDate: try capacity.latest(for: .oneLegBalance)?.recordedAt,
            ticks: ticks)
        return make(inputs, now: now, calendar: calendar)
    }

    /// Ticks the test done today. The tick is a manual check of the rule on today's date.
    public static func markDone(ruleKey: RuleKey, routine: RoutineStore, now: Date, calendar: Calendar) throws {
        guard let active = try routine.activeProtocol() else { throw RoutineError.missingProtocol }
        let parts = calendar.dateComponents([.era, .year, .month, .day], from: now)
        let day = DayIdentity(era: parts.era ?? 1, year: parts.year ?? 0, month: parts.month ?? 0, day: parts.day ?? 0)
        try routine.overrideCheck(protocolID: active.routineProtocol.id, ruleKey: ruleKey, day: day, state: .kept, at: now)
    }

    static func date(of day: DayIdentity, calendar: Calendar) -> Date? {
        calendar.date(from: DateComponents(era: day.era, year: day.year, month: day.month, day: day.day, hour: 12))
    }
}
