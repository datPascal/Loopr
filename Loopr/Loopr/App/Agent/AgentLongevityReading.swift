import AIKit
import Foundation

// LV-09: the readers and plain rows behind the longevity tools. Like the older readers they hold no storage types,
// so tests can supply rows directly. Nothing here checks Your data. `AgentReaders` does, before and after each read.
// Every protocol has an empty default, so a source that predates these tools still compiles and reads nothing.

// MARK: Protocol, adherence and experiments (Journal answers)

nonisolated struct AgentProtocolRuleRow: Equatable, Sendable {
    let key: String
    let title: String
    /// `sleep`, `food`, `fitness`, `supplements`, `tests` or `custom`.
    let group: String
    /// Who checks the rule: `band`, `food`, `fitness`, `appleHealth` or `manual`.
    let source: String
    /// `done`, `atLeast`, `atMost` or `exactly`.
    let targetKind: String
    let targetMetric: String?
    let targetValue: Double?
    let targetUnit: String?
    /// Local `HH:mm`. Nil means any time of day.
    let time: String?
    let evening: Bool
}

nonisolated struct AgentProtocolVersionRow: Equatable, Sendable {
    let number: Int
    /// The local day the version was saved.
    let day: String
}

nonisolated struct AgentProtocolRow: Equatable, Sendable {
    let name: String
    let version: Int
    let versionDay: String
    let rules: [AgentProtocolRuleRow]
    /// Version 1 first. Numbers and dates only.
    let versions: [AgentProtocolVersionRow]
}

nonisolated struct AgentAdherenceCheck: Equatable, Sendable {
    let ruleKey: String
    let title: String
    /// `kept`, `missed`, `pending` or `unknown`.
    let state: String
}

nonisolated struct AgentAdherenceDay: Equatable, Sendable {
    let day: String
    let version: Int
    let checks: [AgentAdherenceCheck]
}

nonisolated struct AgentAdherenceData: Equatable, Sendable {
    let protocolName: String
    let days: [AgentAdherenceDay]
}

nonisolated struct AgentExperimentResult: Equatable, Sendable {
    /// `tooEarlyToSay`, `cannotReport`, `notEnoughNights`, `notCalled` or `result`.
    let state: String
    /// `Strong`, `Clear`, `Early` or `No change`. Only with state `result`.
    let label: String?
    let onNights: Int
    let offNights: Int
    /// On nights minus off nights, in the outcome's unit. Only with a label.
    let difference: Double?
    /// The likely range of the difference. Only with a label.
    let rangeFrom: Double?
    let rangeTo: Double?
}

nonisolated struct AgentExperimentRow: Equatable, Sendable {
    let id: String
    let title: String
    let intervention: String
    let ruleKey: String
    /// `alternating`, `blocks` or `beforeAfter`.
    let design: String
    let designLength: Int?
    let washout: Int
    let minimumNightsPerArm: Int
    let plannedNights: Int
    let outcomeKey: String
    let outcomeTitle: String
    let outcomeUnit: String
    /// `higher` or `lower`, fixed on day 1.
    let outcomeBenefit: String
    let startDay: String
    /// `running`, `finished` or `stopped`.
    let status: String
    let endDay: String?
    let stoppedEarly: Bool
    let nightsCompleted: Int
    /// Nil when the result was not computed because Band metrics and sleep is off.
    let result: AgentExperimentResult?
}

nonisolated protocol AgentProtocolReading: Sendable {
    func activeProtocol() async throws -> AgentProtocolRow?
    /// Stored checks for each day in the range, by the rules in force that day. Nil without an active protocol.
    func adherence(from: String, to: String, today: String) async throws -> AgentAdherenceData?
    /// The running experiment and the ones that overlap the range. `withResults` is false when the result needs
    /// sleep readings that Your data does not allow.
    func experiments(from: String, to: String, today: String, withResults: Bool) async throws -> [AgentExperimentRow]
}

extension AgentProtocolReading {
    func activeProtocol() async throws -> AgentProtocolRow? { nil }
    func adherence(from: String, to: String, today: String) async throws -> AgentAdherenceData? { nil }
    func experiments(from: String, to: String, today: String, withResults: Bool) async throws -> [AgentExperimentRow] { [] }
}

// MARK: Supplements and medication

/// One dose due on one day. There is no field for a prescriber, an item note or a tick note: the snapshot Ask reads
/// leaves them out, and this row has nowhere to put them.
nonisolated struct AgentStackDose: Equatable, Sendable {
    let day: String
    let name: String
    let dose: String
    let slot: String
    /// `taken`, `skipped` or `notRecorded`.
    let status: String
    /// Local `HH:mm` of the tick. Nil when nothing was recorded.
    let at: String?
}

nonisolated struct AgentStackData: Equatable, Sendable {
    let supplements: [AgentStackDose]
    let medication: [AgentStackDose]
    static let empty = AgentStackData(supplements: [], medication: [])
}

nonisolated protocol AgentSupplementsReading: Sendable {
    func stackDoses(from: String, to: String) async throws -> AgentStackData
}
extension AgentSupplementsReading {
    func stackDoses(from: String, to: String) async throws -> AgentStackData { .empty }
}

// MARK: Blood tests

/// A lab value as the lab printed it. The number is the printed digits. The range and the flag are the lab's own
/// text, and nothing here compares a value with a range.
nonisolated struct AgentLabValueRow: Equatable, Sendable {
    let id: String
    let name: String
    let markerKey: String?
    let assay: String?
    let value: String
    let unit: String?
    let rangeMin: String?
    let rangeMax: String?
    let rangeText: String?
    let flag: String?
    /// `typed` or `scan`.
    let entry: String
    /// A scanned value the person has not checked yet.
    let needsReview: Bool
}

nonisolated struct AgentLabReportRow: Equatable, Sendable {
    let id: String
    let day: String
    let labName: String?
    let fasting: Bool?
    let values: [AgentLabValueRow]
}

nonisolated struct AgentLabClockRow: Equatable, Sendable {
    let id: String
    let name: String
    let value: String
    let unit: String?
    let labName: String
    let day: String
}

nonisolated struct AgentLabsData: Equatable, Sendable {
    let reports: [AgentLabReportRow]
    let clocks: [AgentLabClockRow]
    /// Collection days of the reports outside the range, newest first, so the model can ask for them.
    let otherDays: [String]
    static let empty = AgentLabsData(reports: [], clocks: [], otherDays: [])
}

nonisolated protocol AgentLabsReading: Sendable {
    func labs(from: String, to: String) async throws -> AgentLabsData
}
extension AgentLabsReading {
    func labs(from: String, to: String) async throws -> AgentLabsData { .empty }
}

// MARK: Capacity and weekly dose (Training)

nonisolated struct AgentCapacityResultRow: Equatable, Sendable {
    let id: String
    let test: String
    let title: String
    let value: Double
    let unit: String
    /// `left` or `right`. Nil for a test with no side.
    let side: String?
    let day: String
    /// `typed`, `timed` or `workout`.
    let source: String
}

nonisolated struct AgentCapacityGoalRow: Equatable, Sendable {
    let test: String
    let title: String
    let targetValue: Double
    let unit: String
    let targetAge: Int
    let setDay: String
}

nonisolated struct AgentWeeklyDoseRow: Equatable, Sendable {
    /// ISO week, such as `2026-W42`.
    let week: String
    let firstDay: String
    let lastDay: String
    /// Nil when the band has no data for the week, or when Band metrics and sleep is off.
    let zone2Minutes: Double?
    let zone2Target: Double?
    let hardMinutes: Double?
    let hardTarget: Double?
    let strengthSessions: Int
    let strengthTarget: Int?
    let mobilitySessions: Int
    let mobilityTarget: Int?
    let bandDaysWithData: Int
    let bandDaysInWeek: Int
}

nonisolated struct AgentCapacityData: Equatable, Sendable {
    let results: [AgentCapacityResultRow]
    let goals: [AgentCapacityGoalRow]
    let weeks: [AgentWeeklyDoseRow]
    static let empty = AgentCapacityData(results: [], goals: [], weeks: [])
}

nonisolated protocol AgentCapacityReading: Sendable {
    /// `withBandMinutes` allows zone minutes from the band. `withTargets` allows the weekly targets in the protocol.
    func capacity(from: String, to: String, today: String, withBandMinutes: Bool, withTargets: Bool) async throws -> AgentCapacityData
}
extension AgentCapacityReading {
    func capacity(from: String, to: String, today: String, withBandMinutes: Bool, withTargets: Bool) async throws -> AgentCapacityData { .empty }
}

// MARK: Ages

nonisolated struct AgentCardioAgeRow: Equatable, Sendable {
    let available: Bool
    let years: Double?
    /// The label the Body screen shows, such as "30 or younger".
    let label: String?
    let vo2Max: Double?
    /// `Apple Health`, `lab test` or `Loopr estimate`.
    let vo2MaxSource: String?
    let day: String?
}

nonisolated struct AgentBloodAgeRow: Equatable, Sendable {
    let years: Double
    let collectedDay: String
}

nonisolated protocol AgentAgesReading: Sendable {
    func cardioAge(today: String) async throws -> AgentCardioAgeRow?
    /// The seam for PhenoAge. Until that branch is merged nothing computes it, so the default is nil.
    func bloodAge() async throws -> AgentBloodAgeRow?
}
extension AgentAgesReading {
    func cardioAge(today: String) async throws -> AgentCardioAgeRow? { nil }
    func bloodAge() async throws -> AgentBloodAgeRow? { nil }
}
