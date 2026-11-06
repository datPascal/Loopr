import AIKit
import AnalyticsKit
import BodyKit
import DataKit
import DomainKit
import FoodKit
import Foundation
import RoutineKit
import StorageKit
import TrainKit
import WorkoutKit

/// Reads the longevity stores for the Ask tools (LV-09). Nothing here checks Your data. `AgentReaders` does that
/// before it hands any method to a tool, and again after the read.
///
/// Every row it builds is a plain value with no free text from the person: no version notes, rebuttals, report
/// notes, dose notes or prescriber.
nonisolated struct LooprLongevityAgentReader: AgentProtocolReading, AgentSupplementsReading, AgentLabsReading,
                                              AgentCapacityReading, AgentAgesReading {
    private let routineStore: RoutineStore
    private let experimentStore: ExperimentStore
    private let supplementStore: SupplementStore
    private let labStore: LabStore
    private let capacityStore: CapacityStore
    private let trainStore: TrainStore?
    private let workoutRecords: @Sendable () async -> [WorkoutRecord]
    private let body: (any BodyRepository)?
    private let history: any MetricHistoryProviding
    private let timeZone: TimeZone

    init(database: StorageDatabase, train: TrainStore? = nil, workoutRecords: @escaping @Sendable () async -> [WorkoutRecord] = { [] },
         body: (any BodyRepository)? = nil, history: any MetricHistoryProviding = EmptyMetricHistoryProvider(),
         timeZone: TimeZone = .current) {
        routineStore = RoutineStore(database: database); experimentStore = ExperimentStore(database: database)
        supplementStore = SupplementStore(database: database); labStore = LabStore(database: database)
        capacityStore = CapacityStore(database: database); trainStore = train; self.workoutRecords = workoutRecords
        self.body = body; self.history = history; self.timeZone = timeZone
    }

    private func dayString(_ date: Date) -> String { AgentDays.string(date, in: timeZone) }
    private static func clock(minutes: Int) -> String { String(format: "%02d:%02d", minutes / 60, minutes % 60) }

    /// The stores read SQLite synchronously. Run those reads off the main actor.
    private func offMain<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated) { try work() }.value
    }

    // MARK: Protocol

    func activeProtocol() async throws -> AgentProtocolRow? {
        let store = routineStore, zone = timeZone
        return try await offMain {
            guard let active = try store.activeProtocol() else { return nil }
            let versions = try store.versions(protocolID: active.routineProtocol.id)
            let latest = active.latestVersion
            return AgentProtocolRow(name: active.routineProtocol.name, version: latest.number,
                versionDay: AgentDays.string(latest.createdAt, in: zone), rules: latest.rules.map(Self.ruleRow),
                versions: versions.map { AgentProtocolVersionRow(number: $0.number, day: AgentDays.string($0.createdAt, in: zone)) })
        }
    }

    private static func ruleRow(_ rule: ProtocolRule) -> AgentProtocolRuleRow {
        AgentProtocolRuleRow(key: rule.key.rawValue, title: rule.title, group: rule.group.rawValue, source: rule.source.rawValue,
            targetKind: rule.target.kind.rawValue, targetMetric: rule.target.metric, targetValue: rule.target.value,
            targetUnit: rule.target.unit, time: rule.timeOfDayMinutes.map(clock(minutes:)), evening: rule.isEvening)
    }

    // MARK: Adherence

    func adherence(from: String, to: String, today: String) async throws -> AgentAdherenceData? {
        let store = routineStore, zone = timeZone
        return try await offMain {
            guard let active = try store.activeProtocol() else { return nil }
            let id = active.routineProtocol.id
            let versions = try store.versions(protocolID: id)
            guard let first = versions.first else { return nil }
            let firstDay = AgentDays.string(first.createdAt, in: zone)
            func titleOf(_ key: RuleKey, version: Int) -> String {
                versions.first { $0.number == version }?.rule(for: key)?.title
                    ?? versions.reversed().compactMap { $0.rule(for: key)?.title }.first ?? key.rawValue
            }
            var days: [AgentAdherenceDay] = []
            for day in AgentDays.days(from: from, to: to) {
                guard let identity = DayIdentity(routineDayKey: day) else { continue }
                let stored = try store.checks(protocolID: id, day: identity)
                // A day before the Protocol began has nothing unless history was migrated onto it.
                guard day >= firstDay || !stored.isEmpty else { continue }
                let dayEnd = (AgentDays.noon(of: day, in: zone) ?? .distantPast).addingTimeInterval(12 * 3_600)
                let inForce = versions.last { $0.createdAt <= dayEnd } ?? first
                let byKey = Dictionary(stored.map { ($0.ruleKey, $0) }, uniquingKeysWith: { _, latest in latest })
                var checks = inForce.rules.map { rule -> AgentAdherenceCheck in
                    // No stored check yet: today may still be kept, a past day was never recorded.
                    let state = byKey[rule.key]?.state.rawValue ?? (day == today ? "pending" : "unknown")
                    return AgentAdherenceCheck(ruleKey: rule.key.rawValue, title: rule.title, state: state)
                }
                // A check from a version with a rule the version in force no longer has still counts.
                let listed = Set(inForce.rules.map(\.key))
                for check in stored where !listed.contains(check.ruleKey) {
                    checks.append(AgentAdherenceCheck(ruleKey: check.ruleKey.rawValue, title: titleOf(check.ruleKey, version: check.version),
                                                      state: check.state.rawValue))
                }
                days.append(AgentAdherenceDay(day: day, version: inForce.number, checks: checks))
            }
            return AgentAdherenceData(protocolName: active.routineProtocol.name, days: days)
        }
    }

    // MARK: Experiments

    /// The outcome metrics an experiment can fix on day 1, as the history series that holds them. A metric with no
    /// series has no baseline, and then no result.
    static func historyKey(forOutcome key: String) -> MetricKey? {
        switch key {
        case ExperimentMetric.deepSleep.key: .deepSleep
        case ExperimentMetric.sleepHeartRate.key: .sleepingHeartRate
        case ExperimentMetric.hrv.key: .rmssd
        default: nil
        }
    }

    func experiments(from: String, to: String, today: String, withResults: Bool) async throws -> [AgentExperimentRow] {
        let store = experimentStore
        let all = try await offMain { try store.experiments() }
        let chosen = all.filter { experiment in
            if experiment.status == .running { return true }
            let start = experiment.start.startDay.routineDayKey ?? ""
            let end = (experiment.endDay ?? experiment.start.lastPlannedDay).routineDayKey ?? ""
            return start <= to && end >= from
        }
        guard let todayID = DayIdentity(routineDayKey: today), let lastNight = todayID.adding(days: -1) else { return [] }
        var rows: [AgentExperimentRow] = []
        for experiment in chosen {
            var result: AgentExperimentResult?
            var nightsCompleted = experiment.schedule.nights.filter { ($0.day.days(until: lastNight) ?? -1) >= 0 }.count
            if withResults {
                let baseline = try await outcomeBaseline(for: experiment)
                let id = experiment.id
                let report = try await offMain { try store.report(experimentID: id, baseline: baseline, lastNight: lastNight) }
                result = Self.result(report)
                nightsCompleted = report.nightsCompleted
            }
            let start = experiment.start
            rows.append(AgentExperimentRow(
                id: start.id.rawValue.uuidString, title: start.title, intervention: start.interventionName, ruleKey: start.ruleKey.rawValue,
                design: start.design.kind, designLength: start.design.length, washout: start.washout,
                minimumNightsPerArm: start.minimumNightsPerArm, plannedNights: start.plannedNights, outcomeKey: start.outcome.key,
                outcomeTitle: start.outcome.title, outcomeUnit: start.outcome.unit, outcomeBenefit: start.outcome.benefit.rawValue,
                startDay: start.startDay.routineDayKey ?? "", status: experiment.status.rawValue, endDay: experiment.endDay?.routineDayKey,
                stoppedEarly: experiment.stoppedEarly, nightsCompleted: nightsCompleted, result: result))
        }
        return rows
    }

    /// The outcome on the nights before day 1, keyed by the night's day. A night is recorded on the day the person
    /// wakes, so the reading for night `d` sits on `d + 1`.
    private func outcomeBaseline(for experiment: Experiment) async throws -> [DayIdentity: Double] {
        guard let key = Self.historyKey(forOutcome: experiment.start.outcome.key),
              let startKey = experiment.start.startDay.routineDayKey,
              let end = AgentDays.noon(of: startKey, in: timeZone) else { return [:] }
        let window = ExperimentPolicy.standard.baselineWindowNights
        let points = try await history.series(for: key, days: window, endingOn: end)
        var baseline: [DayIdentity: Double] = [:]
        for point in points {
            guard let woke = DayIdentity(routineDayKey: dayString(point.day)), let night = woke.adding(days: -1),
                  (night.days(until: experiment.start.startDay) ?? 0) > 0 else { continue }
            baseline[night] = point.value
        }
        return baseline
    }

    private static func result(_ report: ExperimentReport) -> AgentExperimentResult {
        func make(_ state: String, label: ExperimentLabel? = nil) -> AgentExperimentResult {
            AgentExperimentResult(state: state, label: label?.title, onNights: report.on.nights, offNights: report.off.nights,
                difference: label == nil ? nil : report.difference, rangeFrom: label == nil ? nil : report.range?.lowerBound,
                rangeTo: label == nil ? nil : report.range?.upperBound)
        }
        switch report.state {
        case .cannotReport: return make("cannotReport")
        case .tooEarlyToSay: return make("tooEarlyToSay")
        case .notEnoughNights: return make("notEnoughNights")
        case .notCalled: return make("notCalled")
        case .result(let label): return make("result", label: label)
        }
    }

    // MARK: Supplements and medication

    func stackDoses(from: String, to: String) async throws -> AgentStackData {
        let store = supplementStore, zone = timeZone
        return try await offMain {
            let snapshot = try store.askSnapshot(from: from, through: to)
            func at(_ date: Date?) -> String? { date.map { AgentDays.clock($0, zoneID: zone.identifier) } }
            return AgentStackData(
                supplements: snapshot.supplements.map {
                    AgentStackDose(day: $0.localDay, name: $0.name, dose: $0.dose, slot: $0.slot.rawValue, status: $0.status.rawValue, at: at($0.recordedAt))
                },
                medication: snapshot.medication.map {
                    AgentStackDose(day: $0.localDay, name: $0.name, dose: $0.dose, slot: $0.slot.rawValue, status: $0.status.rawValue, at: at($0.recordedAt))
                })
        }
    }

    // MARK: Blood tests

    func labs(from: String, to: String) async throws -> AgentLabsData {
        let store = labStore
        return try await offMain {
            var reports: [AgentLabReportRow] = []
            var other: Set<String> = []
            for report in try store.reports() {
                guard let day = report.collectedDay else { continue }
                guard day >= from, day <= to else { other.insert(day); continue }
                let values = try store.values(reportID: report.id).map { value in
                    AgentLabValueRow(id: value.id.uuidString, name: value.subject.displayName, markerKey: value.subject.markerKey?.rawValue,
                        assay: value.assay, value: value.printedText, unit: value.unit,
                        rangeMin: value.referenceRange.low?.description, rangeMax: value.referenceRange.high?.description,
                        rangeText: value.referenceRange.text, flag: value.flagText, entry: value.source.rawValue, needsReview: value.needsReview)
                }
                reports.append(AgentLabReportRow(id: report.id.uuidString, day: day, labName: report.labName, fasting: report.fasting, values: values))
            }
            var clocks: [AgentLabClockRow] = []
            for clock in try store.clockResults() {
                guard let day = clock.collectedDay else { continue }
                guard day >= from, day <= to else { other.insert(day); continue }
                clocks.append(AgentLabClockRow(id: clock.id.uuidString, name: clock.kind.displayName, value: clock.value.description,
                                               unit: clock.unit, labName: clock.labName, day: day))
            }
            return AgentLabsData(reports: reports.sorted { ($0.day, $0.id) < ($1.day, $1.id) },
                                 clocks: clocks.sorted { ($0.day, $0.id) < ($1.day, $1.id) },
                                 otherDays: Array(other.sorted(by: >).prefix(24)))
        }
    }

    // MARK: Capacity and weekly dose

    func capacity(from: String, to: String, today: String, withBandMinutes: Bool, withTargets: Bool) async throws -> AgentCapacityData {
        let capacityDB = capacityStore, routine = routineStore, zone = timeZone
        let (results, goals, targets) = try await offMain { () -> ([CapacityResult], [CapacityTestKind: CapacityGoal], DoseTargets) in
            var targets = DoseTargets.none
            if withTargets, let active = try routine.activeProtocol() { targets = DoseTargets(rules: active.latestVersion.rules) }
            return (try capacityDB.allResults(), try capacityDB.goals(), targets)
        }
        let resultRows = results.compactMap { result -> AgentCapacityResultRow? in
            let day = AgentDays.string(result.recordedAt, in: TimeZone(identifier: result.timeZoneIdentifier) ?? zone)
            guard day >= from, day <= to else { return nil }
            return AgentCapacityResultRow(id: result.id.uuidString, test: result.kind.rawValue, title: result.kind.title, value: result.value,
                unit: result.unit, side: result.side?.rawValue, day: day, source: result.source.rawValue)
        }.sorted { ($0.day, $0.id) < ($1.day, $1.id) }
        let goalRows = goals.values.sorted { $0.kind.rawValue < $1.kind.rawValue }.map { goal in
            AgentCapacityGoalRow(test: goal.kind.rawValue, title: goal.kind.title, targetValue: goal.targetValue, unit: goal.unit,
                                 targetAge: CapacityGoal.targetAge, setDay: AgentDays.string(goal.setAt, in: zone))
        }
        return AgentCapacityData(results: resultRows, goals: goalRows,
            weeks: try await weeklyDose(from: from, to: to, today: today, withBandMinutes: withBandMinutes, targets: targets))
    }

    private func weeklyDose(from: String, to: String, today: String, withBandMinutes: Bool, targets: DoseTargets) async throws -> [AgentWeeklyDoseRow] {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        var weeks: [ISOWeek] = []
        for day in AgentDays.days(from: from, to: to) {
            guard let noon = AgentDays.noon(of: day, in: timeZone), let week = ISOWeek(containing: noon, calendar: calendar),
                  !weeks.contains(week) else { continue }
            weeks.append(week)
        }
        guard !weeks.isEmpty else { return [] }

        var sessions: [DoseSession] = []
        if let trainStore {
            let store = trainStore
            sessions += try await offMain { try store.sessions() }.compactMap { DoseSession(trainSession: $0) }
        }
        let linked = Set(sessions.compactMap(\.id))
        for workout in await workoutRecords() where !workout.isActive && !linked.contains(workout.id) {
            guard let start = workout.startedAt else { continue }
            sessions.append(DoseSession(id: workout.id, activity: workout.activity, date: start))
        }

        var rows: [AgentWeeklyDoseRow] = []
        for week in weeks {
            var doseDays: [DoseDay] = []
            if withBandMinutes, let body {
                for day in week.days {
                    guard let key = day.routineDayKey, key <= today, let snapshot = try await body.readBodyDay(for: day) else { continue }
                    let zones = Dictionary(snapshot.zoneMinutes.map { ($0.id, $0.minutes) }, uniquingKeysWith: { first, _ in first })
                    // No zone minutes saved for the day means the band had no usable heart rate, not zero minutes.
                    let band: BandZoneMinutes? = zones.isEmpty ? nil : BandZoneMinutes(zones: (1...5).map { zones[$0] ?? 0 })
                    doseDays.append(DoseDay(day: day, zones: band))
                }
            }
            let dose = WeeklyDose.make(week: week, days: doseDays, sessions: sessions, targets: targets)
            let keys = week.days.compactMap(\.routineDayKey)
            rows.append(AgentWeeklyDoseRow(
                week: String(format: "%04d-W%02d", week.yearForWeekOfYear, week.weekOfYear),
                firstDay: keys.first ?? from, lastDay: keys.last ?? to,
                zone2Minutes: dose.zone2.minutes, zone2Target: dose.zone2.target, hardMinutes: dose.hard.minutes, hardTarget: dose.hard.target,
                strengthSessions: dose.strength.count, strengthTarget: dose.strength.target,
                mobilitySessions: dose.mobility.count, mobilityTarget: dose.mobility.target,
                bandDaysWithData: dose.bandDaysWithData, bandDaysInWeek: dose.bandDaysInWeek))
        }
        return rows
    }

    // MARK: Ages

    func cardioAge(today: String) async throws -> AgentCardioAgeRow? {
        guard let body else { return nil }
        var fallback: AgentCardioAgeRow?
        for offset in 0..<7 {
            guard let key = AgentDays.add(-offset, to: today), let day = DayIdentity(routineDayKey: key),
                  let result = try await body.readBodyDay(for: day)?.cardioAge else { continue }
            let row = AgentCardioAgeRow(available: result.isAvailable, years: result.ageYears, label: result.displayLabel, vo2Max: result.vo2max,
                                        vo2MaxSource: result.source.map(Self.sourceLabel), day: key)
            if result.isAvailable { return row }
            fallback = fallback ?? row
        }
        return fallback
    }

    private static func sourceLabel(_ source: VO2MaxSourceKind) -> String {
        switch source {
        case .healthKit: "Apple Health"
        case .measuredCPET: "lab test"
        case .looprExerciseEstimate: "Loopr estimate"
        }
    }

    /// The one seam for PhenoAge. The calculator lives on a parallel branch (LV-06). When it merges, compute blood age
    /// here from the newest report that holds its nine markers and return it. Until then there is no blood age.
    func bloodAge() async throws -> AgentBloodAgeRow? { nil }
}
